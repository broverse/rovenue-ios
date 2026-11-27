//
//  Skeleton.swift
//  Rovenue
//
//  The placeholder a funnel draws while its store prices load (spec
//  2026-11-22-funnel-price-loading-state): core marks a package row's price
//  (`RenderPackage.priceState == "pending"`), its caption / period line
//  (`captionPending` / `periodPending`) and a heading's or text's copy
//  (`pending` + `pendingChars`) as still loading, and the drawer puts a
//  rounded bar in the look's muted tone where the text goes, so the screen
//  keeps its layout and reads as "not yet" instead of finished-but-empty.
//  When the prices land (`setPackagePrices`) the session redraws and the
//  real text takes the bar's place.
//

import SwiftUI

/// The skeleton's numbers — one place, shared by every drawer that draws
/// one (and kept equal to sdk-kotlin's).
enum SkeletonFormat {
    /// The pulse's two ends and its one-way duration: opacity 0.35↔0.7,
    /// about a second each way.
    static let dimOpacity = 0.35
    static let brightOpacity = 0.7
    static let pulseSeconds = 1.0
    /// The still opacity under Reduce Motion: no pulse, the middle tone.
    static let restingOpacity = 0.5
    /// A pending character is about half the font size wide (spec: width
    /// ≈ `pendingChars × 0.5 × fontSize`, capped at the available width).
    static let charWidthShare: CGFloat = 0.5
    /// The bar's height as a share of the font size: about a glyph's ink,
    /// centred in the line box the text would take.
    static let barHeightShare: CGFloat = 0.8
    /// Corner radius as a share of the bar's height.
    static let radiusShare: CGFloat = 0.25
    /// `PENDING_VALUE_CHARS` in render.rs: the characters a pending price
    /// stands for ("$79.99", "₺1.299,99" run 5–9) — the price column's bar.
    static let priceChars: CGFloat = 6
    /// A caption / period line's bar, in characters: a short second line.
    static let lineChars: CGFloat = 14
}

/// One skeleton bar: a rounded rect in `color` (the look's muted tone),
/// `height` tall and `width` wide — nil takes the width offered, a number
/// is capped by it — pulsing between `SkeletonFormat`'s two opacities, and
/// still when the system asks for reduced motion. VoiceOver reads it as the
/// chrome copy's `loading` ("Loading", localized by core); with no chrome
/// copy it is hidden.
struct FunnelSkeletonBar: View {
    let color: Color
    var width: CGFloat? = nil
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.funnelCopy) private var copy
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: height * SkeletonFormat.radiusShare, style: .continuous)
            .fill(color)
            .frame(maxWidth: width ?? .infinity, minHeight: height, maxHeight: height)
            .opacity(opacity)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeInOut(duration: SkeletonFormat.pulseSeconds).repeatForever(autoreverses: true)
                ) { bright = true }
            }
            .accessibilityElement()
            .ifLet(copy) { $0.accessibilityLabel($1.loading) }
            .accessibilityHidden(copy == nil)
    }

    /// Under Reduce Motion the pulse's state is ignored, so turning the
    /// setting on mid-pulse stops it at once.
    private var opacity: Double {
        if reduceMotion { return SkeletonFormat.restingOpacity }
        return bright ? SkeletonFormat.brightOpacity : SkeletonFormat.dimOpacity
    }
}

/// A skeleton standing in for one line of text at `size` pt (already
/// scaled for the device's text size): `chars` characters wide, capped at
/// the width offered.
struct FunnelSkeletonText: View {
    let color: Color
    let size: CGFloat
    let chars: CGFloat

    var body: some View {
        FunnelSkeletonBar(
            color: color, width: chars * SkeletonFormat.charWidthShare * size,
            height: size * SkeletonFormat.barHeightShare)
    }
}

/// A skeleton in a text line's slot: a blank run in `font` at the look's
/// line height for `size` (the unscaled size, as `funnelLineHeight` takes
/// it), so the slot is exactly as tall as the line it stands for and the
/// row keeps its height when the real text arrives; `chars` characters
/// wide, shrinking when less width is offered. A package row's price
/// column and caption / period lines draw these.
struct FunnelSkeletonSlot: View {
    let look: RenderLook
    let font: Font
    let size: CGFloat
    let family: String?
    let scale: FunnelTextScale
    let chars: CGFloat

    var body: some View {
        let scaled = scale(size)
        Text(verbatim: " ")
            .font(font)
            .accessibilityHidden(true)
            .funnelLineHeight(look, size: size, family: family)
            .frame(maxWidth: chars * SkeletonFormat.charWidthShare * scaled)
            .overlay { FunnelSkeletonText(color: look.mutedColor, size: scaled, chars: chars) }
    }
}
