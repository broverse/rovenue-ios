//  FunnelPackagePrices.swift — store prices for a funnel's package rows (D13).
//
//  Core performs no store I/O, so a funnel session opens with its offering's
//  packages titled (the product's display name) but UNPRICED. This hands the
//  session what StoreKit knows, once, as soon as the products load — the
//  same product lookup `getOfferings` hydrates from (the instance's
//  `productCache`, keyed by `appleProductId`), `displayPrice` as the price,
//  and the SAME `Period` `getOfferings` builds (`appleOfferInputs`) as the
//  period — plus the numeric facts (micros, currency, per-month / per-week
//  strings, the intro offer when eligible) the funnel computes savings and
//  trial copy from. The session forwards them into the funnel machine,
//  which keeps them for every later render.
//
//  A package the store does not know is simply left out: it keeps its
//  display-name title and an empty price, and the row still draws.

import Foundation
import StoreKit

/// `Period` spelled for a person, in the device's language — "1 month",
/// "3 months" — by the platform's own formatter. `getOfferings` exposes the
/// structured `Period`; the funnel row needs its words.
func localizedPeriod(_ period: Period) -> String? {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    var components = DateComponents()
    switch period.unit {
    case .day:
        formatter.allowedUnits = [.day]
        components.day = period.value
    case .week:
        formatter.allowedUnits = [.weekOfMonth]
        components.weekOfMonth = period.value
    case .month:
        formatter.allowedUnits = [.month]
        components.month = period.value
    case .year:
        formatter.allowedUnits = [.year]
        components.year = period.value
    }
    return formatter.string(from: components)
}

/// Micros per currency unit — the scale funnel-core's `amountMicros` is in.
let microsPerCurrencyUnit = Decimal(1_000_000)

/// A StoreKit price as funnel-core's micros, rounded to the nearest micro.
func amountMicros(_ price: Decimal) -> Int64 {
    var scaled = price * microsPerCurrencyUnit
    var rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    return NSDecimalNumber(decimal: rounded).int64Value
}

func funnelPeriodUnit(_ unit: PeriodUnit) -> FunnelPeriodUnit {
    switch unit {
    case .day: return .day
    case .week: return .week
    case .month: return .month
    case .year: return .year
    }
}

func funnelOfferKind(_ mode: PaymentMode) -> FunnelOfferKind {
    switch mode {
    case .freeTrial: return .freeTrial
    case .payAsYouGo: return .payAsYouGo
    case .payUpFront: return .payUpFront
    }
}

/// The introductory offer as funnel-core reads it — its WHOLE duration
/// (`periodValue × periodCount` of its unit, so a 3 × 1-month pay-as-you-go
/// offer is "3 months"), the price only when it is not free. Nil when the
/// visitor is not eligible: the funnel's trial copy then hides itself
/// (spec 2026-10-11-funnel-paywall-blocks §4.0) rather than promising an
/// offer StoreKit will not apply.
func funnelPackageOffer(_ intro: AppleOfferInput?, eligible: Bool) -> FunnelPackageOffer? {
    guard eligible, let intro else { return nil }
    let duration = makePeriod(value: intro.periodValue * max(intro.periodCount, 1), unit: intro.periodUnit)
    guard let words = localizedPeriod(duration) else { return nil }
    return FunnelPackageOffer(
        kind: funnelOfferKind(intro.paymentMode),
        periodUnit: funnelPeriodUnit(duration.unit),
        periodCount: UInt32(duration.value),
        localizedPeriod: words,
        localizedPrice: intro.paymentMode == .freeTrial ? nil : intro.displayPrice
    )
}

