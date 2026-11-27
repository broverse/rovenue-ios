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
import CryptoKit
import Foundation

private enum FontStoreFormat {
    static let manifestPath = "funnel-fonts/manifest.json"
    static let facesPath = "funnel-fonts"
    static let cacheFolder = "rovenue-funnel-fonts"
    static let stackSeparator: Character = ","
    static let quotes = CharacterSet(charactersIn: "'\"")
    /// Uploaded faces live under `<cacheFolder>/uploaded/<hash>.<format>`.
    static let uploadedFolder = "uploaded"
    static let uploadFormats: Set<String> = ["ttf", "otf", "woff2"]
    static let italicStyle = "italic"
    static let sha256HexLength = 64
    /// The size a registered face is built at only to read its name back.
    static let probeSize: CGFloat = 12
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
            case .packageList(let b):
                visit(b.style)
                // The authored row-name / price and secondary faces.
                for font in [b.primaryFont, b.secondaryFont] {
                    if let family = funnelPrimaryFamily(font?.family) { out.insert(family) }
                }
            case .comparisonTable(let b): visit(b.style)
            case .featureList(let b): visit(b.style)
            case .purchaseButton(let b): visit(b.style)
            case .stack(let b): walk(b.children)
            case .stickyFooter(let b): walk(b.children)
            case .expressCheckout(let b): walk(b.children)
            case .check(let b): visit(b.style)
            case .cardCheckout(let b): visit(b.style)
            case .carousel(let b): walk(b.children)
            case .accordion(let b):
                visit(b.style)
                for item in b.items { walk(item.children) }
            // Spec NE: the elements that draw text in their style's face.
            case .countdown(let b): visit(b.style)
            case .loader(let b): visit(b.style)
            case .chart(let b): visit(b.style)
            case .cookieConsent(let b): visit(b.style)
            case .popup(let b): walk(b.children)
            case .lottie: break
            // A progress label draws in the system face.
            case .image, .video, .spacer, .icon, .divider, .activity, .gallery, .progress: break
            }
        }
    }
    walk(screen.blocks)
    if let cta = screen.cta { visit(cta.style) }
    return out
}

/// The page's body font as the resolver wrote it onto its blocks (the
/// theme font, unless a block authored its own): the first `text` block's,
/// else the first copy-bearing block's, else the CTA's. Nil when none
/// carries one — the page then draws in the system face. The web's
/// `screenBodyFont` (purchase-overlay.tsx), walked in the same order:
/// blocks, header, overlay, each depth first, parents before children.
func funnelBodyFont(in screen: RenderScreen) -> String? {
    var firstCopy: String?
    var firstText: String?
    func walk(_ blocks: [RenderBlock]) {
        for block in blocks where firstText == nil {
            if let font = funnelBodyCandidate(block) {
                if block.kind == .text { firstText = font } else if firstCopy == nil { firstCopy = font }
            }
            walk(block.childBlocks)
        }
    }
    walk(screen.blocks)
    walk(screen.header)
    walk(screen.overlay)
    return firstText ?? firstCopy ?? screen.cta?.style.fontFamily
}

/// `block`'s font when it may carry the body face: nil for the blocks that
/// never do (a heading may wear the heading face; media and spacing draw
/// no copy) and for a block with no font. The web's `NOT_BODY`.
@inline(never)
private func funnelBodyCandidate(_ block: RenderBlock) -> String? {
    switch block {
    case .heading, .spacer, .divider, .image, .video, .icon, .activity: return nil
    case .text(let b): return b.style.fontFamily
    case .button(let b): return b.style.fontFamily
    case .review(let b): return b.style.fontFamily
    case .gallery(let b): return b.style.fontFamily
    case .stack(let b): return b.style.fontFamily
    case .progress(let b): return b.style.fontFamily
    case .question(let b): return b.style.fontFamily
    case .packageList(let b): return b.style.fontFamily
    case .comparisonTable(let b): return b.style.fontFamily
    case .featureList(let b): return b.style.fontFamily
    case .purchaseButton(let b): return b.style.fontFamily
    case .stickyFooter(let b): return b.style.fontFamily
    case .expressCheckout(let b): return b.style.fontFamily
    case .check(let b): return b.style.fontFamily
    case .cardCheckout(let b): return b.style.fontFamily
    case .carousel(let b): return b.style.fontFamily
    case .accordion(let b): return b.style.fontFamily
    case .countdown(let b): return b.style.fontFamily
    case .popup(let b): return b.style.fontFamily
    case .loader(let b): return b.style.fontFamily
    case .lottie(let b): return b.style.fontFamily
    case .chart(let b): return b.style.fontFamily
    case .cookieConsent(let b): return b.style.fontFamily
    }
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
            case .carousel(let b): walk(b.children)
            case .accordion(let b): for item in b.items { walk(item.children) }
            case .popup(let b): walk(b.children)
            default: break
            }
        }
    }
    walk(screen.blocks)
    return out
}

