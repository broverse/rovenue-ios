//  FunnelAnswers.swift — what a presented funnel hands back of the
//  visitor's answers: the session state's `answers` and `preselected`,
//  the same two values a web funnel's claim carries (`funnel_answers`,
//  `funnel_preselected`).

import Foundation

enum FunnelStateAnswers {
    /// The session's answers as a JSON object string, keyed by question key:
    /// every key the machine wrote — answers, `set_variable` results and
    /// seeded app values alike, as the claim's `funnel_answers` holds them.
    /// `"{}"` when there are none or the state cannot be read.
    static func answersJson(inStateJson json: String) -> String {
        guard let answers = state(json)?["answers"] as? [String: Any],
            JSONSerialization.isValidJSONObject(answers),
            let data = try? JSONSerialization.data(
                withJSONObject: answers, options: [.sortedKeys, .fragmentsAllowed]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// The question keys an app value preselected and the visitor left
    /// unchanged (the claim's `funnel_preselected`). Empty when none.
    static func preselected(inStateJson json: String) -> [String] {
        (state(json)?["preselected"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The machine state inside a persisted session: `state_json()` wraps
    /// it with the presentation id; a bare state is read as is.
    private static func state(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (root["state"] as? [String: Any]) ?? root
    }
}
