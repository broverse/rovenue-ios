//  RovenueFunnelView.swift — the entry point and the step driver.
//
//  The driver owns the session and applies effects; the view is thin. No
//  block view ever holds a session, and the drawer never navigates a URL
//  itself — that goes to the host.

import Foundation
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// The seam a test fakes. The real conformance wraps the uniffi
/// `FunnelSession`; every method returns the step that call produced.
public protocol FunnelSessionDriving {
    func current() -> FunnelStep
    func tap(_ path: String) -> FunnelStep
    func submit(_ blockId: String, _ answerJson: String) -> FunnelStep
    func selectPackage(_ identifier: String) -> FunnelStep
    func back() -> FunnelStep
    func dismiss()
    func stateJson() -> String
    /// Hand in the device's colour scheme; the session redraws the current
    /// screen in it (the funnel's dark palette when its dark mode is on).
    func setColorScheme(_ scheme: FunnelColorScheme) -> FunnelStep
}

extension FunnelSessionDriving {
    /// A session that has no colour scheme to take — a test's fake —
    /// keeps drawing what it drew.
    public func setColorScheme(_ scheme: FunnelColorScheme) -> FunnelStep {
        current()
    }
}

/// The real conformance. The generated `FunnelSession` already has every
/// method; this only reconciles the argument labels, so there is no logic
/// here to get wrong.
extension FunnelSession: FunnelSessionDriving {
    public func tap(_ path: String) -> FunnelStep {
        tap(actionPath: path)
    }

    public func submit(_ blockId: String, _ answerJson: String) -> FunnelStep {
        submit(blockId: blockId, answerJson: answerJson)
    }

    public func selectPackage(_ identifier: String) -> FunnelStep {
        selectPackage(identifier: identifier)
    }

    /// Redraws the current screen in the device's colour scheme — the
    /// generated `setColorScheme(scheme:)`, relabelled.
    public func setColorScheme(_ scheme: FunnelColorScheme) -> FunnelStep {
        setColorScheme(scheme: scheme)
    }
}

/// What the host wants to be told about. Every handler is optional: a host
/// that does not care about URLs is a legitimate host, and an effect with
/// no handler is dropped rather than fatal.
///
/// The lifecycle events (spec 2026-10-17 §3.5a) are the same on every SDK:
/// `onLoaded`, `onUnavailable` and `onError` come from
/// `RovenueFunnelView(placementId:)`, which resolves the placement itself;
/// `onScreenChanged`, `onCompleted` and `onDismissed` come from the driver,
/// so they fire for a driver a host built itself too.
public struct FunnelHostHandlers {
    public var onUrl: ((String) -> Void)?
    public var onAlert: ((String?, String, String?) -> Void)?
    public var onCustom: ((String, String) -> Void)?
    public var onPurchase: ((String) -> Void)?
    public var onRestore: (() -> Void)?
    /// The first screen is on screen; in a draft, again after every
    /// live-refresh rebuild.
    public var onLoaded: ((FunnelLoaded) -> Void)?
    /// The view has nothing to draw: the previous funnel is cleared. A
    /// draft that cannot be served reports `.draftIssues` with its issues
    /// (and the view draws them); a draft deleted while on screen reports
    /// `.noTarget`.
    public var onUnavailable: ((FunnelUnavailable) -> Void)?
    /// Resolving failed (a network failure with no cache or fallback, an
    /// invalid or unsupported config), or a screen did not decode
    /// (`RovenueError.funnelScreenUndecodableCode`). The previous funnel is
    /// cleared. A cancelled resolve is never reported.
    public var onError: ((RovenueError) -> Void)?
    /// The visible screen changed, including the first.
    public var onScreenChanged: ((FunnelScreen) -> Void)?
    /// The funnel reached its end. Never fires together with `onDismissed`.
    public var onCompleted: (() -> Void)?
    /// The visitor dismissed the funnel (its close action). Never fires
    /// together with `onCompleted`, and not for the host's own `close()`.
    public var onDismissed: (() -> Void)?

    public init(
        onUrl: ((String) -> Void)? = nil,
        onAlert: ((String?, String, String?) -> Void)? = nil,
        onCustom: ((String, String) -> Void)? = nil,
        onPurchase: ((String) -> Void)? = nil,
        onRestore: (() -> Void)? = nil,
        onLoaded: ((FunnelLoaded) -> Void)? = nil,
        onUnavailable: ((FunnelUnavailable) -> Void)? = nil,
        onError: ((RovenueError) -> Void)? = nil,
        onScreenChanged: ((FunnelScreen) -> Void)? = nil,
        onCompleted: (() -> Void)? = nil,
        onDismissed: (() -> Void)? = nil
    ) {
        self.onUrl = onUrl
        self.onAlert = onAlert
        self.onCustom = onCustom
        self.onPurchase = onPurchase
        self.onRestore = onRestore
        self.onLoaded = onLoaded
        self.onUnavailable = onUnavailable
        self.onError = onError
        self.onScreenChanged = onScreenChanged
        self.onCompleted = onCompleted
        self.onDismissed = onDismissed
    }
}

