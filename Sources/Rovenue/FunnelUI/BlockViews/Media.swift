//  Media.swift — image, video and gallery.
//
//  A URL that does not parse renders a placeholder rather than crashing: a
//  draft saves mid-edit, so a half-typed URL can reach a device.

import AVKit
import Combine
import SwiftUI

private enum MediaFormat {
    static let videoAspectRatio: CGFloat = 16.0 / 9.0
    static let noBleed: CGFloat = 0
    /// What an aspect-hugging picture shows before it loads: no size at
    /// all, so the box is zero wide until the art says how wide it is.
    static var unloaded: some View { Color.clear.frame(width: 0, height: 0) }
}

/// Sizes its one child — a resizable picture — at the child's natural
/// aspect for the proposed height (`width: fit` + a height). The width is
/// capped by a finite proposed width, where the aspect fill then crops
/// (the caller clips), as a web `max-width: 100%` image would.
@available(iOS 16.0, macOS 13.0, *)
struct FunnelIntrinsicAspect: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(.unspecified)
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? natural.height
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: 0, height: height) }
        var width = height * natural.width / natural.height
        if let cap = proposal.width, cap.isFinite { width = min(width, cap) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size))
    }
}

/// The screen's resolved padding (`RenderScreen.padding`), installed by
/// `RovenueFunnelView` for the screen it draws — the sides a bleeding image
/// cancels. nil outside a funnel screen, where the look's page padding (the
/// resolver's own default for a page with none) stands in.
private struct FunnelPagePaddingKey: EnvironmentKey {
    static let defaultValue: RenderPadding? = nil
}

extension EnvironmentValues {
    var funnelPagePadding: RenderPadding? {
        get { self[FunnelPagePaddingKey.self] }
        set { self[FunnelPagePaddingKey.self] = newValue }
    }
}

struct FunnelImageView: View {
    let block: ImageBlock
    let look: RenderLook
    @Environment(\.funnelPagePadding) private var pagePadding
    @Environment(\.layoutDirection) private var layoutDirection

