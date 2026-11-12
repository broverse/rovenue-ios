//  Pagers.swift — the accordion (Spec D §5): expandable items, mutually
//  recursive with FunnelNodeView as the other containers are. The carousel
//  lives in Carousel/ (spec CL §8.2).
//
//  Open/closed is drawer-local UI state, never machine state: nothing here
//  reports to the session.

import SwiftUI

private enum PagerFormat {
    static let millisecondsPerSecond = 1000.0
    static let modeSingle = "single"
    static let chevronNone = "none"
    static let chevronPlus = "plus"
    static let chevronGlyph = "chevron.down"
    static let plusGlyph = "plus"
    static let minusGlyph = "minus"
    /// The chevron turns this far when its item opens.
    static let chevronOpenDegrees = 180.0
    /// The item header's spoken state: SDK chrome, the English fallback —
    /// the tree's `expandedLabel` / `collapsedLabel` replace it where the
    /// visitor's language is not `en` (spec F §7 N1, P106).
    static let expanded = "expanded"
    static let collapsed = "collapsed"
}

// MARK: - Accordion

struct FunnelAccordionView: View {
    let block: AccordionBlock
    let bodies: [[FunnelNode]]
    let look: RenderLook
    let interaction: FunnelInteraction

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Seeded from the resolver's `open`; drawer-local after that.
    @State private var open: Set<String>

    init(block: AccordionBlock, bodies: [[FunnelNode]], look: RenderLook, interaction: FunnelInteraction) {
        self.block = block
        self.bodies = bodies
        self.look = look
        self.interaction = interaction
        _open = State(initialValue: Set(block.items.filter(\.open).map(\.blockId)))
    }

    var body: some View {
        VStack(spacing: CGFloat(block.gap)) {
            ForEach(Array(zip(block.items, bodies).enumerated()), id: \.offset) { _, pair in
                item(pair.0, body: pair.1)
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }

    private var expandedWord: String {
        block.expandedLabel.flatMap { $0.isEmpty ? nil : $0 } ?? PagerFormat.expanded
    }
    private var collapsedWord: String {
        block.collapsedLabel.flatMap { $0.isEmpty ? nil : $0 } ?? PagerFormat.collapsed
    }

    private func item(_ item: RenderAccordionItem, body: [FunnelNode]) -> some View {
        let isOpen = open.contains(item.blockId)
        return VStack(alignment: .leading, spacing: CGFloat(look.cardGap)) {
            Button { toggle(item.blockId) } label: {
                HStack(spacing: CGFloat(look.indicatorGap)) {
                    Text(item.title)
                        .font(funnelFont(
                            size: CGFloat(block.titleSize), weight: look.emphasisWeight, family: nil,
                            scale: FunnelTextScale(dynamicType: dynamicTypeSize)))
                        .foregroundColor(funnelColor(block.titleColor) ?? look.textColor)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    chevron(isOpen)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(isOpen ? expandedWord : collapsedWord))
            if isOpen && !body.isEmpty {
                // A collapsed body is not drawn at all — out of the
                // accessibility tree and the tab order (Spec D §5).
                VStack(alignment: .leading, spacing: CGFloat(look.blockGap)) {
                    FunnelNodeList(nodes: body.filter { !$0.isAbsolute }, look: look, interaction: interaction)
                }
                .environment(\.funnelParentFlow, .column)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .funnelStyle(item.style, look.bodyType)
    }

    @ViewBuilder
    private func chevron(_ isOpen: Bool) -> some View {
        let tint = funnelColor(block.titleColor) ?? look.textColor
        switch block.chevron {
        case PagerFormat.chevronNone:
            EmptyView()
        case PagerFormat.chevronPlus:
            Image(systemName: isOpen ? PagerFormat.minusGlyph : PagerFormat.plusGlyph).foregroundColor(tint)
        default:
            Image(systemName: PagerFormat.chevronGlyph)
                .foregroundColor(tint)
                .rotationEffect(.degrees(isOpen && !reduceMotion ? PagerFormat.chevronOpenDegrees : 0))
                .scaleEffect(y: isOpen && reduceMotion ? -1 : 1)
        }
    }

    /// `single` keeps at most one item open; `multiple` toggles freely.
    private func toggle(_ id: String) {
        let change = {
            if open.contains(id) {
                open.remove(id)
            } else {
                if block.mode == PagerFormat.modeSingle { open.removeAll() }
                open.insert(id)
            }
        }
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: look.motion.fastSeconds)) { change() } }
    }
}

extension RenderMotionTokens {
    fileprivate var fastSeconds: Double { Double(fastMs) / PagerFormat.millisecondsPerSecond }
}
