//  Rovenue+OfferCodes.swift — the App Store's offer-code redemption sheet.
//
//  `AppStore.presentOfferCodeRedeemSheet(in:)` (iOS 16+) shows Apple's sheet
//  where a subscriber types a subscription offer code. Apple reports no
//  result to the app: a redeemed code becomes a transaction that arrives
//  through `Transaction.updates`, which the SDK already listens to and posts
//  to the server like any purchase made outside the app. Its JWS carries
//  `offerType` 3 (offer code) and the offer's reference name, which the
//  server records on the purchase.

import Foundation
import StoreKit

extension Rovenue {
    /// Presents the App Store's offer-code redemption sheet over the app's
    /// foreground window scene.
    ///
    /// Returns when the sheet closes. Apple reports nothing about the code:
    /// a redeemed code arrives as a transaction, the SDK posts it, and the
    /// new access is announced on `changes` like any other purchase.
    ///
    /// A second call while the sheet is up returns at once without a second
    /// sheet. Throws `RovenueError` with `.storeProblem` when there is no
    /// foreground window scene (background, app extension) or on macOS, and
    /// `.storeServiceUnavailable` (retryable) when StoreKit could not reach
    /// the App Store. Closing the sheet is not an error.
    ///
    /// The sheet may not appear in the simulator or on a device whose App
    /// Store account has not accepted the current terms; offer codes are
    /// redeemable in the sandbox and in TestFlight.
    @MainActor
    public func presentCodeRedemptionSheet() async throws {
        try await OfferCodeSheet.present()
        // Backstop: the redeemed transaction normally arrives through
        // `Transaction.updates`; post anything StoreKit still holds
        // unfinished in case it was delivered while no listener ran.
        Rovenue.scanUnfinishedTransactions(recovery)
    }
}

/// The sheet behind `presentCodeRedemptionSheet` and a funnel's
/// `redeem_offer_code`, which also runs in a funnel preview with no
/// configured instance.
enum OfferCodeSheet {
    @MainActor static let gate = SingleSheetGate()

    @MainActor
    static func present() async throws {
        #if os(iOS) || os(visionOS)
        guard let scene = HostScene.foregroundWindowScene() else {
            throw RovenueError(
                kind: .storeProblem,
                message: "The offer code sheet needs a foreground window scene; call it while the app is in front."
            )
        }
        let presented = try await gate.run {
            do {
                try await AppStore.presentOfferCodeRedeemSheet(in: scene)
            } catch {
                if let mapped = offerCodeSheetError(error) { throw mapped }
            }
        }
        if !presented {
            Rovenue.emit(LogEntry(level: "debug", message: "presentCodeRedemptionSheet: the sheet is already up"))
        }
        #else
        throw RovenueError(kind: .storeProblem, message: "The App Store offer code sheet exists on iOS only.")
        #endif
    }
}

/// Lets one sheet be up at a time: a call while one is presenting does not
/// present and answers `false`.
@MainActor
final class SingleSheetGate {
    private(set) var isPresenting = false

    /// Runs `present` unless a sheet is already up; `true` when it ran.
    func run(_ present: @MainActor () async throws -> Void) async throws -> Bool {
        guard !isPresenting else { return false }
        isPresenting = true
        defer { isPresenting = false }
        try await present()
        return true
    }
}

/// The error a failed redeem sheet throws, or nil for none (the user closed
/// it). A network or system failure is retryable; anything else is a store
/// problem.
func offerCodeSheetError(_ error: Error) -> RovenueError? {
    guard let storeKit = error as? StoreKitError else {
        return RovenueError(kind: .storeProblem, message: "Offer code sheet failed: \(error)")
    }
    switch storeKit {
    case .userCancelled:
        return nil
    case .networkError, .systemError:
        return RovenueError(kind: .storeServiceUnavailable, message: "Offer code sheet could not reach the App Store: \(storeKit)")
    default:
        return RovenueError(kind: .storeProblem, message: "Offer code sheet failed: \(storeKit)")
    }
}
