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
}

/// Each package is the same row card a choice option is (`FunnelRowCard`):
/// title `textSize`/`emphasisWeight` on the left with the period `muted`
/// under it, the price `textSize`/`emphasisWeight` on the right, and the
/// selected package wearing the selected indicator and border.
struct FunnelPackageListView: View {
    /// The text size (FunnelTextScale): read so this view redraws when it changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The screen's haptics — silent when the funnel switched them off.
    @Environment(\.funnelHaptics) private var haptics
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
    private var anyBadge: Bool { block.packages.contains { $0.badge != nil } }

    var body: some View {
        if shop {
            FunnelPackShopView(block: block, look: look, onSelect: onSelect)
        } else {
            plain
        }
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
            look: look, style: block.style, scale: FunnelTextScale(dynamicType: dynamicTypeSize),
            packageSecondary: block.secondaryTextSize, packageCaption: block.captionTextSize)
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
                    FunnelRowCard(look: look, selected: selected, shape: .radio, indicator: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            FunnelInlineBadgeRow(badge: package.inlineBadge, look: look, fontSize: text.badge) {
                                if let title = package.localizedTitle, !title.isEmpty {
                                    Text(title)
                                        .font(text.secondaryFont(weight: look.emphasisWeight))
                                        .funnelLineHeight(look, size: text.secondary, family: text.family)
                                }
                            }
                            if let price = package.priceColumn(text, weight: look.emphasisWeight, look: look) {
                                price.funnelLineHeight(look, size: text.primary, family: text.family)
                            }
                            if let period = package.periodShown, !period.isEmpty {
                                Text(period)
                                    .font(text.periodFont(weight: look.textWeight))
                                    .foregroundColor(look.mutedColor)
                                    .funnelLineHeight(look, size: text.period, family: text.family)
                            }
                            if let caption = package.caption, !caption.isEmpty {
                                Text(caption)
                                    .font(text.captionFont(weight: look.textWeight))
                                    .foregroundColor(look.mutedColor)
                                    .funnelLineHeight(look, size: text.caption, family: text.family)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .overlay(alignment: .top) {
                        if let badge = package.badge {
                            FunnelPackageBadge(badge: badge, look: look)
                                .offset(y: -CGFloat(look.badgeOffsetY))
                        }
                    }
                } else {
                FunnelRowCard(look: look, selected: selected, shape: .radio, indicatorDot: block.indicatorDotColor) {
                    VStack(alignment: .leading, spacing: 0) {
                        FunnelInlineBadgeRow(badge: package.inlineBadge, look: look, fontSize: text.badge) {
                            if let title = package.localizedTitle, !title.isEmpty {
                                Text(title)
                                    .font(text.primaryFont(weight: look.emphasisWeight))
                                    .funnelLineHeight(look, size: text.primary, family: text.family)
                            }
                        }
                        if let period = package.periodShown, !period.isEmpty {
                            Text(period)
                                .font(text.periodFont(weight: look.textWeight))
                                .foregroundColor(look.mutedColor)
                                .funnelLineHeight(look, size: text.period, family: text.family)
                        }
                        if let caption = package.caption, !caption.isEmpty {
                            Text(caption)
                                .font(text.captionFont(weight: look.textWeight))
                                .foregroundColor(look.mutedColor)
                                .funnelLineHeight(look, size: text.caption, family: text.family)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // An empty price is a package the store did not price —
                    // the row still draws its title rather than an empty
                    // column.
                    if let price = package.priceColumn(text, weight: look.emphasisWeight, look: look) {
                        price.funnelLineHeight(look, size: text.primary, family: text.family)
                    }
                }
                // Inside the button's label, so VoiceOver reads the badge
                // as part of the row.
                .overlay(alignment: horizontal ? .top : .topTrailing) {
                    if let badge = package.badge {
                        FunnelPackageBadge(badge: badge, look: look)
                            // Its top `badgeOffsetY` above the row's outer
                            // edge; trailing on the row's content edge.
                            .offset(y: -CGFloat(look.badgeOffsetY))
                            .padding(.trailing, horizontal ? 0 : CGFloat(look.rowPaddingX + look.borderWidth))
                    }
                }
                // A vertical list reserves the overlap per badged row.
                .padding(.top, !horizontal && package.badge != nil ? CGFloat(look.badgeOffsetY) : 0)
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
            look: look, style: block.style, scale: FunnelTextScale(dynamicType: dynamicTypeSize),
            packageSecondary: block.secondaryTextSize, packageCaption: block.captionTextSize)
        ForEach(Array(block.packages.enumerated()), id: \.element.identifier) { index, package in
            let selected = package.identifier == block.selectedIdentifier
            let shape = RoundedRectangle(cornerRadius: CGFloat(look.cardRadius))
            Button {
                haptics.select()
                onSelect(package.identifier)
            } label: {
                Group {
                    if tiles { tile(package, text) } else { row(package, text) }
                }
                .background(shape.fill(lookColor(selected ? block.highlightFill : look.card)))
                .overlay(alignment: .top) {
                    if tiles, let badge = package.badge {
                        Text(badge.text)
                            .font(funnelFont(size: CGFloat(look.badgeFontSize), weight: look.badgeWeight, family: nil, scale: FunnelTextScale(dynamicType: dynamicTypeSize)))
                            .foregroundColor(lookColor(badge.color))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: CGFloat(look.packRibbonHeight))
                            .background(lookColor(badge.background))
                    }
                }
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        selected ? lookColor(block.highlight) : look.borderColor,
                        lineWidth: CGFloat(selected ? look.selectedBorderWidth : look.borderWidth)))
                .contentShape(shape)
            }
            .buttonStyle(FunnelRowPress(look: look))
            .funnelRadio(index: index, count: block.packages.count, selected: selected)
        }
    }

    private func title(_ package: RenderPackage, _ text: FunnelRowText) -> some View {
        Text(package.localizedTitle ?? "")
            .font(funnelFont(size: CGFloat(look.packTitleSize), weight: look.headingWeight, family: text.family, scale: text.scale))
            .funnelLineHeight(look, size: look.packTitleSize, family: text.family)
    }

    /// A pack's caption (spec F §8 H2 size).
    private func captionLine(_ value: String, _ text: FunnelRowText) -> some View {
        Text(value)
            .font(text.captionFont(weight: look.textWeight))
            .foregroundColor(look.mutedColor)
            .funnelLineHeight(look, size: text.caption, family: text.family)
    }

    /// The period line (spec F §7 G3 size).
    private func periodLine(_ value: String, _ text: FunnelRowText) -> some View {
        Text(value)
            .font(text.periodFont(weight: look.textWeight))
            .foregroundColor(look.mutedColor)
            .funnelLineHeight(look, size: text.period, family: text.family)
    }

    private func price(_ package: RenderPackage, _ text: FunnelRowText) -> some View {
        (package.priceColumn(text, weight: look.headingWeight, look: look) ?? Text(""))
            .funnelLineHeight(look, size: text.primary, family: text.family)
    }

    private func tile(_ package: RenderPackage, _ text: FunnelRowText) -> some View {
        VStack(spacing: CGFloat(look.cardGap) / CommerceFormat.halfGap) {
            if let icon = package.icon { FunnelIconPlate(icon: icon) }
            FunnelInlineBadgeRow(badge: package.inlineBadge, look: look, fontSize: text.badge) {
                if let t = package.localizedTitle, !t.isEmpty {
                    title(package, text).multilineTextAlignment(.center)
                }
            }
            if let caption = package.caption, !caption.isEmpty {
                captionLine(caption, text).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            if package.hasPrice {
                price(package, text).padding(.top, CGFloat(look.cardGap) / CommerceFormat.halfGap)
            }
            if let period = package.periodShown, !period.isEmpty { periodLine(period, text) }
        }
        .padding(.top, CGFloat(look.packRibbonHeight + look.cardGap))
        .padding(.bottom, CGFloat(look.rowPaddingY))
        .padding(.horizontal, CGFloat(look.cardGap))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ package: RenderPackage, _ text: FunnelRowText) -> some View {
        HStack(spacing: CGFloat(look.indicatorGap)) {
            if let icon = package.icon { FunnelIconPlate(icon: icon) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: CGFloat(look.badgePaddingX)) {
                    if let t = package.localizedTitle, !t.isEmpty { title(package, text) }
                    if let badge = package.badge { FunnelPackageBadge(badge: badge, look: look) }
                    if let inline = package.inlineBadge { FunnelPackageBadge(badge: inline, look: look, fontSize: text.badge) }
                }
                if let caption = package.caption, !caption.isEmpty { captionLine(caption, text) }
                if let period = package.periodShown, !period.isEmpty { periodLine(period, text) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if package.hasPrice { price(package, text) }
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

    /// The muted line under the title (spec F §7 G2): the author's
    /// `periodText` when the crate sends one — "" draws no line — else the
    /// store period.
    var periodShown: String? { periodText ?? localizedPeriod }

    /// The price column as ONE text: the price at the row's primary size
    /// and `weight`, then the `priceSuffix` smaller (secondary size), muted,
    /// at the text weight — `PackagePrice` on the web. nil when no price.
    func priceColumn(_ text: FunnelRowText, weight: Int, look: RenderLook) -> Text? {
        guard hasPrice else { return nil }
        let price = Text(priceShown).font(text.primaryFont(weight: weight))
        guard let suffix = priceSuffix, !suffix.isEmpty else { return price }
        return price
            + Text(suffix).font(text.periodFont(weight: look.textWeight)).foregroundColor(look.mutedColor)
    }
}

/// A package title with its inline badge after it (spec F §6 F5c), the
/// badge's own metrics, `badgePaddingX` apart; the title alone, unwrapped,
/// when the row has none.
struct FunnelInlineBadgeRow<Title: View>: View {
    let badge: RenderBadge?
    let look: RenderLook
    /// Spec F §7 G3: the list's authored secondary size; nil is the badge's.
    var fontSize: CGFloat? = nil
    @ViewBuilder let title: () -> Title

    var body: some View {
        if let badge {
            HStack(spacing: CGFloat(look.badgePaddingX)) {
                title()
                FunnelPackageBadge(badge: badge, look: look, fontSize: fontSize)
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
    let badge: RenderBadge
    let look: RenderLook
    /// Spec F §7 G3: an inline badge's authored text size; nil is
    /// `badgeFontSize` (every corner badge).
    var fontSize: CGFloat? = nil

    var body: some View {
        let size = fontSize ?? CGFloat(look.badgeFontSize)
        Text(badge.text)
            .font(funnelFont(size: size, weight: look.badgeWeight, family: nil, scale: FunnelTextScale(dynamicType: dynamicTypeSize)))
            .foregroundColor(lookColor(badge.color))
            .lineLimit(1)
            .fixedSize()
            .funnelLineHeight(look, size: size, family: nil)
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

    init(block: PurchaseButtonBlock, look: RenderLook, onTap: @escaping () -> Void) {
        self.block = block
        self.look = look
        self.onTap = onTap
    }

    var body: some View {
        FunnelChromeButton(
            label: block.label, chromeless: CommerceFormat.purchaseChromeless, style: block.style,
            look: look, enabled: block.enabled && checking == nil, parts: block, onTap: onTap, glass: block.glass,
            disabledBackground: block.disabledBackground, disabledText: block.disabledText)
    }
}
