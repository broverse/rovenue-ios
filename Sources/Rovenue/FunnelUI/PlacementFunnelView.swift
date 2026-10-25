//  PlacementFunnelView.swift — `RovenueFunnelView(placementId:)`: resolves
//  the placement, reports the lifecycle events, and keeps a DRAFT live
//  (spec 2026-10-17 §3.5, §3.5a).
//
//  A debug build on a Sandbox key is served each native funnel's latest
//  draft (D1). While one is on screen and the app is in the foreground, the
//  view asks for the placement again every `DRAFT_REFRESH_INTERVAL` with the
//  ETag it last saw (`refresh_open_draft`): a 304 changes nothing; a changed
//  draft rebuilds the session and replays the visitor's inputs onto it, so
//  the screen they are on stays when it still exists (FM7); a draft that can
//  no longer be served shows its issues and keeps refreshing (FM6); a draft
//  that is gone clears the view and stops (Review Focus 3). Off screen or in
//  the background nothing is requested (FM8).

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// How often a draft on screen asks for the placement again, in seconds
/// (spec §3.4).
let DRAFT_REFRESH_INTERVAL: TimeInterval = 15
private let nanosecondsPerSecond: TimeInterval = 1_000_000_000

struct PlacementFunnelView: View {
    let placementId: String
    let locale: String?
    let handlers: FunnelHostHandlers

    @StateObject private var model = PlacementFunnelModel()

    var body: some View {
        ZStack {
            switch model.phase {
            case .empty:
                Color.clear
            case .funnel(let driver, let generation):
                // A new identity per rebuild: the new session's controls
                // start from its own answers, not the old one's state.
                FunnelDriverView(driver: driver).id(generation)
            case .issues(let issues):
                DraftIssuesView(issues: issues)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.showsDraftBadge { DraftBadge() }
        }
        // Resolved once per placement + locale — not per appearance, so a
        // screen pushed over the funnel and popped again does not restart
        // it. A new placement or locale resolves again.
        .onAppear {
            model.handlers = handlers
            model.request(PlacementKey(placementId: placementId, locale: locale))
            model.setOnScreen(true)
        }
        .onChange(of: PlacementKey(placementId: placementId, locale: locale)) { key in
            model.handlers = handlers
            model.request(key)
        }
        .onDisappear { model.setOnScreen(false) }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            model.setForeground(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            model.setForeground(false)
        }
        #endif
    }
}

/// What a resolve is keyed by.
struct PlacementKey: Equatable {
    let placementId: String
    let locale: String?
}

/// The "Draft" badge: SDK chrome, never part of the document (C6), so a
/// developer never mistakes the draft for the published funnel.
private struct DraftBadge: View {
    var body: some View {
        Text(DraftBadgeCopy.text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, DraftBadgeMetrics.horizontalPadding)
            .padding(.vertical, DraftBadgeMetrics.verticalPadding)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(DraftBadgeMetrics.inset)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DraftBadgeCopy.accessibilityLabel)
            .accessibilityIdentifier(DraftBadgeCopy.accessibilityIdentifier)
    }
}

private enum DraftBadgeCopy {
    static let text = "Draft"
    static let accessibilityLabel = "Draft preview"
    static let accessibilityIdentifier = "rovenue-draft-badge"
}

private enum DraftBadgeMetrics {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 3
    static let inset: CGFloat = 8
}

@MainActor
final class PlacementFunnelModel: ObservableObject {
    enum Phase {
        /// Nothing to draw: loading, unavailable, failed or gone.
        case empty
        case funnel(FunnelDriver, generation: Int)
        /// A draft that cannot be served, and why.
        case issues([DraftIssue])
    }

    @Published private(set) var phase: Phase = .empty {
        didSet {
            if case .funnel(let driver, _) = phase { onScreenDriver.driver = driver } else { onScreenDriver.driver = nil }
        }
    }
    /// The driver on screen, readable from `deinit` (which is not on the
    /// main actor).
    private let onScreenDriver = DriverHolder()
    /// A draft is what is (or would be) on screen.
    @Published private(set) var showsDraftBadge = false

    var handlers = FunnelHostHandlers()

    private var placementId = ""
    private var locale: String?
    /// The placement + locale requested last, and its resolve.
    private var requested: PlacementKey?
    private var loadTask: Task<Void, Never>?
    /// Bumped per resolve: a slower earlier resolve or refresh never lands
    /// over a newer one.
    private var loadSerial = 0
    private var generation = 0

    // The live refresh — only for a draft.
    private var isDraft = false
    private var etag: String?
    private var recorder: RecordingFunnelSession?
    private var onScreen = false
    private var foreground = true
    private var refreshTask: Task<Void, Never>?
    // StoreKit prices for the draft's packages, by package identifier, and
    // the product ids they were looked up for.
    private var storePrices: [String: FunnelPackagePrice] = [:]
    private var storeLookupIds: Set<String>?

