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
/// - Throws: `RovenueError` with `.ineligible` kind if the offer is `.introductory` or missing an identifier.
internal func resolvePromotionalOfferId(_ offer: Discount?) throws -> String? {
    guard let offer else { return nil }
    guard offer.type != .introductory else {
        throw RovenueError(kind: .ineligible, message: "Introductory offers are applied automatically; do not pass them as a promotional offer.")
    }
    guard let id = offer.identifier else {
        throw RovenueError(kind: .ineligible, message: "Promotional offer is missing an identifier.")
    }
    return id
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
    public static func configure(
        apiKey: String,
        baseUrl: String? = nil,
        logLevel: LogLevel = .warn,
        appVersion: String? = nil,
        environment: String? = nil,
        dangerouslyAllowSandboxKeyInRelease: Bool = false
    ) throws {
        try configure(
            apiKey: apiKey,
            baseUrl: baseUrl,
            logLevel: logLevel,
            appVersion: appVersion,
            environment: environment,
            releaseBuild: isReleaseBuild,
            debugBuild: isDebugBuild,
            allowSandboxKeyInRelease: dangerouslyAllowSandboxKeyInRelease
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
        hostReleaseBuild: Bool
    ) throws {
        try configure(
            apiKey: apiKey,
            baseUrl: baseUrl,
            logLevel: logLevel,
            appVersion: appVersion,
            environment: environment,
            releaseBuild: hostReleaseBuild,
            debugBuild: !hostReleaseBuild,
            allowSandboxKeyInRelease: false
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
        allowSandboxKeyInRelease: Bool
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
            isDebugBuild: debugBuild
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
        defer { lock.unlock() }
        _shared = instance
        _configuredApiBaseURL = URL(string: config.baseUrl)
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
            s.transactionListener?.cancel()
            s.transactionListener = nil
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

    private init(core: RovenueCore, bridge: ObserverBridge, funnelBridge: FunnelClaimBridge, appVersion: String?) {
        self.core = core
        self.bridge = bridge
        self.funnelBridge = funnelBridge
        self.dispatcher = Dispatcher()
        self.appVersion = appVersion
        if #available(iOS 15.0, macOS 12.0, *) {
            startTransactionListener()
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
    /// The local link is written at once; `POST /v1/identify` is
    /// best-effort — an offline/5xx failure is retried later, not thrown.
    /// Throws `.invalidArgument` for a blank id, and `.subscriberUnresolvable`
    /// when the server cannot resolve this install's subscriber (corrupt
    /// merge history): the local link stands, unsynced, until the data is
    /// repaired.
    public func identify(_ appUserId: String) async throws {
        do {
            try await dispatcher.run { [core] in
                do {
                    try core.identify(appUserId: appUserId)
                } catch let err as RovenueErrorFfi {
                    throw mapError(err)
                }
            }
        } catch {
            throw error
        }
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
            throw error
        }
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
    public func entitlementsAll() async -> [Entitlement] {
        await dispatcher.runNonThrowing { [core] in
            core.entitlementsAll()
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

    // MARK: - Refund Shield — stable per-subscriber token

    /// Returns a stable UUID for the current user. The host app passes this
    /// to `Product.purchase(options: [.appAccountToken(uuid)])` so Apple's
    /// `CONSUMPTION_REQUEST` webhook can attribute the refund request back
    /// to a known subscriber.
    ///
    /// The token is generated once per (project, current_user_scope) pair
    /// and persisted locally. It is stable across app launches and reused
    /// for every subsequent purchase. Calling `identify()` first changes
    /// the scope, so the next `getAppAccountToken()` returns a different
    /// UUID for the now-known user.
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

    /// Tell the SDK whether the app is in the foreground. While foreground,
    /// the SDK's internal polling scheduler ticks; while background, polling
    /// pauses. Call from your AppDelegate / SceneDelegate.
    public func setForeground(_ foreground: Bool) {
        core.setForeground(foreground: foreground)
    }

    /// Stop background work cleanly. Called automatically on `resetForTesting`.
    public func shutdown() {
        transactionListener?.cancel()
        transactionListener = nil
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
        let ffi: CoreOfferings
        do {
            ffi = try await dispatcher.run { [core] in
                do { return try core.getOfferings() }
                catch let err as RovenueErrorFfi { throw mapError(err) }
            }
        } catch {
            throw error
        }

        // Batch-load every Apple product id referenced across all offerings.
        let appleIds = ffi.offerings
            .flatMap { $0.packages }
            .compactMap { $0.appleProductId }
        let skProducts = await StoreKitAppleStore().products(for: Array(Set(appleIds)))

        func buildProduct(_ p: CoreOfferingProduct) async -> StoreProduct {
            guard let product = p.appleProductId.flatMap({ skProducts[$0] }) else {
                // No StoreKit product found — return config-only product.
                return mapAppleStoreProduct(core: p, period: nil, introOffer: nil,
                    promoOffers: [], groupId: nil, isFamilyShareable: false, description: nil,
                    priceString: nil, price: nil, currencyCode: nil, isEligible: nil, raw: nil,
                    formatCurrency: { _ in nil })
            }
            let offers = appleOfferInputs(from: product)
            let isEligible = try? await product.subscription?.isEligibleForIntroOffer
            let priceString = product.displayPrice
            let price = product.price
            let currencyCode = product.priceFormatStyle.currencyCode
            let fmtStyle = product.priceFormatStyle
            let formatCurrency: (Decimal) -> String? = { $0.formatted(fmtStyle) }
            return mapAppleStoreProduct(core: p, period: offers.period, introOffer: offers.intro,
                promoOffers: offers.promos, groupId: offers.groupId,
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
            return try openPreviewFunnel(payloadJson: payload, locale: locale, today: nil)
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
    @available(iOS 15.0, macOS 12.0, *)
    public func getFunnel(
        placementId: String,
        locale: String? = nil,
        restoredStateJson: String? = nil
    ) async throws -> FunnelResolution {
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
                    let session = try core.openFunnel(
                        funnel: ffi,
                        locale: locale ?? Locale.current.identifier,
                        today: nil,
                        restoredStateJson: restoredStateJson
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
        await applyStorePrices(to: session, offering: ffi.offering)

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
                configJson: ffi.configJson, requested: locale ?? Locale.current.identifier)
        ))
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
    /// The offer id is used as-is — no introductory/identifier guards are applied.
    /// The RN bridge calls this overload directly.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(_ product: StoreProduct, promotionalOfferId: String) async throws -> PurchaseResult {
        try await _purchaseCore(product: product, offerId: promotionalOfferId)
    }

    /// Purchase a `StoreProduct`. Runs the StoreKit flow, validates the JWS
    /// server-side, finishes the transaction, then returns refreshed state.
    /// Pass a `promotionalOffer` (`.promotional` or `.winBack`) to sign and
    /// inject a promotional offer; `.introductory` throws immediately.
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(_ product: StoreProduct, promotionalOffer: Discount? = nil) async throws -> PurchaseResult {
        let offerId = try resolvePromotionalOfferId(promotionalOffer)
        return try await _purchaseCore(product: product, offerId: offerId)
    }

    /// Single-sourced purchase implementation used by all public purchase overloads.
    @available(iOS 15.0, macOS 12.0, *)
    private func _purchaseCore(product: StoreProduct, offerId: String?) async throws -> PurchaseResult {
        let token = try? await getAppAccountToken()
        let flow = ApplePurchaseFlow(
            store: StoreKitAppleStore(),
            validate: { [core] jws, pid in
                try await self.dispatcher.run {
                    do {
                        return try core.postAppleReceipt(receipt: jws, productId: pid, appAccountToken: token)
                    } catch let err as RovenueErrorFfi {
                        throw mapError(err)
                    }
                }
            },
            signOffer: { [core] pid, oid, tok in
                try await self.dispatcher.run {
                    do {
                        let sig = try core.getAppleOfferSignature(productId: pid, offerId: oid, appAccountToken: tok.isEmpty ? nil : tok)
                        return AppleSignedOffer(offerId: oid, keyId: sig.keyIdentifier, nonce: sig.nonce, signatureBase64: sig.signature, timestamp: Int(sig.timestamp))
                    } catch let err as RovenueErrorFfi { throw mapError(err) }
                }
            }
        )
        return try await flow.run(productId: product.id, appAccountToken: token, promotionalOfferId: offerId)
    }

    /// Restore the user's prior purchases. Syncs with the App Store, re-posts
    /// every current entitlement's JWS for validation (best-effort), then
    /// refreshes and returns the resulting entitlement/credit state.
    @available(iOS 15.0, macOS 12.0, *)
    public func restorePurchases() async throws -> PurchaseResult {
        try? await AppStore.sync()
        for await result in Transaction.currentEntitlements {
            guard case let .verified(t) = result else { continue }
            _ = try? await dispatcher.run { [core] in
                try? core.postAppleReceipt(
                    receipt: result.jwsRepresentation,
                    productId: t.productID,
                    appAccountToken: nil
                )
            }
        }
        try await refreshEntitlements()
        let result = PurchaseResult(
            entitlements: await entitlementsAll(),
            virtualCurrencies: await virtualCurrencyBalances(),
            productId: "",
            storeTransactionId: ""
        )
        return result
    }

    /// Drain `Transaction.updates` for the lifetime of the instance, posting
    /// each verified update's JWS to the backend and finishing the transaction.
    /// Covers renewals, refunds, Ask-to-Buy approvals, and cross-device buys.
    @available(iOS 15.0, macOS 12.0, *)
    private func startTransactionListener() {
        transactionListener = Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { break }
                if case let .verified(t) = update {
                    let validated = (try? await self.dispatcher.run { [core = self.core] in
                        try core.postAppleReceipt(
                            receipt: update.jwsRepresentation,
                            productId: t.productID,
                            appAccountToken: nil
                        )
                    }) != nil
                    if validated {
                        await t.finish()
                    }
                    // validation failed → leave unfinished; StoreKit re-delivers, listener retries.
                }
            }
        }
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

    /// Claim install attribution. Returns the resolved record when an
    /// unattributed install matches a pending funnel token; returns `nil`
    /// when no match is found.
    public func claimInstall(_ params: ClaimInstallParams) async throws -> FunnelClaimResult? {
        try await dispatcher.run { [core] in
            do { return try core.claimInstall(params: params) }
            catch let err as RovenueErrorFfi { throw mapError(err) }
        }
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
