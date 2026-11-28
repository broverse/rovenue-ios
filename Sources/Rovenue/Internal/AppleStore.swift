//  AppleStore.swift — abstraction over the App Store purchase mechanism so the
//  purchase orchestration (`ApplePurchaseFlow`) can be unit-tested with a fake.
//
//  The real implementation (`StoreKitAppleStore`) wraps StoreKit 2 and CANNOT
//  run under `swift test` (no store, no network) — it is build-verified only.
//  Tests inject a `FakeStore` instead.

import Foundation
import StoreKit

/// The outcome of asking the store to run a purchase. `success` carries the
/// signed JWS to validate server-side, the store transaction id, and a
/// `finish` closure the flow must call *after* successful validation so the
/// transaction is only acknowledged once the entitlement is granted.
internal enum StorePurchaseOutcome {
    case success(jws: String, transactionId: String, finish: @Sendable () async -> Void)
    case userCancelled
    /// The purchase is pending external action (Ask to Buy, etc.).
    /// The flow returns a deferred `PurchaseResult` rather than throwing.
    case pending
    case productNotFound
    /// The user already owns this non-consumable / active subscription.
    case alreadyOwned
    /// Payment was declined (e.g. parental controls, insufficient funds signal).
    case paymentDeclined
    /// The App Store is temporarily unreachable.
    case serviceUnavailable
    /// The user is ineligible for the offer (e.g. introductory offer already used).
    case ineligible
    /// The product is not available in the user's storefront.
    case productNotAvailableInStorefront
    /// A win-back purchase whose offer StoreKit cannot apply here: the OS is
    /// older than iOS 18 / macOS 15, the SDK was built without the API, or
    /// StoreKit lists no win-back offer with that id for the product. The
    /// sheet was never opened.
    case winBackOfferUnavailable
}

/// The offer a purchase applies. A promotional offer carries the signed
/// material; a win-back offer only its id — StoreKit redeems it with
/// `Product.PurchaseOption.winBackOffer(_:)`, no signature.
internal enum AppleStoreOffer: Sendable, Equatable {
    case promotional(AppleSignedOffer)
    case winBack(offerId: String)
}

/// Minimal seam over the App Store. Implementations must be `Sendable` so they
/// can be captured into the `ApplePurchaseFlow` struct across concurrency
/// domains.
internal protocol AppleStore: Sendable {
    func purchase(productId: String, appAccountToken: String?, offer: AppleStoreOffer?) async throws -> StorePurchaseOutcome
}

/// The real StoreKit 2 implementation. Build-verified only — never exercised
/// under `swift test` (requires a live App Store / StoreKit testing host).
@available(iOS 15.0, macOS 12.0, *)
internal struct StoreKitAppleStore: AppleStore {
    func purchase(productId: String, appAccountToken: String?, offer: AppleStoreOffer?) async throws -> StorePurchaseOutcome {
        let products: [Product]
        do {
            products = try await Product.products(for: [productId])
        } catch let skErr as StoreKitError {
            switch skErr {
            case .networkError, .systemError:
                return .serviceUnavailable
            case .notAvailableInStorefront:
                return .productNotAvailableInStorefront
            default:
                throw RovenueError(kind: .storeProblem, message: "\(skErr)")
            }
        } catch {
            throw RovenueError(kind: .storeProblem, message: "\(error)")
        }
        guard let product = products.first else {
            return .productNotFound
        }

        var options: Set<Product.PurchaseOption> = []
        if let token = appAccountToken, let uuid = UUID(uuidString: token) {
            options.insert(.appAccountToken(uuid))
        }
        switch offer {
        case nil:
            break
        case let .promotional(signed):
            // JWS form when this build has it, legacy signature otherwise
            // (AppleOfferSigning); malformed material throws, never buys
            // without the offer.
            for option in try AppleOfferSigning.purchaseOptions(for: signed) {
                options.insert(option)
            }
        case let .winBack(offerId):
            // Never buys without the offer: one StoreKit does not list (or
            // an OS without win-back offers) ends here, before the sheet.
            guard let option = Self.winBackOption(product: product, offerId: offerId) else {
                return .winBackOfferUnavailable
            }
            options.insert(option)
        }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: options)
        } catch let skErr as StoreKitError {
            switch skErr {
            case .networkError, .systemError:
                return .serviceUnavailable
            case .notAvailableInStorefront:
                return .productNotAvailableInStorefront
            default:
                throw RovenueError(kind: .storeProblem, message: "\(skErr)")
            }
        } catch let pErr as Product.PurchaseError {
            switch pErr {
            case .ineligibleForOffer, .invalidQuantity, .productUnavailable:
                return .ineligible
            // StoreKit refused the signed offer itself. Reported as is: the
            // other signature form would be refused for the same reason.
            case .invalidOfferSignature:
                throw AppleOfferSigning.offerRejected("invalidOfferSignature")
            case .invalidOfferIdentifier:
                throw AppleOfferSigning.offerRejected("invalidOfferIdentifier")
            case .invalidOfferPrice:
                throw AppleOfferSigning.offerRejected("invalidOfferPrice")
            case .missingOfferParameters:
                throw AppleOfferSigning.offerRejected("missingOfferParameters")
            default:
                throw RovenueError(kind: .storeProblem, message: "\(pErr)")
            }
        } catch {
            throw RovenueError(kind: .storeProblem, message: "\(error)")
        }

        switch result {
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        case let .success(verification):
            guard case let .verified(transaction) = verification else {
                throw RovenueError(kind: .receiptInvalid, message: "StoreKit transaction could not be verified")
            }
            return .success(
                jws: verification.jwsRepresentation,
                transactionId: String(transaction.id),
                finish: { await transaction.finish() }
            )
        @unknown default:
            throw RovenueError(kind: .storeProblem, message: "Unexpected StoreKit result")
        }
    }

    /// `.winBackOffer(_:)` with the subscription's StoreKit win-back offer
    /// whose id is `offerId`; nil before iOS 18 / macOS 15, in a build whose
    /// SDK lacks the API, or when StoreKit lists no such offer.
    static func winBackOption(product: Product, offerId: String) -> Product.PurchaseOption? {
        #if compiler(>=6.0)
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *),
           let offer = product.subscription?.winBackOffers.first(where: { $0.id == offerId }) {
            return .winBackOffer(offer)
        }
        #endif
        return nil
    }

    /// Best-effort batch lookup of StoreKit products by store id. Returns an
    /// empty map on any failure (offerings still render, just without prices).
    func products(for ids: [String]) async -> [String: Product] {
        guard !ids.isEmpty else { return [:] }
        do {
            let products = try await Product.products(for: ids)
            return Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        } catch {
            return [:]
        }
    }
}
