//  FunnelImageLoader.swift — funnel images from memory and disk, decoded at
//  the size they are drawn (spec 2026-11-03-placement-open-from-cache §4).
//
//  Every funnel image goes through one loader: a byte-bounded memory cache of
//  decoded, DOWNSAMPLED bitmaps (keyed by URL + target pixel width) over a
//  disk cache of the original bytes in Caches/. A memory hit is answered
//  synchronously, so a reopened screen draws its images on the first frame
//  — no placeholder flash. Decoding runs off the main thread through ImageIO
//  (`CGImageSourceCreateThumbnailAtIndex`) at the drawn width × screen
//  scale, never the source size: a 3000 px collage costs what it shows.
//
//  Funnel asset URLs are immutable (one id per upload; the asset store
//  serves `Cache-Control: public, max-age=…, immutable`), so a disk entry is
//  never revalidated. The bitmap type is `CGImage`, drawn through
//  `Image(decorative:scale:)`, so the same code runs on iOS and macOS.

import CryptoKit
import Foundation
import ImageIO
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Sizes and names of the image caches. Named, never inline.
enum FunnelImageCacheFormat {
    /// Decoded bitmaps kept in memory (bytes).
    static let memoryBytes = 32 * 1024 * 1024
    /// Original image bytes kept on disk (bytes); trimmed least-recently-used.
    static let diskBytes = 100 * 1024 * 1024
    /// The folder under Caches/.
    static let diskFolder = "rovenue-funnel-images"
    /// The width (points) an image is decoded at when the drawer cannot say:
    /// a macOS host has no phone-width screen to read.
    static let fallbackWidthPoints: CGFloat = 430
    static let fallbackScale: CGFloat = 2
    static let httpOK = 200
    static let keySeparator = "#"
}

/// A decoded bitmap in `NSCache` (which needs a class).
private final class DecodedImage {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
    var cost: Int { image.bytesPerRow * image.height }
}

/// The width of the screen a funnel draws on, in points, and its scale.
@MainActor
func funnelScreenMetrics() -> (width: CGFloat, scale: CGFloat) {
    #if canImport(UIKit) && !os(watchOS)
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
        if let screen { return (screen.bounds.width, screen.scale) }
    #endif
    return (FunnelImageCacheFormat.fallbackWidthPoints, FunnelImageCacheFormat.fallbackScale)
}

/// The pixel width a full-width funnel image is decoded at on this screen —
/// what the drawers and `preloadPlacement` both ask for, so a prefetched
/// image is a memory hit when it is drawn.
@MainActor
func funnelFullWidthPixels() -> Int {
    let metrics = funnelScreenMetrics()
    return Int((metrics.width * metrics.scale).rounded(.up))
}

final class FunnelImageLoader: @unchecked Sendable {
    static let shared = FunnelImageLoader()

    private let memory = NSCache<NSString, DecodedImage>()
    private let directory: URL?
    private let session: URLSession
    private let lock = NSLock()
    /// One download per URL, however many views ask at once.
    private var downloads: [URL: Task<Data?, Never>] = [:]
    /// The full-width variant decoded per URL, so a smaller drawer (a
    /// feature icon) still has something to draw on its first frame.
    private var widestKey: [URL: (width: Int, key: NSString)] = [:]
    private let diskQueue = DispatchQueue(label: "dev.rovenue.funnel-images.disk", qos: .utility)

