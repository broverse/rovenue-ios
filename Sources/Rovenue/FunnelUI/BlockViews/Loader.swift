//  Loader.swift — the determinate loader (spec 2026-11-10 NE §4.3, §7).
//
//  The resolver times it: `durationMs`, and `steps[i].endsMs` when step i
//  completes. This view computes the ONE formula the tree line states —
//  progress‰ = elapsed × 1000 / durationMs — from wall-clock time since the
//  page's first frame, frozen while the app is in the background
//  (`FunnelForegroundClock`). Reduced Motion changes nothing about the
//  time (the wait is content). At the end it tells the session once
//  (`loaderCompleted`), which releases the CTA hold and runs `onComplete`.
//  Every length is a `look.elements.loader` token.

import SwiftUI

private enum LoaderFormat {
    static let indicatorBar = "bar"
    static let indicatorRing = "ring"
    static let perMille = 1000.0
    static let percentPerPerMille = 10
    static let percentSign = "%"
    /// The accessible value's whole: steps done of the count, in whole percents.
    static let percentWhole = 100
    /// A ring starts at twelve o'clock.
    static let ringStart = Angle.degrees(-90)
    static let empty: CGFloat = 0
    /// No steps: the accessible value moves in tenths, never per frame.
    static let stepsWhenNone = 10
    static let doneSymbol = "checkmark.circle.fill"
    static let pendingSymbol = "circle"
}

struct FunnelLoaderView: View {
    let block: LoaderBlock
    let look: RenderLook
    @Environment(\.funnelElements) private var host
    @Environment(\.funnelScreenMotion) private var screenMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var clock = FunnelForegroundClock()
    /// Steps completed so far — what the accessible value moves by.
    @State private var stepsDone = 0
    @State private var completed = false