/// The UPLOADED files registered with CoreText: content hash → the
/// PostScript name its face is drawn by. Process-wide, as CoreText's
/// registration is; it knows nothing of families — which file a family
/// and weight draw is each FUNNEL's own (`FunnelSessionFonts`), so two
/// funnels naming one family with different files never mix (review R10).
///
/// An uploaded face is drawn by PostScript name, never by family name: the
/// uploaded name ("Baloo 2") is what the document says, while the file's
/// own family name can be anything, so CoreText's family lookup would miss
/// it. Written by `FunnelFontStore`, read on the main thread while drawing;
/// lock-guarded.
final class FunnelUploadedFaces: @unchecked Sendable {
    static let shared = FunnelUploadedFaces()

    private let lock = NSLock()
    private var byHash: [String: String] = [:]

    func record(hash: String, postScriptName: String) {
        lock.lock()
        defer { lock.unlock() }
        byHash[hash] = postScriptName
    }

    /// The PostScript name `hash`'s file draws by — nil when it is not
    /// registered, or when another file has since taken that name over
    /// (`FunnelPostScriptOwners`), so a name never draws the wrong file.
    func postScriptName(hash: String) -> String? {
        lock.lock()
        let name = byHash[hash]
        lock.unlock()
        guard let name, FunnelPostScriptOwners.shared.owner(of: name) == hash else { return nil }
        return name
    }
}

/// Which uploaded file (by content hash) holds each PostScript name in
/// CoreText's process registry. CoreText registers one font per name, so a
/// re-upload with the same name evicts the previous file
/// (`funnelRegisterUploadedFile`); this is the one record of who won.
final class FunnelPostScriptOwners: @unchecked Sendable {
    static let shared = FunnelPostScriptOwners()

    private let lock = NSLock()
    private var owners: [String: String] = [:]

    func owner(of postScriptName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return owners[postScriptName]
    }

    func set(_ postScriptName: String, owner hash: String) {
        lock.lock()
        defer { lock.unlock() }
        owners[postScriptName] = hash
    }
}

/// An uploaded face as the drawers draw it: the registered file's
/// PostScript name, and what has to be synthesised on top because the
/// funnel uploaded no face for it (review R5, as browsers and Android do).
struct FunnelUploadedDraw: Equatable {
    let postScriptName: String
    /// The CSS weight the funnel uploaded this face as.
    let weight: Int
    /// A heavier weight than any face the family has — CSS's rule: asked
    /// for 600 or more, drawn from a face of 500 or less (Chromium's bold
    /// threshold; Android's minikin also fakes bold from 600 up).
    let synthesizedBold: Bool
    /// An italic run of a family with no italic face: slanted by
    /// `funnelObliqueSkew`.
    let synthesizedItalic: Bool
}

/// The horizontal skew a synthesised oblique is drawn with — 0.25, the
/// slant Skia (Chrome) and Android (`setTextSkewX(-0.25)`) fake italics at.
let funnelObliqueSkew: CGFloat = 0.25

private enum SynthesisFormat {
    /// Asked for this weight or heavier…
    static let boldFrom = 600
    /// …from a face this light or lighter, a bold is synthesised.
    static let regularUpTo = 500
}

/// One funnel's uploaded faces (`CoreFunnel.fonts`): the drawers resolve a
/// family, weight and slant to the file THIS funnel names (its hash), then
/// the hash to the face registered for it (review R10). Handed down the
/// view tree (`EnvironmentValues.funnelFonts`) inside `FunnelTextScale`.
struct FunnelSessionFonts: Equatable {
    private struct Face: Equatable {
        let family: String
        let weight: Int
        let italic: Bool
        let hash: String
    }

