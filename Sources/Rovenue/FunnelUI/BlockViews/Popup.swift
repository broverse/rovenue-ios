//  Popup.swift — the popup (spec 2026-11-10 NE §4.2, §7).
//
//  Open / closed is the session's show flag, already resolved into
//  `PopupBlock.open` (NE-D4): a `show_element` tap opens it, a dismiss here
//  asks the session (`popupDismiss`), an `enter` trigger asks it after
//  `delayMs` of foreground time (`popupTrigger`) — the session refuses what
//  must not open (shown once already, another one open). It is drawn over
//  the page by `FunnelScreenContent`, never as a system sheet, so it works
//  inside a host's sheet and inside sdk-rn / Flutter hosted views. Native
//  has no `exit` trigger and never intercepts the funnel's close (H2).
//  Every length is a `look.elements.popup` token; its motion is the look's.

import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// A top-level popup of the page and its children.
struct FunnelPopupNode {
    let block: PopupBlock
    let children: [FunnelNode]
}

private enum PopupFormat {
    static let presentationSheet = "sheet"
    static let triggerEnter = "enter"
    static let viaClose = "close"
    static let viaScrim = "scrim"
    /// The sheet's swipe-down, VoiceOver's escape gesture: they always
    /// dismiss, whatever `closeButton` / `scrim` say (spec NE §4.2).
    static let viaEscape = "escape"
    static let closeSymbol = "xmark"
    static let scrimColor = Color.black
    static let percent: CGFloat = 100
    static let millisecondsPerSecond = 1000.0
    /// A sheet dragged down past this share of its height dismisses.
    static let swipeDismissShare: CGFloat = 0.25
    static let resting: CGFloat = 0
}

/// Every popup of one page, laid over it.
struct FunnelPopupLayer: View {
    let popups: [FunnelPopupNode]
    let look: RenderLook
    let interaction: FunnelInteraction
    /// The page is the one being left: no trigger arms.
    let leaving: Bool

    var body: some View {
        ZStack {
            ForEach(popups, id: \.block.blockId) { popup in
                FunnelPopupView(popup: popup, look: look, interaction: interaction, leaving: leaving)
            }
        }
    }
}

private struct FunnelPopupView: View {
    let popup: FunnelPopupNode
    let look: RenderLook
    let interaction: FunnelInteraction
    let leaving: Bool
    @Environment(\.funnelElements) private var host
    @Environment(\.funnelScreenMotion) private var screenMotion
    @StateObject private var clock = FunnelForegroundClock()
    @State private var dragOffset = PopupFormat.resting
    @State private var panelHeight = PopupFormat.resting

    private var block: PopupBlock { popup.block }
    private var tokens: RenderPopupLook { look.elements.popup }
    private var isSheet: Bool { block.presentation == PopupFormat.presentationSheet }
    private var reduced: Bool { screenMotion?.mode != .full }

