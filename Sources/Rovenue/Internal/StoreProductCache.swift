//  StoreProductCache.swift — the StoreKit half of `getOfferings`, cached.
//
//  The core answers `getOfferings` from its own per-subscriber cache, so the
//  latency left on the façade is StoreKit: `Product.products(for:)` and a
//  per-product `isEligibleForIntroOffer`. This actor keeps both for
//  `freshness` (5 minutes):
//
//  - a product younger than that is served with no StoreKit call;
//  - an older one is served at once and refreshed in the background, at most
//    one refresh in flight per product id;
//  - a missing one is fetched, and a concurrent caller waiting on the same id
//    joins that fetch instead of starting another;
//  - an id StoreKit answered without (a misconfigured product) is remembered
//    as absent for the same 5 minutes; a failed lookup is never cached.
//
//  Eligibility — intro (`isEligibleForIntroOffer`) and win-back (the
//  renewal info's `eligibleWinBackOfferIDs`) — is cached per product and
//  dropped on purchase / restore /
//  renewal (`dropEligibility`); identify and logOut drop everything
//  (`dropAll`). An eligibility read that started before a drop never writes
//  its answer back (generation check). Products carry no generation, so a
//  product fetch running across `dropAll` may still store its answer; that is
//  harmless, as products are not per-subscriber.

import Foundation
import StoreKit

internal actor StoreProductCache {
    /// Freshness for products and eligibility: 5 minutes, as the core's
    /// offerings cache.
    static let freshness: TimeInterval = 300
    /// A fetch still running after this long is no longer joined: StoreKit
    /// requests can hang, and one must not pin an id for good.
    static let fetchGiveUp: TimeInterval = 30

    typealias Loader = @Sendable ([String]) async throws -> [Product]

    /// `product == nil`: StoreKit answered the lookup without this id.
    private struct ProductEntry {
        let product: Product?
        let fetchedAt: Date
    }

    private struct Fetch {
        let id: Int
        let task: Task<Void, Never>
        let startedAt: Date
    }

    private struct EligibilityEntry {
        let isEligible: Bool
        let readAt: Date
    }

    private let load: Loader
    private let now: @Sendable () -> Date
    private var products: [String: ProductEntry] = [:]
    private var eligibility: [String: EligibilityEntry] = [:]
    private var winBackEligibility: [String: (ids: [String], readAt: Date)] = [:]
    /// The fetch currently loading each id; one task may cover several ids.
    private var inFlight: [String: Fetch] = [:]
    private var nextFetchId = 0
    /// Bumped by every eligibility drop, so a read begun before a purchase
    /// cannot store its pre-purchase answer after it.
    private var eligibilityGeneration = 0

    init(
        load: @escaping Loader = { try await Product.products(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.load = load
        self.now = now
    }

    /// The StoreKit products for `ids` that StoreKit knows, keyed by id.
    /// Waits on StoreKit only for ids never loaded (or dropped); stale ones
    /// are returned as they are and refreshed in the background.
    func products(for ids: [String]) async -> [String: Product] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [:] }
        let at = now()
        let missing = wanted.filter { products[$0] == nil }
        let stale = wanted.filter { id in
            products[id].map { at.timeIntervalSince($0.fetchedAt) >= Self.freshness } ?? false
        }
        let staleIdle = stale.filter { liveFetch($0, at: at) == nil }
        if !staleIdle.isEmpty {
            startFetch(staleIdle, at: at)  // background: not awaited
        }
        if !missing.isEmpty {
            var waits = Set(missing.compactMap { liveFetch($0, at: at)?.task })
            let unclaimed = missing.filter { liveFetch($0, at: at) == nil }
            if !unclaimed.isEmpty {
                waits.insert(startFetch(unclaimed, at: at))
            }
            for task in waits { await task.value }
        }
        var out: [String: Product] = [:]
        for id in wanted {
            if let product = products[id]?.product { out[id] = product }
        }
        return out
    }

    /// `isEligibleForIntroOffer` for a subscription product (nil for any
    /// other product), cached per product id.
    func isEligibleForIntroOffer(_ product: Product) async -> Bool? {
        guard let subscription = product.subscription else { return nil }
        if let cached = eligibility[product.id], now().timeIntervalSince(cached.readAt) < Self.freshness {
            return cached.isEligible
        }
        let generation = eligibilityGeneration
        let isEligible = await subscription.isEligibleForIntroOffer
        if generation == eligibilityGeneration {
            eligibility[product.id] = EligibilityEntry(isEligible: isEligible, readAt: now())
        }
        return isEligible
    }

    /// The win-back offer ids the customer may redeem for `productId`'s
    /// subscription group, best first, cached per product id. `read` asks
    /// StoreKit and answers nil when it cannot (no status, unverified
    /// renewal info): that reads as none eligible and is not cached.
    func eligibleWinBackOfferIds(productId: String, read: @Sendable () async -> [String]?) async -> [String] {
        if let cached = winBackEligibility[productId], now().timeIntervalSince(cached.readAt) < Self.freshness {
            return cached.ids
        }
        let generation = eligibilityGeneration
        guard let ids = await read() else { return [] }
        if generation == eligibilityGeneration {
            winBackEligibility[productId] = (ids, now())
        }
        return ids
    }

    /// A purchase, restore or renewal may have used an intro or win-back
    /// offer (or ended the lapse that made one redeemable).
    func dropEligibility() {
        eligibility.removeAll()
        winBackEligibility.removeAll()
        eligibilityGeneration += 1
    }

    /// The subscriber changed (identify / logOut). A product fetch already in
    /// flight still lands: a product is not the subscriber's, and its
    /// answer is newer than the drop's start.
    func dropAll() {
        products.removeAll()
        dropEligibility()
    }

    private func liveFetch(_ id: String, at: Date) -> Fetch? {
        guard let fetch = inFlight[id], at.timeIntervalSince(fetch.startedAt) < Self.fetchGiveUp else { return nil }
        return fetch
    }

    @discardableResult
    private func startFetch(_ ids: Set<String>, at: Date) -> Task<Void, Never> {
        nextFetchId += 1
        let fetchId = nextFetchId
        let task = Task { [load] in
            let loaded = try? await load(Array(ids))
            self.finishFetch(ids, fetchId: fetchId, loaded: loaded)
        }
        for id in ids { inFlight[id] = Fetch(id: fetchId, task: task, startedAt: at) }
        return task
    }

    private func finishFetch(_ ids: Set<String>, fetchId: Int, loaded: [Product]?) {
        for id in ids where inFlight[id]?.id == fetchId { inFlight[id] = nil }
        // A thrown lookup, or an empty answer for a non-empty request (what
        // StoreKit returns offline at times), is a failure: keep what is
        // cached and record nothing as absent.
        guard let loaded, !loaded.isEmpty else { return }
        let byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let at = now()
        for id in ids {
            products[id] = ProductEntry(product: byId[id], fetchedAt: at)
        }
    }
}
