import AVFoundation
import Foundation

// The sounds a funnel's `play_sound` actions play (spec 2026-11-27-funnel-
// authoring-fidelity §I).
//
// The placement envelope lists them (`CoreFunnel.sounds`, read through
// `FunnelSession.sounds()`); the driver hands that list to `prefetch` as the
// funnel opens, which downloads each file, checks it against its SHA-256
// `hash` and caches it under that hash (so it survives relaunches and is
// never fetched twice), the way `FunnelFontStore` treats uploaded faces.
//
// `play` NEVER waits on the network: a sound that is not cached yet is
// skipped, not delayed — the chain has already moved on. iOS plays in the
// `ambient` category while a funnel is presented, unless the host app
// already chose a category of its own, which is left alone; the previous
// category comes back when the funnel ends (`FunnelAudioCategoryLease`,
// ruling R17).

private enum SoundStoreFormat {
    static let cacheFolder = "rovenue-funnel-sounds"
    /// The containers an audio asset is stored as (`ASSET_AUDIO_EXTENSIONS`).
    static let extensions: Set<String> = ["mp3", "m4a"]
    static let sha256HexLength = 64
    static let maxVolume: Float = 100
}

/// Downloads, caches and plays funnel sounds. One per process.
actor FunnelSoundStore {
    static let shared = FunnelSoundStore()

    typealias Fetch = @Sendable (URL) async -> Data?
    /// Plays the cached file at a volume 0...1; false when it could not.
    typealias Play = @Sendable (URL, Float) async -> Bool

    private let fetch: Fetch
    private let player: Play
    private let cacheRoot: URL?
    /// url → the cached file it plays from, once downloaded and checked.
    private var ready: [String: URL] = [:]
    /// Hashes being downloaded, each one task every concurrent prefetch awaits.
    private var inFlight: [String: Task<URL?, Never>] = [:]
    /// Hashes whose download failed its hash check: not fetched again.
    private var refused = Set<String>()

    init(
        fetch: @escaping Fetch = FunnelFontStore.httpGet,
        player: @escaping Play = FunnelSoundStore.systemPlay,
        cacheRoot: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(SoundStoreFormat.cacheFolder)
    ) {
        self.fetch = fetch
        self.player = player
        self.cacheRoot = cacheRoot
    }

    /// Makes every sound playable from the cache. Failures are silent: a
    /// sound that never lands is simply skipped when its action runs. A
    /// transient failure (offline, a non-200, a cache write) is tried again
    /// by the next `prefetch`.
    func prefetch(_ sounds: [FunnelSound]) async {
        for sound in sounds where ready[sound.url] == nil {
            if let file = await load(sound) { ready[sound.url] = file }
        }
    }

    /// Whether `url` plays now (it is cached).
    func isReady(_ url: String) -> Bool {
        ready[url] != nil
    }

    /// Plays `url` at `volume` (0...100) when it is cached; otherwise
    /// skips it at once. True when it played.
    @discardableResult
    func play(url: String, volume: UInt32) async -> Bool {
        guard let file = ready[url] else { return false }
        let level = min(Float(volume), SoundStoreFormat.maxVolume) / SoundStoreFormat.maxVolume
        return await player(file, level)
    }

    private func load(_ sound: FunnelSound) async -> URL? {
        let hash = sound.hash.lowercased()
        // The hash names a file on disk: anything but 64 hex digits never
        // reaches a path; the extension comes only from the known containers.
        guard hash.count == SoundStoreFormat.sha256HexLength, hash.allSatisfy(\.isHexDigit),
            !refused.contains(hash), let url = URL(string: sound.url),
            SoundStoreFormat.extensions.contains(url.pathExtension.lowercased()), let cacheRoot
        else { return nil }
        if let running = inFlight[hash] { return await running.value }
        let file = cacheRoot.appendingPathComponent("\(hash).\(url.pathExtension.lowercased())")
        let task = Task { await self.download(url, to: file, hash: hash) }
        inFlight[hash] = task
        let result = await task.value
        inFlight[hash] = nil
        return result
    }

    private func download(_ url: URL, to file: URL, hash: String) async -> URL? {
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let data = await fetch(url) else { return nil }
        guard funnelSHA256Hex(data) == hash else {
            refused.insert(hash)
            return nil
        }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return file
    }

    /// The system output: `FunnelSoundOutput.shared`, off the main actor.
    static let systemPlay: Play = { file, level in
        FunnelSoundOutput.shared.play(file, level: level)
    }
}

