//  FunnelPurchaseOverlay.swift — the authored purchase overlay a presented
//  funnel shows while a purchase or restore runs (plan 2026-11-16 D3).
//
//  A black scrim at the resolved `scrimOpacity` over the funnel's own
//  bounds; with a logo, title or description, a centred card holding them
//  (logo → spinner → title → description); with none, the spinner alone on
//  the scrim. Every length is a presentation token, every colour the
//  current screen's look. It swallows every touch and is the one element
//  assistive tech sees, announcing the resolved title (else "Processing…").

#if os(iOS)
import SwiftUI
import UIKit

struct FunnelPurchaseOverlayView: View {
    let overlay: CoreFunnelPurchaseOverlay
    let tokens: CoreFunnelPresentationTokens
    let look: RenderLook
    /// The page's body font (`funnelBodyFont`); nil draws the system face,
    /// as the face does until a hosted font is registered.
    let bodyFamily: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts

    init(
        overlay: CoreFunnelPurchaseOverlay, tokens: CoreFunnelPresentationTokens, look: RenderLook,
        bodyFamily: String?
    ) {
        self.overlay = overlay
        self.tokens = tokens
        self.look = look
        self.bodyFamily = bodyFamily
    }

    var body: some View {
        ZStack {
            // Black on any background, as the popup's scrim (`PopupFormat`).
            Color.black
                .opacity(Double(overlay.scrimOpacity) / Double(FunnelPurchaseOverlayFormat.percent))
                .ignoresSafeArea()
            if overlay.card {
                card
            } else if overlay.spinner {
                spinner
            }
        }
        // Full bleed: the touch area and the accessibility element cover
        // the funnel's whole box, under the system bars too, as the scrim
        // does; the card centres in it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // Every touch lands here and does nothing: the funnel underneath
        // is waiting for the store.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(overlay.announcement))
        .accessibilityAddTraits(.isModal)
        .onAppear {
            UIAccessibility.post(notification: .screenChanged, argument: overlay.announcement)
        }
    }

    /// The look's activity ring (`accent`), the same one an activity block draws.
    private var spinner: some View {
        ProgressView().progressViewStyle(FunnelActivityRingStyle(look: look))
    }

    private var card: some View {
        let scale = FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts)
        let logoSize = CGFloat(tokens.overlayLogoSize)
        return VStack(spacing: CGFloat(tokens.overlayGap)) {
            // An address that is not fetchable media leaves the slot out,
            // as Android does.
            if let logo = overlay.logo.flatMap(funnelMediaURL) {
                FunnelAsyncImage(url: logo, targetWidth: logoSize) {
                    $0.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: logoSize, height: logoSize)
            }
            if overlay.spinner { spinner }
            if let title = overlay.title {
                Text(title)
                    .funnelTextFont(
                        size: CGFloat(tokens.overlayTitleSize), weight: FunnelPurchaseOverlayFormat.titleWeight,
                        family: bodyFamily, scale: scale)
                    .foregroundColor(look.textColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let description = overlay.description {
                Text(description)
                    .funnelTextFont(
                        size: CGFloat(tokens.overlayDescriptionSize), weight: look.textWeight, family: bodyFamily,
                        scale: scale)
                    .foregroundColor(look.mutedColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(CGFloat(tokens.overlayPadding))
        .frame(maxWidth: CGFloat(tokens.overlayMaxWidth))
        .background(
            RoundedRectangle(cornerRadius: CGFloat(tokens.overlayRadius)).fill(look.cardColor))
    }
}

enum FunnelPurchaseOverlayFormat {
    /// `scrimOpacity` is a percent on the wire.
    static let percent: UInt32 = 100
    /// The title is semibold (CSS 600).
    static let titleWeight = 600
    static let curvePoints = 4

    /// The overlay's fade: `fadeMs` on `fadeCurve` (thousandths, cubic
    /// Bézier control points), as the presentation's own fade entrance.
    static func fade(_ tokens: CoreFunnelPresentationTokens) -> Animation {
        let seconds = Double(tokens.fadeMs) / FunnelPresentationFormat.millisecondsPerSecond
        guard tokens.fadeCurve.count == curvePoints else { return .easeInOut(duration: seconds) }
        let p = tokens.fadeCurve.map { Double($0) / Double(FunnelPresentationFormat.thousandths) }
        return .timingCurve(p[0], p[1], p[2], p[3], duration: seconds)
    }
}
#endif