    init(block: ImageBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    var body: some View {
        // A bleeding image cancels the screen's resolved side padding, its
        // physical `left` / `right` mapped to leading / trailing exactly as
        // the body pads them (a right-to-left screen swaps them).
        let padding = pagePadding ?? RenderPadding(look: look)
        let rtl = layoutDirection == .rightToLeft
        let leading = CGFloat(rtl ? padding.right : padding.left)
        let trailing = CGFloat(rtl ? padding.left : padding.right)
        picture
        // The overlay pill (spec F §6 F3) sits in the picture's own box —
        // a fit-width picture's too — and is clipped with it.
        .overlay(alignment: FunnelImageOverlay.alignment(block.overlay?.position)) {
            if let overlay = block.overlay { FunnelImageOverlay(overlay: overlay, look: look) }
        }
        // Full width; a radius in the style clips the corners.
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityLabel(block.alt ?? "")
        .funnelStyle(block.style, look.bodyType)
        .padding(.leading, block.bleed ? -leading : MediaFormat.noBleed)
        .padding(.trailing, block.bleed ? -trailing : MediaFormat.noBleed)
        // An image has no action, so it never takes a touch (P86): a
        // decorative picture overlapping a control in a layered stack — the
        // WG04 fan over the pick area — must not swallow its tap. (This also
        // retires the overflowing aspect-fill photo's stolen taps, which the
        // `contentShape` box used to bound.)
        .allowsHitTesting(false)
    }

    /// With a fixed height the picture FILLS that box, cropping (aspect
    /// fill); without one it is aspect fit at full width — the rule the
    /// web and Android draw.
    ///
    /// The fill is an overlay on `Color.clear`, never the image itself in
    /// the layout: an aspect-filled image REPORTS the size that fills its
    /// proposal, which is wider than the proposal whenever the box is
    /// narrower than the art (Fern's 4:3 hero at 330 pt high reports 440 pt
    /// against a 402 pt screen), and `.frame(maxWidth: .infinity)` never
    /// shrinks below its child — so the whole column grew and the heading
    /// and CTA ran off the right edge (spec 2026-10-12-open-followups §3).
    /// `Color.clear` takes exactly the proposal; the overlay fills and is
    /// clipped to it. The page background and the question tiles already
    /// draw their fills this way.
    @ViewBuilder
    private var picture: some View {
        if hugsAspect {
            aspectHugging
        } else {
            boxed
        }
    }

    /// `width: fit` with a height: the picture at its intrinsic aspect for
    /// that height, as the web (`height` + `width: auto`) and the render
    /// tree draw it. The fill-overlay below takes the proposal, and a fit
    /// box proposes no width (`fixedSize`), so it collapsed to a sliver.
    private var hugsAspect: Bool {
        block.style.width == RenderStyle.widthFit && block.style.height != nil
    }

    @ViewBuilder
    private var aspectHugging: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            FunnelIntrinsicAspect {
                if let ref = block.photoRef {
                    FunnelLocalPhoto(ref: ref) { $0.resizable().scaledToFill() } placeholder: { MediaFormat.unloaded }
                } else {
                    FunnelAsyncImage(url: URL(string: block.url)) { $0.resizable().scaledToFill() } placeholder: {
                        MediaFormat.unloaded
                    }
                }
            }
        } else {
            // macOS 12 has no `Layout`; no funnel is drawn there outside the tests.
            boxed
        }
    }

    @ViewBuilder
    private var boxed: some View {
        // The visitor's photo (Spec B §6): from the SDK's photo store, never
        // a URL; a gone file draws nothing.
        if let ref = block.photoRef {
            if block.style.height != nil {
                Color.clear.overlay(
                    FunnelLocalPhoto(ref: ref) { $0.resizable().scaledToFill() } placeholder: { Color.clear })
            } else {
                FunnelLocalPhoto(ref: ref) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
            }
        } else if block.style.height != nil {
            Color.clear.overlay(
                FunnelAsyncImage(url: URL(string: block.url)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            )
        } else {
            FunnelAsyncImage(url: URL(string: block.url)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
        }
    }
}

/// An image's overlay pill (spec F §6 F3/F3b, `overlay.tsx` on the web):
/// the tree's position, width, inset, colours, glass plate (the stack
/// glass, `FunnelGlassSurface`, fallbacks included) and icon. Only WHEN is
/// the host's: while the check its text binds runs, it reads the tree's
/// `checkingText` and — `activityCheck` naming that check — wears a
/// spinner in the overlay colour. It hides whenever its text is empty.
/// Metrics (P82): chip padding and gap, `badgeRadius`, muted text size at
/// the emphasis weight.
struct FunnelImageOverlay: View {
    let overlay: RenderOverlay
    let look: RenderLook

    @Environment(\.funnelRunningChecks) private var running
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let center = "center"
    private static let fill = "fill"
    private static let start = "start"
    private static let end = "end"

    /// The pill's corner of the picture; the corners are logical, so an
    /// RTL screen mirrors them.
    static func alignment(_ position: String?) -> Alignment {
        switch position {
        case "topStart": return .topLeading
        case "topEnd": return .topTrailing
        case "bottomEnd": return .bottomTrailing
        case center: return .center
        default: return .bottomLeading
        }
    }

    /// Spec F §7 G5 `start|center|end`, logical (mirrors in RTL).
    private var contentAlignment: Alignment {
        switch overlay.align {
        case Self.start: return .leading
        case Self.end: return .trailing
        default: return .center
        }
    }

    private var checking: Bool { overlay.check.map(running.contains) ?? false }
    private var spinning: Bool { overlay.activityCheck.map(running.contains) ?? false }
    private var text: String {
        if checking, let busy = overlay.checkingText { return busy }
        return overlay.text
    }

    var body: some View {
        if !text.isEmpty {
            let scale = FunnelTextScale(dynamicType: dynamicTypeSize)
            let size = scale(CGFloat(look.mutedTextSize))
            let color = funnelColor(overlay.color) ?? .white
            let shape = RoundedRectangle(cornerRadius: CGFloat(look.badgeRadius))
            HStack(spacing: CGFloat(look.chipGap)) {
                if spinning {
                    FunnelInlineSpinner(size: size, color: color)
                } else if let icon = overlay.icon {
                    FunnelIconGlyph(icon: icon)
                }
                Text(text)
                    .font(funnelFont(size: CGFloat(look.mutedTextSize), weight: look.emphasisWeight, family: nil, scale: scale))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(color)
            // Spec F §7 G5: the authored padding, else the chip's.
            .padding(.horizontal, CGFloat(overlay.paddingX ?? look.chipPaddingX))
            .padding(.vertical, CGFloat(overlay.paddingY ?? look.chipPaddingY))
            // `align` places the content inside a `fill` pill (absent: centred);
            // a hugging pill has no room to place it in.
            .frame(maxWidth: overlay.width == Self.fill ? .infinity : nil, alignment: contentAlignment)
            .background {
                if overlay.surface == nil, let plate = funnelColor(overlay.background) { shape.fill(plate) }
            }
            .modifier(FunnelGlassSurface(surface: overlay.surface, radius: look.badgeRadius))
            .clipShape(shape)
            .padding(CGFloat(overlay.inset))
            .accessibilityElement(children: .combine)
        }
    }
}

/// A small ring spinner sized to the copy beside it, in that copy's colour
/// — `InlineSpinner` on the web: a ¾ ring, stroke 14 % of its size, one
/// turn per 900 ms.
struct FunnelInlineSpinner: View {
    let size: CGFloat
    let color: Color
    @State private var turning = false

    private static let strokeRatio: CGFloat = 0.14
    private static let arc: CGFloat = 0.75
    private static let turnSeconds = 0.9
    private static let fullTurn = 360.0

    var body: some View {
        Circle()
            .trim(from: 0, to: Self.arc)
            .stroke(color, lineWidth: max(1, (size * Self.strokeRatio).rounded()))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? Self.fullTurn : 0))
            .onAppear {
                withAnimation(.linear(duration: Self.turnSeconds).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityHidden(true)
    }
}

/// Muted and looping. A funnel screen's video
/// is decoration, not something someone came to watch.
struct FunnelVideoView: View {
    let block: VideoBlock
    let look: RenderLook

    @State private var player: AVPlayer?
    /// The player's own state (`timeControlStatus`): what the playback word
    /// says — a 404, a video still buffering or one paused reads "paused".
    @State private var playing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Still entering: the first frame moves, playback waits (spec
    /// 2026-10-19-funnel-motion "Element animations").
    @Environment(\.funnelPlaybackHeld) private var playbackHeld

    init(block: VideoBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    /// Reduce Motion or Low Power Mode: the poster stands in for the loop.
    private var stillOnly: Bool {
        reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        Group {
            if stillOnly, let poster = block.poster.flatMap(URL.init(string:)) {
                FunnelAsyncImage(url: poster) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
            } else if let player {
                VideoPlayer(player: player)
                    .aspectRatio(MediaFormat.videoAspectRatio, contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !stillOnly, let url = URL(string: block.url) else { return }
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
            if !playbackHeld { player.play() }
            self.player = player
        }
        .onChange(of: playbackHeld) { held in held ? player?.pause() : player?.play() }
        .onReceive(playingStatus) { playing = $0 }
        .onDisappear {
            player?.pause()
            player = nil
        }
        // Its true playback state, read from the player itself (spec
        // 2026-11-11-funnel-followups §2.2). It is the LABEL, not the value:
        // inside a carousel the pager's position value ("2 of 5") reaches
        // every exposed element and wins over one set here. A media element
        // (`.isImage`): the pager's adjustable action reaches it too, and with
        // no role of its own it would read as a slider. One element, so the
        // player's own controls are out of VoiceOver's reach: its default
        // action pauses and resumes the loop instead (WCAG 2.2.2).
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(FunnelPlaybackA11y.value(playing: playing))
        .accessibilityIdentifier(FunnelPlaybackA11y.identifier)
        .accessibilityAction { togglePlayback() }
        .funnelStyle(block.style, look.bodyType)
    }

    /// `playing` as the player reports it (its initial value included), on
    /// the main queue; `false` with no player.
    private var playingStatus: AnyPublisher<Bool, Never> {
        guard let player else { return Just(false).eraseToAnyPublisher() }
        return player.publisher(for: \.timeControlStatus)
            .map { $0 == .playing }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// VoiceOver's activate: pause a playing loop, resume a paused one.
    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }
}

struct FunnelGalleryView: View {
    let block: GalleryBlock
    let look: RenderLook

    init(block: GalleryBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    /// `columns` is always filled by the resolver, so no default is
    /// invented here; the tiles sit `look.galleryGap` apart.
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: CGFloat(look.galleryGap)),
            count: max(1, block.columns))
    }

    /// A tile's drawn width, at most: the screen split into the columns.
    @MainActor
    private var galleryTileWidth: CGFloat {
        funnelScreenMetrics().width / CGFloat(max(1, block.columns))
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: CGFloat(look.galleryGap)) {
            ForEach(block.urls, id: \.self) { url in
                FunnelAsyncImage(url: URL(string: url), targetWidth: galleryTileWidth) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipped()
                // As an image's: the hit area is the tile, not the overflow.
                .contentShape(Rectangle())
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }
}
