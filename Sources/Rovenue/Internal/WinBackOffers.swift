//  WinBackOffers.swift — StoreKit win-back offers (iOS 18 / macOS 15+).
//
//  A win-back offer is a discount Apple lets a LAPSED subscriber redeem. Two
//  StoreKit answers matter:
//    * the catalog — `Product.SubscriptionInfo.winBackOffers`, every win-back
//      offer configured for the subscription (mapped into
//      `StoreProduct.discounts` as `.winBack`, see ProductMapping);
//    * eligibility — `RenewalInfo.eligibleWinBackOfferIDs` of the group's
//      subscription statuses, ordered best offer first by Apple.
//  Redeeming one is `Product.PurchaseOption.winBackOffer(_:)` with the
//  catalog's `Product.SubscriptionOffer`: no signature, no server call.
//
//  The pure rules live here so `swift test` can pin them; the StoreKit
//  readers are build-verified and exercised by the example app's StoreKit
//  Testing suite.

import Foundation
import StoreKit

/// The product's `.winBack` discounts whose ids are in `eligibleOfferIds`,
/// in `eligibleOfferIds`' order (Apple's: best first), each once. Ids of
/// other products of the group, and non-win-back discounts that share an
/// id, are skipped.
func eligibleWinBackDiscounts(_ discounts: [Discount], eligibleOfferIds: [String]) -> [Discount] {
    var byId: [String: Discount] = [:]
    for discount in discounts where discount.type == .winBack {
        if let id = discount.identifier, byId[id] == nil { byId[id] = discount }
    }
    var seen = Set<String>()
    return eligibleOfferIds.compactMap { id in
        guard seen.insert(id).inserted else { return nil }
        return byId[id]
    }
}

/// The eligible ids of every subscription status of the group (one per
/// Family Sharing source), first-seen order kept, each once.
func unitedWinBackOfferIds(_ perStatus: [[String]]) -> [String] {
    var seen = Set<String>()
    return perStatus.flatMap { $0 }.filter { seen.insert($0).inserted }
}

/// The offer id `purchase(_:winBackOffer:)` redeems: a `.winBack` discount
/// with an identifier, else `.ineligible` (`WIN_BACK_OFFER_UNAVAILABLE`).
func resolveWinBackOfferId(_ offer: Discount) throws -> String {
    guard offer.type == .winBack else {
        throw RovenueError.winBackOfferUnavailable("the discount is a \(offer.type) offer, not a win-back offer")
    }
    guard let id = offer.identifier, !id.isEmpty else {
        throw RovenueError.winBackOfferUnavailable("the discount has no identifier")
    }
    return id
}

/// Which purchase path an App Store purchase intent's offer takes.
enum PurchaseIntentOffer: Equatable {
    /// No offer, an introductory one (StoreKit applies it by itself), or one
    /// without an id: a plain purchase.
    case none
    case promotional(String)
    case winBack(String)
}

func purchaseIntentOffer(type: DiscountType?, id: String?) -> PurchaseIntentOffer {
    guard let type, let id, !id.isEmpty else { return .none }
    switch type {
    case .introductory: return .none
    case .promotional: return .promotional(id)
    case .winBack: return .winBack(id)
    }
}

/// The win-back offer ids StoreKit says this customer may redeem in the
/// product's subscription group, best first; nil when StoreKit cannot
/// answer (before iOS 18 / macOS 15, an SDK built without the API, a
/// non-subscription, a status lookup that threw). Unverified renewal info
/// is ignored.
@available(iOS 15.0, macOS 12.0, *)
func storeKitEligibleWinBackOfferIds(_ product: Product) async -> [String]? {
    #if compiler(>=6.0)
    if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *),
       let subscription = product.subscription,
       let statuses = try? await subscription.status {
        let perStatus: [[String]] = statuses.compactMap { status in
            guard case let .verified(renewal) = status.renewalInfo else { return nil }
            return renewal.eligibleWinBackOfferIDs
        }
        return unitedWinBackOfferIds(perStatus)
    }
    #endif
    return nil
}
