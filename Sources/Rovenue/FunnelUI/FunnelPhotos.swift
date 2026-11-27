//  FunnelPhotos.swift — the on-device photo store behind a `photo_upload`
//  question (spec 2026-11-07-funnel-photo-upload-design §4, Spec B §6).
//
//  Native photos never leave the device: the SDK normalises the picked
//  image (EXIF orientation applied, ≤ 2048 px on the long edge, JPEG at
//  0.85 with every metadata block — EXIF, GPS, TIFF — dropped), writes it to
//  `<Caches>/rovenue/photos/<uuid>.jpg` (excluded from backup), answers the
//  question with `local:<uuid>` and hands the host the file.
//
//  The file outlives the session on purpose: the result is delivered at
//  session end, and a bridge hop (RN, Flutter) would race a deletion there.
//  It goes when the host calls `Rovenue.releasePhoto(_:)`, or at the first
//  store access (SDK configure, or a funnel touching a photo) once it is
//  older than `FunnelPhotoStore.retention`.
//
//  ImageIO only — no UIKit — so the store is the same code on the macOS
//  test host as on a device.

import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The photo a `photo_upload` question was answered with, as the host
/// receives it (`FunnelHostHandlers.onPhotoSelected`,
/// `FunnelPresentResult.photos`). An upright JPEG with no metadata.
public struct FunnelPhotoRef: Sendable, Equatable, Hashable {
    /// The file, a `file://` URL string. Valid until `Rovenue.releasePhoto`
    /// is called with it, or for 7 days.
    public let localUri: String
    /// Pixel width, after normalisation.
    public let width: Int
    /// Pixel height, after normalisation.
    public let height: Int
    /// The file's size in bytes.
    public let byteSize: Int
    /// Always `image/jpeg`.
    public let mimeType: String

    /// A photo reference with every field given — for host tests and
    /// previews; the SDK builds its own from the photo store.
    public init(localUri: String, width: Int, height: Int, byteSize: Int, mimeType: String) {
        self.localUri = localUri
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.mimeType = mimeType
    }
}

/// Why a picked image was refused.
enum FunnelPhotoError: Error, Equatable {
    /// Larger than `FunnelPhotoStore.maxSourceBytes` before normalisation.
    case tooLarge
    /// Not an image ImageIO can decode.
    case undecodable
    /// The store could not be written.
    case unwritable
}

enum FunnelPhotoStore {
    /// `local:` + a lowercase UUID — the only native photo reference the
    /// resolver accepts (P9); anything else is never turned into a path.
    static let refPrefix = "local:"
    /// The long edge a stored photo is scaled down to, at most.
    static let maxPixelSize = 2048
    /// The JPEG quality a photo is re-encoded at.
    static let jpegQuality = 0.85
    /// A source above this is refused before decoding (10 MB).
    static let maxSourceBytes = 10 * 1024 * 1024
    /// How long an unreleased photo is kept: 7 days.
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let mimeType = "image/jpeg"
    static let fileExtension = "jpg"
    private static let directoryPath = ["rovenue", "photos"]
    /// The lowercase-UUID shape after `local:` (8-4-4-4-12 hex).
    private static let uuidPattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

    /// The swept-once guard: the expiry sweep runs at the first access in a
    /// process, never on the drawing path again.
    private static let sweepOnce: Void = { sweepExpired(now: Date()) }()

