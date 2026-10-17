//  DraftReplay.swift — keeping the screen across a live refresh (spec
//  2026-10-17 §3.5, FM7).
//
//  A draft session opens at the funnel's first screen and takes no restored
//  state (a draft revision is not a stable identity), so the view keeps the
//  screen another way: every input the visitor gave the old session (taps,
//  answers, package picks, back) is recorded, and replayed onto the session
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
}

/// A session that records every input it is given, so another session
/// can be brought to the same screen.
final class RecordingFunnelSession: FunnelSessionDriving {
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

    /// A draft session emits nothing; the call is kept for the protocol.
    func dismiss() { session.dismiss() }

    func stateJson() -> String { session.stateJson() }

    /// `inputs` replayed onto `session`, effects dropped: the session the
    /// replay leaves, recording on from there.
    static func replaying(_ inputs: [DraftInput], onto session: FunnelSession) -> RecordingFunnelSession {
        for input in inputs {
            switch input {
            case .tap(let path): _ = session.tap(actionPath: path)
            case .submit(let blockId, let answer): _ = session.submit(blockId: blockId, answerJson: answer)
            case .selectPackage(let identifier): _ = session.selectPackage(identifier: identifier)
            case .back: _ = session.back()
            }
        }
        return RecordingFunnelSession(session, inputs: inputs)
    }

    /// The id of the screen this session is on, nil when it shows none.
    var screenId: String? {
        session.current().screenJson.flatMap(decodeRenderScreen)?.screenId
    }
}
