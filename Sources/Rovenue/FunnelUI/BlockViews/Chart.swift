//  Chart.swift — the chart block (spec 2026-11-10 NE §4.5, §7).
//
//  The resolver drew it: a projection's points and a bar's height are per
//  mille of the plot box, x in READING order, y from the top; the values,
//  the end date and the accessible summary are already formatted in the
//  visitor's language. This view only multiplies by its box — and flips x
//  right to left (`x' = 1000 − x`), as every RTL layout mirrors, so "first"
//  is always the reading-start side for both kinds. The plot's height and
//  every stroke, radius and gap are `look.elements.chart` tokens.

import SwiftUI

private enum ChartFormat {
    static let kindBars = "bars"
    static let fillArea = "area"
    static let perMille = 1000
    static let wordSpace = " "
    static let listSeparator = ", "
    static let hidden: CGFloat = 0
    static let shown: CGFloat = 1
    static let millisecondsPerSecond = 1000.0
}

struct FunnelChartView: View {
    let block: ChartBlock
    let look: RenderLook
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.funnelScreenMotion) private var screenMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// How much of the line is drawn / how tall the bars stand, 0…1: grows
    /// over the look's "normal" duration on first appearance, complete at
    /// once under Reduce Motion.
    @State private var reveal = ChartFormat.hidden

    init(block: ChartBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    private var tokens: RenderChartLook { look.elements.chart }
    private var scale: FunnelTextScale { FunnelTextScale(dynamicType: dynamicTypeSize) }
    private var rtl: Bool { layoutDirection == .rightToLeft }

    var body: some View {
        Group {
            if block.kind == ChartFormat.kindBars { bars } else { projection }
        }
        .frame(maxWidth: .infinity)
        .funnelStyle(block.style, look.bodyType)
        .onAppear(perform: revealOnce)
    }

    private func revealOnce() {
        guard reveal == ChartFormat.hidden else { return }
        guard let screenMotion, screenMotion.mode == .full, screenMotion.leavingMs == nil else {
            reveal = ChartFormat.shown
            return
        }
        withAnimation(.easeOut(duration: Double(look.motion.normalMs) / ChartFormat.millisecondsPerSecond)) {
            reveal = ChartFormat.shown
        }
    }

    // MARK: Projection

    private var projection: some View {
        VStack(spacing: CGFloat(look.indicatorGap)) {
            HStack(alignment: .lastTextBaseline) {
                caption(withUnit(block.startValue), type: look.emphasisType, color: look.textColor)
                Spacer(minLength: CGFloat(look.indicatorGap))
                if let marker = block.marker {
                    caption(marker, type: look.mutedType, color: look.mutedColor)
                }
                caption(withUnit(block.endValue), type: look.emphasisType, color: look.accentColor)
            }
            plot
                .frame(height: CGFloat(tokens.height))
            HStack {
                caption(block.startLabel, type: look.mutedType, color: look.mutedColor)
                Spacer(minLength: CGFloat(look.indicatorGap))
                caption(block.endLabel, type: look.mutedType, color: look.mutedColor)
            }
        }
        // One image to VoiceOver, its summary the resolver's (spec NE §7).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(block.label))
        .accessibilityAddTraits(.isImage)
    }

    private var plot: some View {
        GeometryReader { proxy in
            let points = block.points.compactMap { point(for: $0, in: proxy.size) }
            ZStack(alignment: .topLeading) {
                if block.fill == ChartFormat.fillArea, let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                        for p in points { path.addLine(to: p) }
                        path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(look.accentColor.opacity(look.chartAreaOpacity * Double(reveal)))
                }
                Path { path in path.addLines(points) }
                    .trim(from: ChartFormat.hidden, to: reveal)
                    .stroke(
                        look.accentColor,
                        style: StrokeStyle(lineWidth: CGFloat(tokens.strokeWidth), lineCap: .round, lineJoin: .round))
                if block.marker != nil, let last = points.last {
                    let r = CGFloat(tokens.markerRadius)
                    Circle()
                        .fill(look.accentColor)
                        .frame(width: r * FunnelGeometry.halves, height: r * FunnelGeometry.halves)
                        .position(last)
                        .opacity(Double(reveal))
                }
            }
        }
    }

    /// A per-mille point in the box; x mirrored right to left.
    private func point(for pair: [Int], in size: CGSize) -> CGPoint? {
        guard pair.count == 2 else { return nil }
        let x = rtl ? ChartFormat.perMille - pair[0] : pair[0]
        return CGPoint(x: look.chartShare(x) * size.width, y: look.chartShare(pair[1]) * size.height)
    }

    // MARK: Bars

    /// 2–5 bars, equal widths `barGap` apart, each value above and label
    /// below; the row mirrors right to left (spec NE §7).
    private var bars: some View {
        HStack(alignment: .bottom, spacing: CGFloat(tokens.barGap)) {
            ForEach(Array(block.bars.enumerated()), id: \.offset) { _, bar in
                VStack(spacing: CGFloat(look.indicatorGap)) {
                    VStack(spacing: CGFloat(look.indicatorGap)) {
                        caption(bar.value, type: look.emphasisType, color: bar.highlight ? look.accentColor : look.textColor)
                        RoundedRectangle(cornerRadius: CGFloat(tokens.barRadius))
                            .fill(bar.highlight ? look.accentColor : look.borderColor)
                            .frame(height: look.chartShare(bar.height) * CGFloat(tokens.height))
                            .scaleEffect(x: ChartFormat.shown, y: reveal, anchor: .bottom)
                    }
                    .frame(height: CGFloat(tokens.height), alignment: .bottom)
                    caption(bar.label, type: look.mutedType, color: look.mutedColor)
                }
                .frame(maxWidth: .infinity)
                // Each bar's label and value to VoiceOver (spec NE §7).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(bar.label + ChartFormat.listSeparator + bar.value))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(block.label))
    }

    // MARK: Copy

    private func withUnit(_ value: String?) -> String? {
        guard let value else { return nil }
        guard let unit = block.unit else { return value }
        return value + ChartFormat.wordSpace + unit
    }

    @ViewBuilder
    private func caption(_ text: String?, type: FunnelType, color: Color) -> some View {
        if let text {
            Text(text)
                .font(funnelFont(block.style, type, scale: scale))
                .foregroundColor(color)
                .lineLimit(1)
        }
    }
}