/// Encodes an answer into the shape `funnel_core::answer::AnswerValue`
/// decodes from.
///
/// A whole number must not become `3.0`. funnel-core compares numbers as f64
/// so a branch would still match, but the same value is written into
/// subscriber attributes, where `3.0` is not `3`.
func encodeAnswer(_ answer: QuestionAnswer) -> String {
    switch answer {
    case .text(let s):
        return (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "null"
    case .number(let n):
        return n == n.rounded() && n.isFinite ? String(Int(n)) : String(n)
    case .bool(let b):
        return b ? "true" : "false"
    case .list(let items):
        return (try? String(data: JSONEncoder().encode(items), encoding: .utf8)) ?? "[]"
    case .contact(let fields):
        // Sorted so the wire shape is stable; an unordered dictionary
        // would make an otherwise identical answer look like a change.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? String(data: encoder.encode(fields), encoding: .utf8)) ?? "{}"
    }
}

/// Drives one funnel: holds the session, publishes the screen, applies
/// effects.
public final class FunnelDriver: ObservableObject {
    // Internal: the VIEW reads this. A host hands the driver to
    // RovenueFunnelView and never touches a RenderScreen itself.
    @Published private(set) var screen: RenderScreen?
    /// How `screen` was reached — the step's direction and transition, and
    /// the screen being left, drawn while the transition runs. Assigned
    /// with `screen`, in the same update.
    @Published private(set) var arrival = FunnelArrival.first
    @Published public private(set) var finished = false
    /// Bumped when a catalog font a screen draws in has been registered —
    /// the view reads it, so it redraws in the funnel's own faces.
    @Published private(set) var fontsVersion = 0
    /// The page a held tap landed on: every refused answer on it shows its
    /// reason (`funnelRevealInvalid`). Cleared when the page changes, so a
    /// new page — or a return to this one — starts with nothing shown.
    @Published private(set) var revealedScreenId: String?
    /// Which way the funnel's copy reads, set by `RovenueFunnelView
    /// (placementId:)` from the funnel's own locale
    /// (`FunnelTextDirection`). nil — a driver the host built — inherits
    /// the host's direction.
    var layoutDirection: LayoutDirection?

    private let session: FunnelSessionDriving
    private let handlers: FunnelHostHandlers
    /// Whether the view has shown this driver yet: screen changes are
    /// reported from the first appearance on, so a host hears `onLoaded`
    /// before the first `onScreenChanged` (spec §3.5a).
    private var presented = false
    /// The screen last reported through `onScreenChanged`.
    private var reportedScreenId: String?
    /// Internal: the placement view's `onLoaded`, fired once, as the
    /// driver's first screen goes on screen.
    var onFirstPresented: (() -> Void)?
    /// The API origin the funnel's catalog fonts are fetched from
    /// (`FunnelFonts.swift`); nil draws every family in the system face.
    private let fontBaseURL: URL?
    private let autoAdvanceScheduler: AutoAdvanceScheduling
    /// Set when the funnel asks for a purchase or restore: the haptics its
    /// outcome plays with (the requesting screen's switch). nil while none
    /// is pending, so an outcome nobody here asked for plays nothing.
    private var pendingStoreHaptics: FunnelHaptics?
    private var storeObserver: NSObjectProtocol?
    /// The device scheme last handed to the session; nil until the view
    /// first appears.
    private var colorScheme: FunnelColorScheme?

    // R2: the host owns the clock for a timed screen. Lazy because its tap
    // reaches back through `interaction`, which needs `self`.
    private lazy var clock = AutoAdvanceClock(scheduler: autoAdvanceScheduler) { [weak self] in
        self?.interaction.tap(autoAdvanceTapPath)
    }

    /// - Parameter fontBaseURL: where the funnel's catalog fonts are served
    ///   (`<fontBaseURL>/funnel-fonts/…`). Defaults to the API `configure`
    ///   was given; a preview tool that never configures passes its own.
    public convenience init(
        session: FunnelSessionDriving,
        handlers: FunnelHostHandlers = .init(),
        fontBaseURL: URL? = Rovenue.configuredApiBaseURL
    ) {
        self.init(session: session, handlers: handlers, scheduler: TaskAutoAdvanceScheduler(), fontBaseURL: fontBaseURL)
    }

    // Internal: a test hands in fake time.
    init(
        session: FunnelSessionDriving,
        handlers: FunnelHostHandlers,
        scheduler: AutoAdvanceScheduling,
        fontBaseURL: URL? = nil
    ) {
        self.session = session
        self.handlers = handlers
        self.autoAdvanceScheduler = scheduler
        self.fontBaseURL = fontBaseURL
        // The device scheme before the first screen draws, so a dark device
        // never sees one light frame; the view keeps it current after.
        if let seeded = FunnelDriver.deviceColorScheme() {
            colorScheme = seeded
            _ = session.setColorScheme(seeded)
        }
        apply(session.current())
        storeObserver = NotificationCenter.default.addObserver(
            forName: FunnelStoreOutcome.notification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let outcome = note.object as? FunnelStoreOutcome else { return }
            // Delivered on the main queue, where the haptic generators live.
            MainActor.assumeIsolated { self.storeEnded(outcome) }
        }
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    /// A purchase or restore this funnel asked for ended: success or a real
    /// failure plays its haptic; a cancelled sheet or a deferred purchase
    /// plays nothing.
    @MainActor
    private func storeEnded(_ outcome: FunnelStoreOutcome) {
        guard let haptics = pendingStoreHaptics else { return }
        pendingStoreHaptics = nil
        if outcome != .quiet { haptics.storeEnded(outcome) }
    }

    // Internal for the same reason: block views report through it.
    lazy var interaction = FunnelInteraction(
        tap: { [weak self] path in self?.apply(self?.session.tap(path)) },
        answer: { [weak self] blockId, answer in
            self?.apply(self?.session.submit(blockId, encodeAnswer(answer)))
        },
        selectPackage: { [weak self] identifier in
            self?.apply(self?.session.selectPackage(identifier))
        },
        // The machine is not asked: a held control runs no chain. The
        // answers it holds are already current — every edit is submitted
        // as it happens — so the page's verdict needs no flush first.
        held: { [weak self] in
            self?.revealedScreenId = self?.screen?.screenId
        },
        // A progress block's back control runs the same back step a host's
        // `goBack()` does.
        back: { [weak self] in self?.goBack() }
    )

    // A driver starts off-screen (the clock starts paused), so a funnel that
    // is resolved but never shown never advances; the view's appear starts
    // the clock and its disappear stops it.
    //
    // Internal: RovenueFunnelView calls these as it leaves and re-enters the
    // screen. A hidden funnel must not advance itself — its next chain's
    // effects (a URL, a purchase) would fire where no one can see them.
    // Mirrors sdk-kotlin's onDetachedFromWindow / onAttachedToWindow,
    // including restarting the wait from zero on return.
    func pauseClock() {
        clock.pause()
    }

    func resumeClock() {
        clock.resume(finished ? nil : screen)
    }

    /// The view put this driver on screen. The first time: `onLoaded` (for
    /// a placement view), then the first `onScreenChanged`.
    func didAppear() {
        guard !presented else { return }
        presented = true
        onFirstPresented?()
        onFirstPresented = nil
        reportScreen()
    }

    private func reportScreen() {
        guard presented, let screen, screen.screenId != reportedScreenId else { return }
        reportedScreenId = screen.screenId
        handlers.onScreenChanged?(FunnelScreen(screenId: screen.screenId, index: screen.index))
    }

    public func goBack() {
        apply(session.back())
    }

    /// The device's colour scheme, from the view (`@Environment(\.colorScheme)`)
    /// as it appears and whenever it changes: the session redraws the
    /// current screen in it. An unchanged scheme asks nothing.
    /// The device's scheme as UIKit reports it now; nil where there is no
    /// UIKit (the macOS test host), left to the view's `onAppear`.
    private static func deviceColorScheme() -> FunnelColorScheme? {
        #if canImport(UIKit) && !os(watchOS)
            return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #else
            return nil
        #endif
    }

    func setColorScheme(_ scheme: ColorScheme) {
        let next: FunnelColorScheme = scheme == .dark ? .dark : .light
        guard next != colorScheme else { return }
        colorScheme = next
        apply(session.setColorScheme(next))
    }

    /// A link the visitor tapped inside a block (a legal block's terms
    /// link). One rule on every drawer: the host's `onUrl` first — the
    /// same handler an authored `open_url` reaches; with none, only an
    /// http(s) address opens, in the system browser, and any other scheme
    /// is inert. Mirrors sdk-kotlin's `consent` and the web's `Consent`.
    func openLink(_ url: URL) -> OpenURLAction.Result {
        if let onUrl = handlers.onUrl {
            onUrl(url.absoluteString)
            return .handled
        }
        guard let scheme = url.scheme?.lowercased(), webSchemes.contains(scheme) else {
            return .discarded
        }
        return .systemAction
    }

    /// The host closed the view: emit `funnel_dismiss` (once — the
    /// session guards a double call) and stop the clock, so a closed
    /// funnel advances nowhere. Fires neither `onDismissed` nor
    /// `onCompleted`: closing is the host's own decision, not an event to
    /// report back to it.
    public func close() {
        session.dismiss()
        clock.cancel()
    }

    /// The persisted session. A host stores this and hands it back on the
    /// next launch.
    public func stateJson() -> String {
        session.stateJson()
    }

    private func apply(_ step: FunnelStep?) {
        guard let step else { return }
        // The screen is assigned BEFORE effects run, so a submit that
        // re-resolved is visible even if an effect handler takes a while.
        let previous = screen
        let previousScreenId = previous?.screenId
        if let json = step.screenJson {
            let next = decodeRenderScreen(json)
            // A new page is a new arrival; a re-resolve of the same page is
            // not, and keeps whatever is still settling.
            if let previous, let next, next.screenId != previous.screenId {
                // A purchase the page being left asked for and that never
                // ended through the SDK (the host bought some other way) is
                // over: a later, unrelated SDK purchase must not play it.
                pendingStoreHaptics = nil
                arrival = FunnelArrival(
                    serial: arrival.serial + 1,
                    navigation: FunnelNavigation(direction: step.direction, transition: step.transition),
                    leaving: previous)
            }
            screen = next
            if screen == nil {
                // A screen this SDK cannot draw is reported, never drawn
                // blank (spec §3.5a).
                handlers.onError?(RovenueError(
                    kind: .funnelInvalid,
                    message: undecodableScreenMessage,
                    serverCode: RovenueError.funnelScreenUndecodableCode
                ))
            }
        } else {
            screen = nil
        }
        if screen?.screenId != previousScreenId { revealedScreenId = nil }
        reportScreen()
        loadFonts(for: screen)
        // Armed (or kept, or called off) as the screen lands, before any
        // effect handler can re-enter the driver with the next one.
        clock.screenArrived(finished ? nil : screen)
        for effect in step.effects {
            handle(effect)
        }
        if step.finished && !finished {
            finished = true
            handlers.onCompleted?()
        }
        // A funnel that ended here advances nowhere.
        if finished {
            clock.cancel()
        }
    }

    /// Fetches and registers the catalog faces `screen` draws in, then
    /// redraws. Host I/O, off the drawing path: until it lands the drawers
    /// draw the system face.
    private func loadFonts(for screen: RenderScreen?) {
        guard let screen, let base = fontBaseURL else { return }
        let families = funnelFamilies(in: screen)
        let italicFamilies = funnelItalicFamilies(in: screen)
        guard !families.isEmpty || !italicFamilies.isEmpty else { return }
        Task { [weak self] in
            if await FunnelFontStore.shared.ensure(families, italics: italicFamilies, base: base) {
                await MainActor.run { self?.fontsVersion += 1 }
            }
        }
    }

    private func handle(_ effect: FunnelEffect) {
        switch effect {
        case .dismiss:
            session.dismiss()
            // Marked finished first, so the same step's `finished` does not
            // also report a completion.
            let wasFinished = finished
            finished = true
            if !wasFinished { handlers.onDismissed?() }
        case .openUrl(let url):
            handlers.onUrl?(url)
        case .showAlert(let title, let message, let buttonLabel):
            handlers.onAlert?(title, message, buttonLabel)
        case .custom(let actionId, let paramsJson):
            handlers.onCustom?(actionId, paramsJson)
        case .purchase(let packageId):
            // C11: the store sheet covers the screen, so its wait must not
            // run out underneath. Held before the host opens the sheet.
            clock.hold()
            pendingStoreHaptics = FunnelHaptics(enabled: screen?.haptics ?? true)
            handlers.onPurchase?(packageId)
        case .restorePurchases:
            clock.hold()
            pendingStoreHaptics = FunnelHaptics(enabled: screen?.haptics ?? true)
            handlers.onRestore?()
        }
    }
}

/// The only schemes a tapped link opens without a host handler.
private let webSchemes: Set<String> = ["http", "https"]

/// `onError`'s message for a screen that does not decode.
private let undecodableScreenMessage = "The funnel's screen could not be decoded by this SDK version."

/// The SDK's funnel view.
///
/// - `init(placementId:locale:handlers:)` resolves the placement itself and
///   reports every lifecycle event (`onLoaded`, `onUnavailable`, `onError`,
///   …). In a debug build on a Sandbox key it shows the funnel's latest
///   DRAFT with a "Draft" badge, and keeps it live: every edit in the
///   builder arrives within a few seconds, on the screen you are on when it
///   still exists (spec 2026-10-17 §3.5).
/// - `init(driver:)` draws a session the host resolved and drives itself
///   (a fixed snapshot: no resolve events, no live refresh).
public struct RovenueFunnelView: View {
    private enum Source {
        case driver(FunnelDriver)
        case placement(id: String, locale: String?, handlers: FunnelHostHandlers)
    }

    private let source: Source

    /// Draws a driver the host built (`FunnelDriver(session:handlers:)`).
    public init(driver: FunnelDriver) {
        self.source = .driver(driver)
    }

    /// Resolves `placementId` and draws what it serves.
    ///
    /// - Parameters:
    ///   - placementId: the placement's identifier.
    ///   - locale: the BCP-47 locale to resolve text in; the device's when nil.
    ///   - handlers: what the host is told about, including the lifecycle
    ///     events. A new `placementId` or `locale` resolves again; the
    ///     previous funnel is cleared first.
    public init(placementId: String, locale: String? = nil, handlers: FunnelHostHandlers = .init()) {
        self.source = .placement(id: placementId, locale: locale, handlers: handlers)
    }

    public var body: some View {
        switch source {
        case .driver(let driver):
            FunnelDriverView(driver: driver)
        case .placement(let id, let locale, let handlers):
            PlacementFunnelView(placementId: id, locale: locale, handlers: handlers)
        }
    }
}

/// How the driver's current screen was reached.
struct FunnelArrival {
    /// Bumped per new page, so a view knows a transition is due.
    let serial: Int
    let navigation: FunnelNavigation
    /// The screen being left, drawn while the transition runs; nil for the
    /// first screen.
    let leaving: RenderScreen?

    static let first = FunnelArrival(serial: 0, navigation: .still, leaving: nil)
}

/// Draws whatever screen the driver currently holds — and, while a page
/// transition runs, the page being left as an inert layer beside it
/// (`FunnelMotion.swift`).
struct FunnelDriverView: View {
    @ObservedObject var driver: FunnelDriver
    /// The arrival whose leaving page has been dropped. Starts at the
    /// driver's current one, so a view rebuilt over a running driver
    /// replays nothing.
    @State private var settledSerial: Int
    /// The clock every layer of the running navigation reads.
    @State private var clock = FunnelTransitionClock()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The device's scheme, handed to the session: a funnel with dark mode
    /// on redraws in its dark palette.
    @Environment(\.colorScheme) private var colorScheme
    /// Prefer Cross-Fade Transitions, observed: unlike Reduce Motion it is
    /// no environment value, so its change notification is what redraws.
    @State private var prefersCrossFade = FunnelDriverView.crossFadePreferred()

    init(driver: FunnelDriver) {
        self.driver = driver
        _settledSerial = State(initialValue: driver.arrival.serial)
    }

    var body: some View {
        // A ZStack, not a Group: a Group hands its modifiers to each child,
        // so the appear/disappear below would fire on every screen swap
        // instead of when the funnel itself enters or leaves the screen.
        ZStack {
            if let screen = driver.screen {
                // Read so a font registration redraws the screen; never
                // part of its identity (that would reset its controls).
                let _ = driver.fontsVersion
                let arrival = driver.arrival
                // One identity per SCREEN: a re-resolve of the same screen
                // keeps every control's state (and a caret mid-typing),
                // while the next screen's controls start from its own
                // resolved answers rather than inheriting a previous
                // screen's at the same position.
                ForEach(layers(screen, arrival)) { layer in
                    FunnelScreenContent(
                        screen: layer.screen,
                        interaction: driver.interaction,
                        revealInvalid: driver.revealedScreenId == layer.screen.screenId,
                        mode: motionMode,
                        enterOffsetMs: layer.enterOffsetMs,
                        leavingMs: layer.leavingMs
                    )
                    .modifier(
                        FunnelPageLayer(
                            motion: layer.motion, serial: arrival.serial, clock: clock,
                            interactive: layer.leavingMs == nil))
                    .zIndex(layer.order)
                    // The page being left never takes a tap: the new page is
                    // interactive from its first frame.
                    .allowsHitTesting(layer.leavingMs == nil)
                    .accessibilityHidden(layer.leavingMs != nil)
                }
            } else {
                Color.clear
            }
        }
        // The page backdrop is painted here, edge to edge under the system
        // bars, not by the moving page layers — the web's
        // `useBackdropLayers`: it stays put across a transition, and when
        // the page being left had a different one, that one stays on top
        // and fades out over the transition.
        .background {
            if let screen = driver.screen {
                ZStack {
                    ForEach(backdrops(screen, driver.arrival)) { layer in
                        FunnelPageBackground(
                            base: funnelColor(layer.backdrop.base) ?? .clear,
                            background: layer.backdrop.background
                        )
                        .modifier(
                            FunnelBackdropFade(
                                fadeMs: layer.fadeMs, serial: driver.arrival.serial,
                                tokens: screen.look.motion, clock: clock))
                        .zIndex(layer.fadeMs == nil ? LayerOrder.under : LayerOrder.over)
                    }
                }
            }
        }
        // The page being left is dropped once its transition ends; a newer
        // arrival in the meantime drops it at once (transitions never queue).
        .onChange(of: driver.arrival.serial) { serial in settle(serial) }
        // The hosting view leaving its window (sdk-rn's didMoveToWindow(nil)
        // → detachFromParent, Flutter's platform view going away, a pushed
        // screen covering this one) is what SwiftUI reports as disappear.
        .onAppear {
            driver.setColorScheme(colorScheme)
            driver.didAppear()
            driver.resumeClock()
        }
        .onDisappear { driver.pauseClock() }
        .onChange(of: colorScheme) { scheme in driver.setColorScheme(scheme) }
        .modifier(CrossFadePreferenceObserver(prefersCrossFade: $prefersCrossFade))
        // Every link a block opens goes through the driver, never straight
        // to the system: the host's handler first (see `openLink`).
        .environment(\.openURL, OpenURLAction { [driver] url in driver.openLink(url) })
        // Logical positions (a button icon at `start`, a row's leading
        // edge) mirror for a right-to-left funnel even in a left-to-right
        // app — the web frame's `dir` (text-direction.ts).
        .ifLet(driver.layoutDirection) { $0.environment(\.layoutDirection, $1) }
    }

    /// iOS Reduce Motion, or Prefer Cross-Fade Transitions, asks for the
    /// reduced variant.
    private var motionMode: FunnelMotionMode {
        prefersCrossFade || reduceMotion ? .reduced : .full
    }

    /// Prefer Cross-Fade Transitions, as the system reports it now.
    fileprivate static func crossFadePreferred() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
            return UIAccessibility.prefersCrossFadeTransitions
        #else
            return false
        #endif
    }

    /// The transition the current arrival still plays, or nil once it has
    /// settled, for the first screen, or for a cut.
    private func plan(_ screen: RenderScreen, _ arrival: FunnelArrival) -> FunnelTransitionPlan? {
        guard arrival.serial != settledSerial, let leaving = arrival.leaving,
            leaving.screenId != screen.screenId
        else { return nil }
        return funnelTransitionPlan(arrival.navigation, mode: motionMode, tokens: screen.look.motion)
    }

    /// Each layer is keyed by its page AND the arrival that brought it in
    /// (the web's per-arrival layer keys): the page being left stays the
    /// view it was while it was current, and a page arriving again — A → B
    /// → A inside one transition — is a fresh view that plays its enters,
    /// not the leaving copy turned around.
    private func layers(_ screen: RenderScreen, _ arrival: FunnelArrival) -> [FunnelPageLayerModel] {
        let currentKey = FunnelPageLayerModel.key(screen, arrival.serial)
        guard let plan = plan(screen, arrival), let leaving = arrival.leaving else {
            return [FunnelPageLayerModel(key: currentKey, screen: screen, motion: nil, order: LayerOrder.under, enterOffsetMs: 0, leavingMs: nil)]
        }
        let enterOffsetMs = screen.look.motion.enterOffsetMs(plays: true, mode: motionMode)
        return [
            // The page being left was current at the previous arrival.
            FunnelPageLayerModel(
                key: FunnelPageLayerModel.key(leaving, arrival.serial - 1),
                screen: leaving, motion: plan.outgoing,
                order: plan.incomingOnTop ? LayerOrder.under : LayerOrder.over,
                enterOffsetMs: 0, leavingMs: plan.totalMs),
            FunnelPageLayerModel(
                key: currentKey,
                screen: screen, motion: plan.incoming,
                order: plan.incomingOnTop ? LayerOrder.over : LayerOrder.under,
                enterOffsetMs: enterOffsetMs, leavingMs: nil),
        ]
    }

    /// The current page's backdrop, plus the leaving page's above it while
    /// a transition runs and the two differ. Keyed by the backdrop itself:
    /// identical backdrops are one view that never rebuilds, and a leaving
    /// one is the view that was already painting it (a video keeps going).
    private func backdrops(_ screen: RenderScreen, _ arrival: FunnelArrival) -> [FunnelBackdropLayer] {
        let current = FunnelBackdrop(base: screen.backgroundColor, background: screen.background)
        guard let plan = plan(screen, arrival), let leaving = arrival.leaving else {
            return [FunnelBackdropLayer(backdrop: current, fadeMs: nil)]
        }
        let left = FunnelBackdrop(base: leaving.backgroundColor, background: leaving.background)
        guard left != current else { return [FunnelBackdropLayer(backdrop: current, fadeMs: nil)] }
        return [
            FunnelBackdropLayer(backdrop: current, fadeMs: nil),
            FunnelBackdropLayer(backdrop: left, fadeMs: plan.totalMs),
        ]
    }

    private func settle(_ serial: Int) {
        let totalMs = driver.screen.flatMap { plan($0, driver.arrival)?.totalMs } ?? 0
        dropLeaving(serial, totalMs: Double(totalMs), afterMs: Double(totalMs))
    }

    /// Drops the page being left once the transition's CLOCK has run
    /// `totalMs` — not a fixed delay from the arrival: the clock may have
    /// restarted at the incoming page's first drawn frame
    /// (`FunnelTransitionClock`), and a fixed timer would cut the
    /// transition short by that much.
    private func dropLeaving(_ serial: Int, totalMs: Double, afterMs: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, afterMs) / LayerOrder.millisecondsPerSecond) {
            guard driver.arrival.serial == serial else { return }
            let remaining = totalMs - clock.elapsedMs(serial, now: Date())
            if remaining > 0 {
                dropLeaving(serial, totalMs: totalMs, afterMs: remaining)
            } else {
                settledSerial = serial
            }
        }
    }
}