    private let faces: [Face]
    private let registry: FunnelUploadedFaces
    private let catalog: FunnelCatalogFaces
    /// The driver's font registrations so far (`FunnelDriver.fontsVersion`):
    /// part of equality, so a face landing changes the environment value and
    /// every drawer that resolves through it draws again in that face.
    private var version = 0

    /// A funnel served no uploaded faces: every family resolves as before.
    static let none = FunnelSessionFonts([])

    init(_ served: [FunnelFontFace], registry: FunnelUploadedFaces = .shared, catalog: FunnelCatalogFaces = .shared) {
        faces = served.map {
            Face(
                family: $0.family.lowercased(), weight: Int($0.weight),
                italic: $0.style == FontStoreFormat.italicStyle, hash: $0.hash.lowercased())
        }
        self.registry = registry
        self.catalog = catalog
    }

    static func == (lhs: FunnelSessionFonts, rhs: FunnelSessionFonts) -> Bool {
        lhs.faces == rhs.faces && lhs.registry === rhs.registry && lhs.catalog === rhs.catalog
            && lhs.version == rhs.version
    }

    /// These faces as of the driver's `version`th font registration.
    func at(version: Int) -> FunnelSessionFonts {
        var copy = self
        copy.version = version
        return copy
    }

    /// The registered face of `stack`'s primary family (any case) nearest
    /// `weight` — the lighter one on a tie, as `funnelCSSWeight` snaps — in
    /// the asked slant; an italic ask with no italic face registered gets
    /// the upright one to slant. Nil: not an uploaded family of this funnel
    /// on this device (yet).
    ///
    /// A family this funnel uploaded no face for falls back to the CATALOG
    /// faces registered for it (`FunnelCatalogFaces`), resolved the same
    /// way: by the PostScript name of the file the manifest lists for that
    /// weight, never by CoreText's family lookup — a catalog file's own
    /// family name need not be the catalog's (every Nunito instance calls
    /// itself "Nunito ExtraLight"), so that lookup missed and its 800 / 900
    /// files never drew.
    func face(_ stack: String?, weight: Int, italic: Bool) -> FunnelUploadedDraw? {
        guard let family = funnelPrimaryFamily(stack)?.lowercased() else { return nil }
        guard faces.contains(where: { $0.family == family }) else {
            return catalog.face(family: family, weight: weight, italic: italic)
        }
        func nearest(italic: Bool) -> (Face, String)? {
            faces
                .filter { $0.family == family && $0.italic == italic }
                .compactMap { face in registry.postScriptName(hash: face.hash).map { (face, $0) } }
                .min { (abs($0.0.weight - weight), $0.0.weight) < (abs($1.0.weight - weight), $1.0.weight) }
        }
        let real = italic ? nearest(italic: true) : nil
        guard let (face, name) = real ?? nearest(italic: false) else { return nil }
        return funnelFaceDraw(name: name, faceWeight: face.weight, weight: weight, italic: italic, realItalic: real != nil)
    }
}

/// A registered face as drawn for `weight` / `italic`: what has to be
/// synthesised on top of the face picked.
private func funnelFaceDraw(name: String, faceWeight: Int, weight: Int, italic: Bool, realItalic: Bool) -> FunnelUploadedDraw {
    FunnelUploadedDraw(
        postScriptName: name, weight: faceWeight,
        synthesizedBold: weight >= SynthesisFormat.boldFrom && faceWeight <= SynthesisFormat.regularUpTo,
        synthesizedItalic: italic && !realItalic)
}

/// The CATALOG faces registered with CoreText: lower-cased family → weight
/// → PostScript name, upright and italic apart — the manifest's family and
/// weight for each file, never the file's own family name. Process-wide, as
/// CoreText's registration is (a catalog family is the same files in every
/// funnel). Written by `FunnelFontStore`, read on the main thread while
/// drawing; lock-guarded.
final class FunnelCatalogFaces: @unchecked Sendable {
    static let shared = FunnelCatalogFaces()

    private struct Key: Hashable {
        let family: String
        let italic: Bool
    }

    private let lock = NSLock()
    private var byFamily: [Key: [Int: String]] = [:]
    private var recorded = 0

