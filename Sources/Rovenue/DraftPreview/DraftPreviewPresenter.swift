//  DraftPreviewPresenter.swift — puts the draft preview on screen (spec
//  2026-10-16 §3.4, C5): a UIHostingController presented full screen from
//  the top-most view controller of the foreground key window, on top of
//  whatever the app shows. The host app writes no view code.
//
//  Never twice (FM7): one presenter per process. A document for the session
//  already on screen refreshes it in place; a document for another session
//  (a deep link opened while one is showing) replaces its content in the
//  same controller. Only when nothing is on screen is anything presented.

#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class DraftPreviewPresenter {
    static let shared = DraftPreviewPresenter()

    /// How long "Preview ended" shows before the preview goes away.
    private static let endedBannerNanoseconds: UInt64 = 2_000_000_000
    /// How often a preview with no window to present from tries again
    /// (the app is still launching, or between scenes).
    private static let presentRetryNanoseconds: UInt64 = 500_000_000

    private var model: DraftPreviewModel?
    private var host: DraftPreviewHostingController?
    private weak var controller: DraftPreviewController?
    private var retry: Task<Void, Never>?
    private var endTimer: Task<Void, Never>?
    private var loggedNoWindow = false
    /// Sessions the person closed in this process. The core already never
    /// pairs a closed session again, but a host that configures the SDK a
    /// second time gets a new core with no such memory; this one outlives
    /// it, so a closed preview stays closed (FM7). A deep link clears it.
    private var closedSessionIds: Set<String> = []

    private init() {}

    func receive(_ fetch: PreviewFetch, controller: DraftPreviewController) {
        self.controller = controller
        switch fetch {
        case .notModified:
            return
        case let .document(sessionId, payloadJson, issuesJson, locale, appearance, etag):
            if model == nil, closedSessionIds.contains(sessionId) {
                controller.close()
                return
            }
            endTimer?.cancel()
            endTimer = nil
            if let model {
                guard model.sessionId != sessionId || model.etag != etag else { return }
                model.update(sessionId: sessionId, payloadJson: payloadJson, issuesJson: issuesJson, locale: locale, appearance: appearance, etag: etag)
                applyAppearance()
                logDraftPreview(DraftPreviewLogLevel.info, DraftPreviewLog.refreshed)
            } else {
                let model = DraftPreviewModel(onClose: { [weak self] in self?.closeByUser() })
                model.update(sessionId: sessionId, payloadJson: payloadJson, issuesJson: issuesJson, locale: locale, appearance: appearance, etag: etag)
                self.model = model
                present()
            }
        case .gone:
            guard let model, endTimer == nil else { return }
            model.showEnded()
            logDraftPreview(DraftPreviewLogLevel.info, DraftPreviewLog.ended)
            endTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.endedBannerNanoseconds)
                guard !Task.isCancelled else { return }
                self?.tearDown(animated: true)
            }
        }
    }

    /// `handleURL(_:)` opened a link: the person asked for that session.
    func allowReopening() {
        closedSessionIds.removeAll()
    }

    // MARK: - Presenting

    private func present() {
        guard host == nil, let model else { return }
        guard let top = Self.topViewController() else {
            if !loggedNoWindow {
                loggedNoWindow = true
                logDraftPreview(DraftPreviewLogLevel.info, DraftPreviewLog.noWindow)
            }
            retry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.presentRetryNanoseconds)
                guard !Task.isCancelled else { return }
                self?.present()
            }
            return
        }
        loggedNoWindow = false
        let host = DraftPreviewHostingController(rootView: DraftPreviewScreen(model: model))
        host.modalPresentationStyle = .fullScreen
        host.view.accessibilityIdentifier = DraftPreviewAccessibilityID.root
        host.onDismissedElsewhere = { [weak self] in self?.dismissedElsewhere() }
        self.host = host
        applyAppearance()
        top.present(host, animated: true)
        logDraftPreview(DraftPreviewLogLevel.info, DraftPreviewLog.presented)
    }

    /// The top-most view controller of the foreground key window.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else { return nil }
        guard let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        guard let top, !top.isBeingDismissed else { return nil }
        return top
    }

    /// `appearance` from the session (`light` / `dark`), else the device's.
    private func applyAppearance() {
        guard let host else { return }
        switch model?.appearance {
        case DraftPreviewAppearance.light: host.overrideUserInterfaceStyle = .light
        case DraftPreviewAppearance.dark: host.overrideUserInterfaceStyle = .dark
        default: host.overrideUserInterfaceStyle = .unspecified
        }
    }

    // MARK: - Leaving

    /// Close: the core stops following the session and never pairs it
    /// again; nothing is revoked server-side, so "Send to my app" re-opens.
    private func closeByUser() {
        rememberClosed()
        controller?.close()
        logDraftPreview(DraftPreviewLogLevel.info, DraftPreviewLog.closed)
        tearDown(animated: true)
    }

    /// The app dismissed the preview itself (its own `dismiss` on a view
    /// controller below it): treated as Close, so the next poll does not
    /// present the same session again.
    private func dismissedElsewhere() {
        guard host != nil else { return }
        rememberClosed()
        controller?.close()
        host = nil
        tearDown(animated: false)
    }

    private func rememberClosed() {
        if let id = model?.sessionId, !id.isEmpty { closedSessionIds.insert(id) }
    }

    private func tearDown(animated: Bool) {
        retry?.cancel()
        retry = nil
        endTimer?.cancel()
        endTimer = nil
        model?.purchaseRequest = nil
        if let host {
            host.onDismissedElsewhere = nil
            host.presentingViewController?.dismiss(animated: animated)
        }
        host = nil
        model = nil
    }
}

/// The session `appearance` values (spec §3.1).
enum DraftPreviewAppearance {
    static let light = "light"
    static let dark = "dark"
}

/// Reports a dismissal the presenter did not start.
final class DraftPreviewHostingController: UIHostingController<DraftPreviewScreen> {
    var onDismissedElsewhere: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismissedElsewhere?()
        }
    }
}
#endif
