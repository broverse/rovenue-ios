//  CarouselFade.swift — `fade` (spec CL §4.1, §8.2): a crossfade inside
//  one box sized to the tallest slide (F2), on `fadeMs` and the look's fade
//  curve. A swipe past the threshold changes the slide; the content does
//  not follow the finger. Every slide but the current one is invisible,
//  takes no touch and is hidden from assistive tech (F9, A1) — the one
//  fading out included, so a tap mid-fade reaches the slide arriving; once
//  its fade ends it is `.hidden()`, kept only for the box's height.

import SwiftUI

struct CarouselFade: View {
    let block: CarouselBlock
    let children: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction
    let width: CGFloat
    let index: Int
    let motion: CarouselMotion

    /// The slide fading out, drawn until its fade ends.
    @State private var departing: Int?
    @State private var shown: Int?

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(children.enumerated()), id: \.offset) { i, child in
                let current = i == index
                let drawn = current || i == departing
                FunnelNodeView(node: child, look: look, interaction: interaction)
                    .modifier(CarouselCardFrame(card: block.card, tokens: look.carousel))
                    .frame(width: width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(current ? 1 : 0)
                    // Once its fade has ended a slide is out of the drawing,
                    // the touch and the accessibility tree alike — still in
                    // the layout, so the box keeps the tallest slide (F2, F9).
                    .modifier(CarouselFadeHidden(hidden: !drawn))
                    .zIndex(current ? 1 : 0)
                    .environment(\.funnelPlaybackHeld, !current)
                    .allowsHitTesting(current)
                    .carouselHidden(!current)
            }
        }
        // One box for every slide: the tallest one's.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width)
        .animation(motion.fade, value: index)
        .onAppear { shown = index }
        .onChange(of: index) { next in
            departing = shown
            shown = next
        }
        .task(id: departing) {
            guard departing != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(Double(block.fadeMs) * CarouselFormat.nanosecondsPerMillisecond))
            guard !Task.isCancelled else { return }
            departing = nil
        }
    }
}

/// `.hidden()` when the slide is not drawn at all.
private struct CarouselFadeHidden: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden { content.hidden() } else { content }
    }
}