    func record(family: String, weight: Int, italic: Bool, postScriptName: String) {
        lock.lock()
        defer { lock.unlock() }
        byFamily[Key(family: family.lowercased(), italic: italic), default: [:]][weight] = postScriptName
        recorded += 1
    }

    /// Grows with every face recorded — whoever registered it (a screen's
    /// own load, or a warm of the pages ahead), so a screen drawn before
    /// it landed knows to redraw.
    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The registered face of `family` (lower-cased) nearest `weight` — the
    /// lighter on a tie — in the asked slant; an italic ask with no italic
    /// face gets the upright one to slant. Nil: no catalog face of the
    /// family is registered (yet).
    func face(family: String, weight: Int, italic: Bool) -> FunnelUploadedDraw? {
        func nearest(italic: Bool) -> (Int, String)? {
            lock.lock()
            let faces = byFamily[Key(family: family, italic: italic)] ?? [:]
            lock.unlock()
            return faces.min { (abs($0.key - weight), $0.key) < (abs($1.key - weight), $1.key) }
                .map { ($0.key, $0.value) }
        }
        let real = italic ? nearest(italic: true) : nil
        guard let (faceWeight, name) = real ?? nearest(italic: false) else { return nil }
        return funnelFaceDraw(name: name, faceWeight: faceWeight, weight: weight, italic: italic, realItalic: real != nil)
    }
}

/// The CoreText font an uploaded face draws at `size`: slanted by a skew
/// matrix when `draw` synthesises the italic. A synthesised BOLD is not
/// the font's to draw — CoreText cannot embolden a one-face family (its
/// trait copy is nil) — but the view's (`FunnelFakeBold`) or the field's
/// (`strokeWidth`).
func funnelUploadedCTFont(_ draw: FunnelUploadedDraw, size: CGFloat) -> CTFont {
    guard draw.synthesizedItalic else { return CTFontCreateWithName(draw.postScriptName as CFString, size, nil) }
    var skew = CGAffineTransform(a: 1, b: 0, c: funnelObliqueSkew, d: 1, tx: 0, ty: 0)
    return CTFontCreateWithName(draw.postScriptName as CFString, size, &skew)
}

