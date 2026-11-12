//  CarouselArrows.swift — previous/next (spec CL §4.4): a chevron in an
//  `arrowSize` circle of the look's surface at `arrowFillOpacity`, the
//  glyph in the text colour, the touch target the look's minimum hit
//  target. Labelled with the resolver's `previousLabel` / `nextLabel`. At
//  either end an arrow fades out (the fade speed) unless the carousel
//  loops. The `backward`/`forward` chevrons mirror under RTL by themselves,
//  and the HStack swaps the two sides.

import SwiftUI

struct CarouselArrowButton: View {
    enum Kind { case previous, next }

    let kind: Kind
    let label: String
    let shown: Bool
    let tokens: RenderCarouselLook
    let look: RenderLook
    let fade: Animation?
    let action: () -> Void

    private static let previousGlyph = "chevron.backward"
    private static let nextGlyph = "chevron.forward"

    /// The touch target: the circle, grown to the minimum hit target.
    static func hitSize(_ tokens: RenderCarouselLook) -> CGFloat {
        CGFloat(max(tokens.arrowSize, MIN_TOUCH_TARGET))
    }

    var body: some View {
        let size = CGFloat(tokens.arrowSize)
        let hit = Self.hitSize(tokens)
        Button(action: action) {
            Image(systemName: kind == .previous ? Self.previousGlyph : Self.nextGlyph)
                .font(.system(size: size * CarouselFormat.glyphShare, weight: funnelFontWeight(look.emphasisWeight)))
                .foregroundColor(look.textColor)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(look.cardColor.opacity(Double(tokens.arrowFillOpacity) / Double(CarouselFormat.percent))))
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .animation(fade, value: shown)
    }
}
