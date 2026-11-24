//  AppleRestoreFlow.swift — pure, testable restore orchestration (spec
//  docs/superpowers/specs/2026-11-23-sdk-restore-owned-purchases-design.md).
//
//  The same four steps as the Kotlin SDK's restore:
//    1. collect what the store says this account owns (`sync`, then `owned`);
//    2. post each one through the receipt path the purchase flow uses;
//    3. refresh entitlements (a failure here throws);
//    4. decide with `restoreFailure`: a failed step is an error only while
//       no entitlement is active.
//
//  Failure modes answered here (numbers from the spec):
//    R3  every POST failed, the refresh worked, no access → the retryable
//        error is thrown instead of an empty success.
//    R4  the server refused for good (409 RECEIPT_IN_USE) → that error.
//    R5  a failed POST, but an entitlement is active → success.
//    R6  one transient and one permanent failure → the transient one.
//    R8  `AppStore.sync()` failed and nothing was restored → the sync error;
//        the refresh still ran.
//    R9  the user cancelled the App Store sign-in (`.purchaseCanceled` from
//        `sync`) → not a failure; what is on the device is still posted.
//    R10 task cancellation → rethrown, never counted as a failed receipt or a
//        failed sync. Three ways it arrives, all ending the restore:
//        a step throws `CancellationError`; StoreKit reports the cancelled
//        task as some other error (the task is then cancelled, so that is
//        checked before the error is judged); a step does not observe
//        cancellation at all (a receipt POST runs to its end on the core's
//        queue), so the task is checked before each POST and the refresh.
//    R15 the refresh failed → thrown.
//
//  The POSTs do not go through `AppleTransactionRecovery`: its per-session
//  "already landed" set would skip a transaction that has to move to the
//  identity the user switched to (R16).
//
//  StoreKit and the core are injected, so this type runs under `swift test`
//  with fakes — no StoreKit, no network.

import Foundation
import StoreKit

/// One purchase the App Store says this Apple ID currently owns.
internal struct OwnedAppleTransaction: Sendable {
    let jws: String
    let productId: String
}

internal struct AppleRestoreFlow {
    /// `AppStore.sync()`, with whatever it throws: `run` judges the error
    /// (`appStoreSyncError`), so cancellation is seen before any mapping.
    let sync: @Sendable () async throws -> Void
    /// The verified `Transaction.currentEntitlements`.
    let owned: @Sendable () async -> [OwnedAppleTransaction]
    /// The receipt POST for one owned transaction.
    let post: @Sendable (_ transaction: OwnedAppleTransaction) async throws -> Void
    /// Refreshes entitlements against the server and returns them.
    let refresh: @Sendable () async throws -> [Entitlement]

    /// The refreshed entitlements, or the error `restoreFailure` picks.
    func run() async throws -> [Entitlement] {
        var failures: [Error] = []
        do {
            try await sync()
        } catch {
            try rethrowIfCancelled(error) // [R10]
            let failure = appStoreSyncError(error)
            // [R9] a cancelled sign-in is the user's choice, not a failure.
            if failure.kind != .purchaseCanceled { failures.append(failure) } // [R8]
        }
        for transaction in await owned() {
            try Task.checkCancellation() // [R10]
            do {
                try await post(transaction)
            } catch {
                try rethrowIfCancelled(error) // [R10]
                failures.append(error)
            }
        }
        try Task.checkCancellation() // [R10]
        let entitlements = try await refresh() // [R15]
        if let failure = restoreFailure(failures, entitlements: entitlements) { throw failure }
        return entitlements
    }
}

/// Ends a restore whose task was cancelled while a step ran: throws
/// `CancellationError` when `error` is one, or when the task is cancelled and
/// the step reported it as something else.
private func rethrowIfCancelled(_ error: Error) throws {
    if error is CancellationError { throw error }
    try Task.checkCancellation()
}

/// What a restore throws once every owned purchase was posted and
/// entitlements were refreshed, or nil for a success (R3–R6; the Kotlin SDK's
/// `restoreFailure` is the same rule). A failed step is an error only while
/// no entitlement is active — with access there is nothing left to restore.
/// A retryable failure is preferred, so the app can offer "try again"
/// whenever trying again could work.
internal func restoreFailure(_ failures: [Error], entitlements: [Entitlement]) -> Error? {
    guard let first = failures.first, !entitlements.contains(where: \.isActive) else { return nil }
    return failures.first { ($0 as? RovenueError)?.isRetryable == true } ?? first
}

/// `AppStore.sync()`'s error as the restore reports it: a cancelled sign-in
/// is `.purchaseCanceled` (quiet, R9); a network or system error is the
/// retryable `.storeServiceUnavailable`, as `StoreKitAppleStore.purchase`
/// maps it; anything else is `.storeProblem`.
internal func appStoreSyncError(_ error: Error) -> RovenueError {
    if let known = error as? RovenueError { return known }
    guard let storeKit = error as? StoreKitError else {
        return RovenueError(kind: .storeProblem, message: "\(error)")
    }
    switch storeKit {
    case .userCancelled:
        return RovenueError(kind: .purchaseCanceled, message: "The App Store sign-in was cancelled")
    case .networkError, .systemError:
        return RovenueError(kind: .storeServiceUnavailable, message: "The App Store is temporarily unavailable")
    default:
        return RovenueError(kind: .storeProblem, message: "\(storeKit)")
    }
}