/// Downloads, caches and registers funnel faces. One per process.
///
/// Two sources:
///  - the CATALOG (`<api>/funnel-fonts/manifest.json`), by family name;
///  - the faces the project UPLOADED (`CoreFunnel.fonts`, served beside the
///    document), each fetched from its own URL, checked against its SHA-256
///    `hash`, cached under that hash (so it survives relaunches and is never
///    fetched twice) and recorded in `FunnelUploadedFaces`.
/// A family a funnel serves uploaded faces for is never looked up in the
/// catalog (the server already left catalog names out).
///
/// Nothing here throws or blocks a draw: a failure registers nothing and
/// the drawers keep the system face. A TRANSIENT one (offline, a 404, a
/// cache write) is tried again by the next `ensure`; a file that arrived
/// but fails its hash or that CoreText refuses is not fetched again for the
/// life of the process (review R7).
///
/// One download per hash at a time (review R9): the actor gives up its
/// turn at every `await fetch`, so a second `ensure` of the same face would
/// otherwise start a second download; it waits on the first one instead.
actor FunnelFontStore {
    static let shared = FunnelFontStore()

    typealias Fetch = @Sendable (URL) async -> Data?

    private let fetch: Fetch
    private let cacheRoot: URL?
    private let uploaded: FunnelUploadedFaces
    private let catalog: FunnelCatalogFaces
    private var manifest: Manifest?
    private var registered = Set<String>()
    /// Uploaded hashes being downloaded / registered, each one task every
    /// concurrent `ensure` of that face awaits.
    private var inFlight: [String: Task<Bool, Never>] = [:]
    /// Uploaded hashes whose file failed its hash or CoreText's check: not
    /// fetched again by this store (`shared`: for the process).
    private var refused = Set<String>()

    private struct Manifest: Decodable {
        let families: [String: [String: String]]
        /// Family → weight → italic face, for the families that have one.
        let italics: [String: [String: String]]?
    }

    init(
        fetch: @escaping Fetch = FunnelFontStore.httpGet,
        cacheRoot: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(FontStoreFormat.cacheFolder),
        uploaded: FunnelUploadedFaces = .shared,
        catalog: FunnelCatalogFaces = .shared
    ) {
        self.fetch = fetch
        self.cacheRoot = cacheRoot
        self.uploaded = uploaded
        self.catalog = catalog
    }

    /// The body of a 200 answer to a plain GET, else nil.
    static let httpGet: Fetch = { url in
        guard let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == HTTPStatus.ok
        else { return nil }
        return data
    }

    /// Makes the faces of `families` (upright) and `italics` (their italic
    /// faces) available to CoreText: from `uploaded` for a family the funnel
    /// was served uploaded faces for, else from the catalog at `base` (none
    /// without one). True when at least one face was newly registered —
    /// the caller redraws.
    func ensure(
        _ families: Set<String>, italics: Set<String> = [], base: URL?, uploaded faces: [FunnelFontFace] = []
    ) async -> Bool {
        guard !families.isEmpty || !italics.isEmpty else { return false }
        let uploadedFamilies = Set(faces.map { $0.family.lowercased() })
        var added = false
        for face in faces {
            let family = face.family.lowercased()
            let italic = face.style == FontStoreFormat.italicStyle
            let wanted = italic
                ? italics.contains { $0.lowercased() == family }
                : families.contains { $0.lowercased() == family }
            if wanted, await registerUploaded(face, italic: italic) { added = true }
        }
        guard let base else { return added }
        let catalogFamilies = families.filter { !uploadedFamilies.contains($0.lowercased()) }
        let catalogItalics = italics.filter { !uploadedFamilies.contains($0.lowercased()) }
        guard !catalogFamilies.isEmpty || !catalogItalics.isEmpty,
            let manifest = await loadManifest(base: base)
        else { return added }
        let wanted =
            catalogFamilies.compactMap { family in manifest.families[family].map { (family, false, $0) } }
            + catalogItalics.compactMap { family in manifest.italics?[family].map { (family, true, $0) } }
        for (family, italic, faces) in wanted {
            for (weightKey, path) in faces where !registered.contains(path) {
                guard let weight = Int(weightKey), let file = await cachedFace(path, base: base) else { continue }
                var error: Unmanaged<CFError>?
                // Already registered by an earlier run in this process is fine.
                _ = CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
                registered.insert(path)
                // Drawn by the file's PostScript name under the MANIFEST's
                // family and weight (`FunnelCatalogFaces`).
                if let name = funnelRegisteredPostScriptName(file) {
                    catalog.record(family: family, weight: weight, italic: italic, postScriptName: name)
                }
                added = true
            }
        }
        return added
    }

    /// Downloads (or reads from the cache), checks, registers and records
    /// one uploaded face. False when it could not be made drawable.
    private func registerUploaded(_ face: FunnelFontFace, italic: Bool) async -> Bool {
        let hash = face.hash.lowercased()
        guard uploaded.postScriptName(hash: hash) == nil, !refused.contains(hash) else { return false }
        if let running = inFlight[hash] { return await running.value }
        let task = Task { await self.loadUploaded(face, hash: hash) }
        inFlight[hash] = task
        let added = await task.value
        inFlight[hash] = nil
        return added
    }

    /// The download / cache / register of one uploaded file, run once per
    /// hash at a time by `registerUploaded`.
    private func loadUploaded(_ face: FunnelFontFace, hash: String) async -> Bool {
        // The hash names a file on disk: anything but 64 hex digits never
        // reaches a path. The format picks only the extension.
        guard hash.count == FontStoreFormat.sha256HexLength, hash.allSatisfy(\.isHexDigit),
            FontStoreFormat.uploadFormats.contains(face.format), let cacheRoot,
            let url = URL(string: face.url)
        else { return false }
        let file = cacheRoot.appendingPathComponent(FontStoreFormat.uploadedFolder)
            .appendingPathComponent("\(hash).\(face.format)")
        if !FileManager.default.fileExists(atPath: file.path) {
            // Offline or a non-200 is transient: the next open tries again.
            guard let data = await fetch(url) else { return false }
            guard funnelSHA256Hex(data) == hash else {
                refused.insert(hash)
                return false
            }
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                return false
            }
        }
        guard let postScriptName = funnelRegisterUploadedFile(file, hash: hash) else {
            // A file CoreText refuses is neither kept nor fetched again.
            try? FileManager.default.removeItem(at: file)
            refused.insert(hash)
            return false
        }
        uploaded.record(hash: hash, postScriptName: postScriptName)
        return true
    }

    private func loadManifest(base: URL) async -> Manifest? {
        if let manifest { return manifest }
        let url = base.appendingPathComponent(FontStoreFormat.manifestPath)
        guard let data = await fetch(url), let decoded = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        manifest = decoded
        return decoded
    }

    private func cachedFace(_ path: String, base: URL) async -> URL? {
        guard let cacheRoot else { return nil }
        let file = cacheRoot.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let url = base.appendingPathComponent(FontStoreFormat.facesPath).appendingPathComponent(path)
        guard let data = await fetch(url) else { return nil }
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

/// Registers an uploaded file (`<…>/uploaded/<hash>.<format>`) for the
/// process and returns its PostScript name, or nil when CoreText cannot
/// draw it (review R10).
///
/// CoreText holds ONE font per PostScript name. When another UPLOADED file
/// already holds this one (a re-upload, or another funnel's file under the
/// same name), that file is unregistered first, so the name draws the file
/// just checked rather than passing the probe with the old one's glyphs;
/// `FunnelPostScriptOwners` then says this hash owns the name, and the
/// evicted hash resolves nothing until an `ensure` registers it again.
///
/// Left as is (documented limits):
///  - two funnels visible AT ONCE whose different files share a PostScript
///    name: the last registered draws in both until the other's next
///    `ensure` takes the name back;
///  - a name held by a font that is not an uploaded file (the app's own,
///    a catalog face): never unregistered — the uploaded face is accepted
///    when CoreText resolves the name, and draws the other file's glyphs;
///  - SwiftUI and UIKit may keep a font already built under the name until
///    the view redraws.
func funnelRegisterUploadedFile(_ file: URL, hash: String) -> String? {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
        let descriptor = descriptors.first,
        let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
    else { return nil }
    let owners = FunnelPostScriptOwners.shared
    // The file CoreText draws the name from now, if any.
    let holder = funnelRegisteredFile(of: name)
    if let holder, holder.standardizedFileURL != file.standardizedFileURL,
        owners.owner(of: name) != hash, funnelUploadedHash(of: holder) != nil
    {
        CTFontManagerUnregisterFontsForURL(holder as CFURL, .process, nil)
    }
    var error: Unmanaged<CFError>?
    // Already registered (the same bytes under another cache path, a
    // relaunch within one test process) is fine: the probe decides.
    _ = CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
    let drawn = CTFontCreateWithName(name as CFString, FontStoreFormat.probeSize, nil)
    guard (CTFontCopyPostScriptName(drawn) as String) == name else { return nil }
    owners.set(name, owner: hash)
    return name
}

/// The PostScript name a registered catalog file draws by, or nil when
/// CoreText does not resolve that name (the file did not register).
private func funnelRegisteredPostScriptName(_ file: URL) -> String? {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
        let name = descriptors.first.flatMap({ CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String })
    else { return nil }
    return funnelRegisteredFile(of: name) == nil ? nil : name
}

/// The file CoreText draws `postScriptName` from, or nil when no font of
/// that name is registered (CoreText then falls back to another name).
private func funnelRegisteredFile(of postScriptName: String) -> URL? {
    let font = CTFontCreateWithName(postScriptName as CFString, FontStoreFormat.probeSize, nil)
    guard (CTFontCopyPostScriptName(font) as String) == postScriptName else { return nil }
    return CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
}

/// The content hash an uploaded face file is named by, or nil for any
/// other file — only these are ever unregistered.
private func funnelUploadedHash(of file: URL) -> String? {
    let hash = file.deletingPathExtension().lastPathComponent
    guard file.deletingLastPathComponent().lastPathComponent == FontStoreFormat.uploadedFolder,
        hash.count == FontStoreFormat.sha256HexLength, hash.allSatisfy(\.isHexDigit)
    else { return nil }
    return hash
}

/// Lower-case hex SHA-256 of `data` — the API's `contentHash`.
func funnelSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private enum HTTPStatus {
    static let ok = 200
}
