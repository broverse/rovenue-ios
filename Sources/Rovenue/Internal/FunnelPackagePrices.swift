//  FunnelPackagePrices.swift — store prices for a funnel's package rows (D13).
//
//  Core performs no store I/O, so a funnel session opens with its offering's
//  packages titled (the product's display name) but UNPRICED. This hands the
//  session what StoreKit knows, once, as soon as the products load — the
//  same product lookup `getOfferings` hydrates from (`StoreKitAppleStore
//  .products(for:)` keyed by `appleProductId`), `displayPrice` as the price,
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
/// calendar, written by `format` (the product's own `priceFormatStyle`).
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

/// One package's price facts from its StoreKit product: the display price,
/// the numbers savings are computed from, the per-month / per-week strings
/// on the crate's calendar (`funnelPerUnitStrings`, StoreKit's own format
/// style), and the intro offer when `eligible`.
@available(iOS 15.0, macOS 12.0, *)
func funnelPackagePrice(
    identifier: String, product: StoreKit.Product, eligible: Bool
) -> FunnelPackagePrice {
    let offers = appleOfferInputs(from: product)
    let style = product.priceFormatStyle
    let per = funnelPerUnitStrings(price: product.price, period: offers.period) { $0.formatted(style) }
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
        offer: funnelPackageOffer(offers.intro, eligible: eligible)
    )
}

/// One price per package StoreKit returned a product for; the rest are
/// omitted rather than sent empty. Eligibility is asked per product
/// (`isEligibleForIntroOffer` is per subscription group); a product StoreKit
/// cannot answer for is treated as not eligible — never promise an offer.
@available(iOS 15.0, macOS 12.0, *)
func funnelPackagePrices(
    _ offering: CoreOffering, products: [String: StoreKit.Product]
) async -> [FunnelPackagePrice] {
    var prices: [FunnelPackagePrice] = []
    for pkg in offering.packages {
        guard let product = pkg.appleProductId.flatMap({ products[$0] }) else { continue }
        let eligible = await product.subscription?.isEligibleForIntroOffer ?? false
        prices.append(funnelPackagePrice(identifier: pkg.packageIdentifier, product: product, eligible: eligible))
    }
    return prices
}

/// How long `getFunnel` waits for StoreKit prices. The funnel is the product
/// and prices are decoration on its rows: a store slower than this drops the
/// prices (rows keep their titles) rather than delay the funnel. 3 s covers a
/// product request on a cold StoreKit daemon with margin, and stays under the
/// point a host's loading state reads as hung.
let storePriceTimeoutNanoseconds: UInt64 = 3_000_000_000

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

/// StoreKit's prices for `offering`'s products, written to
/// `FunnelPriceCache` and returned per package. Nil when StoreKit has not
/// answered within `storePriceTimeoutNanoseconds`.
@available(iOS 15.0, macOS 12.0, *)
func lookUpAndCachePrices(_ offering: CoreOffering) async -> [FunnelPackagePrice]? {
    let ids = Array(Set(offering.packages.compactMap { $0.appleProductId }))
    guard !ids.isEmpty,
        let products = await storeProducts(ids, within: storePriceTimeoutNanoseconds)
    else { return nil }
    let prices = await funnelPackagePrices(offering, products: products)
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

/// Hands the offering's StoreKit prices to the session. Prices this app
/// session already looked up are handed in at once — no StoreKit wait on a
/// reopen — and refreshed in the background for the next open (a price row
/// already drawn is never swapped). Otherwise StoreKit is asked, within
/// `storePriceTimeoutNanoseconds`; a funnel with no offering, a slower
/// store, or one that knows none of its products leaves the session
/// untouched.
@available(iOS 15.0, macOS 12.0, *)
func applyStorePrices(to session: FunnelSession, offering: CoreOffering?) async {
    guard let offering else { return }
    if let cached = FunnelPriceCache.shared.prices(for: offering) {
        _ = session.setPackagePrices(prices: cached)
        Task.detached { _ = await lookUpAndCachePrices(offering) }
        return
    }
    guard let prices = await lookUpAndCachePrices(offering), !prices.isEmpty else { return }
    _ = session.setPackagePrices(prices: prices)
}

/// StoreKit's products for `ids`, or nil when StoreKit has not answered
/// within `nanoseconds`. Not a task group: a group waits for every child,
/// so a StoreKit request that ignores cancellation would still hold the
/// funnel. Whichever of the load and the deadline finishes first resumes.
@available(iOS 15.0, macOS 12.0, *)
func storeProducts(
    _ ids: [String], within nanoseconds: UInt64
) async -> [String: StoreKit.Product]? {
    await withCheckedContinuation { (continuation: CheckedContinuation<[String: StoreKit.Product]?, Never>) in
        let once = ResumeOnce(continuation)
        let load = Task { once.resume(await StoreKitAppleStore().products(for: ids)) }
        Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            load.cancel()
            once.resume(nil)
        }
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
