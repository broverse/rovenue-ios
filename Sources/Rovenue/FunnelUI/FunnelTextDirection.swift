//  FunnelTextDirection.swift — which way a funnel's copy reads, from the
//  locale it is drawn in (spec 2026-10-17-button-icons §4.4; the web's
//  `packages/funnel-renderer/src/text-direction.ts`).
//
//  The resolver hands the drawer a screen in logical terms — a button icon
//  at `start`, a row's leading edge — and SwiftUI mirrors them only under a
//  right-to-left `layoutDirection`. Nothing set it: an Arabic funnel in an
//  English app drew its `start` icons on the left. `RovenueFunnelView
//  (placementId:)` now sets it from the funnel's own locale.

import Foundation
import SwiftUI

/// The primary language subtags written right to left — the web's
/// `RTL_LANGUAGES` (text-direction.ts), BCP 47, lower-cased. Matched on the
/// primary subtag only: a script subtag (`ku-Arab` vs `ku-Latn`) is not
/// read, so Kurdish is not listed rather than guessed.
let RTL_LANGUAGES: Set<String> = [
    "ar",  // Arabic
    "he",  // Hebrew
    "iw",  // Hebrew (legacy tag)
    "fa",  // Persian
    "ur",  // Urdu
    "ps",  // Pashto
    "sd",  // Sindhi
    "ug",  // Uyghur
    "yi",  // Yiddish
    "dv",  // Dhivehi
]

enum FunnelTextDirection {
    /// BCP 47 separates subtags with `-`; ICU-style tags (`Locale.identifier`) use `_`.
    private static let subtagSeparators: Set<Character> = ["-", "_"]
    /// The published config's source-locale key.
    private static let defaultLocaleKey = "defaultLocale"
    /// A draft payload wraps the config under this key.
    private static let configKey = "config"

    /// `locale`'s primary language subtag, lower-cased.
    static func primaryLanguage(_ locale: String) -> String {
        String(locale.split(whereSeparator: { subtagSeparators.contains($0) }).first ?? "").lowercased()
    }

    /// The direction `locale`'s copy reads in — left to right for anything not listed.
    static func layoutDirection(of locale: String) -> LayoutDirection {
        RTL_LANGUAGES.contains(primaryLanguage(locale)) ? .rightToLeft : .leftToRight
    }

    /// The locale a funnel's copy is drawn in — the web runner's rule
    /// (`useRunnerLocale`): the requested locale when the document carries
    /// copy in its language, else the document's source locale (which is
    /// what the resolver falls every text back to). nil when `json` is not
    /// a funnel config (or a draft payload wrapping one) with a source
    /// locale.
    ///
    /// The document's languages are the keys of its localized maps: an
    /// object whose values are all strings and which carries the source
    /// locale (every authored text has its source-locale copy).
    static func contentLocale(configJson json: String, requested: String) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            var config = parsed as? [String: Any]
        else { return nil }
        if config[defaultLocaleKey] == nil, let inner = config[configKey] as? [String: Any] { config = inner }
        guard let source = config[defaultLocaleKey] as? String, !source.isEmpty else { return nil }
        let wanted = primaryLanguage(requested)
        if wanted == primaryLanguage(source) { return requested }
        var languages = Set<String>()
        collectLanguages(config, source: source, into: &languages)
        return languages.contains(wanted) ? requested : source
    }

    /// The direction for a funnel config drawn for `requested`; nil when
    /// the config names no source locale (the view then inherits the host's).
    static func layoutDirection(configJson: String, requested: String) -> LayoutDirection? {
        contentLocale(configJson: configJson, requested: requested).map(layoutDirection(of:))
    }

    private static func collectLanguages(_ node: Any, source: String, into languages: inout Set<String>) {
        if let object = node as? [String: Any] {
            if object[source] != nil, object.values.allSatisfy({ $0 is String }) {
                for key in object.keys { languages.insert(primaryLanguage(key)) }
                return
            }
            for value in object.values { collectLanguages(value, source: source, into: &languages) }
        } else if let array = node as? [Any] {
            for value in array { collectLanguages(value, source: source, into: &languages) }
        }
    }
}
