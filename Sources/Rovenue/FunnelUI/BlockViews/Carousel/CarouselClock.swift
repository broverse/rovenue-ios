//  CarouselClock.swift — autoplay's one clock (spec CL §4.3 F7, §4.6).
//
//  The page tick and the story bars' fill read the same anchor: the fill
//  is the share of `autoplayMs` that has run since the page SETTLED (the
//  layout's resolved move time after the tick — `fadeMs` for `fade`,
//  `curve.settleMs` for every other layout, as on the web and Android; the
//  bar is empty while the page moves), and the tick fires when that share
//  reaches one. A pause (off screen, the app
//  in the background, a finger on the carousel) keeps the elapsed share and
//  resumes from it. The first interaction with the carousel stops it for
//  good — then the current bar is drawn full.

import Foundation
import SwiftUI

@MainActor
final class CarouselClock: ObservableObject {
    /// Bumped once per elapsed interval: the carousel pages on it.
    @Published private(set) var ticks = 0
    @Published private(set) var running = false
    /// Stopped for good by an interaction, or never configured.
    @Published private(set) var stopped = false

    private var intervalMs = 0
    /// How long a page takes to move after a tick; its dwell starts then.
    private var moveMs = 0
    private var resumedAt: Date?
    private var elapsedMs = 0.0
    private var timer: Task<Void, Never>?

    /// Applies the gates: `intervalMs` nil is no autoplay at all.
    func sync(intervalMs: Int?, moveMs: Int, runs: Bool) {
        self.moveMs = moveMs
        guard let intervalMs, intervalMs > 0, !stopped else {
            halt()
            return
        }
        if intervalMs != self.intervalMs {
            self.intervalMs = intervalMs
            elapsedMs = 0
            if running { resumedAt = Date() }
        }
        if runs { resume() } else { halt() }
    }

    /// The first interaction with this carousel: autoplay never runs again.
    func stop() {
        guard !stopped else { return }
        halt()
        stopped = true
    }

    /// The current page's share of the interval, 0…1 — 1 once autoplay has
    /// stopped or when there is none (the bar is drawn full).
    func fill(at date: Date) -> Double {
        guard !stopped, intervalMs > 0 else { return 1 }
        var elapsed = elapsedMs
        if let resumedAt { elapsed += date.timeIntervalSince(resumedAt) * CarouselFormat.millisecondsPerSecond }
        return min(max(elapsed / Double(intervalMs), 0), 1)
    }

    private func resume() {
        guard !running else { return }
        running = true
        resumedAt = Date()
        schedule()
    }

    private func halt() {
        timer?.cancel()
        timer = nil
        if let resumedAt {
            elapsedMs += Date().timeIntervalSince(resumedAt) * CarouselFormat.millisecondsPerSecond
        }
        resumedAt = nil
        if running { running = false }
    }

    private func schedule() {
        timer?.cancel()
        let now = Date()
        var elapsed = elapsedMs
        if let resumedAt { elapsed += now.timeIntervalSince(resumedAt) * CarouselFormat.millisecondsPerSecond }
        let remaining = max(Double(intervalMs) - elapsed, 0)
        let due = now.addingTimeInterval(remaining / CarouselFormat.millisecondsPerSecond)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * CarouselFormat.nanosecondsPerMillisecond))
            guard !Task.isCancelled else { return }
            self?.fire(due: due)
        }
    }

    /// The next page's dwell starts when it has settled after the moment
    /// this one was due — not when the (possibly late) wake-up ran: the
    /// cadence never drifts, and the bar that has just filled hands over to
    /// the next on the same clock (F7).
    private func fire(due: Date) {
        elapsedMs = 0
        resumedAt = due.addingTimeInterval(Double(moveMs) / CarouselFormat.millisecondsPerSecond)
        ticks += 1
        schedule()
    }
}
