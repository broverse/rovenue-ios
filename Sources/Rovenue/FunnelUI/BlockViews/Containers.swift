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
        // Placed by `alignX`/`alignY`/`distribute` alone — a legacy stack's
        // `style.align` was folded into `alignX` by the resolver. A stack
        // with a fixed height spreads its children over that height.
        FunnelArrangement(
            spec: FunnelArrangementSpec(stack: block), claimsHeight: block.style.height != nil
        ) {
            FunnelNodeList(nodes: children, look: look, interaction: interaction)
        }
        .funnelStyle(block.style, look.bodyType)
    }
}

// MARK: - Arrangement (a stack's or the page body's children)

/// How a stack — or the page body — places its children: its resolved
/// `direction`, `gap`, `alignX`, `alignY` and `distribute`, as numbers.
struct FunnelArrangementSpec: Equatable {
    enum Flow: Equatable {
        case column, row, wrap
    }

    enum Distribute: Equatable {
        case packed, spaceBetween, spaceAround, spaceEvenly
    }

    let flow: Flow
    let gap: CGFloat
    /// Where along each axis packed children sit, as a fraction of the
    /// free space: 0 leading/top, ½ centre, 1 trailing/bottom. Logical —
    /// a custom `Layout` mirrors itself in a right-to-left environment.
    let alignX: CGFloat
    let alignY: CGFloat
    let distribute: Distribute

    init(direction: String, gap: Double, alignX: String, alignY: String, distribute: String) {
        switch direction {
        case RenderLayout.directionHorizontal: flow = .row
        case RenderLayout.directionWrap: flow = .wrap
        default: flow = .column
        }
        self.gap = CGFloat(gap)
        self.alignX = funnelPlacementFraction(alignX)
        self.alignY = funnelPlacementFraction(alignY)
        switch distribute {
        case RenderLayout.distributeSpaceBetween: self.distribute = .spaceBetween
        case RenderLayout.distributeSpaceAround: self.distribute = .spaceAround
        case RenderLayout.distributeSpaceEvenly: self.distribute = .spaceEvenly
        default: self.distribute = .packed
        }
    }

    init(stack: StackBlock) {
        self.init(
            direction: stack.direction, gap: Double(stack.gap), alignX: stack.alignX,
            alignY: stack.alignY, distribute: stack.distribute)
    }

    init(layout: RenderLayout) {
        self.init(
            direction: layout.direction, gap: layout.gap, alignX: layout.alignX,
            alignY: layout.alignY, distribute: layout.distribute)
    }
}

/// Geometry shared by the arrangement and the progress bar.
enum FunnelGeometry {
    /// Halving a length: a centre, half a gap.
    static let halves: CGFloat = 2
}

private enum PlacementFraction {
    static let start: CGFloat = 0
    static let center: CGFloat = 0.5
    static let end: CGFloat = 1
}

/// A wire position as a fraction of the free space: `left`/`top`/`start`
/// 0, `center` ½, `right`/`bottom`/`end` 1. Anything else is the start.
func funnelPlacementFraction(_ value: String?) -> CGFloat {
    switch value {
    case RenderLayout.alignCenter: return PlacementFraction.center
    case RenderLayout.alignRight, RenderLayout.alignBottom, RenderStyle.alignSelfEnd:
        return PlacementFraction.end
    default: return PlacementFraction.start
    }
}

/// Which kind of arrangement a block sits in — read by `funnelStyle`'s
/// width rule. nil: a container that is not an arrangement (the sticky
/// footer, express checkout), where a block keeps today's full width.
enum FunnelParentFlow: Equatable {
    /// A column: an unwritten width fills it.
    case column
    /// A row or wrap: an unwritten width hugs.
    case row
}

private struct FunnelParentFlowKey: EnvironmentKey {
    static let defaultValue: FunnelParentFlow? = nil
}

extension EnvironmentValues {
    var funnelParentFlow: FunnelParentFlow? {
        get { self[FunnelParentFlowKey.self] }
        set { self[FunnelParentFlowKey.self] = newValue }
    }
}

