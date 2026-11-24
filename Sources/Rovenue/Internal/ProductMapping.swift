import Foundation
import StoreKit

// MARK: - AppleOfferInput

struct AppleOfferInput {
    let id: String?
    let type: DiscountType
    let paymentMode: PaymentMode
    let price: Decimal
    let displayPrice: String
    let periodValue: Int
    let periodUnit: PeriodUnit
    let periodCount: Int
}

// MARK: - Pure mapper

/// A StoreKit subscription offer as a public `Discount` (`StoreProduct.discounts`).
func appleDiscount(_ offer: AppleOfferInput, currencyCode: String?) -> Discount {
    let per = makePeriod(value: offer.periodValue, unit: offer.periodUnit)
    return Discount(identifier: offer.id, price: offer.price, priceString: offer.displayPrice,
                    currencyCode: currencyCode, period: per, numberOfPeriods: offer.periodCount,
                    paymentMode: offer.paymentMode, type: offer.type)
}

/// The win-back discounts `eligibleWinBackOffers(for:)` filters: the
/// product's own, or — for a product built from its id alone (the React
/// Native and Flutter bridges pass one, with no catalog and no StoreKit
/// product) — those StoreKit lists for it (`storeWinBacks`).
func winBackCatalog(_ product: StoreProduct, storeWinBacks: [AppleOfferInput], currencyCode: String?) -> [Discount] {
    let own = product.discounts.filter { $0.type == .winBack }
    guard own.isEmpty, product.rawStoreProduct == nil else { return own }
    return storeWinBacks.map { appleDiscount($0, currencyCode: currencyCode) }
}

func mapAppleStoreProduct(
    core: CoreOfferingProduct,
    period: Period?,
    introOffer: AppleOfferInput?,
    promoOffers: [AppleOfferInput],
    winBackOffers: [AppleOfferInput] = [],
    groupId: String?,
    isFamilyShareable: Bool,
    description: String?,
    priceString: String?,
    price: Decimal?,
    currencyCode: String?,
    isEligible: Bool?,
    raw: StoreKit.Product?,
    formatCurrency: (Decimal) -> String?
) -> StoreProduct {
    let type = ProductType.from(core.productType)
    let category: ProductCategory = type == .subscription ? .subscription : .nonSubscription
    let displayName = raw?.displayName ?? core.displayName

    let introPrice: IntroPrice? = introOffer.map {
        let per = makePeriod(value: $0.periodValue, unit: $0.periodUnit)
        return IntroPrice(price: $0.price, priceString: $0.displayPrice, currencyCode: currencyCode,
                          period: per, cycles: $0.periodCount, paymentMode: $0.paymentMode)
    }
    // discounts = promotional offers, then win-back offers (intro is exposed
    // via introPrice). Win-back offers are the catalog StoreKit lists, not
    // what this customer may redeem: see `eligibleWinBackOffers(for:)`.
    let discounts: [Discount] = (promoOffers + winBackOffers).map { appleDiscount($0, currencyCode: currencyCode) }
    let per = perUnitPrices(price: price, period: period, formatCurrency: formatCurrency)

    // StoreProduct.id is the App Store SKU used for StoreKit product lookups
    // and server-side receipt validation — NOT the Rovenue catalog slug. Mirror
    // the Kotlin façade's `mapProductId` (googleProductId ?? identifier): fall
    // back to the catalog identifier only when no Apple product id is configured.
    let productId = core.appleProductId ?? core.identifier
    return StoreProduct(id: productId, type: type, productCategory: category,
        displayName: displayName, description: description, priceString: priceString,
        price: price, currencyCode: currencyCode, subscriptionPeriod: period,
        subscriptionGroupIdentifier: groupId, isFamilyShareable: isFamilyShareable,
        introPrice: introPrice, discounts: discounts, isEligibleForIntroOffer: isEligible,
        subscriptionOptions: nil, defaultOption: nil,
        pricePerWeek: per.week, pricePerMonth: per.month, pricePerYear: per.year,
        pricePerWeekString: per.weekStr, pricePerMonthString: per.monthStr,
        pricePerYearString: per.yearStr, rawStoreProduct: raw)
}

// MARK: - StoreKit offer extractor

