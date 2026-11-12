//  FunnelPresenter.swift — `Rovenue.presentFunnel` on iOS (spec
//  2026-11-03-funnel-presentation §2): resolve the placement first (the
//  same cache-first open `preloadPlacement` warms), and only when a funnel
//  came back present it the way the author chose in the editor — full
//  screen from the bottom / side / fade / at once, the page-sheet modal, or
//  a sheet at its detents. The SDK performs the funnel's purchases and
//  restores unless the host passes its own, closes on purchase when the
//  funnel says so, and resolves the call exactly once with what happened.
//
//  The funnel is the presented controller's whole view: no host navigation
//  bar is ever drawn over it, so a top-end close button is tappable in
//  every style. Inside a modal or sheet "the screen" is the sheet's own
//  bounds — the safe area the funnel measures is its own box's.

#if os(iOS)
import SwiftUI
import UIKit

/// One presentation at a time, process-wide.
@MainActor
final class FunnelPresenter {
    static let shared = FunnelPresenter()
    private(set) var active: FunnelPresentation?
    /// Claimed before the placement resolves, so a second call made while
    /// the first is still loading is refused too.
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }

    func release() {
        claimed = false
        active = nil
    }

    func attach(_ presentation: FunnelPresentation) {
        active = presentation
    }
}

/// Finds the controller a funnel presents from when the host names none.
@MainActor
enum FunnelPresenterLookup {
    static func topMost() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        guard var top = window?.rootViewController else { return nil }
        while true {
            if let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            } else if let nav = top as? UINavigationController, let visible = nav.visibleViewController {
                if visible === top { break }
                top = visible
            } else if let tabs = top as? UITabBarController, let selected = tabs.selectedViewController {
                top = selected
            } else {
                break
            }
        }
        return top
    }
}

/// A live presentation: its session, its controller and the one awaiting
/// caller.
@MainActor
final class FunnelPresentation: NSObject {
    let session: FunnelSession
    let resolved: CoreFunnelPresentation
    let handlers: FunnelPresentHandlers
    private let offering: CoreOffering?
    private(set) var driver: FunnelDriver!
    private var controller: FunnelHostingController?
    private var continuation: CheckedContinuation<FunnelPresentResult, Never>?
    private var resolvedOnce = false

    private var purchased = false
    private var customerInfo: PurchaseResult?
    private var lastError: RovenueError?
    /// A purchase or restore is running: nothing may close the funnel.
    private(set) var storeInFlight = false {
        didSet { controller?.updateModalInPresentation() }
    }

    init(
        resolved funnel: ResolvedFunnel, style: FunnelPresentationOverride?,
        handlers: FunnelPresentHandlers, offering: CoreOffering?
    ) {
        self.session = funnel.session
        self.resolved = funnel.session.presentation(styleOverride: style?.ffi)
        self.handlers = handlers
        self.offering = offering
        super.init()
        var host = FunnelHostHandlers()
        host.onUrl = { [weak self] url in self?.openUrl(url) }
        host.onCustom = { [weak self] id, params in self?.handlers.onCustomAction?(id, params) }
        host.onPurchase = { [weak self] packageId in self?.purchase(packageId) }
        host.onRestore = { [weak self] in self?.restore() }
        host.onCompleted = { [weak self] in self?.close(.completed) }
        host.onDismissed = { [weak self] in self?.close(.dismissed) }
        host.onPhotoSelected = handlers.onPhotoSelected
        host.onCheck = handlers.onCheck
        let driver = FunnelDriver(session: funnel.session, handlers: host)
        driver.layoutDirection = funnel.contentLocale.map(FunnelTextDirection.layoutDirection(of:))
        driver.contentLocale = funnel.contentLocale
        self.driver = driver
    }

