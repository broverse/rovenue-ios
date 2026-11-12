//  Countdown.swift — the countdown block (spec 2026-11-10 NE §4.1, §7).
//
//  The core keeps the time state: the deadline (`deadlineMs`, or the
//  evergreen anchor `countdownAnchor` stores at this first draw), expiry
//  and its `onExpire` chain (`tick`, driven by the driver once per
//  `look.elements.countdown.tickMs`). This view keeps only the DISPLAY
//  clock: remaining = deadline − (device now + the session's skew), redrawn
//  on the second boundaries of that remaining time. Every length is a
//  `look.elements.countdown` token; the unit words are the resolver's.

import SwiftUI

private enum CountdownFormat {
    static let msPerSecond: Int64 = 1000
    static let secondsPerMinute: Int64 = 60
    static let secondsPerHour: Int64 = 3600
    static let secondsPerDay: Int64 = 86_400
    static let minutesPerHour: Int64 = 60
    static let hoursPerDay: Int64 = 24
    /// Hours, minutes and seconds in a box always show two digits ("09").
    static let boxDigits = 2
    static let padDigit: Character = "0"
    /// A timeline date sits exactly on a second boundary; a binary epoch
    /// can land a hair before it, which must not show the previous second.
    static let boundaryEpsilonSeconds = 0.001
    /// Unicode LEFT-TO-RIGHT ISOLATE … POP DIRECTIONAL ISOLATE: digits read
    /// left to right inside right-to-left copy (spec NE §7).
    static let ltrIsolate = "\u{2066}"
    static let popIsolate = "\u{2069}"
    static let wordSpace = " "
    static let modeEvergreen = "evergreen"
    static let displayInline = "inline"
    static let atZeroHide = "hide"
    static let atZeroText = "text"
    static let noRemaining: Int64 = 0
    static let nanosPerMs: UInt64 = 1_000_000
}

/// One unit drawn: its count and its words.
private struct CountdownUnit: Identifiable {
    let id: String
    let count: Int64
    let word: RenderUnitWord
    /// Hours, minutes and seconds pad to two digits in a box; the leading
    /// days count does not.
    let padded: Bool
}

struct FunnelCountdownView: View {
    let block: CountdownBlock
    let look: RenderLook
    @Environment(\.funnelElements) private var host
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// An evergreen key's deadline from the anchor the session stored at
    /// this first draw — until the next resolve carries it as `deadlineMs`.
    @State private var anchoredDeadline: Int64?
    /// Whether time was seen remaining: only a zero reached after that is
    /// reached on screen. A zero computed before the session adopted its
    /// clock skew (a fast device, the probe still out) is provisional.
    @State private var seenRunning = false
    /// The zero's one announcement went out.
    @State private var zeroAnnounced = false