/// The win-back offer a funnel may sell this package at: the first of
/// `eligibleIds` (Apple's order, best first) that is one of the product's
/// win-back offers, as funnel-core reads it — its id (what the purchase
/// redeems), kind, whole duration and price (none when free). Nil when the
/// visitor is eligible for none: `product.has_winback` is then false and a
/// `"offer": "win_back"` purchase buys at the regular price.
func funnelWinBackOffer(_ winBacks: [AppleOfferInput], eligibleIds: [String]) -> FunnelPackageOffer? {
    for id in eligibleIds {
        guard let offer = winBacks.first(where: { $0.id == id }) else { continue }
        let duration = makePeriod(value: offer.periodValue * max(offer.periodCount, 1), unit: offer.periodUnit)
        guard let words = localizedPeriod(duration) else { return nil }
        return FunnelPackageOffer(
            kind: funnelOfferKind(offer.paymentMode),
            periodUnit: funnelPeriodUnit(duration.unit),
            periodCount: UInt32(duration.value),
            localizedPeriod: words,
            localizedPrice: offer.paymentMode == .freeTrial ? nil : offer.displayPrice,
            id: id
        )
    }
    return nil
}

// funnel-core-rs `product.rs`'s calendar — the one `{{product.savings_percent}}`
// is computed with and the web's per-month string uses (apps/api
// `services/funnel/offering.ts`): a year is 12 months, 52 weeks, 365 days.
// NOT `getOfferings`' `perUnitPrices`, whose 30-day month put a yearly row's
// "≈ /mo" caption 1.4% under the price the badge was computed from
// ($59.99/yr → "$4.93", not "$5.00"; spec 2026-10-11-funnel-paywall-blocks
// §4.0, found by e2e/live/funnel-paywall-blocks-w5.mjs ios).
let funnelMonthsPerYear = Decimal(12)
let funnelWeeksPerYear = Decimal(52)
let funnelDaysPerYear = Decimal(365)

/// How many months `period` spans on the crate's calendar.
func funnelMonths(in period: Period) -> Decimal {
    let value = Decimal(period.value)
    switch period.unit {
    case .day: return value * funnelMonthsPerYear / funnelDaysPerYear
    case .week: return value * funnelMonthsPerYear / funnelWeeksPerYear
    case .month: return value
    case .year: return value * funnelMonthsPerYear
    }
}

/// The per-month and per-week strings of a recurring price, on the crate's
/// calendar, written by `format` (`funnelPriceFormat`'s style).
func funnelPerUnitStrings(
    price: Decimal, period: Period?, format: (Decimal) -> String
) -> (month: String?, week: String?) {
    guard let period else { return (nil, nil) }
    let months = funnelMonths(in: period)
    guard months > 0 else { return (nil, nil) }
    let perMonth = price / months
    let perWeek = perMonth * funnelMonthsPerYear / funnelWeeksPerYear
    return (format(perMonth), format(perWeek))
}

/// The style every price string of a product is written in: the one that
/// writes its base price as StoreKit's `displayPrice`, byte for byte.
/// `displayPrice` is the storefront's currency in the DEVICE's number format,
/// while `priceFormatStyle` carries the storefront's locale — on a Turkish
/// device with a US storefront the two wrote "$49,99" beside "$0.96" (e2e
/// B2). So the device locale is tried first, the storefront style second,
/// and each is checked against `displayPrice`; nil when neither reproduces
/// it — the caller then writes no per-unit strings and the core shapes them
/// from `displayPrice` itself (funnel-core-rs `product.rs` `per_period`).
@available(iOS 15.0, macOS 12.0, *)
func funnelPriceFormat(
    price: Decimal, displayPrice: String,
    storefront: Decimal.FormatStyle.Currency, deviceLocale: Locale = .current
) -> Decimal.FormatStyle.Currency? {
    [storefront.locale(deviceLocale), storefront].first { price.formatted($0) == displayPrice }
}

/// The per-month and per-week strings of a recurring price, written like
/// its `displayPrice` (`funnelPriceFormat`); none when no style writes the
/// display price.
@available(iOS 15.0, macOS 12.0, *)
func funnelPerUnitPriceStrings(
    price: Decimal, displayPrice: String, period: Period?,
    storefront: Decimal.FormatStyle.Currency, deviceLocale: Locale = .current
) -> (month: String?, week: String?) {
    guard let style = funnelPriceFormat(
        price: price, displayPrice: displayPrice, storefront: storefront, deviceLocale: deviceLocale
    ) else { return (nil, nil) }
    return funnelPerUnitStrings(price: price, period: period) { $0.formatted(style) }
}