/// Plays cached files through AVAudioPlayer. Off the main actor: creating
/// and starting a player from a local file needs no UI thread.
final class FunnelSoundOutput: @unchecked Sendable {
    static let shared = FunnelSoundOutput(lease: .shared)

    private let lease: FunnelAudioCategoryLease
    private let lock = NSLock()
    /// Players still sounding, kept alive until they finish.
    private var playing: [AVAudioPlayer] = []

    init(lease: FunnelAudioCategoryLease) {
        self.lease = lease
    }

    func play(_ file: URL, level: Float) -> Bool {
        lease.prepareForPlayback()
        guard let player = try? AVAudioPlayer(contentsOf: file) else { return false }
        player.volume = level
        guard player.play() else { return false }
        // The category stays the funnel's until this sound has played out.
        lease.soundPlaying(for: player.duration)
        lock.lock()
        playing.removeAll { !$0.isPlaying }
        playing.append(player)
        lock.unlock()
        return true
    }
}

/// The app's audio category, as the lease reads and writes it. An opaque
/// pair (category raw value, options raw value), so a test fakes it on
/// any platform.
struct FunnelAudioCategory: Equatable {
    let category: String
    let options: UInt
}

/// What the lease may do to the app's audio session (`AVAudioSession` on
/// iOS; nothing elsewhere).
protocol FunnelAudioSessionControlling: AnyObject {
    /// The category and options now.
    func current() -> FunnelAudioCategory
    /// Whether `current()` is the system default (`.soloAmbient`) — a
    /// category no host chose.
    func isSystemDefault(_ category: FunnelAudioCategory) -> Bool
    /// The category funnel sounds play in: `.ambient` + `.mixWithOthers`.
    var funnelCategory: FunnelAudioCategory { get }
    /// Sets `category`; false when the system refused.
    func set(_ category: FunnelAudioCategory) -> Bool
}

/// Ruling R17: funnel sounds play in `.ambient` (the silent switch mutes
/// them, other audio keeps playing) — but the app's audio session is the
/// HOST's. So the category is changed only while it is still the system
/// default (`.soloAmbient`), only once a presented funnel actually plays a
/// sound, and the previous category is RESTORED when the last presented
/// funnel holding the lease ends. A host that set its own category
/// (`.playback`, …) is never touched; funnel sounds then follow its choice.
///
/// Every presented funnel that serves sounds `acquire`s once and
/// `release`s once (`FunnelDriver`); the category is restored only when
/// no holder remains, and only if it is still the one the lease set (a
/// host that changed it meanwhile keeps its change).
///
/// A sound a funnel started is not cut over to the host's category: the
/// restore waits until every sound dispatched under the lease has started
/// (`soundDispatched` / `soundSettled`, bracketing the fire-and-forget
/// play) and played out (`soundPlaying(for:)`, bounded by the file's
/// length). The funnel's UI closes at once; only the category waits — so a
/// `play_sound` before `close_funnel` in one chain plays in `.ambient`.
final class FunnelAudioCategoryLease: @unchecked Sendable {
    static let shared = FunnelAudioCategoryLease(session: FunnelSystemAudioSession.make())

    /// Seconds on a monotonic clock.
    typealias Clock = @Sendable () -> TimeInterval
    /// Runs the closure after the delay, in seconds.
    typealias Schedule = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private let session: FunnelAudioSessionControlling?
    private let now: Clock
    private let schedule: Schedule
    private let lock = NSLock()
    private var holders = 0
    /// What the category was before the lease changed it; nil while unchanged.
    private var saved: FunnelAudioCategory?
    /// Sounds dispatched under the lease that have not started (or been skipped) yet.
    private var pendingSounds = 0
    /// When the last sound started under the lease stops playing.
    private var soundsUntil: TimeInterval = 0

