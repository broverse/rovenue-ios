//  FunnelDeviceLocale.swift — the locale a funnel opens in when the host passes none.
//
//  `Locale.current` is limited to the HOST APP's own localizations: an
//  English-only app on a Turkish device reports `en_TR`, so a funnel with
//  Turkish copy would draw English. The device's preferred languages are not
//  limited, so the core picks from them, in the user's order: the first one
//  the funnel has copy in, else the first one (spec 2026-11-27-native-funnel-
//  visitor-origin §C, owner ruling). An explicit `locale:` from the host
//  always wins and never reaches here.

import Foundation

extension Rovenue {
    /// The locale a funnel document (or a placement payload holding one under
    /// `config`) opens in for this device's preferred languages.
    static func deviceFunnelLocale(configJson: String) -> String {
        funnelDeviceLocale(configJson: configJson, preferred: Locale.preferredLanguages)
    }
}
