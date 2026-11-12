//  Absolute.swift — absolute blocks (spec 2026-11-03-funnel-absolute-blocks §2).
//
//  The resolver decided every number: the anchor as fractions, the four
//  insets (margins + an edge-pinned offset, maybe negative), a centred
//  axis's shift and which edges take the device's safe-area inset. This
//  file only places the box. A container draws its absolute children in a
//  PIN LAYER over its own box — a stack's and the sticky footer's padded
//  box, the page body's content box, the whole screen for the overlay — so
//  its flow children arrange as if they were absent (their layouts never
//  see them), and they draw above them, later ones over earlier ones.
//
//  Placement, logical (a custom `Layout` mirrors itself under RTL):
//    leading = insetLeading + (W − insetLeading − insetTrailing − w) × pinX + shiftX
//  and the same down the vertical axis. A hugging block is at most
//  W − insetLeading − insetTrailing wide, so its text wraps; a `fill` one is
//  exactly that wide. A pin layer takes no taps of its own: only what its
//  blocks draw is hit, so a tap on its empty area reaches what is below.

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// An absolute block's placement, as numbers — `RenderStyle`'s absolute
/// fields. nil for a block in flow.
struct FunnelPin: Equatable {
    let pinX: CGFloat
    let pinY: CGFloat
    let top: CGFloat
    let leading: CGFloat
    let bottom: CGFloat
    let trailing: CGFloat
    let shiftX: CGFloat
    let shiftY: CGFloat
    /// `width: "fill"`: exactly the pin box's width between the insets.
    let fills: Bool
    /// The edges whose device inset is added to the inset there.
    let safeEdges: Set<String>

    init?(style: RenderStyle?) {
        guard let style, style.isAbsolute else { return nil }
        pinX = CGFloat(style.pinX ?? PinFormat.none)
        pinY = CGFloat(style.pinY ?? PinFormat.none)
        top = CGFloat(style.insetTop ?? PinFormat.none)
        leading = CGFloat(style.insetLeading ?? PinFormat.none)
        bottom = CGFloat(style.insetBottom ?? PinFormat.none)
        trailing = CGFloat(style.insetTrailing ?? PinFormat.none)
        shiftX = CGFloat(style.shiftX ?? PinFormat.none)
        shiftY = CGFloat(style.shiftY ?? PinFormat.none)
        fills = style.width == RenderStyle.widthFill
        safeEdges = Set(style.safeAreaEdges ?? [])
    }

    /// The four insets with the device's safe-area inset added on each
    /// edge the resolver named.
    func insets(adding device: EdgeInsets) -> EdgeInsets {
        EdgeInsets(
            top: top + (safeEdges.contains(RenderStyle.safeEdgeTop) ? device.top : PinFormat.none),
            leading: leading
                + (safeEdges.contains(RenderStyle.safeEdgeLeading) ? device.leading : PinFormat.none),
            bottom: bottom
                + (safeEdges.contains(RenderStyle.safeEdgeBottom) ? device.bottom : PinFormat.none),
            trailing: trailing
                + (safeEdges.contains(RenderStyle.safeEdgeTrailing) ? device.trailing : PinFormat.none))
    }

    /// Where the block's top-leading corner goes in `bounds`, and the size
    /// it is offered, for a block that measures `measure(proposedWidth)`.
    func frame(in bounds: CGRect, device: EdgeInsets, measure: (CGFloat?) -> CGSize) -> CGRect {
        let inset = insets(adding: device)
        let width = max(PinFormat.none, bounds.width - inset.leading - inset.trailing)
        let height = max(PinFormat.none, bounds.height - inset.top - inset.bottom)
        var size: CGSize
        if fills {
            size = measure(width)
            size.width = width
        } else {
            // Hug: its ideal width, wrapped at the room it has.
            size = measure(nil)
            if size.width > width { size = measure(width) }
        }
        return CGRect(
            x: bounds.minX + inset.leading + (width - size.width) * pinX + shiftX,
            y: bounds.minY + inset.top + (height - size.height) * pinY + shiftY,
            width: size.width, height: size.height)
    }
}

private enum PinFormat {
    static let none: CGFloat = 0
}

extension FunnelNode {
    /// Whether the node is out of its parent's flow.
    var isAbsolute: Bool { style?.isAbsolute ?? false }
}

@available(iOS 16.0, macOS 13.0, *)
private struct FunnelPinKey: LayoutValueKey {
    static let defaultValue: FunnelPin? = nil
}

private struct FunnelDeviceInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    /// The device's safe-area insets (logical edges), for the blocks whose
    /// resolved `safeAreaEdges` add them. Set once per screen.
    var funnelDeviceInsets: EdgeInsets {
        get { self[FunnelDeviceInsetsKey.self] }
        set { self[FunnelDeviceInsetsKey.self] = newValue }
    }
}

