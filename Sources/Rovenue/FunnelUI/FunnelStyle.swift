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
    /// `#RRGGBBAA`: the alpha byte last.
    static let hexDigitsWithAlpha = 8
    static let alphaBits: UInt32 = 8
    static let channelMask: UInt32 = 0xFF
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
    /// `opacity` is a percentage on the wire (80 = 0.8).
    static let opacityPercent = 100.0
    static let opaque = 1.0
    /// An authored `dashed` border (spec A Part B): CSS's dash rhythm —
    /// each dash three widths long, each gap two — so the three drawers
    /// agree on a pattern the wire leaves to the platform.
    static let dashed = "dashed"
    static let dashWidths: CGFloat = 3
    static let gapWidths: CGFloat = 2
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

/// `#RRGGBB`, or `#RRGGBBAA` with the alpha byte LAST (CSS order) — the
/// wire formats the dashboard writes. Anything else is "no override": a
/// draft saves mid-edit, so a malformed colour must not crash a shipped app.
func funnelColor(_ hex: String?) -> Color? {
    guard var raw = hex, raw.first == StyleFormat.hexPrefix else { return nil }
    raw.removeFirst()
    guard raw.count == StyleFormat.hexDigits || raw.count == StyleFormat.hexDigitsWithAlpha,
        raw.allSatisfy(\.isHexDigit),
        let value = UInt32(raw, radix: StyleFormat.radix)
    else { return nil }
    // Six digits are opaque; eight carry alpha in the low byte.
    let rgb = raw.count == StyleFormat.hexDigits ? value : value >> StyleFormat.alphaBits
    let alpha =
        raw.count == StyleFormat.hexDigits
        ? StyleFormat.opaque : Double(value & StyleFormat.channelMask) / StyleFormat.maxChannel
    return Color(
        .sRGB,
        red: Double((rgb >> 16) & StyleFormat.channelMask) / StyleFormat.maxChannel,
        green: Double((rgb >> 8) & StyleFormat.channelMask) / StyleFormat.maxChannel,
        blue: Double(rgb & StyleFormat.channelMask) / StyleFormat.maxChannel,
        opacity: alpha
    )
}

func funnelAlignment(_ align: String?) -> HorizontalAlignment {
    switch align {
    case "center": return .center
    case "right": return .trailing
    default: return .leading
    }
}