/// What a child tells the arrangement placing it, from its own style.
struct FunnelChildPlacement: Equatable {
    /// An equal share of a row's free width: `width: "fill"`, a flexible
    /// spacer, or a progress bar / divider / image with no width written —
    /// the blocks that have no content width to hug (cross-platform
    /// ruling; a fixed spacer keeps its own).
    var fills = false
    /// The free height of a column (a flexible spacer).
    var grows = false
    /// Hugs and never shrinks (`width: "fit"`).
    var fits = false
    /// Its own cross-axis position (`alignSelf`), or nil for the parent's.
    var crossSelf: CGFloat?
    /// A fit box's `style.align`: where it sat in a column before
    /// `alignSelf` existed, kept for a document that sets no `alignSelf`.
    var legacyCross: CGFloat?

    static let none = FunnelChildPlacement()

    init() {}

    init(node: FunnelNode) {
        if case .spacer(let spacer) = node, spacer.flex {
            fills = true
            grows = true
        }
        guard let style = node.style else { return }
        fills = fills || style.width == RenderStyle.widthFill || (style.width == nil && node.fillsARowByDefault)
        fits = style.width == RenderStyle.widthFit
        crossSelf = style.alignSelf.map { funnelPlacementFraction($0) }
        legacyCross = fits ? style.align.map { funnelPlacementFraction($0) } : nil
    }

    /// The child's cross-axis fraction: its own, a fit box's legacy
    /// `align` in a column, else the parent's.
    func cross(_ parent: CGFloat, column: Bool) -> CGFloat {
        crossSelf ?? (column ? legacyCross : nil) ?? parent
    }
}

extension FunnelNode {
    /// A progress bar, a divider and an image have no content width to
    /// hug (an image is full width, aspect fit): in a row with no width
    /// written they take the fill share rather than collapse.
    fileprivate var fillsARowByDefault: Bool {
        switch self {
        case .progress, .divider, .image: return true
        default: return false
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct FunnelChildPlacementKey: LayoutValueKey {
    static let defaultValue = FunnelChildPlacement.none
}

extension View {
    /// Hands the arrangement this child sits in its placement.
    @ViewBuilder
    func funnelChildPlacement(_ placement: FunnelChildPlacement) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.layoutValue(key: FunnelChildPlacementKey.self, value: placement)
        } else {
            self
        }
    }
}

/// Lays out `content` (one subview per block) as `spec` says.
///
/// - `claimsHeight`: take the height offered (and at least `minHeight`),
///   so `alignY` and `distribute` have room to act — the page body and a
///   fixed-height stack. Any other stack is as tall as its content, as a
///   `VStack` is.
struct FunnelArrangement<Content: View>: View {
    let spec: FunnelArrangementSpec
    let claimsHeight: Bool
    let minHeight: CGFloat
    let content: Content

    init(
        spec: FunnelArrangementSpec, claimsHeight: Bool, minHeight: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.spec = spec
        self.claimsHeight = claimsHeight
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        arranged.environment(\.funnelParentFlow, spec.flow == .column ? .column : .row)
    }

    @ViewBuilder
    private var arranged: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            let height = FunnelClaimedHeight(claims: claimsHeight, minimum: minHeight)
            switch spec.flow {
            case .column: FunnelColumnLayout(spec: spec, height: height) { content }
            case .row: FunnelRowLayout(spec: spec, height: height) { content }
            case .wrap: FunnelFlowLayout(spec: spec, height: height) { content }
            }
        } else {
            // macOS 12, the package's other floor, has no `Layout`; no
            // funnel is drawn there outside the tests.
            switch spec.flow {
            case .column: VStack(alignment: .leading, spacing: spec.gap) { content }
            case .row, .wrap: HStack(spacing: spec.gap) { content }
            }
        }
    }
}

/// How tall an arrangement makes itself, given its content's height.
private struct FunnelClaimedHeight {
    let claims: Bool
    let minimum: CGFloat

    func resolve(content: CGFloat, offered: CGFloat?) -> CGFloat {
        guard claims else { return content }
        let finiteOffer = Arrange.finite(offered) ?? Arrange.none
        return max(content, minimum, finiteOffer)
    }
}