    init(
        session: FunnelAudioSessionControlling?,
        now: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Schedule = { delay, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { work() }
        }
    ) {
        self.session = session
        self.now = now
        self.schedule = schedule
    }

    /// A funnel holding the lease hands a `play_sound` to the player (which
    /// plays it asynchronously). Synchronous, before the chain's next action
    /// — a `close_funnel` — can release the lease.
    func soundDispatched() {
        lock.lock()
        pendingSounds += 1
        lock.unlock()
    }

    /// The dispatched sound started (`soundPlaying(for:)` already called) or
    /// was skipped.
    func soundSettled() {
        lock.lock()
        defer { lock.unlock() }
        pendingSounds = max(0, pendingSounds - 1)
        restoreIfDone()
    }

    /// A sound started under the lease and plays for `duration` seconds.
    func soundPlaying(for duration: TimeInterval) {
        lock.lock()
        soundsUntil = max(soundsUntil, now() + max(0, duration))
        lock.unlock()
    }

    /// How many presented funnels hold the lease (tests read it).
    var holderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return holders
    }

    func acquire() {
        lock.lock()
        holders += 1
        lock.unlock()
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard holders > 0 else { return }
        holders -= 1
        restoreIfDone()
    }

    /// With the lock held: gives the category back once no funnel holds the
    /// lease and every sound it started has played out; while one still
    /// plays, tries again when it ends.
    private func restoreIfDone() {
        guard holders == 0, pendingSounds == 0, let previous = saved, let session else { return }
        let remaining = soundsUntil - now()
        if remaining > 0 {
            schedule(remaining) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.restoreIfDone()
            }
            return
        }
        saved = nil
        if session.current() == session.funnelCategory { _ = session.set(previous) }
    }

    /// Before a sound plays: the funnel category, if a funnel holds the
    /// lease (or dispatched this sound before it let go) and the app is
    /// still on the system default.
    func prepareForPlayback() {
        lock.lock()
        defer { lock.unlock() }
        guard holders > 0 || pendingSounds > 0, saved == nil, let session else { return }
        let now = session.current()
        guard session.isSystemDefault(now), session.set(session.funnelCategory) else { return }
        saved = now
    }
}

/// `AVAudioSession` as the lease sees it; nil where there is none (macOS).
final class FunnelSystemAudioSession: FunnelAudioSessionControlling {
    static func make() -> FunnelAudioSessionControlling? {
        #if os(iOS)
            return FunnelSystemAudioSession()
        #else
            return nil
        #endif
    }

    #if os(iOS)
        func current() -> FunnelAudioCategory {
            let session = AVAudioSession.sharedInstance()
            return FunnelAudioCategory(category: session.category.rawValue, options: session.categoryOptions.rawValue)
        }

        func isSystemDefault(_ category: FunnelAudioCategory) -> Bool {
            category.category == AVAudioSession.Category.soloAmbient.rawValue
        }

        var funnelCategory: FunnelAudioCategory {
            FunnelAudioCategory(
                category: AVAudioSession.Category.ambient.rawValue,
                options: AVAudioSession.CategoryOptions.mixWithOthers.rawValue)
        }

        func set(_ category: FunnelAudioCategory) -> Bool {
            (try? AVAudioSession.sharedInstance().setCategory(
                AVAudioSession.Category(rawValue: category.category),
                options: AVAudioSession.CategoryOptions(rawValue: category.options))) != nil
        }
    #else
        func current() -> FunnelAudioCategory { FunnelAudioCategory(category: "", options: 0) }
        func isSystemDefault(_ category: FunnelAudioCategory) -> Bool { false }
        var funnelCategory: FunnelAudioCategory { FunnelAudioCategory(category: "", options: 0) }
        func set(_ category: FunnelAudioCategory) -> Bool { false }
    #endif
}
