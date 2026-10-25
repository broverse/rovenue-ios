//  Paywall.swift — the comparison table and the feature list (spec
//  2026-10-11-funnel-paywall-blocks §4.2, §4.3).
//
//  Every length, size, weight and colour is the screen's look — the
//  table's `tableValueColumnWidth` / `tableRowPaddingY` / `tableHeader*` /
//  `tableCheckSize` / `tableHighlight`, the list's `featureIcon*` /
//  `featureItemGap` — exactly as the web's `blocks/paywall.tsx` and
//  Android's `blocks/Paywall.kt` read them. The glyph GEOMETRY (a check and
//  a dash in a 24-unit box) is the one shape all three drawers trace; its
//  stroke is the look's `selectedBorderWidth`.

import SwiftUI

private enum PaywallFormat {
    /// The box the glyph points are written in — the web's `GLYPH_VIEWBOX`.
    static let glyphBox: CGFloat = 24
    /// The check: (5, 12.5) → (9.5, 17) → (19, 7.5) — the web's `CHECK_PATH`.
    static let check: [CGPoint] = [
        CGPoint(x: 5, y: 12.5), CGPoint(x: 9.5, y: 17), CGPoint(x: 19, y: 7.5),
    ]
    /// The dash: (7, 12) → (17, 12) — the web's `DASH_PATH`.
    static let dash: [CGPoint] = [CGPoint(x: 7, y: 12), CGPoint(x: 17, y: 12)]
    static let cellCheck = "check"
    static let cellDash = "dash"
    static let cellText = "text"
    static let iconEmoji = "emoji"
    static let iconImage = "image"
    /// An emoji is one glyph on one line.
    static let singleLine = 1
}

/// A polyline in the 24-unit glyph box, scaled to the frame it is drawn in.
struct FunnelGlyphShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / PaywallFormat.glyphBox
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) })
        return path
    }
}

/// A stroked check or dash, `size` square, in `color`.
private struct FunnelGlyph: View {
    let points: [CGPoint]
    let size: Int
    let color: Color
    let look: RenderLook

    var body: some View {
        FunnelGlyphShape(points: points)
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: CGFloat(look.selectedBorderWidth), lineCap: .round, lineJoin: .round))
            .frame(width: CGFloat(size), height: CGFloat(size))
    }
}

/// The highlighted column's cell background: square, except the column's
/// outer corners (the header's top, the last row's bottom) round to
/// `cardRadius`. A Shape because iOS 16 has no uneven rounded rectangle.
private struct FunnelColumnCell: Shape {
    let radius: CGFloat
    let roundTop: Bool
    let roundBottom: Bool

