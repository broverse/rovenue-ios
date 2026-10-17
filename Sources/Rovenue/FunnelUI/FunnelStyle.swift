//  FunnelStyle.swift — RenderStyle as SwiftUI modifiers.
//
//  This is the ONLY derivation a drawer performs, and it is a type
//  conversion, not a decision: the resolver already merged the funnel theme
//  into every block's style. Nothing here chooses a value.

import CoreText
import SwiftUI

private enum StyleFormat {
    static let hexPrefix: Character = "#"
    static let hexDigits = 6
    static let radix = 16
    static let maxChannel = 255.0
    /// The size CoreText is asked to build a font at when the ONLY
    /// question is which family it resolves to. Never drawn: the drawn size
    /// is the block's or the look's (`funnelFont` in FunnelLook.swift).
    static let familyProbeSize: CGFloat = 12
    static let noRadius: CGFloat = 0
    static let noMargin: CGFloat = 0
    static let noPadding: CGFloat = 0
    /// The one `textDecoration` the wire can carry.
    static let underline = "underline"
    /// The only width the wire writes — Fill is the absence of the key.
    static let widthFit = "fit"
    /// `opacity` is a percentage on the wire (80 = 0.8).
    static let opacityPercent = 100.0
    static let opaque = 1.0
}

/// A button's label, underlined when the resolver asked for it.
///
/// `Text.underline` rather than the `View` modifier of the same name: the
/// latter is macOS 13 / iOS 16, and this package still ships to
/// `.macOS(.v12)`, where the tests also run. A `Text` has carried the
/// modifier since macOS 10.15.
///
/// Not folded into `funnelStyle` for that reason — `funnelStyle` applies to a
/// `View`, and by the time a `Button` exists its label is no longer a
/// `Text` this file can decorate.
func funnelLabel(_ label: String, _ style: RenderStyle) -> Text {
    Text(label).underline(style.textDecoration == StyleFormat.underline)
}

/// `#RRGGBB` only — the wire format the dashboard writes. Anything else is
/// "no override": a draft saves mid-edit, so a malformed colour must not
/// crash a shipped app.
func funnelColor(_ hex: String?) -> Color? {
    guard var raw = hex, raw.first == StyleFormat.hexPrefix else { return nil }
    raw.removeFirst()
    guard raw.count == StyleFormat.hexDigits,
        let value = UInt32(raw, radix: StyleFormat.radix)
    else { return nil }
    return Color(
        red: Double((value >> 16) & 0xFF) / StyleFormat.maxChannel,
        green: Double((value >> 8) & 0xFF) / StyleFormat.maxChannel,
        blue: Double(value & 0xFF) / StyleFormat.maxChannel
    )
}

func funnelAlignment(_ align: String?) -> HorizontalAlignment {
    switch align {
    case "center": return .center
    case "right": return .trailing
    default: return .leading
    }
}

func funnelTextAlignment(_ align: String?) -> TextAlignment {
    switch align {
    case "center": return .center
    case "right": return .trailing
    default: return .leading
    }
}

/// The SwiftUI weight for a CSS weight: the nearest row of
/// `funnelCSSWeights` (100–900), as Android's `Typeface.create(…, weight, …)`
/// and the browser's CSS draw every one of them. No weight is regular.
func funnelFontWeight(_ weight: Int?) -> Font.Weight {
    guard let weight else { return .regular }
    return funnelCSSWeight(nearest: weight).font
}

/// The family to use, or nil for the system face.
///
/// `fontFamily` is a family NAME, and the resolver does not know which
/// fonts the app bundles — so this asks the platform what is actually
/// installed and falls back when it is not. It never downloads one,
/// because a drawer performs no I/O.
///
/// Split out from `funnelFont` because it is the DECISION, and SwiftUI's
/// `Font` cannot be meaningfully compared in a test: two `.system` fonts
/// with identical parameters are not `==`. Testing the family name tests
/// the thing that can be wrong.
func funnelResolvedFontFamily(_ stack: String?) -> String? {
    // A theme font arrives as a CSS stack (`'Fraunces', Georgia, serif`);
    // the face asked for is its first family (`FunnelFonts.swift`).
    guard let family = funnelPrimaryFamily(stack) else { return nil }
    // CoreText rather than UIFont: UIKit is absent on macOS, where the
    // tests run, so a `canImport(UIKit)` guard compiles the check away
    // exactly where it would be exercised. CTFont substitutes a fallback
    // face for an unknown name, so comparing the family it actually
    // produced is what detects the substitution.
    let font = CTFontCreateWithName(family as CFString, StyleFormat.familyProbeSize, nil)
    let resolved = CTFontCopyFamilyName(font) as String
    return resolved.caseInsensitiveCompare(family) == .orderedSame ? family : nil
}