    /// The store's directory, created (and excluded from backup) on demand.
    static func directory() -> URL? {
        let fm = FileManager.default
        guard var url = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        for part in directoryPath { url.appendPathComponent(part, isDirectory: true) }
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            } catch {
                return nil
            }
        }
        return url
    }

    /// The UUID of a well-formed `local:` reference, else nil.
    static func uuid(ofRef ref: String) -> String? {
        guard ref.hasPrefix(refPrefix) else { return nil }
        let id = String(ref.dropFirst(refPrefix.count))
        return id.range(of: uuidPattern, options: .regularExpression) != nil ? id : nil
    }

    /// The file behind a `local:` reference, when it is well formed AND the
    /// file is still there. A gone file means "not answered" (spec A §4).
    static func fileURL(forRef ref: String) -> URL? {
        _ = sweepOnce
        guard let id = uuid(ofRef: ref), let dir = directory() else { return nil }
        let url = dir.appendingPathComponent("\(id).\(fileExtension)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What the host receives for a stored reference, or nil when it is gone.
    static func photoRef(forRef ref: String) -> FunnelPhotoRef? {
        guard let url = fileURL(forRef: ref) else { return nil }
        return describe(url)
    }

    /// Normalises `data` and stores it. Returns the `local:` reference and
    /// what the host is handed.
    static func store(imageData data: Data) throws -> (ref: String, photo: FunnelPhotoRef) {
        _ = sweepOnce
        guard data.count <= maxSourceBytes else { throw FunnelPhotoError.tooLarge }
        guard let jpeg = normalizedJPEG(data) else { throw FunnelPhotoError.undecodable }
        guard let dir = directory() else { throw FunnelPhotoError.unwritable }
        let id = UUID().uuidString.lowercased()
        let url = dir.appendingPathComponent("\(id).\(fileExtension)")
        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            throw FunnelPhotoError.unwritable
        }
        guard let photo = describe(url) else { throw FunnelPhotoError.unwritable }
        return ("\(refPrefix)\(id)", photo)
    }

    /// Deletes a stored photo by its `localUri` (or its `local:` reference).
    /// Anything outside the store is ignored — never a path to delete.
    @discardableResult
    static func release(_ localUriOrRef: String) -> Bool {
        guard let dir = directory() else { return false }
        let target: URL?
        if localUriOrRef.hasPrefix(refPrefix) {
            target = uuid(ofRef: localUriOrRef).map { dir.appendingPathComponent("\($0).\(fileExtension)") }
        } else if let url = URL(string: localUriOrRef), url.isFileURL {
            target = url.standardizedFileURL
        } else {
            target = nil
        }
        guard let file = target,
            file.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path,
            file.pathExtension == fileExtension,
            uuid(ofRef: refPrefix + file.deletingPathExtension().lastPathComponent) != nil
        else { return false }
        return (try? FileManager.default.removeItem(at: file)) != nil
    }

    /// Removes every stored photo older than `retention`.
    static func sweepExpired(now: Date) {
        guard let dir = directory(),
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if now.timeIntervalSince(modified) > retention {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Decode with the EXIF orientation applied, scale the long edge to
    /// `maxPixelSize` at most, re-encode as JPEG. The destination is handed
    /// only the quality, so no source property (EXIF, GPS, TIFF, IPTC,
    /// maker notes) is carried over.
    static func normalizedJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    private static func describe(_ url: URL) -> FunnelPhotoRef? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return FunnelPhotoRef(
            localUri: url.absoluteString, width: width, height: height, byteSize: size,
            mimeType: mimeType)
    }

    /// The photo answers in a persisted session (`FunnelSessionDriving.
    /// stateJson`), by question key, whose files still exist — what a
    /// presentation's result carries.
    static func photos(inStateJson json: String) -> [String: FunnelPhotoRef] {
        var out: [String: FunnelPhotoRef] = [:]
        for (key, ref) in localAnswers(inStateJson: json) {
            if let photo = photoRef(forRef: ref) { out[key] = photo }
        }
        return out
    }

    /// Every `local:` text answer by key, file or not. The session state is
    /// `{presentation_id, state: {answers: {…}}}` in core-rs; a bare
    /// funnel-core state (`{answers: {…}}`) is read too.
    static func localAnswers(inStateJson json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        let state = (root["state"] as? [String: Any]) ?? root
        guard let answers = state["answers"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in answers {
            if let text = value as? String, uuid(ofRef: text) != nil { out[key] = text }
        }
        return out
    }
}

// MARK: - Drawing a stored photo

/// Draws a `local:` photo from the store — never from a URL (Spec B §6).
/// A gone file draws nothing; the caller decides what stands in.
struct FunnelLocalPhoto<Content: View, Placeholder: View>: View {
    let ref: String
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var loaded: (ref: String, image: CGImage)?

    init(
        ref: String, @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.ref = ref
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let loaded, loaded.ref == ref {
                content(Image(decorative: loaded.image, scale: 1))
            } else {
                placeholder()
            }
        }
        .task(id: ref) {
            let ref = ref
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let url = FunnelPhotoStore.fileURL(forRef: ref),
                    let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
            if let image { loaded = (ref, image) }
        }
    }
}
