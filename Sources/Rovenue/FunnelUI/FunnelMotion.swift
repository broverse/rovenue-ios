//  FunnelMotion.swift — page transitions, element enters, exits and the
//  pulse (spec 2026-10-19-funnel-motion), drawn from the tree's values.
//
//  Every NUMBER comes from `RenderLook.motion` (`look.rs`) or a block's
//  resolved `RenderMotion`. This file keeps unit conversions only: the
//  crate writes durations in milliseconds, scales and shares in percent and
//  bezier control points in thousandths, and SwiftUI wants seconds and
//  fractions. It mirrors the web drawer's `motion/` module (funnel-renderer)
//  so the platforms agree:
//
//  - A page transition keeps the page being left drawn as an inert layer
//    and moves both layers by the table in `funnelTransitionPlan`; back is
//    the spatial mirror of the transition the step reports. Travel and
//    scale ride the `smooth` spring, opacity the fade curve.
//  - An element ENTERS when its page appears (from `enterAtPercent` into
//    the transition, after its own delay, cascade folded in by the crate)
//    and when it is revealed on a page already showing (at once); it EXITS
//    when hidden on the same page (kept drawn by `FunnelPresence` until the
//    exit ends) and when its page is left (fitted inside the transition).
//  - The PULSE starts once the enter has settled, three cycles, then stops.
//  - Reduced motion: every transition but `none` is a fast cross-fade; an
//    enter or exit is opacity only at the fast duration with no delay; no
//    pulse. End states are always reached.
//
//  Geometry is written left-to-right with +x toward the TRAILING edge:
//  SwiftUI mirrors offsets and geometry effects under a right-to-left
//  `layoutDirection`. It does NOT mirror a clip shape's path (the example
//  app's RTL recording, e2e/live/funnel-motion-native.mjs N6, showed the
//  push keeping the left part of the page being left), so `FunnelUncovered`
//  is the one piece that reads the direction.

import SwiftUI

// MARK: - Units

/// The only constants this file keeps: how the crate spells its units.
private enum MotionUnits {
    static let millisecondsPerSecond = 1000.0
    static let percent = 100.0
    static let thousandths = 1000.0
    /// A cubic bezier's four control points, x1 y1 x2 y2.
    static let bezierPoints = 4
    static let restingScale: CGFloat = 1
    static let opaque = 1.0
    static let invisible = 0.0
    /// Half of a pulse cycle goes up, the other half comes back.
    static let half = 0.5
    /// The least opacity that still takes a touch: SwiftUI, like UIKit
    /// (`alpha <= 0.01`), delivers none to a view drawn at (or under)
    /// 0.01, so a page fading in from 0 or a control waiting for its enter
    /// is drawn at this instead of 0 — invisible to the eye, live to the
    /// finger (the incoming page is interactive from its first frame).
    static let hitTestableOpacity = 0.011
    /// One display frame at 60 Hz, ms: while a transition starts up, a gap
    /// between its clock's ticks longer than this was the incoming page's
    /// first layout and render, not motion on screen.
    static let frameMs = millisecondsPerSecond / 60
    /// How many of a transition's first ticks may move its clock's origin.
    static let startupTicks = 3
}

private func seconds(_ ms: Int) -> Double { Double(ms) / MotionUnits.millisecondsPerSecond }
private func fraction(_ percent: Int) -> Double { Double(percent) / MotionUnits.percent }

// MARK: - Modes, navigation and the screen's motion

/// What plays once the device has had its say — the web's `ActiveMotion`.
enum FunnelMotionMode: Equatable {
    case full
    /// iOS Reduce Motion or Prefer Cross-Fade Transitions.
    case reduced
}

/// The page transitions — `look::PAGE_TRANSITIONS` (wire names).
enum FunnelPageTransition {
    static let none = "none"
    static let push = "push"
    static let slide = "slide"
    static let lift = "lift"
    static let fade = "fade"
    static let fadeThrough = "fade_through"
    /// The ones this drawer animates; any other value cuts.
    static let animated: Set<String> = [push, slide, lift, fade, fadeThrough]
}

/// How the page on screen was reached: the step's direction and the
/// transition it plays. On a BACK step the transition is the one that
/// brought the visitor to the page being left, played mirrored — never
/// the destination's own `RenderScreen.transition`.
struct FunnelNavigation: Equatable {
    let direction: FunnelDirection
    let transition: String

    /// The first screen, and any step that did not move: a cut.
    static let still = FunnelNavigation(direction: .still, transition: FunnelPageTransition.none)

    var isBack: Bool { direction == .back }
}