    /// Presents from `presenter` and waits for the end.
    func run(from presenter: UIViewController, isDraft: Bool) async -> FunnelPresentResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let controller = FunnelHostingController(presentation: self, isDraft: isDraft)
            self.controller = controller
            presenter.present(controller, animated: controller.animatesTransition)
        }
    }

    // MARK: - Ending

    /// The funnel ended from inside (its close, its finish, a purchase
    /// that closes it): play the exit, then resolve.
    private func close(_ outcome: FunnelPresentOutcome) {
        guard let controller, !resolvedOnce else { return }
        controller.dismiss(animated: controller.animatesTransition) { [weak self] in
            self?.finish(outcome)
        }
    }

    /// The visitor swiped the sheet away (`presentationControllerDidDismiss`).
    func userDismissed() {
        // The same path as a host's close: `funnel_dismiss`, once (the
        // session guards it, and stays silent after a completion).
        driver.close()
        finish(.dismissed)
    }

    private func finish(_ outcome: FunnelPresentOutcome) {
        guard !resolvedOnce else { return }
        resolvedOnce = true
        if outcome == .dismissed { driver.close() }
        let result = FunnelPresentResult(
            result: outcome, purchased: purchased, customerInfo: purchased ? customerInfo : nil,
            lastError: lastError, reason: nil, photos: driver.photos)
        controller = nil
        FunnelPresenter.shared.release()
        continuation?.resume(returning: result)
        continuation = nil
    }

    // MARK: - Effects

    private func openUrl(_ url: String) {
        if let onUrl = handlers.onUrl { onUrl(url); return }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
            ["http", "https"].contains(scheme)
        else { return }
        UIApplication.shared.open(parsed)
    }

    private func purchase(_ packageId: String) {
        guard !storeInFlight else { return }
        storeInFlight = true
        Task { @MainActor in
            defer { storeInFlight = false }
            if let onPurchase = handlers.onPurchase {
                if await onPurchase(packageId) { await hostSucceeded(packageId) }
                return
            }
            guard #available(iOS 15.0, *) else { return }
            guard let productId = appleProductId(packageId) else {
                failed(RovenueError(
                    kind: .invalidArgument,
                    message: "The funnel's package \(packageId) has no App Store product."), haptic: true)
                return
            }
            do {
                let result = try await Rovenue.shared.purchase(productId: productId)
                guard !result.isDeferred else { return }
                succeeded(packageId, info: result)
            } catch {
                failed(error, haptic: false)
            }
        }
    }

    private func restore() {
        guard !storeInFlight else { return }
        storeInFlight = true
        Task { @MainActor in
            defer { storeInFlight = false }
            if let onRestore = handlers.onRestore {
                if await onRestore() { await hostSucceeded("") }
                return
            }
            guard #available(iOS 15.0, *) else { return }
            do {
                let result = try await Rovenue.shared.restorePurchases()
                // A restore that found nothing leaves the funnel where it is.
                guard result.entitlements.contains(where: \.isActive) else { return }
                succeeded("", info: result)
            } catch {
                failed(error, haptic: false)
            }
        }
    }

    /// The host performed it: entitlements once, for `customerInfo`.
    private func hostSucceeded(_ packageId: String) async {
        var info: PurchaseResult?
        if #available(iOS 15.0, *) {
            try? await Rovenue.shared.refreshEntitlements()
            info = PurchaseResult(
                entitlements: await Rovenue.shared.entitlementsAll(),
                virtualCurrencies: await Rovenue.shared.virtualCurrencyBalances(),
                productId: "", storeTransactionId: "")
        }
        succeeded(packageId, info: info)
    }

    private func succeeded(_ packageId: String, info: PurchaseResult?) {
        purchased = true
        customerInfo = info
        // Released before the step lands, so a close it causes is not held.
        storeInFlight = false
        driver.purchaseSucceeded(packageId, close: resolved.closeOnPurchase)
    }

    /// A cancelled sheet is no error and changes nothing. A real failure is
    /// observed and kept; the paywall stays. The SDK's own purchase already
    /// played the failure haptic (`FunnelStoreOutcome`); `haptic` plays it
    /// for a failure that never reached the store.
    private func failed(_ error: Error, haptic: Bool) {
        let rovenue = (error as? RovenueError) ?? RovenueError(kind: .internal, message: error.localizedDescription)
        guard rovenue.kind != .purchaseCanceled else { return }
        lastError = rovenue
        if haptic { FunnelStoreOutcome.failure.post() }
        handlers.onPurchaseError?(rovenue)
    }

    private func appleProductId(_ packageId: String) -> String? {
        offering?.packages.first { $0.packageIdentifier == packageId }?.appleProductId
    }
}

// MARK: - The presented controller

/// Hosts the funnel; configured for the resolved presentation.
@MainActor
final class FunnelHostingController: UIHostingController<AnyView>, UIAdaptivePresentationControllerDelegate {
    private weak var presentation: FunnelPresentation?
    private let resolved: CoreFunnelPresentation
    private let measure = FunnelFitMeasure()
    private var fitHeight: CGFloat = 0
    private var animator: FunnelEntranceTransitions?
    private var keyboardObserver: NSObjectProtocol?