/// What an arrangement measures once per change of its children rather
/// than on every pass: each child's placement, its ideal size, and — in a
/// row — its min-content width (the floor it never shrinks below).
private struct FunnelArrangementCache {
    var placements: [FunnelChildPlacement]
    var ideals: [CGSize]
    var floors: [CGFloat]

    @available(iOS 16.0, macOS 13.0, *)
    init(_ subviews: LayoutSubviews, floors measureFloors: Bool) {
        placements = subviews.map { $0[FunnelChildPlacementKey.self] }
        ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        floors =
            measureFloors
            ? subviews.map { $0.sizeThatFits(ProposedViewSize(width: Arrange.none, height: nil)).width }
            : []
    }
}

private enum Arrange {
    static let none: CGFloat = 0
    /// Below this a leftover length is rounding, not space.
    static let epsilon: CGFloat = 0.5

    /// A finite proposed length, or nil for "ideal" (unspecified/infinite).
    static func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func gaps(_ count: Int, _ gap: CGFloat) -> CGFloat {
        count > 1 ? CGFloat(count - 1) * gap : none
    }

    /// Where the first child starts and what each gap grows by, for
    /// `extra` free space along the main axis — CSS `justify-content`.
    static func spread(
        _ extra: CGFloat, count: Int, _ distribute: FunnelArrangementSpec.Distribute,
        packed fraction: CGFloat
    ) -> (lead: CGFloat, between: CGFloat) {
        guard extra > none, count > 0 else { return (none, none) }
        let n = CGFloat(count)
        switch distribute {
        case .packed: return (extra * fraction, none)
        case .spaceBetween: return count > 1 ? (none, extra / (n - 1)) : (none, none)
        case .spaceAround: return (extra / (n * FunnelGeometry.halves), extra / n)
        case .spaceEvenly: return (extra / (n + 1), extra / (n + 1))
        }
    }
}

/// A column: every child offered the full width (an unwritten width
/// fills it), stacked `gap` apart; a fit child sits across by its own
/// `alignSelf`, else by `alignX`. Free height goes to flexible spacers,
/// else is spread by `distribute` / `alignY`.
@available(iOS 16.0, macOS 13.0, *)
private struct FunnelColumnLayout: Layout {
    let spec: FunnelArrangementSpec
    let height: FunnelClaimedHeight

    func makeCache(subviews: Subviews) -> FunnelArrangementCache {
        FunnelArrangementCache(subviews, floors: false)
    }

    func updateCache(_ cache: inout FunnelArrangementCache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout FunnelArrangementCache
    ) -> CGSize {
        let width =
            Arrange.finite(proposal.width) ?? cache.ideals.map(\.width).max() ?? Arrange.none
        let sizes = measure(width, subviews)
        let content = sizes.reduce(Arrange.none) { $0 + $1.height } + Arrange.gaps(sizes.count, spec.gap)
        return CGSize(width: width, height: height.resolve(content: content, offered: proposal.height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout FunnelArrangementCache
    ) {
        var sizes = measure(bounds.width, subviews)
        let placements = cache.placements
        let content = sizes.reduce(Arrange.none) { $0 + $1.height } + Arrange.gaps(sizes.count, spec.gap)
        var extra = max(Arrange.none, bounds.height - content)
        let growing = placements.indices.filter { placements[$0].grows }
        if !growing.isEmpty && extra > Arrange.none {
            let share = extra / CGFloat(growing.count)
            for i in growing { sizes[i].height += share }
            extra = Arrange.none
        }
        let (lead, between) = Arrange.spread(
            extra, count: sizes.count, spec.distribute, packed: spec.alignY)
        var y = bounds.minY + lead
        for i in subviews.indices {
            let cross = placements[i].cross(spec.alignX, column: true)
            let x = bounds.minX + (bounds.width - sizes[i].width) * cross
            subviews[i].place(
                at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: sizes[i].height))
            y += sizes[i].height + spec.gap + between
        }
    }

    private func measure(_ width: CGFloat, _ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    }
}

/// A row: every child hugs its content (its ideal width), a fill child
/// takes an equal share of what is left (`flex: 1`). When the row runs
/// out, the hugging children shrink in proportion to their width — but
/// never below their min-content width (CSS `flex: 0 1 auto` with
/// `min-width: auto`), and a fit child never shrinks. Free width is
/// spread by `distribute` / `alignX`; each child sits across by its own
/// `alignSelf`, else by `alignY`.
@available(iOS 16.0, macOS 13.0, *)
private struct FunnelRowLayout: Layout {
    let spec: FunnelArrangementSpec
    let height: FunnelClaimedHeight