/// Set once a screen's first frame is up. A node that appears while it is
/// false is part of the page APPEARING (page offset, delay and cascade
/// apply); one that appears after was REVEALED on a page already showing
/// and enters at once. A class so the flag is shared, not copied.
final class FunnelAppearance {
    var appeared = false
}

/// What one drawn screen may animate — the web's `ScreenMotion`.
struct FunnelScreenMotion: Equatable {
    let tokens: RenderMotionTokens
    let mode: FunnelMotionMode
    /// When this page's element enters start on its first frame, ms.
    let enterOffsetMs: Int
    /// Non-nil while the page is the one being LEFT: how long the outgoing
    /// transition runs. An exit plays inside it.
    let leavingMs: Int?
    let appearance: FunnelAppearance

    static func == (a: FunnelScreenMotion, b: FunnelScreenMotion) -> Bool {
        a.tokens == b.tokens && a.mode == b.mode && a.enterOffsetMs == b.enterOffsetMs
            && a.leavingMs == b.leavingMs && a.appearance === b.appearance
    }
}

private struct FunnelScreenMotionKey: EnvironmentKey {
    /// nil: nothing animates — a view drawn outside a funnel screen (a
    /// preview, a test host) draws every element at rest.
    static let defaultValue: FunnelScreenMotion? = nil
}

/// A video inside an element that is still entering: its poster moves and
/// playback waits for the enter to end (spec "Element animations").
private struct FunnelPlaybackHeldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var funnelScreenMotion: FunnelScreenMotion? {
        get { self[FunnelScreenMotionKey.self] }
        set { self[FunnelScreenMotionKey.self] = newValue }
    }

    var funnelPlaybackHeld: Bool {
        get { self[FunnelPlaybackHeldKey.self] }
        set { self[FunnelPlaybackHeldKey.self] = newValue }
    }
}

// MARK: - Tokens as SwiftUI animations

extension RenderMotionTokens {
    /// A cubic-bezier animation from four control points in thousandths.
    fileprivate func curve(_ points: [Int], durationMs: Int, delayMs: Int = 0) -> Animation {
        let duration = seconds(durationMs)
        let base: Animation
        if points.count == MotionUnits.bezierPoints {
            let p = points.map { Double($0) / MotionUnits.thousandths }
            base = .timingCurve(p[0], p[1], p[2], p[3], duration: duration)
        } else {
            base = .linear(duration: duration)
        }
        return base.delay(seconds(delayMs))
    }

    /// Opacity on the way in and every cross-fade.
    fileprivate func fade(_ durationMs: Int, delayMs: Int = 0) -> Animation {
        curve(fadeCurve, durationMs: durationMs, delayMs: delayMs)
    }

    /// An element's exit, opacity and travel alike.
    fileprivate func exit(_ durationMs: Int) -> Animation {
        curve(exitCurve, durationMs: durationMs)
    }

    /// `percent` of `value`, rounded — the tree's shares.
    fileprivate func share(_ value: Int, _ percent: Int) -> Int {
        Int((Double(value) * fraction(percent)).rounded())
    }

    /// A reduced-motion exit: the fast duration at the exit share.
    fileprivate var reducedExitMs: Int { share(fastMs, exitPercent) }

    /// When a page's element enters start, ms after its transition does —
    /// `look::enter_offset_ms`: `enterAtPercent` of `pageMs` under full
    /// motion when a transition plays, else at once.
    func enterOffsetMs(plays: Bool, mode: FunnelMotionMode) -> Int {
        mode == .full && plays ? share(pageMs, enterAtPercent) : 0
    }
}

extension RenderSpring {
    /// Where this spring is, 0 → 1, `ms` after it starts from rest — the
    /// damped oscillator (mass 1) SwiftUI's `.spring(response:
    /// dampingFraction:)` and the crate's sampled CSS easing both run:
    /// natural frequency 2π / response, damping ratio in percent.
    func value(atMs ms: Double) -> Double {
        let t = ms / MotionUnits.millisecondsPerSecond
        let omega = 2 * Double.pi / seconds(responseMs)
        let zeta = fraction(dampingRatio)
        if zeta < 1 {
            let damped = omega * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
        }
        if zeta == 1 {
            return 1 - exp(-omega * t) * (1 + omega * t)
        }
        let root = (zeta * zeta - 1).squareRoot()
        let r1 = -omega * (zeta - root)
        let r2 = -omega * (zeta + root)
        return 1 - (r2 * exp(r1 * t) - r1 * exp(r2 * t)) / (r2 - r1)
    }

    /// The spring SwiftUI runs: its response and damping ratio, mass 1 —
    /// the same physics the crate sampled for the web.
    fileprivate func animation(delayMs: Int = 0) -> Animation {
        .spring(response: seconds(responseMs), dampingFraction: fraction(dampingRatio), blendDuration: 0)
            .delay(seconds(delayMs))
    }
}

