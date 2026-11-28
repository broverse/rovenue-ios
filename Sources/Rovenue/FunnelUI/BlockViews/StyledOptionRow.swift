import SwiftUI

// Spec 2026-11-27 A: a choice question's authored row anatomy
// (`RenderRowStyle`). Every number and colour is the crate's — resolved
// with the look's value wherever the author set none — so nothing here
// picks a default of its own. `FunnelOptionRows` / `FunnelOptionTiles`
// draw these in place of their plain rows / tiles when the question has
// a `rowStyle`.

/// One styled option row:
/// `[start indicator] [thumb] [icon] (label, description below) … (trailing,
/// caption, description trailing) [end indicator]`, `contentGap` apart,
/// inside a `FunnelRowCard` painted, padded, sized and ledged per state.
struct StyledOptionRow: View {
    let option: RenderOption
    let style: RenderRowStyle
    let look: RenderLook
    let rowText: FunnelRowText
    let selected: Bool
    /// A grid tile: the text column takes every point the grid row offers,
    /// so the card (fill, border, ledge) is as tall as the row's tallest
    /// tile, not its own content.
    var fillsHeight = false

    var body: some View {
        StyledRowCard(style: style, look: look, selected: selected) {
            HStack(spacing: CGFloat(style.contentGap)) {
                if !style.indicator.isEnd {
                    RowIndicatorView(indicator: style.indicator, letter: option.letter, selected: selected)
                }
                if let thumb = StyledRowThumb(option: option, style: style) { thumb }
                if let icon = option.icon {
                    FunnelIconPlate(icon: style.leadingIcon(icon, selected: selected))
                }
                VStack(alignment: .leading, spacing: 0) {
                    // An image with no authored thumbnail size keeps
                    // today's place: above the label, full width.
                    if style.mediaSize == nil, let url = option.imageUrl.flatMap(URL.init(string:)) {
                        FunnelAsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: {
                            Color.clear
                        }
                        .cornerRadius(CGFloat(style.radius))
                    }
                    StyledRowLine(text: option.label, line: style.label, rowText: rowText, look: look, selected: selected)
                    if !style.description.isTrailing {
                        StyledRowDescription(
                            option: option, line: style.description.text, rowText: rowText, look: look,
                            selected: selected)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .leading)
                StyledRowTrailingColumn(option: option, style: style, rowText: rowText, look: look, selected: selected)
                if style.indicator.isEnd {
                    RowIndicatorView(indicator: style.indicator, letter: option.letter, selected: selected)
                }
            }
        }
    }
}

/// One styled grid tile. `iconPlacement == top` (ruling R23, the web's
/// anatomy): a row's slots, top-aligned — `[start indicator] [thumb]
/// (icon / image / label / description) [trailing column] [end indicator]`
/// — with the option's icon bare (no plate) over the label, `contentGap`
/// between. Otherwise the tile draws a row's content. Fills its grid
/// row's height, so a row's tiles are equally tall.
struct StyledOptionTile: View {
    let option: RenderOption
    let style: RenderRowStyle
    let look: RenderLook
    let rowText: FunnelRowText
    let selected: Bool

