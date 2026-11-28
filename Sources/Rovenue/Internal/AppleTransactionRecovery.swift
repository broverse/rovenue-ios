//  AppleTransactionRecovery.swift — posts App Store transactions the server
//  has not verified yet, from every path that can surface one, exactly once
//  at a time (spec 2026-11-22-purchase-verification-pending-design.md).
//
//  Paths:
//    1. the transaction a `purchase()` returned whose receipt POST failed
//       transiently — kept in memory and retried with backoff
//       (`scheduleRetry`);
//    2. `Transaction.updates`;
//    3. a `Transaction.unfinished` scan at configure and on each foreground.
//  All three call `attempt(_:)`.
//
//  Failure modes answered here (numbers from the spec):
//    P9  one transaction on two paths at once → `inFlight` lets one POST run
//        per id; `finished` skips an id that already landed this session.
//        `Transaction.unfinished` is eventually consistent right after a
//        purchase and may yield what `updates` yields — both land here.
//    P10 shutdown mid-retry → `stop()` cancels every retry task; the
//        transaction stays unfinished for the next backstop.
//    P11 the server credited it by S2S while the POST keeps failing →
//        `refresh` (entitlements + balances, which emit change events) runs
//        after every failed retry.
//    P12 the window ends → the loop returns; the transaction stays
//        unfinished.
//    P13 a permanent error → the loop returns; the transaction stays
//        unfinished (what the `updates` listener always did).
//    P7  an identity switch mid-retry → `post` re-sends the token the
//        transaction carries and posts with `ReceiptAttribution.buyer`: the
//        core recorded the identity that first presented this transaction
//        (on disk, so `updates` / `unfinished` find it after a relaunch
//        too) and keeps presenting it as that rovenue_id, never as the
//        identity signed in by now. The server records a receipt on
//        whoever presents it; it does not route by the token.
//
//  A transaction is finished only after its POST succeeded, and it is THAT
//  transaction object that is finished (its `finish` closure).
//
//  The clock (`sleep`), the POST and the refresh are injected, so this type
//  runs under `swift test` with fakes — no StoreKit, no network.

import Foundation

/// One App Store transaction the server has not verified yet.
internal struct PendingAppleTransaction: Sendable {
    let transactionId: String
    let jws: String
    let productId: String
    /// The token the transaction carries: the one the purchase ran with, or
    /// `Transaction.appAccountToken` for a transaction surfaced by
    /// `updates` / `unfinished`; `nil` when it has none.
    let appAccountToken: String?
    /// Finishes the original StoreKit `Transaction`.
    let finish: @Sendable () async -> Void
}

/// What one `attempt` did.
internal enum RecoveryAttempt: Equatable, Sendable {
    /// Posted and finished.
    case landed
    /// The POST failed with a retryable error; still unfinished.
    case retryLater
    /// The POST failed with a permanent error; still unfinished.
    case permanent
    /// Another path is posting it right now, it already landed, or the
    /// instance stopped — nothing was sent.
    case skipped
}

internal actor AppleTransactionRecovery {
    /// Seconds slept before each retry of a kept transaction: ≈ 3¼ minutes
    /// in all, on top of the core's own 3 attempts per POST.
    static let defaultRetryDelays: [Double] = [2, 5, 10, 20, 40, 60, 60]

    private let delays: [Double]
    private let post: @Sendable (PendingAppleTransaction) async throws -> Void
    private let onLanded: @Sendable () async -> Void
    private let refresh: @Sendable () async -> Void
    private let sleep: @Sendable (Double) async throws -> Void

    private var inFlight: Set<String> = []
    private var finished: Set<String> = []
    private var retries: [String: Task<Void, Never>] = [:]
    private var stopped = false

    init(
        delays: [Double] = AppleTransactionRecovery.defaultRetryDelays,
        post: @escaping @Sendable (PendingAppleTransaction) async throws -> Void,
        onLanded: @escaping @Sendable () async -> Void = {},
        refresh: @escaping @Sendable () async -> Void = {},
        sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.delays = delays
        self.post = post
        self.onLanded = onLanded
        self.refresh = refresh
        self.sleep = sleep
    }

    /// Post `transaction` unless another path holds it or it already landed;
    /// finish it once the server accepted it.
    @discardableResult
    func attempt(_ transaction: PendingAppleTransaction) async -> RecoveryAttempt {
        let id = transaction.transactionId
        guard !stopped, !finished.contains(id), !inFlight.contains(id) else { return .skipped }
        inFlight.insert(id)
        do {
            try await post(transaction)
        } catch {
            inFlight.remove(id)
            return (error as? RovenueError)?.isRetryable == true ? .retryLater : .permanent
        }
        await transaction.finish()
        inFlight.remove(id)
        finished.insert(id)
        await onLanded()
        return .landed
    }

    /// The purchase flow is verifying `id` itself: the other paths skip it
    /// until `release`.
    func claim(_ id: String) {
        inFlight.insert(id)
    }

    /// The purchase flow's own verification of `id` ended; `landed` when the
    /// server accepted it (the flow finishes the transaction itself).
    func release(_ id: String, landed: Bool) {
        inFlight.remove(id)
        if landed { finished.insert(id) }
    }

    /// Keep retrying a transaction whose purchase-time POST failed
    /// transiently. One loop per id; a no-op once stopped or landed.
    func scheduleRetry(_ transaction: PendingAppleTransaction) {
        let id = transaction.transactionId
        guard !stopped, !finished.contains(id), retries[id] == nil else { return }
        retries[id] = Task { await self.runRetries(transaction) }
    }

    /// Whether a POST of `id` is running (tests).
    func isInFlight(_ id: String) -> Bool {
        inFlight.contains(id)
    }

    /// The retry loop for `id`, if one is running (tests await it).
    func retryTask(_ id: String) -> Task<Void, Never>? {
        retries[id]
    }

    /// Cancel every retry and refuse new work. Final.
    func stop() {
        stopped = true
        for task in retries.values { task.cancel() }
        retries.removeAll()
    }

    private func runRetries(_ transaction: PendingAppleTransaction) async {
        let id = transaction.transactionId
        defer { retries[id] = nil }
        for delay in delays {
            do { try await sleep(delay) } catch { return }
            if Task.isCancelled || stopped || finished.contains(id) { return }
            switch await attempt(transaction) {
            case .landed, .permanent:
                return
            case .retryLater, .skipped:
                // The server may have credited it by S2S meanwhile.
                await refresh()
            }
        }
    }
}
