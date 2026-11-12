//  Types.swift — Sendable conformance for UniFFI-generated value types.
//
//  The generated `User`, `Entitlement`, `ReceiptResult`, and `ChangeEvent`
//  already conform to `Equatable, Hashable` via UniFFI-generated extensions,
//  so we only need to add `@unchecked Sendable` here so SwiftUI / Combine
//  consumers can pass these values across actors.
//
//  All stored properties are themselves `Sendable` (String, Int64, Bool,
//  Optional<…>) — the `@unchecked` is purely because the structs are defined
//  in another file we don't own, so the compiler can't synthesize the
//  conformance automatically.
//
//  Adding these here keeps the public API surface idiomatic without forcing
//  the UDL to declare conformance traits (UniFFI 0.25 doesn't expose that
//  knob anyway).

import Foundation
import StoreKit

extension User: @unchecked Sendable {}

extension Entitlement: @unchecked Sendable {}

extension ReceiptResult: @unchecked Sendable {}

extension ChangeEvent: @unchecked Sendable {}

// MARK: - Public purchase types
//
// These are the SDK's public-facing purchasing surface. They intentionally
// mirror the RevenueCat / Adapty shapes (Offerings → Offering → Package →
// StoreProduct) so the API is familiar.
//
// NOTE: the UniFFI core returns its own `CoreOfferings` / `CoreOffering` /
// `CoreOfferingProduct` value types (defined in Generated/RovenueFFI.swift,
// renamed from `Offerings` / `Offering` / `OfferingProduct` to avoid a
// same-module name collision with the public types below). `getOfferings()`
// in Rovenue.swift bridges the core types into these public ones, enriching
// them with StoreKit price metadata.

/// Product kind, mapped from the core's `productType` string.
public enum ProductType: Sendable, Equatable {
    case subscription, consumable, nonConsumable

    public static func from(_ raw: String) -> ProductType {
        switch raw {
        case "CONSUMABLE": return .consumable
        case "NON_CONSUMABLE": return .nonConsumable
        case "SUBSCRIPTION": return .subscription
        default: return .subscription
        }
    }
}

public enum ProductCategory: Sendable, Equatable { case subscription, nonSubscription }
public enum PeriodUnit: Sendable, Equatable { case day, week, month, year }
public enum PaymentMode: Sendable, Equatable { case freeTrial, payAsYouGo, payUpFront }
public enum DiscountType: Sendable, Equatable { case introductory, promotional, winBack }
public enum RecurrenceMode: Sendable, Equatable { case infiniteRecurring, finiteRecurring, nonRecurring }

public struct Period: Sendable, Equatable {
    public let value: Int
    public let unit: PeriodUnit
    public let iso8601: String
    public init(value: Int, unit: PeriodUnit, iso8601: String) {
        self.value = value; self.unit = unit; self.iso8601 = iso8601
    }
}

public struct IntroPrice: Sendable, Equatable {
    public let price: Decimal?
    public let priceString: String?
    public let currencyCode: String?
    public let period: Period
    public let cycles: Int
    public let paymentMode: PaymentMode
    public init(price: Decimal?, priceString: String?, currencyCode: String?,
                period: Period, cycles: Int, paymentMode: PaymentMode) {
        self.price = price; self.priceString = priceString; self.currencyCode = currencyCode
        self.period = period; self.cycles = cycles; self.paymentMode = paymentMode
    }
}

public struct Discount: Sendable, Equatable {
    public let identifier: String?
    public let price: Decimal?
    public let priceString: String?
    public let currencyCode: String?
    public let period: Period
    public let numberOfPeriods: Int
    public let paymentMode: PaymentMode
    public let type: DiscountType
    public init(identifier: String?, price: Decimal?, priceString: String?, currencyCode: String?,
                period: Period, numberOfPeriods: Int, paymentMode: PaymentMode, type: DiscountType) {
        self.identifier = identifier; self.price = price; self.priceString = priceString
        self.currencyCode = currencyCode; self.period = period
        self.numberOfPeriods = numberOfPeriods; self.paymentMode = paymentMode; self.type = type
    }
}

public struct PricingPhase: Sendable, Equatable {
    public let price: Decimal?
    public let priceString: String?
    public let currencyCode: String?
    public let billingPeriod: Period
    public let billingCycleCount: Int?
    public let recurrenceMode: RecurrenceMode
    public let paymentMode: PaymentMode?
    public init(price: Decimal?, priceString: String?, currencyCode: String?,
                billingPeriod: Period, billingCycleCount: Int?,
                recurrenceMode: RecurrenceMode, paymentMode: PaymentMode?) {
        self.price = price; self.priceString = priceString; self.currencyCode = currencyCode
        self.billingPeriod = billingPeriod; self.billingCycleCount = billingCycleCount
        self.recurrenceMode = recurrenceMode; self.paymentMode = paymentMode
    }
}

