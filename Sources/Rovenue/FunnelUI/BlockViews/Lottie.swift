//  Lottie.swift — the Lottie block on iOS: its POSTER (spec 2026-11-10 NE
//  §4.4, ledger P186).
//
//  Native Lottie ships poster-only in v1: the SDK carries no Lottie player
//  (the React Native iOS host could not launch with lottie-ios linked), the
//  resolver says so (`playback` false) and the judge requires a poster on a
//  native funnel (`LOTTIE_POSTER_REQUIRED`). So this view draws the
//  poster in the animation's own box — `width` (or the content width) by
//  width × 1000 / `aspectPermille` — from its first frame, so nothing jumps
//  when the poster lands; a poster that fails leaves the same empty box.
//  Nothing plays, so Reduce Motion has nothing to stop.

import SwiftUI

private enum LottieFormat {
    static let perMille: CGFloat = 1000
}

struct FunnelLottieView: View {
    let block: LottieBlock
    let look: RenderLook

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
    }

    /// The box: a fixed width, or the content width; its height from the
    /// aspect ratio either way.
    @ViewBuilder
    private var sized: some View {
        // The box is laid out first and the poster filled INTO it, clipped
        // to it: a poster of any shape never changes the box.
        if let width = block.width {
            Color.clear
                .frame(width: CGFloat(width), height: CGFloat(width) / aspect)
                .overlay { poster }
                .clipped()
        } else {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { poster }
                .clipped()
        }
    }

    private var poster: some View {
        FunnelAsyncImage(
            url: block.poster.flatMap(URL.init(string:)),
            targetWidth: block.width.map(CGFloat.init),
            content: { image in image.resizable().scaledToFill() },
            placeholder: { Color.clear }
        )
        // With a label it is an image VoiceOver names; without one it is
        // decoration (spec NE §7).
        .accessibilityElement(children: .ignore)
        .ifLet(block.label) { $0.accessibilityLabel(Text($1)).accessibilityAddTraits(.isImage) }
        .accessibilityHidden(block.label == nil)
    }

    /// A fixed-width box sits where the block's `align` puts it (centred by
    /// default); leading and trailing mirror right to left.
    private var alignment: HorizontalAlignment {
        block.style.align.map(funnelAlignment) ?? .center
    }
}
