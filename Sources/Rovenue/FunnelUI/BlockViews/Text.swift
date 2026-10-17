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

    var body: some View {
        trackedText
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
        guard let tracking = funnelTracking(style, size: CGFloat(style.fontSize ?? type.size)) else {
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
        var out = AttributedString()
        let size = CGFloat(style.fontSize ?? type.size)
        for s in segments {
            var run = AttributedString(s.text)
            if s.bold {
                run.font = funnelFont(size: size, weight: boldMarkWeight, family: style.fontFamily)
            }
            if s.italic {
                // The family's real italic face when the device has it
                // (fetched for screens that carry an italic run); else the
                // system's `italic()`, which only slants a system face.
                let weight = s.bold ? boldMarkWeight : (style.fontWeight ?? type.weight)
                if let face = funnelItalicFont(size: size, weight: weight, family: style.fontFamily) {
                    run.font = face
                } else if #available(macOS 13, *) {
                    // `Font.italic()` is macOS 13; this package ships macOS 12
                    // (where the tests run, though they never draw a view).
                    // iOS always takes this branch — the floor is 16.
                    run.font = (run.font ?? funnelFont(style, type)).italic()
                }
            }
            if s.strike { run.strikethroughStyle = .single }
            if s.code { run.font = .system(size: size, design: .monospaced) }
            if let link = s.link, let url = URL(string: link) {
                run.link = url
                run.foregroundColor = look.accentColor
                run.underlineStyle = .single
            }
            out += run
        }
        return Text(out)
    }
}