    var body: some View {
        ZStack(alignment: isSheet ? .bottom : .center) {
            if block.open {
                scrim.transition(fade)
                panel.transition(panelTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isSheet ? .bottom : .center)
        .onAppear(perform: armEnter)
        .onDisappear { clock.stop() }
        .onChange(of: block.open) { _ in
            dragOffset = PopupFormat.resting
            #if canImport(UIKit) && !os(watchOS)
                // VoiceOver moves into the popup as it opens, and back to
                // the page as it closes (spec NE §7).
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            #endif
        }
    }

    /// An `enter` popup asks to open after `delayMs` on the page, the wait
    /// standing still while the app is in the background.
    private func armEnter() {
        guard block.trigger == PopupFormat.triggerEnter, !leaving, !block.open, !clock.started else { return }
        clock.start()
        clock.at(Double(block.delayMs)) { [host, id = block.blockId] in
            host.popupTrigger(id, PopupFormat.triggerEnter)
        }
    }

    private func dismiss(_ via: String) {
        host.popupDismiss(block.blockId, via)
    }

    // MARK: Drawing

    /// The scrim: always drawn (the page beneath takes no tap while a popup
    /// is open); a tap on it dismisses only with `scrim`.
    private var scrim: some View {
        PopupFormat.scrimColor
            .opacity(look.popupScrimOpacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { if block.scrimDismiss { dismiss(PopupFormat.viaScrim) } }
            .accessibilityHidden(true)
    }

    private var panel: some View {
        let radius = CGFloat(isSheet ? tokens.sheetRadius : tokens.dialogRadius)
        return FunnelArrangement(
            spec: FunnelArrangementSpec(
                direction: RenderLayout.directionVertical, gap: 0, alignX: RenderLayout.alignCenter,
                alignY: RenderLayout.alignTop, distribute: ""),
            claimsHeight: false
        ) {
            FunnelNodeList(nodes: popup.children, look: look, interaction: interaction)
        }
        .padding(CGFloat(tokens.padding))
        .frame(maxWidth: isSheet ? .infinity : CGFloat(tokens.dialogMaxWidth))
        .background {
            Group {
                if isSheet {
                    FunnelTopRoundedRectangle(radius: radius).fill(look.cardColor).ignoresSafeArea(edges: .bottom)
                } else {
                    RoundedRectangle(cornerRadius: radius).fill(look.cardColor)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if block.closeButton { closeButton }
        }
        .background(GeometryReader { proxy in Color.clear.onAppear { panelHeight = proxy.size.height } })
        .padding(.horizontal, isSheet ? PopupFormat.resting : CGFloat(look.pagePaddingX))
        .offset(y: dragOffset)
        .gesture(swipeDown, including: isSheet ? .all : .subviews)
        // Modal to VoiceOver: named by its label (or first heading), the
        // escape gesture dismisses (spec NE §7, F6).
        .accessibilityElement(children: .contain)
        .ifLet(block.label) { $0.accessibilityLabel(Text($1)) }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss(PopupFormat.viaEscape) }
    }

    /// The close control: a `closeSize` glyph in a `closeHit` target,
    /// named from the chrome copy; trailing, so it mirrors right to left.
    private var closeButton: some View {
        Button { dismiss(PopupFormat.viaClose) } label: {
            Image(systemName: PopupFormat.closeSymbol)
                .font(.system(size: CGFloat(tokens.closeSize)))
                .foregroundColor(look.mutedColor)
                .frame(width: CGFloat(tokens.closeHit), height: CGFloat(tokens.closeHit))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(block.closeLabel))
    }

    /// A sheet follows the finger down and dismisses past a quarter of its
    /// height; anything less springs back.
    private var swipeDown: some Gesture {
        DragGesture()
            .onChanged { value in dragOffset = max(PopupFormat.resting, value.translation.height) }
            .onEnded { value in
                if value.translation.height > panelHeight * PopupFormat.swipeDismissShare {
                    dismiss(PopupFormat.viaEscape)
                } else {
                    withAnimation(enterAnimation) { dragOffset = PopupFormat.resting }
                }
            }
    }

    // MARK: Motion

    private var enterSeconds: Double {
        Double(look.motion.normalMs) / PopupFormat.millisecondsPerSecond
    }

    private var exitSeconds: Double {
        enterSeconds * Double(look.motion.exitPercent) / Double(PopupFormat.percent)
    }

    private var enterAnimation: Animation { .easeOut(duration: enterSeconds) }
    private var exitAnimation: Animation { .easeIn(duration: exitSeconds) }

    private var fade: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.opacity.animation(enterAnimation),
            removal: AnyTransition.opacity.animation(exitAnimation))
    }

    /// Sheet: up from the bottom edge; dialog: in at the look's enter
    /// scale. Reduced Motion: a fade only (spec NE §7).
    private var panelTransition: AnyTransition {
        guard !reduced else { return fade }
        let moved: AnyTransition =
            isSheet
            ? .move(edge: .bottom)
            : .scale(scale: CGFloat(look.motion.enterScale) / PopupFormat.percent)
        return .asymmetric(
            insertion: moved.combined(with: .opacity).animation(enterAnimation),
            removal: moved.combined(with: .opacity).animation(exitAnimation))
    }
}

/// A sheet's shape: the top corners rounded, the bottom square.
private struct FunnelTopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / FunnelGeometry.halves, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY),
            radius: r)
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r),
            radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
