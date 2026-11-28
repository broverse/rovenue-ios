//  ApplePurchaseFlow.swift — pure, testable purchase orchestration.
//
//  Sequencing guarantees:
//    1. ask the store to run the purchase;
//    2. on success, validate the JWS server-side BEFORE finishing the
//       transaction (so a validation failure leaves the transaction
//       un-finished and StoreKit re-delivers it later);
//    3. only after validation succeeds, finish() the transaction;
//    4. return the entitlements already hydrated into ReceiptResult by the
//       core (no separate cache read needed).
//
//  Store interaction (`AppleStore`) and validation (`validate`) are injected,
//  so this type is fully unit-testable with fakes — no StoreKit, no network.
//
//  Deferred / Ask-to-Buy: a `.pending` outcome is NOT an error. The flow
//  returns a `PurchaseResult` with empty entitlements and `isDeferred = true`
//  (`pendingReason = .storeApproval`) so the caller can surface the
//  appropriate UI without special-casing `catch`.
//
//  Verification deferred (spec 2026-11-22-purchase-verification-pending,
//  P1–P4): the store charged but `validate` threw a RETRYABLE error (offline,
//  timeout, 429, 5xx — after the core's own retries). The user paid, so this
//  is not an error either: the transaction stays UNFINISHED, is handed to
//  `deferVerification` (which keeps retrying it), and the flow returns
//  `isDeferred = true`, `pendingReason = .verification`. A non-retryable
//  error (receipt invalid, other 4xx) still throws, unfinished, as before.
//
//  Temporary entitlements (spec 2026-11-24-temporary-entitlements): the core
//  grants the bought product's access on the device when THIS post (the
//  purchase's first, `newPurchase: true`) fails transiently, so the
//  verification deferral reports `currentEntitlements` — temporary ones
//  marked `isTemporary` — instead of none. Never credits.

import Foundation

internal struct ApplePurchaseFlow {
    let store: AppleStore
    let validate: @Sendable (_ jws: String, _ productId: String) async throws -> ReceiptResult
    let signOffer: @Sendable (_ productId: String, _ offerId: String, _ appAccountToken: String) async throws -> AppleSignedOffer
    /// Receives a store-completed transaction whose verification failed
    /// transiently; it is still unfinished.
    var deferVerification: @Sendable (_ transaction: PendingAppleTransaction) async -> Void = { _ in }
    /// Brackets the flow's own verification of a transaction id so the
    /// recovery paths do not post it at the same time (P9).
    var claim: @Sendable (_ transactionId: String) async -> Void = { _ in }
    /// Ends the bracket; `landed` when the server accepted the receipt.
    var release: @Sendable (_ transactionId: String, _ landed: Bool) async -> Void = { _, _ in }
    /// The entitlements the app has now (the core's cache, temporary grants
    /// included), read for a verification deferral's result.
    var currentEntitlements: @Sendable () async -> [Entitlement] = { [] }

    /// `promotionalOfferId` is signed first (`signOffer`); `winBackOfferId`
    /// goes to the store as it is — StoreKit redeems win-back offers without
    /// a signature. At most one of the two.
    func run(
        productId: String,
        appAccountToken: String?,
        promotionalOfferId: String? = nil,
        winBackOfferId: String? = nil
    ) async throws -> PurchaseResult {
        var offer: AppleStoreOffer?
        switch (promotionalOfferId, winBackOfferId) {
        case (nil, nil):
            break
        case let (promotional?, nil):
            offer = .promotional(try await signOffer(productId, promotional, appAccountToken ?? ""))
        case let (nil, winBack?):
            offer = .winBack(offerId: winBack)
        case (_?, _?):
            throw RovenueError(
                kind: .invalidArgument,
                message: "A purchase applies one offer: pass a promotional offer or a win-back offer, not both."
            )
        }
        let outcome = try await store.purchase(productId: productId, appAccountToken: appAccountToken, offer: offer)
        switch outcome {
        case .userCancelled:
            throw RovenueError(kind: .purchaseCanceled, message: "The purchase was cancelled by the user")
        case .pending:
            // Deferred purchase (Ask to Buy, etc.) — not an error.
            return PurchaseResult(
                entitlements: [],
                virtualCurrencies: [:],
                productId: productId,
                storeTransactionId: "",
                isDeferred: true,
                pendingReason: .storeApproval
            )
        case .productNotFound:
            throw RovenueError(kind: .productNotAvailable, message: "The requested product is not available from the store")
        case .alreadyOwned:
            throw RovenueError(kind: .alreadyOwned, message: "You already own this product")
        case .paymentDeclined:
            throw RovenueError(kind: .paymentDeclined, message: "Payment was declined")
        case .serviceUnavailable:
            throw RovenueError(kind: .storeServiceUnavailable, message: "The App Store is temporarily unavailable")
        case .ineligible:
            throw RovenueError(kind: .ineligible, message: "You are not eligible for this offer")
        case .productNotAvailableInStorefront:
            throw RovenueError(kind: .productNotAvailable, message: "This product is not available in your storefront")
        case .winBackOfferUnavailable:
            throw RovenueError.winBackOfferUnavailable()
        case let .success(jws, transactionId, finish):
            await claim(transactionId)
            let receipt: ReceiptResult
            do {
                receipt = try await validate(jws, productId)
            } catch let error as RovenueError where error.isRetryable {
                await release(transactionId, false)
                await deferVerification(PendingAppleTransaction(
                    transactionId: transactionId,
                    jws: jws,
                    productId: productId,
                    appAccountToken: appAccountToken,
                    finish: finish
                ))
                return PurchaseResult(
                    entitlements: await currentEntitlements(),
                    virtualCurrencies: [:],
                    productId: productId,
                    storeTransactionId: transactionId,
                    isDeferred: true,
                    pendingReason: .verification
                )
            } catch {
                await release(transactionId, false)
                throw error
            }
            await finish()
            await release(transactionId, true)
            return PurchaseResult(
                entitlements: receipt.entitlements,
                virtualCurrencies: receipt.virtualCurrencies,
                productId: productId,
                storeTransactionId: transactionId
            )
        }
    }
}
