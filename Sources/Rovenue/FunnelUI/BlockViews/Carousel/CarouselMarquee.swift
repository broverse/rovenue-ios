//  CarouselMarquee.swift — `marquee` (spec CL §4.1, §7, §8.1–8.2): a
//  continuous ticker of `itemWidth`-wide items, `gap` apart, drifting at
//  `marquee.pxPerS`. No paging, no indicator, no arrows.
//
//  The strip is `copies = ceil(viewport / copyWidth) + 1` copies of the
//  items, each copy carrying ONE trailing gap per item (so the wrap has no
//  half-gap seam, F3). A `TimelineView` drives the phase,
//  `(elapsed × pxPerS) mod copyWidth`; the strip moves by exactly one copy
//  width per cycle, so the wrap is invisible. Pausing (the button, a tap
//  on the strip, off screen, the app in the background, VoiceOver) keeps
//  the elapsed time, so it resumes where it stopped (A2, P3).
//
//  `forward` moves content from the trailing edge toward the leading edge;
//  RTL mirrors the physical drift. Only the first copy is exposed to
//  assistive tech — as a list with "n of m" values; every other copy is
//  hidden and takes no touch (A1). Reduce Motion draws the first copy as a
//  static row that scrolls by hand (A4).

import SwiftUI

struct CarouselMarquee: View {
    let block: CarouselBlock
    let children: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction
    let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.funnelCopy) private var copy
    @State private var paused = false
    @State private var onScreen = false
    @State private var voiceOver = CarouselAccessibility.voiceOverRunning
    /// The app is in the foreground (UIKit's notifications: a hosted
    /// funnel's `scenePhase` is not always its window scene's).
    @State private var appActive = true
    /// The drift's time, kept in the TimelineView's own clock (see `DriftClock`).
    @State private var drift = DriftClock()

    private static let pauseGlyph = "pause.fill"
    private static let playGlyph = "play.fill"

    private var tokens: RenderCarouselLook { look.carousel }
    private var itemWidth: CGFloat { width * CGFloat(block.itemWidth) / CarouselFormat.percent }
    private var gap: CGFloat { CGFloat(block.gap) }
    /// One copy: every item and its trailing gap.
    private var copyWidth: CGFloat { CGFloat(children.count) * (itemWidth + gap) }
    private var copies: Int {
        guard copyWidth > 0 else { return 1 }
        return Int((width / copyWidth).rounded(.up)) + 1
    }
    private var pxPerS: Double { Double(block.marquee?.pxPerS ?? 0) }
    private var moving: Bool { !reduceMotion && width > 0 && copyWidth > 0 && pxPerS > 0 }
    private var runs: Bool { moving && !paused && onScreen && appActive && !voiceOver }

    var body: some View {
        Group {
            if moving {
                drifting
            } else {
                // The still row keeps the drift's `bleed` above and below,
                // inside the scroll view's clip: card shadows are drawn and
                // the block is as tall as the drifting strip (web, Android).
                ScrollView(.horizontal, showsIndicators: false) {
                    copyRow(0).padding(.vertical, CGFloat(block.bleed))
                }
                .frame(width: width)
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onVoiceOverChange { voiceOver = $0 }
        .onAppActiveChange { appActive = $0 }
        .onChange(of: runs) { running in
            if running { drift.resume() } else { drift.pause() }
        }
    }

    private var drifting: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !runs)) { context in
            HStack(spacing: 0) {
                ForEach(0..<copies, id: \.self) { c in copyView(c) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .offset(x: offset(at: context.date))
            .frame(width: width, alignment: .leading)
        }
        .padding(.vertical, CGFloat(block.bleed))
        .frame(width: width)
        .clipped()
        .contentShape(Rectangle())
        // A tap on the strip toggles it too (§7).
        .onTapGesture { paused.toggle() }
        .accessibilityElement(children: .contain)
        .overlay(alignment: .trailing) { pauseButton }
    }

    /// Where the strip sits: one copy width of travel per cycle.
    private func offset(at date: Date) -> CGFloat {
        let elapsed = drift.elapsed(at: date)
        let phase = CGFloat((elapsed * pxPerS).truncatingRemainder(dividingBy: Double(copyWidth)))
        let forward = block.marquee?.direction != CarouselFormat.directionBackward
        // Layout coordinates (+ toward the trailing edge): SwiftUI mirrors
        // the offset under RTL, so `forward` drifts left-to-right there.
        return forward ? -phase : phase - copyWidth
    }

    /// One copy of the items, each followed by its gap.
    private func copyRow(_ c: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.offset) { i, child in
                FunnelNodeView(node: child, look: look, interaction: interaction)
                    .modifier(CarouselCardFrame(card: block.card, tokens: tokens))
                    .frame(width: itemWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .accessibilityElement(children: .combine)
                    .ifLet(copy) { view, copy in
                        view.accessibilityValue(FunnelA11y.position(i + 1, of: children.count, copy: copy))
                    }
                    .padding(.trailing, gap)
            }
        }
        .allowsHitTesting(c == 0)
    }

    /// Copies after the first are decoration: never exposed, inert, and so
    /// carry no second identifier (A1). A copy's index never changes, so
    /// neither does its branch.
    @ViewBuilder
    private func copyView(_ c: Int) -> some View {
        if c == 0 {
            copyRow(c)
        } else {
            copyRow(c).carouselNeverExposed()
        }
    }

    private var pauseButton: some View {
        let size = CGFloat(tokens.pauseSize)
        let hit = CGFloat(max(tokens.pauseSize, MIN_TOUCH_TARGET))
        return Button { paused.toggle() } label: {
            Image(systemName: paused ? Self.playGlyph : Self.pauseGlyph)
                .font(.system(size: size * CarouselFormat.glyphShare))
                .foregroundColor(look.textColor)
                .frame(width: size, height: size)
                .background(Circle().fill(look.cardColor))
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(paused ? (block.marquee?.playLabel ?? "") : (block.marquee?.pauseLabel ?? ""))
        // Where an arrow's circle would sit: `arrowInset` from the edge.
        .padding(.trailing, CGFloat(tokens.arrowInset) - (hit - size) / CarouselFormat.half)
    }
}

