//  DraftReplay.swift — keeping the screen across a live refresh (spec
//  2026-10-17 §3.5, FM7).
//
//  A draft session opens at the funnel's first screen and takes no restored
//  state (a draft revision is not a stable identity), so the view keeps the
//  screen another way: every input the visitor gave the old session (taps,
//  answers, package picks, back, a purchase that succeeded, a check's
//  outcome) is recorded, and replayed onto the session
//  built from the edited draft. The replay is kept when it lands on the
//  screen the visitor was looking at; when the edit removed that screen, or
//  rerouted the way there, the new session starts from the first screen
//  instead.
//
//  Replaying calls the session directly, not the driver: the effects the
//  replayed steps produce (a purchase, a URL) already happened once and are
//  dropped.

import Foundation

/// One input a visitor gave a funnel session.
enum DraftInput {
    case tap(String)
    case submit(String, String)
    case selectPackage(String)
    case back
    case purchaseSucceeded(String, close: Bool)
    case checkResult(String, FunnelCheckOutcome)
    // Spec NE §5.2: an expiry chain, an evergreen anchor, a popup's open /
    // dismiss and a loader's completion each change the session.
    case tick(Int64)
    case countdownAnchor(String, Int64)
    case popupTrigger(String, String)
    case popupDismiss(String, String)
    case loaderCompleted(String)
}

/// A session that records every input it is given, so another session
/// can be brought to the same screen. Every `FunnelSessionDriving` method
/// reaches the session — a protocol-extension default left in place (meant
/// for a test's fake) would make the draft lane behave unlike the live one
/// (plan 2026-11-03-funnel-followup-fixes F4).
final class RecordingFunnelSession: FunnelSessionDriving, FunnelUpcomingScreens {
    private let session: FunnelSession
    private(set) var inputs: [DraftInput]

    init(_ session: FunnelSession, inputs: [DraftInput] = []) {
        self.session = session
        self.inputs = inputs
    }

    func current() -> FunnelStep { session.current() }

    func tap(_ path: String) -> FunnelStep {
        inputs.append(.tap(path))
        return session.tap(actionPath: path)
    }

    func submit(_ blockId: String, _ answerJson: String) -> FunnelStep {
        inputs.append(.submit(blockId, answerJson))
        return session.submit(blockId: blockId, answerJson: answerJson)
    }

    func selectPackage(_ identifier: String) -> FunnelStep {
        inputs.append(.selectPackage(identifier))
        return session.selectPackage(identifier: identifier)
    }

    func back() -> FunnelStep {
        inputs.append(.back)
        return session.back()
    }

    /// Recorded: the "After purchase" page it moves to must survive a refresh.
    func purchaseSucceeded(_ packageId: String, close: Bool) -> FunnelStep {
        inputs.append(.purchaseSucceeded(packageId, close: close))
        return session.purchaseSucceeded(packageId: packageId, close: close)
    }

    /// Recorded: a passed check's route (`onPass`) must survive a refresh,
    /// and the replay must not ask the host to check again.
    func checkResult(_ key: String, _ outcome: FunnelCheckOutcome) -> FunnelStep {
        inputs.append(.checkResult(key, outcome))
        return session.checkResult(key: key, outcome: outcome)
    }

    /// Not recorded: the driver over a replayed session hands it the
    /// device scheme again as it appears.
    func setColorScheme(_ scheme: FunnelColorScheme) -> FunnelStep {
        session.setColorScheme(scheme: scheme)
    }

    /// Recorded when it changed something: an expiry's chain (and its
    /// navigation) must survive a refresh, while the once-a-second ticks
    /// that move nothing would only grow the replay.
    func tick(nowMs: Int64) -> FunnelStep {
        let before = session.current().screenJson
        let step = session.tick(nowMs: nowMs)
        if !step.effects.isEmpty || step.finished || step.screenJson != before {
            inputs.append(.tick(nowMs))
        }
        return step
    }

    /// Recorded: the evergreen anchor must not restart on a refresh.
    func countdownAnchor(key: String, nowMs: Int64) -> Int64 {
        inputs.append(.countdownAnchor(key, nowMs))
        return session.countdownAnchor(key: key, nowMs: nowMs)
    }

    /// Not recorded: it reads.
    func clockSkewMs() -> Int64 { session.clockSkewMs() }

    /// Recorded: an opened popup stays open (and shown once) across a refresh.
    func popupTrigger(popupId: String, trigger: String) -> FunnelStep {
        inputs.append(.popupTrigger(popupId, trigger))
        return session.popupTrigger(popupId: popupId, trigger: trigger)
    }

    /// Recorded: a dismissed popup stays closed across a refresh.
    func popupDismiss(popupId: String, via: String) -> FunnelStep {
        inputs.append(.popupDismiss(popupId, via))
        return session.popupDismiss(popupId: popupId, via: via)
    }

    /// Recorded: a completed loader's release and route survive a refresh.
    func loaderCompleted(blockId: String) -> FunnelStep {
        inputs.append(.loaderCompleted(blockId))
        return session.loaderCompleted(blockId: blockId)
    }

    /// A draft session emits nothing; the call is kept for the protocol.
    func dismiss() { session.dismiss() }

    func stateJson() -> String { session.stateJson() }

    /// Not recorded: it reads, and a replay never needs it.
    func upcomingScreensJson() -> [String] { session.upcomingScreensJson() }

    /// `inputs` replayed onto `session`, effects dropped: the session the
    /// replay leaves, recording on from there.
    static func replaying(_ inputs: [DraftInput], onto session: FunnelSession) -> RecordingFunnelSession {
        for input in inputs {
            switch input {
            case .tap(let path): _ = session.tap(actionPath: path)
            case .submit(let blockId, let answer): _ = session.submit(blockId: blockId, answerJson: answer)
            case .selectPackage(let identifier): _ = session.selectPackage(identifier: identifier)
            case .back: _ = session.back()
            case .purchaseSucceeded(let packageId, let close):
                _ = session.purchaseSucceeded(packageId: packageId, close: close)
            case .checkResult(let key, let outcome):
                _ = session.checkResult(key: key, outcome: outcome)
            case .tick(let nowMs): _ = session.tick(nowMs: nowMs)
            case .countdownAnchor(let key, let nowMs): _ = session.countdownAnchor(key: key, nowMs: nowMs)
            case .popupTrigger(let popupId, let trigger):
                _ = session.popupTrigger(popupId: popupId, trigger: trigger)
            case .popupDismiss(let popupId, let via): _ = session.popupDismiss(popupId: popupId, via: via)
            case .loaderCompleted(let blockId): _ = session.loaderCompleted(blockId: blockId)
            }
        }
        return RecordingFunnelSession(session, inputs: inputs)
    }

    /// The id of the screen this session is on, nil when it shows none.
    var screenId: String? {
        session.current().screenJson.flatMap(decodeRenderScreen)?.screenId
    }
}