    init(block: LoaderBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    private var tokens: RenderLoaderLook { look.elements.loader }
    private var scale: FunnelTextScale { FunnelTextScale(dynamicType: dynamicTypeSize) }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: completed || !clock.running)) { context in
            let elapsed = min(Double(block.durationMs), clock.elapsedMs(at: context.date))
            drawn(elapsedMs: elapsed, permille: permille(elapsed))
        }
        .funnelStyle(block.style, look.bodyType)
        // A progress value to VoiceOver, moved per step (spec NE §7). Label
        // and value on the loader's OWN element, never an
        // `accessibilityRepresentation { ProgressView }`: over a
        // TimelineView that representation has no frame (0×0), and under
        // the page's `accessibilityHidden(true, isEnabled:)` gate SwiftUI
        // folds a frameless element into its sibling — a loader above a
        // button stretched the button's frame over the loader, so its
        // activation point landed on the ring (iOS E7/E9, w3a-regress).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(currentStepLabel ?? ""))
        .accessibilityValue(Text(accessiblePercent.formatted(.percent)))
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear(perform: start)
        .onDisappear { clock.stop() }
    }

    /// progress‰ = elapsed × 1000 / durationMs — the tree's formula.
    private func permille(_ elapsedMs: Double) -> Int {
        guard block.durationMs > 0 else { return Int(LoaderFormat.perMille) }
        return min(Int(LoaderFormat.perMille), Int(elapsedMs * LoaderFormat.perMille / Double(block.durationMs)))
    }

    /// Starts the page's clock at the first frame; the page being left
    /// starts nothing.
    private func start() {
        guard !clock.started, screenMotion?.leavingMs == nil else { return }
        clock.start()
        for (index, step) in block.steps.enumerated() {
            clock.at(Double(step.endsMs)) { [host] in
                stepsDone = max(stepsDone, index + 1)
                // Each completed step, politely, once.
                host.announcer.announce(step.label)
            }
        }
        if block.steps.isEmpty {
            let tenths = LoaderFormat.stepsWhenNone
            for tenth in 1...tenths {
                clock.at(Double(block.durationMs * tenth / tenths)) { stepsDone = max(stepsDone, tenth) }
            }
        }
        clock.at(Double(block.durationMs)) { [host, blockId = block.blockId] in
            completed = true
            host.loaderCompleted(blockId)
        }
    }

    /// Whole percent of the steps done, rounded DOWN in integers (P230): a
    /// fraction read "%33,333333"; rounding to nearest would say 100 before
    /// the last step ends, and a Double floor turns 29/100 into 28. An `Int`
    /// percent style formats 33 as "33%" / "%33" in the reader's locale —
    /// it never scales by 100. The visible percent floors the same way.
    private var accessiblePercent: Int {
        let count = block.steps.isEmpty ? LoaderFormat.stepsWhenNone : block.steps.count
        return min(stepsDone, count) * LoaderFormat.percentWhole / count
    }

    private var currentStepLabel: String? {
        guard !block.steps.isEmpty else { return nil }
        return block.steps[min(stepsDone, block.steps.count - 1)].label
    }

    // MARK: Drawing

    private func drawn(elapsedMs: Double, permille: Int) -> some View {
        VStack(spacing: CGFloat(look.blockGap)) {
            switch block.indicator {
            case LoaderFormat.indicatorBar: bar(permille)
            case LoaderFormat.indicatorRing: ring(permille)
            default:
                if block.showPercent { percentText(permille) }
            }
            if !block.steps.isEmpty { steps(elapsedMs) }
        }
        .frame(maxWidth: .infinity)
    }

    private func percentText(_ permille: Int) -> some View {
        Text("\(permille / LoaderFormat.percentPerPerMille)\(LoaderFormat.percentSign)")
            .font(funnelFont(block.style, look.labelType, scale: scale).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
    }

    /// A track filled from the reading-start edge (right to left in RTL),
    /// the percent at its end.
    private func bar(_ permille: Int) -> some View {
        HStack(spacing: CGFloat(look.indicatorGap)) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: CGFloat(tokens.barRadius)).fill(look.borderColor)
                    RoundedRectangle(cornerRadius: CGFloat(tokens.barRadius))
                        .fill(look.accentColor)
                        .frame(width: proxy.size.width * CGFloat(permille) / CGFloat(LoaderFormat.perMille))
                }
            }
            .frame(height: CGFloat(tokens.barHeight))
            if block.showPercent { percentText(permille) }
        }
    }

    /// A ring filled clockwise from twelve o'clock, the percent inside. It
    /// never spins: the fill is the motion, and it is the time.
    private func ring(_ permille: Int) -> some View {
        let stroke = CGFloat(tokens.ringStroke)
        return ZStack {
            Circle().stroke(look.borderColor, lineWidth: stroke)
            Circle()
                .trim(from: LoaderFormat.empty, to: CGFloat(permille) / CGFloat(LoaderFormat.perMille))
                .stroke(look.accentColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(LoaderFormat.ringStart)
            if block.showPercent { percentText(permille) }
        }
        .padding(stroke / FunnelGeometry.halves)
        .frame(width: CGFloat(tokens.ringSize), height: CGFloat(tokens.ringSize))
    }

    /// The step list, each row ticked when the clock passes its end.
    private func steps(_ elapsedMs: Double) -> some View {
        VStack(alignment: .leading, spacing: CGFloat(tokens.stepGap)) {
            ForEach(Array(block.steps.enumerated()), id: \.offset) { _, step in
                let done = elapsedMs >= Double(step.endsMs)
                HStack(spacing: CGFloat(look.indicatorGap)) {
                    Image(systemName: done ? LoaderFormat.doneSymbol : LoaderFormat.pendingSymbol)
                        .font(.system(size: CGFloat(look.indicatorSize)))
                        .foregroundColor(done ? look.accentColor : look.mutedColor)
                    Text(step.label)
                        .font(funnelFont(block.style, look.bodyType, scale: scale))
                        .foregroundColor(done ? look.textColor : look.mutedColor)
                }
                .frame(maxWidth: .infinity, minHeight: CGFloat(tokens.stepRowHeight), alignment: .leading)
            }
        }
    }
}