    static let fitIdentifier = UISheetPresentationController.Detent.Identifier("dev.rovenue.funnel.fit")

    init(presentation: FunnelPresentation, isDraft: Bool) {
        self.presentation = presentation
        self.resolved = presentation.resolved
        let style = FunnelPresentationStyle(rawValue: resolved.style) ?? .fullScreen
        let detents = resolved.detents.compactMap(FunnelSheetDetent.init(rawValue:))
        let measures = style == .sheet && detents.contains(.fit)
        let root = FunnelPresentedRoot(driver: presentation.driver, isDraft: isDraft)
            .environment(\.funnelFitMeasure, measures ? measure : nil)
        super.init(rootView: AnyView(root))
        configure(style: style, detents: detents)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("FunnelHostingController is created in code")
    }

    deinit {
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
    }

    /// Whether present / dismiss animate (`none` does not).
    var animatesTransition: Bool {
        !(resolved.style == FunnelPresentationStyle.fullScreen.rawValue
            && resolved.enter == FunnelPresentationEnter.none.rawValue
            && !UIAccessibility.isReduceMotionEnabled)
    }

    private func configure(style: FunnelPresentationStyle, detents: [FunnelSheetDetent]) {
        view.backgroundColor = .clear
        switch style {
        case .fullScreen:
            let enter = FunnelPresentationEnter(rawValue: resolved.enter) ?? .bottom
            // Reduce Motion: every entrance is a fade (spec failure list 7).
            let effective: FunnelPresentationEnter = UIAccessibility.isReduceMotionEnabled && enter != .none ? .fade : enter
            switch effective {
            case .bottom, .none:
                modalPresentationStyle = .fullScreen
            case .side, .fade:
                modalPresentationStyle = .overFullScreen
                let transitions = FunnelEntranceTransitions(enter: effective, tokens: resolved.tokens)
                animator = transitions
                transitioningDelegate = transitions
            }
        case .modal:
            modalPresentationStyle = .pageSheet
        case .sheet:
            modalPresentationStyle = .pageSheet
            if let sheet = sheetPresentationController {
                sheet.detents = detents.map(detent)
                sheet.prefersGrabberVisible = detents.count >= 2
                sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            }
            measure.onChange = { [weak self] height in self?.fitChanged(height) }
            // A field in a sheet raises it to its tallest height
            // (spec failure list 8).
            keyboardObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.raiseToTallest() }
            }
        }
        presentationController?.delegate = self
        updateModalInPresentation()
    }

    private func detent(_ detent: FunnelSheetDetent) -> UISheetPresentationController.Detent {
        switch detent {
        case .large: return .large()
        case .medium:
            let share = CGFloat(resolved.tokens.mediumPercent) / FunnelPresentationFormat.percent
            return .custom(identifier: .medium) { context in context.maximumDetentValue * share }
        case .fit:
            return .custom(identifier: Self.fitIdentifier) { [weak self] context in
                guard let self, self.fitHeight > 0 else { return context.maximumDetentValue }
                // Capped at large (spec failure list 5); the bottom safe
                // area sits under the content.
                let inset = self.view.window?.safeAreaInsets.bottom ?? 0
                return min(context.maximumDetentValue, self.fitHeight + inset)
            }
        }
    }

    private func fitChanged(_ height: CGFloat) {
        fitHeight = height
        guard let sheet = sheetPresentationController else { return }
        sheet.animateChanges { sheet.invalidateDetents() }
    }

    private func raiseToTallest() {
        guard let sheet = sheetPresentationController, let tallest = sheet.detents.last else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = tallest.identifier }
    }

    /// Not dismissible, or a purchase in flight: no swipe closes it.
    func updateModalInPresentation() {
        isModalInPresentation = !resolved.dismissible || (presentation?.storeInFlight ?? false)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        presentation?.userDismissed()
    }
}

/// The funnel, alone in its controller (no host bar), with the Draft badge
/// for a draft.
private struct FunnelPresentedRoot: View {
    @ObservedObject var driver: FunnelDriver
    let isDraft: Bool

    var body: some View {
        FunnelDriverView(driver: driver)
            .overlay(alignment: .bottom) { if isDraft { DraftBadge() } }
    }
}

enum FunnelPresentationFormat {
    static let percent: CGFloat = 100
    static let millisecondsPerSecond: TimeInterval = 1000
    static let thousandths: CGFloat = 1000
}