extension View {
    /// Applies a block's resolved style over the look's `type`. Every
    /// style value is optional, and an absent one means "the look's" or
    /// "inherit" — never a default invented here.
    func funnelStyle(_ style: RenderStyle, _ type: FunnelType) -> some View {
        self
            .funnelTypography(style, type)
            .funnelFixedHeight(style)
            .funnelWidthFit(style)
            // Padding before the background, so the fill covers the
            // padded box — the CSS padding box, as the web draws it.
            .padding(.top, style.paddingTop.map(CGFloat.init) ?? StyleFormat.noPadding)
            .padding(.trailing, style.paddingRight.map(CGFloat.init) ?? StyleFormat.noPadding)
            .padding(.bottom, style.paddingBottom.map(CGFloat.init) ?? StyleFormat.noPadding)
            .padding(.leading, style.paddingLeft.map(CGFloat.init) ?? StyleFormat.noPadding)
            .background(funnelColor(style.background))
            .cornerRadius(style.radius.map(CGFloat.init) ?? StyleFormat.noRadius)
            // After the corner radius so the outline follows the rounded
            // shape, and before the margins so it outlines the control
            // rather than the space around it.
            .funnelBorder(style)
            .opacity(style.opacity.map { Double($0) / StyleFormat.opacityPercent } ?? StyleFormat.opaque)
            .padding(.top, style.marginTop.map(CGFloat.init) ?? StyleFormat.noMargin)
            .padding(.bottom, style.marginBottom.map(CGFloat.init) ?? StyleFormat.noMargin)
            .padding(.leading, style.marginLeft.map(CGFloat.init) ?? StyleFormat.noMargin)
            .padding(.trailing, style.marginRight.map(CGFloat.init) ?? StyleFormat.noMargin)
    }

    /// Fit wraps the content and `align` positions the box; Fill (nil)
    /// is no frame at all — the drawer's current full width.
    @ViewBuilder
    fileprivate func funnelWidthFit(_ style: RenderStyle) -> some View {
        if style.width == StyleFormat.widthFit {
            self
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: funnelAlignment(style.align), vertical: .center))
        } else {
            self
        }
    }

    /// A Fixed height is the box, not a floor: the frame plus a clip, so
    /// content past it is cut, as the web (`height` + `overflow: hidden`)
    /// and Android (exact layout height) draw it. Absent means no frame
    /// at all — an unconditional `.clipped()` would also cut shadows and
    /// overflows the look never asked to cut.
    @ViewBuilder
    fileprivate func funnelFixedHeight(_ style: RenderStyle) -> some View {
        if let height = style.height {
            self.frame(height: CGFloat(height)).clipped()
        } else {
            self
        }
    }

    /// The outline the resolver asked for, or nothing at all.
    ///
    /// `strokeBorder` rather than `stroke`: `stroke` centres the line on
    /// the shape's edge, so half of it falls outside the control and gets
    /// clipped. Nothing is invented when either half of the pair is
    /// absent — the resolver writes width and colour together.
    @ViewBuilder
    fileprivate func funnelBorder(_ style: RenderStyle) -> some View {
        if let width = style.borderWidth, let color = funnelColor(style.borderColor) {
            self.overlay(
                RoundedRectangle(
                    cornerRadius: style.radius.map(CGFloat.init) ?? StyleFormat.noRadius
                )
                .strokeBorder(color, lineWidth: CGFloat(width))
            )
        } else {
            self
        }
    }
}