    init() {
        #if os(iOS)
        foreground = UIApplication.shared.applicationState == .active
        #endif
    }

    deinit {
        refreshTask?.cancel()
        loadTask?.cancel()
        // The host took the view away: the presentation ends here, as a
        // host's own `close()` would end it.
        if let driver = onScreenDriver.driver { retire(driver) }
    }

    // MARK: - Resolving

    /// Resolves `key` unless it is already what was asked for.
    func request(_ key: PlacementKey) {
        guard key != requested else { return }
        requested = key
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.load(placementId: key.placementId, locale: key.locale)
        }
    }

    private func load(placementId: String, locale: String?) async {
        loadSerial += 1
        let serial = loadSerial
        self.placementId = placementId
        self.locale = locale
        stopRefreshing()
        // FM13: whatever was on screen goes before the next resolve lands.
        clear()
        guard #available(iOS 15.0, macOS 12.0, *) else { return }
        do {
            let resolution = try await Rovenue.shared.getFunnel(placementId: placementId, locale: locale)
            // A resolve superseded by a newer one (or a disappeared view)
            // reports nothing (FM14).
            guard !Task.isCancelled, serial == loadSerial else { return }
            switch resolution {
            case .funnel(let resolved):
                show(resolved)
            case .unavailable(let unavailable):
                unavailableArrived(unavailable)
            }
        } catch {
            guard !Task.isCancelled, serial == loadSerial else { return }
            clear()
            handlers.onError?(rovenueError(error))
        }
    }

    private func show(_ resolved: ResolvedFunnel) {
        isDraft = resolved.isDraft
        showsDraftBadge = resolved.isDraft
        etag = resolved.draftEtag
        let loaded = FunnelLoaded(
            placementId: placementId,
            funnelId: resolved.funnelId,
            revision: resolved.revision,
            variantId: resolved.variantId,
            experimentKey: resolved.experimentKey,
            servedFromFallback: resolved.servedFromFallback,
            isDraft: resolved.isDraft
        )
        if resolved.isDraft {
            let recording = RecordingFunnelSession(resolved.session)
            recorder = recording
            mount(recording, loaded: loaded, contentLocale: resolved.contentLocale)
        } else {
            mount(resolved.session, loaded: loaded, contentLocale: resolved.contentLocale)
        }
        updateRefreshing()
    }

    private func mount(_ session: FunnelSessionDriving, loaded: FunnelLoaded, contentLocale: String?) {
        if case .funnel(let previous, _) = phase { retire(previous) }
        let driver = FunnelDriver(session: session, handlers: handlers)
        driver.layoutDirection = contentLocale.map(FunnelTextDirection.layoutDirection(of:))
        let onLoaded = handlers.onLoaded
        driver.onFirstPresented = { onLoaded?(loaded) }
        generation += 1
        phase = .funnel(driver, generation: generation)
    }

    private func unavailableArrived(_ unavailable: FunnelUnavailable) {
        clear()
        if unavailable.reason == .draftIssues {
            // Only a draft has issues: keep asking, the next edit may fix it.
            isDraft = true
            showsDraftBadge = true
            phase = .issues(unavailable.issues)
            updateRefreshing()
        }
        handlers.onUnavailable?(unavailable)
    }

    /// Back to nothing on screen, refresh state included.
    private func clear() {
        if case .funnel(let driver, _) = phase { retire(driver) }
        phase = .empty
        showsDraftBadge = false
        isDraft = false
        etag = nil
        recorder = nil
    }

    // MARK: - The live refresh

    func setOnScreen(_ value: Bool) {
        onScreen = value
        updateRefreshing()
    }

    func setForeground(_ value: Bool) {
        foreground = value
        updateRefreshing()
    }

    /// Refreshes exactly while a draft is on screen in a foreground app.
    private func updateRefreshing() {
        let wanted = isDraft && onScreen && foreground
        if !wanted {
            stopRefreshing()
        } else if refreshTask == nil {
            let serial = loadSerial
            let interval = UInt64(DRAFT_REFRESH_INTERVAL * nanosecondsPerSecond)
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: interval)
                    guard !Task.isCancelled, let self else { return }
                    await self.refreshOnce(serial: serial)
                }
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refreshOnce(serial: Int) async {
        guard #available(iOS 15.0, macOS 12.0, *) else { return }
        let next: DraftRefresh
        do {
            next = try await Rovenue.shared.refreshOpenDraft(placementId: placementId, etag: etag)
        } catch {
            // A network failure is dropped: the next tick tries again.
            return
        }
        guard !Task.isCancelled, serial == loadSerial, isDraft else { return }
        switch next {
        case .notModified:
            return
        case .changed(let funnelJson, let nextEtag):
            etag = nextEtag
            rebuild(funnelJson)
        case .blocked(let issues, let nextEtag):
            etag = nextEtag
            // The recorded inputs stay: once the draft is fixed, the next
            // document can still bring the visitor back to their screen.
            if case .funnel(let driver, _) = phase { retire(driver) }
            if case .issues(let shown) = phase, shown == issues { return }
            phase = .issues(issues)
            handlers.onUnavailable?(FunnelUnavailable(placementId: placementId, reason: .draftIssues, issues: issues))
        case .gone:
            clear()
            stopRefreshing()
            handlers.onUnavailable?(FunnelUnavailable(placementId: placementId, reason: .noTarget, issues: []))
        }
    }

    /// A changed draft: a new session, brought to the screen the visitor
    /// is on when the edited draft still has it (FM7).
    private func rebuild(_ funnelJson: String) {
        let target = recorder?.screenId
        let inputs = recorder?.inputs ?? []
        do {
            var next = RecordingFunnelSession(try openDraft(funnelJson))
            if target != nil, !inputs.isEmpty {
                let replayed = RecordingFunnelSession.replaying(inputs, onto: try openDraft(funnelJson))
                if replayed.screenId == target { next = replayed }
            }
            recorder = next
            showsDraftBadge = true
            mount(
                next, loaded: draftLoaded(funnelJson),
                contentLocale: FunnelTextDirection.contentLocale(
                    configJson: funnelJson, requested: locale ?? Locale.current.identifier))
        } catch {
            clear()
            stopRefreshing()
            handlers.onError?(rovenueError(error))
        }
        lookUpStorePrices(funnelJson)
    }

    /// A non-emitting session on the draft, priced with what is known.
    private func openDraft(_ funnelJson: String) throws -> FunnelSession {
        let session = try Rovenue.previewFunnel(payload: funnelJson, locale: locale ?? Locale.current.identifier)
        let prices = DraftPayload.decode(funnelJson)?.packages.compactMap { storePrices[$0.packageIdentifier] } ?? []
        if !prices.isEmpty { _ = session.setPackagePrices(prices: prices) }
        return session
    }

    private func draftLoaded(_ funnelJson: String) -> FunnelLoaded {
        let payload = DraftPayload.decode(funnelJson)
        return FunnelLoaded(
            placementId: placementId,
            funnelId: payload?.id ?? "",
            revision: payload?.revision ?? 0,
            variantId: nil,
            experimentKey: nil,
            servedFromFallback: false,
            isDraft: true
        )
    }

    /// StoreKit's prices for the draft's products, looked up once per
    /// product set; when the store knows any, the session is rebuilt in
    /// place with them.
    private func lookUpStorePrices(_ funnelJson: String) {
        guard #available(iOS 15.0, macOS 12.0, *) else { return }
        let packages = DraftPayload.decode(funnelJson)?.packages ?? []
        let ids = Set(packages.compactMap(\.storeIds.apple))
        guard ids != storeLookupIds else { return }
        storeLookupIds = ids
        guard !ids.isEmpty else { return }
        let serial = loadSerial
        Task { [weak self] in
            guard let products = await storeProducts(Array(ids), within: storePriceTimeoutNanoseconds) else { return }
            var prices: [String: FunnelPackagePrice] = [:]
            for pkg in packages {
                guard let product = pkg.storeIds.apple.flatMap({ products[$0] }) else { continue }
                let eligible = await product.subscription?.isEligibleForIntroOffer ?? false
                prices[pkg.packageIdentifier] = funnelPackagePrice(identifier: pkg.packageIdentifier, product: product, eligible: eligible)
            }
            guard let self, serial == self.loadSerial, self.storeLookupIds == ids, !prices.isEmpty else { return }
            self.storePrices = prices
            self.rebuild(funnelJson)
        }
    }

    private func rovenueError(_ error: Error) -> RovenueError {
        (error as? RovenueError) ?? RovenueError(kind: .internal, message: error.localizedDescription)
    }
}

/// Holds the on-screen driver for `PlacementFunnelModel.deinit`.
private final class DriverHolder {
    var driver: FunnelDriver?
}

/// A funnel leaving the view: closed (its dismissal recorded once, its
/// clock stopped) unless it already ended on its own — a completed funnel
/// was not dismissed.
private func retire(_ driver: FunnelDriver) {
    if !driver.finished { driver.close() }
}

/// The parts of a draft payload (the object `/v1/placements` serves under
/// `funnel`) the view reads itself: its ids for `onLoaded`, and its
/// offering's packages for StoreKit prices.
private struct DraftPayload: Decodable {
    struct Offering: Decodable {
        let packages: [Package]
    }

    struct Package: Decodable {
        struct StoreIds: Decodable {
            let apple: String?
        }

        let packageIdentifier: String
        let storeIds: StoreIds
    }

    let id: String?
    let revision: Int64?
    let offering: Offering?

    var packages: [Package] { offering?.packages ?? [] }

    static func decode(_ json: String) -> DraftPayload? {
        try? JSONDecoder().decode(DraftPayload.self, from: Data(json.utf8))
    }
}
