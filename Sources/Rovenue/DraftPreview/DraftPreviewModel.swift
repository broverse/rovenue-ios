//  DraftPreviewModel.swift — one open draft preview: the document the core
//  last reported, the non-emitting session drawn from it, and the simulated
//  purchases (spec 2026-10-16 §3.4).
//
//  A new document rebuilds the session (live refresh, G2) and keeps the
//  screen when it still exists (`PreviewReplay.swift`, FM6). A document
//  with no payload is a shape refusal: the "Can't render this draft" list
//  (FM9). Prices come from StoreKit's product lookup — the SDK's normal
//  hydration — with a placeholder until, or unless, the store answers.

#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// One issue the API reported for the draft — what would block a publish.
struct DraftPreviewIssue: Decodable, Identifiable, Equatable {
    let path: String
    let code: String
    let message: String
    let severity: String?
    /// Issues carry no id of their own; what they say is their identity.
    var id: String { "\(path)#\(code)#\(message)" }
}

/// The part of the preview payload (the object `/v1/placements` serves
/// under `funnel`) the presenter reads itself: its offering's packages,
/// for prices and the simulated sheet's package name.
private struct PreviewPayloadOffering: Decodable {
    struct Offering: Decodable {
        let packages: [Package]
    }

    struct Package: Decodable {
        struct StoreIds: Decodable {
            let apple: String?
        }

        let packageIdentifier: String
        let displayName: String
        let storeIds: StoreIds
    }

    let offering: Offering?
}

@MainActor
final class DraftPreviewModel: ObservableObject {
    /// Where the funnel ended; a real app closes it here.
    enum Outcome: Equatable {
        case purchased(String)
        case restored
        case finished
    }

