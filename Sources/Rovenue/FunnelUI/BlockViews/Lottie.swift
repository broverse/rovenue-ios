//  Lottie.swift — the Lottie block on iOS (spec 2026-11-10 NE §4.4; native
//  playback by spec 2026-11-27 §J, lifting ledger P186's poster-only v1).
//
//  The box is `width` (or the content width) by width × 1000 /
//  `aspectPermille`, laid out from the first frame so nothing jumps. The
//  POSTER fills it until the animation's JSON is fetched (through the
//  funnel media cache) and decoded, and stays when the file cannot be
//  loaded, or when the resolver says this target does not play it
//  (`playback` false — a core under the poster-only ruling). Then
//  lottie-ios plays it: `looping`, at `speedPercent` / 100. With Reduce
//  Motion on nothing moves: the `still` frame (first or last) is drawn.

import Lottie
import SwiftUI

private enum LottieFormat {
    static let perMille: CGFloat = 1000
    static let percent: Double = 100
    static let stillFirst = "first"
    static let firstProgress: AnimationProgressTime = 0
    static let lastProgress: AnimationProgressTime = 1
    /// lottie-ios's own default decoding strategy.
    static let decoding: DecodingStrategy = .dictionaryBased
}

struct FunnelLottieView: View {
    let block: LottieBlock
    let look: RenderLook

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The decoded animation, keyed by the url it came from.
    @State private var loaded: (url: String, animation: LottieAnimation)?

    init(block: LottieBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    /// width ÷ height.
    private var aspect: CGFloat { CGFloat(block.aspectPermille) / LottieFormat.perMille }

    var body: some View {
        sized
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .funnelStyle(block.style, look.bodyType)
            // With a label it is an image VoiceOver names; without one it is
            // decoration (spec NE §7).
            .accessibilityElement(children: .ignore)
            .ifLet(block.label) { $0.accessibilityLabel(Text($1)).accessibilityAddTraits(.isImage) }
            .accessibilityHidden(block.label == nil)
            .task(id: block.url) { await load() }
    }

    /// The box: a fixed width, or the content width; its height from the
    /// aspect ratio either way.
    @ViewBuilder
    private var sized: some View {
        // The box is laid out first and the drawing filled INTO it, clipped
        // to it: a poster or an animation of any shape never changes the box.
        if let width = block.width {
            Color.clear
                .frame(width: CGFloat(width), height: CGFloat(width) / aspect)
                .overlay { drawing }
                .clipped()
        } else {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { drawing }
                .clipped()
        }
    }

    @ViewBuilder
    private var drawing: some View {
        if let animation = current {
            if reduceMotion {
                LottieView(animation: animation)
                    .resizable()
                    .currentProgress(stillProgress)
            } else {
                LottieView(animation: animation)
                    .resizable()
                    .playing(loopMode: block.looping ? .loop : .playOnce)
                    .animationSpeed(Double(block.speedPercent) / LottieFormat.percent)
            }
        } else {
            poster
        }
    }

    private var current: LottieAnimation? {
        guard block.playback, let loaded, loaded.url == block.url else { return nil }
        return loaded.animation
    }

    private var stillProgress: AnimationProgressTime {
        block.still == LottieFormat.stillFirst ? LottieFormat.firstProgress : LottieFormat.lastProgress
    }

    private var poster: some View {
        FunnelAsyncImage(
            url: block.poster.flatMap(URL.init(string:)),
            targetWidth: block.width.map(CGFloat.init),
            content: { image in image.resizable().scaledToFill() },
            placeholder: { Color.clear }
        )
    }

    /// Fetch (media cache) and decode off the main thread; a file that
    /// cannot be fetched or decoded leaves the poster.
    private func load() async {
        guard block.playback, loaded?.url != block.url, let url = funnelMediaURL(block.url) else { return }
        guard let data = await FunnelImageLoader.shared.data(url: url) else { return }
        // `strategy` explicitly: its default argument reads
        // `LottieConfiguration.shared` through an accessor the prebuilt
        // lottie-spm binary does not export (macOS link: undefined
        // `LottieConfiguration.shared.unsafeMutableAddressor`).
        let decoded = await Task.detached(priority: .userInitiated) {
            try? LottieAnimation.from(data: data, strategy: LottieFormat.decoding)
        }.value
        guard let decoded, !Task.isCancelled else { return }
        loaded = (block.url, decoded)
    }

    /// A fixed-width box sits where the block's `align` puts it (centred by
    /// default); leading and trailing mirror right to left.
    private var alignment: HorizontalAlignment {
        block.style.align.map(funnelAlignment) ?? .center
    }
}