// MARK: - Side and fade entrances

/// `side` (from the trailing edge, mirrored in a right-to-left layout) and
/// `fade`, timed and curved by the presentation's look tokens.
final class FunnelEntranceTransitions: NSObject, UIViewControllerTransitioningDelegate {
    let enter: FunnelPresentationEnter
    let tokens: CoreFunnelPresentationTokens

    init(enter: FunnelPresentationEnter, tokens: CoreFunnelPresentationTokens) {
        self.enter = enter
        self.tokens = tokens
    }

    func animationController(
        forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        FunnelEntranceAnimator(enter: enter, tokens: tokens, presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        FunnelEntranceAnimator(enter: enter, tokens: tokens, presenting: false)
    }
}

final class FunnelEntranceAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let enter: FunnelPresentationEnter
    let tokens: CoreFunnelPresentationTokens
    let presenting: Bool

    init(enter: FunnelPresentationEnter, tokens: CoreFunnelPresentationTokens, presenting: Bool) {
        self.enter = enter
        self.tokens = tokens
        self.presenting = presenting
    }

    private var durationMs: UInt32 {
        if !presenting { return tokens.exitMs }
        return enter == .fade ? tokens.fadeMs : tokens.enterMs
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        TimeInterval(durationMs) / FunnelPresentationFormat.millisecondsPerSecond
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewKey = presenting ? .to : .from
        guard let view = context.view(forKey: key) else {
            context.completeTransition(!context.transitionWasCancelled)
            return
        }
        let container = context.containerView
        if presenting {
            if let controller = context.viewController(forKey: .to) {
                view.frame = context.finalFrame(for: controller)
            }
            container.addSubview(view)
        }
        // The trailing edge: right in a left-to-right layout, left in RTL.
        let rtl = container.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let offscreen = CGAffineTransform(translationX: (rtl ? -1 : 1) * container.bounds.width, y: 0)
        let hidden: () -> Void = {
            switch self.enter {
            case .side: view.transform = offscreen
            default: view.alpha = 0
            }
        }
        let shown: () -> Void = {
            view.transform = .identity
            view.alpha = 1
        }
        if presenting { hidden() }
        let duration = transitionDuration(using: context)
        let finish: (UIViewAnimatingPosition) -> Void = { _ in
            context.completeTransition(!context.transitionWasCancelled)
        }
        let animator: UIViewPropertyAnimator
        if presenting && enter == .side {
            // The page transition's spring (look.rs `smooth`).
            let spring = UISpringTimingParameters(
                mass: 1, stiffness: CGFloat(tokens.springStiffness),
                damping: Self.damping(percent: tokens.springDampingPercent, stiffness: tokens.springStiffness),
                initialVelocity: .zero)
            animator = UIViewPropertyAnimator(duration: duration, timingParameters: spring)
        } else {
            let curve = presenting ? tokens.fadeCurve : tokens.exitCurve
            animator = UIViewPropertyAnimator(duration: duration, timingParameters: Self.cubic(curve))
        }
        animator.addAnimations(presenting ? shown : hidden)
        animator.addCompletion(finish)
        animator.startAnimation()
    }

    /// Damping coefficient for a ratio (percent) at mass 1: c = 2ζ√k.
    static func damping(percent: UInt32, stiffness: UInt32) -> CGFloat {
        2 * CGFloat(percent) / FunnelPresentationFormat.percent * CGFloat(stiffness).squareRoot()
    }

    static func cubic(_ points: [UInt32]) -> UICubicTimingParameters {
        guard points.count == 4 else { return UICubicTimingParameters(animationCurve: .easeInOut) }
        let p = points.map { CGFloat($0) / FunnelPresentationFormat.thousandths }
        return UICubicTimingParameters(
            controlPoint1: CGPoint(x: p[0], y: p[1]), controlPoint2: CGPoint(x: p[2], y: p[3]))
    }
}

// MARK: - Rovenue.presentFunnel

