//  Questions.swift — the sixteen input controls.
//
//  `required`, `selected`, `options` and `contactFields` all arrive
//  resolved — including the two options of a `yes_no` the author left
//  bare, which the resolver synthesizes and localizes (spec D4). This file
//  chooses a control and reports changes; it decides nothing about whether
//  a question should be asked or is answered.
//
//  Every length, size, weight and colour is the screen's look (spec D1),
//  the web's `blocks/questions.tsx` element by element: fields are the
//  one box in Fields.swift; the slider, the stars and the opinion scale
//  draw from the look's control tokens. A block's authored `fontSize` sets
//  the primary text, `fontFamily` every text (spec D2, `FunnelRowText`).
//  Every control seeds its state from the resolver in `init`, so drawing a
//  control never reports an answer nobody gave.
//
//  The `switch` over QuestionKind is exhaustive, so a kind added without a
//  control does not compile.

import Foundation
import SwiftUI

/// The resolver's QUESTION_KINDS, verbatim. `init?(rawValue:)` returning
/// nil is how a forward-version kind degrades.
enum QuestionKind: String, CaseIterable, Sendable {
    case singleChoice = "single_choice"
    case multiChoice = "multi_choice"
    case pictureChoice = "picture_choice"
    case yesNo = "yes_no"
    case shortText = "short_text"
    case longText = "long_text"
    case email
    case phone
    case numberInput = "number_input"
    case dateInput = "date_input"
    case slider
    case rating
    case opinionScale = "opinion_scale"
    case contactInfo = "contact_info"
    case legal
    case checkbox
}

/// What a control reports upward. The entry point turns it into
/// `session.submit`; a control never calls the session itself.
enum QuestionAnswer: Equatable, Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([String])
    case contact([String: String])
}

private enum QuestionFormat {
    static let starCount = 5
    static let opinionScaleLow = 1
    static let opinionScaleHigh = 10
    static let defaultSliderMin = 0.0
    static let defaultSliderMax = 100.0
    static let defaultSliderStep = 1.0
    static let trueValue = "true"
    static let half: CGFloat = 2
    /// A plate's padding sits on both sides of its glyph.
    static let sides = 2
    /// Contact field names the resolver sends (`contactFields`).
    static let contactEmail = "email"
    static let contactPhone = "phone"
}

/// A `YYYY-MM-DD` calendar date, zero-padded and Gregorian, read in the
/// device's own time zone.
///
/// Two decisions, both load-bearing:
///
/// **Gregorian, always.** A device set to the Buddhist or Hebrew calendar
/// would otherwise produce a year the evaluator cannot compare at all.
///
/// **The device's time zone, not UTC.** A `DatePicker` hands back the
/// instant of local midnight, so reading it in UTC shifts the day backwards
/// everywhere east of Greenwich: someone in Istanbul picking 5 January
/// would submit `2026-01-04`. The answer has to be the date they saw.
///
/// The format itself is not cosmetic either: the evaluator's date operators
/// compare lexicographically because that equals chronological order for
/// zero-padded `YYYY-MM-DD` and only for it — `2026-1-5` sorts after
/// `2026-01-10` as text while being earlier as a date.
func isoDateString(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}


/// The inverse of `isoDateString`, in the same frame — local midnight of
/// that calendar date, so a round trip does not drift a day.
func isoDate(_ s: String) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let parts = s.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var c = DateComponents()
    c.year = parts[0]
    c.month = parts[1]
    c.day = parts[2]
    return calendar.date(from: c)
}

struct FunnelQuestionView: View {
    let block: QuestionBlock
    let look: RenderLook
    let onAnswer: (QuestionAnswer) -> Void
    let onOptionTap: (String) -> Void

    init(
        block: QuestionBlock,
        look: RenderLook,
        onAnswer: @escaping (QuestionAnswer) -> Void,
        onOptionTap: @escaping (String) -> Void
    ) {
        self.block = block
        self.look = look
        self.onAnswer = onAnswer
        self.onOptionTap = onOptionTap
    }

    var body: some View {
        // A kind this build does not know draws nothing rather than
        // crashing — the same degradation the resolver applies to an
        // unknown block type. The wrapper carries the block's style, so its
        // colour reaches every primary text that does not set its own; the
        // authored size and family are applied per text (spec D2).
        if let kind = QuestionKind(rawValue: block.kind) {
            control(for: kind, text: FunnelRowText(look: look, style: block.style))
                .funnelStyle(block.style, look.bodyType)
        }
    }

