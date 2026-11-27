//  Rovenue.swift — public singleton façade over the Rust core (UniFFI-generated
//  `RovenueCore`). Lifecycle, identity, entitlements, credits, receipts,
//  and the observer stream all live here.
//
//  Threading: every async method that touches `RovenueCore` flows through
//  the internal `Dispatcher` (one serial queue, qos: .userInitiated). The
//  Rust core is itself thread-safe (Arc<Mutex<…>>); the Swift-side serial
//  queue keeps in-flight calls ordered without adding contention.

import Foundation
import StoreKit

// MARK: - LogEntry

/// A single log event emitted by the Rovenue façade. Forwarded to any
/// handler registered via `setLogHandler`. The `message` field is a
/// fixed string per emit site (no user input interpolation); the `data`
/// field is currently always `nil` (reserved for future structured
/// payloads, which MUST NOT include PII).
public struct LogEntry: Sendable {
    public let level: String   // "off" | "error" | "warn" | "info" | "debug" | "trace"
    public let message: String
    public let data: [String: String]?

    public init(level: String, message: String, data: [String: String]? = nil) {
        self.level = level
        self.message = message
        self.data = data
    }
}

// MARK: - Promotional offer validation (file-scope, testable function)

/// Resolves the offer id to redeem, throwing for offers that can't be redeemed via the promotional-offer path.
/// - Parameter offer: A `Discount` to validate and extract the identifier from, or nil.
/// - Returns: The offer identifier to pass to the purchase flow, or nil if no offer was provided.
/// - Throws: `RovenueError` with `.ineligible` kind if the offer is `.introductory` or missing an identifier,
///   and with `.invalidArgument` kind (`serverCode` `RovenueError.winBackOfferUnsupportedCode`) for `.winBack`:
///   StoreKit redeems win-back offers through its own purchase option, never a promotional-offer signature —
///   buy them with `purchase(_:winBackOffer:)`.
internal func resolvePromotionalOfferId(_ offer: Discount?) throws -> String? {
    guard let offer else { return nil }
    guard offer.type != .introductory else {
        throw RovenueError(kind: .ineligible, message: "Introductory offers are applied automatically; do not pass them as a promotional offer.")
    }
    guard offer.type != .winBack else {
        throw RovenueError.winBackOfferUnsupported()
    }
    guard let id = offer.identifier else {
        throw RovenueError(kind: .ineligible, message: "Promotional offer is missing an identifier.")
    }
    return id
}

/// The id overload's twin of the `.winBack` guard above: `offerId` must not
/// name a win-back offer, either in the product's `discounts` or among the
/// win-back offers StoreKit lists for the subscription (`storeWinBackOfferIds`,
/// empty before iOS 18). Throws `.invalidArgument` with
/// `RovenueError.winBackOfferUnsupportedCode`, before anything is signed;
/// such an id is bought with `purchase(_:winBackOfferId:)`.
internal func refuseWinBackOfferId(_ offerId: String, discounts: [Discount], storeWinBackOfferIds: Set<String>) throws {
    let named = storeWinBackOfferIds.contains(offerId)
        || discounts.contains { $0.type == .winBack && $0.identifier == offerId }
    if named { throw RovenueError.winBackOfferUnsupported() }
}

public final class Rovenue: @unchecked Sendable {
    // MARK: - Singleton plumbing
    //
    // Guarded by a single NSLock. Configure-twice replaces the instance
    // (RevenueCat / Adapty pattern). Accessing `.shared` before configure()
    // triggers fatalError — silent fallback would mask developer mistakes.

    private static let lock = NSLock()
    private static var _shared: Rovenue?
    private static var _configuredApiBaseURL: URL?