extension Rovenue {
    /// Present the funnel a placement serves, the way the funnel's editor
    /// settings say (full screen, modal or sheet), and wait until it ends.
    ///
    /// The placement is resolved first — instantly after
    /// `preloadPlacement(_:)` — and nothing is presented when it serves no
    /// funnel. The SDK performs purchases and restores itself unless you
    /// pass `handlers.onPurchase` / `onRestore`, and closes after a
    /// successful one when the funnel is set to "Close after purchase".
    /// While a purchase runs the funnel cannot be swiped away.
    ///
    /// Only one funnel is presented at a time: a second call while one is
    /// up resolves `.unavailable` with reason `alreadyPresented`.
    ///
    /// - Parameters:
    ///   - placement: the placement identifier.
    ///   - locale: the locale to resolve text in; the device's when nil.
    ///   - style: overrides the funnel's own presentation, field by field.
    ///   - from: the controller to present from; the top-most when nil.
    ///   - handlers: purchase, restore, error, URL, custom-action, photo and
    ///     check hooks.
    ///   - values: values for the funnel's declared externals (an ad's
    ///     scene, a campaign) — trimmed, 512 characters at most, undeclared
    ///     names dropped. A fresh value overrides a restored one and
    ///     preselects a `defaultFrom` question. Never pass personal data:
    ///     values are written to the on-device session state.
    /// - Returns: how it ended, whether something was bought, the
    ///   entitlements after it, the last purchase error and the photos.
    @available(iOS 15.0, *)
    @MainActor
    public func presentFunnel(
        placement: String,
        locale: String? = nil,
        style: FunnelPresentationOverride? = nil,
        from: UIViewController? = nil,
        handlers: FunnelPresentHandlers = .init(),
        values: [String: String] = [:]
    ) async -> FunnelPresentResult {
        let presenter = FunnelPresenter.shared
        guard presenter.claim() else { return .unavailable(FunnelPresentResult.alreadyPresented) }
        let resolution: FunnelResolution
        do {
            resolution = try await getFunnel(placementId: placement, locale: locale, values: values)
        } catch {
            presenter.release()
            let rovenue = (error as? RovenueError) ?? RovenueError(kind: .internal, message: error.localizedDescription)
            return .unavailable(rovenue.serverCode ?? String(describing: rovenue.kind), lastError: rovenue)
        }
        guard case .funnel(let resolved) = resolution else {
            presenter.release()
            if case .unavailable(let unavailable) = resolution {
                return .unavailable(unavailable.reason.wireName)
            }
            return .unavailable(FunnelPresentResult.noPresenter)
        }
        guard let host = from ?? FunnelPresenterLookup.topMost(), host.viewIfLoaded?.window != nil else {
            resolved.session.dismiss()
            presenter.release()
            return .unavailable(FunnelPresentResult.noPresenter)
        }
        let presentation = FunnelPresentation(
            resolved: resolved, style: style, handlers: handlers, offering: resolved.offering)
        presenter.attach(presentation)
        return await presentation.run(from: host, isDraft: resolved.isDraft)
    }
}

// MARK: - SwiftUI

extension View {
    /// Presents the funnel a placement serves while `isPresented` is true
    /// (`Rovenue.presentFunnel`), and sets it back to false when the funnel
    /// ends, handing `onResult` how it ended.
    ///
    /// - Parameters:
    ///   - isPresented: the binding that presents the funnel.
    ///   - placement: the placement identifier.
    ///   - locale: the locale to resolve text in; the device's when nil.
    ///   - style: overrides the funnel's own presentation.
    ///   - handlers: purchase, restore, error, URL, custom-action, photo and
    ///     check hooks.
    ///   - values: values for the funnel's declared externals
    ///     (`Rovenue.presentFunnel(values:)`).
    ///   - onResult: how the presentation ended.
    @available(iOS 15.0, *)
    public func rovenueFunnel(
        isPresented: Binding<Bool>,
        placement: String,
        locale: String? = nil,
        style: FunnelPresentationOverride? = nil,
        handlers: FunnelPresentHandlers = .init(),
        values: [String: String] = [:],
        onResult: @escaping (FunnelPresentResult) -> Void = { _ in }
    ) -> some View {
        modifier(FunnelPresentModifier(
            isPresented: isPresented, placement: placement, locale: locale, style: style,
            handlers: handlers, values: values, onResult: onResult))
    }
}

@available(iOS 15.0, *)
private struct FunnelPresentModifier: ViewModifier {
    @Binding var isPresented: Bool
    let placement: String
    let locale: String?
    let style: FunnelPresentationOverride?
    let handlers: FunnelPresentHandlers
    let values: [String: String]
    let onResult: (FunnelPresentResult) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { presented in
            guard presented else { return }
            Task { @MainActor in
                let result = await Rovenue.shared.presentFunnel(
                    placement: placement, locale: locale, style: style, handlers: handlers, values: values)
                isPresented = false
                onResult(result)
            }
        }
    }
}
#endif
