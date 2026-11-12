//  FunnelCarouselView.swift — the format-6 carousel (spec CL §8.2): one
//  child per slide, drawn in one of six layouts. This file owns what every
//  paging layout shares — the current slide, the swipe rule, autoplay, the
//  indicator and arrows around the pager — and the offset strip that draws
//  `peek`, `paged` and `scale`. `stack` is CarouselDeck, `fade`
//  CarouselFade, `marquee` CarouselMarquee.
//
//  Every number is the resolver's (`RenderBlock::Carousel`) or the look's
//  (`look.carousel`, `look.motion`): no drawer-private threshold, pitch,
//  margin or timing (spec CL §4.7, C2). The current slide is drawer-local
//  UI state, never machine state: nothing here reports to the session.

import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// The words and unit conversions the carousel compares against — never a
/// geometry or timing value (those are the block's and the look's).
enum CarouselFormat {
    static let percent: CGFloat = 100
    static let half: CGFloat = 2
    static let millisecondsPerSecond = 1000.0
    static let nanosecondsPerMillisecond = 1_000_000.0
    static let thousandths = 1000.0
    /// A cubic bezier's four control points, x1 y1 x2 y2.
    static let bezierPoints = 4
    static let alignStart = "start"
    static let layoutScale = "scale"
    static let layoutStack = "stack"
    static let layoutFade = "fade"
    static let layoutMarquee = "marquee"
    static let positionBelow = "below"
    static let positionOverlayTop = "overlayTop"
    static let stylePill = "pill"
    static let styleBars = "bars"
    static let styleCounter = "counter"
    static let arrowsOverlay = "overlay"
    static let arrowsBelow = "below"
    static let cardElevated = "elevated"
    static let cardOutlined = "outlined"
    static let cardGlass = "glass"
    static let directionBackward = "backward"
    /// A chevron or pause glyph's share of its circle (as the web's).
    static let glyphShare: CGFloat = 0.5
    /// CSS `box-shadow` blur is twice the Gaussian deviation SwiftUI's
    /// `.shadow(radius:)` takes: the same shadow, in each one's unit.
    static let cssBlurPerShadowRadius: CGFloat = 2
}

extension RenderSpring {
    /// The carousel's movement (`block.curve`) as SwiftUI's spring: the
    /// response and damping ratio the crate resolved, mass 1 — the physics
    /// the web samples into `css` and Android into its interpolator.
    var carouselAnimation: Animation {
        .spring(
            response: Double(responseMs) / CarouselFormat.millisecondsPerSecond,
            dampingFraction: Double(dampingRatio) / Double(CarouselFormat.percent), blendDuration: 0)
    }
}

/// The two clocks a carousel animates on (spec CL §4.5), or none under
/// Reduce Motion: `curve` moves, `speed` fades and resizes.
struct CarouselMotion {
    let block: CarouselBlock
    let look: RenderLook
    let reduced: Bool

    /// Settling a page, a throw, a spring-back: the block's spring.
    var move: Animation? { reduced ? nil : block.curve.carouselAnimation }

    /// A crossfade, a pill's width, an arrow's fade: `fadeMs` on the look's
    /// fade curve.
    var fade: Animation? {
        guard !reduced else { return nil }
        let seconds = Double(block.fadeMs) / CarouselFormat.millisecondsPerSecond
        let points = look.motion.fadeCurve
        guard points.count == CarouselFormat.bezierPoints else { return .linear(duration: seconds) }
        let p = points.map { Double($0) / CarouselFormat.thousandths }
        return .timingCurve(p[0], p[1], p[2], p[3], duration: seconds)
    }
}

/// The pager's geometry, from the measured width and the resolver's numbers.
struct CarouselGeometry {
    let width: CGFloat
    let block: CarouselBlock

    var slideWidth: CGFloat { width * CGFloat(block.itemWidth) / CarouselFormat.percent }
    var gap: CGFloat { CGFloat(block.gap) }
    /// One page of travel: a slide and its gap (the deck and the fade page
    /// by the card itself).
    var pitch: CGFloat {
        switch block.layout {
        case CarouselFormat.layoutStack, CarouselFormat.layoutFade: return slideWidth
        default: return slideWidth + gap
        }
    }
    /// Where the current slide's leading edge sits: `start` at the leading
    /// edge (the next one peeks), `center` centred (both peek).
    var lead: CGFloat { block.align == CarouselFormat.alignStart ? 0 : (width - slideWidth) / CarouselFormat.half }
}