    /// An alert the host would show: the funnel's own `show_alert`, a
    /// custom action, or a simulated failure.
    struct HostAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let button: String
    }

    @Published private(set) var driver: FunnelDriver?
    /// Bumped on every new session: the drawer restarts with this identity.
    @Published private(set) var generation = 0
    @Published private(set) var issues: [DraftPreviewIssue] = []
    /// The draft failed the shape gate (`payload: null`).
    @Published private(set) var cantRender = false
    /// The payload arrived but the SDK could not open it.
    @Published private(set) var buildError: String?
    @Published private(set) var outcome: Outcome?
    /// The session ended server-side; the presenter dismisses shortly.
    @Published private(set) var ended = false
    @Published var purchaseRequest: SimulatedPurchaseRequest?
    @Published var alert: HostAlert?
    @Published var issuesExpanded = false

    private(set) var sessionId = ""
    private(set) var etag = ""
    private(set) var appearance: String?
    private var payload: String?
    private var locale = Locale.current.identifier
    private var recorder: RecordingFunnelSession?
    private var packages: [PreviewPayloadOffering.Package] = []
    /// StoreKit's prices by package identifier, once the store answered.
    private var storePrices: [String: FunnelPackagePrice] = [:]
    /// The product ids the last store lookup was for.
    private var storeLookupIds: Set<String>?

    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var canRestart: Bool { payload != nil && !cantRender }

    /// A document from the core: the first one, or a changed one.
    func update(sessionId: String, payloadJson: String?, issuesJson: String, locale: String?, appearance: String?, etag: String) {
        let newSession = sessionId != self.sessionId
        self.sessionId = sessionId
        self.etag = etag
        self.appearance = appearance
        self.locale = locale ?? Locale.current.identifier
        if newSession {
            recorder = nil
            outcome = nil
            ended = false
        }
        issues = (try? JSONDecoder().decode([DraftPreviewIssue].self, from: Data(issuesJson.utf8))) ?? []
        guard let payloadJson else {
            // Keep the recorded inputs: when the draft is fixed, the next
            // document can still bring the visitor back to their screen.
            cantRender = true
            payload = nil
            closeDriver()
            return
        }
        cantRender = false
        payload = payloadJson
        packages = (try? JSONDecoder().decode(PreviewPayloadOffering.self, from: Data(payloadJson.utf8)))?.offering?.packages ?? []
        rebuild(keepScreen: !newSession)
        loadStorePrices()
    }

    func restart() {
        recorder = nil
        rebuild(keepScreen: false)
    }

    func close() {
        onClose()
    }

    func showEnded() {
        ended = true
        purchaseRequest = nil
    }

    // MARK: - Session

    private func rebuild(keepScreen: Bool) {
        guard let payload else { return }
        let target = keepScreen ? recorder?.screenId : nil
        let inputs = keepScreen ? recorder?.inputs ?? [] : []
        do {
            var next = try RecordingFunnelSession(openSession(payload))
            if let target, !inputs.isEmpty {
                let replayed = RecordingFunnelSession.replaying(inputs, onto: try openSession(payload))
                if replayed.screenId == target { next = replayed }
            }
            closeDriver()
            recorder = next
            outcome = nil
            purchaseRequest = nil
            buildError = nil
            driver = FunnelDriver(session: next, handlers: makeHandlers())
            generation += 1
        } catch {
            closeDriver()
            buildError = (error as? RovenueError)?.message ?? error.localizedDescription
        }
    }

    /// A fresh preview session, priced with what is known so far.
    private func openSession(_ payload: String) throws -> FunnelSession {
        let session = try Rovenue.previewFunnel(payload: payload, locale: locale)
        let prices = packages.compactMap { pkg -> FunnelPackagePrice? in
            if let price = storePrices[pkg.packageIdentifier] { return price }
            guard pkg.storeIds.apple != nil else { return nil }
            return FunnelPackagePrice(
                identifier: pkg.packageIdentifier,
                localizedPrice: SimulatedPurchaseSheet.storePricePlaceholder
            )
        }
        if !prices.isEmpty { _ = session.setPackagePrices(prices: prices) }
        return session
    }

    private func closeDriver() {
        driver?.close()
        driver = nil
    }

    /// StoreKit's prices for the offering's products, looked up once per
    /// product set. When the store knows any of them the session is
    /// rebuilt in place (same screen) with the real prices; on a simulator
    /// without a StoreKit configuration it knows none and the placeholder
    /// stays.
    private func loadStorePrices() {
        let ids = Set(packages.compactMap(\.storeIds.apple))
        guard ids != storeLookupIds else { return }
        storeLookupIds = ids
        guard !ids.isEmpty else { return }
        let packages = self.packages
        Task { [weak self] in
            guard let products = await storeProducts(Array(ids), within: storePriceTimeoutNanoseconds) else { return }
            var prices: [String: FunnelPackagePrice] = [:]
            for pkg in packages {
                guard let product = pkg.storeIds.apple.flatMap({ products[$0] }) else { continue }
                let eligible = await product.subscription?.isEligibleForIntroOffer ?? false
                prices[pkg.packageIdentifier] = funnelPackagePrice(identifier: pkg.packageIdentifier, product: product, eligible: eligible)
            }
            guard let self, self.storeLookupIds == ids, !prices.isEmpty else { return }
            self.storePrices = prices
            self.rebuild(keepScreen: true)
        }
    }

    // MARK: - Host effects

    private func makeHandlers() -> FunnelHostHandlers {
        FunnelHostHandlers(
            onUrl: { [weak self] raw in
                Task { @MainActor in self?.open(raw) }
            },
            onAlert: { [weak self] title, message, button in
                Task { @MainActor in
                    self?.alert = HostAlert(title: title ?? "", message: message, button: button ?? Copy.ok)
                }
            },
            onCustom: { [weak self] actionId, _ in
                Task { @MainActor in
                    self?.alert = HostAlert(title: Copy.customTitle, message: Copy.customMessage(actionId), button: Copy.ok)
                }
            },
            onPurchase: { [weak self] packageId in
                Task { @MainActor in self?.askPurchase(packageId) }
            },
            onRestore: { [weak self] in
                Task { @MainActor in self?.purchaseRequest = SimulatedPurchaseRequest(kind: .restore) }
            },
            onFinished: { [weak self] in
                Task { @MainActor in
                    guard let self, self.outcome == nil else { return }
                    self.outcome = .finished
                }
            }
        )
    }

    private func open(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        if let scheme = url.scheme?.lowercased(), Copy.webSchemes.contains(scheme) {
            UIApplication.shared.open(url)
        } else {
            alert = HostAlert(title: Copy.linkTitle, message: Copy.linkMessage(raw), button: Copy.ok)
        }
    }

    private func askPurchase(_ packageId: String) {
        let pkg = packages.first { $0.packageIdentifier == packageId }
        let price = storePrices[packageId]?.localizedPrice
            ?? (pkg?.storeIds.apple != nil ? SimulatedPurchaseSheet.storePricePlaceholder : nil)
        purchaseRequest = SimulatedPurchaseRequest(
            kind: .purchase(packageId: packageId),
            packageName: pkg?.displayName ?? packageId,
            priceText: price
        )
    }

    /// The simulated sheet's ending, played the way a real result plays: a
    /// purchase is the END of an action chain (the session takes no result
    /// back), so on success the host closes the funnel, on failure it says
    /// so and the visitor stays on the paywall, on cancel nothing happens.
    func resolve(_ request: SimulatedPurchaseRequest, _ result: SimulatedPurchaseResult) {
        purchaseRequest = nil
        switch (request.kind, result) {
        case (.purchase, .success):
            outcome = .purchased(request.packageName ?? "")
        case (.restore, .success):
            outcome = .restored
        case (.purchase, .failure):
            alert = HostAlert(title: Copy.purchaseFailedTitle, message: Copy.purchaseFailedMessage, button: Copy.ok)
        case (.restore, .failure):
            alert = HostAlert(title: Copy.restoreFailedTitle, message: Copy.restoreFailedMessage, button: Copy.ok)
        case (_, .cancel):
            break
        }
    }

    enum Copy {
        static let ok = "OK"
        static let webSchemes: Set<String> = ["http", "https"]
        static let customTitle = "Custom Action"
        static func customMessage(_ id: String) -> String {
            "“\(id)” is handled by your app's own code. The preview does nothing here."
        }
        static let linkTitle = "Link"
        static func linkMessage(_ url: String) -> String { "The funnel opens \(url) here." }
        static let purchaseFailedTitle = "Purchase Failed"
        static let purchaseFailedMessage = "Simulated failure. The funnel stays on the paywall so the visitor can try again."
        static let restoreFailedTitle = "Restore Failed"
        static let restoreFailedMessage = "Simulated failure. Nothing was restored; the funnel stays where it was."
    }
}
#endif