    /// The API origin `configure` resolved — what a funnel's catalog fonts
    /// are fetched from (`FunnelDriver`). Nil before `configure`.
    public static var configuredApiBaseURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _configuredApiBaseURL
    }

    /// The configured instance, or nil before `configure` — for SDK paths
    /// that also run without one (the funnel views in a preview tool) and
    /// only borrow its caches when there is one.
    internal static var sharedIfConfigured: Rovenue? {
        lock.lock()
        defer { lock.unlock() }
        return _shared
    }

    public static var shared: Rovenue {
        lock.lock()
        defer { lock.unlock() }
        guard let instance = _shared else {
            fatalError("Rovenue: must call Rovenue.configure(apiKey:baseUrl:) before accessing shared")
        }
        return instance
    }

    /// Configure the SDK. Must be called before any other API.
    /// Throws `RovenueError(kind: .invalidApiKey, …)` if the api key is empty/whitespace.
    /// Calling this a second time replaces the shared instance.
    ///
    /// `appVersion` defaults to `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`
    /// so the session-event telemetry payload carries the host app's user-facing
    /// version automatically. Pass an explicit value to override (tests / unusual
    /// bundle setups).
    ///
    /// A Sandbox (`rov_pk_test_…`) key in a release build throws
    /// `RovenueError(kind: .sandboxKeyInRelease, …)` and logs one line, so a
    /// test key never ships to the App Store by accident. A build is not
    /// release when this package was compiled with `DEBUG`, when it runs on
    /// the simulator, or when the app is development-signed (its embedded
    /// provisioning profile has `get-task-allow`). A custom build
    /// configuration (`Staging`, say) whose app is not development-signed —
    /// ad-hoc, enterprise, TestFlight — counts as release. Pass
    /// `dangerouslyAllowSandboxKeyInRelease: true` only for such internal
    /// builds that must talk to the Sandbox environment.
    ///
    /// `automaticStoreMessages` (default `true`) leaves App Store messages
    /// — billing issue, price increase consent, win-back offer — to
    /// StoreKit, which shows each one when the app comes to the foreground.
    /// Pass `false` to hold them until you call `showStoreMessages(for:)`.
    public static func configure(
        apiKey: String,
        baseUrl: String? = nil,
        logLevel: LogLevel = .warn,
        appVersion: String? = nil,
        environment: String? = nil,
        dangerouslyAllowSandboxKeyInRelease: Bool = false,
        awaitMmpAttribution: Bool = false,
        automaticStoreMessages: Bool = true
    ) throws {
        try configure(
            apiKey: apiKey,
            baseUrl: baseUrl,
            logLevel: logLevel,
            appVersion: appVersion,
            environment: environment,
            releaseBuild: isReleaseBuild,
            debugBuild: isDebugBuild,
            allowSandboxKeyInRelease: dangerouslyAllowSandboxKeyInRelease,
            awaitMmpAttribution: awaitMmpAttribution,
            automaticStoreMessages: automaticStoreMessages
        )
    }

    /// Configure from a host framework (React Native, Flutter) whose own
    /// runtime decides what a release build is (`__DEV__`, `kReleaseMode`).
    /// The host's verdict replaces the native one, and there is no opt-out:
    /// those SDKs do not expose one.
    @_spi(HostFramework)
    public static func configure(
        apiKey: String,
        baseUrl: String?,
        logLevel: LogLevel,
        appVersion: String?,
        environment: String?,
        hostReleaseBuild: Bool,
        awaitMmpAttribution: Bool = false,
        automaticStoreMessages: Bool = true
    ) throws {
        try configure(
            apiKey: apiKey,
            baseUrl: baseUrl,
            logLevel: logLevel,
            appVersion: appVersion,
            environment: environment,
            releaseBuild: hostReleaseBuild,
            debugBuild: !hostReleaseBuild,
            allowSandboxKeyInRelease: false,
            awaitMmpAttribution: awaitMmpAttribution,
            automaticStoreMessages: automaticStoreMessages
        )
    }

    /// Whether the host app is a release build. Not release when any of:
    /// the package was compiled with `DEBUG`; it runs on the simulator; or
    /// the app is development-signed (its embedded provisioning profile has
    /// `get-task-allow`). The last two matter because Xcode compiles a Swift
    /// package without `DEBUG` under any build configuration not named
    /// "Debug" (a `Dev` or `Staging` configuration), although such a build is
    /// still installed from Xcode with a development profile. App Store and
    /// TestFlight builds carry no profile; ad-hoc and enterprise profiles
    /// deny `get-task-allow`: both are release.
    internal static let isReleaseBuild: Bool = {
        #if DEBUG
        return false
        #elseif targetEnvironment(simulator)
        return false
        #else
        return !isDevelopmentSigned(provisioningProfile: embeddedProvisioningProfile())
        #endif
    }()

    /// Whether this package was compiled with `DEBUG` — the one verdict
    /// draft serving trusts (spec 2026-10-17 §3.1: the core sends
    /// `X-Rovenue-Debug-Build` from it). Stricter than `!isReleaseBuild` on
    /// purpose: a Release build on the simulator, or a development-signed
    /// non-Debug configuration, never receives a draft.
    internal static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// The app's embedded provisioning profile (iOS `embedded.mobileprovision`,
    /// macOS `embedded.provisionprofile`); nil when the app carries none.
    private static func embeddedProvisioningProfile() -> Data? {
        let candidates = [
            Bundle.main.url(forResource: ProvisioningProfile.name, withExtension: ProvisioningProfile.iosExtension),
            Bundle.main.url(forResource: ProvisioningProfile.name, withExtension: ProvisioningProfile.macExtension),
        ]
        return candidates.lazy.compactMap { $0 }.compactMap { try? Data(contentsOf: $0) }.first
    }

    /// Whether a provisioning profile grants `get-task-allow` (a development
    /// profile). The profile is a CMS-signed blob whose payload is a plain
    /// XML plist: the bytes from `<?xml` through `</plist>`. Anything that is
    /// not such a profile, or does not say `true`, is not development-signed.
    internal static func isDevelopmentSigned(provisioningProfile: Data?) -> Bool {
        guard
            let profile = provisioningProfile,
            let start = profile.range(of: Data(ProvisioningProfile.plistStart.utf8)),
            let end = profile.range(of: Data(ProvisioningProfile.plistEnd.utf8), in: start.lowerBound..<profile.endIndex),
            let plist = try? PropertyListSerialization.propertyList(
                from: profile.subdata(in: start.lowerBound..<end.upperBound),
                format: nil
            ) as? [String: Any],
            let entitlements = plist[ProvisioningProfile.entitlementsKey] as? [String: Any],
            let getTaskAllow = entitlements[ProvisioningProfile.getTaskAllowKey] as? Bool
        else { return false }
        return getTaskAllow
    }

    private enum ProvisioningProfile {
        static let name = "embedded"
        static let iosExtension = "mobileprovision"
        static let macExtension = "provisionprofile"
        static let plistStart = "<?xml"
        static let plistEnd = "</plist>"
        static let entitlementsKey = "Entitlements"
        static let getTaskAllowKey = "get-task-allow"
    }

    /// The one configure body. Internal so tests can state the build kind.
    internal static func configure(
        apiKey: String,
        baseUrl: String?,
        logLevel: LogLevel,
        appVersion: String?,
        environment: String?,
        releaseBuild: Bool,
        debugBuild: Bool,
        allowSandboxKeyInRelease: Bool,
        awaitMmpAttribution: Bool = false,
        automaticStoreMessages: Bool = true
    ) throws {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RovenueError(kind: .invalidApiKey, message: "API key is missing or invalid")
        }
        do {
            try guardSandboxKeyInRelease(
                apiKey: apiKey,
                releaseBuild: releaseBuild,
                allowSandboxKeyInRelease: allowSandboxKeyInRelease
            )
        } catch let err as RovenueErrorFfi {
            let mapped = mapError(err)
            NSLog("%@", mapped.message)
            throw mapped
        }
        let resolvedVersion = appVersion ?? readBundleAppVersion()
        // Omit baseUrl → the generated Config default ("https://api.rovenue.io")
        // applies; the Rust core validates it on construction.
        var config = Config(
            apiKey: apiKey,
            logLevel: logLevel,
            appVersion: resolvedVersion,
            platform: "ios",
            environment: environment,
            isDebugBuild: debugBuild,
            awaitMmpAttribution: awaitMmpAttribution
        )
        if let baseUrl {
            config.baseUrl = baseUrl
        }
        let core: RovenueCore
        do {
            core = try RovenueCore(config: config)
        } catch let err as RovenueErrorFfi {
            throw mapError(err)
        }
        let bridge = ObserverBridge()
        core.registerObserver(obs: bridge)
        core.registerLogSink(sink: LogSinkBridge())
        let funnelBridge = FunnelClaimBridge()
        core.registerFunnelClaimListener(listener: funnelBridge)
        let instance = Rovenue(core: core, bridge: bridge, funnelBridge: funnelBridge, appVersion: resolvedVersion)
        lock.lock()
        let previous = _shared
        _shared = instance
        _configuredApiBaseURL = URL(string: config.baseUrl)
        lock.unlock()
        // Configure-twice: the replaced instance stops observing the app and
        // its scheduler pauses, so exactly one core ticks and one observer
        // reports (spec failure 8).
        previous?.stopLifecycleObservation()
        instance.lifecycle.start()
        instance.submitFirstLaunchAttribution()
        instance.prefetchOfferings()
        applyStoreMessageMode(automatic: automaticStoreMessages)
        // Photos a funnel stored and the host never released go after 7
        // days (spec A §4), off the configuring thread.
        DispatchQueue.global(qos: .utility).async { FunnelPhotoStore.sweepExpired(now: Date()) }
    }

    /// Deletes a photo a funnel stored on the device (spec A §4), once you
    /// are done with it: the `localUri` of a `FunnelPhotoRef` from
    /// `onPhotoSelected` or a presentation's `photos`. Anything outside the
    /// SDK's photo store is ignored. An unreleased photo is deleted 7 days
    /// after it was picked. Needs no `configure`.
    @discardableResult
    public static func releasePhoto(_ localUri: String) -> Bool {
        FunnelPhotoStore.release(localUri)
    }

    // -----------------------------------------------------------------
    // App-version reader — injectable for tests so we don't depend on
    // whatever Bundle.main resolves to inside an XCTest runner.
    // -----------------------------------------------------------------

    /// Test seam. Production callers leave this nil and the default
    /// Bundle.main lookup runs.
    internal static var _appVersionReaderForTesting: (() -> String?)?

    private static func readBundleAppVersion() -> String? {
        if let reader = _appVersionReaderForTesting {
            return reader()
        }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Test-only: clears the shared instance so each test runs in isolation.
    /// Internal access through `@testable import Rovenue`.
    internal static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        if let s = _shared {
            s.lifecycle.stop()
            s.transactionListener?.cancel()
            s.transactionListener = nil
            let recovery = s.recovery
            Task { await recovery.stop() }
            s.core.shutdown()
            s.bridge.finishAll()
            s.funnelBridge.finishAll()
        }
        _shared = nil
    }

    // MARK: - Log handlers
    //
    // Static dictionary (not cleared on configure-twice) so consumers
    // can install a handler once at app start and reconfigure without
    // silently losing it.

    private static let logLock = NSLock()
    private static var logHandlers: [UUID: (LogEntry) -> Void] = [:]

    /// Register a log handler that receives bridge-level events
    /// (configure / identify / refresh / receipt / shutdown).
    /// Returns an unsubscribe closure.
    @discardableResult
    public func setLogHandler(_ handler: @escaping (LogEntry) -> Void) -> () -> Void {
        let id = UUID()
        Self.logLock.lock(); Self.logHandlers[id] = handler; Self.logLock.unlock()
        return {
            Self.logLock.lock(); Self.logHandlers.removeValue(forKey: id); Self.logLock.unlock()
        }
    }

    internal static func emit(_ entry: LogEntry) {
        logLock.lock(); let snapshot = Array(logHandlers.values); logLock.unlock()
        snapshot.forEach { $0(entry) }
    }

    // MARK: - Instance state

    internal let core: RovenueCore
    internal let bridge: ObserverBridge
    internal let funnelBridge: FunnelClaimBridge
    internal let dispatcher: Dispatcher
    /// Captured at configure() time — exposed via `configuredAppVersion`,
    /// which `AppVersionTests` reads to verify the wiring without scraping
    /// the actual session-event request body.
    private let appVersion: String?

    /// Background task draining `Transaction.updates` (renewals, refunds,
    /// Ask-to-Buy approvals, cross-device purchases). Started in `init`,
    /// cancelled in `shutdown()` / `resetForTesting()`.
    private var transactionListener: Task<Void, Never>?

    /// Reports app foreground/background to the core — the host never has
    /// to call `setForeground`. Started by `configure`, stopped by
    /// `shutdown` and by a later `configure`.
    internal let lifecycle: AppLifecycleObserver

    /// StoreKit products and intro eligibility behind `getOfferings`
    /// (5 minutes; dropped on purchase / restore / identify / logOut).
    internal let productCache: StoreProductCache

    /// Posts App Store transactions the server has not verified yet — the
    /// kept `purchase()` transaction whose POST failed transiently,
    /// `Transaction.updates`, and the `Transaction.unfinished` backstop —
    /// one POST per transaction id at a time (spec 2026-11-22).
    internal let recovery: AppleTransactionRecovery

    private init(core: RovenueCore, bridge: ObserverBridge, funnelBridge: FunnelClaimBridge, appVersion: String?) {
        self.core = core
        self.bridge = bridge
        self.funnelBridge = funnelBridge
        let dispatcher = Dispatcher()
        self.dispatcher = dispatcher
        self.appVersion = appVersion
        let productCache = StoreProductCache()
        self.productCache = productCache
        let recovery = AppleTransactionRecovery(
            post: { transaction in
                _ = try await Rovenue.postAppleReceipt(
                    core, dispatcher,
                    jws: transaction.jws, productId: transaction.productId, appAccountToken: transaction.appAccountToken,
                    attribution: .buyer
                )
            },
            // The purchase may have used an intro offer.
            onLanded: { await productCache.dropEligibility() },
            // A failed retry re-reads entitlements + balances: the server may
            // have credited the purchase by S2S. Both emit change events.
            refresh: {
                await dispatcher.runNonThrowing {
                    _ = try? core.refreshEntitlements()
                    _ = try? core.refreshVirtualCurrencies()
                }
            }
        )
        self.recovery = recovery
        self.lifecycle = AppLifecycleObserver(
            onForeground: {
                // Also resets the poll cadence (a returning app refreshes at
                // once) and drains the event queue — see core `set_foreground`.
                core.setForeground(foreground: true)
                // Backstop: post anything StoreKit still holds unfinished.
                if #available(iOS 15.0, macOS 12.0, *) {
                    Rovenue.scanUnfinishedTransactions(recovery)
                }
            },
            onBackground: { finish in
                core.setForeground(foreground: false)
                // One flush so values written just before backgrounding are
                // not stuck until the next launch. Queued behind any
                // in-flight setAttributes on the serial dispatcher. Failures
                // are ignored: the durable queues retry on the next
                // foreground.
                dispatcher.submit {
                    _ = try? core.flushAttributes()
                    _ = try? core.flushSessionEvents()
                    finish()
                }
            }
        )
        if #available(iOS 15.0, macOS 12.0, *) {
            startTransactionListener()
            // At configure, also when the app launched into the background
            // (the foreground report then never fires).
            Rovenue.scanUnfinishedTransactions(recovery)
        }
    }

    /// The app version resolved at `configure()` time (bundle
    /// `CFBundleShortVersionString` or an explicit override).
    ///
    /// It was threaded into the builder paywall's render context to feed
    /// the `visibility.minAppVersion`/`maxAppVersion` gate; that renderer
    /// went in sub-project 5, so `AppVersionTests` is the only reader
    /// left. The VALUE is still live either way — `appVersion` reaches
    /// the core and rides every session-event payload — and this accessor
    /// is how a test proves `configure()` captured it without scraping a
    /// request body.
    internal var configuredAppVersion: String? { appVersion }

    /// Stop observing the app lifecycle and pause the scheduler — used when
    /// a later `configure` replaces this instance.
    private func stopLifecycleObservation() {
        lifecycle.stop { [core] in core.setForeground(foreground: false) }
        let recovery = self.recovery
        Task { await recovery.stop() }
    }

    // MARK: - Version

    public var version: String {
        sdkVersion()
    }

    // MARK: - Identity

    /// Returns the SDK's current user (anonymous ID + optional known ID).
    public func currentUser() async -> User {
        await dispatcher.runNonThrowing { [core] in
            core.currentUser()
        }
    }

    /// Associate the SDK's user with the customer's app-side user id.
    ///
    /// `identityToken` vouches for `appUserId`: your backend mints it with
    /// the secret key (`POST /v1/identity-tokens`) for the signed-in user and
    /// hands it to the app. It is valid for 15 minutes; fetch a fresh one
    /// for each identify.
    ///
    /// The local link is written at once; `POST /v1/identify` is
    /// best-effort — an offline/5xx failure is retried later (with the same
    /// token), not thrown. Throws `.invalidArgument` for a blank id or token,
    /// `.identityTokenInvalid` when the server refuses the token (expired,
    /// or minted for another user, project or environment: the bind is
    /// dropped, so identify again with a fresh token), and
    /// `.subscriberUnresolvable` when the server cannot resolve this
    /// install's subscriber (corrupt merge history): the local link stands,
    /// unsynced, until the data is repaired.
    public func identify(appUserId: String, identityToken: String) async throws {
        do {
            try await dispatcher.run { [core] in
                do {
                    try core.identify(appUserId: appUserId, identityToken: identityToken)
                } catch let err as RovenueErrorFfi {
                    throw mapError(err)
                }
            }
        } catch {
            // Some failures still change the local link (an unresolvable
            // subscriber keeps it), so the caches go either way.
            await subscriberChanged()
            throw error
        }
        await subscriberChanged()
    }

    /// Reset the SDK to an anonymous state, discarding any associated app user id.
    /// The core generates a new anonymous `rovenueId`; `appUserId` becomes nil.
    @available(iOS 15.0, macOS 12.0, *)
    public func logOut() async throws {
        do {
            try await dispatcher.run { [core] in
                do { try core.logOut() } catch let e as RovenueErrorFfi { throw mapError(e) }
            }
        } catch {
            await subscriberChanged()
            throw error
        }
        await subscriberChanged()
    }

    /// Drops the previous subscriber's store products and eligibility (before
    /// the caller's next `getOfferings` can read them), then prefetches the
    /// new subscriber's offerings in the background.
    private func subscriberChanged() async {
        await productCache.dropAll()
        prefetchOfferings()
    }

    // MARK: - Entitlements

    /// Fetch a specific entitlement from the local cache. Returns nil if it
    /// doesn't exist locally — does not hit the network.
    public func entitlement(_ id: String) async -> Entitlement? {
        await dispatcher.runNonThrowing { [core] in
            core.entitlement(id: id)
        }
    }

    /// List all cached entitlements. Does not hit the network.
    ///
    /// An entitlement with `isTemporary == true` was granted on this device
    /// for a purchase the App Store charged but Rovenue could not verify yet
    /// (offline, timeout, server error). It lasts until the receipt is
    /// verified (then the server's answer replaces it), refused, the user
    /// logs out or identifies as someone else, or 24 hours pass.
    public func entitlementsAll() async -> [Entitlement] {
        await dispatcher.runNonThrowing { [core] in
            core.entitlementsAll()
        }
    }

    /// App Store product ids of purchases the store charged that Rovenue has
    /// not verified yet. Their access may be granted temporarily
    /// (`Entitlement.isTemporary`); their credits are granted only once the
    /// server verifies the receipt, so show "on the way" rather than a final
    /// balance while a product is listed. Changes emit `.entitlementsChanged`.
    public func pendingVerificationProductIds() async -> [String] {
        await dispatcher.runNonThrowing { [core] in
            core.pendingVerificationProductIds()
        }
    }

    /// Force a refresh of the entitlements cache against the server.
    /// On success, emits `.entitlementsChanged` to subscribers of `changes`.
    public func refreshEntitlements() async throws {
        do {
            try await dispatcher.run { [core] in
                do {
                    try core.refreshEntitlements()
                } catch let err as RovenueErrorFfi {
                    throw mapError(err)
                }
            }
        } catch {
            throw error
        }
    }

    // MARK: - Virtual Currencies

    /// Read the cached virtual-currency balances (code → amount). Empty if uncached.
    public func virtualCurrencyBalances() async -> [String: Int64] {
        await dispatcher.runNonThrowing { [core] in
            core.virtualCurrencyBalances()
        }
    }

    /// Read the cached balance for a single virtual currency by code. Returns 0 if uncached.
    public func virtualCurrency(_ code: String) async -> Int64 {
        await dispatcher.runNonThrowing { [core] in
            core.virtualCurrency(code: code)
        }
    }

    /// Force a refresh of virtual-currency balances against the server.
    /// On success (when balances changed), emits `.virtualCurrenciesChanged`.
    public func refreshVirtualCurrencies() async throws {
        do {
            try await dispatcher.run { [core] in
                do {
                    try core.refreshVirtualCurrencies()
                } catch let err as RovenueErrorFfi {
                    throw mapError(err)
                }
            }
        } catch {
            throw error
        }
    }

    // MARK: - Remote Config

    /// Force a refresh of the remote config cache against the server.
    /// On success (when values changed), emits `.remoteConfigChanged`.
    public func refreshRemoteConfig() async throws {
        do {
            try await dispatcher.run { [core] in
                do {
                    try core.refreshRemoteConfig()
                } catch let err as RovenueErrorFfi {
                    throw mapError(err)
                }
            }
        } catch {
            throw error
        }
    }

    /// Read a boolean remote-config value from the local cache, returning
    /// `fallback` when the key is absent. Does not hit the network.
    public func remoteConfigBool(_ key: String, default fallback: Bool) async -> Bool {
        await dispatcher.runNonThrowing { [core] in
            core.remoteConfigBool(key: key, fallback: fallback)
        }
    }

    /// Read a string remote-config value from the local cache, returning
    /// `fallback` when the key is absent. Does not hit the network.
    public func remoteConfigString(_ key: String, default fallback: String) async -> String {
        await dispatcher.runNonThrowing { [core] in
            core.remoteConfigString(key: key, fallback: fallback)
        }
    }

    /// Read an integer remote-config value from the local cache, returning
    /// `fallback` when the key is absent. Does not hit the network.
    public func remoteConfigInt(_ key: String, default fallback: Int64) async -> Int64 {
        await dispatcher.runNonThrowing { [core] in
            core.remoteConfigInt(key: key, fallback: fallback)
        }
    }

    /// Read a double remote-config value from the local cache, returning
    /// `fallback` when the key is absent. Does not hit the network.
    public func remoteConfigDouble(_ key: String, default fallback: Double) async -> Double {
        await dispatcher.runNonThrowing { [core] in
            core.remoteConfigDouble(key: key, fallback: fallback)
        }
    }

    /// Read a raw JSON remote-config value from the local cache. Returns nil
    /// if the key is absent. Does not hit the network.
    public func remoteConfigJSON(_ key: String) async -> String? {
        await dispatcher.runNonThrowing { [core] in
            core.remoteConfigJson(key: key)
        }
    }

    /// List all cached remote-config keys. Does not hit the network.
    public func remoteConfigKeys() async -> [String] {
        await dispatcher.runNonThrowing { [core] in
            core.remoteConfigKeys()
        }
    }

    /// Return the full remote-config payload serialized as a JSON object.
    /// Does not hit the network.
    public func remoteConfigAllJSON() async -> String {
        await dispatcher.runNonThrowing { [core] in
            core.remoteConfigAllJson()
        }
    }

    /// Fetch the user's assignment for a single experiment from the local
    /// cache. Returns nil if the user is not enrolled. Does not hit the network.
    public func experiment(_ key: String) async -> ExperimentAssignment? {
        await dispatcher.runNonThrowing { [core] in
            core.experiment(key: key)
        }
    }

    /// List all of the user's experiment assignments from the local cache.
    /// Does not hit the network.
    public func experimentsAll() async -> [ExperimentAssignment] {
        await dispatcher.runNonThrowing { [core] in
            core.experimentsAll()
        }
    }

    // MARK: - Refund Shield — account token derived from rovenueId (stable across identify, changes on logOut)

    /// Returns the Apple `appAccountToken` (a lowercase UUID) for the
    /// current user, derived from the current rovenueId. The SDK's own
    /// `purchase` already passes it to
    /// `Product.purchase(options: [.appAccountToken(uuid)])`; a host app
    /// that buys through StoreKit directly passes it the same way, so the
    /// App Store notification for that purchase routes to this subscriber
    /// even when it arrives before the receipt.
    ///
    /// Stable across app launches and across `identify()`; `logOut()`
    /// mints a new rovenueId and so a new token.
    @discardableResult
    public func getAppAccountToken() async throws -> String {
        try await dispatcher.run { [core] in
            do { return try core.getOrCreateAppAccountToken() }
            catch let err as RovenueErrorFfi { throw mapError(err) }
        }
    }

    // MARK: - Refund Shield — session telemetry

    /// Record a single SDK session-lifecycle event (open / background / close).
    /// Buffered locally and flushed in batches of up to 200 every ~30s by the
    /// Rust core's `SessionDispatcher`. Best-effort: dropped on network error.
    public func recordSessionEvent(
        kind: SessionEventKind,
        occurredAt: String,
        durationMs: UInt32? = nil
    ) async throws {
        try await dispatcher.run { [core] in
            do {
                try core.recordSessionEvent(
                    kind: kind,
                    occurredAt: occurredAt,
                    durationMs: durationMs
                )
            } catch let err as RovenueErrorFfi {
                throw mapError(err)
            }
        }
    }

    /// Send a pre-serialised event envelope to the server (POST /v1/events).
    /// The caller is responsible for building the JSON envelope; this method
    /// forwards it verbatim to the Rust core and then to the API.
    public func track(envelopeJson: String) async throws {
        do {
            try await dispatcher.run { [core] in
                do {
                    try core.track(envelopeJson: envelopeJson)
                } catch let err as RovenueErrorFfi {
                    throw mapError(err)
                }
            }
        } catch {
            throw error
        }
    }

    /// Force an immediate flush of buffered session events. Returns the
    /// number of events drained. Normally callers don't invoke this — the
    /// Rust core's 30s poll covers it.
    @discardableResult
    public func flushSessionEvents() async throws -> UInt32 {
        try await dispatcher.run { [core] in
            do { return try core.flushSessionEvents() }
            catch let err as RovenueErrorFfi { throw mapError(err) }
        }
    }

    // MARK: - Subscriber attributes

    /// Queue a batch of subscriber-attribute mutations. A `nil` value deletes
    /// the key. Written locally immediately; flushed to the server in the
    /// background (30s tick / foreground / manual `flushAttributes`).
    public func setAttributes(_ attributes: [String: String?]) async throws {
        do {
            try await dispatcher.run { [core] in
                do {
                    try core.setAttributes(attributes: attributes)
                } catch let err as RovenueErrorFfi {
                    throw mapError(err)
                }
            }
        } catch {
            throw error
        }
    }

    /// Set (or, with `nil`, clear) the reserved `$email` attribute.
    public func setEmail(_ email: String?) async throws { try await setAttributes(["$email": email]) }
    /// Set (or, with `nil`, clear) the reserved `$displayName` attribute.
    public func setDisplayName(_ name: String?) async throws { try await setAttributes(["$displayName": name]) }
    /// Set (or, with `nil`, clear) the reserved `$phoneNumber` attribute.
    public func setPhoneNumber(_ phone: String?) async throws { try await setAttributes(["$phoneNumber": phone]) }
    /// iOS push token → the `$apnsTokens` reserved attribute.
    public func setPushToken(_ token: String?) async throws { try await setAttributes(["$apnsTokens": token]) }

    /// Force an immediate flush of queued attribute mutations. Returns the
    /// number of mutations sent. Normally callers don't invoke this — the
    /// Rust core's 30s poll covers it.
    @discardableResult
    public func flushAttributes() async throws -> UInt32 {
        try await dispatcher.run { [core] in
            do { return try core.flushAttributes() }
            catch let err as RovenueErrorFfi { throw mapError(err) }
        }
    }

    // MARK: - Lifecycle hooks

    /// Override the SDK's foreground state. Not needed: `configure` observes
    /// the app lifecycle itself — polling and the attribute/session flush
    /// run while the app is in front and pause in the background, and
    /// entering the background flushes once. A manual call is still honoured
    /// until the next lifecycle transition.
    public func setForeground(_ foreground: Bool) {
        core.setForeground(foreground: foreground)
    }

    /// Stop background work cleanly: stops observing the app lifecycle and
    /// stops the polling scheduler. Called automatically on `resetForTesting`.
    public func shutdown() {
        lifecycle.stop()
        transactionListener?.cancel()
        transactionListener = nil
        let recovery = self.recovery
        Task { await recovery.stop() }
        core.shutdown()
    }

    // MARK: - Purchasing
    //
    // SDK-driven StoreKit 2 purchasing. The SDK runs the StoreKit flow,
    // validates the resulting JWS against the Rovenue backend, and only then
    // finishes the transaction. The legacy "host app posts the receipt"
    // surface is gone — callers no longer touch StoreKit directly.

    /// Fetch the project's offerings and enrich each product with live
    /// StoreKit price metadata. The list of offerings (and which one is
    /// `current`) comes from the Rovenue backend; prices come from StoreKit.
    /// Products missing from StoreKit still appear, just without price fields.
    @available(iOS 15.0, macOS 12.0, *)
    public func getOfferings() async throws -> Offerings {
        let ffi = try await dispatcher.run { [core] in
            do { return try core.getOfferings() }
            catch let err as RovenueErrorFfi { throw mapError(err) }
        }
        return await hydrateOfferings(ffi)
    }

    /// Loads offerings (core + store products + eligibility) into the caches
    /// so the app's first `getOfferings` finds them ready. Fire-and-forget:
    /// never on the caller's path, never thrown (a failure is logged). The
    /// core call runs on a global queue, not the serial dispatcher, so a
    /// miss's network fetch does not hold up the caller's next SDK call.
    private func prefetchOfferings() {
        Task.detached(priority: .utility) { [weak self, core] in
            do {
                let ffi = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CoreOfferings, Swift.Error>) in
                    DispatchQueue.global(qos: .utility).async {
                        do { continuation.resume(returning: try core.getOfferings()) }
                        catch let err as RovenueErrorFfi { continuation.resume(throwing: mapError(err)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                _ = await self?.hydrateOfferings(ffi)
            } catch {
                let kind = (error as? RovenueError).map { "\($0.kind)" } ?? "unknown"
                Rovenue.emit(LogEntry(level: "warn", message: "offerings prefetch failed: \(kind)"))
            }
        }
    }

    /// Enriches the core's offerings with StoreKit price metadata and intro
    /// eligibility, both from `productCache`.
    private func hydrateOfferings(_ ffi: CoreOfferings) async -> Offerings {
        // Batch-load every Apple product id referenced across all offerings.
        let appleIds = ffi.offerings
            .flatMap { $0.packages }
            .compactMap { $0.appleProductId }
        let skProducts = await productCache.products(for: appleIds)

        func buildProduct(_ p: CoreOfferingProduct) async -> StoreProduct {
            guard let product = p.appleProductId.flatMap({ skProducts[$0] }) else {
                // No StoreKit product found — return config-only product.
                return mapAppleStoreProduct(core: p, period: nil, introOffer: nil,
                    promoOffers: [], groupId: nil, isFamilyShareable: false, description: nil,
                    priceString: nil, price: nil, currencyCode: nil, isEligible: nil, raw: nil,
                    formatCurrency: { _ in nil })
            }
            let offers = appleOfferInputs(from: product)
            let isEligible = await productCache.isEligibleForIntroOffer(product)
            let priceString = product.displayPrice
            let price = product.price
            let currencyCode = product.priceFormatStyle.currencyCode
            let formatCurrency = storeProductPriceFormatter(
                price: price, displayPrice: priceString, storefront: product.priceFormatStyle)
            return mapAppleStoreProduct(core: p, period: offers.period, introOffer: offers.intro,
                promoOffers: offers.promos, winBackOffers: offers.winBacks, groupId: offers.groupId,
                isFamilyShareable: product.isFamilyShareable, description: product.description,
                priceString: priceString, price: price, currencyCode: currencyCode,
                isEligible: isEligible, raw: product, formatCurrency: formatCurrency)
        }

        func buildOffering(_ o: CoreOffering) async -> Offering {
            var packages: [Package] = []
            for pkg in o.packages {
                packages.append(Package(identifier: pkg.packageIdentifier, packageType: packageType(forSlot: pkg.packageIdentifier),
                                        product: await buildProduct(pkg),
                                        isPromoted: pkg.isPromoted, metadataJson: pkg.metadataJson,
                                        virtualCurrencyGrants: pkg.virtualCurrencyGrants.map {
                                            VirtualCurrencyGrant(code: $0.code, amount: $0.amount, grantOn: $0.grantOn, intervalDays: $0.intervalDays,
                                                                 trialAmount: $0.trialAmount, expiresAtPeriodEnd: $0.expiresAtPeriodEnd)
                                        }))
            }
            return Offering(
                identifier: o.identifier,
                isDefault: o.isDefault,
                // Use packageIdentifier (the slot id, e.g. $rov_monthly) as
                // Package.identifier — that is the value the SDK contract
                // exposes to callers. The product's App Store SKU (the id used
                // for StoreKit lookups and purchases) is available via
                // pkg.product.id.
                packages: packages,
                metadataJson: o.metadataJson
            )
        }

        var offerings: [Offering] = []
        for o in ffi.offerings {
            offerings.append(await buildOffering(o))
        }
        let all = Dictionary(uniqueKeysWithValues: offerings.map { ($0.identifier, $0) })
        let current = ffi.current.flatMap { all[$0] }
        return Offerings(current: current, all: all)
    }

    /// Open a NON-EMITTING preview of a funnel. Intended for preview tools
    /// (the Rovenue operator apps' "Test on device"), not for shipping
    /// paywalls — a shipping app uses `getFunnel(placementId:)`.
    ///
    /// Usable WITHOUT `configure`: it needs no API key and touches no
    /// network, cache or event queue. The session is the same Rust machine
    /// a real one is — navigation, conditions, variables and actions behave
    /// identically, and purchase / restore still reach your
    /// `FunnelHostHandlers` — but it is built without an event recorder, so
    /// it emits no `funnel_*` event and no experiment exposure, and
    /// `dismiss()` is a no-op.
    ///
    /// Draw it as you would a resolved funnel's session:
    /// `RovenueFunnelView(driver: FunnelDriver(session: session, handlers: …))`. Package rows draw titled but unpriced;
    /// call `setPackagePrices(prices:)` on it to show a price or
    /// placeholder.
    ///
    /// - Parameters:
    ///   - payload: exactly the object `GET /v1/placements` serves under its
    ///     `funnel` key — the dashboard's funnel preview-document route
    ///     serves the same shape as its `payload`.
    ///   - locale: the BCP-47 locale to resolve text in; the document's
    ///     default locale is used for any string it lacks.
    /// - Throws: `RovenueError(kind: .funnelInvalid, …)` when the payload or
    ///   its `config` does not decode, `.funnelConfigUnsupported` when the
    ///   config format is newer than this SDK.
    public static func previewFunnel(
        payload: String,
        locale: String = Locale.current.identifier
    ) throws -> FunnelSession {
        do {
            return try openPreviewFunnel(payloadJson: payload, locale: locale, today: funnelLocalToday())
        } catch let err as RovenueErrorFfi {
            throw mapError(err)
        }
    }

    /// `previewFunnel(payload:locale:)` for a payload still in raw bytes
    /// (an HTTP response body).
    ///
    /// - Throws: `RovenueError(kind: .funnelInvalid, …)` when `payload` is
    ///   not UTF-8, otherwise whatever the `String` overload throws.
    public static func previewFunnel(
        payload: Data,
        locale: String = Locale.current.identifier
    ) throws -> FunnelSession {
        guard let json = String(data: payload, encoding: .utf8) else {
            throw RovenueError(kind: .funnelInvalid, message: "Funnel preview payload is not valid UTF-8")
        }
        return try previewFunnel(payload: json, locale: locale)
    }

    /// Resolve a placement to a FUNNEL — the native multi-screen experience
    /// a placement serves.
    ///
    /// `.unavailable` means the placement resolved to nothing — an empty
    /// identifier, an unknown placement, a `none` row, an experiment with no
    /// servable variant, or (in a debug build on a Sandbox key) a draft that
    /// cannot be served, with its issues. It is not an error: a shipped app
    /// must not crash because a placement was retired server-side. Each
    /// draft issue is also logged at `error` through the SDK logger.
    ///
    /// The returned session is ready to drive; hand it to
    /// `RovenueFunnelView`. `restoredStateJson` resumes a session the host
    /// stored from a previous run — the machine discards it by itself
    /// when the funnel or its revision no longer matches, so handing back a
    /// stale one is safe rather than something the caller must check. A
    /// draft never restores.
    ///
    /// `RovenueFunnelView(placementId:)` calls this itself, and keeps a
    /// draft live while it is on screen; a host that calls it directly
    /// draws a fixed snapshot.
    ///
    /// `values` are the host's values for the funnel's declared externals
    /// (spec B §7.2): trimmed, 512 characters at most, undeclared names
    /// dropped; a fresh value overrides a restored one and preselects a
    /// `defaultFrom` question the visitor has not changed. Never pass
    /// personal data — values are written to the on-device session state.
    @available(iOS 15.0, macOS 12.0, *)
    public func getFunnel(
        placementId: String,
        locale: String? = nil,
        restoredStateJson: String? = nil,
        values: [String: String] = [:]
    ) async throws -> FunnelResolution {
        // The price skeletons' 10 s are counted from here (spec
        // 2026-11-22-funnel-price-loading-state): the whole open, as the
        // visitor waits it.
        let openedAt = funnelPriceClockNow()
        // Opened in core, once (wave 7): the session holds the durable
        // event queue and the offering comes from `ffi.offering` —
        // structurally, without StoreKit prices (those are the
        // platform's job and core performs no store I/O), so there is no
        // offering JSON to hydrate here anymore — the store prices are
        // handed to the opened session instead (`applyStorePrices`).
        let opened: OpenedFunnel = try await dispatcher.run { [core] in
            do {
                switch try core.getFunnel(placementId: placementId, locale: locale) {
                case .unavailable(let reason, let issues):
                    return .unavailable(FunnelUnavailable(placementId: placementId, reason: reason, issues: issues))
                case .funnel(let ffi):
                    // No values: the open every funnel had before them.
                    let session =
                        values.isEmpty
                        ? try core.openFunnel(
                            funnel: ffi,
                            locale: locale ?? Locale.current.identifier,
                            today: funnelLocalToday(),
                            restoredStateJson: restoredStateJson
                        )
                        : try core.openFunnelWithValues(
                            funnel: ffi,
                            locale: locale ?? Locale.current.identifier,
                            today: funnelLocalToday(),
                            restoredStateJson: restoredStateJson,
                            values: values
                        )
                    return .opened(ffi, session)
                }
            } catch let err as RovenueErrorFfi { throw mapError(err) }
        }
        let ffi: CoreFunnel
        let session: FunnelSession
        switch opened {
        case .unavailable(let unavailable):
            return .unavailable(unavailable)
        case .opened(let resolved, let opened):
            (ffi, session) = (resolved, opened)
        }

        // D13: the rows are titled by core but priced by the platform. The
        // prices are handed in BEFORE the session is returned, so the first
        // screen a driver draws (`session.current()`) already carries them.
        // A store slower than the 3 s budget leaves the first screen unpriced
        // and hands the still-running lookup along with the funnel: the
        // driver drawing it applies the prices when they land (plan
        // 2026-11-22-funnel-first-open-prices D).
        // Such a funnel opens in the Pending price state (spec 2026-11-22-
        // funnel-price-loading-state): set before the session is returned, so
        // its first frame already draws skeletons and a held purchase button.
        // A store that answered in time with no price at all opens it Failed
        // instead — never an unpriced Ready paywall — and the driver still
        // owns the lookup, so "Try again" works and later prices recover it.
        var latePrices: FunnelLatePrices?
        let outcome = await applyStorePrices(to: session, offering: ffi.offering, from: productCache)
        let watched: (FunnelPriceLookup, FunnelPriceState)? =
            switch outcome {
            case .settled: nil
            case .late(let lookup): (lookup, .pending)
            case .empty(let lookup): (lookup, .failed)
            }
        if let (lookup, state) = watched, let offering = ffi.offering {
            _ = session.setPriceState(state: state)
            latePrices = FunnelLatePrices(
                lookup: lookup, state: state, deadline: openedAt + storePriceGiveUpNanoseconds,
                offering: offering, products: productCache)
        }

        return .funnel(ResolvedFunnel(
            placementIdentifier: ffi.placementIdentifier,
            placementRevision: ffi.placementRevision,
            identifier: ffi.funnelIdentifier,
            funnelId: ffi.funnelId,
            revision: ffi.revision,
            configFormatVersion: ffi.configFormatVersion,
            servedFromFallback: ffi.servedFromFallback,
            variantId: ffi.variantId,
            experimentKey: ffi.experimentKey,
            isDraft: ffi.isDraft,
            session: session,
            draftEtag: ffi.draftEtag,
            contentLocale: FunnelTextDirection.contentLocale(
                configJson: ffi.configJson, requested: locale ?? Locale.current.identifier),
            offering: ffi.offering,
            latePrices: latePrices
        ))
    }

    /// Fetch a placement and warm everything its first screen draws, so
    /// even the first open draws complete and at once: the placement
    /// response (cached for the next `getFunnel` /
    /// `RovenueFunnelView(placementId:)`), the first screen's images and
    /// video posters (decoded for this screen's width), the store prices of
    /// the funnel's packages and its fonts.
    ///
    /// Call it at app start for the placement that shows your paywall.
    /// It never throws: an unavailable placement or a network failure is
    /// logged and the open loads as it would have without it. Nothing is
    /// presented, so no funnel event is sent and no purchase is attributed
    /// to the placement by this call.
    ///
    /// - Parameters:
    ///   - placementId: the placement identifier.
    ///   - locale: the locale the funnel will open in; defaults to the
    ///     device's.
    @available(iOS 15.0, macOS 12.0, *)
    public func preloadPlacement(_ placementId: String, locale: String? = nil) async {
        let preloaded: PreloadedFunnel? = try? await dispatcher.run { [core] in
            do {
                switch try core.preloadPlacement(placementId: placementId, locale: locale) {
                case .funnel(let funnel): return PreloadedFunnel(funnel: funnel)
                case .unavailable: return PreloadedFunnel(funnel: nil)
                }
            } catch let err as RovenueErrorFfi { throw mapError(err) }
        }
        guard let funnel = preloaded?.funnel else { return }
        await warmFunnel(
            funnel, locale: locale ?? Locale.current.identifier, fontBase: Rovenue.configuredApiBaseURL,
            products: productCache)
    }

    /// What `preloadPlacement`'s core call hands back across the dispatcher.
    private struct PreloadedFunnel: @unchecked Sendable {
        let funnel: CoreFunnel?
    }

    /// What `getFunnel`'s core call hands back across the dispatcher.
    private enum OpenedFunnel: @unchecked Sendable {
        case unavailable(FunnelUnavailable)
        case opened(CoreFunnel, FunnelSession)
    }

    /// One live-refresh tick for a draft on screen (spec 2026-10-17 §3.4):
    /// the placement again, with the ETag last seen. Off the caller's
    /// thread, like every network call. Throws on a network failure — the
    /// view drops it and tries again on the next tick.
    @available(iOS 15.0, macOS 12.0, *)
    internal func refreshOpenDraft(placementId: String, etag: String?) async throws -> DraftRefresh {
        try await dispatcher.run { [core] in
            do {
                return try core.refreshOpenDraft(identifier: placementId, etag: etag)
            } catch let err as RovenueErrorFfi { throw mapError(err) }
        }
    }

    /// Parse a spec D1 bundled fallback-placements file (once, replacing any
    /// previously-loaded set) into memory so `getFunnel` can serve
    /// placements offline when both the network and disk cache miss.
    /// Synchronous — parsing is CPU-only, no I/O on this call itself
    /// (mirrors `installId()`/`hasResolvedFunnelClaim()`, not the
    /// dispatcher-routed network-touching methods above).
    ///
    /// Throws `RovenueError(kind: .invalidArgument, …)` — loudly, at call
    /// time — if the file doesn't parse as JSON or its `formatVersion`
    /// isn't literal `1`. An individual placement entry that fails to
    /// decode is skipped (not fatal) and doesn't count toward the returned
    /// total.
    ///
    /// - Returns: the number of placement entries actually loaded.
    @discardableResult
    public func setFallbackPlacements(json: String) throws -> UInt32 {
        do {
            return try core.setFallbackPlacements(json: json)
        } catch let e as RovenueErrorFfi {
            throw mapError(e)
        }
    }

    /// Convenience overload: reads `fileURL` (e.g. a bundled app resource)
    /// and forwards its contents to `setFallbackPlacements(json:)`.
    ///
    /// - Throws: whatever `Data(contentsOf:)` throws for an unreadable
    ///   file, `RovenueError(kind: .invalidArgument, …)` if the file isn't
    ///   valid UTF-8, or whatever `setFallbackPlacements(json:)` throws for
    ///   a malformed fallback file.
    @discardableResult
    public func setFallbackPlacements(fileURL: URL) throws -> UInt32 {
        let data = try Data(contentsOf: fileURL)
        guard let json = String(data: data, encoding: .utf8) else {
            throw RovenueError(
                kind: .invalidArgument,
                message: "Fallback placements file is not valid UTF-8: \(fileURL.lastPathComponent)"
            )
        }
        return try setFallbackPlacements(json: json)
    }

    /// Purchase the product backing a `Package`, optionally with a signed promotional offer.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(_ package: Package, promotionalOffer: Discount? = nil) async throws -> PurchaseResult {
        try await purchase(package.product, promotionalOffer: promotionalOffer)
    }

    /// Purchase a `StoreProduct` by promotional offer id directly.
    /// The offer id is used as-is (no introductory/identifier guards), except
    /// that a win-back offer id throws `.invalidArgument`
    /// (`RovenueError.winBackOfferUnsupportedCode`) before anything is signed,
    /// as `purchase(_:promotionalOffer:)` does for a `.winBack` discount: one
    /// named by `product.discounts`, or (iOS 18+) by the subscription's
    /// StoreKit win-back offers. Buy those with `purchase(_:winBackOfferId:)`.
    /// The React Native and Flutter bridges call this overload.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(_ product: StoreProduct, promotionalOfferId: String) async throws -> PurchaseResult {
        try refuseWinBackOfferId(
            promotionalOfferId,
            discounts: product.discounts,
            storeWinBackOfferIds: await AppleOfferSigning.winBackOfferIds(productId: product.id)
        )
        return try await _purchaseCore(product: product, offerId: promotionalOfferId)
    }

    /// Purchase a `StoreProduct`. Runs the StoreKit flow, validates the JWS
    /// server-side, finishes the transaction, then returns refreshed state.
    /// Pass a `.promotional` `promotionalOffer` to have Rovenue sign it (a JWS
    /// for `promotionalOffer(_:compactJWS:)` when the SDK is built with Xcode
    /// 26 or later, the legacy signature otherwise) and apply it.
    /// `.introductory` throws immediately (StoreKit applies it on its own);
    /// `.winBack` throws `.invalidArgument` (`RovenueError.winBackOfferUnsupportedCode`):
    /// a win-back offer is not a promotional offer — buy it with
    /// `purchase(_:winBackOffer:)`.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(_ product: StoreProduct, promotionalOffer: Discount? = nil) async throws -> PurchaseResult {
        let offerId = try resolvePromotionalOfferId(promotionalOffer)
        return try await _purchaseCore(product: product, offerId: offerId)
    }

    // MARK: - Win-back offers (iOS 18 / macOS 15+)

    /// Purchase a subscription with one of its StoreKit win-back offers — a
    /// discount Apple lets a lapsed subscriber redeem. `winBackOffer` is a
    /// `.winBack` entry of `product.discounts`; pass one
    /// `eligibleWinBackOffers(for:)` returned. StoreKit applies it with
    /// `Product.PurchaseOption.winBackOffer(_:)`: nothing is signed and no
    /// server call happens before the purchase sheet. The result, the
    /// receipt validation, Ask to Buy and a deferred verification behave as
    /// for any `purchase`.
    ///
    /// Throws `.ineligible` with `RovenueError.winBackOfferUnavailableCode`,
    /// before the sheet, when the discount is not `.winBack` or has no id,
    /// on iOS older than 18 / macOS older than 15, or when StoreKit lists no
    /// such offer for the product. StoreKit refusing a customer who is not
    /// eligible is `.ineligible` too.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(_ product: StoreProduct, winBackOffer: Discount) async throws -> PurchaseResult {
        let offerId = try resolveWinBackOfferId(winBackOffer)
        return try await _purchaseCore(productId: product.id, offerId: nil, winBackOfferId: offerId)
    }

    /// Purchase the product backing a `Package` with one of its win-back
    /// offers; see `purchase(_:winBackOffer:)` for a `StoreProduct`.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(_ package: Package, winBackOffer: Discount) async throws -> PurchaseResult {
        try await purchase(package.product, winBackOffer: winBackOffer)
    }

    /// Purchase a `StoreProduct` with the StoreKit win-back offer whose id
    /// is `winBackOfferId` — the id form of `purchase(_:winBackOffer:)`,
    /// which the React Native and Flutter bridges call. An id StoreKit does
    /// not list for the product throws `.ineligible` with
    /// `RovenueError.winBackOfferUnavailableCode` before the sheet.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(_ product: StoreProduct, winBackOfferId: String) async throws -> PurchaseResult {
        try await _purchaseCore(productId: product.id, offerId: nil, winBackOfferId: winBackOfferId)
    }

    /// The win-back offers of `product` this customer may redeem now, best
    /// first (Apple's order): the product's `.winBack` discounts whose ids
    /// the subscription group's renewal info lists as eligible
    /// (`RenewalInfo.eligibleWinBackOfferIDs`). Empty before iOS 18 /
    /// macOS 15, for a customer who never subscribed or is subscribed now,
    /// and when StoreKit cannot answer. Never throws. Cached for 5 minutes
    /// and re-read after a purchase, restore or renewal.
    @available(iOS 15.0, macOS 12.0, *)
    public func eligibleWinBackOffers(for product: StoreProduct) async -> [Discount] {
        // A product StoreKit priced lists its win-back offers itself.
        if product.rawStoreProduct != nil, !product.discounts.contains(where: { $0.type == .winBack }) { return [] }
        let storeProduct: Product?
        if let raw = product.rawStoreProduct {
            storeProduct = raw
        } else {
            storeProduct = await productCache.products(for: [product.id])[product.id]
        }
        guard let storeProduct else { return [] }
        let catalog = winBackCatalog(
            product, storeWinBacks: appleOfferInputs(from: storeProduct).winBacks,
            currencyCode: storeProduct.priceFormatStyle.currencyCode)
        guard !catalog.isEmpty else { return [] }
        let ids = await productCache.eligibleWinBackOfferIds(productId: product.id) {
            await storeKitEligibleWinBackOfferIds(storeProduct)
        }
        return eligibleWinBackDiscounts(catalog, eligibleOfferIds: ids)
    }

    /// The win-back offers of the package's product this customer may
    /// redeem now; see `eligibleWinBackOffers(for:)` for a `StoreProduct`.
    @available(iOS 15.0, macOS 12.0, *)
    public func eligibleWinBackOffers(for package: Package) async -> [Discount] {
        await eligibleWinBackOffers(for: package.product)
    }

    #if os(iOS) || os(macOS)
    /// Buys what an App Store purchase intent asks for — a purchase started
    /// on the App Store (a promoted in-app purchase, or an App Store win-back
    /// offer) that StoreKit hands to the app through
    /// `PurchaseIntent.intents`. With Streamlined Purchasing on (App Store
    /// Connect's default) StoreKit completes App Store win-back purchases
    /// itself and the transaction reaches the SDK's `Transaction.updates`
    /// listener: nothing to do. With it off, the app listens and calls this:
    ///
    ///     for await intent in PurchaseIntent.intents {
    ///         _ = try? await Rovenue.shared.purchase(intent)
    ///     }
    ///
    /// The intent's win-back offer (iOS 18 / macOS 15) is redeemed as in
    /// `purchase(_:winBackOfferId:)`, a promotional one is signed as in
    /// `purchase(_:promotionalOfferId:)`; an introductory offer is applied
    /// by StoreKit itself.
    @available(iOS 16.4, macOS 14.4, *)
    public func purchase(_ intent: PurchaseIntent) async throws -> PurchaseResult {
        var type: DiscountType?
        var offerId: String?
        #if compiler(>=6.0)
        if #available(iOS 18.0, macOS 15.0, *), let offer = intent.offer {
            offerId = offer.id
            if offer.type == .introductory { type = .introductory }
            else if offer.type == .promotional { type = .promotional }
            else if offer.type == .winBack { type = .winBack }
        }
        #endif
        let productId = intent.product.id
        switch purchaseIntentOffer(type: type, id: offerId) {
        case .none:
            return try await _purchaseCore(productId: productId, offerId: nil)
        case let .promotional(id):
            return try await _purchaseCore(productId: productId, offerId: id)
        case let .winBack(id):
            return try await _purchaseCore(productId: productId, offerId: nil, winBackOfferId: id)
        }
    }
    #endif

    /// Buys an App Store product by id — what a presented funnel's
    /// purchase runs (`FunnelPresentation`), which knows the package's
    /// product id from the served offering but holds no `StoreProduct`.
    /// `winBackOfferId`, when set, is redeemed as in
    /// `purchase(_:winBackOfferId:)`.
    @available(iOS 15.0, macOS 12.0, *)
    func purchase(productId: String, winBackOfferId: String? = nil) async throws -> PurchaseResult {
        try await _purchaseCore(productId: productId, offerId: nil, winBackOfferId: winBackOfferId)
    }

    @available(iOS 15.0, macOS 12.0, *)
    private func _purchaseCore(product: StoreProduct, offerId: String?) async throws -> PurchaseResult {
        try await _purchaseCore(productId: product.id, offerId: offerId)
    }

    /// Single-sourced purchase implementation used by all public purchase
    /// overloads. `offerId` is a promotional offer (signed first),
    /// `winBackOfferId` a win-back offer (never signed); at most one.
    @available(iOS 15.0, macOS 12.0, *)
    private func _purchaseCore(productId: String, offerId: String?, winBackOfferId: String? = nil) async throws -> PurchaseResult {
        // Never buy without the account token: the server routes a
        // notification that beats the receipt by it. Derivation is local and
        // only fails on a broken core, which a retry would not heal (P8).
        let token: String
        do {
            token = try await getAppAccountToken()
        } catch {
            let failure = RovenueError(
                kind: .internal,
                message: "The App Store account token could not be derived; the purchase was not started (\(error.localizedDescription))",
                serverCode: RovenueError.appAccountTokenUnavailableCode
            )
            Rovenue.emit(LogEntry(level: "error", message: "purchase(\(productId)) not started: app account token unavailable: \(error.localizedDescription)"))
            FunnelStoreOutcome.of(failure).post()
            throw failure
        }
        let recovery = self.recovery
        var flow = ApplePurchaseFlow(
            store: StoreKitAppleStore(),
            validate: Rovenue.firstPurchasePost(appAccountToken: token) { [core, dispatcher] jws, pid, tok, attribution, newPurchase in
                try await Rovenue.postAppleReceipt(
                    core, dispatcher, jws: jws, productId: pid, appAccountToken: tok, attribution: attribution,
                    newPurchase: newPurchase)
            },
            signOffer: { [core, dispatcher] pid, oid, tok in
                try await AppleOfferSigning.sign(
                    mode: .compiled,
                    productId: pid,
                    offerId: oid,
                    appAccountToken: tok,
                    transactionId: { await AppleOfferSigning.customerTransactionId(productId: pid) },
                    fetchJWS: { pid, oid, txId in
                        try await dispatcher.run {
                            do { return try core.getAppleOfferJws(productId: pid, offerId: oid, transactionId: txId) }
                            catch let err as RovenueErrorFfi { throw mapError(err) }
                        }
                    },
                    fetchLegacy: { pid, oid, tok in
                        try await dispatcher.run {
                            do {
                                let sig = try core.getAppleOfferSignature(productId: pid, offerId: oid, appAccountToken: tok.isEmpty ? nil : tok)
                                return .legacy(offerId: oid, keyId: sig.keyIdentifier, nonce: sig.nonce, signatureBase64: sig.signature, timestamp: Int(sig.timestamp))
                            } catch let err as RovenueErrorFfi { throw mapError(err) }
                        }
                    }
                )
            }
        )
        flow.currentEntitlements = { [core, dispatcher] in
            await dispatcher.runNonThrowing { core.entitlementsAll() }
        }
        flow.claim = { id in await recovery.claim(id) }
        flow.release = { id, landed in await recovery.release(id, landed: landed) }
        // Paid but not verified (P1–P3): keep the unfinished transaction and
        // keep posting it; it is finished once the server accepts it.
        flow.deferVerification = { transaction in
            Rovenue.emit(LogEntry(level: "warn", message: "purchase(\(transaction.productId)) verification deferred; retrying in the background"))
            await recovery.scheduleRetry(transaction)
        }
        do {
            let result = try await flow.run(
                productId: productId, appAccountToken: token,
                promotionalOfferId: offerId, winBackOfferId: winBackOfferId
            )
            // An intro or win-back offer may be used up: the next
            // getOfferings / eligibleWinBackOffers re-reads it.
            await productCache.dropEligibility()
            FunnelStoreOutcome.of(result).post()
            return result
        } catch {
            // A purchase that failed after StoreKit charged (validation)
            // may still have used the intro offer.
            await productCache.dropEligibility()
            // A funnel that asked for this purchase plays its outcome
            // (success / a real failure; nothing for a cancelled sheet). A
            // verification deferral returned above as a result, so it plays
            // `.quiet` there, never a failure (P15).
            FunnelStoreOutcome.of(error).post()
            throw error
        }
    }

    /// The purchase flow's FIRST post of a transaction StoreKit just
    /// completed — every purchase path's, a win-back offer, a purchase intent
    /// and a funnel's included: presented as the buyer, as a new purchase, so
    /// a transient failure grants the product's access temporarily (spec
    /// 2026-11-24-temporary-entitlements). Retries post without that flag.
    static func firstPurchasePost(
        appAccountToken token: String,
        post: @escaping @Sendable (_ jws: String, _ productId: String, _ appAccountToken: String?,
                                   _ attribution: ReceiptAttribution, _ newPurchase: Bool) async throws -> ReceiptResult
    ) -> @Sendable (_ jws: String, _ productId: String) async throws -> ReceiptResult {
        { jws, pid in try await post(jws, pid, token, .buyer, true) }
    }

    /// POST an App Store JWS; FFI errors surface as `RovenueError`. The one
    /// receipt call behind `purchase`, the recovery paths and
    /// `restorePurchases`. `appAccountToken` is the token the transaction
    /// carries. `.buyer` presents the purchase as the identity that bought
    /// it when this install recorded one (a log out since does not move it
    /// to the new identity); `.presenter` — a restore — always presents it
    /// as the current identity.
    private static func postAppleReceipt(
        _ core: RovenueCore,
        _ dispatcher: Dispatcher,
        jws: String,
        productId: String,
        appAccountToken: String?,
        attribution: ReceiptAttribution,
        newPurchase: Bool = false
    ) async throws -> ReceiptResult {
        try await dispatcher.run {
            do {
                return try core.postAppleReceipt(
                    receipt: jws, productId: productId, appAccountToken: appAccountToken, attribution: attribution,
                    newPurchase: newPurchase)
            } catch let err as RovenueErrorFfi {
                throw mapError(err)
            }
        }
    }

    /// Restore the user's prior purchases. Syncs with the App Store, posts
    /// every current entitlement's JWS for the current user, then refreshes
    /// and returns the resulting entitlement/credit state. The server moves
    /// a purchase another subscriber holds per the project's transfer
    /// behavior, so a reinstall or a new device gets its access back.
    ///
    /// Throws when the App Store sync or a receipt POST failed and no
    /// entitlement is active afterwards — a retryable error when trying
    /// again can help, otherwise the server's refusal (e.g.
    /// `RECEIPT_IN_USE`). With nothing owned, with access, or when the user
    /// only cancelled the App Store sign-in, it returns normally.
    @available(iOS 15.0, macOS 12.0, *)
    public func restorePurchases() async throws -> PurchaseResult {
        let flow = AppleRestoreFlow(
            sync: { try await AppStore.sync() },
            owned: {
                var owned: [OwnedAppleTransaction] = []
                for await result in Transaction.currentEntitlements {
                    guard case let .verified(transaction) = result else { continue }
                    owned.append(OwnedAppleTransaction(jws: result.jwsRepresentation, productId: transaction.productID))
                }
                return owned
            },
            // A restore is for the current user, whoever bought it: the
            // project's transfer behavior decides what moves.
            post: { [core, dispatcher] transaction in
                _ = try await Rovenue.postAppleReceipt(
                    core, dispatcher, jws: transaction.jws, productId: transaction.productId, appAccountToken: nil,
                    attribution: .presenter)
            },
            refresh: { [productCache] in
                await productCache.dropEligibility()
                try await self.refreshEntitlements()
                return await self.entitlementsAll()
            }
        )
        let entitlements: [Entitlement]
        do {
            entitlements = try await flow.run()
        } catch {
            // Success / a real failure; nothing for a cancelled task.
            if !(error is CancellationError) { FunnelStoreOutcome.of(error).post() }
            throw error
        }
        let result = PurchaseResult(
            entitlements: entitlements,
            virtualCurrencies: await virtualCurrencyBalances(),
            productId: "",
            storeTransactionId: ""
        )
        FunnelStoreOutcome.success.post()
        return result
    }

    /// Drain `Transaction.updates` for the lifetime of the instance, posting
    /// each verified update's JWS to the backend and finishing the transaction.
    /// Covers renewals, refunds, Ask-to-Buy approvals, and cross-device buys.
    /// Posts through `recovery`, so a transaction the kept-purchase retry or
    /// the `unfinished` scan is posting is not sent twice at once (P9).
    @available(iOS 15.0, macOS 12.0, *)
    private func startTransactionListener() {
        transactionListener = Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { break }
                if let pending = Rovenue.pendingTransaction(update) {
                    // Validation failed → left unfinished; StoreKit
                    // re-delivers and the `unfinished` scan retries it.
                    await self.recovery.attempt(pending)
                    // A renewal, Ask-to-Buy approval or cross-device buy may
                    // have used an intro offer.
                    await self.productCache.dropEligibility()
                }
            }
        }
    }

    /// Posts every verified transaction StoreKit still holds unfinished — the
    /// backstop at configure and on each foreground (P5, P6). Right after a
    /// purchase `Transaction.unfinished` is eventually consistent and may
    /// also yield what `updates` yields; `recovery` dedupes by id.
    @available(iOS 15.0, macOS 12.0, *)
    static func scanUnfinishedTransactions(_ recovery: AppleTransactionRecovery) {
        Task.detached(priority: .utility) {
            for await result in Transaction.unfinished {
                if let pending = pendingTransaction(result) {
                    await recovery.attempt(pending)
                }
            }
        }
    }

    /// A verified StoreKit transaction as recovery posts it; nil when
    /// StoreKit could not verify it (never posted, never finished).
    @available(iOS 15.0, macOS 12.0, *)
    private static func pendingTransaction(_ result: VerificationResult<Transaction>) -> PendingAppleTransaction? {
        guard case let .verified(transaction) = result else { return nil }
        return PendingAppleTransaction(
            transactionId: String(transaction.id),
            jws: result.jwsRepresentation,
            productId: transaction.productID,
            // The token the transaction carries names its buyer: the core
            // presents it as that identity when this install recorded it.
            appAccountToken: transaction.appAccountToken?.uuidString.lowercased(),
            finish: { await transaction.finish() }
        )
    }

    // MARK: - Observer stream

    /// AsyncStream of cache-change notifications. Each access returns a new
    /// stream — subscribing twice (one per view, say) is supported. Stream
    /// termination on cancel deregisters the subscriber automatically.
    public var changes: AsyncStream<ChangeEvent> {
        bridge.subscribe()
    }

    // MARK: - Funnel Claim

    /// AsyncStream of resolved funnel-claim events. Each access returns a new
    /// stream. Mirrors `changes` / `ObserverBridge` but carries a
    /// `FunnelClaimResult` payload.
    public var funnelClaims: AsyncStream<FunnelClaimResult> {
        funnelBridge.subscribe()
    }

    /// Returns the SDK's stable install ID (a device-scoped anonymous
    /// identifier generated once and persisted locally). Synchronous —
    /// backed by the Rust MMKV store.
    public func installId() -> String {
        core.installId()
    }

    /// Whether this install has already successfully claimed a funnel token
    /// (deep-link / QR-code / email attribution). A synchronous local read
    /// backed by persisted install state — no network call. Use this to gate
    /// first-launch attribution orchestration so `claimFunnelToken`/
    /// `claimInstall`/`claimViaEmail` only run once per install, even across
    /// app restarts.
    public func hasResolvedFunnelClaim() -> Bool {
        core.hasResolvedFunnelClaim()
    }

    /// Claim a funnel token (from a deep-link or QR code). Returns the
    /// resolved subscriber record immediately and also emits on `funnelClaims`.
    public func claimFunnelToken(_ token: String) async throws -> FunnelClaimResult {
        try await dispatcher.run { [core] in
            do { return try core.claimFunnelToken(token: token) }
            catch let err as RovenueErrorFfi { throw mapError(err) }
        }
    }

    /// Claim install attribution — the deferred match for a fresh install
    /// whose buyer paid on a web funnel and opened its universal link on this
    /// device. The SDK reads the device context itself (language, timezone,
    /// screen, model). Returns the resolved record when the install matches a
    /// pending funnel token; returns `nil` when no match is found.
    public func claimInstall() async throws -> FunnelClaimResult? {
        try await claimInstall(ClaimDeviceContext.empty)
    }

    /// `claimInstall()` with caller-supplied values. Any empty field is
    /// filled from the device, exactly as the no-argument form does.
    public func claimInstall(_ params: ClaimInstallParams) async throws -> FunnelClaimResult? {
        let filled = await ClaimDeviceContext.fill(params)
        return try await dispatcher.run { [core] in
            do { return try core.claimInstall(params: filled) }
            catch let err as RovenueErrorFfi { throw mapError(err) }
        }
    }

    /// Claim the token the web funnel's success screen copied to the
    /// pasteboard (`rovenue-funnel:<token>`). Call it from a user gesture:
    /// iOS asks the user before an app reads the pasteboard. Returns `nil`
    /// when the pasteboard holds no funnel marker; after a successful claim
    /// the marker is cleared, and anything else on the pasteboard is left alone.
    public func claimFromClipboard() async throws -> FunnelClaimResult? {
        guard let token = await FunnelClipboard.token() else { return nil }
        let result = try await claimFunnelToken(token)
        await FunnelClipboard.clearMarker()
        return result
    }

    /// Claim by email address. The backend matches an install token to the
    /// provided email; completes without returning a value (resolution is
    /// notified via the `funnelClaims` stream).
    public func claimViaEmail(_ email: String) async throws {
        try await dispatcher.run { [core] in
            do { try core.claimViaEmail(email: email) }
            catch let err as RovenueErrorFfi { throw mapError(err) }
        }
    }
}

/// The visitor's local calendar date, `YYYY-MM-DD` — what a funnel session
/// is opened with: the date conditions' "today" and the session's
/// `started_on`, captured once at session start (spec 2026-11-10 NE §4.5,
/// NE-D11), from which a chart's end date is computed. The core reads no
/// time zone of its own, so the device's is passed in.
func funnelLocalToday(_ date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
    var local = calendar
    local.timeZone = TimeZone.current
    let day = local.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
}
