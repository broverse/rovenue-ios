//  Attribution.swift — install attribution on iOS.
//
//  Core owns the logic (first-launch tracking, the 3 s placement latch, the
//  POST to /v1/attribution). This file only reads the platform signal
//  (the AdServices token) and exposes the MMP hand-off.

import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// The mobile measurement partner whose attribution callback you forward
/// to ``Rovenue/setAttribution(provider:data:)``.
public enum AttributionProvider: String, Sendable, Equatable {
    /// AppsFlyer's conversion-data / attribution callback object.
    case appsflyer
    /// Adjust's attribution object.
    case adjust
}

/// Names used by the first-launch hand-off.
private enum AttributionConstants {
    /// DEBUG builds only: stands in for the AdServices token, which the
    /// Simulator never produces. Compiled out of every non-DEBUG build.
    static let debugTokenEnvKey = "ROVENUE_DEBUG_APPLE_ADS_TOKEN"
}

extension Rovenue {
    /// Core calls of the attribution hand-off run here, NOT on the SDK's
    /// serial dispatcher: `getFunnel` holds that queue for up to 3 s on the
    /// first-launch latch, and the submit / MMP hand-off is what releases it.
    /// Queued behind `getFunnel` they could only ever time the latch out.
    /// The Rust core is thread-safe, so these calls may overlap other core calls.
    private static let attributionDispatcher = Dispatcher(label: "dev.rovenue.sdk.attribution")

    /// Forward the attribution your MMP produced. Call it from the MMP's
    /// conversion / attribution callback, passing the callback object as-is.
    ///
    /// Core posts it to Rovenue; the server record is write-once, so a call
    /// after the install is already attributed changes nothing. Network and
    /// server failures are logged, not thrown (same as Android).
    ///
    /// - Parameters:
    ///   - provider: Which MMP produced `data`.
    ///   - data: The callback object, JSON-serialisable.
    /// - Throws: `.invalidArgument` only, when `data` cannot be serialised to JSON.
    public func setAttribution(provider: AttributionProvider, data: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(data),
              let encoded = try? JSONSerialization.data(withJSONObject: data),
              let json = String(data: encoded, encoding: .utf8)
        else {
            throw RovenueError(kind: .invalidArgument, message: "Attribution data is not JSON-serialisable.")
        }
        let failure: String? = await Self.attributionDispatcher.runNonThrowing { [core] in
            do {
                _ = try core.setAttribution(provider: provider.rawValue, dataJson: json)
                return nil
            } catch let err as RovenueErrorFfi {
                return mapError(err).message
            } catch {
                return error.localizedDescription
            }
        }
        if let failure {
            Rovenue.emit(LogEntry(level: "warn", message: "setAttribution(\(provider.rawValue)) failed: \(failure)"))
        }
    }

    /// On a pending first launch, read the AdServices token off the main
    /// actor and hand it to core. Core waits (up to 3 s) for this call before
    /// the first placement is served, so it is made even when no token could
    /// be read: skipping it would cost the full wait.
    internal func submitFirstLaunchAttribution() {
        Task.detached(priority: .userInitiated) { [core] in
            let dispatcher = Self.attributionDispatcher
            let pending = await dispatcher.runNonThrowing { core.isFirstLaunchAttributionPending() }
            guard pending else { return }
            let token = Self.readAppleAdsToken()
            await dispatcher.runNonThrowing {
                core.submitFirstLaunchSignals(signals: FirstLaunchSignals(
                    playInstallReferrer: nil,
                    referrerClickTs: nil,
                    installBeginTs: nil,
                    metaReferrerData: nil,
                    metaReferrerNonce: nil,
                    appleAdsToken: token
                ))
            }
        }
    }

    /// The AdServices attribution token, or nil when the platform gives none
    /// (Simulator, iOS before 14.3, no AdServices, the call throws).
    private static func readAppleAdsToken() -> String? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[AttributionConstants.debugTokenEnvKey],
           !override.isEmpty {
            return override
        }
        #endif
        #if canImport(AdServices)
        if #available(iOS 14.3, macOS 11.1, *) {
            return try? AAAttribution.attributionToken()
        }
        #endif
        return nil
    }
}