    func path(in rect: CGRect) -> Path {
        let top = roundTop ? min(radius, rect.height / 2) : 0
        let bottom = roundBottom ? min(radius, rect.height / 2) : 0
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            p.addQuadCurve(
                to: CGPoint(x: rect.minX + top, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + top),
                control: CGPoint(x: rect.maxX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        if bottom > 0 {
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        if bottom > 0 {
            p.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
                control: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Comparison table

/// A label column that takes the remaining width and wraps, then 1...3
/// value columns each exactly `tableValueColumnWidth` wide with their
/// content centred, so every row's value cells share one x-centre. Headers
/// are `tableHeaderSize` in `tableHeaderWeight`, `muted` except the
/// highlighted column's (`accent`), which stands on `tableHighlight` for
/// the column's full height. Rows are padded `tableRowPaddingY` and
/// separated by a `borderWidth` hairline in `border`. A check is `accent`
/// in the highlighted column and `text` elsewhere, a dash `muted`; each is
/// read aloud as the screen copy's `included` / `notIncluded`.
struct FunnelComparisonTableView: View {
    let block: ComparisonTableBlock
    let look: RenderLook
    @Environment(\.funnelCopy) private var copy

    init(block: ComparisonTableBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(block.rows.enumerated()), id: \.offset) { index, row in
                tableRow(row, index: index)
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            ForEach(Array(block.columns.enumerated()), id: \.offset) { column, title in
                valueCell(column: column, roundTop: true, roundBottom: false) {
                    Text(title)
                        .font(funnelFont(
                            size: CGFloat(look.tableHeaderSize), weight: look.tableHeaderWeight,
                            family: block.style.fontFamily))
                        .foregroundColor(isHighlighted(column) ? look.accentColor : look.mutedColor)
                        .multilineTextAlignment(.center)
                        .funnelLineHeight(look, size: look.tableHeaderSize, family: block.style.fontFamily)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tableRow(_ row: RenderTableRow, index: Int) -> some View {
        let last = index == block.rows.count - 1
        return HStack(spacing: 0) {
            Text(row.label)
                .font(funnelFont(size: CGFloat(look.textSize), weight: look.textWeight, family: block.style.fontFamily))
                .multilineTextAlignment(.leading)
                .funnelLineHeight(look, size: look.textSize, family: block.style.fontFamily)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, CGFloat(look.tableRowPaddingY))
                .padding(.trailing, CGFloat(look.indicatorGap))
            ForEach(Array(row.cells.enumerated()), id: \.offset) { column, cell in
                valueCell(column: column, roundTop: false, roundBottom: last) {
                    cellContent(cell, column: column)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // The hairline runs across the highlighted column too, as on the web.
        .overlay(alignment: .top) {
            if index > 0 {
                Rectangle().fill(look.borderColor).frame(height: CGFloat(look.borderWidth))
            }
        }
    }

    private func valueCell<Content: View>(
        column: Int, roundTop: Bool, roundBottom: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.vertical, CGFloat(look.tableRowPaddingY))
            .frame(width: CGFloat(look.tableValueColumnWidth))
            .frame(maxHeight: .infinity)
            .background(
                FunnelColumnCell(radius: CGFloat(look.cardRadius), roundTop: roundTop, roundBottom: roundBottom)
                    .fill(isHighlighted(column) ? look.tableHighlightColor : .clear))
    }

    @ViewBuilder
    private func cellContent(_ cell: RenderTableCell, column: Int) -> some View {
        switch cell.kind {
        case PaywallFormat.cellCheck:
            FunnelGlyph(
                points: PaywallFormat.check, size: look.tableCheckSize,
                color: isHighlighted(column) ? look.accentColor : look.textColor, look: look
            )
            .accessibilityElement()
            .ifLet(copy) { $0.accessibilityLabel($1.included) }
        case PaywallFormat.cellDash:
            FunnelGlyph(points: PaywallFormat.dash, size: look.tableCheckSize, color: look.mutedColor, look: look)
                .accessibilityElement()
                .ifLet(copy) { $0.accessibilityLabel($1.notIncluded) }
        case PaywallFormat.cellText:
            Text(cell.text ?? "")
                .font(funnelFont(
                    size: CGFloat(look.mutedTextSize), weight: look.labelWeight, family: block.style.fontFamily))
                .multilineTextAlignment(.center)
                .funnelLineHeight(look, size: look.mutedTextSize, family: block.style.fontFamily)
        default:
            // A cell kind this build does not know draws an empty cell
            // rather than shifting the columns after it.
            EmptyView()
        }
    }

    private func isHighlighted(_ column: Int) -> Bool { block.highlight == column }
}

// MARK: - Feature list

/// Rows `featureItemGap` apart, each the block's ONE `iconColumn` (the
/// crate's widest outer icon box) with the item's icon centred in it, then
/// the copy `featureIconGap` after it — so every title starts at one x: the title at `textSize` in `labelWeight`, the body (when the
/// resolver kept one) at `mutedTextSize` in `muted`. The icon is
/// top-aligned with the title's first line. An emoji is its glyph at
/// `featureIconSize`, an image fills that box, and an `icon` or `check` is
/// its tree glyph inside its plate.
struct FunnelFeatureListView: View {
    let block: FeatureListBlock
    let look: RenderLook

    init(block: FeatureListBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(look.featureItemGap)) {
            ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: CGFloat(look.featureIconGap)) {
                    // The block's ONE icon column, the icon centred in it,
                    // so every title starts at the same x.
                    icon(item)
                        .frame(width: CGFloat(block.iconColumn))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title)
                            .font(funnelFont(
                                size: CGFloat(look.textSize), weight: look.labelWeight,
                                family: block.style.fontFamily))
                            .funnelLineHeight(look, size: look.textSize, family: block.style.fontFamily)
                        if let body = item.body, !body.isEmpty {
                            Text(body)
                                .font(funnelFont(
                                    size: CGFloat(look.mutedTextSize), weight: look.textWeight,
                                    family: block.style.fontFamily))
                                .foregroundColor(look.mutedColor)
                                .funnelLineHeight(look, size: look.mutedTextSize, family: block.style.fontFamily)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .funnelStyle(block.style, look.bodyType)
    }

    /// An emoji, an image or the fallback check fill the `featureIconSize`
    /// square; an `icon` or `check` item that carries its drawn mark is
    /// that glyph inside its plate, and the box is the plate's.
    @ViewBuilder
    private func icon(_ item: RenderFeature) -> some View {
        switch item.iconKind {
        case PaywallFormat.iconEmoji:
            Text(item.icon)
                .font(.system(size: CGFloat(look.featureIconSize)))
                .lineLimit(PaywallFormat.singleLine)
                .fixedSize()
                .frame(width: CGFloat(look.featureIconSize), height: CGFloat(look.featureIconSize))
        case PaywallFormat.iconImage:
            AsyncImage(url: URL(string: item.icon)) { $0.resizable().scaledToFill() } placeholder: {
                Color.clear
            }
            .frame(width: CGFloat(look.featureIconSize), height: CGFloat(look.featureIconSize))
            .clipped()
        default:
            if let glyph = item.glyph {
                // `icon` and `check` items carry their mark — the set's
                // glyph (the check for `check`) with its colour and plate.
                FunnelIconPlate(icon: glyph)
            } else {
                // Any icon kind this build does not know: the column keeps
                // the vector check rather than collapsing.
                FunnelGlyph(points: PaywallFormat.check, size: look.featureIconSize, color: look.accentColor, look: look)
                    .frame(width: CGFloat(look.featureIconSize), height: CGFloat(look.featureIconSize))
            }
        }
    }
}
