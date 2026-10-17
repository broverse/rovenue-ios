//  Containers.swift — the three recursive blocks.
//
//  These live beside FunnelNodeView rather than with the other block views
//  because they are mutually recursive with it: a container renders each
//  child through FunnelNodeView, and FunnelNodeView renders a container
//  through these. Splitting them across files is fine; splitting them
//  across commits is not, because neither compiles alone.
//
//  Recursion depth needs no guard here. The resolver already bounded it at
//  MAX_BLOCK_DEPTH, so a screen that reached this point cannot nest deeper.

import SwiftUI

private enum ContainerFormat {
    static let directionHorizontal = "horizontal"
}

struct FunnelStackView: View {
    let block: StackBlock
    let children: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction

    init(
        block: StackBlock, children: [FunnelNode], look: RenderLook,
        interaction: FunnelInteraction
    ) {
        self.block = block
        self.children = children
        self.look = look
        self.interaction = interaction
    }

    var body: some View {
        Group {
            if block.direction == ContainerFormat.directionHorizontal {
                HStack(spacing: CGFloat(block.gap)) { content }
            } else {
                VStack(
                    alignment: funnelAlignment(block.style.align), spacing: CGFloat(block.gap)
                ) { content }
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }

    @ViewBuilder
    private var content: some View {
        ForEach(identified(children)) { entry in
            FunnelNodeView(node: entry.node, look: look, interaction: interaction)
        }
    }
}

/// Blocks pinned to the bottom of the screen. The entry point is what
/// actually pins them, via `.safeAreaInset`; this is the stack itself.
struct FunnelStickyFooterView: View {
    let block: StickyFooterBlock
    let children: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction

    init(
        block: StickyFooterBlock, children: [FunnelNode], look: RenderLook,
        interaction: FunnelInteraction
    ) {
        self.block = block
        self.children = children
        self.look = look
        self.interaction = interaction
    }

    var body: some View {
        // Its blocks sit `blockGap` apart, exactly as the scrolled body's
        // do; the page padding around it is the entry point's.
        VStack(spacing: CGFloat(look.blockGap)) {
            ForEach(identified(children)) { entry in
                FunnelNodeView(node: entry.node, look: look, interaction: interaction)
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }
}

/// Inline express checkout. Web-only, so a native screen never carries
/// one outside the contract fixtures — and there is no wallet to mount
/// here anyway. It draws the authored fallback, the no-wallet state,
/// exactly as the web drawer does when no wallet is available.
struct FunnelExpressCheckoutView: View {
    let block: ExpressCheckoutBlock
    let children: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction

    init(
        block: ExpressCheckoutBlock, children: [FunnelNode], look: RenderLook,
        interaction: FunnelInteraction
    ) {
        self.block = block
        self.children = children
        self.look = look
        self.interaction = interaction
    }

    var body: some View {
        VStack(spacing: CGFloat(look.blockGap)) {
            ForEach(identified(children)) { entry in
                FunnelNodeView(node: entry.node, look: look, interaction: interaction)
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }
}