/// The enter preset that rides the fade curve alone.
private let enterFade = "fade"

extension RenderEnter {
    /// When the enter has finished moving, ms after it starts —
    /// `look::enter_settle_ms`.
    fileprivate var settleMs: Int {
        preset == enterFade ? durationMs : max(durationMs, spring.settleMs)
    }
}

// MARK: - Page transitions

/// Where a page layer is, relative to rest.
struct FunnelPagePose: Equatable {
    /// Travel as a fraction of the layer's width; + is the trailing edge.
    var shift: CGFloat = 0
    var x: CGFloat = 0
    var y: CGFloat = 0
    var opacity: Double = MotionUnits.opaque
    var scale: CGFloat = MotionUnits.restingScale
    /// The push's black wash over the page underneath.
    var wash: Double = MotionUnits.invisible
    /// The share of the width, from the trailing edge, the page on top
    /// already covers — the page underneath is clipped there, so a page
    /// with no backdrop of its own never shows through the one sliding in.
    var covered: CGFloat = 0

    static let rest = FunnelPagePose()
}

/// One animation's timing.
enum FunnelTiming: Equatable {
    case spring(RenderSpring, delayMs: Int)
    case curve([Int], durationMs: Int, delayMs: Int)

    /// How far along it is, 0 → 1, `ms` after the navigation started: held
    /// at 0 through its delay, at 1 once it has ended.
    func progress(atMs ms: Double) -> Double {
        switch self {
        case .spring(let spring, let delay):
            let t = ms - Double(delay)
            guard t > 0 else { return 0 }
            return t >= Double(spring.settleMs) ? 1 : spring.value(atMs: t)
        case .curve(let points, let duration, let delay):
            let t = ms - Double(delay)
            guard t > 0 else { return 0 }
            guard t < Double(duration), duration > 0 else { return 1 }
            let x = t / Double(duration)
            return FunnelCubicBezier(thousandths: points)?.y(atX: x) ?? x
        }
    }

    /// When it ends, ms after it starts — a spring when it settles.
    var endMs: Int {
        switch self {
        case .spring(let spring, let delay): return spring.settleMs + delay
        case .curve(_, let duration, let delay): return duration + delay
        }
    }
}

/// One layer's move: from a pose to another, each property on its timing.
struct FunnelLayerMotion: Equatable {
    var from: FunnelPagePose = .rest
    var to: FunnelPagePose = .rest
    /// Travel, wash and clip.
    var move: FunnelTiming?
    var fade: FunnelTiming?
    var grow: FunnelTiming?

    var endMs: Int { [move, fade, grow].compactMap { $0?.endMs }.max() ?? 0 }
}

/// A navigation's two layers.
struct FunnelTransitionPlan: Equatable {
    var incoming = FunnelLayerMotion()
    var outgoing = FunnelLayerMotion()
    /// Forward the new page slides over; back the page left slides off the top.
    var incomingOnTop: Bool
    var totalMs: Int { max(incoming.endMs, outgoing.endMs) }
}