/// A block's own `alignSelf` (`start|center|end`, logical) across a
/// column, or nil when it set none.
func funnelSelfAlignment(_ alignSelf: String?) -> HorizontalAlignment? {
    switch alignSelf {
    case RenderStyle.alignSelfStart: return .leading
    case RenderStyle.alignSelfCenter: return .center
    case RenderStyle.alignSelfEnd: return .trailing
    default: return nil
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
        self.funnelBox(style, type).funnelOuter(style)
    }

    /// `funnelStyle`'s inner half: the block's own box — type, height,
    /// width, padding, fill, corners and outline. A container draws its
    /// ABSOLUTE children over this box (`funnelPinned`), before
    /// `funnelOuter` fades and spaces the whole block.
    func funnelBox(_ style: RenderStyle, _ type: FunnelType) -> some View {
        self
            .funnelTypography(style, type)
            .funnelFixedHeight(style)
            .modifier(FunnelWidthFit(style: style))
            // Padding before the background, so the fill covers the
            // padded box — the CSS padding box, as the web draws it.
            .padding(.top, style.paddingTop.map(CGFloat.init) ?? StyleFormat.noPadding)
            .padding(.trailing, style.paddingRight.map(CGFloat.init) ?? StyleFormat.noPadding)
            .padding(.bottom, style.paddingBottom.map(CGFloat.init) ?? StyleFormat.noPadding)
            .padding(.leading, style.paddingLeft.map(CGFloat.init) ?? StyleFormat.noPadding)
            .background(funnelColor(style.background))
            // Only an authored radius (or per-corner radii) rounds — and
            // so clips — the box: an absent one leaves the ink free to
            // spill past it as CSS's `overflow: visible` does (a tight line
            // box's descenders and accents, spec F §8 L1);
            // `.cornerRadius(0)` would cut them. The outline follows the
            // rounded shape, inside the margins so it outlines the control
            // rather than the space around it.
            .modifier(FunnelBoxCorners(style: style))
    }

    /// `funnelStyle`'s outer half: the whole block's opacity, then its margins.
    func funnelOuter(_ style: RenderStyle) -> some View {
        self
            .opacity(style.opacity.map { Double($0) / StyleFormat.opacityPercent } ?? StyleFormat.opaque)
            .padding(.top, style.marginTop.map(CGFloat.init) ?? StyleFormat.noMargin)
            .padding(.bottom, style.marginBottom.map(CGFloat.init) ?? StyleFormat.noMargin)
            .padding(.leading, style.marginLeft.map(CGFloat.init) ?? StyleFormat.noMargin)
            .padding(.trailing, style.marginRight.map(CGFloat.init) ?? StyleFormat.noMargin)
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
    fileprivate func funnelBorder(_ style: RenderStyle, shape: FunnelBoxShape) -> some View {
        if let width = style.borderWidth, let color = funnelColor(style.borderColor) {
            let line = CGFloat(width)
            self.overlay(
                shape
                .strokeBorder(
                    color,
                    style: StrokeStyle(
                        lineWidth: line,
                        dash: style.borderStyle == StyleFormat.dashed
                            ? [line * StyleFormat.dashWidths, line * StyleFormat.gapWidths] : []))
            )
        } else {
            self
        }
    }
}

extension View {
    /// A paint-time rotation in whole degrees (spec E §6), already clamped
    /// and RTL-negated by the resolver; nil draws unturned. The layout box
    /// is the unrotated one — `rotationEffect` never moves a sibling — and
    /// hit testing follows the turned shape.
    @ViewBuilder
    func funnelRotation(_ degrees: Int?) -> some View {
        if let degrees, degrees != 0 {
            self.rotationEffect(.degrees(Double(degrees)))
        } else {
            self
        }
    }
}

/// A block's rounded box: one `radius` on every corner, or — the author
/// wrote `corners` (spec 2026-11-27 K) — a radius per LOGICAL corner,
/// mirrored for a right-to-left layout. Drawn by hand rather than with
/// `UnevenRoundedRectangle`, which needs iOS 17 (the SDK supports 16).
/// Each radius is capped at half the shorter side, as CSS and
/// `RoundedRectangle` draw an oversized one.
struct FunnelBoxShape: InsettableShape {
    var topLeading: CGFloat
    var topTrailing: CGFloat
    var bottomLeading: CGFloat
    var bottomTrailing: CGFloat
    var rightToLeft = false
    var inset: CGFloat = 0

    /// `style`'s shape: its corners when authored, else its radius
    /// (none: square).
    init(_ style: RenderStyle, rightToLeft: Bool) {
        if let c = style.corners {
            topLeading = CGFloat(c.topStart)
            topTrailing = CGFloat(c.topEnd)
            bottomLeading = CGFloat(c.bottomStart)
            bottomTrailing = CGFloat(c.bottomEnd)
        } else {
            let r = style.radius.map(CGFloat.init) ?? StyleFormat.noRadius
            topLeading = r
            topTrailing = r
            bottomLeading = r
            bottomTrailing = r
        }
        self.rightToLeft = rightToLeft
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let cap = max(0, min(r.width, r.height) / 2)
        let clamp = { (v: CGFloat) in max(0, min(v - inset, cap)) }
        // Physical corners: leading is the right edge in RTL.
        let tl = clamp(rightToLeft ? topTrailing : topLeading)
        let tr = clamp(rightToLeft ? topLeading : topTrailing)
        let bl = clamp(rightToLeft ? bottomTrailing : bottomLeading)
        let br = clamp(rightToLeft ? bottomLeading : bottomTrailing)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(
            center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(
            center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(
            center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(
            center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> FunnelBoxShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// `funnelBox`'s corners and outline: clipped to `FunnelBoxShape` when the
/// author rounded the box (a radius or corners), then the outline in the
/// same shape.
private struct FunnelBoxCorners: ViewModifier {
    let style: RenderStyle
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        let shape = FunnelBoxShape(style, rightToLeft: layoutDirection == .rightToLeft)
        content
            .ifLet(style.radius != nil || style.corners != nil ? shape : nil) { $0.clipShape($1) }
            .funnelBorder(style, shape: shape)
    }
}

/// Fit hugs the content; nothing else needs a frame here. In an
/// arrangement (`FunnelArrangement`) the layout sizes and places the box —
/// a column offers the full width (an unwritten width fills it), a row
/// offers each child its own width — so a fit box only stops growing.
/// Outside one (the sticky footer) a fit box keeps today's placement: its
/// own `align` across the full width.
private struct FunnelWidthFit: ViewModifier {
    let style: RenderStyle
    @Environment(\.funnelParentFlow) private var flow

    func body(content: Content) -> some View {
        if let widthPt = style.widthPt {
            // A Fixed width (spec 2026-11-27 F): exactly this wide, placed
            // like a fit box — by its arrangement, or outside one by its
            // own `align` across the full width.
            if flow == nil {
                content
                    .frame(width: CGFloat(widthPt))
                    .frame(
                        maxWidth: .infinity,
                        alignment: Alignment(horizontal: funnelAlignment(style.align), vertical: .center))
            } else {
                content.frame(width: CGFloat(widthPt))
            }
        } else if style.width != RenderStyle.widthFit {
            content
        } else if flow == nil {
            content
                .fixedSize(horizontal: true, vertical: false)
                .frame(
                    maxWidth: .infinity,
                    alignment: Alignment(horizontal: funnelAlignment(style.align), vertical: .center))
        } else {
            content.fixedSize(horizontal: true, vertical: false)
        }
    }
}