public struct SubscriptionOption: Sendable, Equatable {
    public let id: String
    public let basePlanId: String?
    public let offerId: String?
    public let tags: [String]
    public let isBasePlan: Bool
    public let isPrepaid: Bool
    public let pricingPhases: [PricingPhase]
    public let freePhase: PricingPhase?
    public let introPhase: PricingPhase?
    public let fullPricePhase: PricingPhase?
    public init(id: String, basePlanId: String?, offerId: String?, tags: [String],
                isBasePlan: Bool, isPrepaid: Bool, pricingPhases: [PricingPhase],
                freePhase: PricingPhase?, introPhase: PricingPhase?, fullPricePhase: PricingPhase?) {
        self.id = id; self.basePlanId = basePlanId; self.offerId = offerId; self.tags = tags
        self.isBasePlan = isBasePlan; self.isPrepaid = isPrepaid; self.pricingPhases = pricingPhases
        self.freePhase = freePhase; self.introPhase = introPhase; self.fullPricePhase = fullPricePhase
    }
}

public enum PackageType: Sendable, Equatable {
    case unknown, custom, lifetime, annual, sixMonth, threeMonth, twoMonth, monthly, weekly
}

/// A purchasable product, enriched with StoreKit price metadata when available.
public struct StoreProduct: Sendable, Equatable {
    public let id: String
    public let type: ProductType
    public let productCategory: ProductCategory
    public let displayName: String
    public let description: String?
    public let priceString: String?
    public let price: Decimal?
    public let currencyCode: String?
    public let subscriptionPeriod: Period?
    public let subscriptionGroupIdentifier: String?
    public let isFamilyShareable: Bool
    public let introPrice: IntroPrice?
    public let discounts: [Discount]
    public let isEligibleForIntroOffer: Bool?
    public let subscriptionOptions: [SubscriptionOption]?
    public let defaultOption: SubscriptionOption?
    public let pricePerWeek: Decimal?
    public let pricePerMonth: Decimal?
    public let pricePerYear: Decimal?
    public let pricePerWeekString: String?
    public let pricePerMonthString: String?
    public let pricePerYearString: String?
    public let rawStoreProduct: StoreKit.Product?
    public init(id: String, type: ProductType, productCategory: ProductCategory,
                displayName: String, description: String?, priceString: String?, price: Decimal?,
                currencyCode: String?, subscriptionPeriod: Period?, subscriptionGroupIdentifier: String?,
                isFamilyShareable: Bool, introPrice: IntroPrice?, discounts: [Discount],
                isEligibleForIntroOffer: Bool?, subscriptionOptions: [SubscriptionOption]?,
                defaultOption: SubscriptionOption?, pricePerWeek: Decimal?, pricePerMonth: Decimal?,
                pricePerYear: Decimal?, pricePerWeekString: String?, pricePerMonthString: String?,
                pricePerYearString: String?, rawStoreProduct: StoreKit.Product?) {
        self.id = id; self.type = type; self.productCategory = productCategory
        self.displayName = displayName; self.description = description
        self.priceString = priceString; self.price = price; self.currencyCode = currencyCode
        self.subscriptionPeriod = subscriptionPeriod
        self.subscriptionGroupIdentifier = subscriptionGroupIdentifier
        self.isFamilyShareable = isFamilyShareable; self.introPrice = introPrice
        self.discounts = discounts; self.isEligibleForIntroOffer = isEligibleForIntroOffer
        self.subscriptionOptions = subscriptionOptions; self.defaultOption = defaultOption
        self.pricePerWeek = pricePerWeek; self.pricePerMonth = pricePerMonth
        self.pricePerYear = pricePerYear; self.pricePerWeekString = pricePerWeekString
        self.pricePerMonthString = pricePerMonthString; self.pricePerYearString = pricePerYearString
        self.rawStoreProduct = rawStoreProduct
    }
}

/// One credit grant a package's product pays: `amount` of the virtual currency
/// `code`, on `grantOn` (`"PURCHASE"`, `"RENEWAL"` or `"BOTH"` today; newer
/// values pass through verbatim). The same rule the server grants by.
public struct VirtualCurrencyGrant: Sendable, Equatable {
    /// The virtual currency's code, as configured in the dashboard (e.g. `"GOLD"`).
    public let code: String
    /// How much of the currency one grant pays.
    public let amount: Int64
    /// When the grant fires. An open string so a newer server value never fails decoding.
    public let grantOn: String
    /// Days between grants for a periodic trigger; `nil` for every lifecycle trigger.
    public let intervalDays: Int64?
    /// Credits paid once, when a trial starts, for each subscription chain and
    /// currency. Never clawed back. `0` means no trial grant.
    public let trialAmount: Int64
    /// Whether credits granted by this rule expire at the end of the period they
    /// were granted for: the billing period, the N-day period for a periodic
    /// rule, or the trial.
    public let expiresAtPeriodEnd: Bool

