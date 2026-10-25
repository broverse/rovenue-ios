//  FunnelFonts.swift — the funnel's fonts on device (spec
//  2026-10-11-genre-funnel-templates §10.4 V5).
//
//  A funnel theme names catalog families (Fraunces, Space Grotesk…) the app
//  does not bundle. The API serves each as TrueType faces plus a manifest
//  (`/funnel-fonts/manifest.json`); this store fetches only the faces a
//  screen draws in, keeps them in the caches directory, and registers them
//  with CoreText for the process. The DRAWER still performs no I/O: it asks
//  CoreText for the family (`funnelResolvedFontFamily`) and gets the system
//  face until registration lands, then the driver redraws.

import CoreText
import Foundation

private enum FontStoreFormat {
    static let manifestPath = "funnel-fonts/manifest.json"
    static let facesPath = "funnel-fonts"
    static let cacheFolder = "rovenue-funnel-fonts"
    static let stackSeparator: Character = ","
    static let quotes = CharacterSet(charactersIn: "'\"")
}

/// The first family of a CSS font stack (`'Fraunces', Georgia, serif` →
/// `Fraunces`), or a bare family name as is. Nil for an empty value.
func funnelPrimaryFamily(_ stack: String?) -> String? {
    guard let stack, let first = stack.split(separator: FontStoreFormat.stackSeparator).first else { return nil }
    let name = first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: FontStoreFormat.quotes)
    return name.isEmpty ? nil : name
}

/// Every family a screen's blocks draw in (their resolved `fontFamily`s).
func funnelFamilies(in screen: RenderScreen) -> Set<String> {
    var out = Set<String>()
    func visit(_ style: RenderStyle) {
        if let family = funnelPrimaryFamily(style.fontFamily) { out.insert(family) }
    }
    func walk(_ blocks: [RenderBlock]) {
        for block in blocks {
            switch block {
            case .heading(let b): visit(b.style)
            case .text(let b): visit(b.style)
            case .button(let b): visit(b.style)
            case .review(let b): visit(b.style)
            case .question(let b): visit(b.style)
            case .packageList(let b): visit(b.style)
            case .comparisonTable(let b): visit(b.style)
            case .featureList(let b): visit(b.style)
            case .purchaseButton(let b): visit(b.style)
            case .stack(let b): walk(b.children)
            case .stickyFooter(let b): walk(b.children)
            case .expressCheckout(let b): walk(b.children)
            // A progress label draws in the system face.
            case .image, .video, .spacer, .icon, .divider, .activity, .gallery, .progress: break
            }
        }
    }
    walk(screen.blocks)
    if let cta = screen.cta { visit(cta.style) }
    return out
}

/// The families a screen draws an `*italic*` run in: a heading or text block
/// whose segments mark one. Only these fetch their italic faces — a screen
/// with no italic copy downloads none (spec 2026-10-12-open-followups §4).
/// Registered with CoreText under the same family name, the italic face is
/// what `Font.custom(family).italic()` resolves to; without it SwiftUI
/// draws the run upright (it never synthesises a slant for a custom font).
func funnelItalicFamilies(in screen: RenderScreen) -> Set<String> {
    var out = Set<String>()
    func visit(_ style: RenderStyle, _ segments: [RenderSegment]?) {
        guard segments?.contains(where: { $0.italic }) == true,
            let family = funnelPrimaryFamily(style.fontFamily)
        else { return }
        out.insert(family)
    }
    func walk(_ blocks: [RenderBlock]) {
        for block in blocks {
            switch block {
            case .heading(let b): visit(b.style, b.segments)
            case .text(let b): visit(b.style, b.segments)
            case .stack(let b): walk(b.children)
            case .stickyFooter(let b): walk(b.children)
            case .expressCheckout(let b): walk(b.children)
            default: break
            }
        }
    }
    walk(screen.blocks)
    return out
}

/// Downloads, caches and registers catalog faces. One per process.
actor FunnelFontStore {
    static let shared = FunnelFontStore()

    private var manifest: Manifest?
    private var registered = Set<String>()

    private struct Manifest: Decodable {
        let families: [String: [String: String]]
        /// Family → weight → italic face, for the families that have one.
        let italics: [String: [String: String]]?
    }

    /// Makes every face of `families` the catalog has available to
    /// CoreText. True when at least one face was newly registered — the
    /// caller redraws. A failure (offline, a 404) registers nothing and the
    /// drawers keep the system face.
    func ensure(_ families: Set<String>, italics: Set<String> = [], base: URL) async -> Bool {
        guard !families.isEmpty || !italics.isEmpty, let manifest = await loadManifest(base: base) else { return false }
        var added = false
        let wanted =
            families.compactMap { manifest.families[$0] }
            + italics.compactMap { manifest.italics?[$0] }
        for faces in wanted {
            for path in faces.values where !registered.contains(path) {
                guard let file = await cachedFace(path, base: base) else { continue }
                var error: Unmanaged<CFError>?
                // Already registered by an earlier run in this process is fine.
                _ = CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
                registered.insert(path)
                added = true
            }
        }
        return added
    }

    private func loadManifest(base: URL) async -> Manifest? {
        if let manifest { return manifest }
        let url = base.appendingPathComponent(FontStoreFormat.manifestPath)
        guard let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == HTTPStatus.ok,
            let decoded = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        manifest = decoded
        return decoded
    }

    private func cachedFace(_ path: String, base: URL) async -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let file = caches.appendingPathComponent(FontStoreFormat.cacheFolder).appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let url = base.appendingPathComponent(FontStoreFormat.facesPath).appendingPathComponent(path)
        guard let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == HTTPStatus.ok
        else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return file
    }
}

private enum HTTPStatus {
    static let ok = 200
}