    var body: some View {
        if style.iconPlacement == RenderRowStyle.iconTop {
            StyledRowCard(style: style, look: look, selected: selected) {
                HStack(alignment: .top, spacing: CGFloat(style.contentGap)) {
                    if !style.indicator.isEnd {
                        RowIndicatorView(indicator: style.indicator, letter: option.letter, selected: selected)
                    }
                    if let thumb = StyledRowThumb(option: option, style: style) { thumb }
                    VStack(alignment: .leading, spacing: 0) {
                        if let icon = option.icon {
                            FunnelIconGlyph(icon: style.topIcon(icon, selected: selected), sizing: .followsText)
                        }
                        if style.mediaSize == nil, let url = option.imageUrl.flatMap(URL.init(string:)) {
                            FunnelAsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: {
                                Color.clear
                            }
                            .cornerRadius(CGFloat(style.radius))
                        }
                        StyledRowLine(
                            text: option.label, line: style.label, rowText: rowText, look: look, selected: selected
                        )
                        .padding(.top, option.icon == nil ? 0 : CGFloat(style.contentGap))
                        if !style.description.isTrailing {
                            StyledRowDescription(
                                option: option, line: style.description.text, rowText: rowText, look: look,
                                selected: selected)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    StyledRowTrailingColumn(
                        option: option, style: style, rowText: rowText, look: look, selected: selected)
                    if style.indicator.isEnd {
                        RowIndicatorView(indicator: style.indicator, letter: option.letter, selected: selected)
                    }
                }
            }
        } else {
            StyledOptionRow(
                option: option, style: style, look: look, rowText: rowText, selected: selected, fillsHeight: true)
        }
    }
}

/// The selection indicator a styled row draws, from the resolved
/// `RenderRowIndicator` alone: `radio` a circle (today's ring + fill, at
/// the row's size and colours); `check` a rounded square (`radius`) with
/// ✓ when selected (ruling R10); `circleCheck` a filled circle with ✓ when
/// selected; `letter` a rounded
/// square with the option's letter; `none` nothing. A ring is drawn only
/// for a state with a border colour.
struct RowIndicatorView: View {
    let indicator: RenderRowIndicator
    /// The option's badge letter (a `letter` indicator's).
    let letter: String?
    let selected: Bool

    /// The check mark a selected `circleCheck` draws.
    private static let checkGlyph = "✓"
    private static let glyphWeight = 700

    var body: some View {
        let size = CGFloat(indicator.size)
        switch indicator.kind {
        case RenderRowIndicator.kindRadio:
            plate(Circle()).frame(width: size, height: size).accessibilityHidden(true)
        case RenderRowIndicator.kindCheck, RenderRowIndicator.kindLetter:
            plate(RoundedRectangle(cornerRadius: CGFloat(indicator.radius)))
                .overlay {
                    if indicator.kind == RenderRowIndicator.kindLetter {
                        if let letter { glyph(letter) }
                    } else if selected {
                        glyph(Self.checkGlyph)
                    }
                }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case RenderRowIndicator.kindCircleCheck:
            plate(Circle())
                .overlay { if selected { glyph(Self.checkGlyph) } }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        default:
            // `none`, and a kind this build does not know: no indicator.
            EmptyView()
        }
    }

    private func plate<S: InsettableShape>(_ shape: S) -> some View {
        let ring = funnelColor(selected ? indicator.selectedBorder : indicator.border)
        return shape.fill(lookColor(selected ? indicator.selectedFill : indicator.fill))
            .overlay {
                if let ring, indicator.borderWidth > 0 {
                    shape.strokeBorder(ring, lineWidth: CGFloat(indicator.borderWidth))
                }
            }
    }

    private func glyph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: CGFloat(indicator.glyphSize), weight: funnelFontWeight(Self.glyphWeight)))
            .foregroundColor(lookColor(selected ? indicator.selectedGlyph : indicator.glyph))
    }
}

/// The card every styled row and tile sits on: `FunnelRowCard` with the
/// row style's paint, padding, least height and this state's ledge.
private struct StyledRowCard<Content: View>: View {
    let style: RenderRowStyle
    let look: RenderLook
    let selected: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        FunnelRowCard(
            look: look, selected: selected, shape: .radio, indicator: false, paint: style.cardPaint,
            insets: RenderInsets(x: style.paddingX, y: style.paddingY),
            minHeight: style.minHeight > 0 ? CGFloat(style.minHeight) : nil,
            ledge: FunnelLedge(
                depth: CGFloat(style.ledgeDepth),
                color: funnelColor(selected ? style.ledgeSelectedColor : style.ledgeColor)),
            content: content)
    }
}

/// A line of row copy in its `RenderRowText`: size, line height, weight,
/// family (the block's when the row names none) and this state's colour.
private struct StyledRowLine: View {
    let text: String
    let line: RenderRowText
    let rowText: FunnelRowText
    let look: RenderLook
    let selected: Bool

    var body: some View {
        Text(text).styledRowText(line, rowText: rowText, look: look, selected: selected)
    }
}

/// The option's description in its row text, when it has one; a marked
/// description keeps its runs.
private struct StyledRowDescription: View {
    let option: RenderOption
    let line: RenderRowText
    let rowText: FunnelRowText
    let look: RenderLook
    let selected: Bool

    var body: some View {
        if let description = option.description, !description.isEmpty {
            FunnelDescriptionCopy(
                text: description, segments: option.descriptionSegments, rowText: rowText, look: look)
                .styledRowText(line, rowText: rowText, look: look, selected: selected)
        }
    }
}

/// The right-aligned column after the text: the trailing value, its
/// caption, and a `trailing`-placed description. Absent when the option
/// has none of them. Not fixed to its ideal width: the row's `HStack`
/// sizes it before the (infinitely flexible) label column, which caps it
/// at an even share of the row, so long trailing copy wraps (each line at
/// most `trailingLines`) instead of squeezing the label to nothing.
private struct StyledRowTrailingColumn: View {
    let option: RenderOption
    let style: RenderRowStyle
    let rowText: FunnelRowText
    let look: RenderLook
    let selected: Bool