/// Keeps `prefersCrossFade` in step with the system setting while the
/// funnel is up (M8): toggling Prefer Cross-Fade Transitions switches the
/// next transition's mode at once, not at some unrelated redraw.
private struct CrossFadePreferenceObserver: ViewModifier {
    @Binding var prefersCrossFade: Bool

    func body(content: Content) -> some View {
        #if canImport(UIKit) && !os(watchOS)
            content.onReceive(
                NotificationCenter.default.publisher(
                    for: UIAccessibility.prefersCrossFadeTransitionsStatusDidChange)
            ) { _ in
                prefersCrossFade = UIAccessibility.prefersCrossFadeTransitions
            }
        #else
            content
        #endif
    }
}

/// One drawn page: the current one, or the one being left.
private struct FunnelPageLayerModel: Identifiable {
    /// The page's id and the serial of the arrival that made it current.
    let key: String
    let screen: RenderScreen
    let motion: FunnelLayerMotion?
    let order: Double
    let enterOffsetMs: Int
    /// Non-nil on the page being left: how long its transition runs.
    let leavingMs: Int?

    var id: String { key }

    static func key(_ screen: RenderScreen, _ serial: Int) -> String { "\(screen.screenId)#\(serial)" }
}

/// What a page paints behind its blocks.
private struct FunnelBackdrop: Hashable {
    let base: String?
    let background: RenderBackground?
}