@available(iOS 15.0, macOS 12.0, *)
func appleOfferInputs(from product: StoreKit.Product)
    -> (period: Period?, intro: AppleOfferInput?, promos: [AppleOfferInput], winBacks: [AppleOfferInput], groupId: String?) {
    guard let sub = product.subscription else { return (nil, nil, [], [], nil) }
    func unit(_ u: StoreKit.Product.SubscriptionPeriod.Unit) -> PeriodUnit {
        switch u {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .year: return .year
        @unknown default: return .month
        }
    }
    func mode(_ m: StoreKit.Product.SubscriptionOffer.PaymentMode) -> PaymentMode {
        switch m {
        case .freeTrial: return .freeTrial
        case .payAsYouGo: return .payAsYouGo
        case .payUpFront: return .payUpFront
        default: return .payAsYouGo
        }
    }
    let period = makePeriod(value: sub.subscriptionPeriod.value,
                            unit: unit(sub.subscriptionPeriod.unit))
    func input(_ o: StoreKit.Product.SubscriptionOffer, _ type: DiscountType) -> AppleOfferInput {
        AppleOfferInput(id: o.id, type: type, paymentMode: mode(o.paymentMode),
            price: o.price, displayPrice: o.displayPrice, periodValue: o.period.value,
            periodUnit: unit(o.period.unit), periodCount: o.periodCount)
    }
    let intro: AppleOfferInput? = sub.introductoryOffer.map { input($0, .introductory) }
    let promos: [AppleOfferInput] = sub.promotionalOffers.map { input($0, .promotional) }
    // Win-back offers exist from iOS 18 / macOS 15, in SDKs built with
    // Xcode 16 (Swift 6) or later; elsewhere the product lists none.
    var winBacks: [AppleOfferInput] = []
    #if compiler(>=6.0)
    if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        winBacks = sub.winBackOffers.map { input($0, .winBack) }
    }
    #endif
    return (period, intro, promos, winBacks, sub.subscriptionGroupID)
}

// MARK: - Period helpers

func iso8601(from value: Int, unit: PeriodUnit) -> String {
    switch unit {
    case .day: return "P\(value)D"
    case .week: return "P\(value)W"
    case .month: return "P\(value)M"
    case .year: return "P\(value)Y"
    }
}

func makePeriod(value: Int, unit: PeriodUnit) -> Period {
    Period(value: value, unit: unit, iso8601: iso8601(from: value, unit: unit))
}

/// A product's per-week, per-month and per-year prices, on the funnel's
/// calendar (`funnelMonths`: a year is 12 months, 52 weeks, 365 days), so
/// `pricePerWeekString` matches `{{product.price_per_week}}` — a 30-day
/// month here once made a $1,299.99 yearly row "$24.93" a week beside the
/// funnel's "$25.00".
func perUnitPrices(price: Decimal?, period: Period?, formatCurrency: (Decimal) -> String?)
    -> (week: Decimal?, month: Decimal?, year: Decimal?, weekStr: String?, monthStr: String?, yearStr: String?) {
    guard let price = price, let period = period else {
        return (nil, nil, nil, nil, nil, nil)
    }
    let months = funnelMonths(in: Period(value: max(period.value, 1), unit: period.unit, iso8601: period.iso8601))
    let m = price / months
    let w = m * funnelMonthsPerYear / funnelWeeksPerYear
    let y = m * funnelMonthsPerYear
    return (w, m, y, formatCurrency(w), formatCurrency(m), formatCurrency(y))
}

/// How a product's `pricePer*String` fields are written: in the style that
/// writes its base price as StoreKit's `displayPrice` (`funnelPriceFormat`,
/// the rule a funnel's per-unit prices follow), so a Turkish device on a US
/// storefront gets "$2.606,62" beside "$49,99", not `priceFormatStyle`'s
/// "$2,606.62". Writes nothing when no style reproduces `displayPrice`.
@available(iOS 15.0, macOS 12.0, *)
func storeProductPriceFormatter(
    price: Decimal, displayPrice: String,
    storefront: Decimal.FormatStyle.Currency, deviceLocale: Locale = .current
) -> (Decimal) -> String? {
    guard let style = funnelPriceFormat(
        price: price, displayPrice: displayPrice, storefront: storefront, deviceLocale: deviceLocale
    ) else { return { _ in nil } }
    return { $0.formatted(style) }
}

// MARK: - PackageType derivation

func packageType(forSlot id: String) -> PackageType {
    switch id {
    case "$rov_weekly": return .weekly
    case "$rov_monthly": return .monthly
    case "$rov_two_month": return .twoMonth
    case "$rov_three_month": return .threeMonth
    case "$rov_six_month": return .sixMonth
    case "$rov_annual": return .annual
    case "$rov_lifetime": return .lifetime
    default: return .custom
    }
}