/// The plan a navigation plays, or nil for a cut: it did not move, it
/// names a transition this drawer does not animate, or it is `none`. The
/// table is the web's `planTransition` (spec "Page transitions").
func funnelTransitionPlan(
    _ navigation: FunnelNavigation, mode: FunnelMotionMode, tokens t: RenderMotionTokens
) -> FunnelTransitionPlan? {
    guard navigation.direction != .still, FunnelPageTransition.animated.contains(navigation.transition)
    else { return nil }
    let back = navigation.isBack
    var plan = FunnelTransitionPlan(incomingOnTop: !back)
    let fadeIn = { (ms: Int, delay: Int) -> FunnelTiming in .curve(t.fadeCurve, durationMs: ms, delayMs: delay) }
    let smooth = FunnelTiming.spring(t.smooth, delayMs: 0)
    let invisible = FunnelPagePose(opacity: MotionUnits.invisible)

    if mode == .reduced {
        plan.incoming = FunnelLayerMotion(from: invisible, fade: fadeIn(t.fastMs, 0))
        plan.outgoing = FunnelLayerMotion(to: invisible, fade: fadeIn(t.fastMs, 0))
        return plan
    }

    switch navigation.transition {
    case FunnelPageTransition.push:
        let under = -CGFloat(fraction(t.pushPercent))
        let covered = 1 - CGFloat(fraction(t.pushPercent))
        let underneath = FunnelPagePose(shift: under, wash: fraction(t.pushDim), covered: covered)
        let offscreen = FunnelPagePose(shift: 1)
        if back {
            plan.outgoing = FunnelLayerMotion(to: offscreen, move: smooth)
            plan.incoming = FunnelLayerMotion(from: underneath, move: smooth)
        } else {
            plan.incoming = FunnelLayerMotion(from: offscreen, move: smooth)
            plan.outgoing = FunnelLayerMotion(to: underneath, move: smooth)
        }
    case FunnelPageTransition.slide:
        let d = CGFloat(t.pageDistance) * (back ? -1 : 1)
        plan.incoming = FunnelLayerMotion(
            from: FunnelPagePose(x: d, opacity: MotionUnits.invisible), move: smooth,
            fade: fadeIn(t.pageMs, 0))
        plan.outgoing = FunnelLayerMotion(
            to: FunnelPagePose(x: -d, opacity: MotionUnits.invisible), move: smooth,
            fade: fadeIn(t.pageMs, 0))
    case FunnelPageTransition.lift:
        let below = CGFloat(t.pageDistance)
        if back {
            plan.incoming = FunnelLayerMotion(from: invisible, fade: fadeIn(t.pageMs, 0))
            plan.outgoing = FunnelLayerMotion(
                to: FunnelPagePose(y: below, opacity: MotionUnits.invisible), move: smooth,
                fade: fadeIn(t.pageMs, 0))
        } else {
            plan.incoming = FunnelLayerMotion(
                from: FunnelPagePose(y: below, opacity: MotionUnits.invisible), move: smooth,
                fade: fadeIn(t.pageMs, 0))
            plan.outgoing = FunnelLayerMotion(to: invisible, fade: fadeIn(t.pageMs, 0))
        }
    case FunnelPageTransition.fade:
        plan.incoming = FunnelLayerMotion(from: invisible, fade: fadeIn(t.normalMs, 0))
        plan.outgoing = FunnelLayerMotion(to: invisible, fade: fadeIn(t.normalMs, 0))
    case FunnelPageTransition.fadeThrough:
        let split = t.share(t.pageMs, t.fadeThroughSplit)
        plan.outgoing = FunnelLayerMotion(to: invisible, fade: fadeIn(split, 0))
        plan.incoming = FunnelLayerMotion(
            from: FunnelPagePose(opacity: MotionUnits.invisible, scale: CGFloat(fraction(t.fadeThroughScale))),
            fade: fadeIn(t.pageMs - split, split),
            grow: .spring(t.smooth, delayMs: split))
    default:
        return nil
    }
    return plan
}

/// The clock one navigation's layers share: both page layers, the leaving
/// backdrop and the drop of the page being left read it, so they move on
/// one timeline.
///
/// It is STAMPED when a navigation's layers appear (`onAppear` /
/// `onChange(of: serial)`), and it starts for real when the incoming page
/// is first ON SCREEN: over its first few `TimelineView` ticks, any gap
/// longer than a frame — since the stamp, or between two ticks — was spent
/// laying out and rendering the new page, not showing it, and the origin
/// moves forward by it. Without that, a page slow to lay out or draw the
/// first time shows its first frame already partway through the travel.
/// (Android's ValueAnimator shifts its start for a slow first frame the
/// same way; the web's WAAPI starts after the layout frame.) A class, so a
/// tick can rebase it while drawing.
final class FunnelTransitionClock {
    private var serial: Int?
    private var origin = Date()
    /// The last tick (or the stamp) the clock saw, and how many ticks so far.
    private var last = Date()
    private var ticks = 0

    /// The navigation `serial`'s layers appeared now. Only the first call
    /// for a serial counts.
    func stamp(_ serial: Int) {
        guard self.serial != serial else { return }
        self.serial = serial
        origin = Date()
        last = origin
        ticks = 0
    }

    /// ms since `serial` started, read by a tick drawing the frame at
    /// `date`; nil until the serial's layers have appeared.
    func elapsedMs(_ serial: Int, drawingAt date: Date) -> Double? {
        guard self.serial == serial else { return nil }
        if date > last {
            if ticks < MotionUnits.startupTicks {
                let gapMs = date.timeIntervalSince(last) * MotionUnits.millisecondsPerSecond
                if gapMs > MotionUnits.frameMs {
                    origin = origin.addingTimeInterval((gapMs - MotionUnits.frameMs) / MotionUnits.millisecondsPerSecond)
                }
            }
            ticks += 1
            last = date
        }
        return max(0, date.timeIntervalSince(origin) * MotionUnits.millisecondsPerSecond)
    }