    static let trailingLines = 2

    private var hasDescription: Bool {
        style.description.isTrailing && !(option.description ?? "").isEmpty
    }

    var body: some View {
        if option.trailing != nil || option.trailingCaption != nil || hasDescription {
            VStack(alignment: .trailing, spacing: 0) {
                if let trailing = option.trailing {
                    StyledRowLine(text: trailing, line: style.trailing, rowText: rowText, look: look, selected: selected)
                }
                if let caption = option.trailingCaption {
                    StyledRowLine(
                        text: caption, line: style.trailingCaption, rowText: rowText, look: look, selected: selected)
                }
                if hasDescription {
                    StyledRowDescription(
                        option: option, line: style.description.text, rowText: rowText, look: look,
                        selected: selected)
                }
            }
            .multilineTextAlignment(.trailing)
            .lineLimit(Self.trailingLines)
        }
    }
}

/// The option's image as a leading `mediaSize` square, `mediaRadius`
/// corners — only when the row style sizes one and the option has one.
private struct StyledRowThumb: View {
    let url: URL
    let size: CGFloat
    let radius: CGFloat

    init?(option: RenderOption, style: RenderRowStyle) {
        guard let size = style.mediaSize, let url = option.imageUrl.flatMap(URL.init(string:)) else { return nil }
        self.url = url
        self.size = CGFloat(size)
        self.radius = CGFloat(style.mediaRadius ?? 0)
    }

    var body: some View {
        FunnelAsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .contentShape(Rectangle())
    }
}

extension View {
    /// Row copy in a `RenderRowText`.
    fileprivate func styledRowText(
        _ line: RenderRowText, rowText: FunnelRowText, look: RenderLook, selected: Bool
    ) -> some View {
        let size = CGFloat(line.size)
        let family = line.family ?? rowText.family
        return
            self
            .funnelTextFont(size: size, weight: line.weight, family: family, scale: rowText.scale)
            .foregroundColor(lookColor(selected ? line.selectedColor ?? line.color : line.color))
            .funnelLineHeight(look, size: size, family: family, percent: line.lineHeightPercent)
    }
}

extension RenderRowText {
    /// The resolved line height (pt) as the percent of `size`
    /// `funnelLineHeight` takes.
    fileprivate var lineHeightPercent: Int {
        guard size > 0 else { return 0 }
        return Int((Double(lineHeight) * 100 / Double(size)).rounded())
    }
}

extension RenderRowIndicator {
    fileprivate var isEnd: Bool { position == Self.positionEnd }
}

extension RenderRowDescription {
    fileprivate var isTrailing: Bool { placement == Self.placementTrailing }
}

extension RenderRowStyle {
    /// The card paint `FunnelRowCard` takes.
    fileprivate var cardPaint: RenderPackageCard {
        RenderPackageCard(
            fill: fill, selectedFill: selectedFill, border: border, selectedBorder: selectedBorder,
            borderWidth: borderWidth, selectedBorderWidth: selectedBorderWidth, radius: radius,
            titleColor: nil, selectedTitleColor: nil, priceColor: nil, selectedPriceColor: nil,
            captionColor: nil, selectedCaptionColor: nil)
    }

    /// This state's icon colour: the authored selected one while picked,
    /// else the authored one, else the icon's own (ruling R9).
    private func iconTint(_ icon: RenderIcon, selected: Bool) -> String {
        (selected ? iconSelectedColor : nil) ?? iconColor ?? icon.color
    }

    /// A leading icon keeps its own plate, and its own size and colour
    /// unless the row style sets them (spec A, ruling R9).
    fileprivate func leadingIcon(_ icon: RenderIcon, selected: Bool) -> RenderIcon {
        icon.repainted(color: iconTint(icon, selected: selected), size: iconSize ?? icon.size, plate: icon.plate)
    }

    /// A top icon draws bare (no plate), tinted per state, at `iconSize`
    /// or the size the resolver gave the tile's icon.
    fileprivate func topIcon(_ icon: RenderIcon, selected: Bool) -> RenderIcon {
        icon.repainted(color: iconTint(icon, selected: selected), size: iconSize ?? icon.size, plate: nil)
    }
}

extension RenderIcon {
    fileprivate func repainted(color: String, size: Int, plate: RenderPlate?) -> RenderIcon {
        RenderIcon(
            pack: pack, name: name, color: color, size: size, layers: layers, plate: plate,
            systemSymbol: systemSymbol, weight: weight)
    }
}
