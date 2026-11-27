//  Commerce.swift — the package list and the purchase button.
//
//  Packages arrive PRICED. `localizedPrice` was formatted by the caller,
//  in the store's own currency — never reformat it here, and never compute
//  a discount or a per-month figure from it. Currency formatting is the
//  platform's job only when the platform is the one that has the number,
//  and here it is not.

import SwiftUI

private enum CommerceFormat {
    /// A purchase button always draws full chrome — only an authored
    /// `button` can be chrome-less.
    static let purchaseChromeless = false
    static let layoutHorizontal = "horizontal"
    /// The two SHOP layouts (spec 2026-10-11-genre-funnel-templates §10.10).
    static let layoutTiles = "tiles"
    static let layoutShop = "shop"
    /// A tile's inner gap is half the card gap — the web's `cardGap / 2`.
    static let halfGap: CGFloat = 2
    /// A corner badge's authored corners (`badgePosition`).
    static let badgeTopStart = "topStart"
    static let badgeTopCenter = "topCenter"
    static let badgeTopEnd = "topEnd"
    /// `priceSuffixPlacement` stacking the suffix under the price.
    static let suffixBelow = "below"
}

/// Each package is the same row card a choice option is (`FunnelRowCard`):
/// title `textSize`/`emphasisWeight` on the left with the period `muted`
/// under it, the price `textSize`/`emphasisWeight` on the right, and the
/// selected package wearing the selected indicator and border.
struct FunnelPackageListView: View {
    /// The text size (FunnelTextScale): read so this view redraws when it changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts
    /// The screen's haptics — silent when the funnel switched them off.
    @Environment(\.funnelHaptics) private var haptics
    /// A purchase or restore in flight: the whole list dims and is disabled.
    @Environment(\.funnelStoreBusy) private var storeBusy
    let block: PackageListBlock
    let look: RenderLook
    let onSelect: (String) -> Void

    init(block: PackageListBlock, look: RenderLook, onSelect: @escaping (String) -> Void) {
        self.block = block
        // The selection colour is the block's `highlight` (the accent when
        // the author set none): every selected border and indicator below
        // reads it through the look.
        var look = look
        look.accent = block.highlight
        // Spec F §8 H1: an authored row padding / row gap stands in for the
        // look's package row metrics, so every row and the shop read them
        // through the same look (the web's `rowMetrics`).
        if let padding = block.rowPadding {
            look.rowPaddingX = padding.x
            look.rowPaddingY = padding.y
        }
        if let gap = block.rowGap { look.rowGap = gap }
        self.look = look
        self.onSelect = onSelect
    }

    private var shop: Bool {
        block.layout == CommerceFormat.layoutTiles || block.layout == CommerceFormat.layoutShop
    }

    private var horizontal: Bool { block.layout == CommerceFormat.layoutHorizontal }
    private var anyBadge: Bool { block.packages.contains { $0.hasCornerBadge } }

    var body: some View {
        Group {
            if shop {
                FunnelPackShopView(block: block, look: look, onSelect: onSelect)
            } else {
                plain
            }
        }
        .funnelStoreDimmed(storeBusy)
    }

