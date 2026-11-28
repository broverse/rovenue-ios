//  StoreCountry.swift — the App Store account's country, for funnel analytics.
//
//  Core owns the contract (alpha-3 → alpha-2 through the shared ISO table,
//  `unknown` for anything else) and carries the value on every native
//  `funnel_view` as `visitor.storeCountry` (spec 2026-11-27-native-funnel-
//  visitor-origin §B: "read once per session open with a short deadline;
//  never blocks presentation"). `configure` starts a read to warm it, and
//  every `getFunnel` starts (or joins) one while its placement loads, then
//  waits at most `storeCountryOpenWaitNanoseconds` for it and hands THAT
//  read's answer to the session it opens — so the first funnel after launch
//  records the storefront, not `unknown`, and a store that does not answer
//  costs the open that bound, never more. A read that times out opens the
//  session with no country (`unknown`): nothing is kept from an earlier
//  read, whose store account may have changed since.

import Foundation
import StoreKit

/// How long a funnel open waits for a storefront read still running after
/// its placement loaded (spec §B's "short deadline").
let storeCountryOpenWaitNanoseconds: UInt64 = 300_000_000

/// One storefront read: started once, finished once, awaited with a
/// deadline. The read itself is never awaited (`Storefront.current` is not
/// cancellable): each waiter gets its own timer and resumes on whichever
/// comes first — the read finishing or its deadline.
final class StoreCountryRead: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var country: String?
    private var waiters: [UUID: CheckedContinuation<String?, Never>] = [:]

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// The read answered: `country` is the storefront's code, or nil when
    /// there is none. Every waiter still within its deadline gets it.
    func finish(country: String?) {
        lock.lock()
        finished = true
        self.country = country
        let pending = waiters
        waiters = [:]
        lock.unlock()
        pending.values.forEach { $0.resume(returning: country) }
    }

    /// This read's answer when it has one within `nanoseconds`, else nil —
    /// what the open waiting on it hands its session. An answer arriving
    /// after the deadline never reaches that waiter.
    func wait(nanoseconds: UInt64) async -> String? {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            lock.lock()
            if finished {
                let answer = country
                lock.unlock()
                continuation.resume(returning: answer)
                return
            }
            waiters[id] = continuation
            lock.unlock()
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                self?.resumeWaiter(id)
            }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}

/// The SDK's storefront reads: at most one running at a time, joined by
/// every open that starts while it runs.
final class StoreCountryReader: @unchecked Sendable {
    /// Reads the storefront's country code (alpha-3), nil when there is none.
    private let readCountry: @Sendable () async -> String?
    private let lock = NSLock()
    private var current: StoreCountryRead?

    init(readCountry: @escaping @Sendable () async -> String? = { await Storefront.current?.countryCode }) {
        self.readCountry = readCountry
    }

    /// The running read, or a new one when none is running. Reads
    /// `Storefront.current?.countryCode` (alpha-3) off every caller's path;
    /// no storefront (no App Store account, Simulator without a StoreKit
    /// configuration) answers nil, which core records as `unknown`.
    @discardableResult
    func refresh() -> StoreCountryRead {
        lock.lock()
        if let running = current, !running.isFinished {
            lock.unlock()
            return running
        }
        let read = StoreCountryRead()
        current = read
        lock.unlock()
        Task.detached(priority: .utility) { [readCountry] in
            read.finish(country: await readCountry())
        }
        return read
    }
}