    func makeCache(subviews: Subviews) -> FunnelArrangementCache {
        FunnelArrangementCache(subviews, floors: true)
    }

    func updateCache(_ cache: inout FunnelArrangementCache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout FunnelArrangementCache
    ) -> CGSize {
        let width =
            Arrange.finite(proposal.width)
            ?? cache.ideals.reduce(Arrange.none) { $0 + $1.width } + Arrange.gaps(cache.ideals.count, spec.gap)
        let heights = measure(widths(width, cache), subviews)
        let content = heights.max() ?? Arrange.none
        return CGSize(width: width, height: height.resolve(content: content, offered: proposal.height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout FunnelArrangementCache
    ) {
        let widths = widths(bounds.width, cache)
        let heights = measure(widths, subviews)
        let placements = cache.placements
        let used = widths.reduce(Arrange.none, +) + Arrange.gaps(widths.count, spec.gap)
        // Fill children already took the free width.
        let extra = placements.contains { $0.fills } ? Arrange.none : max(Arrange.none, bounds.width - used)
        let (lead, between) = Arrange.spread(
            extra, count: widths.count, spec.distribute, packed: spec.alignX)
        var x = bounds.minX + lead
        for i in subviews.indices {
            let cross = placements[i].cross(spec.alignY, column: false)
            let y = bounds.minY + (bounds.height - heights[i]) * cross
            subviews[i].place(
                at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: widths[i], height: heights[i]))
            x += widths[i] + spec.gap + between
        }
    }

    /// Each child's width in a row `width` wide.
    private func widths(_ width: CGFloat, _ cache: FunnelArrangementCache) -> [CGFloat] {
        let placements = cache.placements
        let ideals = cache.ideals.map(\.width)
        let available = max(Arrange.none, width - Arrange.gaps(ideals.count, spec.gap))
        // Nothing goes below its min-content width (`min-width: auto`) —
        // a fill child included.
        let floors = ideals.indices.map { min(cache.floors[$0], ideals[$0]) }
        let fillers = placements.indices.filter { placements[$0].fills }
        var widths = ideals.indices.map { placements[$0].fills ? floors[$0] : ideals[$0] }
        let hugging = widths.reduce(Arrange.none, +)
        if hugging > available {
            // Shrink in proportion to each child's own width, freezing a
            // child at its floor and handing what it could not give to the
            // others — until the row fits or nothing can give.
            var active = widths.indices.filter {
                !placements[$0].fills && !placements[$0].fits && widths[$0] > floors[$0]
            }
            var overflow = hugging - available
            while overflow > Arrange.epsilon && !active.isEmpty {
                let weight = active.reduce(Arrange.none) { $0 + ideals[$1] }
                guard weight > Arrange.none else { break }
                let floored = active.filter { widths[$0] - overflow * ideals[$0] / weight <= floors[$0] }
                if floored.isEmpty {
                    for i in active { widths[i] -= overflow * ideals[i] / weight }
                    overflow = Arrange.none
                } else {
                    for i in floored {
                        overflow -= widths[i] - floors[i]
                        widths[i] = floors[i]
                    }
                    active.removeAll { floored.contains($0) }
                }
            }
        } else if !fillers.isEmpty {
            // The fill children split what the hugging ones leave.
            let fillFloors = fillers.reduce(Arrange.none) { $0 + floors[$1] }
            let share = (available - hugging + fillFloors) / CGFloat(fillers.count)
            for i in fillers { widths[i] = max(floors[i], share) }
        }
        return widths
    }

    private func measure(_ widths: [CGFloat], _ subviews: Subviews) -> [CGFloat] {
        subviews.indices.map {
            subviews[$0].sizeThatFits(ProposedViewSize(width: widths[$0], height: nil)).height
        }
    }
}

/// Rows that wrap (CSS `flex-wrap`): children hug, each line holds as
/// many as fit `gap` apart, lines are `gap` apart. A fill child takes an
/// equal share of its line's free width; otherwise a line's free width is
/// spread by `distribute` / `alignX`, and each child sits in its line by
/// its own `alignSelf`, else by `alignY`.
@available(iOS 16.0, macOS 13.0, *)
private struct FunnelFlowLayout: Layout {
    let spec: FunnelArrangementSpec
    let height: FunnelClaimedHeight