    @ViewBuilder
    private func control(for kind: QuestionKind, text: FunnelRowText) -> some View {
        switch kind {
        // The resolver sends a bare yes/no its two options (spec D4), so it
        // is a choice like any other; single or multi is the tree's
        // `multiple`, never the kind.
        case .singleChoice, .pictureChoice, .yesNo, .multiChoice:
            ChoiceList(
                block: block, look: look, rowText: text,
                onAnswer: onAnswer, onOptionTap: onOptionTap)
        case .shortText, .email, .phone:
            SingleLineField(block: block, kind: kind, look: look, rowText: text, onAnswer: onAnswer)
        case .longText:
            MultiLineField(block: block, look: look, rowText: text, onAnswer: onAnswer)
        case .numberInput:
            NumberField(block: block, look: look, rowText: text, onAnswer: onAnswer)
        case .dateInput:
            DateField(block: block, look: look, rowText: text, onAnswer: onAnswer)
        case .slider:
            SliderControl(block: block, look: look, rowText: text, onAnswer: onAnswer)
        case .rating:
            RatingControl(block: block, look: look, onAnswer: onAnswer)
        case .opinionScale:
            OpinionScaleControl(block: block, look: look, rowText: text, onAnswer: onAnswer)
        case .contactInfo:
            ContactFields(block: block, look: look, rowText: text, onAnswer: onAnswer)
        case .legal, .checkbox:
            ConsentControl(block: block, look: look, rowText: text, onAnswer: onAnswer)
        }
    }
}

// MARK: - Choice

/// Single- and multi-select, including picture choice and yes/no. Whether a
/// pick adds to a list or replaces the answer is the tree's `multiple` —
/// never the kind string, so a `picture_choice` with `multiple` collects a
/// list like a `multi_choice` (spec 2026-10-16-option-grid-layouts FM3).
struct ChoiceList: View {
    let block: QuestionBlock
    let look: RenderLook
    let rowText: FunnelRowText
    let onAnswer: (QuestionAnswer) -> Void
    let onOptionTap: (String) -> Void

    /// Seeded from the resolver, never defaulted here.
    @State private var chosen: Set<String>

    init(
        block: QuestionBlock, look: RenderLook, rowText: FunnelRowText,
        onAnswer: @escaping (QuestionAnswer) -> Void, onOptionTap: @escaping (String) -> Void
    ) {
        self.block = block
        self.look = look
        self.rowText = rowText
        self.onAnswer = onAnswer
        self.onOptionTap = onOptionTap
        _chosen = State(initialValue: Set(block.selected))
    }

    private var shape: FunnelIndicatorShape { block.multiple ? .checkbox : .radio }

    var body: some View {
        // The resolver decides the layout and, for a grid, the one tile
        // anatomy every tile draws (spec 2026-10-16-option-grid-layouts §3.3).
        if block.layout == FunnelOptionTiles.layoutGrid, let tile = block.tile {
            FunnelOptionTiles(
                options: block.options,
                columns: block.columns,
                tile: tile,
                dense: block.dense,
                look: look,
                rowText: rowText,
                shape: shape,
                isSelected: { chosen.contains($0.value) },
                onPick: select
            )
        } else if block.layout == FunnelOptionChips.layoutChips {
            FunnelOptionChips(
                options: block.options,
                look: look,
                rowText: rowText,
                shape: shape,
                isSelected: { chosen.contains($0.value) },
                onPick: select
            )
        } else {
            FunnelOptionRows(
                options: block.options,
                look: look,
                rowText: rowText,
                shape: shape,
                isSelected: { chosen.contains($0.value) },
                onPick: select
            )
        }
    }

    private func select(_ option: RenderOption) {
        if block.multiple {
            if chosen.contains(option.value) {
                chosen.remove(option.value)
            } else {
                chosen.insert(option.value)
            }
            onAnswer(.list(chosen.sorted()))
        } else {
            chosen = [option.value]
            onAnswer(.text(option.value))
        }
        // An option-level chain runs IN ADDITION to the answer, never
        // instead of it — the answer is what a later condition reads.
        // `enabled` gates the CHAIN alone: false means another required
        // question on this page is unanswered, so the pick still answers
        // and simply moves nobody.
        if option.enabled, let path = option.actionPath {
            onOptionTap(path)
        }
    }
}

/// The option rows a choice, picture choice and yes/no question all draw:
/// one row card per option (`FunnelRowCard`), label at the primary size in
/// `labelWeight`, description `muted` at the secondary size (spec D2), a
/// picture option's image rounded to `cardRadius`. A single choice's rows
/// are radios, a multi choice's checkboxes (spec D7); the indicator and
/// the accent border only show it.
struct FunnelOptionRows: View {
    let options: [RenderOption]
    let look: RenderLook
    let rowText: FunnelRowText
    let shape: FunnelIndicatorShape
    let isSelected: (RenderOption) -> Bool
    let onPick: (RenderOption) -> Void

