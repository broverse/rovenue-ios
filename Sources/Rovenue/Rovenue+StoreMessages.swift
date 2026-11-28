//  Rovenue+StoreMessages.swift — App Store messages (billing issue, price
//  increase consent, win-back offer, generic) shown when the app chooses.
//
//  StoreKit 2 (iOS 16+) delivers App Store messages through
//  `Message.messages`. With no listener, StoreKit displays each one itself
//  when the app comes to the foreground — the default, and what
//  `automaticStoreMessages: true` keeps. With `automaticStoreMessages: false`
//  the SDK listens instead, holds every message, and the app calls
//  `showStoreMessages(for:)` once a screen can be covered (after onboarding,
//  never over a checkout). Apple: "Message", "Message.messages",
//  "Message.Reason", "DisplayMessageAction".

import Foundation
import StoreKit

/// Why the App Store wants to show a message — StoreKit's `Message.Reason`.
public enum StoreMessageType: String, CaseIterable, Sendable {
    /// The subscription could not be renewed: the payment method needs
    /// fixing (`Message.Reason.billingIssue`, iOS 16.4+).
    case billingIssue
    /// The subscriber has to agree to a price increase
    /// (`Message.Reason.priceIncreaseConsent`).
    case priceIncreaseConsent
    /// Any other App Store message (`Message.Reason.generic`), including a
    /// reason newer than this SDK.
    case generic
    /// A win-back offer for a lapsed subscriber
    /// (`Message.Reason.winBackOffer`, iOS 18+).
    case winBackOffer
}

extension Set where Element == StoreMessageType {
    /// Every message type.
    public static var all: Set<StoreMessageType> { Set(StoreMessageType.allCases) }
}

extension Rovenue {
    /// Shows the App Store messages the SDK has held, of the given types,
    /// in the order they arrived. Only messages held because `configure`
    /// was called with `automaticStoreMessages: false` are shown here; with
    /// the default (`true`) StoreKit displays them itself and this does
    /// nothing.
    ///
    /// Each message is shown once. Without a foreground window scene
    /// (the app is in the background, or this is an app extension), nothing
    /// is shown and the messages stay held for a later call. Messages of a
    /// type not asked for stay held too.
    ///
    /// A message the App Store sends before `configure` runs is displayed by
    /// StoreKit itself: call `configure` early (at launch) for the SDK to
    /// hold them. iOS 16+ only; elsewhere (macOS) it does nothing.
    @MainActor
    public func showStoreMessages(for types: Set<StoreMessageType> = .all) async {
        #if os(iOS) || os(visionOS)
        let center = StoreMessageCenter.shared
        guard center.queue.count > 0 else {
            Rovenue.emit(LogEntry(level: "debug", message: "showStoreMessages: nothing held"))
            return
        }
        guard let scene = HostScene.foregroundWindowScene() else {
            Rovenue.emit(LogEntry(
                level: "warn",
                message: "showStoreMessages: no foreground window scene; \(center.queue.count) message(s) stay held"
            ))
            return
        }
        let shown = center.queue.show(types: types, in: scene)
        Rovenue.emit(LogEntry(level: "info", message: "showStoreMessages: displayed \(shown)"))
        #endif
    }
}

/// The messages StoreKit handed over while the SDK listens, in arrival
/// order. Generic over the scene so its rules run under `swift test` on
/// macOS, where StoreKit has no `Message`.
@MainActor
final class StoreMessageQueue<Scene> {
    struct Entry {
        let type: StoreMessageType
        /// Displays the message in a scene; throws when StoreKit refuses.
        let display: @MainActor (Scene) throws -> Void
    }

    private var pending: [Entry] = []

    var count: Int { pending.count }
    var pendingTypes: [StoreMessageType] { pending.map(\.type) }

    func enqueue(_ entry: Entry) {
        pending.append(entry)
    }

    /// Displays every held message whose type is in `types`, oldest first,
    /// and returns how many were displayed. Each one leaves the queue before
    /// it is displayed, so it is never shown twice; one StoreKit refuses is
    /// kept. With no scene nothing is displayed.
    @discardableResult
    func show(types: Set<StoreMessageType>, in scene: Scene?) -> Int {
        guard let scene, !types.isEmpty else { return 0 }
        let batch = pending
        pending = []
        var kept: [Entry] = []
        var shown = 0
        for entry in batch {
            guard types.contains(entry.type) else {
                kept.append(entry)
                continue
            }
            do {
                try entry.display(scene)
                shown += 1
            } catch {
                kept.append(entry)
            }
        }
        // Anything a display enqueued meanwhile stays after what was kept.
        pending = kept + pending
        return shown
    }
}

#if os(iOS) || os(visionOS)
import UIKit

/// The process-wide listener on `Message.messages`. One per process, not
/// per `Rovenue` instance: a second `configure` must not start a second
/// listener (each message would be held twice), and messages held before it
/// must survive it.
@MainActor
final class StoreMessageCenter {
    static let shared = StoreMessageCenter()

    let queue = StoreMessageQueue<UIWindowScene>()
    private var listener: Task<Void, Never>?

    /// `true`: StoreKit displays messages itself (no listener). `false`:
    /// listen and hold them for `showStoreMessages`. Idempotent; held
    /// messages stay held when switching back to automatic.
    func setAutomatic(_ automatic: Bool) {
        if automatic {
            listener?.cancel()
            listener = nil
            return
        }
        guard listener == nil else { return }
        listener = Task { @MainActor [weak self] in
            for await message in Message.messages {
                guard let self, !Task.isCancelled else { break }
                self.queue.enqueue(.init(type: StoreMessageType(message.reason)) { scene in
                    try message.display(in: scene)
                })
                Rovenue.emit(LogEntry(
                    level: "info",
                    message: "App Store message held: \(StoreMessageType(message.reason).rawValue)"
            ))
            }
        }
    }
}

extension StoreMessageType {
    /// A reason newer than this SDK, or one this OS version cannot name,
    /// reads as `.generic`.
    init(_ reason: Message.Reason) {
        if reason == .priceIncreaseConsent {
            self = .priceIncreaseConsent
            return
        }
        if #available(iOS 16.4, visionOS 1.0, *), reason == .billingIssue {
            self = .billingIssue
            return
        }
        if #available(iOS 18.0, visionOS 2.0, *), reason == .winBackOffer {
            self = .winBackOffer
            return
        }
        self = .generic
    }
}

/// The app's foreground window scene, for StoreKit sheets and messages.
enum HostScene {
    /// The first `foregroundActive` window scene; nil in the background,
    /// with no window scene, or inside an app extension (no
    /// `UIApplication.shared` there — read by selector so the package still
    /// builds for extension targets).
    @MainActor
    static func foregroundWindowScene() -> UIWindowScene? {
        guard !Bundle.main.bundlePath.hasSuffix(".appex"),
              let app = UIApplication.value(forKey: "sharedApplication") as? UIApplication
        else { return nil }
        return app.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}
#endif

extension Rovenue {
    /// `configure`'s `automaticStoreMessages`, applied on main (the listener
    /// is main-actor state). A no-op where StoreKit has no `Message`.
    static func applyStoreMessageMode(automatic: Bool) {
        #if os(iOS) || os(visionOS)
        if Thread.isMainThread {
            MainActor.assumeIsolated { StoreMessageCenter.shared.setAutomatic(automatic) }
        } else {
            DispatchQueue.main.async { StoreMessageCenter.shared.setAutomatic(automatic) }
        }
        #endif
    }
}
