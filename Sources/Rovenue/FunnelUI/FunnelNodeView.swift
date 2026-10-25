//  FunnelNodeView.swift — the exhaustive switch over FunnelNode.
//
//  Adding a FunnelNode case without a view here does not compile, which is
//  the half of the contract that tests cannot cover: FunnelNodeTests proves
//  each block maps to the intended CASE, and this proves each case has a
//  VIEW. Neither covers the failure mode alone.

import SwiftUI

/// What a view reports upward. Bundled so a new block type does not widen
/// every view's signature, and so no block view ever holds the session.
struct FunnelInteraction {
    /// Run the chain at an action path (`cta`, `el.<blockId>`,
    /// `opt.<urlEncodedValue>`).
    let tap: (String) -> Void
    /// Record an answer for a question block.
    let answer: (String, QuestionAnswer) -> Void
    /// Record which offering package a package-list row selected.
    let selectPackage: (String) -> Void
    /// A held button or CTA was tapped: the page shows why its answers
    /// cannot be used yet.
    let held: () -> Void
    /// A progress block's back control: the session's existing back step.
    let back: () -> Void

    init(
        tap: @escaping (String) -> Void,
        answer: @escaping (String, QuestionAnswer) -> Void,
        selectPackage: @escaping (String) -> Void,
        held: @escaping () -> Void = {},
        back: @escaping () -> Void = {}
    ) {
        self.tap = tap
        self.answer = answer
        self.selectPackage = selectPackage
        self.held = held
        self.back = back
    }
}

struct FunnelNodeView: View {
    let node: FunnelNode
    /// The screen's look — every block draws with it (see FunnelLook.swift).
    let look: RenderLook
    let interaction: FunnelInteraction
    /// Hidden on the same page and drawn only for its exit (`FunnelPresence`).
    let exiting: Bool
    /// Its exit ended: the list drops it.
    let onExited: (() -> Void)?

    init(
        node: FunnelNode, look: RenderLook, interaction: FunnelInteraction, exiting: Bool = false,
        onExited: (() -> Void)? = nil
    ) {
        self.node = node
        self.look = look
        self.interaction = interaction
        self.exiting = exiting
        self.onExited = onExited
    }

    var body: some View {
        // Every node enters, exits and pulses the same way, whatever it draws.
        drawn.modifier(
            FunnelElementMotion(
                motion: node.motion, exiting: exiting, onExited: onExited, holdsPlayback: node.isVideo))
            // Read by the arrangement it sits in (`FunnelArrangement`).
            .funnelChildPlacement(FunnelChildPlacement(node: node))
    }

    @ViewBuilder
    private var drawn: some View {
        switch node {
        case .heading(let b): FunnelHeadingView(block: b, look: look)
        case .text(let b): FunnelTextView(block: b, look: look)
        case .image(let b): FunnelImageView(block: b, look: look)
        case .video(let b): FunnelVideoView(block: b, look: look)
        case .button(let b):
            FunnelButtonView(
                block: b, look: look, onTap: { interaction.tap(b.actionPath) },
                onHeldTap: interaction.held)
        case .spacer(let b): FunnelSpacerView(block: b)
        case .icon(let b): FunnelIconView(block: b, look: look)
        case .divider(let b): FunnelDividerView(block: b, look: look)
        case .activity: FunnelActivityView(look: look)
        case .review(let b): FunnelReviewView(block: b, look: look)
        case .gallery(let b): FunnelGalleryView(block: b, look: look)
        case .stack(let b, let children):
            FunnelStackView(block: b, children: children, look: look, interaction: interaction)
        case .progress(let b): FunnelProgressView(block: b, look: look, onBack: interaction.back)
        case .question(let b):
            FunnelQuestionView(
                block: b,
                look: look,
                onAnswer: { interaction.answer(b.blockId, $0) },
                onOptionTap: { interaction.tap($0) }
            )
        case .packageList(let b):
            FunnelPackageListView(block: b, look: look) { interaction.selectPackage($0) }
        case .purchaseButton(let b):
            FunnelPurchaseButtonView(block: b, look: look) { interaction.tap(b.actionPath) }
        case .comparisonTable(let b): FunnelComparisonTableView(block: b, look: look)
        case .featureList(let b): FunnelFeatureListView(block: b, look: look)
        case .stickyFooter(let b, let children):
            FunnelStickyFooterView(
                block: b, children: children, look: look, interaction: interaction)
        case .expressCheckout(let b, let children):
            FunnelExpressCheckoutView(
                block: b, children: children, look: look, interaction: interaction)
        case .cta(let c):
            FunnelCtaView(
                cta: c, look: look, onTap: { interaction.tap(c.actionPath) },
                onHeldTap: interaction.held)
        }
    }
}

extension FunnelNode {
    /// A video holds its playback while it enters.
    fileprivate var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
}
