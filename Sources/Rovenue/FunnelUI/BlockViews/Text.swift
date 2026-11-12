//  Text.swift — heading and body copy.
//
//  `text` arrives localized AND interpolated. There is no {{placeholder}}
//  left to expand and no locale to choose; rendering it verbatim is the
//  whole job.
//
//  Size, weight and line height are the screen's look (a heading's size by
//  its level, `headingWeight`); the block's own style wins wherever it
//  speaks — the rule every drawer shares (`text.tsx` on the web).

import SwiftUI

struct FunnelHeadingView: View {
    let block: HeadingBlock
    let look: RenderLook

    init(block: HeadingBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    var body: some View {
        let type = look.headingType(level: block.level)
        FunnelCopy(text: block.text, style: block.style, type: type, look: look, segments: block.segments)
    }
}

struct FunnelTextView: View {
    let block: TextBlock
    let look: RenderLook

    init(block: TextBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    var body: some View {
        FunnelCopy(text: block.text, style: block.style, type: look.bodyType, look: look, segments: block.segments)
    }
}

/// A `**bold**` run draws at weight 700 — "bold", not "bolder", so the
/// mark means the same on every base weight.
private let boldMarkWeight = 700

/// One block of copy: full width, aligned as the block asked, the look's
/// line height at whatever size is actually drawn.
private struct FunnelCopy: View {
    let text: String
    let style: RenderStyle
    let type: FunnelType
    let look: RenderLook
    let segments: [RenderSegment]?
    /// Read here so the copy redraws the moment the text size changes —
    /// the device's setting or a host's override (FunnelTextScale).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var scale: FunnelTextScale { FunnelTextScale(dynamicType: dynamicTypeSize) }

    var body: some View {
        trackedText
            .funnelBoxedRuns(segments?.contains { $0.boxed == true } == true)
            .multilineTextAlignment(funnelTextAlignment(style.align))
            .funnelLineHeight(
                look, size: CGFloat(style.fontSize ?? type.size), family: style.fontFamily,
                percent: style.lineHeight)
            .frame(
                maxWidth: .infinity,
                alignment: Alignment(horizontal: funnelAlignment(style.align), vertical: .center))
            .funnelStyle(style, type)
    }

    /// The copy at the block's tracking (`letterSpacing`), when it sets one.
    private var trackedText: Text {
        guard let tracking = funnelTracking(style, size: CGFloat(style.fontSize ?? type.size), scale: scale) else {
            return funnelText
        }
        return funnelText.tracking(tracking)
    }

    /// Verbatim when the copy carries no marks (the path every unmarked
    /// block has always drawn), else the segments as one attributed
    /// string — a single VoiceOver element, and link taps route through
    /// the `openURL` environment the funnel view overrides, exactly as a
    /// terms link's do.
    private var funnelText: Text {
        guard let segments else { return Text(text) }
        return FunnelMarks(
            size: CGFloat(style.fontSize ?? type.size), weight: style.fontWeight ?? type.weight,
            family: style.fontFamily, base: funnelFont(style, type, scale: scale), scale: scale, look: look
        ).text(segments)
    }
}

/// The inline marks (`**`, `*`, `~~`, `` ` ``, links, colour spans,
/// `[[boxed]]`) drawn over copy at one base size / weight / family — the
/// one mark painter every marked copy shares (body copy, and an option's
/// or tile's description, spec F §8 H9).
struct FunnelMarks {
    let size: CGFloat
    let weight: Int
    let family: String?
    /// The copy's own face, which an italic run slants when the family
    /// has no real italic on the device.
    let base: Font
    let scale: FunnelTextScale
    let look: RenderLook
    /// Which link runs a tap opens; the others draw as links but are inert.
    /// Every link by default (the host's `onUrl` decides); a description
    /// opens http(s) only.
    var opensLink: (String) -> Bool = { _ in true }

    /// The segments as one `Text`. A `[[boxed]]` run needs its own `Text`
    /// to carry the box attribute the renderer reads, so copy with one is
    /// concatenated run by run; copy without one is a single attributed
    /// string.
    func text(_ segments: [RenderSegment]) -> Text {
        if segments.contains(where: { $0.boxed == true }) {
            return segments.reduce(Text("")) { out, s in
                guard s.boxed == true else { return out + Text(attributed(s)) }
                return out + Text(attributed(s, boxPadding: true))
                    .customAttributeIfAvailable(FunnelBoxedRun(color: funnelColor(s.color)))
            }
        }
        return Text(segments.reduce(into: AttributedString()) { out, s in out += attributed(s) })
    }