/// The marquee's elapsed drift, read in ONE time base: the dates the
/// TimelineView draws (`context.date`). On iOS 16–17 an `.animation`
/// timeline's date is the frame's presentation time, ~2 frames ahead of
/// `Date()`; a pause read off the wall clock then held the strip behind
/// the last drawn frame and the resume jumped ahead of it (CL E6). So the
/// pause keeps the last DRAWN date, and a resume anchors on the first
/// drawn date after it (that frame shows the held phase). A reference
/// type: it is written while drawing, which must not invalidate the view.
///
/// Ways it could fail (written before the code): the paused timeline's
/// stale date, redrawn on the resume, anchors it (→ a jump by the whole
/// pause; only a date newer than the last drawn one anchors); a state
/// write per frame re-renders the strip (a class, never published).
private final class DriftClock {
    /// Drift time before the last pause, seconds.
    private var accumulated: TimeInterval = 0
    /// The drawn date the current run is counted from; nil while paused.
    private var anchor: Date?
    /// Resumed, not yet anchored on a drawn frame.
    private var pending = false
    /// The last date drawn.
    private var lastDrawn: Date?

    func elapsed(at date: Date) -> TimeInterval {
        if pending, lastDrawn.map({ date > $0 }) ?? true {
            anchor = date
            pending = false
        }
        lastDrawn = date
        guard let anchor else { return accumulated }
        return accumulated + max(0, date.timeIntervalSince(anchor))
    }

    func resume() {
        pending = true
    }

    func pause() {
        pending = false
        if let anchor, let lastDrawn { accumulated += max(0, lastDrawn.timeIntervalSince(anchor)) }
        anchor = nil
    }
}