    /// ms since `serial` started, as of now — for the drop timer, which
    /// waits out a rebased clock rather than a fixed delay. A serial this
    /// clock never ran has nothing to wait for.
    func elapsedMs(_ serial: Int, now: Date) -> Double {
        guard self.serial == serial else { return .infinity }
        return now.timeIntervalSince(origin) * MotionUnits.millisecondsPerSecond
    }
}

/// Moves one page layer from its plan's `from` pose to its `to` pose,
/// computed per frame from the navigation's clock rather than handed to
/// SwiftUI's animator. That is what makes a navigation during a transition
/// SNAP the running one (spec "Page transitions", the web's interrupt): a
/// new `serial` restarts the clock, and the pose is the new plan's at zero
/// — nothing in flight carries over. nil motion holds the layer at rest and
/// pauses the clock.
///
/// The page's own content is the modifier's `content`, so a frame
/// re-evaluates only the pose, never the blocks.
struct FunnelPageLayer: ViewModifier {
    let motion: FunnelLayerMotion?
    let serial: Int
    let clock: FunnelTransitionClock
    /// The page a visitor can tap (not the one being left): it never draws
    /// below the hit-testable opacity, so a tap while it fades in lands.
    let interactive: Bool
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: motion == nil)) { timeline in
            let pose = pose(at: timeline.date)
            content
                .overlay(Color.black.opacity(pose.wash).ignoresSafeArea().allowsHitTesting(false))
                .clipShape(FunnelUncovered(covered: pose.covered, rightToLeft: layoutDirection == .rightToLeft))
                .scaleEffect(pose.scale)
                .modifier(FunnelShift(fraction: pose.shift, x: pose.x, y: pose.y))
                .opacity(interactive ? max(pose.opacity, MotionUnits.hitTestableOpacity) : pose.opacity)
        }
        .onAppear { clock.stamp(serial) }
        // The NEW serial is the argument: the closure itself may still see
        // the previous render's properties.
        .onChange(of: serial) { clock.stamp($0) }
    }

    private func pose(at date: Date) -> FunnelPagePose {
        guard let motion else { return .rest }
        // Until this navigation's clock starts, the layer waits at `from`.
        guard let ms = clock.elapsedMs(serial, drawingAt: date) else { return motion.from }
        return motion.pose(atMs: ms)
    }
}

extension FunnelLayerMotion {
    /// The pose `ms` after the navigation started: each property group
    /// eased by its own timing; a group with no timing is already at `to`.
    func pose(atMs ms: Double) -> FunnelPagePose {
        let move = CGFloat(self.move?.progress(atMs: ms) ?? 1)
        let fade = self.fade?.progress(atMs: ms) ?? 1
        let grow = CGFloat(self.grow?.progress(atMs: ms) ?? 1)
        let mix = { (a: CGFloat, b: CGFloat, p: CGFloat) in a + (b - a) * p }
        return FunnelPagePose(
            shift: mix(from.shift, to.shift, move),
            x: mix(from.x, to.x, move),
            y: mix(from.y, to.y, move),
            opacity: from.opacity + (to.opacity - from.opacity) * fade,
            scale: mix(from.scale, to.scale, grow),
            wash: from.wash + (to.wash - from.wash) * Double(move),
            covered: mix(from.covered, to.covered, move))
    }
}

/// The leaving page's backdrop: fades out over the transition, on the
/// fade curve, then is dropped — on the navigation's clock, like
/// `FunnelPageLayer`, so an interrupt restarts it rather than blending.
/// nil `fadeMs` holds it opaque.
struct FunnelBackdropFade: ViewModifier {
    let fadeMs: Int?
    let serial: Int
    let tokens: RenderMotionTokens
    let clock: FunnelTransitionClock

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: fadeMs == nil)) { timeline in
            content.opacity(opacity(at: timeline.date))
        }
        .onAppear { clock.stamp(serial) }
        .onChange(of: serial) { clock.stamp($0) }
    }

    private func opacity(at date: Date) -> Double {
        guard let fadeMs else { return MotionUnits.opaque }
        guard let ms = clock.elapsedMs(serial, drawingAt: date) else { return MotionUnits.opaque }
        let p = FunnelTiming.curve(tokens.fadeCurve, durationMs: fadeMs, delayMs: 0).progress(atMs: ms)
        return MotionUnits.opaque - p
    }
}

/// Moves a layer by a share of its own width plus points.
private struct FunnelShift: GeometryEffect {
    var fraction: CGFloat
    var x: CGFloat
    var y: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(fraction, x), y) }
        set {
            fraction = newValue.first.first
            x = newValue.first.second
            y = newValue.second
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: fraction * size.width + x, y: y))
    }
}

