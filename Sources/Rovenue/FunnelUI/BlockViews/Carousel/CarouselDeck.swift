//  CarouselDeck.swift — `stack` (spec CL §4.1, §8.2): a deck. The top card
//  is centred at `itemWidth`; up to `stackDepth` cards sit behind it, each
//  `stackOffset` lower and `stackScaleStep` smaller per level, every card
//  anchored at its top centre so the depth cards peek out below. The frame
//  is the card's height; the depth cards' `deckExtra` (= depth × offset)
//  lives in `bleed`, the pager's padded clip, so they are never cut (V1).
//
//  A swipe throws the top card toward the swipe side by `throwDistance`
//  (percent of the card) with a `throwTilt` tilt; with `loop` it rejoins
//  the back of the deck, without it the last card stays and a swipe springs
//  back. Cards deeper than the depth are not built, so no video mounts in
//  them (P2). Only the top card is exposed to assistive tech (A1).

import SwiftUI

/// The card in flight and the card coming back — the deck's own motion,
/// driven by FunnelCarouselView so a dot, an arrow and autoplay throw too.
@MainActor
final class CarouselDeckState: ObservableObject {
    /// A card leaving the top: which slide, where it is, how far it tilts.
    struct Flight: Equatable {
        let child: Int
        var x: CGFloat
        var tilt: Double
    }

    @Published private(set) var thrown: Flight?
    /// The top card's own travel while it comes back from a backward swipe.
    @Published private(set) var returning: CGFloat = 0
    private var flight = 0

    /// Moves the deck from `from` to `to`, committing the new top through
    /// `commit`. Forward throws the old top card; backward brings the new
    /// top card back in from where it was thrown. Reduce Motion swaps.
    func move(
        from: Int, to: Int, count: Int, looping: Bool, drag: CGFloat, rtl: Bool, geometry: CarouselGeometry,
        tokens: RenderCarouselLook, motion: CarouselMotion, commit: @escaping () -> Void
    ) {
        guard from != to else {
            withAnimation(motion.move) { returning = 0 }
            return
        }
        let forward = Self.isForward(from: from, to: to, count: count, looping: looping)
        // The swipe's side, or — paged by a control — the leading edge.
        let leading: CGFloat = rtl ? 1 : -1
        let side: CGFloat = drag == 0 ? (forward ? leading : -leading) : (drag > 0 ? 1 : -1)
        let distance = geometry.slideWidth * CGFloat(tokens.throwDistance) / CarouselFormat.percent
        guard let animation = motion.move else {
            thrown = nil
            returning = 0
            commit()
            return
        }
        flight += 1
        let current = flight
        let still = Transaction(animation: nil)
        if forward {
            withTransaction(still) {
                thrown = Flight(child: from, x: drag, tilt: Self.tilt(drag, distance: distance, tokens: tokens))
            }
            // The cards behind rise into place on the same spring.
            withAnimation(animation) { commit() }
            DispatchQueue.main.async {
                withAnimation(animation) {
                    self.thrown?.x = side * distance
                    self.thrown?.tilt = Double(side) * Double(tokens.throwTilt)
                }
            }
            let settle = Double(motion.block.curve.settleMs) / CarouselFormat.millisecondsPerSecond
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                if self.flight == current { self.thrown = nil }
            }
        } else {
            withTransaction(still) {
                thrown = nil
                returning = drag == 0 ? side * distance : drag
            }
            withAnimation(animation) { commit() }
            DispatchQueue.main.async {
                withAnimation(animation) { self.returning = 0 }
            }
        }
    }

    /// Forward is the next card — the wrap included when the deck cycles.
    private static func isForward(from: Int, to: Int, count: Int, looping: Bool) -> Bool {
        if looping && count > 1 {
            let ahead = (to - from + count) % count
            return ahead <= count / 2
        }
        return to > from
    }

    /// The tilt that goes with `x` of travel: `throwTilt` at the full throw,
    /// toward the side it moves (clockwise to the right).
    static func tilt(_ x: CGFloat, distance: CGFloat, tokens: RenderCarouselLook) -> Double {
        guard distance > 0 else { return 0 }
        let share = max(-1, min(1, x / distance))
        return Double(share) * Double(tokens.throwTilt)
    }
}

struct CarouselDeck: View {
    let block: CarouselBlock
    let children: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction
    let geometry: CarouselGeometry
    let index: Int
    /// The finger's travel on the top card, physical points (+ right).
    let drag: CGFloat
    let rtl: Bool
    @ObservedObject var state: CarouselDeckState

    private var tokens: RenderCarouselLook { look.carousel }

    /// One drawn card.
    private struct Layer: Identifiable {
        let child: Int
        let level: Int
        let x: CGFloat
        let tilt: Double
        let z: Double
        var id: Int { child }
        var top: Bool { level == 0 }
    }

    /// The top card, the depth cards behind it, and the card in flight.
    private var layers: [Layer] {
        let count = children.count
        guard count > 0 else { return [] }
        let distance = geometry.slideWidth * CGFloat(tokens.throwDistance) / CarouselFormat.percent
        let depth = min(tokens.stackDepth, count - 1)
        var out: [Layer] = []
        for level in 0...max(depth, 0) {
            let raw = index + level
            guard block.looping || raw < count else { break }
            let child = raw % count
            if child == state.thrown?.child { continue }
            let x = level == 0 ? drag + state.returning : 0
            out.append(Layer(
                child: child, level: level, x: x,
                tilt: level == 0 ? CarouselDeckState.tilt(x, distance: distance, tokens: tokens) : 0,
                z: Double(depth - level)))
        }
        if let thrown = state.thrown {
            out.append(Layer(child: thrown.child, level: -1, x: thrown.x, tilt: thrown.tilt, z: Double(depth + 1)))
        }
        return out.sorted { $0.z < $1.z }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(layers) { layer in
                let level = CGFloat(max(layer.level, 0))
                let scale = 1 - level * CGFloat(tokens.stackScaleStep) / CarouselFormat.percent
                FunnelNodeView(node: children[layer.child], look: look, interaction: interaction)
                    .modifier(CarouselCardFrame(card: block.card, tokens: tokens))
                    .frame(width: geometry.slideWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // Scaled and tilted about the card's top centre (§4.1).
                    .scaleEffect(scale, anchor: .top)
                    // Travel and tilt are physical; SwiftUI mirrors both
                    // effects under RTL, so they are handed over mirrored.
                    .rotationEffect(.degrees(rtl ? -layer.tilt : layer.tilt), anchor: .top)
                    .offset(x: rtl ? -layer.x : layer.x, y: level * CGFloat(tokens.stackOffset))
                    .zIndex(layer.z)
                    .environment(\.funnelPlaybackHeld, !layer.top)
                    .carouselHidden(!layer.top)
                    .allowsHitTesting(layer.top)
            }
        }
        // Every card takes the tallest drawn card's height. The depth cards'
        // extra (`deckExtra`) is not laid out: the resolver folds it into
        // `bleed`, the pager's padded clip (spec CL §14 finding 3).
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: geometry.width)
    }
}
