//  FunnelPlaybackA11y.swift — what a funnel video announces as its
//  accessibility label: its true playback state, `playing` or `paused`
//  (spec 2026-11-11-funnel-followups §2.2). A carousel plays only its
//  current slide's video (spec CL §4.6, P2), and assistive tech — and the
//  E2E's native E13 probe — reads which one plays from it. (The spec says
//  value; inside a carousel the pager's position value reaches every
//  exposed element and wins, so on iOS the word is the label. Android uses
//  the state description, which the pager does not touch.)
//
//  The crate's drawer copy carries no word for it, and the crate and
//  render-trees.txt stay untouched, so the SDK carries its own table, one
//  row per language the crate's chrome copy ships. A probe matches the
//  stable `id` of the word (the table's key), never the English text.
//
//  Ways it could fail (written before the code):
//    P1 the value says `playing` while the drawer holds the video (a stale
//       value after a page change) → it is computed from the same
//       `playbackHeld` that calls `play()` / `pause()`;
//    P2 a word is written in the view → every word comes from `table`;
//    P3 a device language with no row reads nothing → `en` stands in.

import Foundation

enum FunnelPlaybackA11y {
    /// The video's accessibility identifier (the Android view id's twin).
    static let identifier = "rovenue_video"
    /// The table's stable ids for the two states.
    static let playingId = "rovenue_video_playing"
    static let pausedId = "rovenue_video_paused"

    struct Words: Equatable, Sendable {
        let playing: String
        let paused: String
    }

    /// The language a device language without a row falls back to.
    static let fallbackLanguage = "en"
    private static let regionSeparator: Character = "-"

    /// One row per language of the crate's chrome copy (chrome_copy.rs).
    static let table: [String: Words] = [
        "en": Words(playing: "Playing", paused: "Paused"),
        "tr": Words(playing: "Oynatılıyor", paused: "Duraklatıldı"),
        "de": Words(playing: "Wird abgespielt", paused: "Pausiert"),
        "es": Words(playing: "Reproduciendo", paused: "En pausa"),
        "fr": Words(playing: "Lecture en cours", paused: "En pause"),
        "pt": Words(playing: "Reproduzindo", paused: "Pausado"),
        "it": Words(playing: "In riproduzione", paused: "In pausa"),
        "ja": Words(playing: "再生中", paused: "一時停止中"),
        "ko": Words(playing: "재생 중", paused: "일시정지됨"),
        "zh": Words(playing: "正在播放", paused: "已暂停"),
    ]

    /// The row for the device's first preferred language (`zh-Hans-CN` → `zh`).
    static func words(preferred: [String] = Locale.preferredLanguages) -> Words {
        let language = preferred.first
            .flatMap { $0.split(separator: regionSeparator).first }
            .map { String($0).lowercased() }
        return language.flatMap { table[$0] } ?? table[fallbackLanguage]!
    }

    static func value(playing: Bool) -> String {
        let row = words()
        return playing ? row.playing : row.paused
    }
}