    var body: some View {
        VStack(spacing: CGFloat(look.rowGap)) {
            ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                let selected = isSelected(option)
                Button {
                    FunnelHaptics.select()
                    onPick(option)
                } label: {
                    FunnelRowCard(look: look, selected: selected, shape: shape, icon: option.icon) {
                        VStack(alignment: .leading, spacing: 0) {
                            if let url = option.imageUrl.flatMap(URL.init(string:)) {
                                AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: {
                                    Color.clear
                                }
                                .cornerRadius(CGFloat(look.cardRadius))
                            }
                            Text(option.label)
                                .font(rowText.primaryFont(weight: look.labelWeight))
                                .funnelLineHeight(look, size: rowText.primary, family: rowText.family)
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .font(rowText.secondaryFont(weight: look.textWeight))
                                    .foregroundColor(look.mutedColor)
                                    .funnelLineHeight(
                                        look, size: rowText.secondary, family: rowText.family)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(FunnelRowPress(look: look))
                .modifier(
                    FunnelRowRole(
                        shape: shape, index: index, count: options.count, selected: selected))
            }
        }
    }
}

/// An option grid (spec 4.7, 2026-10-16-option-grid-layouts §3.3–3.4):
/// `columns` equal-width tiles per row, `tileGap` apart. Each row is an
/// `HStack` fixed to its ideal height — its tallest tile — and every tile
/// fills it, so a row's tiles are equally tall; a short last row keeps the
/// column width from the leading edge with empty cells. Each tile is a
/// `card` box at `tileRadius`, its outline drawn OVER the content
/// (`strokeBorder`) — `borderWidth` in `border`, selected
/// `selectedBorderWidth` in `accent` — so selecting never moves anything.
/// The tree's `tile` decides the anatomy, once for all:
///
///  - `image`: a square image (fill, clipped) on top — a tile with none
///    keeps the square in the hairline colour — the label under it,
///    `tileLabelGap` around, and the indicator over the image's
///    top-trailing corner;
///  - `icon`: the option's plate centred on top, the label `tileLabelGap`
///    under it, `tilePadding` around, at least `tileMinHeight` tall — top
///    aligned, so a row's plates and labels start level whatever wraps;
///  - `text`: no media slot at all; the label centred both ways,
///    `tilePadding` around, at least `tileMinHeight` tall.
///
/// An `icon` or `text` tile has no corner indicator: the accent outline
/// and the accessibility state say it is picked. Every label clamps to
/// `tileLabelLines`. A `dense` grid insets its tiles `tilePaddingDense` and
/// sets its labels at `tileLabelSizeDense`. Same roles, press and haptic as
/// the rows. The web's `OptionTiles`.
struct FunnelOptionTiles: View {
    static let layoutGrid = "grid"
    /// A grid tile's image is square.
    private static let tileAspect: CGFloat = 1

    let options: [RenderOption]
    let columns: Int
    let tile: RenderTileKind
    let dense: Bool
    let look: RenderLook
    let rowText: FunnelRowText
    let shape: FunnelIndicatorShape
    let isSelected: (RenderOption) -> Bool
    let onPick: (RenderOption) -> Void

    /// `columns` is always filled by the resolver; the floor only keeps a
    /// malformed zero from dividing.
    private var perRow: Int { max(1, columns) }

    var body: some View {
        let gap = CGFloat(look.tileGap)
        let indexed = Array(options.enumerated())
        let rows = stride(from: 0, to: indexed.count, by: perRow).map {
            Array(indexed[$0..<min($0 + perRow, indexed.count)])
        }
        VStack(spacing: gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(row, id: \.element.value) { index, option in
                        let selected = isSelected(option)
                        Button {
                            FunnelHaptics.select()
                            onPick(option)
                        } label: {
                            tileView(option, selected: selected)
                        }
                        .buttonStyle(FunnelRowPress(look: look))
                        .modifier(
                            FunnelRowRole(
                                shape: shape, index: index, count: options.count, selected: selected))
                    }
                    // A short last row keeps every column's width: the
                    // missing cells are empty, from the trailing edge.
                    ForEach(row.count..<perRow, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                }
                // The row takes its tallest tile's height; every tile fills
                // it (`maxHeight: .infinity`), so a row's tiles are equal.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The box an `icon` tile's media takes: the glyph plus its plate's
    /// padding on each side. Every option of a block shares one size and
    /// padding, so the first icon is the slot — and a tile whose option has
    /// none keeps an empty slot that size, or `tileIconSize` when no
    /// option has one.
    private var iconSlot: CGFloat {
        guard let icon = options.lazy.compactMap(\.icon).first else {
            return CGFloat(look.tileIconSize)
        }
        return CGFloat(icon.size + (icon.plate.map { $0.padding * QuestionFormat.sides } ?? 0))
    }

    private var labelSize: CGFloat { dense ? CGFloat(look.tileLabelSizeDense) : rowText.primary }
    private var tilePadding: CGFloat { CGFloat(dense ? look.tilePaddingDense : look.tilePadding) }

    private func label(_ option: RenderOption) -> some View {
        VStack(spacing: 0) {
            Text(option.label)
                .font(funnelFont(size: labelSize, weight: look.labelWeight, family: rowText.family))
                .lineLimit(look.tileLabelLines)
                .funnelLineHeight(look, size: labelSize, family: rowText.family)
            if let description = option.description, !description.isEmpty {
                Text(description)
                    .font(rowText.secondaryFont(weight: look.textWeight))
                    .foregroundColor(look.mutedColor)
                    .funnelLineHeight(look, size: rowText.secondary, family: rowText.family)
            }
        }
        // The copy keeps the height it asked for: the row was sized to it,
        // and a sub-point shortfall in the offered height would otherwise
        // truncate a two-line label to one.
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func media(_ option: RenderOption) -> some View {
        switch tile {
        case .image:
            look.borderColor
                .aspectRatio(Self.tileAspect, contentMode: .fit)
                .overlay {
                    if let url = option.imageUrl.flatMap(URL.init(string:)) {
                        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                            Color.clear
                        }
                    }
                }
                .clipped()
        case .icon:
            if let icon = option.icon {
                FunnelIconPlate(icon: icon)
            } else {
                // The tree's `-`: this option has no icon, but its tile
                // keeps the slot so every label in the row sits level.
                Color.clear.frame(width: iconSlot, height: iconSlot)
            }
        case .text:
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(_ option: RenderOption) -> some View {
        switch tile {
        case .image:
            VStack(spacing: 0) {
                media(option)
                label(option).padding(CGFloat(look.tileLabelGap))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .icon:
            VStack(spacing: CGFloat(look.tileLabelGap)) {
                media(option)
                label(option)
            }
            .padding(tilePadding)
            .frame(
                maxWidth: .infinity, minHeight: CGFloat(look.tileMinHeight), maxHeight: .infinity,
                alignment: .top)
        case .text:
            label(option)
                .padding(tilePadding)
                .frame(
                    maxWidth: .infinity, minHeight: CGFloat(look.tileMinHeight), maxHeight: .infinity,
                    alignment: .center)
        }
    }

    private func tileView(_ option: RenderOption, selected: Bool) -> some View {
        let r = RoundedRectangle(cornerRadius: CGFloat(look.tileRadius))
        return content(option)
            .background(look.cardColor)
            .clipShape(r)
            .overlay(alignment: .topTrailing) {
                if tile == .image {
                    FunnelSelectionIndicator(
                        look: look, selected: selected, shape: shape, restingFill: look.cardColor
                    )
                    .padding(CGFloat(look.tileLabelGap))
                }
            }
            .overlay(
                r.strokeBorder(
                    selected ? look.accentColor : look.borderColor,
                    lineWidth: CGFloat(selected ? look.selectedBorderWidth : look.borderWidth)))
            .contentShape(r)
    }
}

/// Wrapping chips (spec 2026-10-16-option-grid-layouts §3.4): each option at
/// its natural width, `chipGap` apart on both axes, wrapping from the
/// leading edge (`FunnelWrapLayout`). A chip is a `card` box, its content a
/// hairline plus `chipPaddingY` × `chipPaddingX` from its edge, its corner
/// `chipRadius` clamped to half its height (`FunnelClampedCorners`), so a
/// large theme radius draws a pill. Selected, its border is
/// `selectedBorderWidth` in `accent`, drawn over the padding band so the
/// label never moves — as a row. An option's icon leads its label
/// `indicatorGap` before it; a chip has no indicator. The web's
/// `OptionChips`.
struct FunnelOptionChips: View {
    static let layoutChips = "chips"

    let options: [RenderOption]
    let look: RenderLook
    let rowText: FunnelRowText
    let shape: FunnelIndicatorShape
    let isSelected: (RenderOption) -> Bool
    let onPick: (RenderOption) -> Void

    var body: some View {
        let gap = CGFloat(look.chipGap)
        Group {
            // The package's macOS floor (12) predates `Layout`; there the
            // chips stack from the leading edge, `chipGap` apart. Every iOS
            // the package supports wraps.
            if #available(macOS 13.0, *) {
                FunnelWrapLayout(spacing: gap) { chips }
            } else {
                VStack(alignment: .leading, spacing: gap) { chips }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chips: some View {
        ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
            let selected = isSelected(option)
            Button {
                FunnelHaptics.select()
                onPick(option)
            } label: {
                chip(option, selected: selected)
            }
            .buttonStyle(FunnelRowPress(look: look))
            .modifier(
                FunnelRowRole(shape: shape, index: index, count: options.count, selected: selected))
        }
    }

    private func chip(_ option: RenderOption, selected: Bool) -> some View {
        let corners = FunnelClampedCorners(radius: CGFloat(look.chipRadius))
        return HStack(spacing: CGFloat(look.indicatorGap)) {
            if let icon = option.icon {
                FunnelIconPlate(icon: icon)
            }
            Text(option.label)
                .font(rowText.primaryFont(weight: look.labelWeight))
                .funnelLineHeight(look, size: rowText.primary, family: rowText.family)
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, CGFloat(look.chipPaddingY + look.borderWidth))
        .padding(.horizontal, CGFloat(look.chipPaddingX + look.borderWidth))
        .background(corners.fill(look.cardColor))
        .overlay(
            corners.strokeBorder(
                selected ? look.accentColor : look.borderColor,
                lineWidth: CGFloat(selected ? look.selectedBorderWidth : look.borderWidth)))
        .contentShape(corners)
    }
}

/// A rounded rectangle whose corner is `radius` clamped to half its
/// height — how every drawer turns the theme's radius into a chip's corner,
/// so a large one draws a pill.
struct FunnelClampedCorners: InsettableShape {
    let radius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let corner = Swift.max(Swift.min(radius, rect.height / QuestionFormat.half) - inset, 0)
        return RoundedRectangle(cornerRadius: corner).path(in: box)
    }

    func inset(by amount: CGFloat) -> FunnelClampedCorners {
        FunnelClampedCorners(radius: radius, inset: inset + amount)
    }
}

/// Children at their natural width (never wider than the line), `spacing`
/// apart on both axes, wrapping onto a new line from the leading edge when
/// the next one does not fit.
@available(macOS 13.0, *)
struct FunnelWrapLayout: Layout {
    let spacing: CGFloat

    private struct Placed {
        let origin: CGPoint
        let size: CGSize
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (placed: [Placed], size: CGSize) {
        var placed: [Placed] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            placed.append(Placed(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = Swift.max(lineHeight, size.height)
            widest = Swift.max(widest, x - spacing)
        }
        return (placed, CGSize(width: widest, height: y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let size = arrange(width: width, subviews).size
        return CGSize(width: width.isFinite ? width : size.width, height: size.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let placed = arrange(width: bounds.width, subviews).placed
        for (subview, spot) in zip(subviews, placed) {
            subview.place(
                at: CGPoint(x: bounds.minX + spot.origin.x, y: bounds.minY + spot.origin.y),
                proposal: ProposedViewSize(spot.size))
        }
    }
}

/// A row's accessibility role: a radio's position, or a checkbox's state.
struct FunnelRowRole: ViewModifier {
    let shape: FunnelIndicatorShape
    let index: Int
    let count: Int
    let selected: Bool

    func body(content: Content) -> some View {
        switch shape {
        case .radio: content.funnelRadio(index: index, count: count, selected: selected)
        case .checkbox: content.funnelCheckbox(checked: selected)
        }
    }
}

// MARK: - Fields

struct SingleLineField: View {
    let block: QuestionBlock
    let kind: QuestionKind
    let look: RenderLook
    let rowText: FunnelRowText
    let onAnswer: (QuestionAnswer) -> Void

    @State private var value: String

    init(
        block: QuestionBlock, kind: QuestionKind, look: RenderLook, rowText: FunnelRowText,
        onAnswer: @escaping (QuestionAnswer) -> Void
    ) {
        self.block = block
        self.kind = kind
        self.look = look
        self.rowText = rowText
        self.onAnswer = onAnswer
        _value = State(initialValue: block.selected.first ?? "")
    }

    var body: some View {
        FunnelField(
            look: look, rowText: rowText, color: block.style.color,
            placeholder: block.placeholder ?? "", input: input, trailing: nil, text: $value
        )
        .onChange(of: value) { onAnswer(.text($0)) }
    }

    private var input: FunnelFieldInput {
        switch kind {
        case .email: return .email
        case .phone: return .phone
        default: return .sentence
        }
    }
}

struct MultiLineField: View {
    let block: QuestionBlock
    let look: RenderLook
    let rowText: FunnelRowText
    let onAnswer: (QuestionAnswer) -> Void

    @State private var value: String

    init(
        block: QuestionBlock, look: RenderLook, rowText: FunnelRowText,
        onAnswer: @escaping (QuestionAnswer) -> Void
    ) {
        self.block = block
        self.look = look
        self.rowText = rowText
        self.onAnswer = onAnswer
        _value = State(initialValue: block.selected.first ?? "")
    }

    var body: some View {
        FunnelTextArea(
            look: look, rowText: rowText, color: block.style.color,
            placeholder: block.placeholder ?? "", text: $value
        )
        .onChange(of: value) { onAnswer(.text($0)) }
    }
}

struct NumberField: View {
    let block: QuestionBlock
    let look: RenderLook
    let rowText: FunnelRowText
    let onAnswer: (QuestionAnswer) -> Void

    @State private var value: String

    init(
        block: QuestionBlock, look: RenderLook, rowText: FunnelRowText,
        onAnswer: @escaping (QuestionAnswer) -> Void
    ) {
        self.block = block
        self.look = look
        self.rowText = rowText
        self.onAnswer = onAnswer
        _value = State(initialValue: block.selected.first ?? "")
    }

    var body: some View {
        FunnelField(
            look: look, rowText: rowText, color: block.style.color,
            placeholder: block.placeholder ?? "", input: .decimal,
            trailing: block.suffix.map(FunnelFieldTrailing.suffix), text: $value
        )
        .onChange(of: value) { text in
            // A half-typed number is not an answer. Reporting NaN or 0
            // would route a `gt` rule on a value nobody entered.
            if let parsed = Double(text) { onAnswer(.number(parsed)) }
        }
    }
}

struct DateField: View {
    let block: QuestionBlock
    let look: RenderLook
    let rowText: FunnelRowText
    let onAnswer: (QuestionAnswer) -> Void

    /// The field's text is the picked date as the wheel writes it; the
    /// ANSWER is the date itself, reported through `onDate`.
    @State private var shown = ""

    var body: some View {
        FunnelField(
            look: look, rowText: rowText, color: block.style.color,
            placeholder: block.placeholder ?? "", input: .date, trailing: .calendar,
            text: $shown,
            date: block.selected.first.flatMap(isoDate),
            onDate: { onAnswer(.text(isoDateString($0))) })
    }
}

// MARK: - Scales

/// A `sliderTrackHeight` track in `border`, its filled part and a
/// `sliderThumbSize` thumb in `accent`; the value and suffix read out
/// above it, centred, from the first frame. Drawn, not a platform
/// `Slider` — whose thumb is white and whose track is its own — and
/// announced AS one, so VoiceOver still adjusts it.
struct SliderControl: View {
    let block: QuestionBlock
    let look: RenderLook
    let rowText: FunnelRowText
    let onAnswer: (QuestionAnswer) -> Void

    @State private var value: Double

    init(
        block: QuestionBlock, look: RenderLook, rowText: FunnelRowText,
        onAnswer: @escaping (QuestionAnswer) -> Void
    ) {
        self.block = block
        self.look = look
        self.rowText = rowText
        self.onAnswer = onAnswer
        let low = block.min ?? QuestionFormat.defaultSliderMin
        _value = State(initialValue: block.selected.first.flatMap(Double.init) ?? low)
    }

    private var range: ClosedRange<Double> {
        let low = block.min ?? QuestionFormat.defaultSliderMin
        let high = block.max ?? QuestionFormat.defaultSliderMax
        // A config with max below min would trap a range; clamp rather
        // than crash a shipped app on a draft nobody validated.
        return low <= high ? low...high : low...low
    }

    private var step: Double { block.step ?? QuestionFormat.defaultSliderStep }

    /// The value as the answer spells it (no `.0` on a whole number), then
    /// the suffix — the web's `${value} ${suffix}`.
    private var readout: String {
        let number = encodeAnswer(.number(value))
        return block.suffix.map { "\(number) \($0)" } ?? number
    }

    var body: some View {
        VStack(spacing: CGFloat(look.rowGap)) {
            Text(readout)
                .font(rowText.primaryFont(weight: look.emphasisWeight))
                .multilineTextAlignment(.center)
                .funnelLineHeight(look, size: rowText.primary, family: rowText.family)
                .frame(maxWidth: .infinity)
            track
        }
        .onChange(of: value) { onAnswer(.number($0)) }
    }

    private var track: some View {
        let thumb = CGFloat(look.sliderThumbSize)
        let trackHeight = CGFloat(look.sliderTrackHeight)
        return GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat(fractionOf(value))
            ZStack(alignment: .leading) {
                Capsule().fill(look.borderColor).frame(height: trackHeight)
                Capsule().fill(look.accentColor).frame(width: width * fraction, height: trackHeight)
                Circle().fill(look.accentColor)
                    .frame(width: thumb, height: thumb)
                    .offset(x: (width - thumb) * fraction)
            }
            .frame(width: width, height: thumb)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    // The thumb's CENTRE follows the finger, over the
                    // span its centre can travel.
                    let span = width - thumb
                    guard span > 0 else { return }
                    let at = (drag.location.x - thumb / QuestionFormat.half) / span
                    value = snapped(Double(Swift.min(Swift.max(at, 0), 1)))
                }
                // Letting go IS the answer — the web's `onPointerUp`: a
                // visitor who accepts the shown value without moving it
                // has answered too.
                .onEnded { _ in onAnswer(.number(value)) })
        }
        .frame(height: thumb)
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step)
        }
    }

    private func fractionOf(_ v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? (v - range.lowerBound) / span : 0
    }

    private func snapped(_ fraction: Double) -> Double {
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        guard step > 0 else { return raw }
        let steps = ((raw - range.lowerBound) / step).rounded()
        return Swift.min(Swift.max(range.lowerBound + steps * step, range.lowerBound), range.upperBound)
    }
}

/// The web's 24-unit star (`STAR_PATH` in `questions.tsx`), as points.
private struct FunnelStarShape: Shape {
    private static let viewBox: CGFloat = 24
    private static let points: [CGPoint] = [
        CGPoint(x: 12, y: 2.5), CGPoint(x: 14.94, y: 8.46), CGPoint(x: 21.52, y: 9.42),
        CGPoint(x: 16.76, y: 14.06), CGPoint(x: 17.88, y: 20.61), CGPoint(x: 12, y: 17.52),
        CGPoint(x: 6.12, y: 20.61), CGPoint(x: 7.24, y: 14.06), CGPoint(x: 2.48, y: 9.42),
        CGPoint(x: 9.06, y: 8.46),
    ]

    func path(in rect: CGRect) -> Path {
        let scale = Swift.min(rect.width, rect.height) / Self.viewBox
        var path = Path()
        path.addLines(Self.points.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) })
        path.closeSubpath()
        return path
    }
}

/// `starSize` stars `scaleGap` apart: filled in `accent`, empty outlined
/// in `border` at `borderWidth` (spec D1). Each is labelled by the screen
/// copy's `positionOf` (spec D7, localized-chrome D1).
struct RatingControl: View {
    let block: QuestionBlock
    let look: RenderLook
    let onAnswer: (QuestionAnswer) -> Void

    @State private var value: Int

    init(block: QuestionBlock, look: RenderLook, onAnswer: @escaping (QuestionAnswer) -> Void) {
        self.block = block
        self.look = look
        self.onAnswer = onAnswer
        _value = State(initialValue: block.selected.first.flatMap(Int.init) ?? 0)
    }

    var body: some View {
        HStack(spacing: CGFloat(look.scaleGap)) {
            ForEach(1...QuestionFormat.starCount, id: \.self) { star in
                let filled = star <= value
                Button {
                    value = star
                    onAnswer(.number(Double(star)))
                } label: {
                    ZStack {
                        FunnelStarShape().fill(filled ? look.accentColor : .clear)
                        FunnelStarShape().stroke(
                            filled ? look.accentColor : look.borderColor,
                            style: StrokeStyle(lineWidth: CGFloat(look.borderWidth), lineJoin: .round))
                    }
                    .frame(width: CGFloat(look.starSize), height: CGFloat(look.starSize))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .funnelPositionLabel(star, of: QuestionFormat.starCount)
                .accessibilityAddTraits(filled ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Equal-width cells, `scaleCellMinHeight` tall and `scaleGap` apart, each
/// a card (`card` fill, `border` hairline, `cardRadius`); the selected cell
/// is an `accent` fill with its number in `onAccent`, `emphasisWeight`.
/// The cells are radios (spec D7).
struct OpinionScaleControl: View {
    let block: QuestionBlock
    let look: RenderLook
    let rowText: FunnelRowText
    let onAnswer: (QuestionAnswer) -> Void

    @State private var value: Int?

    init(
        block: QuestionBlock, look: RenderLook, rowText: FunnelRowText,
        onAnswer: @escaping (QuestionAnswer) -> Void
    ) {
        self.block = block
        self.look = look
        self.rowText = rowText
        self.onAnswer = onAnswer
        _value = State(initialValue: block.selected.first.flatMap(Int.init))
    }

    private var low: Int { block.min.map(Int.init) ?? QuestionFormat.opinionScaleLow }
    private var high: Int { Swift.max(block.max.map(Int.init) ?? QuestionFormat.opinionScaleHigh, low) }

    var body: some View {
        let values = Array(low...high)
        let shape = RoundedRectangle(cornerRadius: CGFloat(look.cardRadius))
        HStack(spacing: CGFloat(look.scaleGap)) {
            ForEach(Array(values.enumerated()), id: \.element) { index, n in
                let selected = value == n
                Button {
                    value = n
                    onAnswer(.number(Double(n)))
                } label: {
                    Text("\(n)")
                        .font(rowText.primaryFont(weight: look.emphasisWeight))
                        .lineLimit(1)
                        .ifLet(selected ? look.onAccentColor : nil) { $0.foregroundColor($1) }
                        .frame(maxWidth: .infinity, minHeight: CGFloat(look.scaleCellMinHeight))
                        .background(shape.fill(selected ? look.accentColor : look.cardColor))
                        .overlay(
                            shape.strokeBorder(
                                selected ? look.accentColor : look.borderColor,
                                lineWidth: CGFloat(look.borderWidth)))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .funnelRadio(index: index, count: values.count, selected: selected)
            }
        }
    }
}

// MARK: - Composite

struct ContactFields: View {
    let block: QuestionBlock
    let look: RenderLook
    let rowText: FunnelRowText
    let onAnswer: (QuestionAnswer) -> Void

    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(spacing: CGFloat(look.rowGap)) {
            // `contactFields` is already resolved, in render order, each
            // with its placeholder (the author's, else the localized
            // table's). Do NOT re-derive either — collectName/collectEmail/
            // collectPhone are not even on this type.
            ForEach(block.contactFields, id: \.key) { field in
                FunnelField(
                    look: look, rowText: rowText, color: block.style.color,
                    placeholder: field.placeholder, input: input(for: field.key), trailing: nil,
                    text: Binding(
                        get: { values[field.key] ?? "" },
                        set: {
                            values[field.key] = $0
                            onAnswer(.contact(values))
                        }
                    ))
            }
        }
    }

    private func input(for field: String) -> FunnelFieldInput {
        switch field {
        case QuestionFormat.contactEmail: return .email
        case QuestionFormat.contactPhone: return .phone
        default: return .name
        }
    }
}

/// The legal / checkbox row: the multi-choice indicator (a rounded square,
/// `indicatorCornerRadius`, `accent`) and the label `indicatorGap` after
/// it; a terms link is `accent`, underlined. A checkbox, not a `Toggle`
/// (spec D1): tapping the indicator ticks it, tapping a link opens it.
struct ConsentControl: View {
    let block: QuestionBlock
    let look: RenderLook
    let rowText: FunnelRowText
    let onAnswer: (QuestionAnswer) -> Void

    // RovenueFunnelView installs this action: it reaches the host's
    // `onUrl` first, never the system directly.
    @Environment(\.openURL) private var openURL
    @State private var accepted: Bool

    init(
        block: QuestionBlock, look: RenderLook, rowText: FunnelRowText,
        onAnswer: @escaping (QuestionAnswer) -> Void
    ) {
        self.block = block
        self.look = look
        self.rowText = rowText
        self.onAnswer = onAnswer
        _accepted = State(initialValue: block.selected.first == QuestionFormat.trueValue)
    }

    var body: some View {
        let label = block.agreementLabel ?? ""
        // A null termsUrl means the label is not a link.
        let terms = block.termsUrl.flatMap(URL.init(string:))
        HStack(spacing: CGFloat(look.indicatorGap)) {
            Button(action: toggle) {
                FunnelSelectionIndicator(look: look, selected: accepted, shape: .checkbox)
            }
            .buttonStyle(.plain)
            if let terms {
                Button { openURL(terms) } label: {
                    Text(label).underline().foregroundColor(look.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: toggle) { Text(label) }.buttonStyle(.plain)
            }
        }
        .font(rowText.primaryFont(weight: look.textWeight))
        .multilineTextAlignment(.leading)
        .funnelLineHeight(look, size: rowText.primary, family: rowText.family)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One checkbox to VoiceOver: its label is the agreement, its value
        // the state; the terms link stays reachable as a named action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .funnelCheckbox(checked: accepted)
        .accessibilityAction { toggle() }
        .ifLet(terms) { view, url in
            view.accessibilityAction(named: Text(label)) { openURL(url) }
        }
    }

    private func toggle() {
        accepted.toggle()
        onAnswer(.bool(accepted))
    }
}