    /// One segment as an attributed run. A boxed run is padded by a thin
    /// space each side, inside its run, so the outline the renderer strokes
    /// around the run's bounds sits ~0.2 em clear of the glyphs (P82's
    /// 0.22 em padding; a `Text` run cannot carry layout padding of its own).
    private func attributed(_ s: RenderSegment, boxPadding: Bool = false) -> AttributedString {
        var run = AttributedString(boxPadding ? BoxedFormat.thinSpace + s.text + BoxedFormat.thinSpace : s.text)
        if s.bold {
            run.font = funnelFont(size: size, weight: boldMarkWeight, family: family, scale: scale)
        }
        if s.italic {
            // The family's real italic face when the device has it
            // (fetched for screens that carry an italic run); else the
            // system's `italic()`, which only slants a system face.
            let weight = s.bold ? boldMarkWeight : self.weight
            if let face = funnelItalicFont(size: size, weight: weight, family: family, scale: scale) {
                run.font = face
            } else if #available(macOS 13, *) {
                // `Font.italic()` is macOS 13; this package ships macOS 12
                // (where the tests run, though they never draw a view).
                // iOS always takes this branch — the floor is 16.
                run.font = (run.font ?? base).italic()
            }
        }
        // A coloured span (spec E §3.4): the resolver already mapped the
        // authored role or hex to hex. A link keeps the accent below.
        if let color = funnelColor(s.color) { run.foregroundColor = color }
        if s.strike { run.strikethroughStyle = .single }
        if s.code { run.font = .system(size: scale(size), design: .monospaced) }
        if let link = s.link, let url = URL(string: link) {
            // An inert link keeps the link's look but takes no touch, so a
            // tap on it reaches whatever is under the copy.
            if opensLink(link) { run.link = url }
            run.foregroundColor = look.accentColor
            run.underlineStyle = .single
        }
        return run
    }
}

/// An option's / tile's description (spec F §8 H9): the plain text
/// exactly as before when it carries no marks, else its marked runs drawn
/// by `FunnelMarks` like any other copy. The caller sets the font, colour
/// and line height as it always did; a marked run's own face is built at
/// the row's secondary size. A description link opens only an http(s)
/// address, in the system browser, and never reaches the host's handler
/// (P130 — the web's `DescriptionCopy` passes no `onOpenUrl`). Any other
/// link run draws as a link but is inert: its tap picks the option, as
/// the web's href-less anchor does. Inside the option's `Button` an
/// http(s) run's own link gesture wins a touch that lands on it (the row
/// is not picked); every other touch picks the option (W4-F, proven on a
/// simulator by e2e/live/photo-flow-w4f-ios-links.mjs).
struct FunnelDescriptionCopy: View {
    let text: String
    let segments: [RenderSegment]?
    let rowText: FunnelRowText
    let look: RenderLook

    var body: some View {
        if let segments {
            FunnelMarks(
                size: rowText.secondary, weight: look.textWeight, family: rowText.family,
                base: rowText.secondaryFont(weight: look.textWeight), scale: rowText.scale, look: look,
                opensLink: funnelDescriptionOpens
            )
            .text(segments)
            .funnelBoxedRuns(segments.contains { $0.boxed == true })
            .environment(\.openURL, OpenURLAction { url in
                funnelDescriptionOpens(url.absoluteString) ? .systemAction : .discarded
            })
        } else {
            Text(text)
        }
    }
}

/// The only schemes a description link opens (P130, the web's `isWebUrl`).
private let descriptionLinkSchemes: Set<String> = ["http", "https"]

/// A description link run opens `link`: an http(s) address only (P130).
private func funnelDescriptionOpens(_ link: String) -> Bool {
    guard let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
    return descriptionLinkSchemes.contains(scheme)
}

// MARK: - Boxed runs (spec F §6 F4b, P82)

private enum BoxedFormat {
    /// The outline's width and the box's corner radius, in em of the run's
    /// own size — P82: 0.07 em and 0.22 em (no look token).
    static let strokeEm: CGFloat = 0.07
    static let radiusEm: CGFloat = 0.22
    /// U+2009 THIN SPACE: the box's side padding (≈ 0.2 em).
    static let thinSpace = "\u{2009}"
    /// A run's ascent + descent in em for the system face (SF: ≈ 1.19), to
    /// recover the run's size from its bounds — a layout run carries no font.
    static let lineBoxEm: CGFloat = 1.19
}

/// The text attribute marking a `[[boxed]]` run: its span colour, or nil
/// for the copy's own colour (the foreground style).
struct FunnelBoxedRun: Hashable {
    let color: Color?
}

#if compiler(>=6.0)
    @available(iOS 18.0, macOS 15.0, *)
    extension FunnelBoxedRun: TextAttribute {}

