//  AppleOfferSigning.swift — which promotional-offer form a purchase uses,
//  and the StoreKit purchase options it turns into.
//
//  Two forms exist (Apple, "Generating JWS to sign App Store requests"):
//    * JWS — `Product.PurchaseOption.promotionalOffer(_:compactJWS:)`, signed
//      server-side by `POST /v1/purchases/apple-offer-jws`. In the iOS 26 /
//      macOS 26 SDKs (Xcode 26, Swift 6.2) and back-deployed to iOS 15 /
//      macOS 12, so every OS this package supports runs it once the SDK was
//      compiled with it.
//    * Legacy signature — `promotionalOffer(offerID:keyID:nonce:signature:timestamp:)`,
//      deprecated in the 26 SDKs. Used only when the SDK was compiled with an
//      older Xcode (the JWS API is then not in the SDK at all), or when the
//      server predates the JWS route (it answers 404).
//
//  StoreKit refusing a JWS is reported, never retried with the legacy form:
//  a rejected signature means wrong key / wrong offer / clock, and the
//  legacy form would fail the same way.

import Foundation
import StoreKit

/// Signed promotional-offer material handed to StoreKit.
internal enum AppleSignedOffer: Sendable, Equatable {
    /// A compact JWS for `promotionalOffer(_:compactJWS:)`.
    case jws(offerId: String, compactJWS: String)
    /// The legacy signature for `promotionalOffer(offerID:keyID:nonce:signature:timestamp:)`.
    case legacy(offerId: String, keyId: String, nonce: String, signatureBase64: String, timestamp: Int)

    var offerId: String {
        switch self {
        case let .jws(offerId, _): return offerId
        case let .legacy(offerId, _, _, _, _): return offerId
        }
    }
}

/// Which promotional-offer form the SDK asks the server for.
internal enum AppleOfferSigningMode: Sendable, Equatable {
    case jws
    case legacySignature

    /// `.jws` when this build's StoreKit has `promotionalOffer(_:compactJWS:)`
    /// (Xcode 26 SDKs ship it with Swift 6.2), else `.legacySignature`.
    static var compiled: AppleOfferSigningMode {
        #if compiler(>=6.2)
        return .jws
        #else
        return .legacySignature
        #endif
    }
}

internal enum AppleOfferSigning {
    typealias FetchJWS = @Sendable (_ productId: String, _ offerId: String, _ transactionId: String?) async throws -> String
    typealias FetchLegacy = @Sendable (_ productId: String, _ offerId: String, _ appAccountToken: String) async throws -> AppleSignedOffer

    /// Fetch the signed offer in `mode`. A JWS request answered 404 (a server
    /// without the route) falls back to the legacy signature; every other
    /// failure — a refused product, a missing key — is thrown as it is.
    static func sign(
        mode: AppleOfferSigningMode,
        productId: String,
        offerId: String,
        appAccountToken: String,
        transactionId: @Sendable () async -> String?,
        fetchJWS: FetchJWS,
        fetchLegacy: FetchLegacy
    ) async throws -> AppleSignedOffer {
        guard mode == .jws else {
            return try await fetchLegacy(productId, offerId, appAccountToken)
        }
        do {
            let jws = try await fetchJWS(productId, offerId, await transactionId())
            return .jws(offerId: offerId, compactJWS: jws)
        } catch let error as RovenueError where error.kind == .notFound && error.httpStatus == 404 {
            return try await fetchLegacy(productId, offerId, appAccountToken)
        }
    }

    /// The purchase options for `offer`. Throws for legacy material StoreKit
    /// cannot take (a nonce that is not a UUID, a signature that is not
    /// Base64), and for a JWS in a build without the JWS API (unreachable:
    /// `AppleOfferSigningMode.compiled` never asks for one there).
    @available(iOS 15.0, macOS 12.0, *)
    static func purchaseOptions(for offer: AppleSignedOffer) throws -> [Product.PurchaseOption] {
        switch offer {
        case let .jws(offerId, compactJWS):
            #if compiler(>=6.2)
            return Product.PurchaseOption.promotionalOffer(offerId, compactJWS: compactJWS)
            #else
            throw RovenueError(
                kind: .storeProblem,
                message: "This build of the SDK has no StoreKit JWS promotional-offer API (needs Xcode 26)"
            )
            #endif
        case let .legacy(offerId, keyId, nonce, signatureBase64, timestamp):
            guard let nonceUUID = UUID(uuidString: nonce),
                  let signature = Data(base64Encoded: signatureBase64) else {
                throw RovenueError(
                    kind: .storeProblem,
                    message: "The promotional-offer signature from the server is malformed"
                )
            }
            return [.promotionalOffer(offerID: offerId, keyID: keyId, nonce: nonceUUID, signature: signature, timestamp: timestamp)]
        }
    }

