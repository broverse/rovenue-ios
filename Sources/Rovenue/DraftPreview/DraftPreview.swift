//  DraftPreview.swift — a native funnel's DRAFT, sent from the dashboard's
//  "Test on device" → "Your app", drawn inside the developer's own debug
//  build (spec docs/superpowers/specs/2026-10-16-draft-preview-in-your-own-app-design.md
//  §3.4–§3.5).
//
//  Two routes into one presenter:
//  - pairing (`enableDraftPreviews()`): the core asks the API for the
//    project's pending preview every few seconds while the app is in the
//    foreground (librovenue `preview_enable`);
//  - the deep link (`handleURL(_:)`): `<scheme>://rovenue-preview?token=…`
//    hands the token straight to the core (`preview_open_token`).
//  Either way the core follows the session (`current`, ETag) and reports
//  each new document, and the session's end, through `PreviewListener`;
//  `DraftPreviewPresenter` draws it.
//
//  The guards live in the core, before any network call: every entry
//  refuses unless the key is a Sandbox key AND this package was compiled
//  with `DEBUG` (`Rovenue.isDebugBuild`, handed over in `Config`). A
//  refusal here logs one fixed line and changes nothing. The token is never
//  logged: neither the URL nor the token is interpolated into any message.

import Foundation
#if os(iOS)
import UIKit
#endif

extension Rovenue {
    /// Receive the dashboard's draft previews in this build.
    ///
    /// After this call, **Send to my app** in the funnel builder's
    /// "Test on device" panel presents the funnel's current draft full
    /// screen, on top of whatever the app shows, within a few seconds — no
    /// URL scheme and no command needed. While the preview is open, every
    /// edit in the builder reaches it live (from the screen you are on when
    /// that screen still exists), purchases are simulated by an SDK sheet
    /// (Success / Failure / Cancel — StoreKit is never called), and nothing
    /// is recorded: no `funnel_*` event, no exposure, no webhook.
    ///
    /// Previews are a development tool, so this does nothing — beyond one
    /// warning through the SDK logger — unless the SDK was configured with
    /// a Sandbox publishable key (`rov_pk_test_…`) **and** this is a debug
    /// build (`DEBUG`). Calling it unconditionally is therefore safe: a
    /// release build never polls and never presents.
    ///
    /// The SDK checks for a pending preview while the app is in the
    /// foreground. Enabling previews tells the SDK the app's foreground
    /// state from `UIApplication`'s lifecycle notifications, as
    /// ``setForeground(_:)`` would.
    ///
    /// Draft previews present on iOS only.
    public func enableDraftPreviews() {
        draftPreview.enablePairing()
    }

    /// Open a draft preview from a deep link — the second route, for a
    /// physical device or a CI script.
    ///
    /// Declare a URL scheme for your app and forward every URL it opens:
    ///
    /// ```swift
    /// .onOpenURL { url in _ = Rovenue.shared.handleURL(url) }
    /// ```
    ///
    /// A preview link is any scheme whose host, or whose first path
    /// segment, is `rovenue-preview`, with the session token in a `token`
    /// query item — `myapp://rovenue-preview?token=…` or
    /// `myapp:///rovenue-preview?token=…`. The dashboard's "Test on device"
    /// panel copies one, and `xcrun simctl openurl booted '<link>'` opens it
    /// on a simulator.
    ///
    /// The token is handed to the SDK's preview client at once and the URL
    /// is never logged. The same guards as ``enableDraftPreviews()`` apply:
    /// with a live key or in a release build the link is refused with one
    /// warning, and nothing is presented. Works without
    /// ``enableDraftPreviews()``, for a host that wants to decide itself
    /// when a preview may open.
    ///
    /// - Parameter url: a URL the app was asked to open.
    /// - Returns: `true` when `url` is a draft-preview link — the SDK has
    ///   consumed it, so the host routes it no further (even when the
    ///   preview was refused: the token must not reach the host's own
    ///   router or logs); `false` for every other URL.
    @discardableResult
    public func handleURL(_ url: URL) -> Bool {
        guard let token = draftPreviewToken(in: url) else { return false }
        draftPreview.open(token: token)
        return true
    }
}

/// The path segment / host that marks a draft-preview deep link (spec §3.5).
let draftPreviewLinkMarker = "rovenue-preview"
/// The query item carrying the session token.
let draftPreviewTokenQueryItem = "token"

/// The token of a draft-preview link, or nil when `url` is not one.
func draftPreviewToken(in url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let marker = draftPreviewLinkMarker
    let firstSegment = components.path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
    guard components.host?.lowercased() == marker || firstSegment?.lowercased() == marker else { return nil }
    let token = components.queryItems?
        .first { $0.name == draftPreviewTokenQueryItem }?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let token, !token.isEmpty else { return nil }
    return token
}

