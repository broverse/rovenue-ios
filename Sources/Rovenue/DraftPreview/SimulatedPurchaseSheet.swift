//  SimulatedPurchaseSheet.swift — the preview's stand-in for the App Store
//  sheet (spec 2026-10-16 §3.4, C4: one copy, owned by the SDK; the
//  operator app and the SDK's own draft-preview presenter both show it).
//
//  It never touches StoreKit (FM10): it only reports which ending the
//  person chose, and the caller continues the funnel the way the real
//  result would — Success ends it (the subscriber is now entitled),
//  Failure says so and stays, Cancel stays silently.

#if os(iOS)
import SwiftUI

/// A purchase or restore a funnel preview asked for, shown by
/// ``SimulatedPurchaseSheet`` instead of the App Store sheet.
public struct SimulatedPurchaseRequest: Identifiable, Equatable {
    /// What the funnel asked for.
    public enum Kind: Equatable {
        /// A `purchase` action for the package with this identifier
        /// (the offering slot, e.g. `$rov_monthly`).
        case purchase(packageId: String)
        /// A `restore_purchases` action.
        case restore
    }

    /// Unique per request, so a repeat of the same purchase is a new sheet.
    public let id = UUID()
    /// What the funnel asked for.
    public let kind: Kind
    /// The package's display name, shown under the title; nil for a restore.
    public let packageName: String?
    /// The price line under the package name — the store's price, or
    /// ``SimulatedPurchaseSheet/storePricePlaceholder`` when the store
    /// returned none; nil shows no price line.
    public let priceText: String?

    /// - Parameters:
    ///   - kind: what the funnel asked for.
    ///   - packageName: the package's display name; nil for a restore.
    ///   - priceText: the price line to show, or nil for none.
    public init(kind: Kind, packageName: String? = nil, priceText: String? = nil) {
        self.kind = kind
        self.packageName = packageName
        self.priceText = priceText
    }
}

/// How the person chose to end a simulated purchase or restore.
public enum SimulatedPurchaseResult: Sendable {
    /// It went through: the subscriber is entitled, so the host ends the funnel.
    case success
    /// The store refused: the host says so and the funnel stays where it was.
    case failure
    /// The person backed out: the funnel stays where it was, silently.
    case cancel
}

/// The simulated App Store sheet: no store request and no charge — the
/// person picks how the purchase ends. Present it in a `.sheet` when a
/// preview's `FunnelHostHandlers.onPurchase` / `onRestore` fires, and treat
/// a swipe-down as ``SimulatedPurchaseResult/cancel``.
public struct SimulatedPurchaseSheet: View {
    /// The price line shown when the store returned no price for the
    /// package — the usual case on a simulator without a StoreKit
    /// configuration.
    public static let storePricePlaceholder = "Price from App Store"

    private let request: SimulatedPurchaseRequest
    private let onResult: (SimulatedPurchaseResult) -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = Metrics.glyphSize

    /// - Parameters:
    ///   - request: what the funnel asked for.
    ///   - onResult: the chosen ending; called once, from a button tap.
    public init(request: SimulatedPurchaseRequest, onResult: @escaping (SimulatedPurchaseResult) -> Void) {
        self.request = request
        self.onResult = onResult
    }

    /// The sheet's content: what is being bought, then the three endings.
    public var body: some View {
        VStack(spacing: Metrics.sectionGap) {
            header
            Spacer(minLength: 0)
            actions
        }
        .padding(Metrics.padding)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var isRestore: Bool { request.kind == .restore }

    private var header: some View {
        VStack(spacing: Metrics.lineGap) {
            Image(systemName: isRestore ? "arrow.clockwise.circle.fill" : "cart.circle.fill")
                .font(.system(size: glyphSize))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(isRestore ? Copy.restoreTitle : Copy.purchaseTitle)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            if let name = request.packageName, !isRestore {
                Text(name).font(.headline)
                if let price = request.priceText {
                    Text(price)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(Copy.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var actions: some View {
        VStack(spacing: Metrics.buttonGap) {
            Button {
                onResult(.success)
            } label: {
                Label(Copy.success, systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(isRestore ? Copy.restoreSuccessHint : Copy.purchaseSuccessHint)

            Button(role: .destructive) {
                onResult(.failure)
            } label: {
                Label(Copy.failure, systemImage: "exclamationmark.triangle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(Copy.failureHint)

            Button(Copy.cancel) {
                onResult(.cancel)
            }
            .frame(maxWidth: .infinity)
            .accessibilityHint(Copy.cancelHint)
        }
        .controlSize(.large)
    }

    private enum Metrics {
        static let glyphSize: CGFloat = 44
        static let sectionGap: CGFloat = 24
        static let lineGap: CGFloat = 6
        static let buttonGap: CGFloat = 12
        static let padding: CGFloat = 24
    }

    private enum Copy {
        static let purchaseTitle = "Simulated Purchase"
        static let restoreTitle = "Simulated Restore"
        static let explanation = "No App Store sheet and no charge. Choose how it ends."
        static let success = "Success"
        static let failure = "Failure"
        static let cancel = "Cancel"
        static let purchaseSuccessHint = "Completes the purchase and ends the funnel"
        static let restoreSuccessHint = "Restores and ends the funnel"
        static let failureHint = "Shows an error and stays on this screen"
        static let cancelHint = "Closes without buying and stays on this screen"
    }
}
#endif
