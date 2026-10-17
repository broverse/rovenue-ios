//  ResolvedFunnel.swift — a placement resolved to a funnel, ready to run.
//
//  The session is already open: `getFunnel` opens it in core, where the
//  offering crosses structurally (identifiers, store product ids and
//  display-name titles), and then hands it the StoreKit prices — the
//  platform's job, since core performs no store I/O
//  (Internal/FunnelPackagePrices.swift).

import Foundation

/// What `Rovenue.shared.getFunnel` hands back.
public struct ResolvedFunnel: @unchecked Sendable {
    public let placementIdentifier: String
    public let placementRevision: Int64
    public let identifier: String
    /// The published version number. A stored session recorded against a
    /// different one is discarded rather than replayed.
    public let revision: Int64
    public let configFormatVersion: Int64
    /// True only when the bundled fallback file answered — network AND
    /// disk cache both missed.
    public let servedFromFallback: Bool
    /// Ready to drive. Hand it to `RovenueFunnelView`.
    public let session: FunnelSession
}