/// The fixed lines draft previews log. Fixed on purpose: no URL, no token.
enum DraftPreviewLog {
    static let unsupportedPlatform = "Rovenue: draft previews present on iOS only; nothing will be shown."
    static let presented = "Rovenue: draft preview presented"
    static let refreshed = "Rovenue: draft preview refreshed"
    static let ended = "Rovenue: draft preview ended"
    static let closed = "Rovenue: draft preview closed"
    static let noWindow = "Rovenue: draft preview is waiting for a foreground window to present from"
}

/// Sends one draft-preview line to the SDK's log handlers. A warning (a
/// refusal) also goes to the device log, as `configure`'s own refusal does,
/// so a host with no handler still sees why nothing opens.
func logDraftPreview(_ level: String, _ message: String) {
    if level == DraftPreviewLogLevel.warn {
        NSLog("%@", message)
    }
    Rovenue.emit(LogEntry(level: level, message: message))
}

/// The SDK log levels draft previews write at.
enum DraftPreviewLogLevel {
    static let warn = "warn"
    static let info = "info"
}

/// The bridge between the core's preview client and the presenter: owns
/// the one listener registration and the foreground wiring, and turns a
/// core refusal into one warning.
final class DraftPreviewController: @unchecked Sendable {
    private let core: RovenueCore
    private let lock = NSLock()
    private var activated = false
    #if os(iOS)
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif

    init(core: RovenueCore) {
        self.core = core
    }

    deinit {
        #if os(iOS)
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        #endif
    }

    /// `enableDraftPreviews()`: turn pairing on, then start listening.
    func enablePairing() {
        guard Self.platformSupported else {
            logDraftPreview(DraftPreviewLogLevel.warn, DraftPreviewLog.unsupportedPlatform)
            return
        }
        do {
            try core.previewEnable(enabled: true)
        } catch let err as RovenueErrorFfi {
            logDraftPreview(DraftPreviewLogLevel.warn, mapError(err).message)
            return
        } catch {
            return
        }
        activate()
    }

    /// `handleURL(_:)`: follow `token`, then start listening.
    func open(token: String) {
        guard Self.platformSupported else {
            logDraftPreview(DraftPreviewLogLevel.warn, DraftPreviewLog.unsupportedPlatform)
            return
        }
        do {
            try core.previewOpenToken(token: token)
        } catch let err as RovenueErrorFfi {
            logDraftPreview(DraftPreviewLogLevel.warn, mapError(err).message)
            return
        } catch {
            return
        }
        #if os(iOS)
        // Opening a link is the person asking for it: a session they
        // closed earlier may open again.
        Task { @MainActor in DraftPreviewPresenter.shared.allowReopening() }
        #endif
        activate()
    }

    /// The host closed the preview: the core stops following it and never
    /// pairs the same session again (a new "Send to my app" mints a new one).
    func close() {
        core.previewClose()
    }

    private static var platformSupported: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Registers the listener and the foreground wiring, once per instance.
    /// Only reached after the core accepted a preview call, so a release
    /// build never gets this far.
    private func activate() {
        lock.lock()
        let first = !activated
        activated = true
        lock.unlock()
        guard first else { return }
        core.registerPreviewListener(listener: DraftPreviewListenerBridge(controller: self))
        #if os(iOS)
        DispatchQueue.main.async { [weak self] in self?.observeLifecycle() }
        #endif
    }

    #if os(iOS)
    /// The core polls only while told the app is in the foreground. The
    /// app's state now, then every change.
    @MainActor
    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.core.setForeground(foreground: true)
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.core.setForeground(foreground: false)
            },
        ]
        if UIApplication.shared.applicationState != .background {
            core.setForeground(foreground: true)
        }
    }
    #endif

    /// From the core's scheduler thread: hop to the main actor and draw.
    fileprivate func receive(_ fetch: PreviewFetch) {
        #if os(iOS)
        Task { @MainActor [weak self] in
            guard let self else { return }
            DraftPreviewPresenter.shared.receive(fetch, controller: self)
        }
        #endif
    }
}

/// The uniffi callback object. Holds the controller weakly: the core keeps
/// the listener for its whole life.
private final class DraftPreviewListenerBridge: PreviewListener, @unchecked Sendable {
    private weak var controller: DraftPreviewController?

    init(controller: DraftPreviewController) {
        self.controller = controller
    }

    func onPreviewUpdate(fetch: PreviewFetch) {
        controller?.receive(fetch)
    }
}