    /// Creates a grant rule, e.g. for a SwiftUI preview.
    public init(code: String, amount: Int64, grantOn: String, intervalDays: Int64? = nil,
                trialAmount: Int64 = 0, expiresAtPeriodEnd: Bool = false) {
        self.code = code; self.amount = amount; self.grantOn = grantOn; self.intervalDays = intervalDays
        self.trialAmount = trialAmount; self.expiresAtPeriodEnd = expiresAtPeriodEnd
    }
}

/// A named container pairing an offering identifier with a concrete product.
public struct Package: Sendable, Equatable {
    public let identifier: String
    public let packageType: PackageType
    public let product: StoreProduct
    /// Whether the dashboard marked this package as the one to feature.
    public let isPromoted: Bool
    /// The package's dashboard metadata as a JSON object string; see ``metadata``.
    public let metadataJson: String
    /// The credit grants this package's product pays: the server's own grant rule.
    public let virtualCurrencyGrants: [VirtualCurrencyGrant]

    /// ``metadataJson`` parsed; `[:]` when empty.
    public var metadata: [String: Any] { parseMetadataJSON(metadataJson) }

    public init(identifier: String, packageType: PackageType, product: StoreProduct,
                isPromoted: Bool = false, metadataJson: String = "{}",
                virtualCurrencyGrants: [VirtualCurrencyGrant] = []) {
        self.identifier = identifier; self.packageType = packageType; self.product = product
        self.isPromoted = isPromoted; self.metadataJson = metadataJson
        self.virtualCurrencyGrants = virtualCurrencyGrants
    }
}

/// A group of packages presented together.
public struct Offering: Sendable, Equatable {
    public let identifier: String
    public let isDefault: Bool
    public let packages: [Package]
    /// The offering's dashboard metadata as a JSON object string; see ``metadata``.
    public let metadataJson: String

    /// ``metadataJson`` parsed; `[:]` when empty.
    public var metadata: [String: Any] { parseMetadataJSON(metadataJson) }

    public init(identifier: String, isDefault: Bool, packages: [Package], metadataJson: String = "{}") {
        self.identifier = identifier
        self.isDefault = isDefault
        self.packages = packages
        self.metadataJson = metadataJson
    }
}

extension Offering {
    public func package(identifier: String) -> Package? {
        packages.first { $0.identifier == identifier }
    }
    private func first(_ t: PackageType) -> Package? { packages.first { $0.packageType == t } }
    public var lifetime: Package? { first(.lifetime) }
    public var annual: Package? { first(.annual) }
    public var sixMonth: Package? { first(.sixMonth) }
    public var threeMonth: Package? { first(.threeMonth) }
    public var twoMonth: Package? { first(.twoMonth) }
    public var monthly: Package? { first(.monthly) }
    public var weekly: Package? { first(.weekly) }
}

/// The full set of offerings, plus the server-designated `current` offering.
public struct Offerings: Sendable, Equatable {
    public let current: Offering?
    public let all: [String: Offering]

    public init(current: Offering?, all: [String: Offering]) {
        self.current = current
        self.all = all
    }
}

/// The result of a completed purchase: refreshed entitlements + virtual-currency balances,
/// plus the product / store-transaction identifiers for the purchase that ran.
///
/// `isDeferred` is `true` when the purchase is pending external approval
/// (e.g. Ask to Buy). In that case `entitlements` is empty and
/// `storeTransactionId` is an empty string — the entitlements will arrive
/// asynchronously once the approver accepts.
public struct PurchaseResult: Sendable, Equatable {
    public let entitlements: [Entitlement]
    public let virtualCurrencies: [String: Int64]
    public let productId: String
    public let storeTransactionId: String
    /// `true` when the purchase is deferred pending external approval.
    public var isDeferred: Bool

    public init(
        entitlements: [Entitlement],
        virtualCurrencies: [String: Int64],
        productId: String,
        storeTransactionId: String,
        isDeferred: Bool = false
    ) {
        self.entitlements = entitlements
        self.virtualCurrencies = virtualCurrencies
        self.productId = productId
        self.storeTransactionId = storeTransactionId
        self.isDeferred = isDeferred
    }
}
