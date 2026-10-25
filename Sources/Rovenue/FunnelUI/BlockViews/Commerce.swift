//  Commerce.swift — the package list and the purchase button.
//
//  Packages arrive PRICED. `localizedPrice` was formatted by the caller,
//  in the store's own currency — never reformat it here, and never compute
//  a discount or a per-month figure from it. Currency formatting is the
//  platform's job only when the platform is the one that has the number,
//  and here it is not.

import SwiftUI

private enum CommerceFormat {
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
        let text = FunnelRowText(look: look, style: block.style)
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
                            if let title = package.localizedTitle, !title.isEmpty {
                                Text(title)
                                    .font(text.secondaryFont(weight: look.emphasisWeight))
                                    .funnelLineHeight(look, size: text.secondary, family: text.family)
                            }
                            if !package.localizedPrice.isEmpty {
                                Text(package.localizedPrice)
                                    .font(text.primaryFont(weight: look.emphasisWeight))
                                    .funnelLineHeight(look, size: text.primary, family: text.family)
                            }
                            if let period = package.localizedPeriod, !period.isEmpty {
                                Text(period)
                                    .font(text.secondaryFont(weight: look.textWeight))
                                    .foregroundColor(look.mutedColor)
                                    .funnelLineHeight(look, size: text.secondary, family: text.family)
                            }
                            if let caption = package.caption, !caption.isEmpty {
                                Text(caption)
                                    .font(text.secondaryFont(weight: look.textWeight))
                                    .foregroundColor(look.mutedColor)
                                    .funnelLineHeight(look, size: text.secondary, family: text.family)
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
                FunnelRowCard(look: look, selected: selected, shape: .radio) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let title = package.localizedTitle, !title.isEmpty {
                            Text(title)
                                .font(text.primaryFont(weight: look.emphasisWeight))
                                .funnelLineHeight(look, size: text.primary, family: text.family)
                        }
                        if let period = package.localizedPeriod, !period.isEmpty {
                            Text(period)
                                .font(text.secondaryFont(weight: look.textWeight))
                                .foregroundColor(look.mutedColor)
                                .funnelLineHeight(look, size: text.secondary, family: text.family)
                        }
                        if let caption = package.caption, !caption.isEmpty {
                            Text(caption)
                                .font(text.secondaryFont(weight: look.textWeight))
                                .foregroundColor(look.mutedColor)
                                .funnelLineHeight(look, size: text.secondary, family: text.family)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // An empty price is a package the store did not price —
                    // the row still draws its title rather than an empty
                    // column.
                    if !package.localizedPrice.isEmpty {
                        Text(package.localizedPrice)
                            .font(text.primaryFont(weight: look.emphasisWeight))
                            .funnelLineHeight(look, size: text.primary, family: text.family)
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
        let text = FunnelRowText(look: look, style: block.style)
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
                            .font(funnelFont(size: CGFloat(look.badgeFontSize), weight: look.badgeWeight, family: nil))
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
            .font(funnelFont(size: CGFloat(look.packTitleSize), weight: look.headingWeight, family: text.family))
            .funnelLineHeight(look, size: look.packTitleSize, family: text.family)
    }

    private func muted(_ value: String, _ text: FunnelRowText) -> some View {
        Text(value)
            .font(text.secondaryFont(weight: look.textWeight))
            .foregroundColor(look.mutedColor)
            .funnelLineHeight(look, size: text.secondary, family: text.family)
    }

    private func price(_ package: RenderPackage, _ text: FunnelRowText) -> some View {
        Text(package.localizedPrice)
            .font(text.primaryFont(weight: look.headingWeight))
            .funnelLineHeight(look, size: text.primary, family: text.family)
    }

    private func tile(_ package: RenderPackage, _ text: FunnelRowText) -> some View {
        VStack(spacing: CGFloat(look.cardGap) / CommerceFormat.halfGap) {
            if let icon = package.icon { FunnelIconPlate(icon: icon) }
            if let t = package.localizedTitle, !t.isEmpty {
                title(package, text).multilineTextAlignment(.center)
            }
            if let caption = package.caption, !caption.isEmpty {
                muted(caption, text).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            if !package.localizedPrice.isEmpty {
                price(package, text).padding(.top, CGFloat(look.cardGap) / CommerceFormat.halfGap)
            }
            if let period = package.localizedPeriod, !period.isEmpty { muted(period, text) }
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
                }
                if let caption = package.caption, !caption.isEmpty { muted(caption, text) }
                if let period = package.localizedPeriod, !period.isEmpty { muted(period, text) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !package.localizedPrice.isEmpty { price(package, text) }
        }
        .padding(.vertical, CGFloat(look.rowPaddingY))
        .padding(.horizontal, CGFloat(look.rowPaddingX))
    }
}

/// A package row's pill: `badgeFontSize` in `badgeWeight`, padded
/// `badgePaddingY` × `badgePaddingX`, `badgeRadius` (999 is a pill —
/// SwiftUI clamps a corner to half the height), in the resolver's colours.
struct FunnelPackageBadge: View {
    let badge: RenderBadge
    let look: RenderLook

    var body: some View {
        Text(badge.text)
            .font(funnelFont(size: CGFloat(look.badgeFontSize), weight: look.badgeWeight, family: nil))
            .foregroundColor(lookColor(badge.color))
            .lineLimit(1)
            .fixedSize()
            .funnelLineHeight(look, size: look.badgeFontSize, family: nil)
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

    init(block: PurchaseButtonBlock, look: RenderLook, onTap: @escaping () -> Void) {
        self.block = block
        self.look = look
        self.onTap = onTap
    }

    var body: some View {
        FunnelChromeButton(
            label: block.label, variant: block.variant, style: block.style, look: look,
            enabled: block.enabled, parts: block, onTap: onTap)
    }
}
