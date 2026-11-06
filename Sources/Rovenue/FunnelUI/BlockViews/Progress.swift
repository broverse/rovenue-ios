//  Progress.swift — the progress block: back control · bar · label.
//
//  Every number is the crate's (`look::progress_geometry`, carried on the
//  block): the bar's height and radius, the segmented gap, the dash, the
//  back control's hit target and glyph, the label's size and opacity, the
//  row's gap. None is chosen here. The web draws the same row from the
//  same fields (`funnel-renderer` progress block), Android too.

import SwiftUI

private enum ProgressFormat {
    /// `labelOpacity` is a percentage on the wire (65 = 0.65).
    static let opacityPercent = 100.0
    /// A one-page funnel is complete — the web's `total > 1 ? … : 1`.
    static let complete: CGFloat = 1
    static let empty: CGFloat = 0
    /// A segmented bar draws at least one cell.
    static let minimumCells = 1
    /// A funnel this long or shorter shows its bar full.
    static let singlePage = 1
    /// The back glyphs — `.backward` mirrors itself right to left.
    static let chevronSymbol = "chevron.backward"
    static let arrowSymbol = "arrow.backward"
}

struct FunnelProgressView: View {
    /// The text size (FunnelTextScale): read so this view redraws when it changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let block: ProgressBlock
    let look: RenderLook
    let onBack: () -> Void
    @Environment(\.funnelCopy) private var copy

    init(block: ProgressBlock, look: RenderLook, onBack: @escaping () -> Void) {
        self.block = block
        self.look = look
        self.onBack = onBack
    }

    var body: some View {
        HStack(spacing: CGFloat(block.rowGap)) {
            if block.showBack { back }
            if block.showBar {
                FunnelProgressBar(block: block).frame(maxWidth: .infinity)
            } else {
                // Keeps the label at the row's end with no bar to push it.
                Spacer(minLength: ProgressFormat.empty)
            }
            if let label = block.labelText {
                Text(label)
                    .font(.system(size: FunnelTextScale(dynamicType: dynamicTypeSize)(CGFloat(block.labelSize))).monospacedDigit())
                    .opacity(Double(block.labelOpacity) / ProgressFormat.opacityPercent)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundColor(look.textColor)
        .funnelStyle(block.style, look.bodyType)
    }

    /// The back control: a `backSize` square around a `backGlyphSize`
    /// glyph, drawn held (dimmed, no tap) on the first page. The glyph sits
    /// beside the row's label, so it grows with the text size; the square
    /// is the tree's hit target and grows only once the glyph outgrows it.
    private var back: some View {
        let glyph = funnelGlyphSide(
            CGFloat(block.backGlyphSize), .followsText, FunnelTextScale(dynamicType: dynamicTypeSize))
        let side = max(CGFloat(block.backSize), glyph)
        return Button(action: onBack) {
            Image(
                systemName: block.backIcon == ProgressBlock.iconArrow
                    ? ProgressFormat.arrowSymbol : ProgressFormat.chevronSymbol
            )
            .font(.system(size: glyph))
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!block.backEnabled)
        .funnelHeld(block.backEnabled)
        // The screen's localized "Back"; with no copy installed the glyph
        // keeps SwiftUI's own name rather than an empty one.
        .ifLet(copy?.back) { $0.accessibilityLabel(Text($1)) }
    }
}

/// The bar, in its style: one track with a fill (`solid`, `rounded`), a
/// cell per page (`segmented`), or a dashed track under the fill
/// (`dashed`).
private struct FunnelProgressBar: View {
    let block: ProgressBlock

    var body: some View {
        let active = funnelColor(block.activeColor) ?? .clear
        let track = funnelColor(block.trackColor) ?? .clear
        let height = CGFloat(block.barHeight)
        let radius = CGFloat(block.barRadius)
        switch block.barStyle {
        case ProgressBlock.styleSegmented:
            HStack(spacing: block.segmentGap.map(CGFloat.init) ?? ProgressFormat.empty) {
                ForEach(0..<max(ProgressFormat.minimumCells, block.total), id: \.self) { cell in
                    RoundedRectangle(cornerRadius: radius)
                        .fill(cell < block.current ? active : track)
                        .frame(height: height)
                }
            }
        case ProgressBlock.styleDashed:
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Path { path in
                        path.move(to: CGPoint(x: ProgressFormat.empty, y: height / FunnelGeometry.halves))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: height / FunnelGeometry.halves))
                    }
                    .stroke(
                        track,
                        style: StrokeStyle(
                            lineWidth: height,
                            dash: [block.dashLength, block.dashGap].map { $0.map(CGFloat.init) ?? ProgressFormat.empty }))
                    RoundedRectangle(cornerRadius: radius)
                        .fill(active)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: height)
        default:
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: radius).fill(track)
                    RoundedRectangle(cornerRadius: radius)
                        .fill(active)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: height)
        }
    }

    /// How much of the bar is filled: this page of `total`.
    private var fraction: CGFloat {
        guard block.total > ProgressFormat.singlePage else { return ProgressFormat.complete }
        return min(ProgressFormat.complete, CGFloat(block.current) / CGFloat(block.total))
    }
}