// MARK: - The carousel

struct FunnelCarouselView: View {
    let block: CarouselBlock
    let children: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.funnelCopy) private var copy
    @State private var width: CGFloat = 0
    @State private var index = 0
    /// The finger's sideways travel, physical points (+ is to the right) —
    /// DragGesture reports it unmirrored.
    @State private var drag: CGFloat = 0
    /// The drag's last two samples, for the release velocity (the fling).
    @State private var lastSample = CarouselDragSample.zero
    @State private var previousSample = CarouselDragSample.zero
    /// A finger is on the carousel: autoplay holds (any drag, a page
    /// scroll's included — it resets itself when the system takes it).
    @GestureState private var touching = false
    @State private var onScreen = false
    @State private var voiceOver = CarouselAccessibility.voiceOverRunning
    /// The app is in the foreground (UIKit's notifications: a hosted
    /// funnel's `scenePhase` is not always its window scene's).
    @State private var appActive = true
    /// The deck's thrown card, the fade's departure — owned by the layouts,
    /// driven from here so a dot, an arrow and autoplay page them too.
    @StateObject private var clock = CarouselClock()
    @StateObject private var deck = CarouselDeckState()

    private var count: Int { children.count }
    private var tokens: RenderCarouselLook { look.carousel }
    private var rtl: Bool { layoutDirection == .rightToLeft }
    private var geometry: CarouselGeometry { CarouselGeometry(width: width, block: block) }
    private var motion: CarouselMotion { CarouselMotion(block: block, look: look, reduced: reduceMotion) }
    private var layout: String { block.layout }
    private var indicator: RenderIndicator? { count > 1 ? block.indicator : nil }
    private var arrows: RenderArrows? { count > 1 ? block.arrows : nil }

    var body: some View {
        VStack(spacing: 0) {
            // The carousel's width, measured on a line of no height that
            // takes exactly what the column offers — never on the strip.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { width = $0 }
                })
            if layout == CarouselFormat.layoutMarquee {
                CarouselMarquee(block: block, children: children, look: look, interaction: interaction, width: width)
            } else {
                paging
            }
        }
        .funnelStyle(block.style, look.bodyType)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onVoiceOverChange { voiceOver = $0 }
        .onAppActiveChange { appActive = $0 }
        // Runs on appear and whenever a gate changes.
        .task(id: autoplayKey) { syncAutoplay() }
        .onChange(of: clock.ticks) { _ in autoplayTick() }
        .onChange(of: touching) { down in
            // The system took the finger (a page scroll): the strip goes home.
            if !down && drag != 0 { withAnimation(motion.move) { drag = 0 } }
        }
        .onChange(of: count) { _ in index = clamped(index) }
    }

    // MARK: Paging layouts

    private var paging: some View {
        let below = (indicator?.position == CarouselFormat.positionBelow) || (arrows?.position == CarouselFormat.arrowsBelow)
        return VStack(spacing: below ? CGFloat(tokens.indicatorMargin) : 0) {
            pager
                .padding(.vertical, CGFloat(block.bleed))
                // The clip reaches past the cards by `bleed`: an elevated
                // card's shadow and the deck's back cards are not cut (V1).
                .frame(width: width)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(TapGesture().onEnded { clock.stop() })
                // No container element of its own: inside one, the slides'
                // `accessibilityHidden` is not honoured. The position and
                // the adjustable action reach the exposed (current) slide.
                .ifLet(copy) { view, copy in
                    view.accessibilityValue(FunnelA11y.position(index + 1, of: count, copy: copy))
                }
                .accessibilityAdjustableAction { direction in
                    clock.stop()
                    switch direction {
                    case .increment: advance(by: 1)
                    case .decrement: advance(by: -1)
                    @unknown default: break
                    }
                }
                .overlay(alignment: overlayAlignment) { overlayIndicator }
                .overlay { overlayArrows }
            if below { belowRow }
        }
    }

    @ViewBuilder
    private var pager: some View {
        switch layout {
        case CarouselFormat.layoutStack:
            CarouselDeck(
                block: block, children: children, look: look, interaction: interaction, geometry: geometry,
                index: index, drag: drag, rtl: rtl, state: deck)
        case CarouselFormat.layoutFade:
            CarouselFade(
                block: block, children: children, look: look, interaction: interaction, width: width, index: index,
                motion: motion)
        default:
            strip
        }
    }

    /// `peek`, `paged` and `scale`: one row of slides moved by an offset.
    private var strip: some View {
        HStack(alignment: .top, spacing: geometry.gap) {
            ForEach(Array(children.enumerated()), id: \.offset) { i, child in
                let pose = scalePose(i)
                FunnelNodeView(node: child, look: look, interaction: interaction)
                    .modifier(CarouselCardFrame(card: block.card, tokens: tokens))
                    .frame(width: geometry.slideWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .scaleEffect(pose.scale)
                    .opacity(pose.opacity)
                    // Only the current slide plays (Spec D §4, P2); the
                    // others hold on their poster frame.
                    .environment(\.funnelPlaybackHeld, i != index)
                    .carouselHidden(i != index)
            }
        }
        // Every slide takes the tallest slide's height, so cards line up.
        .fixedSize(horizontal: false, vertical: true)
        .offset(x: stripOffset)
        // Exactly the measured width: the strip is wider than the carousel,
        // and a flexible frame would grow to it — and with it the measured
        // width, without end.
        .frame(width: width, alignment: .leading)
    }

    /// In layout coordinates: SwiftUI mirrors `.offset(x:)` under RTL by
    /// itself (+ is toward the trailing edge), while the finger's
    /// translation is physical — so only the drag is converted.
    private var stripOffset: CGFloat {
        geometry.lead - CGFloat(index) * geometry.pitch + logicalDrag
    }

    /// `scale`: a neighbour at `neighbourScale` / `neighbourOpacity`, both
    /// linear in its distance from the centre in pitches (clamped at one),
    /// following the finger — arithmetic, no per-slide measuring (P1).
    /// Reduce Motion draws the resting state only.
    private func scalePose(_ i: Int) -> (scale: CGFloat, opacity: Double) {
        guard layout == CarouselFormat.layoutScale, geometry.pitch > 0 else { return (1, 1) }
        let following = reduceMotion ? 0 : logicalDrag / geometry.pitch
        let distance = min(abs(CGFloat(i - index) + following), 1)
        let scale = 1 - (1 - CGFloat(tokens.neighbourScale) / CarouselFormat.percent) * distance
        let opacity = 1 - (1 - Double(tokens.neighbourOpacity) / Double(CarouselFormat.percent)) * Double(distance)
        return (scale, opacity)
    }

    /// The drag in layout coordinates (+ toward the trailing edge, i.e.
    /// toward the previous slide).
    private var logicalDrag: CGFloat { rtl ? -drag : drag }

    // MARK: Swipe

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: CGFloat(tokens.dragSlop))
            .updating($touching) { _, down, _ in down = true }
            .onChanged { value in
                // A drag that is mostly vertical is the page's scroll
                // passing over the carousel, not a swipe of it.
                guard clock.stopped || abs(value.translation.width) > abs(value.translation.height) else { return }
                clock.stop()
                previousSample = lastSample
                lastSample = CarouselDragSample(time: value.time, x: value.translation.width)
                // The fade's content does not follow the finger.
                if layout != CarouselFormat.layoutFade { drag = value.translation.width }
            }
            .onEnded { value in
                defer {
                    lastSample = .zero
                    previousSample = .zero
                }
                guard clock.stopped else { return }
                release(value)
            }
    }

    /// One page when the drag passed `swipeThreshold` of the pitch or the
    /// release was at least `flingVelocity` fast; never more than one
    /// (spec CL §4.5 — the same rule on every platform).
    private func release(_ value: DragGesture.Value) {
        let forward: CGFloat = rtl ? 1 : -1
        let moved = value.translation.width * forward
        let elapsed = value.time.timeIntervalSince(previousSample.time)
        let velocity = previousSample.time == .distantPast || elapsed <= 0
            ? 0 : (value.translation.width - previousSample.x) / CGFloat(elapsed) * forward
        let threshold = geometry.pitch * CGFloat(tokens.swipeThreshold) / CarouselFormat.percent
        var step = 0
        if abs(moved) >= threshold {
            step = moved > 0 ? 1 : -1
        } else if abs(velocity) >= CGFloat(tokens.flingVelocity) {
            step = velocity > 0 ? 1 : -1
        }
        if step != 0, canPage(by: step) {
            advance(by: step)
        } else {
            withAnimation(motion.move) { drag = 0 }
        }
    }

    // MARK: Paging

    private func canPage(by step: Int) -> Bool {
        block.looping || (0..<count).contains(index + step)
    }

    private func clamped(_ target: Int) -> Int {
        guard count > 0 else { return 0 }
        if block.looping { return (target % count + count) % count }
        return min(max(target, 0), count - 1)
    }

    /// One page on (+1) or back (−1): the deck throws or returns a card,
    /// the fade crossfades, the strip springs — `loop` rewinds the strip
    /// and cycles the deck (spec CL §4.6).
    private func advance(by step: Int) {
        guard canPage(by: step) else {
            withAnimation(motion.move) { drag = 0 }
            return
        }
        page(to: index + step)
    }

    /// Straight to `target` (a dot, an arrow, autoplay, a swipe).
    private func page(to target: Int) {
        let next = clamped(target)
        if layout == CarouselFormat.layoutStack {
            deck.move(
                from: index, to: next, count: count, looping: block.looping, drag: drag, rtl: rtl, geometry: geometry,
                tokens: tokens, motion: motion
            ) { index = next }
            drag = 0
            return
        }
        let animation = layout == CarouselFormat.layoutFade ? motion.fade : motion.move
        withAnimation(animation) {
            drag = 0
            index = next
        }
    }

    // MARK: Autoplay (spec CL §4.6, Spec D §4)

    /// Whether autoplay runs now: on screen, the app active, no finger on
    /// the carousel, never under Reduce Motion or VoiceOver. Interacting
    /// with this carousel stops it for good (`clock.stop()`).
    private var autoplayRuns: Bool {
        count > 1 && !reduceMotion && !voiceOver && onScreen && appActive && !touching
    }

    private var autoplayKey: String {
        "\(block.autoplayMs ?? 0)/\(autoplayRuns)"
    }

    /// The resolved time one page change takes to move — the fade's
    /// `fadeMs` for `fade` (it moves on `motion.fade`), the curve's
    /// `settleMs` for every other layout. Autoplay's dwell starts after it,
    /// as on the web (`plan.ts`) and Android (`surface.moveMs`, ledger P173).
    ///
    /// Ways it could fail (written before the code):
    ///   M1 fade keeps `curve.settleMs` → its cadence drifts from the web's and
    ///      Android's by `settleMs − fadeMs` per page;
    ///   M2 a non-fade layout picks up `fadeMs` → paged/scale/stack/peek drift
    ///      the other way;
    ///   M3 a drawer-private number stands in for either → only the two
    ///      resolved fields are read.
    private var moveMs: Int {
        layout == CarouselFormat.layoutFade ? block.fadeMs : block.curve.settleMs
    }

    private func syncAutoplay() {
        clock.sync(intervalMs: block.autoplayMs, moveMs: moveMs, runs: autoplayRuns)
    }

    private func autoplayTick() {
        // It stops at the last slide unless the carousel loops.
        guard block.looping || index < count - 1 else {
            clock.stop()
            return
        }
        page(to: index + 1)
    }

    // MARK: Indicator and arrows

    private var overlayAlignment: Alignment {
        indicator?.position == CarouselFormat.positionOverlayTop ? .top : .bottom
    }

    /// The indicator over the slides, `overlayInset` inside the pager's
    /// box (over the top card on a deck). Only its marks take taps (A3).
    @ViewBuilder
    private var overlayIndicator: some View {
        if let indicator, indicator.position != CarouselFormat.positionBelow {
            let inset = CGFloat(tokens.overlayInset)
            let stack = layout == CarouselFormat.layoutStack
            let side = (stack ? (width - geometry.slideWidth) / CarouselFormat.half : 0) + inset
            let top = indicator.position == CarouselFormat.positionOverlayTop
            indicatorRow(indicator, rowWidth: width - side * CarouselFormat.half)
                .padding(.horizontal, side)
                .padding(top ? .top : .bottom, CGFloat(block.bleed) + inset + (top || !stack ? 0 : CGFloat(block.deckExtra)))
        }
    }

    @ViewBuilder
    private var overlayArrows: some View {
        if let arrows, arrows.position == CarouselFormat.arrowsOverlay {
            let hit = CarouselArrowButton.hitSize(tokens)
            HStack(spacing: 0) {
                arrow(.previous, arrows)
                Spacer(minLength: 0)
                arrow(.next, arrows)
            }
            .padding(.horizontal, CGFloat(tokens.arrowInset) - (hit - CGFloat(tokens.arrowSize)) / CarouselFormat.half)
            // Centred on the top card: the deck's extra is below it.
            .padding(.bottom, layout == CarouselFormat.layoutStack ? CGFloat(block.deckExtra) : 0)
        }
    }

    /// Below the pager: the arrows at either end, the indicator between.
    private var belowRow: some View {
        let arrowsBelow = arrows?.position == CarouselFormat.arrowsBelow ? arrows : nil
        let hit = arrowsBelow == nil ? 0 : CarouselArrowButton.hitSize(tokens)
        return HStack(spacing: 0) {
            if let arrowsBelow { arrow(.previous, arrowsBelow) }
            Group {
                if let indicator, indicator.position == CarouselFormat.positionBelow {
                    indicatorRow(indicator, rowWidth: width - hit * CarouselFormat.half)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .frame(maxWidth: .infinity)
            if let arrowsBelow { arrow(.next, arrowsBelow) }
        }
    }

    private func indicatorRow(_ indicator: RenderIndicator, rowWidth: CGFloat) -> some View {
        CarouselIndicatorView(
            indicator: indicator, tokens: tokens, count: count, index: index, counterLabels: block.counterLabels,
            rowWidth: rowWidth, clock: clock, fade: motion.fade
        ) { target in
            clock.stop()
            page(to: target)
        }
    }

    private func arrow(_ kind: CarouselArrowButton.Kind, _ arrows: RenderArrows) -> some View {
        let shown = block.looping || (kind == .previous ? index > 0 : index < count - 1)
        return CarouselArrowButton(
            kind: kind, label: kind == .previous ? arrows.previousLabel : arrows.nextLabel, shown: shown,
            tokens: tokens, look: look, fade: motion.fade
        ) {
            clock.stop()
            advance(by: kind == .previous ? -1 : 1)
        }
    }
}

/// One drag sample: when, and the finger's sideways translation.
struct CarouselDragSample: Equatable {
    let time: Date
    let x: CGFloat
    static let zero = CarouselDragSample(time: .distantPast, x: 0)
}

// MARK: - VoiceOver

enum CarouselAccessibility {
    static var voiceOverRunning: Bool {
        #if canImport(UIKit)
            return UIAccessibility.isVoiceOverRunning
        #else
            return false
        #endif
    }
}

extension View {
    /// Hears VoiceOver turn on or off (it gates autoplay and the marquee).
    func onVoiceOverChange(_ action: @escaping (Bool) -> Void) -> some View {
        #if canImport(UIKit)
            return onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
                action(UIAccessibility.isVoiceOverRunning)
            }
        #else
            return self
        #endif
    }

    /// Hears the app leave and return to the foreground (autoplay and the
    /// marquee hold in the background, P3).
    func onAppActiveChange(_ action: @escaping (Bool) -> Void) -> some View {
        #if canImport(UIKit)
            return onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                action(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                action(false)
            }
        #else
            return self
        #endif
    }
}

extension View {
    /// Hidden from assistive tech while `hidden`: a slide that is not
    /// current, a depth card, an arrow at the end (A1). It holds only while
    /// no ancestor writes an explicit `accessibilityHidden(false)` (which
    /// wins) — the element-motion wrapper writes `true` only while exiting.
    /// What is ALWAYS hidden uses `carouselNeverExposed()`.
    func carouselHidden(_ hidden: Bool) -> some View {
        accessibilityHidden(hidden)
    }

    /// Never reaches assistive tech, whatever an ancestor says: its
    /// accessibility is replaced by nothing. For views that are hidden for
    /// their whole life (marquee copies after the first, the counter), so
    /// no identity ever changes.
    func carouselNeverExposed() -> some View {
        accessibilityRepresentation { EmptyView() }
    }
}