/// One package's price facts from its StoreKit product: the display price,
/// the numbers savings are computed from, the per-month / per-week strings
/// on the crate's calendar, written like the display price
/// (`funnelPerUnitPriceStrings`), the intro offer when `eligible`, and the
/// best win-back offer of `eligibleWinBackIds` (`funnelWinBackOffer`).
@available(iOS 15.0, macOS 12.0, *)
func funnelPackagePrice(
    identifier: String, product: StoreKit.Product, eligible: Bool, eligibleWinBackIds: [String] = []
) -> FunnelPackagePrice {
    let offers = appleOfferInputs(from: product)
    let style = product.priceFormatStyle
    let per = funnelPerUnitPriceStrings(
        price: product.price, displayPrice: product.displayPrice,
        period: offers.period, storefront: style
    )
    return FunnelPackagePrice(
        identifier: identifier,
        localizedPrice: product.displayPrice,
        localizedPeriod: offers.period.flatMap(localizedPeriod),
        // Core already titles the row with the product's display name.
        localizedTitle: nil,
        amountMicros: amountMicros(product.price),
        currency: style.currencyCode.uppercased(),
        periodUnit: offers.period.map { funnelPeriodUnit($0.unit) },
        periodCount: offers.period.map { UInt32($0.value) },
        localizedPricePerMonth: per.month,
        localizedPricePerWeek: per.week,
        offer: funnelPackageOffer(offers.intro, eligible: eligible),
        winBack: funnelWinBackOffer(offers.winBacks, eligibleIds: eligibleWinBackIds)
    )
}

/// The win-back offer ids StoreKit lets this customer redeem for
/// `product`, best first, through `cache` (the instance's
/// `productCache`, which `eligibleWinBackOffers(for:)` shares) when there
/// is one. No status read for a product without win-back offers; empty
/// when StoreKit cannot answer — never promise an offer.
@available(iOS 15.0, macOS 12.0, *)
func funnelEligibleWinBackIds(_ product: StoreKit.Product, cache: StoreProductCache?) async -> [String] {
    guard !appleOfferInputs(from: product).winBacks.isEmpty else { return [] }
    if let cache {
        return await cache.eligibleWinBackOfferIds(productId: product.id) {
            await storeKitEligibleWinBackOfferIds(product)
        }
    }
    return await storeKitEligibleWinBackOfferIds(product) ?? []
}

/// One price per package StoreKit returned a product for; the rest are
/// omitted rather than sent empty. Eligibility is asked per product
/// (`isEligibleForIntroOffer` is per subscription group, win-back
/// eligibility through `funnelEligibleWinBackIds`); a product StoreKit
/// cannot answer for is treated as not eligible — never promise an offer.
@available(iOS 15.0, macOS 12.0, *)
func funnelPackagePrices(
    _ offering: CoreOffering, products: [String: StoreKit.Product], cache: StoreProductCache? = nil
) async -> [FunnelPackagePrice] {
    var prices: [FunnelPackagePrice] = []
    for pkg in offering.packages {
        guard let product = pkg.appleProductId.flatMap({ products[$0] }) else { continue }
        let eligible = await product.subscription?.isEligibleForIntroOffer ?? false
        let winBackIds = await funnelEligibleWinBackIds(product, cache: cache)
        prices.append(funnelPackagePrice(
            identifier: pkg.packageIdentifier, product: product, eligible: eligible,
            eligibleWinBackIds: winBackIds))
    }
    return prices
}

/// How long `getFunnel` waits for StoreKit prices. The funnel is the product
/// and prices are decoration on its rows: a store slower than this drops the
/// prices (rows keep their titles) rather than delay the funnel. 3 s covers a
/// product request on a cold StoreKit daemon with margin, and stays under the
/// point a host's loading state reads as hung.
let storePriceTimeoutNanoseconds: UInt64 = 3_000_000_000

/// How long a funnel shows its price skeletons before it gives up on the
/// store (spec 2026-11-22-funnel-price-loading-state, owner decision): 10 s
/// in all — counted from `getFunnel`'s start for the first lookup, from the
/// tap for a "Try again" — after which the rows read "Price unavailable" and
/// the purchase button offers "Try again". The lookup itself runs on, and
/// prices that land later still redraw the screen.
let storePriceGiveUpNanoseconds: UInt64 = 10_000_000_000

