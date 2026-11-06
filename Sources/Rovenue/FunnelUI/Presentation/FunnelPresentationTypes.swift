//  FunnelPresentationTypes.swift — the public shapes of `presentFunnel`
//  (spec 2026-11-03-funnel-presentation §2, §2a, §2b): how a funnel opens,
//  who performs its purchases, and what the call resolves with.

import Foundation
import SwiftUI

/// How a presented funnel covers the app.
public enum FunnelPresentationStyle: String, Sendable, CaseIterable {
    /// Covers everything; `FunnelPresentationEnter` picks the entrance.
    case fullScreen
    /// A large card leaving the app visible at the top (the page sheet).
    case modal
    /// A bottom sheet at the funnel's `FunnelSheetDetent` heights.
    case sheet
}

/// How a full-screen funnel enters. Reduce Motion turns each into a fade.
public enum FunnelPresentationEnter: String, Sendable, CaseIterable {
    /// From the bottom edge (the system cover).
    case bottom
    /// From the trailing edge (the leading edge in a right-to-left layout).
    case side
    /// A cross-fade.
    case fade
    /// Appears at once.
    case none
}

/// A sheet height.
public enum FunnelSheetDetent: String, Sendable, CaseIterable {
    /// The first page's content height, capped at `large`.
    case fit
    /// Half the screen.
    case medium
    /// Nearly the whole screen.
    case large
}

/// A present call's partial override of how the funnel's editor settings
/// present it. A field left `nil` keeps the funnel's own; a style changed
/// here with no `dismissible` takes that style's default.
public struct FunnelPresentationOverride: Sendable, Equatable {
    /// The style to present in instead of the funnel's.
    public var style: FunnelPresentationStyle?
    /// The full-screen entrance instead of the funnel's.
    public var enter: FunnelPresentationEnter?
    /// The sheet heights instead of the funnel's.
    public var detents: [FunnelSheetDetent]?
    /// Whether a swipe closes the funnel.
    public var dismissible: Bool?
    /// Whether a successful purchase or restore closes the funnel.
    public var closeOnPurchase: Bool?

    /// - Parameters:
    ///   - style: the style to present in; `nil` keeps the funnel's.
    ///   - enter: the full-screen entrance; `nil` keeps the funnel's.
    ///   - detents: the sheet heights; `nil` keeps the funnel's.
    ///   - dismissible: whether a swipe closes it; `nil` keeps the funnel's.
    ///   - closeOnPurchase: whether a purchase closes it; `nil` keeps the funnel's.
    public init(
        style: FunnelPresentationStyle? = nil,
        enter: FunnelPresentationEnter? = nil,
        detents: [FunnelSheetDetent]? = nil,
        dismissible: Bool? = nil,
        closeOnPurchase: Bool? = nil
    ) {
        self.style = style
        self.enter = enter
        self.detents = detents
        self.dismissible = dismissible
        self.closeOnPurchase = closeOnPurchase
    }

    var ffi: CoreFunnelPresentationOverride {
        CoreFunnelPresentationOverride(
            style: style?.rawValue, enter: enter?.rawValue, detents: detents?.map(\.rawValue),
            dismissible: dismissible, closeOnPurchase: closeOnPurchase)
    }
}

/// What a presented funnel hands back to the host. Every handler is
/// optional: with none, the SDK performs purchases and restores itself and
/// opens URLs with the system.
public struct FunnelPresentHandlers {
    /// Perform the purchase of this package yourself and return whether it
    /// went through. While it runs the funnel cannot be swiped away; on
    /// `true` the SDK refreshes entitlements once (for the result's
    /// `customerInfo`) and applies `closeOnPurchase` as if it had bought.
    public var onPurchase: ((String) async -> Bool)?
    /// Perform a restore yourself and return whether it restored anything.
    public var onRestore: (() async -> Bool)?
    /// Observe a failed purchase or restore the SDK performed. The funnel
    /// stays open; a cancelled store sheet is not reported, and neither is
    /// a failure of your own `onPurchase` / `onRestore`.
    public var onPurchaseError: ((RovenueError) -> Void)?
    /// A URL the funnel opens; without it, an http(s) URL opens in the
    /// system browser.
    public var onUrl: ((String) -> Void)?
    /// A custom action the funnel runs: its id and its params as JSON.
    public var onCustomAction: ((String, String) -> Void)?