    /// Draws every run as the system would, and strokes a rounded outline
    /// around each boxed run's typographic bounds, in the run's colour.
    /// A line box tighter than the face (spec F §8 L1) draws every line
    /// after the first `deficit` points higher per line (`FunnelTightLines`
    /// shrinks the frame to match).
    @available(iOS 18.0, macOS 15.0, *)
    struct FunnelCopyRenderer: TextRenderer {
        let deficit: CGFloat

        /// Room for ink past the frame: a tight line box lets a descender or
        /// an accent spill out of it, as the web draws it, and the renderer
        /// would otherwise clip it at the frame.
        var displayPadding: EdgeInsets {
            EdgeInsets(top: deficit, leading: 0, bottom: deficit, trailing: 0)
        }

        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            for (index, line) in layout.enumerated() {
                var ctx = context
                ctx.translateBy(x: 0, y: -CGFloat(index) * deficit)
                for run in line {
                    if let box = run[FunnelBoxedRun.self] {
                        let bounds = run.typographicBounds
                        let em = (bounds.ascent + bounds.descent) / BoxedFormat.lineBoxEm
                        let stroke = max(1, em * BoxedFormat.strokeEm)
                        let rect = bounds.rect.insetBy(dx: stroke / 2, dy: stroke / 2)
                        let path = RoundedRectangle(cornerRadius: em * BoxedFormat.radiusEm).path(in: rect)
                        ctx.stroke(path, with: box.color.map { .color($0) } ?? .foreground, lineWidth: stroke)
                    }
                    ctx.draw(run)
                }
            }
        }
    }
#endif

extension Text {
    /// Marks a boxed run where the OS can draw the box (iOS 18's text
    /// renderer); before that the run draws as plain copy with its padding.
    func customAttributeIfAvailable(_ box: FunnelBoxedRun) -> Text {
        #if compiler(>=6.0)
            if #available(iOS 18.0, macOS 15.0, *) { return customAttribute(box) }
        #endif
        return self
    }
}

/// The per-line shift a tight line box (spec F §8 L1) asked for, so the
/// boxed-run renderer installed closer to the text keeps it.
private struct FunnelCopyLineDeficitKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var funnelCopyLineDeficit: CGFloat {
        get { self[FunnelCopyLineDeficitKey.self] }
        set { self[FunnelCopyLineDeficitKey.self] = newValue }
    }
}

/// Installs the boxed-run renderer when the copy carries a box.
private struct FunnelBoxedRuns: ViewModifier {
    let any: Bool
    @Environment(\.funnelCopyLineDeficit) private var deficit

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.0)
            if any, #available(iOS 18.0, macOS 15.0, *) {
                content.textRenderer(FunnelCopyRenderer(deficit: deficit))
            } else {
                content
            }
        #else
            content
        #endif
    }
}

extension View {
    /// Installs the boxed-run renderer when the copy carries a box.
    fileprivate func funnelBoxedRuns(_ any: Bool) -> some View {
        modifier(FunnelBoxedRuns(any: any))
    }

    /// Draws a copy run's lines `deficit` closer per line (boxed runs
    /// included) — the tight line box of spec F §8 L1.
    #if compiler(>=6.0)
        @available(iOS 18.0, macOS 15.0, *)
        func funnelTightCopy(deficit: CGFloat) -> some View {
            self.textRenderer(FunnelCopyRenderer(deficit: deficit))
                .environment(\.funnelCopyLineDeficit, deficit)
        }
    #endif
}
