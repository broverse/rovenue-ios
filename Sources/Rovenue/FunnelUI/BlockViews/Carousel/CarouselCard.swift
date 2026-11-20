//  CarouselCard.swift — a slide's card (spec CL §4.2): the resolver's
//  padding and radius over a filled rounded rectangle — `elevated` adds
//  `look.carousel.cardShadow`, `outlined` a `cardBorderWidth` border, and
//  `glass` is Spec E's surface (FunnelGlassSurface, fallbacks included,
//  V2). No card (`none`) draws the slide as it is. The card fills its
//  slide's box, so every card in a row takes the tallest one's height.

import SwiftUI

struct CarouselCardFrame: ViewModifier {
    let card: RenderCarouselCard?
    let tokens: RenderCarouselLook

    func body(content: Content) -> some View {
        if let card {
            let shape = RoundedRectangle(cornerRadius: CGFloat(card.radius), style: .continuous)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(CGFloat(card.padding))
                .background {
                    if card.style == CarouselFormat.cardGlass {
                        Color.clear.modifier(FunnelGlassSurface(surface: card.glass, radius: card.radius))
                    } else {
                        shape.fill(funnelColor(card.background) ?? .clear)
                    }
                }
                .overlay {
                    if card.style == CarouselFormat.cardOutlined {
                        shape.strokeBorder(
                            funnelColor(card.borderColor ?? card.background) ?? .clear,
                            lineWidth: CGFloat(tokens.cardBorderWidth))
                    }
                }
                .clipShape(shape)
                .background {
                    // The shadow sits outside the clip.
                    if card.style == CarouselFormat.cardElevated, let shadow = card.shadow {
                        shape
                            .fill(funnelColor(card.background) ?? .clear)
                            .shadow(
                                color: funnelColor(shadow.color) ?? .clear,
                                radius: CGFloat(shadow.blur) / CarouselFormat.cssBlurPerShadowRadius,
                                x: 0, y: CGFloat(shadow.y))
                    }
                }
        } else {
            content
        }
    }
}