/// The monotonic clock the price deadlines are measured on: nanoseconds of
/// uptime, unaffected by the wall clock.
func funnelPriceClockNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// StoreKit prices kept for the app session, by Apple product id (spec
/// 2026-11-03-placement-open-from-cache §5): a reopened funnel — or one
/// `preloadPlacement` warmed — draws its price row on the first frame
/// instead of waiting on StoreKit. Each entry is stored with its package
/// identifier blanked; `prices(for:)` re-stamps the offering's own.
final class FunnelPriceCache: @unchecked Sendable {
    static let shared = FunnelPriceCache()

    private let lock = NSLock()
    private var byProduct: [String: FunnelPackagePrice] = [:]

    func store(_ prices: [String: FunnelPackagePrice]) {
        lock.lock()
        defer { lock.unlock() }
        byProduct.merge(prices) { _, new in new }
    }

    func price(productId: String) -> FunnelPackagePrice? {
        lock.lock()
        defer { lock.unlock() }
        return byProduct[productId]
    }

    /// One price per package of `offering`, or nil unless EVERY package
    /// with an Apple product is known — a half-priced row set would draw
    /// some rows blank.
    func prices(for offering: CoreOffering) -> [FunnelPackagePrice]? {
        var out: [FunnelPackagePrice] = []
        for pkg in offering.packages {
            guard let productId = pkg.appleProductId else { continue }
            guard var price = price(productId: productId) else { return nil }
            price.identifier = pkg.packageIdentifier
            out.append(price)
        }
        return out.isEmpty ? nil : out
    }
}

/// The StoreKit products for `ids` a funnel prices its rows from, through
/// `cache` — the instance's `productCache`, the one `getOfferings` and the
/// configure-time prefetch fill — so a funnel opened after them reads from
/// memory and concurrent lookups join one StoreKit query (plan
/// 2026-11-22-funnel-first-open-prices A). The cache's rules hold: an id
/// StoreKit answered without stays absent for its freshness, a failed lookup
/// is not kept. With no cache (no configured instance: a preview tool)
/// StoreKit is asked directly, as before.
@available(iOS 15.0, macOS 12.0, *)
func funnelStoreProducts(_ ids: [String], from cache: StoreProductCache?) async -> [String: StoreKit.Product] {
    if let cache { return await cache.products(for: ids) }
    return await StoreKitAppleStore().products(for: ids)
}

/// StoreKit's prices for `offering`'s products, written to
/// `FunnelPriceCache` and returned per package. Waits as long as StoreKit
/// takes — the callers that must not wait bound their wait
/// (`waitForPrices`), never this work. Nil when the offering names no Apple
/// product.
@available(iOS 15.0, macOS 12.0, *)
func lookUpAndCachePrices(_ offering: CoreOffering, from cache: StoreProductCache?) async -> [FunnelPackagePrice]? {
    let ids = Array(Set(offering.packages.compactMap { $0.appleProductId }))
    guard !ids.isEmpty else { return nil }
    let products = await funnelStoreProducts(ids, from: cache)
    let prices = await funnelPackagePrices(offering, products: products, cache: cache)
    var productOf: [String: String] = [:]
    for pkg in offering.packages {
        if let productId = pkg.appleProductId { productOf[pkg.packageIdentifier] = productId }
    }
    var byProduct: [String: FunnelPackagePrice] = [:]
    for price in prices {
        if let productId = productOf[price.identifier] { byProduct[productId] = price }
    }
    FunnelPriceCache.shared.store(byProduct)
    return prices
}

/// A funnel price lookup still running: what `getFunnel` hands the driver
/// when its wait ran out, so the prices still reach the open funnel when
/// StoreKit answers (`FunnelDriver.awaitLatePrices`).
typealias FunnelPriceLookup = Task<[FunnelPackagePrice]?, Never>