    /// - Parameters:
    ///   - onPurchase: perform purchases yourself; `nil` lets the SDK.
    ///   - onRestore: perform restores yourself; `nil` lets the SDK.
    ///   - onPurchaseError: observe the SDK's purchase and restore failures.
    ///   - onUrl: open the funnel's URLs yourself.
    ///   - onCustomAction: hear the funnel's custom actions.
    public init(
        onPurchase: ((String) async -> Bool)? = nil,
        onRestore: (() async -> Bool)? = nil,
        onPurchaseError: ((RovenueError) -> Void)? = nil,
        onUrl: ((String) -> Void)? = nil,
        onCustomAction: ((String, String) -> Void)? = nil
    ) {
        self.onPurchase = onPurchase
        self.onRestore = onRestore
        self.onPurchaseError = onPurchaseError
        self.onUrl = onUrl
        self.onCustomAction = onCustomAction
    }
}

/// How a presentation ended.
public enum FunnelPresentOutcome: String, Sendable {
    /// The funnel finished, or closed after a purchase.
    case completed
    /// The visitor closed it: its close action, a swipe or tap outside.
    case dismissed
    /// Nothing was presented; `FunnelPresentResult.reason` says why.
    case unavailable
}

/// What `presentFunnel` resolves with.
public struct FunnelPresentResult: Sendable, Equatable {
    /// How it ended.
    public let result: FunnelPresentOutcome
    /// Whether a purchase or restore succeeded while it was presented.
    public let purchased: Bool
    /// The entitlements and balances after the purchase; set whenever
    /// `purchased` is true.
    public let customerInfo: PurchaseResult?
    /// The last purchase or restore failure the SDK saw, if any.
    public let lastError: RovenueError?
    /// Why nothing was presented: `alreadyPresented`, `noPresenter`, or the
    /// placement's unavailable reason (`no_placement`, `no_target`, …).
    public let reason: String?

    /// The reason when another funnel is already presented.
    public static let alreadyPresented = "alreadyPresented"
    /// The reason when there was no view controller to present from.
    public static let noPresenter = "noPresenter"

    static func unavailable(_ reason: String, lastError: RovenueError? = nil) -> FunnelPresentResult {
        FunnelPresentResult(result: .unavailable, purchased: false, customerInfo: nil, lastError: lastError, reason: reason)
    }
}

// MARK: - The `fit` detent's measure

/// What a presented sheet's `fit` detent measures: the first page's body,
/// pinned header and footer (screen-pinned blocks are not part of it).
/// Told by the screen as it lays out; it reports the sum when it changes.
final class FunnelFitMeasure {
    private var bodyHeight: CGFloat = 0
    private var headerHeight: CGFloat = 0
    private var footerHeight: CGFloat = 0
    private var reported: CGFloat = 0
    /// Hears the total, on the main queue, once per change.
    var onChange: ((CGFloat) -> Void)?

    private static let tolerance: CGFloat = 0.5

    func body(_ height: CGFloat) { set(\.bodyHeight, height) }
    func header(_ height: CGFloat) { set(\.headerHeight, height) }
    func footer(_ height: CGFloat) { set(\.footerHeight, height) }

    var total: CGFloat { bodyHeight + headerHeight + footerHeight }

    private func set(_ key: ReferenceWritableKeyPath<FunnelFitMeasure, CGFloat>, _ value: CGFloat) {
        guard value.isFinite, abs(self[keyPath: key] - value) > Self.tolerance else { return }
        self[keyPath: key] = value
        let total = self.total
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(total - self.reported) > Self.tolerance else { return }
            self.reported = total
            self.onChange?(total)
        }
    }
}

private struct FunnelFitMeasureKey: EnvironmentKey {
    static let defaultValue: FunnelFitMeasure? = nil
}

extension EnvironmentValues {
    /// Set inside a presented sheet with a `fit` detent.
    var funnelFitMeasure: FunnelFitMeasure? {
        get { self[FunnelFitMeasureKey.self] }
        set { self[FunnelFitMeasureKey.self] = newValue }
    }
}

extension View {
    /// Reports this view's height to `report`, when there is one.
    @ViewBuilder
    func funnelReportsHeight(_ report: ((CGFloat) -> Void)?) -> some View {
        if let report {
            self.background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { report(proxy.size.height) }
                        .onChange(of: proxy.size.height) { report($0) }
                })
        } else {
            self
        }
    }
}