/// Everything but the trailing `covered` share of the width — the right
/// side, or the left one in a right-to-left funnel (a path is drawn in
/// unmirrored coordinates). It reaches a whole size past every edge, so a
/// backdrop drawn under the system bars is never clipped by it; at rest it
/// clips nothing.
private struct FunnelUncovered: Shape {
    var covered: CGFloat
    var rightToLeft: Bool

    var animatableData: CGFloat {
        get { covered }
        set { covered = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let reach = rect.insetBy(dx: -rect.width, dy: -rect.height)
        let cut = covered * rect.width
        if rightToLeft {
            let left = rect.minX + cut
            return Path(CGRect(x: left, y: reach.minY, width: reach.maxX - left, height: reach.height))
        }
        return Path(
            CGRect(
                x: reach.minX, y: reach.minY,
                width: rect.maxX - cut - reach.minX, height: reach.height))
    }
}

// MARK: - Element motion

/// The enter / exit presets — `look::MOTION_*_PRESETS`.
private enum MotionPreset {
    static let slideUp = "slide_up"
    static let slideDown = "slide_down"
    static let slideLeading = "slide_leading"
    static let slideTrailing = "slide_trailing"
    static let scale = "scale"
    static let pop = "pop"
}

/// The emphasis — `look::MOTION_EMPHASES`.
private let emphasisPulse = "pulse"

/// A transform an element moves through: travel in points and a scale.
private struct ElementPose: Equatable {
    var offset: CGSize = .zero
    var scale: CGFloat = MotionUnits.restingScale

    static let rest = ElementPose()

    /// Where an enter starts: `slide_up` rises into place so it starts
    /// below, `slide_leading` moves toward the leading edge so it starts on
    /// the trailing side. nil for a fade.
    static func enterFrom(_ preset: String, _ t: RenderMotionTokens) -> ElementPose? {
        let d = CGFloat(t.elementDistance)
        switch preset {
        case MotionPreset.slideUp: return ElementPose(offset: CGSize(width: 0, height: d))
        case MotionPreset.slideDown: return ElementPose(offset: CGSize(width: 0, height: -d))
        case MotionPreset.slideLeading: return ElementPose(offset: CGSize(width: d, height: 0))
        case MotionPreset.slideTrailing: return ElementPose(offset: CGSize(width: -d, height: 0))
        case MotionPreset.scale: return ElementPose(scale: CGFloat(fraction(t.enterScale)))
        case MotionPreset.pop: return ElementPose(scale: CGFloat(fraction(t.popScale)))
        default: return nil
        }
    }

    /// Where an exit ends — the direction its name says. nil for a fade.
    static func exitTo(_ preset: String, _ t: RenderMotionTokens) -> ElementPose? {
        let d = CGFloat(t.elementDistance)
        switch preset {
        case MotionPreset.slideUp: return ElementPose(offset: CGSize(width: 0, height: -d))
        case MotionPreset.slideDown: return ElementPose(offset: CGSize(width: 0, height: d))
        case MotionPreset.slideLeading: return ElementPose(offset: CGSize(width: -d, height: 0))
        case MotionPreset.slideTrailing: return ElementPose(offset: CGSize(width: d, height: 0))
        case MotionPreset.scale: return ElementPose(scale: CGFloat(fraction(t.enterScale)))
        default: return nil
        }
    }
}

/// One node's enter, exit and pulse. Transform and opacity only — never
/// layout — so a control is laid out, and tappable, from its first frame.
struct FunnelElementMotion: ViewModifier {
    let motion: RenderMotion?
    /// Hidden on the same page and kept drawn only for its exit.
    let exiting: Bool
    let onExited: (() -> Void)?
    let holdsPlayback: Bool

    @Environment(\.funnelScreenMotion) private var screen
    /// The enter's opacity and its travel, each on its own timing.
    @State private var shown: Bool
    @State private var placed: Bool
    /// The exit, opacity and travel together on the exit curve.
    @State private var gone = false
    /// 0 → `pulseCycles`: how far the pulse has run.
    @State private var pulsePhase = 0.0
    @State private var playbackHeld = false

    init(motion: RenderMotion?, exiting: Bool, onExited: (() -> Void)?, holdsPlayback: Bool) {
        self.motion = motion
        self.exiting = exiting
        self.onExited = onExited
        self.holdsPlayback = holdsPlayback
        // An element with an enter waits at its starting pose from its very
        // first frame, so nothing flashes at rest before it enters.
        _shown = State(initialValue: motion?.enter == nil)
        _placed = State(initialValue: motion?.enter == nil)
        // A video that enters is held from its first frame too.
        _playbackHeld = State(initialValue: holdsPlayback && motion?.enter != nil)
    }