/// The safe area the funnel's own view is overlapped by (system bars, the
/// notch, a host's navigation bar), measured on the view itself rather
/// than the window: a funnel shown in a sheet or under a host's bar must
/// not add an inset its box does not have.
struct FunnelSafeAreaKey: PreferenceKey {
    static let defaultValue = EdgeInsets()
    static func reduce(value: inout EdgeInsets, nextValue: () -> EdgeInsets) { value = nextValue() }
}

extension View {
    /// Measures the safe area over this view's box and hands it to its
    /// content as `funnelDeviceInsets`.
    func funnelMeasuresSafeArea(_ insets: Binding<EdgeInsets>) -> some View {
        modifier(FunnelSafeAreaMeasure(insets: insets))
    }
}

/// The measure behind `funnelMeasuresSafeArea`: the unsafe band over the
/// funnel's OWN box — the safe area of the view controller hosting the
/// funnel intersected with a UIKit probe laid over the box (spec
/// 2026-11-03-hard-paywall-and-embedded-safe-area Decisions 6–7). Four
/// things follow from measuring there:
///  - a host's navigation bar, tab bar or toolbar is part of its
///    controller's safe area (not the window's), so an embedded funnel's
///    pins and safe edges clear them;
///  - inside a presented sheet or modal the box is the sheet, so its top
///    inset is zero — "the screen" is the sheet's bounds;
///  - a page that turns its safe area off (`ignoresSafeArea`) still learns
///    the notch: SwiftUI reports zero insets to a reader inside a view that
///    ignored them, UIKit does not;
///  - the keyboard is no safe area in UIKit, so a bottom-pinned `fixed`
///    block does not ride up with it (the screen-pinned layer never follows
///    the keyboard, spec 2026-11-03-funnel-absolute-blocks §2).
private struct FunnelSafeAreaMeasure: ViewModifier {
    @Binding var insets: EdgeInsets
    @Environment(\.layoutDirection) private var layoutDirection
    /// Bumped when the safe area SwiftUI sees over the box changes — a
    /// host hiding or showing its navigation or tab bar while the funnel is
    /// on screen. The probe ignores the safe area, so its own frame and
    /// insets do not change then; this is what tells it to measure again.
    @State private var hostChange = 0

    func body(content: Content) -> some View {
        content
            .background(probe)
            #if os(iOS)
            .background(hostSafeAreaWatch)
            #endif
            .environment(\.funnelDeviceInsets, insets)
    }

    #if os(iOS)
    /// The safe area over the box, as SwiftUI lays it out (not ignored).
    private var hostSafeAreaWatch: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: FunnelSafeAreaKey.self, value: proxy.safeAreaInsets)
        }
        .onPreferenceChange(FunnelSafeAreaKey.self) { _ in hostChange &+= 1 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    #endif

    @ViewBuilder
    private var probe: some View {
        #if os(iOS)
        FunnelSafeAreaProbe(hostChange: hostChange) { [rtl = layoutDirection == .rightToLeft] ui in
            let next = EdgeInsets(
                top: ui.top, leading: rtl ? ui.right : ui.left, bottom: ui.bottom, trailing: rtl ? ui.left : ui.right)
            if next != insets { insets = next }
        }
        // Stretched over every unsafe band the box borders, so its frame is
        // the box's full extent (a sheet's, or the screen's) — the band it
        // overlaps is what is measured.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #else
        GeometryReader { proxy in
            Color.clear.preference(key: FunnelSafeAreaKey.self, value: proxy.safeAreaInsets)
        }
        .onPreferenceChange(FunnelSafeAreaKey.self) { insets = $0 }
        #endif
    }
}

