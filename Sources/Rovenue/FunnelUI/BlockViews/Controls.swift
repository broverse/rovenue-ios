//  Controls.swift — spacer, divider, activity, button, review, and the
//  screen CTA.
//
//  Every one of these takes a plain closure rather than the session: a
//  block view reports, the entry point acts. Every length, size and colour
//  is the screen's look or the block's own style (which wins).

import SwiftUI

private enum ControlFormat {
    /// The review's stars: one filled glyph per point of rating, as the web
    /// draws them (`controls.tsx`'s `FILLED_STAR.repeat(rating)`).
    static let filledStar = "★"
    /// The variant the CTA is — `resolve.rs`'s `cta_of` resolves its style
    /// with the primary variant, so it wears the primary variant's chrome.
    static let variantPrimary = "primary"
}

struct FunnelSpacerView: View {
    let block: SpacerBlock

    init(block: SpacerBlock) {
        self.block = block
    }

    var body: some View {
        if block.flex {
            // Takes the height the page column has left (at least its
            // size): what follows sits at the bottom of the screen.
            Spacer(minLength: CGFloat(block.size))
        } else {
            Spacer().frame(height: CGFloat(block.size))
        }
    }
}

/// A `borderWidth` line in the look's `border`; the block's own ground and
/// height win.
struct FunnelDividerView: View {
    let block: DividerBlock
    let look: RenderLook

    init(block: DividerBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    var body: some View {
        Rectangle()
            .fill(funnelColor(block.style.background) ?? look.borderColor)
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(block.style.height ?? look.borderWidth))
            .cornerRadius(CGFloat(block.style.radius ?? 0))
            .funnelMargins(block.style)
    }
}

/// The indeterminate spinner (C12): still the system's `ProgressView`, so
/// its VoiceOver label ("In progress", localized by the OS) is the
/// platform's, drawn as the look's ring — `activitySize`, `activityStroke`,
/// `accent`. No label is set here — this SDK has no string table, and an
/// English literal would override the system's translated one.
struct FunnelActivityView: View {
    let look: RenderLook

    init(look: RenderLook) {
        self.look = look
    }

    var body: some View {
        ProgressView()
            .progressViewStyle(FunnelActivityRingStyle(look: look))
            .frame(maxWidth: .infinity)
    }
}

struct FunnelButtonView: View {
    let block: ButtonBlock
    let look: RenderLook
    let onTap: () -> Void
    let onHeldTap: (() -> Void)?

    init(
        block: ButtonBlock, look: RenderLook, onTap: @escaping () -> Void,
        onHeldTap: (() -> Void)? = nil
    ) {
        self.block = block
        self.look = look
        self.onTap = onTap
        self.onHeldTap = onHeldTap
    }

    var body: some View {
        // The resolver's forward gate, never re-derived here: false while a
        // visible required question is unanswered and this button's chain
        // would move the visitor on.
        FunnelChromeButton(
            label: block.label, variant: block.variant, style: block.style, look: look,
            enabled: block.enabled, parts: block, onTap: onTap, onHeldTap: onHeldTap)
    }
}

/// A review is a CARD, not loose text: the look's `card` fill, a
/// `borderWidth` hairline in `border`, `cardRadius`, `cardPadding` and
/// `cardGap`; stars in `accent`, the quote in the text colour, the author
/// `muted` at `mutedTextSize` — the same card the web and Android draw. The
/// block's own style wins wherever it speaks.
struct FunnelReviewView: View {
    let block: ReviewBlock
    let look: RenderLook

    init(block: ReviewBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    var body: some View {
        let size = block.style.fontSize ?? look.textSize
        VStack(
            alignment: funnelAlignment(block.style.align), spacing: CGFloat(look.cardGap)
        ) {
            // A nil rating draws no stars at all, rather than zero of them.
            if let rating = block.rating, rating > 0 {
                Text(String(repeating: ControlFormat.filledStar, count: rating))
                    .foregroundColor(look.accentColor)
                    .funnelLineHeight(look, size: size, family: block.style.fontFamily)
            }
            Text(block.quote)
                .multilineTextAlignment(funnelTextAlignment(block.style.align))
                .funnelLineHeight(look, size: size, family: block.style.fontFamily)
            if let author = block.author {
                Text(author)
                    .font(funnelFont(.unstyled, look.mutedType))
                    .foregroundColor(look.mutedColor)
                    .funnelLineHeight(look, size: look.mutedTextSize, family: nil)
            }
        }
        .funnelTypography(block.style, look.bodyType)
        // Inside a border-box card: the hairline, then the padding.
        .padding(CGFloat(look.cardPadding + look.borderWidth))
        .frame(
            maxWidth: .infinity,
            alignment: Alignment(horizontal: funnelAlignment(block.style.align), vertical: .center)
        )
        .funnelCard(
            block.style, fill: look.cardColor, radius: look.cardRadius,
            borderWidth: look.borderWidth, borderColor: look.borderColor)
        .funnelMargins(block.style)
    }
}

/// The screen's call to action — a primary button, in the same ONE shape a
/// primary block button draws (`FunnelButtonChrome`).
///
/// `enabled` is a business rule the resolver already computed — false while
/// a visible required question is unanswered. Do not re-derive it here.
struct FunnelCtaView: View {
    let cta: RenderCta
    let look: RenderLook
    let onTap: () -> Void
    let onHeldTap: (() -> Void)?

    init(
        cta: RenderCta, look: RenderLook, onTap: @escaping () -> Void,
        onHeldTap: (() -> Void)? = nil
    ) {
        self.cta = cta
        self.look = look
        self.onTap = onTap
        self.onHeldTap = onHeldTap
    }

    var body: some View {
        FunnelChromeButton(
            label: cta.label, variant: ControlFormat.variantPrimary, style: cta.style, look: look,
            enabled: cta.enabled, parts: cta, onTap: onTap, onHeldTap: onHeldTap)
    }
}