    func body(content: Content) -> some View {
        let tokens = screen?.tokens
        let full = screen?.mode == .full
        // Outside a funnel screen nothing animates: drawn at rest.
        let entering = screen != nil && motion?.enter != nil
        let enterPose = (entering && full && !placed)
            ? motion?.enter.flatMap { e in tokens.flatMap { ElementPose.enterFrom(e.preset, $0) } } : nil
        let exitPose = (gone && full)
            ? motion?.exit.flatMap { e in tokens.flatMap { ElementPose.exitTo(e.preset, $0) } } : nil
        let pose = exitPose ?? enterPose ?? .rest
        // Waiting for its enter it is drawn at the hit-testable floor, not
        // 0: a control is tappable from its first frame (M3). Only an exit
        // goes all the way to 0 — it takes no tap anyway.
        let opacity =
            gone ? MotionUnits.invisible : (entering && !shown) ? MotionUnits.hitTestableOpacity : MotionUnits.opaque
        content
            .environment(\.funnelPlaybackHeld, playbackHeld)
            .modifier(
                FunnelPulse(
                    phase: pulsePhase, peak: CGFloat(fraction(tokens?.pulseScale ?? 0)),
                    curve: FunnelCubicBezier(thousandths: tokens?.fadeCurve ?? [])))
            .scaleEffect(pose.scale)
            .offset(pose.offset)
            .opacity(opacity)
            // An element drawn only for its exit is gone for every purpose
            // but the eye.
            .allowsHitTesting(!exiting)
            .accessibilityHidden(exiting)
            .onAppear(perform: appear)
            .onChange(of: exiting) { exitingNow in exitingNow ? exitInPlace() : comeBack() }
            .onChange(of: screen?.leavingMs) { leaving in
                if let leaving { leave(within: leaving) } else { comeBack() }
            }
    }

    /// Mounting: part of the page appearing, or revealed on a page already up.
    private func appear() {
        guard let screen, let motion else {
            playbackHeld = false
            return
        }
        let revealed = screen.appearance.appeared
        let start = revealed ? 0 : screen.enterOffsetMs
        var settledAt = start
        if let enter = motion.enter {
            let full = screen.mode == .full
            let delay = full && !revealed ? start + enter.delayMs : start
            let fadeMs = full ? enter.durationMs : screen.tokens.fastMs
            withAnimation(screen.tokens.fade(fadeMs, delayMs: delay)) { shown = true }
            if full, ElementPose.enterFrom(enter.preset, screen.tokens) != nil {
                withAnimation(enter.spring.animation(delayMs: delay)) { placed = true }
            } else {
                placed = true
            }
            settledAt = delay + (full ? enter.settleMs : screen.tokens.fastMs)
            if playbackHeld { release(afterMs: settledAt) }
        }
        if motion.emphasis == emphasisPulse && screen.mode == .full {
            let cycles = screen.tokens.pulseCycles
            withAnimation(.linear(duration: seconds(screen.tokens.pulseMs * cycles)).delay(seconds(settledAt))) {
                pulsePhase = Double(cycles)
            }
        }
    }

    /// A video does not play while it enters; it starts once the enter ends.
    private func release(afterMs ms: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds(ms)) { playbackHeld = false }
    }

    /// Hidden on the same page: exit, then let the list drop the node.
    private func exitInPlace() {
        guard let screen, let exit = motion?.exit else {
            onExited?()
            return
        }
        let duration = screen.mode == .full ? exit.durationMs : screen.tokens.reducedExitMs
        withAnimation(screen.tokens.exit(duration)) { gone = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds(duration)) {
            // Shown again before the exit ended: nothing to drop.
            if gone { onExited?() }
        }
    }

    /// The page is being left: the exit plays inside the outgoing transition.
    private func leave(within leavingMs: Int) {
        guard let screen, let exit = motion?.exit else { return }
        let own = screen.mode == .full ? exit.durationMs : screen.tokens.reducedExitMs
        withAnimation(screen.tokens.exit(min(own, leavingMs))) { gone = true }
    }

    /// Shown again (or the page arrives again) mid-exit: back to rest at once.
    private func comeBack() {
        guard gone else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { gone = false }
    }
}

/// The emphasis: up to `peak` and back, each half on the fade curve, once
/// per whole `phase`; at a whole phase it is at rest — so after the last
/// cycle it is still for good (WCAG 2.2.2).
private struct FunnelPulse: GeometryEffect {
    var phase: Double
    let peak: CGFloat
    let curve: FunnelCubicBezier?

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let within = phase - phase.rounded(.down)
        guard within > 0, let curve else { return ProjectionTransform(.identity) }
        let rise = peak - MotionUnits.restingScale
        let scale =
            within < MotionUnits.half
            ? MotionUnits.restingScale + rise * CGFloat(curve.y(atX: within / MotionUnits.half))
            : peak - rise * CGFloat(curve.y(atX: (within - MotionUnits.half) / MotionUnits.half))
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        return ProjectionTransform(
            CGAffineTransform(translationX: centre.x, y: centre.y)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -centre.x, y: -centre.y))
    }
}