    init() {
        memory.totalCostLimit = FunnelImageCacheFormat.memoryBytes
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(FunnelImageCacheFormat.diskFolder, isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // The disk layer is ours: no URLCache under it (it would refuse
        // anything above 5 % of its capacity, a large collage included).
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Synchronous critical section (never spans an `await`).
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func key(_ url: URL, _ targetPixelWidth: Int) -> NSString {
        "\(url.absoluteString)\(FunnelImageCacheFormat.keySeparator)\(targetPixelWidth)" as NSString
    }

    /// The decoded image already in memory for `url` at `targetPixelWidth`
    /// (or a wider decode of it): synchronous, for the first frame.
    func cachedImage(url: URL, targetPixelWidth: Int) -> CGImage? {
        if let hit = memory.object(forKey: key(url, targetPixelWidth)) { return hit.image }
        let widest = locked { widestKey[url] }
        guard let widest, widest.width >= targetPixelWidth else { return nil }
        return memory.object(forKey: widest.key)?.image
    }

    /// `url` decoded at `targetPixelWidth`: memory, else disk, else network
    /// (written to disk). Nil when it cannot be fetched or decoded.
    func image(url: URL, targetPixelWidth: Int) async -> CGImage? {
        if let hit = cachedImage(url: url, targetPixelWidth: targetPixelWidth) { return hit }
        guard let data = await bytes(url) else { return nil }
        guard let decoded = await decode(data, targetPixelWidth: targetPixelWidth) else { return nil }
        let entry = DecodedImage(decoded)
        let entryKey = key(url, targetPixelWidth)
        memory.setObject(entry, forKey: entryKey, cost: entry.cost)
        locked {
            if (widestKey[url]?.width ?? 0) < targetPixelWidth {
                widestKey[url] = (targetPixelWidth, entryKey)
            }
        }
        return decoded
    }

    /// Warm memory and disk for `urls` (spec §5): every image is fetched and
    /// decoded at `targetPixelWidth`, concurrently.
    func prefetch(urls: [URL], targetPixelWidth: Int) async {
        await withTaskGroup(of: Void.self) { group in
            for url in Set(urls) {
                group.addTask { _ = await self.image(url: url, targetPixelWidth: targetPixelWidth) }
            }
        }
    }

    // MARK: - Bytes (disk, then network)

    private func bytes(_ url: URL) async -> Data? {
        if let file = diskFile(url), let data = await readDisk(file) { return data }
        let task: Task<Data?, Never> = locked {
            if let running = downloads[url] { return running }
            let started = Task<Data?, Never> { [session] in
                guard let (data, response) = try? await session.data(from: url),
                    (response as? HTTPURLResponse)?.statusCode == FunnelImageCacheFormat.httpOK
                else { return nil }
                return data
            }
            downloads[url] = started
            return started
        }
        let data = await task.value
        locked { downloads[url] = nil }
        if let data, let file = diskFile(url) { writeDisk(data, to: file) }
        return data
    }

    private func diskFile(_ url: URL) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    private func readDisk(_ file: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            diskQueue.async {
                let data = try? Data(contentsOf: file)
                if data != nil {
                    // Touch: the LRU trim keeps what was read last.
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date()], ofItemAtPath: file.path)
                }
                continuation.resume(returning: data)
            }
        }
    }

    /// Write, then trim the folder to `diskBytes`, oldest first. Off the
    /// caller's path: a full disk never blocks drawing.
    private func writeDisk(_ data: Data, to file: URL) {
        diskQueue.async { [directory] in
            try? data.write(to: file, options: .atomic)
            guard let directory else { return }
            Self.trim(directory)
        }
    }

    private static func trim(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys)
        else { return }
        var entries = files.compactMap { file -> (URL, Date, Int)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > FunnelImageCacheFormat.diskBytes else { return }
        entries.sort { $0.1 < $1.1 }
        for (file, _, size) in entries where total > FunnelImageCacheFormat.diskBytes {
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }

    // MARK: - Decode

    /// Decode at `targetPixelWidth` (never upscaled), EXIF orientation
    /// applied, off the main thread.
    private func decode(_ data: Data, targetPixelWidth: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            Self.downsample(data, targetPixelWidth: targetPixelWidth)
        }.value
    }

    static func downsample(_ data: Data, targetPixelWidth: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? targetPixelWidth
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? targetPixelWidth
        // The thumbnail size is the LONGER side: scale the target width by
        // the aspect so a tall image is not decoded narrower than drawn.
        let longest = max(width, height)
        let scale = min(1, Double(targetPixelWidth) / Double(max(width, 1)))
        let maxPixelSize = max(1, Int((Double(longest) * scale).rounded(.up)))
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// A funnel image: the loader's memory hit on the first frame, otherwise
/// `placeholder` until it is loaded. The call shape of `AsyncImage`'s
/// content/placeholder initializer. `targetWidth` is the width it is drawn
/// at, in points; nil means the screen width (a full-width image).
struct FunnelAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let targetWidth: CGFloat?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (url: URL, image: CGImage)?

    init(
        url: URL?,
        targetWidth: CGFloat? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.targetWidth = targetWidth
        self.content = content
        self.placeholder = placeholder
    }

    @MainActor
    private var targetPixelWidth: Int {
        guard let targetWidth else { return funnelFullWidthPixels() }
        return Int((targetWidth * displayScale).rounded(.up))
    }

    @MainActor
    private var current: CGImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return FunnelImageLoader.shared.cachedImage(url: url, targetPixelWidth: targetPixelWidth)
    }

    var body: some View {
        Group {
            if let image = current {
                content(Image(decorative: image, scale: displayScale))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, current == nil else { return }
            let width = targetPixelWidth
            if let image = await FunnelImageLoader.shared.image(url: url, targetPixelWidth: width) {
                loaded = (url, image)
            }
        }
    }
}
