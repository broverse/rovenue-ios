//  FunnelPendingLanding.swift — when a deferred funnel purchase has landed
//  (spec 2026-11-22-funnel-purchase-pending).
//
//  The SDK's own recovery — `AppleTransactionRecovery`'s retries, the
//  `Transaction.updates` listener that delivers an approved Ask to Buy,
//  the `unfinished` scan — ends in a receipt POST that hydrates the caches
//  and emits `.entitlementsChanged` / `.virtualCurrenciesChanged`. Those
//  events also fire for an unchanged refresh, so the presenter needs
//  evidence that THIS purchase landed:
//
//  - an active entitlement for the product that was not active before the
//    purchase began;
//  - for a one-time product, a virtual-currency balance above where it was
//    before the purchase began (a consumable sells credits).

import Foundation

/// The caches as they were before the funnel's purchase began.
struct FunnelPendingBaseline: Sendable {
    let activeProducts: Set<String>
    let balances: [String: Int64]

    init(entitlements: [Entitlement], balances: [String: Int64]) {
        activeProducts = Set(entitlements.filter(\.isActive).map(\.productIdentifier))
        self.balances = balances
    }
}

enum FunnelPendingLanding {
    /// The `productType`s of a one-time package (`CoreOfferingPackage`);
    /// anything else reads as a subscription, as `ProductType` does.
    static let oneTimeTypes: Set<String> = ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]

    /// Whether the purchase of `productId` has landed since `baseline`.
    static func landed(
        baseline: FunnelPendingBaseline, entitlements: [Entitlement], balances: [String: Int64],
        productId: String, productType: String
    ) -> Bool {
        let granted = entitlements.contains {
            $0.isActive && $0.productIdentifier == productId && !baseline.activeProducts.contains(productId)
        }
        if granted { return true }
        guard oneTimeTypes.contains(productType) else { return false }
        return balances.contains { code, value in value > (baseline.balances[code] ?? 0) }
    }
}
