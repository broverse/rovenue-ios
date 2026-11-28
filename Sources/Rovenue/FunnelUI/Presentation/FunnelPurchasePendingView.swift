//  FunnelPurchasePendingView.swift — a deferred purchase's notice over a
//  presented funnel (spec 2026-11-22-funnel-purchase-pending).
//
//  Drawn the way the purchase overlay is (`FunnelPurchaseOverlayView`): a
//  black scrim — the authored overlay's opacity, else the presentation's
//  `dimPercent` — and a centred card in the current look holding the
//  authored overlay's logo when there is one, the notice's title and
//  detail, and a "Continue" button in the look's accent that puts it away.
//  No spinner: a pending payment may take days, so nothing suggests it will
//  end on screen. Touches outside the card do nothing; assistive tech reads
//  title and detail as one element, then the button.

#if os(iOS)
import SwiftUI
import UIKit

struct FunnelPurchasePendingView: View {
    let notice: RenderPurchasePending
    /// The authored purchase overlay, for its scrim and logo; nil when the
    /// funnel authors none.
    let overlay: CoreFunnelPurchaseOverlay?
    let tokens: CoreFunnelPresentationTokens
    let look: RenderLook
    let bodyFamily: String?
    let onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts

    private var announcement: String { "\(notice.title). \(notice.detail)" }

    var body: some View {
        ZStack {
            Color.black
                .opacity(Double(overlay?.scrimOpacity ?? tokens.dimPercent) / Double(FunnelPurchaseOverlayFormat.percent))
                .ignoresSafeArea()
                .accessibilityHidden(true)
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // Every touch outside the card lands here and does nothing.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { announce() }
        .onChange(of: notice) { _ in announce() }
    }

    private func announce() {
        UIAccessibility.post(notification: .screenChanged, argument: announcement)
    }

    private var card: some View {
        let scale = FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts)
        let logoSize = CGFloat(tokens.overlayLogoSize)
        return VStack(spacing: CGFloat(tokens.overlayGap)) {
            VStack(spacing: CGFloat(tokens.overlayGap)) {
                if let logo = overlay?.logo.flatMap(funnelMediaURL) {
                    FunnelAsyncImage(url: logo, targetWidth: logoSize) {
                        $0.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: logoSize, height: logoSize)
                }
                Text(notice.title)
                    .funnelTextFont(
                        size: CGFloat(tokens.overlayTitleSize), weight: FunnelPurchaseOverlayFormat.titleWeight,
                        family: bodyFamily, scale: scale)
                    .foregroundColor(look.textColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notice.detail)
                    .funnelTextFont(
                        size: CGFloat(tokens.overlayDescriptionSize), weight: look.textWeight, family: bodyFamily,
                        scale: scale)
                    .foregroundColor(look.mutedColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(announcement))
            Button(action: onDismiss) {
                Text(notice.action)
                    .funnelTextFont(
                        size: CGFloat(look.buttonFontSize), weight: look.buttonFontWeight, family: bodyFamily,
                        scale: scale)
                    .foregroundColor(look.onAccentColor)
                    .padding(.horizontal, CGFloat(look.buttonPaddingX))
                    .padding(.vertical, CGFloat(look.buttonPaddingY))
                    .frame(maxWidth: .infinity, minHeight: CGFloat(look.buttonMinHeight))
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(look.cardRadius)).fill(look.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(CGFloat(tokens.overlayPadding))
        .frame(maxWidth: CGFloat(tokens.overlayMaxWidth))
        .background(
            RoundedRectangle(cornerRadius: CGFloat(tokens.overlayRadius)).fill(look.cardColor))
        .padding(CGFloat(tokens.overlayPadding))
    }
}
#endif