    private struct Line {
        var items: [Int] = []
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
        var height: CGFloat { heights.max() ?? Arrange.none }
    }

    func makeCache(subviews: Subviews) -> FunnelArrangementCache {
        FunnelArrangementCache(subviews, floors: false)
    }

    func updateCache(_ cache: inout FunnelArrangementCache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout FunnelArrangementCache
    ) -> CGSize {
        let width =
            Arrange.finite(proposal.width)
            ?? cache.ideals.reduce(Arrange.none) { $0 + $1.width } + Arrange.gaps(cache.ideals.count, spec.gap)
        let lines = lines(width, cache, subviews)
        return CGSize(
            width: width, height: height.resolve(content: contentHeight(lines), offered: proposal.height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout FunnelArrangementCache
    ) {
        let lines = lines(bounds.width, cache, subviews)
        let placements = cache.placements
        var y =
            bounds.minY + max(Arrange.none, bounds.height - contentHeight(lines)) * spec.alignY
        for line in lines {
            let used = line.widths.reduce(Arrange.none, +) + Arrange.gaps(line.items.count, spec.gap)
            let (lead, between) = Arrange.spread(
                max(Arrange.none, bounds.width - used), count: line.items.count, spec.distribute,
                packed: spec.alignX)
            var x = bounds.minX + lead
            for (k, i) in line.items.enumerated() {
                let cross = placements[i].cross(spec.alignY, column: false)
                subviews[i].place(
                    at: CGPoint(x: x, y: y + (line.height - line.heights[k]) * cross), anchor: .topLeading,
                    proposal: ProposedViewSize(width: line.widths[k], height: line.heights[k]))
                x += line.widths[k] + spec.gap + between
            }
            y += line.height + spec.gap
        }
    }

    private func contentHeight(_ lines: [Line]) -> CGFloat {
        lines.reduce(Arrange.none) { $0 + $1.height } + Arrange.gaps(lines.count, spec.gap)
    }

    /// Greedy lines: a child wider than the row is offered the row's width.
    private func lines(_ width: CGFloat, _ cache: FunnelArrangementCache, _ subviews: Subviews) -> [Line] {
        let placements = cache.placements
        var lines: [Line] = []
        var current = Line()
        var used = Arrange.none
        for i in subviews.indices {
            let w = min(cache.ideals[i].width, width)
            if !current.items.isEmpty && used + spec.gap + w > width {
                lines.append(current)
                current = Line()
                used = Arrange.none
            }
            used += (current.items.isEmpty ? Arrange.none : spec.gap) + w
            current.items.append(i)
            current.widths.append(w)
        }
        if !current.items.isEmpty { lines.append(current) }
        for l in lines.indices {
            let fillers = lines[l].items.indices.filter { placements[lines[l].items[$0]].fills }
            if !fillers.isEmpty {
                let lineUsed =
                    lines[l].widths.reduce(Arrange.none, +) + Arrange.gaps(lines[l].items.count, spec.gap)
                let share = max(Arrange.none, width - lineUsed) / CGFloat(fillers.count)
                for k in fillers { lines[l].widths[k] += share }
            }
            lines[l].heights = lines[l].items.indices.map { k in
                subviews[lines[l].items[k]].sizeThatFits(
                    ProposedViewSize(width: lines[l].widths[k], height: nil)
                ).height
            }
        }
        return lines
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
            FunnelNodeList(nodes: children, look: look, interaction: interaction)
                // Not an arrangement: its blocks keep today's full width.
                .environment(\.funnelParentFlow, nil)
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
            FunnelNodeList(nodes: children, look: look, interaction: interaction)
                .environment(\.funnelParentFlow, nil)
        }
        .funnelStyle(block.style, look.bodyType)
    }
}
