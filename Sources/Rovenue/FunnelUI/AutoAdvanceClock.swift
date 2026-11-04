//  AutoAdvanceClock.swift — the device's clock for a timed screen (R2).
//
//  The server machine is timeless: a screen only SAYS how long it shows
//  (`autoAdvanceMs`), and the host that draws it keeps the time. When the
//  wait ends the host taps the routing address, the same tap a CTA button
//  would make, so the page's own chain decides where the wait leads.
//
//  The rule, identical in funnel-renderer's `useAutoAdvance` and sdk-kotlin's
//  AutoAdvanceClock:
//    - a screen with `autoAdvanceMs` arms exactly ONE tap after that long;
//    - a DIFFERENT screen, or teardown, cancels it;
//    - the SAME screen arriving again while armed keeps the running timer
//      (no restart, no second tap);
//    - once the tap has fired the arrival is consumed, so the same screen
//      arriving again afterwards is a new arrival and arms anew.
//
//  "The same screen" is `screenId` + `index` + `autoAdvanceMs` — the page,
//  its position in the funnel's order, and the wait it asks for. The same
//  page arriving with a CHANGED wait is a new arrival (3a M1).
//
//  Two device-only rules on top (C11 and the view's own lifecycle):
//    - while the view is off screen no wait runs; returning restarts the
//      wait from zero;
//    - a store sheet (`purchase` / `restorePurchases`) HOLDS the screen it
//      opened over: its wait is called off, and that screen does not arm
//      again — not on a re-apply, not on a return to the screen — until a
//      DIFFERENT screen arrives. The web runner does the same while a
//      payment is open.

import Foundation

/// The routing address a timed screen taps when its wait ends. Mirrors
/// `ACTION_PATH_ROOT` in `@rovenue/shared`, the address the crate answers
/// on every page.
let autoAdvanceTapPath = "cta"

private let nanosecondsPerMillisecond: UInt64 = 1_000_000

/// A scheduled wait that can be called off.
protocol AutoAdvanceTimer {
    func cancel()
}

/// Where the clock's time comes from. The real one sleeps a `Task`; a test
/// hands in fake time.
protocol AutoAdvanceScheduling {
    func schedule(
        afterMilliseconds milliseconds: Int,
        _ fire: @escaping @MainActor @Sendable () -> Void
    ) -> AutoAdvanceTimer
}

/// A `Task` that sleeps, then runs `fire` on the main actor — where the
/// block views tap the session too, so the timer's tap and a visitor's tap
/// are never concurrent.
struct TaskAutoAdvanceScheduler: AutoAdvanceScheduling {
    private struct TaskTimer: AutoAdvanceTimer {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }

    func schedule(
        afterMilliseconds milliseconds: Int,
        _ fire: @escaping @MainActor @Sendable () -> Void
    ) -> AutoAdvanceTimer {
        let delay = UInt64(max(milliseconds, 0)) * nanosecondsPerMillisecond
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return  // cancelled while sleeping
            }
            guard !Task.isCancelled else { return }
            fire()
        }
        return TaskTimer(task: task)
    }
}

/// Arms at most one pending tap for the screen on display.
///
/// Stale taps are refused by a GENERATION, not by cancellation alone: a
/// `Task` already past its sleep when the next screen arrives would
/// otherwise still run. Every arm and every cancel bumps the generation;
/// a firing timer whose generation is no longer current does nothing. The
/// generation lives on this object, never in a captured local `var` (the
/// CI toolchain rejects mutating one from concurrently-executing code).
///
/// `@unchecked Sendable` because the timer's closure must reach it from a
/// `Task`: every touch of its state happens on the main thread — the driver
/// applies steps where SwiftUI's block views tap, and the timer fires on
/// the main actor.
final class AutoAdvanceClock: @unchecked Sendable {
    private struct Identity: Equatable {
        let screenId: String
        let index: Int
        let waitMs: Int

        init?(_ screen: RenderScreen?) {
            guard let screen, let waitMs = screen.autoAdvanceMs else { return nil }
            self.screenId = screen.screenId
            self.index = screen.index
            self.waitMs = waitMs
        }
    }

    private let scheduler: AutoAdvanceScheduling
    private let tap: () -> Void

    private var generation: UInt64 = 0
    /// Off screen: nothing runs. A clock starts off screen, so a funnel that
    /// is resolved but never shown never advances.
    private var paused = true
    /// The timed screen on display whose arrival has not been consumed.
    private var current: Identity?
    /// The screen a store sheet opened over; it does not arm again.
    private var held: Identity?
    private var armed: Identity?
    private var timer: AutoAdvanceTimer?

    init(scheduler: AutoAdvanceScheduling, tap: @escaping () -> Void) {
        self.scheduler = scheduler
        self.tap = tap
    }

    deinit {
        timer?.cancel()
    }

    /// Called with every screen the driver publishes; `nil` for none, or
    /// for a funnel that has finished.
    func screenArrived(_ screen: RenderScreen?) {
        current = Identity(screen)
        // A different screen releases the hold.
        if held != current { held = nil }
        reconcile()
    }

    /// The view left the screen: the wait is called off.
    func pause() {
        paused = true
        reconcile()
    }

    /// The view is back on screen with `screen`: its wait runs from zero.
    func resume(_ screen: RenderScreen?) {
        paused = false
        screenArrived(screen)
    }

    /// A store sheet opened over the current screen (C11).
    func hold() {
        held = current
        reconcile()
    }

    /// Calls off any pending tap, for good: the funnel finished or went away.
    func cancel() {
        current = nil
        held = nil
        reconcile()
    }

    private func reconcile() {
        let wanted = paused || current == held ? nil : current
        // The same screen re-applied: the running wait stands.
        if wanted == armed { return }

        generation &+= 1
        timer?.cancel()
        timer = nil
        armed = wanted
        guard let wanted else { return }
        let armedGeneration = generation
        timer = scheduler.schedule(afterMilliseconds: wanted.waitMs) { [weak self] in
            self?.expire(armedGeneration)
        }
    }

    private func expire(_ firedGeneration: UInt64) {
        // A timer from an earlier screen: its tap would land on this one.
        guard firedGeneration == generation else { return }
        // Consumed before tapping: the tap may publish the next screen,
        // which must arm against a clean slate.
        generation &+= 1
        timer = nil
        armed = nil
        current = nil
        tap()
    }
}