private struct FunnelBackdropLayer: Identifiable {
    let backdrop: FunnelBackdrop
    /// Set on the leaving backdrop: how long it takes to fade out.
    let fadeMs: Int?

    var id: FunnelBackdrop { backdrop }
}

private enum LayerOrder {
    static let under = 0.0
    static let over = 1.0
    static let millisecondsPerSecond = 1000.0
}

/// One screen, drawn: the pinned header, the scrolled body, the pinned
/// footer, and the screen's motion and haptics for every block on it.
private struct FunnelScreenContent: View {
    let screen: RenderScreen
    let interaction: FunnelInteraction
    let revealInvalid: Bool
    let mode: FunnelMotionMode
    let enterOffsetMs: Int
    let leavingMs: Int?
    @State private var appearance = FunnelAppearance()
    @StateObject private var footerPresence = FunnelPresence()
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let look = screen.look
        let nodes = funnelNodes(for: screen)
        // The sticky footer is pinned rather than scrolled; everything
        // else, the CTA included, flows in order.
        let pinned = nodes.filter { if case .stickyFooter = $0 { return true } else { return false } }
        let scrolled = nodes.filter { if case .stickyFooter = $0 { return false } else { return true } }
        // Kept drawn while a hidden footer plays its exit.
        let footer = footerPresence.present(identified(pinned), animating: true)
        let header = identified(funnelHeaderNodes(for: screen))
        let base = funnelColor(screen.backgroundColor) ?? .clear
        // The pinned regions sit on the page: over a page background they
        // let that background show, as the web's frame does.
        let pinnedFill = screen.background == nil ? base : .clear
        let padding = screen.padding
        // `padding` is physical (`left`/`right`), as the web's CSS draws it;
        // SwiftUI's edges are leading/trailing, so a right-to-left screen
        // swaps them.
        let rtl = layoutDirection == .rightToLeft
        let leading = CGFloat(rtl ? padding.right : padding.left)
        let trailing = CGFloat(rtl ? padding.left : padding.right)