/// A funnel that opened while its store prices were still loading: the
/// lookup `getFunnel` stopped waiting for, the deadline after which the
/// funnel gives up on it (`storePriceGiveUpNanoseconds` after `getFunnel`
/// began, on `funnelPriceClockNow`), and what a "Try again" looks the
/// prices up again with — the offering and the instance's `productCache`.
/// The driver drawing the funnel takes it over (`FunnelDriver.awaitLatePrices`).
struct FunnelLatePrices: @unchecked Sendable {
    let lookup: FunnelPriceLookup
    /// The state the session was opened in: Pending for a lookup still out,
    /// Failed for one that already answered with no price.
    let state: FunnelPriceState
    let deadline: UInt64
    let offering: CoreOffering
    let products: StoreProductCache?
}

/// `lookUpAndCachePrices` as an unstructured task nobody cancels: the
/// caller's wait may give up or be cancelled, the lookup still lands and
/// fills `FunnelPriceCache` for the next open (plan
/// 2026-11-22-funnel-first-open-prices C — bound the wait, not the work).
@available(iOS 15.0, macOS 12.0, *)
func startPriceLookup(_ offering: CoreOffering, from cache: StoreProductCache?) -> FunnelPriceLookup {
    Task.detached { await lookUpAndCachePrices(offering, from: cache) }
}

/// What a bounded wait on a `FunnelPriceLookup` saw.
enum FunnelPriceWait {
    /// The lookup answered in time (nil: nothing to price).
    case landed([FunnelPackagePrice]?)
    /// The deadline came first; the lookup runs on.
    case timedOut
}

/// Waits for `lookup` at most `nanoseconds`. Not a task group: a group waits
/// for every child, so a StoreKit request that ignores cancellation would
/// still hold the funnel. Whichever of the lookup and the deadline finishes
/// first resumes, and the deadline cancels nothing — it ends only the wait.
@available(iOS 15.0, macOS 12.0, *)
func waitForPrices(_ lookup: FunnelPriceLookup, within nanoseconds: UInt64) async -> FunnelPriceWait {
    await withCheckedContinuation { (continuation: CheckedContinuation<FunnelPriceWait, Never>) in
        let once = ResumeOnce(continuation)
        let deadline = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            once.resume(.timedOut)
        }
        Task {
            let prices = await lookup.value
            once.resume(.landed(prices))
            deadline.cancel()
        }
    }
}

/// How `applyStorePrices` left the session.
enum FunnelStorePriceOutcome {
    /// Priced, or nothing to price (no offering, no Apple product): the
    /// session stays Ready and there is nothing left to watch.
    case settled
    /// The 3 s wait ran out: the session is still unpriced and the lookup
    /// runs on.
    case late(FunnelPriceLookup)
    /// StoreKit answered in time with no price for any of the offering's
    /// Apple products: an unpriced paywall must not open Ready (owner
    /// decision 2026-11-22), so it opens Failed and can "Try again".
    case empty(FunnelPriceLookup)
}

/// Hands the offering's StoreKit prices to the session. Prices this app
/// session already looked up are handed in at once — no StoreKit wait on a
/// reopen — and refreshed in the background for the next open (a price row
/// already drawn is never swapped). Otherwise StoreKit is asked through
/// `cache`, waiting at most `storePriceTimeoutNanoseconds`: a slower store
/// returns the session unpriced together with the still-running lookup
/// (`.late`), which the driver drawing the funnel hands in when it lands; a
/// store that answered with no price at all returns `.empty`. Any price
/// set — even for only some packages — settles it: core then marks only
/// the rows still waiting, and the state stays Ready.
@available(iOS 15.0, macOS 12.0, *)
func applyStorePrices(
    to session: FunnelSession, offering: CoreOffering?, from cache: StoreProductCache?
) async -> FunnelStorePriceOutcome {
    guard let offering, offering.packages.contains(where: { $0.appleProductId != nil }) else { return .settled }
    if let cached = FunnelPriceCache.shared.prices(for: offering) {
        _ = session.setPackagePrices(prices: cached)
        _ = startPriceLookup(offering, from: cache)
        return .settled
    }
    let lookup = startPriceLookup(offering, from: cache)
    switch await waitForPrices(lookup, within: storePriceTimeoutNanoseconds) {
    case .landed(let prices):
        guard let prices, !prices.isEmpty else { return .empty(lookup) }
        _ = session.setPackagePrices(prices: prices)
        return .settled
    case .timedOut:
        return .late(lookup)
    }
}

/// Resumes a continuation exactly once; later calls are dropped.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