    init(block: CountdownBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    private var scale: FunnelTextScale { FunnelTextScale(dynamicType: dynamicTypeSize) }
    private var tokens: RenderCountdownLook { look.elements.countdown }
    private var deadline: Int64? { block.deadlineMs.map(Int64.init) ?? anchoredDeadline }

    var body: some View {
        TimelineView(.periodic(from: phase, by: TimeInterval(tokens.tickMs) / FunnelElementTime.millisecondsPerSecond)) {
            context in
            drawn(remainingMs: remainingMs(at: context.date))
        }
        .onAppear(perform: anchor)
        .task(id: AnnounceKey(deadline: deadline, expired: block.expired)) { await announceAtZero() }
    }

    // MARK: Time

    /// Stores (or reads) the evergreen anchor at the first frame; a
    /// deadline countdown already carries its deadline.
    private func anchor() {
        guard block.deadlineMs == nil, anchoredDeadline == nil,
            let anchor = host.countdownAnchor(block.key)
        else { return }
        anchoredDeadline = block.mode == CountdownFormat.modeEvergreen ? anchor + Int64(block.durationMs ?? 0) : anchor
    }

    /// The deadline in the DEVICE's clock: when its remaining time is zero.
    private var deviceZeroMs: Int64? { deadline.map { $0 - host.skewMs() } }

    /// The redraws land on the remaining time's second boundaries.
    private var phase: Date {
        let tick = Int64(tokens.tickMs)
        let offset = deviceZeroMs.map { (($0 % tick) + tick) % tick } ?? 0
        return Date(timeIntervalSince1970: Double(offset) / FunnelElementTime.millisecondsPerSecond)
    }

    /// Remaining ms at `date` (never below zero); the whole duration while
    /// an evergreen key has no anchor yet.
    private func remainingMs(at date: Date) -> Int64 {
        guard let zero = deviceZeroMs else { return Int64(block.durationMs ?? 0) }
        let seconds = Double(zero) / FunnelElementTime.millisecondsPerSecond - date.timeIntervalSince1970
        let whole = Int64((seconds + CountdownFormat.boundaryEpsilonSeconds).rounded(.down))
        return max(CountdownFormat.noRemaining, whole * CountdownFormat.msPerSecond)
    }

    /// What the announcement waits on: the deadline, and the session's
    /// expiry of the block (which ends a wait on a provisional zero).
    private struct AnnounceKey: Equatable {
        let deadline: Int64?
        let expired: Bool
    }

    /// One polite announcement when the time runs out on screen (spec NE
    /// §7): the expired text. The skew is re-read while waiting (at most
    /// one `tickMs` per sleep): the session adopts it on a tick that can
    /// come after this task started, and a deadline countdown's `deadline`
    /// does not change with it. A zero never preceded by running time is
    /// provisional and re-read until the session expires the block (the
    /// task is re-keyed then and ends here); entered at or past zero, it is
    /// never announced.
    private func announceAtZero() async {
        guard !zeroAnnounced else { return }
        if block.expired {
            // The session's tick saw the zero before this task's own wait did.
            if seenRunning { announceZero() }
            return
        }
        let tickMs = Int64(tokens.tickMs)
        while !Task.isCancelled, let zero = deviceZeroMs {
            let waitMs = zero - funnelDeviceNowMs()
            if waitMs > CountdownFormat.noRemaining {
                seenRunning = true
            } else if seenRunning {
                announceZero()
                return
            }
            let sleepMs = waitMs > CountdownFormat.noRemaining ? min(waitMs, tickMs) : tickMs
            try? await Task.sleep(nanoseconds: UInt64(sleepMs) * CountdownFormat.nanosPerMs)
        }
    }

    private func announceZero() {
        zeroAnnounced = true
        host.announcer.announce(block.expiredText)
    }

    // MARK: Units

    /// Days only from `daysFromMs`, hours only from `hoursFromMs`, minutes
    /// and seconds always (`COUNTDOWN_UNIT_THRESHOLDS`).
    private func units(_ remainingMs: Int64) -> [CountdownUnit] {
        let total = remainingMs / CountdownFormat.msPerSecond
        let showDays = remainingMs >= Int64(tokens.daysFromMs)
        let showHours = showDays || remainingMs >= Int64(tokens.hoursFromMs)
        var out: [CountdownUnit] = []
        if showDays {
            out.append(CountdownUnit(id: "d", count: total / CountdownFormat.secondsPerDay, word: block.units.days, padded: false))
        }
        if showHours {
            let hours = total / CountdownFormat.secondsPerHour
            out.append(
                CountdownUnit(
                    id: "h", count: showDays ? hours % CountdownFormat.hoursPerDay : hours, word: block.units.hours,
                    padded: showDays))
        }
        let minutes = total / CountdownFormat.secondsPerMinute
        out.append(
            CountdownUnit(
                id: "m", count: showHours ? minutes % CountdownFormat.minutesPerHour : minutes,
                word: block.units.minutes, padded: showHours))
        out.append(
            CountdownUnit(
                id: "s", count: total % CountdownFormat.secondsPerMinute, word: block.units.seconds, padded: true))
        return out
    }

    private func isOne(_ count: Int64) -> Bool { block.pluralOne.contains(Int(count)) }

    private func short(_ unit: CountdownUnit) -> String {
        isOne(unit.count) ? unit.word.shortOne : unit.word.shortOther
    }

    private func long(_ count: Int64, _ word: RenderUnitWord) -> String {
        "\(count)\(CountdownFormat.wordSpace)\(isOne(count) ? word.longOne : word.longOther)"
    }

    private func digits(_ unit: CountdownUnit, boxed: Bool) -> String {
        var text = String(unit.count)
        if boxed && unit.padded && text.count < CountdownFormat.boxDigits {
            text = String(repeating: CountdownFormat.padDigit, count: CountdownFormat.boxDigits - text.count) + text
        }
        return CountdownFormat.ltrIsolate + text + CountdownFormat.popIsolate
    }

    // MARK: Drawing

    @ViewBuilder
    private func drawn(remainingMs: Int64) -> some View {
        let expired = block.expired || (deadline != nil && remainingMs <= CountdownFormat.noRemaining)
        if expired && block.atZero == CountdownFormat.atZeroHide {
            EmptyView()
        } else {
            VStack(spacing: CGFloat(tokens.boxGap)) {
                if let label = block.label, !(expired && block.atZero == CountdownFormat.atZeroText) {
                    Text(label)
                        .font(funnelFont(block.style, look.mutedType, scale: scale))
                        .foregroundColor(look.mutedColor)
                }
                if expired && block.atZero == CountdownFormat.atZeroText {
                    Text(block.expiredText).font(funnelFont(block.style, look.bodyType, scale: scale))
                } else if block.display == CountdownFormat.displayInline {
                    inline(units(expired ? CountdownFormat.noRemaining : remainingMs))
                } else {
                    boxes(units(expired ? CountdownFormat.noRemaining : remainingMs))
                }
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .funnelStyle(block.style, look.bodyType)
            // A timer: one element, its words updated per minute, never per
            // second (spec NE §7, F19).
            .accessibilityElement(children: .ignore)
            .ifLet(block.label) { $0.accessibilityLabel(Text($1)) }
            .accessibilityValue(Text(expired ? block.expiredText : spoken(remainingMs)))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var alignment: HorizontalAlignment {
        block.style.align.map(funnelAlignment) ?? .center
    }

    /// The accessible remaining time in full words, to the minute (rounded
    /// up, so the last minute reads "1 minute", not "0").
    private func spoken(_ remainingMs: Int64) -> String {
        let minutesUp =
            (remainingMs + CountdownFormat.secondsPerMinute * CountdownFormat.msPerSecond - 1)
            / (CountdownFormat.secondsPerMinute * CountdownFormat.msPerSecond)
        let shown = units(minutesUp * CountdownFormat.secondsPerMinute * CountdownFormat.msPerSecond)
            .filter { $0.id != "s" && ($0.count > 0 || $0.id == "m") }
        return shown.map { long($0.count, $0.word) }.joined(separator: CountdownFormat.wordSpace)
    }

    private var digitFont: Font {
        let font = funnelFont(
            size: look.countdownDigitSize, weight: look.emphasisWeight, family: block.style.fontFamily, scale: scale)
        return tokens.tabularDigits ? font.monospacedDigit() : font
    }

    /// One box per unit, the short unit word under each, the look's
    /// separator glyph between the boxes. The row mirrors right to left;
    /// each number reads left to right.
    private func boxes(_ units: [CountdownUnit]) -> some View {
        HStack(alignment: .top, spacing: CGFloat(tokens.boxGap)) {
            ForEach(Array(units.enumerated()), id: \.element.id) { index, unit in
                if index > 0 {
                    Text(tokens.separator)
                        .font(digitFont)
                        .padding(.vertical, CGFloat(tokens.boxPadding))
                        .accessibilityHidden(true)
                }
                VStack(spacing: CGFloat(tokens.boxGap)) {
                    Text(digits(unit, boxed: true))
                        .font(digitFont)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(CGFloat(tokens.boxPadding))
                        .background(
                            RoundedRectangle(cornerRadius: CGFloat(tokens.boxRadius)).fill(look.cardColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: CGFloat(tokens.boxRadius))
                                .strokeBorder(look.borderColor, lineWidth: CGFloat(look.borderWidth)))
                    Text(short(unit))
                        .font(funnelFont(block.style, look.mutedType, scale: scale))
                        .foregroundColor(look.mutedColor)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    /// "9 min 59 sec" on one line, in the block's own type.
    private func inline(_ units: [CountdownUnit]) -> some View {
        let text = units.map { digits($0, boxed: false) + CountdownFormat.wordSpace + short($0) }
            .joined(separator: CountdownFormat.wordSpace)
        let font = funnelFont(block.style, look.bodyType, scale: scale)
        return Text(text)
            .font(tokens.tabularDigits ? font.monospacedDigit() : font)
            .lineLimit(1)
    }
}