        // The body is the page `layout` (rulings 6): its top-level blocks
        // placed by direction / alignX / alignY / distribute, `layout.gap`
        // apart — 0 unless the author spaced the body, the look's rhythm
        // then sitting in each block's own `marginTop` (never `blockGap`
        // on top). It is at least the visible height, so centring, spreading
        // and a flexible spacer act while the content is shorter; a longer
        // page scrolls from the top.
        GeometryReader { viewport in
            ScrollView {
                FunnelArrangement(
                    spec: FunnelArrangementSpec(layout: screen.layout), claimsHeight: true,
                    minHeight: max(
                        ColumnFormat.none,
                        viewport.size.height - CGFloat(padding.top + padding.bottom))
                ) {
                    FunnelNodeList(nodes: scrolled, look: look, interaction: interaction)
                }
                .padding(.top, CGFloat(padding.top))
                .padding(.bottom, CGFloat(padding.bottom))
                .padding(.leading, leading)
                .padding(.trailing, trailing)
            }
        }
        .safeAreaInset(edge: .top, spacing: ColumnFormat.none) {
            // The pinned header — the page's top-level progress block — above
            // the scroll, below the page's top padding and in its side
            // padding (rulings 3); the body below keeps its own top padding.
            if !header.isEmpty {
                VStack(spacing: ColumnFormat.none) {
                    ForEach(header) { entry in
                        FunnelNodeView(node: entry.node, look: look, interaction: interaction)
                    }
                }
                .padding(.top, CGFloat(padding.top))
                .padding(.leading, leading)
                .padding(.trailing, trailing)
                .background(pinnedFill)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // The pinned footer keeps the page's side and bottom padding and
            // sits one block gap below the scrolled body.
            if !footer.isEmpty {
                VStack(spacing: CGFloat(look.blockGap)) {
                    ForEach(footer) { entry in
                        FunnelNodeView(
                            node: entry.node, look: look, interaction: interaction,
                            exiting: entry.exiting,
                            onExited: { [footerPresence] in footerPresence.exited(entry.id) })
                    }
                }
                .padding(.top, CGFloat(look.blockGap))
                .padding(.bottom, CGFloat(look.pagePaddingBottom))
                .padding(.leading, leading)
                .padding(.trailing, trailing)
                .background(pinnedFill)
            }
        }
        // `safeArea: false` — header, body and footer reach under the
        // system bars (the background always does); the keyboard's region
        // is still kept clear.
        .ifLet(screen.safeArea ? nil : ColumnFormat.unsafeRegions) { $0.ignoresSafeArea($1) }
        .funnelStatusBarHidden(!screen.statusBar)
        // Copy nobody coloured is the look's text colour, never the
        // system's: the device scheme reaches the screen only through the
        // session (`setColorScheme`), already resolved into the look.
        .foregroundColor(look.textColor)
        // A field's keyboard goes away as the page is dragged.
        .scrollDismissesKeyboardInteractively()
        // The page's background is painted by `FunnelDriverView`, behind
        // the page layers, so it stays edge to edge across a transition.
        // Every accessibility string a block announces is the screen's
        // copy, resolved for its locale — installed once, read by
        // `funnelRadio` / `funnelCheckbox` / `funnelPositionLabel`.
        .environment(\.funnelCopy, screen.copy)
        // The side padding a bleeding image cancels — the body's own.
        .environment(\.funnelPagePadding, screen.padding)
        // A held tap on THIS page reveals every refused answer on it.
        .environment(\.funnelRevealInvalid, revealInvalid)
        // What every block on the page animates with, and the funnel's
        // haptics switch.
        .environment(
            \.funnelScreenMotion,
            FunnelScreenMotion(
                tokens: look.motion, mode: mode, enterOffsetMs: enterOffsetMs, leavingMs: leavingMs,
                appearance: appearance))
        .environment(\.funnelHaptics, FunnelHaptics(enabled: screen.haptics))
        // Every node on the first frame has appeared by the next turn of
        // the run loop; one that appears later was revealed.
        .onAppear { [appearance] in DispatchQueue.main.async { appearance.appeared = true } }
    }
}

private enum ColumnFormat {
    static let none: CGFloat = 0
    /// What `safeArea: false` reaches into: the system bars, not the
    /// keyboard.
    static let unsafeRegions: SafeAreaRegions = .container
}

extension View {
    /// Hides the status bar while the screen shows (`statusBar: false`);
    /// macOS, the test host, has none.
    ///
    /// Known limitation: SwiftUI's `statusBarHidden` is honoured only by the
    /// view controller that owns the status bar — the funnel presented
    /// full screen. Embedded in a host's own controller (sdk-rn's child
    /// `UIHostingController`, a Flutter platform view, a sheet), the host
    /// app decides, and this preference has no effect. Documented in the
    /// funnels docs (inspector-and-layout); no host change this release.
    @ViewBuilder
    fileprivate func funnelStatusBarHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
            self.statusBarHidden(hidden)
        #else
            self
        #endif
    }

    /// `scrollDismissesKeyboard(.interactively)` where the OS has it
    /// (iOS 16, the package's floor); the macOS test host has no keyboard.
    @ViewBuilder
    fileprivate func scrollDismissesKeyboardInteractively() -> some View {
        #if os(iOS)
            self.scrollDismissesKeyboard(.interactively)
        #else
            self
        #endif
    }
}