/// A CSS-style cubic bezier from (0,0) to (1,1), evaluated as y for x —
/// for the pulse, whose halves SwiftUI cannot sequence on one value.
struct FunnelCubicBezier: Equatable {
    let x1: Double, y1: Double, x2: Double, y2: Double

    /// Solver bounds: Newton steps, then bisection steps, to this precision.
    private static let newtonSteps = 8
    private static let bisectionSteps = 24
    private static let precision = 1e-6

    init?(thousandths points: [Int]) {
        guard points.count == MotionUnits.bezierPoints else { return nil }
        let p = points.map { Double($0) / MotionUnits.thousandths }
        (x1, y1, x2, y2) = (p[0], p[1], p[2], p[3])
    }

    private func sample(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private func slope(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }

    func y(atX x: Double) -> Double {
        var t = x
        for _ in 0..<Self.newtonSteps {
            let error = sample(x1, x2, t) - x
            if abs(error) < Self.precision { return sample(y1, y2, t) }
            let d = slope(x1, x2, t)
            if abs(d) < Self.precision { break }
            t -= error / d
        }
        var low = 0.0
        var high = 1.0
        t = x
        for _ in 0..<Self.bisectionSteps {
            let value = sample(x1, x2, t)
            if abs(value - x) < Self.precision { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sample(y1, y2, t)
    }
}

// MARK: - Presence

/// One node a list draws, live or kept only for its exit.
struct FunnelPresentNode: Identifiable {
    let id: String
    let node: FunnelNode
    let exiting: Bool
}

/// Keeps a hidden node drawn until its exit ends — the web's `usePresence`.
///
/// The resolver drops a block from the tree the moment it is hidden. One
/// with an exit must stay where it was, drawn, for as long as its exit
/// runs: a list draws the nodes it has now plus every node it just
/// dropped that has an exit to play, back in its place, flagged
/// `exiting`. When the exit ends the node is dropped for good. With
/// motion off a dropped node is gone at once, as before motion existed.
final class FunnelPresence: ObservableObject {
    /// Bumped when an exit ends, so the owner draws again without it.
    @Published private var finished = 0
    /// What the last draw drew, exiting nodes included. Not published:
    /// it is memory, written while drawing.
    private var drawn: [FunnelPresentNode] = []
    /// Nodes whose exit has ended — never drawn again until they come back.
    private var gone: Set<String> = []

    func present(_ live: [IdentifiedFunnelNode], animating: Bool) -> [FunnelPresentNode] {
        let liveIds = Set(live.map(\.id))
        var present = live.map { FunnelPresentNode(id: $0.id, node: $0.node, exiting: false) }
        if animating {
            for (at, entry) in drawn.enumerated()
            where !liveIds.contains(entry.id) && !gone.contains(entry.id) && entry.node.motion?.exit != nil {
                // Back where it was: right after the nearest earlier node still drawn.
                var anchor = -1
                var i = at - 1
                while i >= 0 && anchor == -1 {
                    let before = drawn[i].id
                    anchor = present.firstIndex { $0.id == before } ?? -1
                    i -= 1
                }
                present.insert(
                    FunnelPresentNode(id: entry.id, node: entry.node, exiting: true), at: anchor + 1)
            }
        }
        // A node shown again is live again; one gone and not drawn is forgotten.
        gone = gone.filter { id in !liveIds.contains(id) && present.contains { $0.id == id } }
        drawn = present
        return present
    }

    func exited(_ id: String) {
        gone.insert(id)
        finished += 1
    }
}

/// A list of nodes inside whatever stack holds it, each drawn through
/// `FunnelNodeView` and kept for its exit by a `FunnelPresence`.
struct FunnelNodeList: View {
    let nodes: [FunnelNode]
    let look: RenderLook
    let interaction: FunnelInteraction
    @StateObject private var presence = FunnelPresence()
    @Environment(\.funnelScreenMotion) private var screenMotion

    var body: some View {
        ForEach(presence.present(identified(nodes), animating: screenMotion != nil)) { entry in
            FunnelNodeView(
                node: entry.node, look: look, interaction: interaction, exiting: entry.exiting,
                onExited: { [presence] in presence.exited(entry.id) })
        }
    }
}
