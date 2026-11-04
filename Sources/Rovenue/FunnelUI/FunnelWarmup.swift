//  FunnelWarmup.swift — what `preloadPlacement` warms besides the placement
//  itself (spec 2026-11-03-placement-open-from-cache §5): the first screen's
//  images (and video posters, never the video), the funnel's store prices
//  and its catalog fonts, so even the first open draws complete.
//
//  The screens are read from a NON-emitting preview session over the
//  preloaded funnel (the resolver that ships, never a re-parse here): the
//  first screen, plus the screens it can lead to (spec 2026-11-03-funnel-
//  next-page-warm §3) — the session's `upcomingScreensJson`, resolved by the
//  core on a copy of the session, so no input is driven. On every new page
//  the drawer warms that page's upcoming screens the same way
//  (`funnelWarmUpcoming`, called from `FunnelDriver`).

import Foundation

/// The parts of a resolved first screen the warm-up fetches.
struct FunnelWarmSet: Equatable {
    var imageURLs: [URL] = []
    var families: Set<String> = []
    var italicFamilies: Set<String> = []
}

extension FunnelWarmSet {
    /// What `self` and `other` warm together.
    func union(_ other: FunnelWarmSet) -> FunnelWarmSet {
        FunnelWarmSet(
            imageURLs: imageURLs + other.imageURLs.filter { !imageURLs.contains($0) },
            families: families.union(other.families),
            italicFamilies: italicFamilies.union(other.italicFamilies))
    }
}

/// The warm set of several screens, as `screen_json` strings; one that will
/// not decode adds nothing.
func funnelWarmSet(screensJson: [String]) -> FunnelWarmSet {
    screensJson.compactMap(decodeRenderScreen).map(funnelWarmSet).reduce(FunnelWarmSet()) { $0.union($1) }
}

/// Every image URL, video poster and font family `screen` draws.
func funnelWarmSet(_ screen: RenderScreen) -> FunnelWarmSet {
    var urls: [String] = []
    func walk(_ blocks: [RenderBlock]) {
        for block in blocks {
            switch block {
            case .image(let b): urls.append(b.url)
            case .gallery(let b): urls.append(contentsOf: b.urls)
            case .video(let b): if let poster = b.poster { urls.append(poster) }
            case .question(let b): urls.append(contentsOf: b.options.compactMap(\.imageUrl))
            case .featureList(let b):
                urls.append(contentsOf: b.items.filter { $0.iconKind == FunnelWarmFormat.imageIcon }.map(\.icon))
            case .stack(let b): walk(b.children)
            case .stickyFooter(let b): walk(b.children)
            case .expressCheckout(let b): walk(b.children)
            default: break
            }
        }
    }
    walk(screen.blocks)
    if let background = screen.background {
        switch background.kind {
        case RenderBackground.kindImage: urls.append(background.value)
        case RenderBackground.kindVideo: if let poster = background.poster { urls.append(poster) }
        default: break
        }
    }
    return FunnelWarmSet(
        imageURLs: urls.compactMap(URL.init(string:)),
        families: funnelFamilies(in: screen),
        italicFamilies: funnelItalicFamilies(in: screen))
}

private enum FunnelWarmFormat {
    /// `RenderFeature.iconKind` of an uploaded image icon.
    static let imageIcon = "image"
}

/// The object `/v1/placements` serves under `funnel`, rebuilt from a
/// `CoreFunnel` — what `previewFunnel(payload:)` opens. `configJson` is
/// already JSON and goes in verbatim. The offering is left out: a warm-up
/// reads screens, never prices, from it.
func funnelWarmPayload(_ funnel: CoreFunnel) -> String? {
    func quoted(_ value: String) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
    guard let identifier = quoted(funnel.funnelIdentifier), let id = quoted(funnel.funnelId) else { return nil }
    return "{\"identifier\":\(identifier),\"id\":\(id),\"revision\":\(funnel.revision),"
        + "\"configFormatVersion\":\(funnel.configFormatVersion),\"config\":\(funnel.configJson)}"
}

/// The first screen `funnel` draws at `locale` and the screens it can lead
/// to, as `screen_json`, from one non-emitting preview session. Empty when
/// it cannot be opened.
func funnelWarmScreensJson(_ funnel: CoreFunnel, locale: String) -> [String] {
    guard let payload = funnelWarmPayload(funnel),
        let session = try? Rovenue.previewFunnel(payload: payload, locale: locale),
        let first = session.current().screenJson
    else { return [] }
    return [first] + session.upcomingScreensJson()
}

/// Fetch `warm`'s images (decoded at the drawers' full-width size, so a
/// prefetched image is a memory hit when drawn) and its catalog fonts.
/// Best-effort: a failure leaves that part to load when drawn.
func funnelWarm(_ warm: FunnelWarmSet, fontBase: URL?) async {
    let width = await MainActor.run { funnelFullWidthPixels() }
    async let images: Void = FunnelImageLoader.shared.prefetch(urls: warm.imageURLs, targetPixelWidth: width)
    async let fonts: Bool = {
        guard let fontBase else { return false }
        return await FunnelFontStore.shared.ensure(warm.families, italics: warm.italicFamilies, base: fontBase)
    }()
    _ = await (images, fonts)
}

/// The drawer's runtime warm (spec 2026-11-03-funnel-next-page-warm §4):
/// the screens `session`'s current page can lead to, read and fetched off
/// the main thread at low priority, so it never delays drawing a step.
/// Covers opens without a preload and funnels longer than two pages.
func funnelWarmUpcoming(_ session: FunnelUpcomingScreens, fontBase: URL?) {
    let source = FunnelWarmSource(session: session)
    Task.detached(priority: .background) {
        await funnelWarm(funnelWarmSet(screensJson: source.session.upcomingScreensJson()), fontBase: fontBase)
    }
}

/// Carries the session into the detached warm task. The uniffi session is
/// internally locked; the warm only reads through it.
private struct FunnelWarmSource: @unchecked Sendable {
    let session: FunnelUpcomingScreens
}

/// Warm images, fonts and prices for `funnel` (spec §5): the first screen
/// and the screens it can lead to. Each part is best-effort: a failure
/// leaves that part to load on open, as before.
@available(iOS 15.0, macOS 12.0, *)
func warmFunnel(_ funnel: CoreFunnel, locale: String, fontBase: URL?) async {
    let warm = funnelWarmSet(screensJson: funnelWarmScreensJson(funnel, locale: locale))
    async let screens: Void = funnelWarm(warm, fontBase: fontBase)
    async let prices: [FunnelPackagePrice]? = {
        guard let offering = funnel.offering else { return nil }
        return await lookUpAndCachePrices(offering)
    }()
    _ = await (screens, prices)
}