#if os(iOS)
/// A transparent UIKit view reporting its own `safeAreaInsets`.
private struct FunnelSafeAreaProbe: UIViewRepresentable {
    /// `FunnelSafeAreaMeasure.hostChange`: a new value re-measures.
    let hostChange: Int
    let onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
        if hostChange != view.hostChange {
            // The host's bars moved (and animate): measure through the settle.
            view.hostChange = hostChange
            view.reportSettling()
        } else {
            view.report()
        }
    }

    final class ProbeView: UIView {
        var onChange: ((UIEdgeInsets) -> Void)?
        var hostChange = 0
        private var last: UIEdgeInsets?

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        /// A presentation moves the box without laying it out (a cover
        /// slides the whole controller up): measured again as it settles.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            reportSettling()
        }

        /// Measure now and again through the longest transition.
        func reportSettling() {
            report()
            for delay in Self.settleChecks {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.report() }
            }
        }

        /// Seconds after joining a window to measure again: through the
        /// longest presentation transition.
        private static let settleChecks: [TimeInterval] = [0.05, 0.3, 0.6, 1.0]

        /// The view whose safe area covers this one: the root view of the
        /// nearest view controller above it on the responder chain (the
        /// `UIHostingController` a `NavigationStack`, a `TabView`, a sheet
        /// or a host app puts the funnel in), whose `safeAreaInsets` carry
        /// the status bar, a navigation bar, a tab bar, a toolbar and the
        /// home indicator that actually cover it. Found through the
        /// responder chain, not `superview.next`: SwiftUI's hosting view
        /// answers `next` with an internal key-press responder, not its
        /// controller. The window when no controller owns a view above.
        private var safeAreaOwner: UIView? {
            var responder = next
            while let current = responder {
                if let controller = current as? UIViewController, let root = controller.viewIfLoaded,
                    isDescendant(of: root)
                {
                    return root
                }
                responder = current.next
            }
            return window
        }

        /// The owner's unsafe band over this view's frame. Computed, not
        /// read from this view's own `safeAreaInsets`: SwiftUI hands a
        /// representable inside an `ignoresSafeArea` region zero insets.
        /// Measured in the owner's space, so a presentation moving the
        /// whole controller (a cover sliding up) does not change it.
        private var overlap: UIEdgeInsets {
            guard window != nil, let owner = safeAreaOwner else { return .zero }
            let frame = convert(bounds, to: owner)
            let safe = owner.safeAreaInsets
            let size = owner.bounds.size
            return UIEdgeInsets(
                top: max(0, safe.top - frame.minY),
                left: max(0, safe.left - frame.minX),
                bottom: max(0, frame.maxY - (size.height - safe.bottom)),
                right: max(0, frame.maxX - (size.width - safe.right)))
        }

        func report() {
            let insets = overlap
            guard window != nil, insets != last else { return }
            last = insets
            // Off the layout pass: the binding it writes redraws the funnel.
            DispatchQueue.main.async { [weak self] in self?.onChange?(insets) }
        }
    }
}
#endif

/// Places every subview by its `FunnelPin`, over the box it is laid in.
@available(iOS 16.0, macOS 13.0, *)
private struct FunnelPinLayout: Layout {
    let device: EdgeInsets

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for subview in subviews {
            guard let pin = subview[FunnelPinKey.self] else { continue }
            let frame = pin.frame(in: bounds, device: device) {
                subview.sizeThatFits(ProposedViewSize(width: $0, height: nil))
            }
            subview.place(
                at: frame.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

extension View {
    /// Hands the pin layer this node's placement.
    @ViewBuilder
    func funnelPinValue(_ node: FunnelNode) -> some View {
        if #available(iOS 16.0, macOS 13.0, *), let pin = FunnelPin(style: node.style) {
            self.layoutValue(key: FunnelPinKey.self, value: pin)
        } else {
            self
        }
    }

    /// Draws `nodes` — a container's absolute children — over this view's
    /// box. Nothing for none.
    @ViewBuilder
    func funnelPinned(
        _ nodes: [FunnelNode], look: RenderLook, interaction: FunnelInteraction
    ) -> some View {
        if nodes.isEmpty {
            self
        } else {
            self.overlay(alignment: .topLeading) {
                FunnelPinnedNodes(nodes: nodes, look: look, interaction: interaction)
            }
        }
    }

    /// The stack's "clip content": everything it draws, absolute children
    /// included, cut to its rounded box.
    @ViewBuilder
    func funnelClip(_ clip: Bool, radius: Int?) -> some View {
        if clip {
            self.clipShape(RoundedRectangle(cornerRadius: CGFloat(radius ?? 0)))
        } else {
            self
        }
    }
}

/// A container's absolute children in their pin layer.
struct FunnelPinnedNodes: View {
    let nodes: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction
    @Environment(\.funnelDeviceInsets) private var device

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            FunnelPinLayout(device: device) {
                FunnelNodeList(nodes: nodes, look: look, interaction: interaction, pinned: true)
            }
        } else {
            // macOS 12, the package's other floor, has no `Layout`; no
            // funnel is drawn there outside the tests.
            ZStack(alignment: .topLeading) {
                FunnelNodeList(nodes: nodes, look: look, interaction: interaction, pinned: true)
            }
        }
    }
}

/// The screen-pinned layer (`RenderScreen.overlay`): the whole screen, the
/// device's safe area included, above the header, body, CTA and footer.
/// It neither scrolls nor follows the keyboard.
struct FunnelScreenOverlay: View {
    let nodes: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction

    var body: some View {
        if !nodes.isEmpty {
            // The pin layer itself, filling the screen: a `Layout` takes no
            // tap on its empty area, so only the blocks it places are hit.
            FunnelPinnedNodes(nodes: nodes, look: look, interaction: interaction)
                .ignoresSafeArea()
        }
    }
}