    private var plain: some View {
        Group {
            if horizontal {
                // The rows share one top edge, so the list reserves the
                // badge overlap once.
                HStack(spacing: CGFloat(look.rowGap)) { rows }
                    .padding(.top, anyBadge ? CGFloat(look.badgeOffsetY) : 0)
            } else {
                VStack(spacing: CGFloat(look.rowGap)) { rows }
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }

    @ViewBuilder
    private var rows: some View {
        // Spec D2: the block's authored size is the title and price, the
        // period keeps the look's muted ratio to it; the family reaches all.
        let text = FunnelRowText(
            look: look, style: block.style, scale: FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts),
            packageSecondary: block.secondaryTextSize, packageCaption: block.captionTextSize)
        let paint = FunnelPackagePaint(block)
        ForEach(Array(block.packages.enumerated()), id: \.element.identifier) { index, package in
            let selected = isSelected(package)
            Button {
                haptics.select()
                onSelect(package.identifier)
            } label: {
                if horizontal {
                    // Side by side, a package is a PLAN TILE: title, price,
                    // period and caption stacked, no radio and no trailing
                    // price column (spec 2026-10-11 §8 F1, as the web and
                    // Android draw it).
                    FunnelRowCard(look: look, selected: selected, shape: .radio, indicator: false, paint: block.card) {
                        VStack(alignment: .leading, spacing: 0) {
                            FunnelInlineBadgeRow(
                                badge: package.inlineBadge, look: look, fontSize: text.badge, font: paint.secondary
                            ) {
                                if let title = package.localizedTitle, !title.isEmpty {
                                    titleLine(title, size: text.secondary, text, paint, selected)
                                }
                            }
                            if package.drawsPriceColumn {
                                // A suffix stacked `below` puts the price stack at
                                // the tile's trailing edge, as the web's flex-end
                                // column and Android do; an inline one stays leading.
                                FunnelPackagePriceView(
                                    package: package, text: text, weight: look.emphasisWeight, look: look,
                                    paint: paint, selected: selected)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: paint.suffixBelow && package.priceSuffix?.isEmpty == false
                                            ? .trailing : .leading)
                            }
                            secondaryLines(package, text, paint, selected)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .overlay(alignment: .top) { cornerBadges(package, paint) }
                } else {
                FunnelRowCard(
                    look: look, selected: selected, shape: .radio, indicatorDot: block.indicatorDotColor, paint: block.card
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        FunnelInlineBadgeRow(
                            badge: package.inlineBadge, look: look, fontSize: text.badge, font: paint.secondary
                        ) {
                            if let title = package.localizedTitle, !title.isEmpty {
                                titleLine(title, size: text.primary, text, paint, selected)
                            }
                        }
                        secondaryLines(package, text, paint, selected)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // An empty price is a package the store did not price —
                    // the row still draws its title rather than an empty
                    // column — unless its price is still loading or failed
                    // to load: then the column holds a skeleton or the
                    // muted "Price unavailable".
                    if package.drawsPriceColumn {
                        FunnelPackagePriceView(
                            package: package, text: text, weight: look.emphasisWeight, look: look,
                            paint: paint, selected: selected)
                    }
                }
                // Inside the button's label, so VoiceOver reads the badge
                // as part of the row.
                .overlay(alignment: .top) { cornerBadges(package, paint) }
                // A vertical list reserves the overlap per badged row.
                .padding(.top, package.hasCornerBadge ? CGFloat(look.badgeOffsetY) : 0)
                }
            }
            .buttonStyle(FunnelRowPress(look: look))
            // A package row is a radio (spec D7).
            .funnelRadio(index: index, count: block.packages.count, selected: selected)
        }
    }

    private func isSelected(_ package: RenderPackage) -> Bool {
        package.identifier == block.selectedIdentifier
    }

    /// The row name in the primary face and its authored colour.
    private func titleLine(
        _ title: String, size: CGFloat, _ text: FunnelRowText, _ paint: FunnelPackagePaint, _ selected: Bool
    ) -> some View {
        let family = paint.primaryFamily(text.family)
        return Text(title)
            .funnelTextFont(size: size, weight: paint.primaryWeight(look.emphasisWeight), family: family, scale: text.scale)
            .ifLet(paint.titleColor(selected)) { $0.foregroundColor($1) }
            .funnelLineHeight(look, size: size, family: family)
    }

    /// The muted period line and caption under the name, in the secondary
    /// face; the caption in its authored colour.
    @ViewBuilder
    private func secondaryLines(
        _ package: RenderPackage, _ text: FunnelRowText, _ paint: FunnelPackagePaint, _ selected: Bool
    ) -> some View {
        let family = paint.secondaryFamily(text.family)
        let weight = paint.secondaryWeight(look.textWeight)
        if let period = package.periodShown, !period.isEmpty {
            Text(period)
                .funnelTextFont(size: text.period, weight: weight, family: family, scale: text.scale)
                .foregroundColor(look.mutedColor)
                .funnelLineHeight(look, size: text.period, family: family)
        }
        if package.periodPending == true {
            pendingLine(size: text.period, weight: weight, family: family, text)
        }
        if let caption = package.caption, !caption.isEmpty {
            Text(caption)
                .funnelTextFont(size: text.caption, weight: weight, family: family, scale: text.scale)
                .foregroundColor(paint.captionColor(selected) ?? look.mutedColor)
                .funnelLineHeight(look, size: text.caption, family: family)
        } else if package.captionPending == true {
            pendingLine(size: text.caption, weight: weight, family: family, text)
        }
    }

    /// A caption / period line hidden only until the store price it names
    /// arrives: a skeleton in the line's slot.
    private func pendingLine(size: CGFloat, weight: Int, family: String?, _ text: FunnelRowText) -> some View {
        FunnelSkeletonSlot(
            look: look, font: funnelFont(size: size, weight: weight, family: family, scale: text.scale),
            size: size, family: family, scale: text.scale, chars: SkeletonFormat.lineChars)
    }

    /// The row's corner pills, each `badgeOffsetY` above the row's outer
    /// edge at its corner: an authored `badgePosition` (start / end inset
    /// to the row's content edge), else the layout's own — trailing in a
    /// list, centred on a plan tile.
    @ViewBuilder
    private func cornerBadges(_ package: RenderPackage, _ paint: FunnelPackagePaint) -> some View {
        let inset = CGFloat(look.rowPaddingX + (block.card?.borderWidth ?? look.borderWidth))
        let fallback = horizontal ? CommerceFormat.badgeTopCenter : CommerceFormat.badgeTopEnd
        ZStack(alignment: .top) {
            if let badge = package.badge {
                cornerBadge(badge, package.badgePosition ?? fallback, inset: inset, paint)
            }
            if let second = package.secondBadge {
                cornerBadge(second, package.secondBadgePosition ?? fallback, inset: inset, paint)
            }
        }
    }

    private func cornerBadge(
        _ badge: RenderBadge, _ position: String, inset: CGFloat, _ paint: FunnelPackagePaint
    ) -> some View {
        let alignment: Alignment =
            switch position {
            case CommerceFormat.badgeTopStart: .topLeading
            case CommerceFormat.badgeTopEnd: .topTrailing
            default: .top
            }
        return FunnelPackageBadge(badge: badge, look: look, font: paint.secondary)
            .offset(y: -CGFloat(look.badgeOffsetY))
            .padding(.leading, position == CommerceFormat.badgeTopStart ? inset : 0)
            .padding(.trailing, position == CommerceFormat.badgeTopEnd ? inset : 0)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// A package list's authored paint and faces (paywall gaps); every nil
/// draws today's.
struct FunnelPackagePaint {
    let card: RenderPackageCard?
    let priceSize: CGFloat?
    let suffixBelow: Bool
    let primary: RenderFont?
    let secondary: RenderFont?

    init(_ block: PackageListBlock) {
        card = block.card
        priceSize = block.priceTextSize.map(CGFloat.init)
        suffixBelow = block.priceSuffixPlacement == CommerceFormat.suffixBelow
        primary = block.primaryFont
        secondary = block.secondaryFont
    }

    func primaryFamily(_ base: String?) -> String? { primary?.family ?? base }
    func primaryWeight(_ base: Int) -> Int { primary?.weight ?? base }
    func secondaryFamily(_ base: String?) -> String? { secondary?.family ?? base }
    func secondaryWeight(_ base: Int) -> Int { secondary?.weight ?? base }
    func titleColor(_ selected: Bool) -> Color? {
        funnelColor(selected ? card?.selectedTitleColor : card?.titleColor)
    }
    func priceColor(_ selected: Bool) -> Color? {
        funnelColor(selected ? card?.selectedPriceColor : card?.priceColor)
    }
    func captionColor(_ selected: Bool) -> Color? {
        funnelColor(selected ? card?.selectedCaptionColor : card?.captionColor)
    }
}

/// The price (`priceText` else the store price) in the primary face at
/// the authored price size and colour, then its muted `priceSuffix` in the
/// secondary face — inline after it, or stacked under it, trailing-aligned,
/// when placed `below`. `PackagePrice` on the web.
struct FunnelPackagePriceView: View {
    let package: RenderPackage
    let text: FunnelRowText
    let weight: Int
    let look: RenderLook
    let paint: FunnelPackagePaint
    let selected: Bool

    var body: some View {
        let size = paint.priceSize ?? text.primary
        let family = paint.primaryFamily(text.family)
        let priceWeight = paint.primaryWeight(weight)
        let priceFont = funnelFont(size: size, weight: priceWeight, family: family, scale: text.scale)
        var price = Text(package.priceShown).font(priceFont)
        if let color = paint.priceColor(selected) { price = price.foregroundColor(color) }
        let suffixFamily = paint.secondaryFamily(text.family)
        let suffixWeight = paint.secondaryWeight(look.textWeight)
        let suffixFont = funnelFont(size: text.period, weight: suffixWeight, family: suffixFamily, scale: text.scale)
        let suffixText = package.priceSuffix.flatMap { $0.isEmpty ? nil : $0 }
        let suffix = suffixText.map { Text($0).font(suffixFont).foregroundColor(look.mutedColor) }
        // Synthesised bold (review R5), per part.
        let priceStroke = funnelFakeBoldStroke(size: size, weight: priceWeight, family: family, scale: text.scale)
        let suffixStroke = funnelFakeBoldStroke(
            size: text.period, weight: suffixWeight, family: suffixFamily, scale: text.scale)
        return Group {
            if package.pricePending {
                // Spec 2026-11-22-funnel-price-loading-state: a skeleton
                // where the price goes, its suffix (when authored) beside or
                // under it as it will be.
                let bar = FunnelSkeletonSlot(
                    look: look, font: priceFont, size: size, family: family, scale: text.scale,
                    chars: SkeletonFormat.priceChars)
                if let suffix, paint.suffixBelow {
                    VStack(alignment: .trailing, spacing: 0) {
                        bar
                        suffix.funnelLineHeight(look, size: text.period, family: suffixFamily)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        bar
                        suffix?.funnelLineHeight(look, size: size, family: family)
                    }
                }
            } else if let unavailable = package.priceUnavailableShown {
                // The lookup failed: the note, muted and at the suffix's
                // size, in the price's place (core drops the suffix).
                Text(unavailable)
                    .font(suffixFont)
                    .foregroundColor(look.mutedColor)
                    .multilineTextAlignment(.trailing)
                    .funnelLineHeight(look, size: text.period, family: suffixFamily)
            } else if let suffix, paint.suffixBelow {
                VStack(alignment: .trailing, spacing: 0) {
                    price.modifier(FunnelFakeBold(stroke: priceStroke))
                        .funnelLineHeight(look, size: size, family: family)
                    suffix.modifier(FunnelFakeBold(stroke: suffixStroke))
                        .funnelLineHeight(look, size: text.period, family: suffixFamily)
                }
            } else {
                // One run of text: the overlay is the same run with the
                // parts that need no emboldening drawn clear.
                let overlay: (Text, CGFloat)? = (priceStroke ?? suffixStroke).map { stroke in
                    let pricePart = priceStroke == nil
                        ? Text(package.priceShown).font(priceFont).foregroundColor(.clear) : price
                    let suffixPart = suffixText.map { value in
                        suffixStroke == nil ? Text(value).font(suffixFont).foregroundColor(.clear) : suffix!
                    }
                    return (suffixPart.map { pricePart + $0 } ?? pricePart, stroke)
                }
                (suffix.map { price + $0 } ?? price)
                    .modifier(FunnelFakeBoldOverlay(overlay: overlay))
                    .funnelLineHeight(look, size: size, family: family)
            }
        }
    }
}

/// A credit page's shop (`tiles` / `shop`, as the web's `FlowPackShop`
/// draws it): each pack a card led by its icon, its title (the quantity)
/// the hero at `packTitleSize`, the price bold, no radio; the selected pack
/// wears `highlight` as its border and `highlightFill` as its fill. A
/// tile's badge is a ribbon across its top (`packRibbonHeight`, reserved by
/// every tile); a shop row's is an inline pill after the title.
struct FunnelPackShopView: View {
    /// The text size (FunnelTextScale): read so this view redraws when it changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts
    /// The screen's haptics — silent when the funnel switched them off.
    @Environment(\.funnelHaptics) private var haptics
    let block: PackageListBlock
    let look: RenderLook
    let onSelect: (String) -> Void

    private var tiles: Bool { block.layout == CommerceFormat.layoutTiles }

    var body: some View {
        Group {
            if tiles {
                HStack(alignment: .top, spacing: CGFloat(look.rowGap)) { packs }
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: CGFloat(look.rowGap)) { packs }
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }

    @ViewBuilder
    private var packs: some View {
        let text = FunnelRowText(
            look: look, style: block.style, scale: FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts),
            packageSecondary: block.secondaryTextSize, packageCaption: block.captionTextSize)
        let paint = FunnelPackagePaint(block)
        ForEach(Array(block.packages.enumerated()), id: \.element.identifier) { index, package in
            let selected = package.identifier == block.selectedIdentifier
            let card = block.card
            let shape = RoundedRectangle(cornerRadius: CGFloat(card?.radius ?? look.cardRadius))
            let fill = card.map { selected ? $0.selectedFill : $0.fill } ?? (selected ? block.highlightFill : look.card)
            let stroke = card.map { selected ? $0.selectedBorder : $0.border } ?? (selected ? block.highlight : look.border)
            let width =
                card.map { selected ? $0.selectedBorderWidth : $0.borderWidth }
                ?? (selected ? look.selectedBorderWidth : look.borderWidth)
            Button {
                haptics.select()
                onSelect(package.identifier)
            } label: {
                Group {
                    if tiles {
                        tile(package, text, paint, selected)
                    } else {
                        row(package, text, paint, selected)
                    }
                }
                .background(shape.fill(lookColor(fill)))
                .overlay(alignment: .top) {
                    // A second corner badge shares the ribbon, side by side.
                    if tiles, package.hasCornerBadge {
                        HStack(spacing: 0) {
                            if let badge = package.badge { ribbon(badge, paint) }
                            if let second = package.secondBadge { ribbon(second, paint) }
                        }
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(lookColor(stroke), lineWidth: CGFloat(width)))
                .contentShape(shape)
            }
            .buttonStyle(FunnelRowPress(look: look))
            .funnelRadio(index: index, count: block.packages.count, selected: selected)
        }
    }

    /// A tile ribbon's segment: the corner badge across the tile's top.
    private func ribbon(_ badge: RenderBadge, _ paint: FunnelPackagePaint) -> some View {
        Text(badge.text)
            .funnelTextFont(
                size: CGFloat(look.badgeFontSize), weight: paint.secondary?.weight ?? look.badgeWeight,
                family: paint.secondary?.family, scale: FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts))
            .foregroundColor(lookColor(badge.color))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(look.packRibbonHeight))
            .background(lookColor(badge.background))
    }

    private func title(
        _ package: RenderPackage, _ text: FunnelRowText, _ paint: FunnelPackagePaint, _ selected: Bool
    ) -> some View {
        let family = paint.primaryFamily(text.family)
        return Text(package.localizedTitle ?? "")
            .funnelTextFont(
                size: CGFloat(look.packTitleSize), weight: paint.primaryWeight(look.headingWeight), family: family,
                scale: text.scale)
            .ifLet(paint.titleColor(selected)) { $0.foregroundColor($1) }
            .funnelLineHeight(look, size: look.packTitleSize, family: family)
    }

    /// A pack's caption (spec F §8 H2 size).
    private func captionLine(
        _ value: String, _ text: FunnelRowText, _ paint: FunnelPackagePaint, _ selected: Bool
    ) -> some View {
        let family = paint.secondaryFamily(text.family)
        return Text(value)
            .funnelTextFont(
                size: text.caption, weight: paint.secondaryWeight(look.textWeight), family: family, scale: text.scale)
            .foregroundColor(paint.captionColor(selected) ?? look.mutedColor)
            .funnelLineHeight(look, size: text.caption, family: family)
    }

    /// The period line (spec F §7 G3 size).
    private func periodLine(_ value: String, _ text: FunnelRowText, _ paint: FunnelPackagePaint) -> some View {
        let family = paint.secondaryFamily(text.family)
        return Text(value)
            .funnelTextFont(
                size: text.period, weight: paint.secondaryWeight(look.textWeight), family: family, scale: text.scale)
            .foregroundColor(look.mutedColor)
            .funnelLineHeight(look, size: text.period, family: family)
    }

    /// A pack's caption / period line still waiting on its store price: a
    /// skeleton in the line's slot.
    private func pendingLine(size: CGFloat, _ text: FunnelRowText, _ paint: FunnelPackagePaint) -> some View {
        let family = paint.secondaryFamily(text.family)
        return FunnelSkeletonSlot(
            look: look,
            font: funnelFont(
                size: size, weight: paint.secondaryWeight(look.textWeight), family: family, scale: text.scale),
            size: size, family: family, scale: text.scale, chars: SkeletonFormat.lineChars)
    }

    private func price(
        _ package: RenderPackage, _ text: FunnelRowText, _ paint: FunnelPackagePaint, _ selected: Bool
    ) -> some View {
        FunnelPackagePriceView(
            package: package, text: text, weight: look.headingWeight, look: look, paint: paint, selected: selected)
    }

    private func tile(
        _ package: RenderPackage, _ text: FunnelRowText, _ paint: FunnelPackagePaint, _ selected: Bool
    ) -> some View {
        VStack(spacing: CGFloat(look.cardGap) / CommerceFormat.halfGap) {
            if let icon = package.icon { FunnelIconPlate(icon: icon) }
            FunnelInlineBadgeRow(badge: package.inlineBadge, look: look, fontSize: text.badge, font: paint.secondary) {
                if let t = package.localizedTitle, !t.isEmpty {
                    title(package, text, paint, selected).multilineTextAlignment(.center)
                }
            }
            if let caption = package.caption, !caption.isEmpty {
                captionLine(caption, text, paint, selected).multilineTextAlignment(.center)
            } else if package.captionPending == true {
                pendingLine(size: text.caption, text, paint)
            }
            Spacer(minLength: 0)
            if package.drawsPriceColumn {
                price(package, text, paint, selected).padding(.top, CGFloat(look.cardGap) / CommerceFormat.halfGap)
            }
            if let period = package.periodShown, !period.isEmpty {
                periodLine(period, text, paint)
            } else if package.periodPending == true {
                pendingLine(size: text.period, text, paint)
            }
        }
        .padding(.top, CGFloat(look.packRibbonHeight + look.cardGap))
        .padding(.bottom, CGFloat(look.rowPaddingY))
        .padding(.horizontal, CGFloat(look.cardGap))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(
        _ package: RenderPackage, _ text: FunnelRowText, _ paint: FunnelPackagePaint, _ selected: Bool
    ) -> some View {
        HStack(spacing: CGFloat(look.indicatorGap)) {
            if let icon = package.icon { FunnelIconPlate(icon: icon) }
            VStack(alignment: .leading, spacing: 0) {
                // A shop row's corner badges are inline pills after the
                // title, the second beside the first.
                HStack(spacing: CGFloat(look.badgePaddingX)) {
                    if let t = package.localizedTitle, !t.isEmpty { title(package, text, paint, selected) }
                    if let badge = package.badge { FunnelPackageBadge(badge: badge, look: look, font: paint.secondary) }
                    if let second = package.secondBadge {
                        FunnelPackageBadge(badge: second, look: look, font: paint.secondary)
                    }
                    if let inline = package.inlineBadge {
                        FunnelPackageBadge(badge: inline, look: look, fontSize: text.badge, font: paint.secondary)
                    }
                }
                if let caption = package.caption, !caption.isEmpty {
                    captionLine(caption, text, paint, selected)
                } else if package.captionPending == true {
                    pendingLine(size: text.caption, text, paint)
                }
                if let period = package.periodShown, !period.isEmpty {
                    periodLine(period, text, paint)
                } else if package.periodPending == true {
                    pendingLine(size: text.period, text, paint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if package.drawsPriceColumn { price(package, text, paint, selected) }
        }
        .padding(.vertical, CGFloat(look.rowPaddingY))
        .padding(.horizontal, CGFloat(look.rowPaddingX))
    }
}

extension RenderPackage {
    /// The trailing price text (spec F §6 F5b): the author's `priceText`
    /// when set, else the store price.
    var priceShown: String { priceText ?? localizedPrice }

    /// Whether a price column draws at all — an empty one is a package
    /// the store did not price.
    var hasPrice: Bool { !priceShown.isEmpty }

    /// The store lookup for this row's price still runs: a skeleton goes
    /// where the price goes (spec 2026-11-22-funnel-price-loading-state).
    var pricePending: Bool { priceState == RenderPackage.pricePending }

    /// The lookup failed: core's "Price unavailable" goes in the price's
    /// place; nil otherwise.
    var priceUnavailableShown: String? {
        guard priceState == RenderPackage.priceFailed, let note = priceUnavailable, !note.isEmpty else { return nil }
        return note
    }

    /// Whether the price column draws: a price, or its loading / failed
    /// stand-in.
    var drawsPriceColumn: Bool { hasPrice || pricePending || priceUnavailableShown != nil }

    /// The muted line under the title (spec F §7 G2): the author's
    /// `periodText` when the crate sends one — "" draws no line — else the
    /// store period.
    var periodShown: String? { periodText ?? localizedPeriod }

    /// Whether the row draws a corner pill (either one) — and so reserves
    /// the badge overlap above it.
    var hasCornerBadge: Bool { badge != nil || secondBadge != nil }
}

/// A package title with its inline badge after it (spec F §6 F5c), the
/// badge's own metrics, `badgePaddingX` apart; the title alone, unwrapped,
/// when the row has none.
struct FunnelInlineBadgeRow<Title: View>: View {
    let badge: RenderBadge?
    let look: RenderLook
    /// Spec F §7 G3: the list's authored secondary size; nil is the badge's.
    var fontSize: CGFloat? = nil
    /// The list's authored secondary face; nil is the badge's.
    var font: RenderFont? = nil
    @ViewBuilder let title: () -> Title

    var body: some View {
        if let badge {
            HStack(spacing: CGFloat(look.badgePaddingX)) {
                title()
                FunnelPackageBadge(badge: badge, look: look, fontSize: fontSize, font: font)
            }
        } else {
            title()
        }
    }
}

/// A package row's pill: `badgeFontSize` in `badgeWeight`, padded
/// `badgePaddingY` × `badgePaddingX`, `badgeRadius` (999 is a pill —
/// SwiftUI clamps a corner to half the height), in the resolver's colours.
struct FunnelPackageBadge: View {
    /// The text size (FunnelTextScale): read so this view redraws when it changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts
    let badge: RenderBadge
    let look: RenderLook
    /// Spec F §7 G3: an inline badge's authored text size; nil is
    /// `badgeFontSize` (every corner badge).
    var fontSize: CGFloat? = nil
    /// The list's authored secondary face (family / weight); nil is the
    /// system face in `badgeWeight`.
    var font: RenderFont? = nil

    var body: some View {
        let size = fontSize ?? CGFloat(look.badgeFontSize)
        Text(badge.text)
            .funnelTextFont(
                size: size, weight: font?.weight ?? look.badgeWeight, family: font?.family,
                scale: FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts))
            .foregroundColor(lookColor(badge.color))
            .lineLimit(1)
            .fixedSize()
            .funnelLineHeight(look, size: size, family: font?.family)
            .padding(.horizontal, CGFloat(look.badgePaddingX))
            .padding(.vertical, CGFloat(look.badgePaddingY))
            .background(RoundedRectangle(cornerRadius: CGFloat(look.badgeRadius)).fill(lookColor(badge.background)))
    }
}

/// Buys whatever is selected — in the same ONE shape every button draws
/// (`FunnelButtonChrome`), the resolver's fill and radius on it. No
/// `.borderedProminent`: layering the platform's capsule under the
/// resolver's fill drew two shapes (D8).
///
/// `enabled` is false while nothing is — a rule the resolver computed, not
/// one to re-derive from the package list, which this view cannot even see.
struct FunnelPurchaseButtonView: View {
    let block: PurchaseButtonBlock
    let look: RenderLook
    let onTap: () -> Void
    /// A check on the page is running: held, keeping its own label (P83,
    /// spec F §8 N2 — only the synthesized Continue is relabelled).
    @Environment(\.funnelCheckingLabel) private var checking
    /// A purchase or restore in flight: spins when this button asked for it.
    @Environment(\.funnelStoreBusy) private var storeBusy

    init(block: PurchaseButtonBlock, look: RenderLook, onTap: @escaping () -> Void) {
        self.block = block
        self.look = look
        self.onTap = onTap
    }

    var body: some View {
        FunnelChromeButton(
            label: block.label, chromeless: CommerceFormat.purchaseChromeless, style: block.style,
            look: look, enabled: block.enabled && checking == nil, parts: block, onTap: onTap, glass: block.glass,
            disabledBackground: block.disabledBackground, disabledText: block.disabledText,
            busy: storeBusy.button(block.actionPath))
    }
}