    /// Any App Store transaction id of this customer, for the JWS
    /// `transactionId` claim (optional, recommended by Apple): the app
    /// transaction's id, else the latest transaction for the product. nil
    /// when StoreKit has neither; the JWS is then signed without it.
    @available(iOS 15.0, macOS 12.0, *)
    static func customerTransactionId(productId: String) async -> String? {
        #if compiler(>=6.2)
        if #available(iOS 16.0, macOS 13.0, *),
           let result = try? await AppTransaction.shared, case let .verified(app) = result,
           !app.appTransactionID.isEmpty {
            return app.appTransactionID
        }
        #endif
        if let latest = await Transaction.latest(for: productId), case let .verified(tx) = latest {
            return String(tx.id)
        }
        return nil
    }

    /// The ids of the subscription's win-back offers as StoreKit lists them
    /// (iOS 18 / macOS 15 and later, in builds whose SDK has the API). Empty
    /// otherwise, and when the product cannot be loaded: the purchase then
    /// reports StoreKit's own answer.
    static func winBackOfferIds(productId: String) async -> Set<String> {
        #if compiler(>=6.0)
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *),
           let product = try? await Product.products(for: [productId]).first,
           let subscription = product.subscription {
            return Set(subscription.winBackOffers.compactMap(\.id))
        }
        #endif
        return []
    }

    /// The error for a purchase StoreKit refused because of the offer itself.
    static func offerRejected(_ reason: String) -> RovenueError {
        RovenueError(
            kind: .storeProblem,
            message: "The App Store rejected the promotional offer (\(reason)). Check the offer id in App Store Connect, the In-App Purchase key and issuer id stored in Rovenue, and the server clock.",
            serverCode: RovenueError.promotionalOfferRejectedCode
        )
    }
}

extension RovenueError {
    /// `serverCode` of the error a purchase throws (kind `.storeProblem`)
    /// when StoreKit refuses the signed promotional offer: invalid signature,
    /// unknown offer id, offer price or missing parameters. Nothing was
    /// charged. Not retried with another signature form.
    public static let promotionalOfferRejectedCode = "APPLE_PROMOTIONAL_OFFER_REJECTED"

    /// `serverCode` of the error `purchase(_:promotionalOffer:)` and
    /// `purchase(_:promotionalOfferId:)` throw (kind `.invalidArgument`) for a
    /// win-back offer: StoreKit redeems win-back offers with its own win-back
    /// purchase option, never a promotional-offer signature — buy them with
    /// `purchase(_:winBackOffer:)`. Nothing was started. (The name predates
    /// win-back support and is kept for compatibility.)
    public static let winBackOfferUnsupportedCode = "WIN_BACK_OFFER_UNSUPPORTED"

    /// `serverCode` of the error `purchase(_:winBackOffer:)` and
    /// `purchase(_:winBackOfferId:)` throw (kind `.ineligible`) when the
    /// win-back offer cannot be applied: the OS is older than iOS 18 /
    /// macOS 15, the SDK was built without the API (Xcode older than 16),
    /// the discount is not a `.winBack` one or has no identifier, or StoreKit
    /// lists no win-back offer with that id for the product. The purchase
    /// sheet was not opened and nothing was charged. StoreKit refusing the
    /// offer at purchase time (`ineligibleForOffer`) is `.ineligible` without
    /// this code.
    public static let winBackOfferUnavailableCode = "WIN_BACK_OFFER_UNAVAILABLE"

    /// The `.invalidArgument` error for a win-back offer passed as a promotional one.
    static func winBackOfferUnsupported() -> RovenueError {
        RovenueError(
            kind: .invalidArgument,
            message: "Win-back offers are not promotional offers: buy them with purchase(_:winBackOffer:) (or purchase(_:winBackOfferId:)); StoreKit redeems them with its own win-back purchase option, not a promotional-offer signature.",
            serverCode: winBackOfferUnsupportedCode
        )
    }

    /// The `.ineligible` error for a win-back offer that cannot be applied.
    static func winBackOfferUnavailable(_ detail: String = "StoreKit offers no such win-back offer for this product on this device (win-back offers need iOS 18 / macOS 15)") -> RovenueError {
        RovenueError(
            kind: .ineligible,
            message: "The win-back offer is unavailable: \(detail).",
            serverCode: winBackOfferUnavailableCode
        )
    }
}
