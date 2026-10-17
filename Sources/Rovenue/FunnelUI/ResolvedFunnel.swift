//  ResolvedFunnel.swift — a placement resolved to a funnel, ready to run,
//  and what the funnel view reports to its host (spec 2026-10-17 §3.5a).
//
//  The session is already open: `getFunnel` opens it in core, where the
//  offering crosses structurally (identifiers, store product ids and
//  display-name titles), and then hands it the StoreKit prices — the
//  platform's job, since core performs no store I/O
//  (Internal/FunnelPackagePrices.swift).

import Foundation

/// A placement resolved to a funnel: what `Rovenue.FunnelResolution.funnel`
/// carries.
public struct ResolvedFunnel: @unchecked Sendable {
    public let placementIdentifier: String
    public let placementRevision: Int64
    public let identifier: String
    /// The `funnels` row id.
    public let funnelId: String
    /// The published version number (a draft's: the version a publish
    /// would create). A stored session recorded against a different one is
    /// discarded rather than replayed.
    public let revision: Int64
    public let configFormatVersion: Int64
    /// True only when the bundled fallback file answered — network AND
    /// disk cache both missed.
    public let servedFromFallback: Bool
    /// The experiment variant this funnel was drawn as, when the placement
    /// serves an experiment over funnels.
    public let variantId: String?
    /// The experiment's key, alongside `variantId`.
    public let experimentKey: String?
    /// True when this is the funnel's latest DRAFT: a debug build on a
    /// Sandbox key (spec 2026-10-17 D1). Its session emits nothing, and
    /// `RovenueFunnelView(placementId:)` keeps it live while it is on screen.
    public let isDraft: Bool
    /// Ready to drive. Hand it to `RovenueFunnelView`.
    public let session: FunnelSession
    /// The draft response's ETag — what the live refresh sends back.
    let draftEtag: String?
    /// The locale the funnel's copy is drawn in (`FunnelTextDirection.
    /// contentLocale`): what the view's layout direction is read from. nil
    /// when the config names no source locale.
    let contentLocale: String?
}

extension Rovenue {
    /// What `getFunnel(placementId:)` resolved a placement to.
    public enum FunnelResolution {
        /// A funnel, its session open and priced.
        case funnel(ResolvedFunnel)
        /// Nothing to draw, and why. Not an error: a shipped app must not
        /// crash because a placement was retired server-side.
        case unavailable(FunnelUnavailable)
    }
}

/// `onLoaded`: the funnel's first screen is on screen. In a draft it fires
/// again after every live-refresh rebuild.
public struct FunnelLoaded: Equatable, Sendable {
    /// The placement the view was asked for.
    public let placementId: String
    /// The `funnels` row id.
    public let funnelId: String
    /// The version drawn (a draft's: the version a publish would create).
    public let revision: Int64
    /// The experiment variant drawn, when the placement serves one.
    public let variantId: String?
    /// The experiment's key, alongside `variantId`.
    public let experimentKey: String?
    /// True when the bundled fallback file answered.
    public let servedFromFallback: Bool
    /// True when this is the funnel's latest draft.
    public let isDraft: Bool
}

/// `onUnavailable`: the view has nothing to draw.
public struct FunnelUnavailable: Equatable {
    /// The placement the view was asked for.
    public let placementId: String
    /// Why there is nothing (`reason.wireName` is the cross-SDK spelling).
    public let reason: UnavailableReason
    /// What blocks the draft; set only for `.draftIssues`, empty otherwise.
    public let issues: [DraftIssue]
}

/// `onScreenChanged`: the visible screen changed, including the first.
public struct FunnelScreen: Equatable, Sendable {
    /// The screen's (page's) id in the funnel document.
    public let screenId: String
    /// Its position in the funnel's page order, from 0.
    public let index: Int
}

extension UnavailableReason {
    /// The spelling every SDK reports this reason with (spec §3.5a):
    /// `empty_placement_id`, `no_placement`, `no_target`, `no_variants` or
    /// `draft_issues`.
    public var wireName: String {
        switch self {
        case .emptyPlacementId: return "empty_placement_id"
        case .noPlacement: return "no_placement"
        case .noTarget: return "no_target"
        case .noVariants: return "no_variants"
        case .draftIssues: return "draft_issues"
        }
    }
}

extension RovenueError {
    /// The `serverCode` `onError` carries (with kind `.funnelInvalid`) when
    /// a screen the core resolved does not decode in this SDK (spec §3.5a)
    /// — reported instead of drawing a blank screen.
    public static let funnelScreenUndecodableCode = "FUNNEL_SCREEN_UNDECODABLE"
}
