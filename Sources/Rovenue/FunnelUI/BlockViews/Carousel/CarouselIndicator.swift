//  CarouselIndicator.swift — dots, pill, story bars or the counter (spec CL
//  §4.3).
//
//  Marks are buttons on `indicatorPitch` (WCAG 2.5.8 by spacing, not
//  padding): each is a pitch-tall box and the space between two marks is
//  `pitch − size`. An overlaid row takes touches on its marks only — the
//  slide under the rest of the row keeps its taps (A3). The pill's active
//  mark widens to `size × pillFactor` on the fade speed. Bars share the
//  row: `segment = (rowWidth − (n − 1) × barGap) / n`; done segments are
//  full, upcoming empty, and the current one fills from the autoplay clock
//  that turns the page (F7). The counter shows the resolver's label and is
//  hidden from assistive tech (the carousel announces its position).

import SwiftUI

struct CarouselIndicatorView: View {
    let indicator: RenderIndicator
    let tokens: RenderCarouselLook
    let count: Int
    let index: Int
    let counterLabels: [String]
    /// The width bars divide: the carousel's, less the overlay insets or
    /// the arrows beside it.
    let rowWidth: CGFloat
    @ObservedObject var clock: CarouselClock
    let fade: Animation?
    let onPick: (Int) -> Void

    @Environment(\.funnelCopy) private var copy

    private var size: CGFloat { CGFloat(indicator.size) }
    private var pitch: CGFloat { CGFloat(tokens.indicatorPitch) }
    private var active: Color { funnelColor(indicator.activeColor) ?? .clear }
    private var inactive: Color { funnelColor(indicator.inactiveColor) ?? .clear }

    var body: some View {
        switch indicator.style {
        case CarouselFormat.styleCounter: counter
        case CarouselFormat.styleBars: bars
        default: marks
        }
    }

    private var counter: some View {
        Text(counterLabels.indices.contains(index) ? counterLabels[index] : "")
            .font(.system(size: size * CGFloat(tokens.counterTextFactor), weight: funnelFontWeight(tokens.counterWeight)))
            .monospacedDigit()
            .foregroundColor(active)
            .padding(.horizontal, CGFloat(tokens.counterPaddingX))
            .padding(.vertical, CGFloat(tokens.counterPaddingY))
            .background(Capsule().fill(inactive))
            .frame(minHeight: pitch)
            .carouselNeverExposed()
            .allowsHitTesting(false)
    }

    /// Dots and the pill: one pitch-wide button per slide.
    private var marks: some View {
        let spacing = max(0, pitch - size)
        let pill = indicator.style == CarouselFormat.stylePill
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let current = i == index
                let markWidth = pill && current ? size * CGFloat(tokens.pillFactor) : size
                Button { onPick(i) } label: {
                    Capsule()
                        .fill(current ? active : inactive)
                        .frame(width: markWidth, height: size)
                        .frame(width: markWidth + spacing, height: pitch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(CarouselMarkLabel(position: i + 1, count: count, current: current))
            }
        }
        .animation(fade, value: index)
        .frame(maxWidth: .infinity)
    }

    /// Story bars: the row divided evenly, the current one filling.
    private var bars: some View {
        let gap = CGFloat(tokens.barGap)
        let segment = max(0, (rowWidth - CGFloat(count - 1) * gap) / CGFloat(max(count, 1)))
        return TimelineView(.animation(minimumInterval: nil, paused: !clock.running)) { context in
            let fill = clock.fill(at: context.date)
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { i in
                    let share: CGFloat = i < index ? 1 : (i == index ? CGFloat(fill) : 0)
                    Button { onPick(i) } label: {
                        ZStack(alignment: .leading) {
                            Capsule().fill(inactive)
                            Capsule().fill(active).frame(width: segment * share)
                        }
                        // The fill runs from the leading edge in either direction.
                        .frame(width: segment, height: size)
                        .clipShape(Capsule())
                        .frame(width: segment, height: pitch)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(CarouselMarkLabel(position: i + 1, count: count, current: i == index))
                }
            }
        }
        // The fill follows the clock alone: a page change (animated on the
        // pager's spring) must not tween a bar from its fill to full.
        .transaction { $0.animation = nil }
        .frame(maxWidth: .infinity)
    }
}

/// A mark's spoken name: `positionOf` filled, a button.
private struct CarouselMarkLabel: ViewModifier {
    @Environment(\.funnelCopy) private var copy
    let position: Int
    let count: Int
    let current: Bool

    func body(content: Content) -> some View {
        content
            .ifLet(copy) { $0.accessibilityLabel(FunnelA11y.position(position, of: count, copy: $1)) }
            .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }
}
