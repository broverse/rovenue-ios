//  AppLifecycleObserver.swift — the SDK reports foreground/background to the
//  core by itself (spec 2026-11-03-sdk-automatic-foreground-design.md).
//
//  The core's polling scheduler starts paused and ticks only while it is told
//  the app is in front; the attribute and session dispatchers ride that
//  scheduler. A host that never wired `setForeground` therefore never polled
//  and never sent attributes. This observer closes that gap without host code.
//
//  Threading: every piece of state is main-actor isolated (UIKit's
//  `applicationState` and `beginBackgroundTask` are main-thread APIs).
//  `start()` / `stop()` may be called from any thread: on main they run
//  synchronously; elsewhere they hop to the main queue, which is FIFO, so a
//  `stop` issued after a `start` always lands after it. No locks.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
internal final class AppLifecycleObserver {
    /// Called on main when the app enters the foreground (and once at start
    /// when it is already in front).
    private nonisolated let onForeground: @Sendable () -> Void
    /// Called on main when the app enters the background (and once at start
    /// when it launched into the background). `finish` must be called once
    /// the background work it started is done; it may be called on any
    /// thread.
    private nonisolated let onBackground: @Sendable (_ finish: @escaping @Sendable () -> Void) -> Void

    private var tokens: [NSObjectProtocol] = []
    private var started = false
    private var stopped = false

    nonisolated init(
        onForeground: @escaping @Sendable () -> Void,
        onBackground: @escaping @Sendable (_ finish: @escaping @Sendable () -> Void) -> Void
    ) {
        self.onForeground = onForeground
        self.onBackground = onBackground
    }

    /// Begin observing. Idempotent; a no-op after `stop()`, outside UIKit,
    /// and inside an app extension (no `UIApplication.shared` there).
    nonisolated func start() {
        onMain { $0.startOnMain() }
    }

    /// Stop observing. Idempotent and final — a later `start()` does nothing.
    /// `then` runs on main once observation has stopped, after any report a
    /// pending `start()` made.
    nonisolated func stop(then: (@MainActor () -> Void)? = nil) {
        onMain {
            $0.stopOnMain()
            then?()
        }
    }

    private func startOnMain() {
        guard !started, !stopped else { return }
        started = true
        #if canImport(UIKit)
        guard let app = Self.hostApplication() else { return }
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterForeground() }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterBackground() }
            },
        ]
        // `willEnterForeground` is not posted for the launch itself, so the
        // state at configure time is reported here. `.inactive` is the
        // launch state of an app coming to the front.
        if app.applicationState == .background {
            enterBackground()
        } else {
            enterForeground()
        }
        #endif
    }

    private func stopOnMain() {
        stopped = true
        let center = NotificationCenter.default
        tokens.forEach(center.removeObserver)
        tokens = []
    }

    private func enterForeground() {
        guard !stopped else { return }
        onForeground()
    }

    private func enterBackground() {
        guard !stopped else { return }
        #if canImport(UIKit)
        guard let app = Self.hostApplication() else { return }
        let task = BackgroundTask(app: app)
        onBackground { DispatchQueue.main.async { MainActor.assumeIsolated { task.end() } } }
        #endif
    }

    /// Run `body` on the main actor: synchronously when already on main,
    /// otherwise enqueued on the (FIFO) main queue.
    private nonisolated func onMain(_ body: @escaping @MainActor (AppLifecycleObserver) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body(self) } }
        }
    }

    #if canImport(UIKit)
    /// The host's `UIApplication`, or nil inside an app extension. Read by
    /// selector so the package still compiles for extension-only targets,
    /// where `UIApplication.shared` is unavailable.
    private static func hostApplication() -> UIApplication? {
        guard !Bundle.main.bundlePath.hasSuffix(Self.appExtensionSuffix) else { return nil }
        return UIApplication.value(forKey: Self.sharedApplicationKey) as? UIApplication
    }

    private static let appExtensionSuffix = ".appex"
    private static let sharedApplicationKey = "sharedApplication"

    /// One `beginBackgroundTask` / `endBackgroundTask` pair. `end()` runs at
    /// most once, whether the work finishes or the OS expires the task.
    private final class BackgroundTask {
        private let app: UIApplication
        private var id: UIBackgroundTaskIdentifier = .invalid

        init(app: UIApplication) {
            self.app = app
            id = app.beginBackgroundTask(withName: Self.name) { [weak self] in
                MainActor.assumeIsolated { self?.end() }
            }
        }

        @MainActor
        func end() {
            guard id != .invalid else { return }
            app.endBackgroundTask(id)
            id = .invalid
        }

        private static let name = "dev.rovenue.sdk.background-flush"
    }
    #endif
}
