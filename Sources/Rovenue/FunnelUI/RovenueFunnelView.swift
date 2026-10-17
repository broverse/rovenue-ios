//  RovenueFunnelView.swift — the entry point and the step driver.
//
//  The driver owns the session and applies effects; the view is thin. No
//  block view ever holds a session, and the drawer never navigates a URL
//  itself — that goes to the host.

import Foundation
import SwiftUI

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
    @Published public private(set) var finished = false
    /// Bumped when a catalog font a screen draws in has been registered —
    /// the view reads it, so it redraws in the funnel's own faces.
    @Published private(set) var fontsVersion = 0
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
        apply(session.current())
    }

    // Internal for the same reason: block views report through it.
    lazy var interaction = FunnelInteraction(
        tap: { [weak self] path in self?.apply(self?.session.tap(path)) },
        answer: { [weak self] blockId, answer in
            self?.apply(self?.session.submit(blockId, encodeAnswer(answer)))
        },
        selectPackage: { [weak self] identifier in
            self?.apply(self?.session.selectPackage(identifier))
        }
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
        if let json = step.screenJson {
            screen = decodeRenderScreen(json)
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
            handlers.onPurchase?(packageId)
        case .restorePurchases:
            clock.hold()
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

/// Draws whatever screen the driver currently holds.
struct FunnelDriverView: View {
    @ObservedObject var driver: FunnelDriver

    var body: some View {
        // A ZStack, not a Group: a Group hands its modifiers to each child,
        // so the appear/disappear below would fire on every screen swap
        // instead of when the funnel itself enters or leaves the screen.
        ZStack {
            if let screen = driver.screen {
                // Read so a font registration redraws the screen; never
                // part of its identity (that would reset its controls).
                let _ = driver.fontsVersion
                // One identity per SCREEN: a re-resolve of the same screen
                // keeps every control's state (and a caret mid-typing),
                // while the next screen's controls start from its own
                // resolved answers rather than inheriting a previous
                // screen's at the same position.
                content(for: screen).id(screen.screenId)
            } else {
                Color.clear
            }
        }
        // The hosting view leaving its window (sdk-rn's didMoveToWindow(nil)
        // → detachFromParent, Flutter's platform view going away, a pushed
        // screen covering this one) is what SwiftUI reports as disappear.
        .onAppear {
            driver.didAppear()
            driver.resumeClock()
        }
        .onDisappear { driver.pauseClock() }
        // Every link a block opens goes through the driver, never straight
        // to the system: the host's handler first (see `openLink`).
        .environment(\.openURL, OpenURLAction { [driver] url in driver.openLink(url) })
        // Logical positions (a button icon at `start`, a row's leading
        // edge) mirror for a right-to-left funnel even in a left-to-right
        // app — the web frame's `dir` (text-direction.ts).
        .ifLet(driver.layoutDirection) { $0.environment(\.layoutDirection, $1) }
    }

    @ViewBuilder
    private func content(for screen: RenderScreen) -> some View {
        let look = screen.look
        let nodes = funnelNodes(for: screen)
        // The sticky footer is pinned rather than scrolled; everything
        // else, the CTA included, flows in order.
        let pinned = nodes.filter { if case .stickyFooter = $0 { return true } else { return false } }
        let scrolled = nodes.filter { if case .stickyFooter = $0 { return false } else { return true } }
        let base = funnelColor(screen.backgroundColor) ?? .clear
        // The pinned footer sits on the page: over a page background it
        // lets that background show, as the web's frame does.
        let footerFill = screen.background == nil ? base : .clear

        // Page padding is the look's — the same numbers the web and Android
        // draw with. The space BETWEEN blocks is each block's own
        // `marginTop`, set by the resolver from the look's rhythm (spec
        // 2026-10-11 §10.2), so the column adds none. The column is at
        // least the visible height, so a flexible spacer can take what is
        // left and pin what follows it to the bottom; a longer page still
        // scrolls.
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: ColumnFormat.noGap) {
                    ForEach(identified(scrolled)) { entry in
                        FunnelNodeView(node: entry.node, look: look, interaction: driver.interaction)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(
                        ColumnFormat.noGap,
                        viewport.size.height - CGFloat(look.pagePaddingTop + look.pagePaddingBottom)),
                    alignment: .topLeading
                )
                .padding(.top, CGFloat(look.pagePaddingTop))
                .padding(.bottom, CGFloat(look.pagePaddingBottom))
                .padding(.horizontal, CGFloat(look.pagePaddingX))
            }
        }
        .safeAreaInset(edge: .bottom) {
            // The pinned footer keeps the page's side and bottom padding and
            // sits one block gap below the scrolled body.
            if !pinned.isEmpty {
                VStack(spacing: CGFloat(look.blockGap)) {
                    ForEach(identified(pinned)) { entry in
                        FunnelNodeView(node: entry.node, look: look, interaction: driver.interaction)
                    }
                }
                .padding(.top, CGFloat(look.blockGap))
                .padding(.bottom, CGFloat(look.pagePaddingBottom))
                .padding(.horizontal, CGFloat(look.pagePaddingX))
                .background(footerFill)
            }
        }
        // Copy nobody coloured is the look's text colour, never the
        // system's (which would follow the device into dark mode).
        .foregroundColor(look.textColor)
        // A field's keyboard goes away as the page is dragged.
        .scrollDismissesKeyboardInteractively()
        // The background runs under the system bars; the content above
        // stays inside the safe area.
        .background(FunnelPageBackground(base: base, background: screen.background))
        // Every accessibility string a block announces is the screen's
        // copy, resolved for its locale — installed once, read by
        // `funnelRadio` / `funnelCheckbox` / `funnelPositionLabel`.
        .environment(\.funnelCopy, screen.copy)
    }
}

private enum ColumnFormat {
    /// Blocks carry their own space above them (`marginTop`).
    static let noGap: CGFloat = 0
}

extension View {
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
