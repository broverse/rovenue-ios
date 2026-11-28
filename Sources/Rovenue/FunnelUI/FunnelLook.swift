//  FunnelLook.swift — the screen's `RenderLook` as SwiftUI.
//
//  The look travels on the SCREEN (`RenderScreen.look`, resolved once by
//  funnel-core-rs/src/look.rs) and is handed down to every block view the
//  same way `FunnelInteraction` is. Every length, size, weight and colour a
//  block draws with comes from the look — or from the block's own
//  `RenderStyle`, which wins wherever it speaks. Nothing here invents a
//  number: the web renderer (`packages/funnel-renderer/src/look.tsx`,
//  `button-chrome.ts`, `blocks/row-card.tsx`) and Android draw from the same
//  table, and a private number here is the drift this whole look exists to
//  end.

import CoreText
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

private enum LookFormat {
    /// `lineHeight` is a percentage on the wire (145 = 1.45×).
    static let lineHeightPercent: CGFloat = 100
    /// The CSS weight whose face sets an uploaded family's line height.
    static let regularWeight = 400
    /// `letterSpacing` is thousandths of an em on the wire (−20 = −0.02 em).
    static let letterSpacingPerEm: CGFloat = 1000
    /// A held control reads as held: the spec's "Disabled: 50% opacity",
    /// the same value the web's `HELD_CONTROL_STYLE` wears.
    static let heldOpacity = 0.5
    static let fullOpacity = 1.0
    /// An authored `heldOpacity` is a percentage on the wire (40 = 0.4).
    static let percent = 100.0
    /// A busy chromed button's label: laid out, not drawn.
    static let hiddenOpacity = 0.0
    /// How long the activity ring takes to turn once — the web's
    /// `ACTIVITY_TURN_MS`. Motion, not layout, so it is not in the look.
    static let activityTurnSeconds = 0.8
    static let fullTurnDegrees = 360.0
    /// The ring's drawn arc: three quarters, one quarter open — the web's
    /// `borderTopColor: transparent`.
    static let ringArc: CGFloat = 0.75
    static let half: CGFloat = 2
    /// The look's press scales are percents on the wire (97 = 0.97×).
    static let scalePercent: CGFloat = 100
    static let restingScale: CGFloat = 1
    /// `pressMs` is milliseconds; SwiftUI animations take seconds.
    static let millisecondsPerSecond = 1000.0
    /// Spec F §8 H3: a selected radio's inner dot as a share of
    /// `indicatorSize` — the web's `INDICATOR_DOT_RATIO` (P129/P130).
    static let indicatorDotRatio: CGFloat = 0.4
}

// MARK: - Values

/// A `#RRGGBB` the RESOLVER wrote. The look's colours are always opaque
/// hex (look.rs derives them), so the clear fallback is unreachable for a
/// resolved screen; it exists only so a type conversion cannot crash.
func lookColor(_ hex: String) -> Color {
    funnelColor(hex) ?? .clear
}

extension RenderLook {
    var textColor: Color { lookColor(text) }
    var accentColor: Color { lookColor(accent) }
    var cardColor: Color { lookColor(card) }
    var borderColor: Color { lookColor(border) }
    var mutedColor: Color { lookColor(muted) }
    var onAccentColor: Color { lookColor(onAccent) }
    var tableHighlightColor: Color { lookColor(tableHighlight) }
    var dangerColor: Color { lookColor(danger) }
}

// MARK: - Spec NE element tokens

/// `look.elements` (spec 2026-11-10 NE §6) in the units SwiftUI takes:
/// every number a countdown, popup, loader, Lottie or chart draws with. The
/// wire carries percents (opacity, digit scale) and per-mille ratios; the
/// conversions live here, once.
enum FunnelElementLook {
    static let percent = 100.0
    static let perMille = 1000.0
}

extension RenderLook {
    /// The popup's scrim, as an opacity.
    var popupScrimOpacity: Double { Double(elements.popup.scrimOpacity) / FunnelElementLook.percent }
    /// The countdown's digits: the body size scaled by `digitScale`.
    var countdownDigitSize: CGFloat {
        CGFloat(textSize) * CGFloat(elements.countdown.digitScale) / CGFloat(FunnelElementLook.percent)
    }
    /// The chart's area fill, as an opacity.
    var chartAreaOpacity: Double { Double(elements.chart.areaOpacity) / FunnelElementLook.percent }
    /// A per-mille chart coordinate as a share of its box.
    func chartShare(_ perMille: Int) -> CGFloat { CGFloat(perMille) / CGFloat(FunnelElementLook.perMille) }
}

/// A size and a weight, the pair every run of copy is drawn with.
struct FunnelType: Equatable {
    let size: Int
    let weight: Int
}

extension RenderLook {
    var bodyType: FunnelType { FunnelType(size: textSize, weight: textWeight) }
    var labelType: FunnelType { FunnelType(size: textSize, weight: labelWeight) }
    var emphasisType: FunnelType { FunnelType(size: textSize, weight: emphasisWeight) }
    var mutedType: FunnelType { FunnelType(size: mutedTextSize, weight: textWeight) }
    var buttonType: FunnelType { FunnelType(size: buttonFontSize, weight: buttonFontWeight) }
    var linkType: FunnelType { FunnelType(size: linkFontSize, weight: labelWeight) }
    func headingType(level: Int) -> FunnelType {
        FunnelType(size: headingSize(level: level), weight: headingWeight)
    }
}

/// Synthetic bold (review R5): a weight the funnel uploaded no face for
/// (`FunnelUploadedDraw.synthesizedBold`) is drawn the way Skia (Chrome,
/// Android) fakes it — the glyph outline grown by a stroke `size × ratio`
/// wide, the ratio 1/24 at 9 pt and below, 1/32 at 36 pt and above, linear
/// between (`SkScalerContext`'s `kStdFakeBoldInterp*`). CoreText offers no
/// emboldening (no trait copy, SwiftUI `.bold()` draws the same pixels), so
/// SwiftUI draws two hidden copies of the text over it, offset half the
/// stroke left and right; layout, wrapping and hit testing are the
/// original's. UIKit and AppKit text inputs stroke the glyphs instead
/// (`funnelFakeBoldAttributes`).
enum FunnelFakeBoldFormat {
    static let smallSize: CGFloat = 9
    static let largeSize: CGFloat = 36
    static let smallRatio: CGFloat = 1.0 / 24
    static let largeRatio: CGFloat = 1.0 / 32
    static let half: CGFloat = 2
    static let percent: CGFloat = 100

    /// The stroke width Skia grows a `size`-point glyph by.
    static func stroke(size: CGFloat) -> CGFloat {
        let t = min(max((size - smallSize) / (largeSize - smallSize), 0), 1)
        return size * (smallRatio + (largeRatio - smallRatio) * t)
    }
}

/// The fake-bold stroke text at `size`/`weight` in `family` (in `italic`
/// when the run is, whose face may differ) is drawn with, or nil when its
/// face is real (or not an uploaded family). Built-in and system faces
/// have real weights and are never emboldened.
func funnelFakeBoldStroke(
    size: CGFloat, weight: Int, family: String?, scale: FunnelTextScale, italic: Bool = false
) -> CGFloat? {
    guard scale.fonts.face(family, weight: weight, italic: italic)?.synthesizedBold == true else { return nil }
    return FunnelFakeBoldFormat.stroke(size: scale(size))
}

/// The same synthesised bold for UIKit text (a field): its
/// `NSAttributedString.Key.strokeWidth` — negative, so the glyphs are
/// filled AND stroked; a percentage of the point size, the stroke centred on
/// the outline as Skia's is. 0 when the face is real.
func funnelFakeBoldStrokePercent(size: CGFloat, weight: Int, family: String?, scale: FunnelTextScale) -> CGFloat {
    guard let stroke = funnelFakeBoldStroke(size: size, weight: weight, family: family, scale: scale) else { return 0 }
    return -stroke / scale(size) * FunnelFakeBoldFormat.percent
}

/// The text attributes that draw the same synthesised bold in UIKit and
/// AppKit text (fields, text areas, a field's suffix): the glyphs filled
/// AND stroked `strokePercent` (`funnelFakeBoldStrokePercent`, 0: none) in
/// the text's own `color`.
func funnelFakeBoldAttributes(strokePercent: CGFloat, color: Any) -> [NSAttributedString.Key: Any] {
    [.strokeWidth: strokePercent, .strokeColor: color]
}

/// Draws `content` emboldened by `stroke` (nil: unchanged) — see
/// `FunnelFakeBoldFormat`. The copies are hidden from VoiceOver and take no
/// touches.
struct FunnelFakeBold: ViewModifier {
    let stroke: CGFloat?

    func body(content: Content) -> some View {
        if let stroke {
            content.overlay {
                ZStack {
                    content.offset(x: -stroke / FunnelFakeBoldFormat.half)
                    content.offset(x: stroke / FunnelFakeBoldFormat.half)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

/// The fake-bold stroke an enclosing `funnelTypography` asks of copy that
/// draws in ITS font (a text block, a button label, a quote) — read by
/// `funnelInheritedFakeBold()` on that copy, never by copy with its own font.
private struct FunnelInheritedBoldKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var funnelInheritedBold: CGFloat? {
        get { self[FunnelInheritedBoldKey.self] }
        set { self[FunnelInheritedBoldKey.self] = newValue }
    }
}

private struct FunnelInheritedFakeBold: ViewModifier {
    @Environment(\.funnelInheritedBold) private var stroke
    func body(content: Content) -> some View { content.modifier(FunnelFakeBold(stroke: stroke)) }
}

extension View {
    /// The font `funnelFont(size:…)` gives, synthesised bold when the funnel
    /// uploaded no face that heavy.
    func funnelTextFont(size: CGFloat, weight: Int, family: String?, scale: FunnelTextScale) -> some View {
        font(funnelFont(size: size, weight: weight, family: family, scale: scale))
            .modifier(FunnelFakeBold(stroke: funnelFakeBoldStroke(size: size, weight: weight, family: family, scale: scale)))
    }

    /// `funnelFont(_:_:scale:)`, synthesised bold likewise.
    func funnelTextFont(_ style: RenderStyle, _ type: FunnelType, scale: FunnelTextScale) -> some View {
        funnelTextFont(
            size: CGFloat(style.fontSize ?? type.size), weight: style.fontWeight ?? type.weight,
            family: style.fontFamily, scale: scale)
    }

    /// A row's text at one of its sizes (`FunnelRowText`).
    func funnelTextFont(_ text: FunnelRowText, size: CGFloat, weight: Int) -> some View {
        funnelTextFont(size: size, weight: weight, family: text.family, scale: text.scale)
    }

    /// Copy drawn in the enclosing `funnelTypography`'s font: emboldened
    /// as that font asks.
    func funnelInheritedFakeBold() -> some View { modifier(FunnelInheritedFakeBold()) }
}

/// The font a run of copy draws with: the block's own size, weight and
/// family where it set them, the look's `type` otherwise.
func funnelFont(_ style: RenderStyle, _ type: FunnelType, scale: FunnelTextScale) -> Font {
    funnelFont(
        size: CGFloat(style.fontSize ?? type.size), weight: style.fontWeight ?? type.weight,
        family: style.fontFamily, scale: scale)
}

/// A font at an exact size — a row's secondary size is a ratio of its
/// primary one, so it need not be whole. `family` is the AUTHORED name;
/// one the device does not have draws in the system face.
func funnelFont(size: CGFloat, weight: Int, family: String?, scale: FunnelTextScale) -> Font {
    // A family the project uploaded is drawn by its registered face's
    // PostScript name — the face IS the weight, so no `.weight` on top
    // (SwiftUI's `.weight`/`.bold()` cannot embolden a one-face family:
    // a synthesised bold is drawn by the view, `funnelFakeBold`).
    if let face = scale.fonts.face(family, weight: weight, italic: false) {
        return .custom(face.postScriptName, size: size)
    }
    let w = funnelFontWeight(weight)
    guard let family = funnelResolvedFontFamily(family) else {
        // `.system(size:)` is fixed: it ignores Dynamic Type, while a
        // custom family (below, relative to `.body`) and every Android
        // TextView (sp) follow the text-size setting. Scaled the way
        // `.custom(_:size:)` scales, by the same environment value, so both
        // faces grow alike; exactly 1× at the default size.
        return .system(size: scale(size), weight: w)
    }
    return .custom(family, size: size).weight(w)
}

/// The text size the funnel draws at: the view's
/// `@Environment(\.dynamicTypeSize)` — the device's setting, or a host's
/// `.dynamicTypeSize(...)` override — the ONE value system-face text, the
/// line box and tracking scale by. `Font.custom(_:size:)` scales by that
/// same environment value by itself, so both faces always agree, and a
/// view that reads it redraws the moment it changes (spec F1 of
/// docs/superpowers/plans/2026-11-03-funnel-followup-fixes.md).
struct FunnelTextScale: Equatable {
    let dynamicType: DynamicTypeSize
    /// The funnel's uploaded faces (`EnvironmentValues.funnelFonts`): which
    /// file a family draws is the funnel's own, so it travels with the
    /// value every font call already takes.
    var fonts: FunnelSessionFonts = .none

    init(dynamicType: DynamicTypeSize, fonts: FunnelSessionFonts = .none) {
        self.dynamicType = dynamicType
        self.fonts = fonts
    }

    /// `size` scaled as `.body` text scales at `dynamicType`. Unchanged
    /// where there is no UIKit (the macOS test host).
    func callAsFunction(_ size: CGFloat) -> CGFloat {
        #if canImport(UIKit) && !os(watchOS)
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicType))
            return UIFontMetrics(forTextStyle: .body).scaledValue(for: size, compatibleWith: traits)
        #else
            return size
        #endif
    }
}

/// Every CSS weight, CoreText's normalised weight trait for it
/// (`kCTFontWeightTrait`, `NSFont.Weight`'s values — CoreText reads a face's
/// OS/2 weight class onto the same scale) and the SwiftUI weight that draws
/// it. The ONE weight table: an upright run's `Font.Weight` and an italic
/// run's face both come from it. The trait scale is NOT even (500 sits
/// nearer 700 than 400), so faces are compared by the CSS weight read back
/// from their trait, never by trait distance (spec 2026-10-12-open-followups
/// §4 review fixes, "Closing items" A1).
let funnelCSSWeights: [(css: Int, trait: CGFloat, font: Font.Weight)] = [
    (100, -0.8, .ultraLight), (200, -0.6, .thin), (300, -0.4, .light),
    (400, 0, .regular), (500, 0.23, .medium), (600, 0.3, .semibold),
    (700, 0.4, .bold), (800, 0.56, .heavy), (900, 0.62, .black),
]

/// The row nearest a CSS weight; the lighter row wins a tie (450 → 400).
/// The schema admits the nine rows (100–900); an off-row weight snaps here.
func funnelCSSWeight(nearest weight: Int) -> (css: Int, trait: CGFloat, font: Font.Weight) {
    funnelCSSWeights.min { abs($0.css - weight) < abs($1.css - weight) }!
}

/// The CSS weight whose trait is nearest `trait` — what a registered face is.
private func cssWeight(ofTrait trait: CGFloat) -> Int {
    funnelCSSWeights.min { abs($0.trait - trait) < abs($1.trait - trait) }!.css
}

/// The family's REAL italic face nearest `weight`, or nil when the device
/// has none registered (spec 2026-10-12-open-followups §4).
///
/// Asked of CoreText directly because `Font.custom(family).italic()` does
/// not reach a registered italic member of a custom family — it draws the
/// roman, upright (measured: identical ink widths). The descriptor match
/// lists every face CoreText has for the family; the italic ones are kept
/// and the nearest weight wins.
func funnelItalicFont(size: CGFloat, weight: Int, family: String?, scale: FunnelTextScale) -> Font? {
    // An uploaded family's italic face, by name; one with none is the
    // upright face slanted (review R5, as browsers and Android synthesise).
    if let face = scale.fonts.face(family, weight: weight, italic: true) {
        return Font(funnelUploadedCTFont(face, size: scale(size)))
    }
    guard let family = funnelResolvedFontFamily(family) else { return nil }
    let query = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
    guard let faces = CTFontDescriptorCreateMatchingFontDescriptors(query, nil) as? [CTFontDescriptor] else {
        return nil
    }
    func traits(_ face: CTFontDescriptor) -> [CFString: Any] {
        CTFontDescriptorCopyAttribute(face, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
    }
    let italic = faces.filter { face in
        let symbolic = (traits(face)[kCTFontSymbolicTrait] as? UInt32) ?? 0
        return CTFontSymbolicTraits(rawValue: symbolic).contains(.traitItalic)
    }
    // Nearest by CSS weight, as Android's `FunnelFontStore.nearest` picks.
    func distance(_ face: CTFontDescriptor) -> Int {
        abs(cssWeight(ofTrait: (traits(face)[kCTFontWeightTrait] as? CGFloat) ?? 0) - weight)
    }
    let nearest = italic.min { distance($0) < distance($1) }
    guard let nearest else { return nil }
    // A CTFont is fixed; scaled as `.custom(_:size:)` scales the upright run.
    return Font(CTFontCreateWithFontDescriptor(nearest, scale(size), nil))
}

/// The DRAWN face's own line height at `size` — ascent + descent + leading,
/// as CoreText measures it: the authored family when the device has it,
/// the system face otherwise (spec D9). SwiftUI lays a line out at exactly
/// this, so it is what the look's `lineHeight` is added on top of.
private func naturalLineHeight(_ size: CGFloat, family: String?, fonts: FunnelSessionFonts) -> CGFloat {
    let font: CTFont
    // An uploaded family's line height is its regular face's.
    if let face = fonts.face(family, weight: LookFormat.regularWeight, italic: false) {
        font = CTFontCreateWithName(face.postScriptName as CFString, size, nil)
    } else if let family = funnelResolvedFontFamily(family) {
        font = CTFontCreateWithName(family as CFString, size, nil)
    } else {
        font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("" as CFString, size, nil)
    }
    return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
}

/// The CSS line box the look's `lineHeight` gives a line at `size`.
func funnelLineBox(_ look: RenderLook, size: CGFloat, scale: FunnelTextScale) -> CGFloat {
    funnelLineBox(percent: look.lineHeight, size: size, scale: scale)
}

/// The CSS line box a line height of `percent` gives a line at `size` — a
/// block's own `lineHeight`, or the look's.
func funnelLineBox(percent: Int, size: CGFloat, scale: FunnelTextScale) -> CGFloat {
    // The face grows with Dynamic Type (`funnelFont`), so does its box.
    scale(size) * CGFloat(percent) / LookFormat.lineHeightPercent
}

/// The leading the look's `lineHeight` adds to a line at `size` in
/// `family`: the CSS `line-height` a web line box has, minus what SwiftUI
/// already draws for that face.
func funnelExtraLeading(_ look: RenderLook, size: CGFloat, family: String?, scale: FunnelTextScale) -> CGFloat {
    funnelExtraLeading(percent: look.lineHeight, size: size, family: family, scale: scale)
}

/// The leading a line height of `percent` adds over the face's own —
/// NEGATIVE for a line height tighter than the face's natural one (a 1.15
/// display heading), as a CSS half-leading is.
func funnelExtraLeading(percent: Int, size: CGFloat, family: String?, scale: FunnelTextScale) -> CGFloat {
    funnelLineBox(percent: percent, size: size, scale: scale) - naturalLineHeight(scale(size), family: family, fonts: scale.fonts)
}

/// Tracking a block's `letterSpacing` (thousandths of an em) asks for at
/// `size`, in points; nil when it asks for none.
func funnelTracking(_ style: RenderStyle, size: CGFloat, scale: FunnelTextScale) -> CGFloat? {
    style.letterSpacing.map { CGFloat($0) * scale(size) / LookFormat.letterSpacingPerEm }
}

/// A row's text (spec D2): the block's authored `fontSize` is the PRIMARY
/// size — an option label, a package title and price, a field's text, the
/// slider readout, a scale digit — else the look's `textSize`; SECONDARY
/// text (a description, a period) keeps the look's `mutedTextSize :
/// textSize` ratio to it. The authored family reaches every text of the
/// block; weights stay the look's. `row-card.tsx`'s `rowTextSizes`.
struct FunnelRowText {
    let primary: CGFloat
    let secondary: CGFloat
    let family: String?
    /// The text size the row's view read from its environment.
    let scale: FunnelTextScale

    /// A package list's period line and price suffix (spec F §7 G3): the
    /// block's authored `secondaryTextSize`, else `secondary`.
    let period: CGFloat
    /// The authored G3 size alone — an inline badge keeps the look's badge
    /// size without one.
    let badge: CGFloat?
    /// A package row's caption (spec F §8 H2): the block's authored
    /// `captionTextSize`, else `secondary` — G3 never reaches it.
    let caption: CGFloat

    init(
        look: RenderLook, style: RenderStyle, scale: FunnelTextScale, packageSecondary: Int? = nil,
        packageCaption: Int? = nil
    ) {
        primary = CGFloat(style.fontSize ?? look.textSize)
        secondary = primary * CGFloat(look.mutedTextSize) / CGFloat(look.textSize)
        family = style.fontFamily
        self.scale = scale
        badge = packageSecondary.map(CGFloat.init)
        period = badge ?? secondary
        caption = packageCaption.map(CGFloat.init) ?? secondary
    }

    func primaryFont(weight: Int) -> Font { funnelFont(size: primary, weight: weight, family: family, scale: scale) }
    func secondaryFont(weight: Int) -> Font {
        funnelFont(size: secondary, weight: weight, family: family, scale: scale)
    }
    func periodFont(weight: Int) -> Font { funnelFont(size: period, weight: weight, family: family, scale: scale) }
    func captionFont(weight: Int) -> Font { funnelFont(size: caption, weight: weight, family: family, scale: scale) }
}

// MARK: - Modifiers

/// `funnelTypography`: reads the text size from the environment, so the
/// copy redraws when it changes.
private struct FunnelTypography: ViewModifier {
    let style: RenderStyle
    let type: FunnelType
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts

    func body(content: Content) -> some View {
        let scale = FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts)
        let size = CGFloat(style.fontSize ?? type.size)
        content
            .font(funnelFont(style, type, scale: scale))
            .environment(
                \.funnelInheritedBold,
                funnelFakeBoldStroke(
                    size: size, weight: style.fontWeight ?? type.weight, family: style.fontFamily, scale: scale))
            .ifLet(funnelColor(style.color)) { $0.foregroundColor($1) }
    }
}

/// `funnelLineHeight`: the line box at the environment's text size.
private struct FunnelLineHeight: ViewModifier {
    let percent: Int
    let size: CGFloat
    let family: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts

    @ViewBuilder
    func body(content: Content) -> some View {
        let scale = FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts)
        let extra = funnelExtraLeading(percent: percent, size: size, family: family, scale: scale)
        if extra >= 0 {
            // At or looser than the face's own leading: SwiftUI adds the
            // extra between lines, half of it above and below (unchanged).
            content
                .lineSpacing(extra)
                .padding(.vertical, extra / LookFormat.half)
        } else {
            // Tighter (spec F §8 L1): SwiftUI clamps a negative
            // `lineSpacing` to zero, so the pitch itself must shrink.
            tight(content, box: funnelLineBox(percent: percent, size: size, scale: scale), extra: extra)
        }
    }

    /// A line box smaller than the face, laid out the way CSS lays it out
    /// (spec F §8 L1): the copy keeps the face's own layout, every line
    /// after the first is drawn `deficit` higher (the renderer), and the
    /// frame loses half a deficit above (the glyphs then sit centred in a
    /// `box`-tall line box — CSS's negative half-leading) and the rest of
    /// `lines × deficit` below; the ink spills past it as on the web.
    /// Not iOS 26's `lineHeight(.exact)` (it clips the ink to the frame and
    /// anchors the glyphs by a face-dependent amount), nor a custom `Layout`
    /// shrinking the frame (iOS clips the placed copy to its bounds).
    /// Before iOS 18 (no text renderer) the pitch cannot shrink: the block
    /// only loses half the deficit above and below — a one-line heading is
    /// exact, a wrapped one keeps the face's pitch between lines.
    @ViewBuilder
    private func tight(_ content: Content, box: CGFloat, extra: CGFloat) -> some View {
        #if compiler(>=6.0)
            if #available(iOS 18.0, macOS 15.0, *) {
                content.modifier(FunnelTightLines(natural: box - extra, deficit: -extra))
            } else {
                content.padding(.vertical, extra / LookFormat.half)
            }
        #else
            content.padding(.vertical, extra / LookFormat.half)
        #endif
    }
}

#if compiler(>=6.0)
    /// Copy whose lines the renderer draws `deficit` closer than the face's
    /// `natural` pitch: the drawn height (measured) gives the line count,
    /// and negative padding takes `lines × deficit` off the frame — half a
    /// deficit at the top, the rest at the bottom.
    @available(iOS 18.0, macOS 15.0, *)
    private struct FunnelTightLines: ViewModifier {
        let natural: CGFloat
        let deficit: CGFloat
        /// The copy's own (face-pitch) height, measured once drawn.
        @State private var drawnHeight: CGFloat = 0

        private var lines: CGFloat { max(1, (drawnHeight / natural).rounded()) }

        func body(content: Content) -> some View {
            content
                .funnelTightCopy(deficit: deficit)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: FunnelTightHeightKey.self, value: proxy.size.height)
                    }
                )
                .onPreferenceChange(FunnelTightHeightKey.self) { drawnHeight = $0 }
                .padding(.top, -deficit / LookFormat.half)
                .padding(.bottom, deficit / LookFormat.half - lines * deficit)
        }
    }

    private struct FunnelTightHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
#endif

extension View {
    /// Applies `value` only when there is one — a nil must mean "inherit",
    /// and `.foregroundColor(nil)` would instead RESET the screen's text
    /// colour to the system's.
    @ViewBuilder
    func ifLet<T, V: View>(_ value: T?, _ transform: (Self, T) -> V) -> some View {
        if let value { transform(self, value) } else { self }
    }

    /// A copy run's type and colour: the look's, unless the block says
    /// otherwise.
    func funnelTypography(_ style: RenderStyle, _ type: FunnelType) -> some View {
        modifier(FunnelTypography(style: style, type: type))
    }

    /// The look's `lineHeight`, laid out the way CSS lays it out: the extra
    /// leading goes between lines AND half of it above the first and below
    /// the last, so a one-line block is as tall as it is on the web.
    func funnelLineHeight(_ look: RenderLook, size: Int, family: String?) -> some View {
        funnelLineHeight(look, size: CGFloat(size), family: family)
    }

    func funnelLineHeight(_ look: RenderLook, size: CGFloat, family: String?, percent: Int? = nil) -> some View {
        modifier(FunnelLineHeight(percent: percent ?? look.lineHeight, size: size, family: family))
    }

    /// A card surface: `fill`, a `borderWidth` hairline, `radius` — the
    /// block's own background, radius and outline winning over the look's.
    func funnelCard(
        _ style: RenderStyle, fill: Color, radius: Int, borderWidth: Int, borderColor: Color
    ) -> some View {
        let r = CGFloat(style.radius ?? radius)
        let shape = RoundedRectangle(cornerRadius: r)
        return self
            .background(shape.fill(funnelColor(style.background) ?? fill))
            .overlay(
                shape.strokeBorder(
                    funnelColor(style.borderColor) ?? borderColor,
                    lineWidth: CGFloat(style.borderWidth ?? borderWidth)))
    }

    /// The margins a block asked for, outside everything else.
    func funnelMargins(_ style: RenderStyle) -> some View {
        self
            .padding(.top, CGFloat(style.marginTop ?? 0))
            .padding(.bottom, CGFloat(style.marginBottom ?? 0))
    }

    /// A control the resolver is holding reads as held.
    func funnelHeld(_ enabled: Bool) -> some View {
        opacity(enabled ? LookFormat.fullOpacity : LookFormat.heldOpacity)
    }
}

// MARK: - Press feedback

extension RenderLook {
    /// A held-down button / CTA / purchase button's scale (`pressScale`).
    var buttonPressedScale: CGFloat { CGFloat(pressScale) / LookFormat.scalePercent }
    /// A held-down choice / yes-no / package row's scale (`rowPressScale`).
    var rowPressedScale: CGFloat { CGFloat(rowPressScale) / LookFormat.scalePercent }
}

extension View {
    /// Draws the control at `pressedScale` while it is held down, easing
    /// there and back over the look's `pressMs` — the same three numbers
    /// the web (`press.tsx`) and Android (`funnelPress`) read. Under
    /// Reduce Motion the scale stays (it is the feedback) and only the
    /// animation goes: the control snaps.
    func funnelPressed(
        _ isPressed: Bool, scale pressedScale: CGFloat, look: RenderLook, reduceMotion: Bool
    ) -> some View {
        scaleEffect(isPressed ? pressedScale : LookFormat.restingScale)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: Double(look.pressMs) / LookFormat.millisecondsPerSecond),
                value: isPressed)
    }
}

/// The haptics a funnel plays (spec 2026-10-19-funnel-motion "Haptics") —
/// platform behaviour drawn from resolved values: a button's `haptic`, the
/// automatic selection tick, success and error. `enabled` is the screen's
/// funnel switch (`RenderScreen.haptics`): off, nothing plays — the
/// automatic ones included. The SDK's floor is iOS 16, so these are UIKit's
/// generators rather than iOS 17's `sensoryFeedback`; macOS draws the same
/// views and plays none.
struct FunnelHaptics: Equatable {
    let enabled: Bool

    /// What a view drawn outside a funnel screen plays with.
    static let on = FunnelHaptics(enabled: true)

    /// The tap feels a button resolves to — `look::TAP_FEELS` minus
    /// `default`, which the crate already settled.
    enum Feel {
        static let none = TapHaptic.none
        static let light = "light"
        static let medium = "medium"
        static let heavy = "heavy"
    }

    /// An accepted tap on a button, the CTA or a purchase button: its
    /// resolved impact, or nothing for `none` (a button that only advances
    /// the page, by default).
    @MainActor
    func tap(_ feel: String) {
        guard enabled else { return }
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
            let style: UIImpactFeedbackGenerator.FeedbackStyle
            switch feel {
            case Feel.light: style = .light
            case Feel.medium: style = .medium
            case Feel.heavy: style = .heavy
            default: return
            }
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }

    /// A choice, yes/no or package row: a selection tick.
    @MainActor
    func select() {
        guard enabled else { return }
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
            UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// A `haptic` action (spec 2026-11-27-funnel-authoring-fidelity §I):
    /// `success | warning | error` notify, `light | medium | heavy` impact,
    /// `selection` ticks; an unknown style plays nothing. The crate never
    /// emits one while the theme's switch is off; `enabled` guards it too.
    @MainActor
    func play(style: String) {
        guard enabled else { return }
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
            switch style {
            case ActionStyle.success: UINotificationFeedbackGenerator().notificationOccurred(.success)
            case ActionStyle.warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case ActionStyle.error: UINotificationFeedbackGenerator().notificationOccurred(.error)
            case ActionStyle.selection: UISelectionFeedbackGenerator().selectionChanged()
            case Feel.light, Feel.medium, Feel.heavy: tap(style)
            default: return
            }
        #endif
    }

    /// The `haptic` action's styles beyond the impact feels
    /// (`schema::HAPTIC_STYLES`).
    enum ActionStyle {
        static let success = "success"
        static let warning = "warning"
        static let error = "error"
        static let selection = "selection"
    }

    /// A purchase or restore the funnel asked for ended: success or a real
    /// failure. A cancelled store sheet or a deferred purchase plays
    /// nothing, and never reaches here.
    @MainActor
    func storeEnded(_ outcome: FunnelStoreOutcome) {
        guard enabled else { return }
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
            UINotificationFeedbackGenerator().notificationOccurred(outcome == .success ? .success : .error)
        #endif
    }
}

private struct FunnelFontsKey: EnvironmentKey {
    static let defaultValue = FunnelSessionFonts.none
}

extension EnvironmentValues {
    /// The presented funnel's uploaded faces — installed by the funnel view,
    /// read into every `FunnelTextScale` (review R10).
    var funnelFonts: FunnelSessionFonts {
        get { self[FunnelFontsKey.self] }
        set { self[FunnelFontsKey.self] = newValue }
    }
}

private struct FunnelHapticsKey: EnvironmentKey {
    static let defaultValue = FunnelHaptics.on
}

extension EnvironmentValues {
    /// The screen's haptics, switch applied — installed per screen.
    var funnelHaptics: FunnelHaptics {
        get { self[FunnelHapticsKey.self] }
        set { self[FunnelHapticsKey.self] = newValue }
    }
}

/// How a purchase or restore ended, for the success / error haptic and for
/// the session's `funnel_checkout_ended` (spec 2026-11-27, review round 2). A
/// cancelled sheet is `cancelled` and a deferred (Ask to Buy) purchase
/// `quiet`: neither plays a haptic, but only a cancel ends the checkout.
enum FunnelStoreOutcome: Equatable {
    case success
    case failure
    case cancelled
    case quiet

    /// Posted by `Rovenue.purchase` / `restorePurchases` as they end, so a
    /// funnel that asked for one plays the outcome whichever host ran it
    /// through the SDK. The object is the `FunnelStoreOutcome`.
    static let notification = Notification.Name("dev.rovenue.funnel.storeOutcome")

    func post() {
        NotificationCenter.default.post(name: Self.notification, object: self)
    }

    /// A purchase's outcome: success unless it was deferred.
    static func of(_ result: PurchaseResult) -> FunnelStoreOutcome {
        result.isDeferred ? .quiet : .success
    }

    /// A thrown purchase or restore: cancelled when the visitor cancelled,
    /// otherwise a real failure.
    static func of(_ error: Error) -> FunnelStoreOutcome {
        (error as? RovenueError)?.kind == .purchaseCanceled ? .cancelled : .failure
    }

    /// Whether this outcome plays a haptic (success or a real failure).
    var playsHaptic: Bool { self == .success || self == .failure }
}

/// A selectable row's button style (choice, yes/no, package): the row
/// draws itself (`FunnelRowCard`); this only adds the press — the look's
/// `rowPressScale`. Replaces `.plain`, which gave a held row no sign at all.
struct FunnelRowPress: ButtonStyle {
    let look: RenderLook
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .funnelPressed(
                configuration.isPressed, scale: look.rowPressedScale, look: look,
                reduceMotion: reduceMotion)
    }
}

// MARK: - Button chrome

/// Where a button's icon sits — `look::BUTTON_ICON_POSITIONS`. Logical,
/// so `start` is the left in LTR and the right in RTL (an `HStack` mirrors
/// under the environment's `layoutDirection`); `only` hides the label and
/// squares the button.
enum FunnelButtonIconPosition {
    static let start = "start"
    static let end = "end"
    static let only = "only"
}

/// The smallest box a finger may hit (Apple HIG, spec 2026-10-17-button-icons
/// §4.1a): an `sm` button, and an icon-only one, draw smaller than this and
/// have their hit area extended to it without changing what is drawn.
let MIN_TOUCH_TARGET = 44

/// What one button draws at, read from the screen's look and the button's
/// own size look — `buttonChrome` in `button-chrome.ts`. `md`'s size look
/// is exactly the look's `button*` values, so a tree that carried no size
/// look (an older core) draws exactly as before buttons had sizes.
struct FunnelButtonMetrics: Equatable {
    let minHeight: Int
    let paddingX: Int
    let paddingY: Int
    let type: FunnelType
    /// The icon to draw beside (or instead of) the label, and where; nil
    /// for a label-only button. Drawn only with a known position and the
    /// size look whose gap spaces it from the label, as on the web.
    let icon: RenderIcon?
    let iconPosition: String?
    let iconGap: Int

    init(chromeless: Bool, look: RenderLook, parts: FunnelButtonParts) {
        let size = parts.sizeLook
        if chromeless {
            // A chrome-less button (`link`, `text`) keeps the look's own link height and type unless the
            // author named a size; it never has a padding band.
            let named = parts.size == nil ? nil : size
            minHeight = named?.minHeight ?? look.linkMinHeight
            paddingX = 0
            paddingY = 0
            type = FunnelType(size: named?.fontSize ?? look.linkFontSize, weight: look.labelWeight)
        } else {
            minHeight = size?.minHeight ?? look.buttonMinHeight
            paddingX = size?.paddingX ?? look.buttonPaddingX
            paddingY = size?.paddingY ?? look.buttonPaddingY
            type = FunnelType(size: size?.fontSize ?? look.buttonFontSize, weight: look.buttonFontWeight)
        }
        let positions = [
            FunnelButtonIconPosition.start, FunnelButtonIconPosition.end, FunnelButtonIconPosition.only,
        ]
        if let icon = parts.icon, let position = parts.iconPosition, let size,
            positions.contains(position)
        {
            self.icon = icon
            iconPosition = position
            iconGap = size.iconGap
        } else {
            icon = nil
            iconPosition = nil
            iconGap = 0
        }
    }

    /// True when the icon draws alone and the button is a square.
    var iconOnly: Bool { icon != nil && iconPosition == FunnelButtonIconPosition.only }

    /// How far past its drawn edges the hit area reaches, per side, so it
    /// is at least `MIN_TOUCH_TARGET` on each axis — vertically for every
    /// button shorter than the target, horizontally too for an icon-only
    /// one, whose width is its height. Full-width buttons are wide enough.
    var hitExtension: (x: CGFloat, y: CGFloat) {
        let short = CGFloat(max(0, MIN_TOUCH_TARGET - minHeight)) / LookFormat.half
        return (iconOnly ? short : 0, short)
    }
}

/// The ONE shape a button, the screen CTA and a purchase button draw —
/// `button-chrome.ts` on the web. The chrome is drawn INSIDE the button
/// style, so the tappable area and the accessibility frame are the whole
/// button, not just its label. The resolver's paint (fill, label colour,
/// radius, outline, underline, height) is layered on top and wins.
///
/// A chrome-less button (`link`, `text` — the crate's `chromeless`) carries
/// no fill and no padding band: it hugs its label at the link's own type
/// and min height; the caller centres it. An icon-only
/// button is a `minHeight` square that hugs its icon; a radius of at
/// least half its height draws it as a circle.
struct FunnelButtonChrome: ButtonStyle {
    let chromeless: Bool
    let style: RenderStyle
    let metrics: FunnelButtonMetrics
    let look: RenderLook
    let enabled: Bool
    /// iOS 26 Liquid Glass (`regular|prominent`), or nil — `glassActive`.
    var glass: String? = nil
    /// The held paint (spec F §6 F6, P81): while held, an authored colour
    /// replaces its enabled half at full opacity — the paint IS the held
    /// signal, so nothing dims on top; a half left nil keeps the enabled
    /// paint. Neither authored: today's 50 % dim (`heldControlStyle`).
    var disabledBackground: String? = nil
    var disabledText: String? = nil
    /// The ledge (spec 2026-11-27 E): a solid copy of the face's shape
    /// `ledgeDepth` pt lower, behind it, outside the layout height.
    var ledgeDepth: Int? = nil
    var ledgeColor: String? = nil
    /// While held, the whole button — ledge included — at this opacity in
    /// percent, over whichever paint it wears; nil keeps today's held look.
    var heldOpacity: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    /// Held with authored paint — `heldPaint` on the web.
    private var paintedHeld: Bool { !enabled && (disabledBackground != nil || disabledText != nil) }

    /// The whole button's opacity: full while enabled; held, the authored
    /// `heldOpacity`, else full under authored paint (the paint is the
    /// signal), else `LookFormat.heldOpacity`.
    private var heldAlpha: Double {
        if enabled { return LookFormat.fullOpacity }
        if let heldOpacity { return Double(heldOpacity) / LookFormat.percent }
        return paintedHeld ? LookFormat.fullOpacity : LookFormat.heldOpacity
    }

    /// A chrome-less button hugs its label; so does any button whose
    /// width is `fit`. A Fixed width (`widthPt`) is its own frame.
    private var hugs: Bool { chromeless || style.width == RenderStyle.widthFit }

    func makeBody(configuration: Configuration) -> some View {
        let shape = FunnelBoxShape(style, rightToLeft: layoutDirection == .rightToLeft)
        let side = CGFloat(metrics.minHeight)
        let hit = metrics.hitExtension
        let heldFill = paintedHeld ? funnelColor(disabledBackground) : nil
        return configuration.label
            // Inside the typography, so the held text colour wins over the style's.
            .ifLet(paintedHeld ? funnelColor(disabledText) : nil) { $0.foregroundColor($1) }
            .funnelTypography(style, metrics.type)
            .multilineTextAlignment(.center)
            .modifier(
                FunnelButtonFrame(
                    metrics: metrics, fullWidth: !hugs, side: side, fixedWidth: style.widthPt.map { CGFloat($0) }))
            .ifLet(style.height) { $0.frame(height: CGFloat($1)) }
            // With glass the material IS the face: the resolved fill and
            // outline would hide it, so neither is painted (spec §4, FM15b);
            // the label colour and the radius still apply.
            .funnelButtonFace(
                glass: glass, shape: shape, fill: heldFill ?? funnelColor(style.background),
                outline: style.borderWidth.flatMap { w in funnelColor(style.borderColor).map { (w, $0) } })
            // Behind the face and outside its layout box, so it dims with
            // it while held and never moves a neighbour. A glass button
            // draws none (ruling R13): the material is the whole face.
            .ifLet(glass == nil ? ledgeDepth.flatMap { d in funnelColor(ledgeColor).map { (CGFloat(d), $0) } } : nil) {
                view, ledge in
                view.background(shape.fill(ledge.1).offset(y: ledge.0))
            }
            .contentShape(shape)
            // The hit area grows past the drawn edges and the layout box
            // gives it straight back, so neighbours keep their spacing and
            // the measured button stays the tree's size (FM6/FM10/FM11). A
            // button already at the target keeps its own shape as the hit.
            .ifLet(hit.x > 0 || hit.y > 0 ? hit : nil) { view, hit in
                view
                    .padding(.horizontal, hit.x)
                    .padding(.vertical, hit.y)
                    .contentShape(Rectangle())
                    .padding(.horizontal, -hit.x)
                    .padding(.vertical, -hit.y)
            }
            // Held, the glyph dims with the label: both sit inside this.
            .opacity(heldAlpha)
            // A held control never presses.
            .funnelPressed(
                enabled && configuration.isPressed, scale: look.buttonPressedScale, look: look,
                reduceMotion: reduceMotion)
    }
}

/// iOS 26 Liquid Glass (spec 2026-11-03-funnel-absolute-blocks §4): the
/// wire's two styles. Anything else — and every OS before 26, and a
/// toolchain before Swift 6.2 (Xcode 16) — draws the normal face.
enum FunnelGlass {
    static let regular = "regular"
    static let prominent = "prominent"
}

extension View {
    /// A button's face: its resolved fill and outline, or — `glass` asked
    /// for, on iOS 26 — the system's Liquid Glass in the button's shape,
    /// `prominent` tinted with the resolved fill. Reduce Transparency and
    /// Increase Contrast are the system's to apply to the material.
    @ViewBuilder
    func funnelButtonFace(
        glass: String?, shape: FunnelBoxShape, fill: Color?, outline: (Int, Color)?
    ) -> some View {
        #if compiler(>=6.2) && os(iOS)
            if #available(iOS 26.0, *), let glass,
                glass == FunnelGlass.regular || glass == FunnelGlass.prominent
            {
                // Not `.interactive()`: the Button's own press handles the
                // touch; an interactive material inside its label takes the
                // touch for itself and the action never runs.
                let material: Glass = glass == FunnelGlass.prominent ? .regular.tint(fill) : .regular
                self.glassEffect(material, in: shape)
            } else {
                self.funnelPaintedFace(shape: shape, fill: fill, outline: outline)
            }
        #else
            self.funnelPaintedFace(shape: shape, fill: fill, outline: outline)
        #endif
    }

    /// The normal face: the resolved fill, then the outline over it.
    @ViewBuilder
    fileprivate func funnelPaintedFace(shape: FunnelBoxShape, fill: Color?, outline: (Int, Color)?)
        -> some View
    {
        self
            .background(shape.fill(fill ?? .clear))
            .ifLet(outline) { $0.overlay(shape.strokeBorder($1.1, lineWidth: CGFloat($1.0))) }
    }

    /// Neighbouring glass buttons in one stack share one glass container,
    /// so their material blends as the system's does (spec §4).
    @ViewBuilder
    func funnelGlassContainer(_ holdsGlass: Bool) -> some View {
        #if compiler(>=6.2) && os(iOS)
            if holdsGlass, #available(iOS 26.0, *) {
                GlassEffectContainer { self }
            } else {
                self
            }
        #else
            self
        #endif
    }
}

/// The box a button's face is laid in: the size's padding band and min
/// height, full width unless a link — or, icon-only, a `minHeight` square.
private struct FunnelButtonFrame: ViewModifier {
    let metrics: FunnelButtonMetrics
    let fullWidth: Bool
    let side: CGFloat
    /// A Fixed width (spec 2026-11-27 F) — exactly this wide.
    var fixedWidth: CGFloat? = nil

    func body(content: Content) -> some View {
        if metrics.iconOnly {
            content.frame(width: fixedWidth ?? side, height: side)
        } else if let fixedWidth {
            content
                .padding(.horizontal, CGFloat(metrics.paddingX))
                .padding(.vertical, CGFloat(metrics.paddingY))
                .frame(minWidth: fixedWidth, maxWidth: fixedWidth, minHeight: side)
        } else {
            content
                .padding(.horizontal, CGFloat(metrics.paddingX))
                .padding(.vertical, CGFloat(metrics.paddingY))
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: side)
        }
    }
}

/// What a button draws inside its chrome — `button-face.tsx`: the label
/// alone, or the label and its icon `iconGap` apart in LOGICAL order —
/// `start` leading, `end` trailing — so an `HStack` mirrors them in RTL
/// with nothing here knowing the locale. Icon-only draws the glyph alone;
/// the caller keeps the label as the accessible name. The glyph is
/// decoration either way (`FunnelIconGlyph` hides itself).
private struct FunnelButtonFace: View {
    let label: String
    let style: RenderStyle
    let metrics: FunnelButtonMetrics

    var body: some View {
        if let icon = metrics.icon, let position = metrics.iconPosition {
            if position == FunnelButtonIconPosition.only {
                // The whole control, in the button's fixed square: the
                // tree's size (a grown glyph would overflow the square).
                FunnelIconGlyph(icon: icon)
            } else {
                // Beside the label: grows as the label does.
                HStack(spacing: CGFloat(metrics.iconGap)) {
                    if position == FunnelButtonIconPosition.start { FunnelIconGlyph(icon: icon, sizing: .followsText) }
                    funnelLabel(label, style).funnelInheritedFakeBold()
                    if position == FunnelButtonIconPosition.end { FunnelIconGlyph(icon: icon, sizing: .followsText) }
                }
            }
        } else {
            // In the button's typography: emboldened as it asks (review R5).
            funnelLabel(label, style).funnelInheritedFakeBold()
        }
    }
}

/// A button's face while the purchase it asked for runs (plan 2026-11-16
/// D2). Chromed: the face stays laid out but invisible — the button keeps
/// its exact size — with a spinner over it in the label colour. Chromeless
/// (a text link): the label stays and a spinner sits after it, trailing (an
/// `HStack`, so it mirrors in RTL). The spinner is the label's font size.
private struct FunnelBusyFace<Face: View>: View {
    let busy: FunnelButtonBusy
    let chromeless: Bool
    let gap: CGFloat
    /// The label's unscaled font size.
    let fontSize: CGFloat
    @ViewBuilder let face: () -> Face
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.funnelFonts) private var funnelFonts

    var body: some View {
        let size = FunnelTextScale(dynamicType: dynamicTypeSize, fonts: funnelFonts)(fontSize)
        if busy != .spinning {
            face()
        } else if chromeless {
            HStack(spacing: gap) {
                face()
                FunnelInlineSpinner(size: size)
            }
        } else {
            face()
                .opacity(LookFormat.hiddenOpacity)
                .overlay { FunnelInlineSpinner(size: size) }
        }
    }
}

/// A full-width (or, for a link and an icon-only button, centred and
/// hugging) button.
struct FunnelChromeButton: View {
    let label: String
    let chromeless: Bool
    let style: RenderStyle
    let look: RenderLook
    let enabled: Bool
    let metrics: FunnelButtonMetrics
    let onTap: () -> Void
    /// A tap on the button while it is held — the page then shows why
    /// (`revealInvalid` in the web's renderer). nil: a held tap is
    /// swallowed, as before.
    let onHeldTap: (() -> Void)?
    /// The resolved impact an accepted tap plays.
    let haptic: String
    /// iOS 26 Liquid Glass (`regular|prominent`), or nil for the normal style.
    let glass: String?
    /// The held paint (spec F §6 F6) — `FunnelButtonChrome`'s.
    let disabledBackground: String?
    let disabledText: String?
    /// The ledge and held opacity (spec 2026-11-27 E) — `FunnelButtonChrome`'s.
    let ledgeDepth: Int?
    let ledgeColor: String?
    let heldOpacity: Int?
    /// A purchase or restore in flight (plan 2026-11-16 D2): this button
    /// spins (it asked for it) or dims (any other).
    let busy: FunnelButtonBusy
    @Environment(\.funnelHaptics) private var haptics
    /// The dim a `.dimmed` button wears (`busyDimPercent`).
    @Environment(\.funnelStoreBusy) private var storeBusy
    /// `processing`, the spinning button's accessibility value.
    @Environment(\.funnelCopy) private var copy

    init(
        label: String, chromeless: Bool, style: RenderStyle, look: RenderLook, enabled: Bool,
        parts: FunnelButtonParts, onTap: @escaping () -> Void, onHeldTap: (() -> Void)? = nil,
        glass: String? = nil, disabledBackground: String? = nil, disabledText: String? = nil,
        ledgeDepth: Int? = nil, ledgeColor: String? = nil, heldOpacity: Int? = nil,
        busy: FunnelButtonBusy = .none
    ) {
        self.busy = busy
        self.ledgeDepth = ledgeDepth
        self.ledgeColor = ledgeColor
        self.heldOpacity = heldOpacity
        self.glass = glass
        self.disabledBackground = disabledBackground
        self.disabledText = disabledText
        self.label = label
        self.chromeless = chromeless
        self.style = style
        self.look = look
        self.enabled = enabled
        self.metrics = FunnelButtonMetrics(chromeless: chromeless, look: look, parts: parts)
        self.onTap = onTap
        self.onHeldTap = onHeldTap
        self.haptic = parts.haptic
    }

    var body: some View {
        Button {
            // A busy funnel runs nothing: the page takes no touch, and this
            // also refuses an assistive activation of the spinning button.
            guard busy == .none else { return }
            // `.disabled` already refuses a held button's tap; the guard
            // keeps the haptic honest if that ever changes.
            if enabled { haptics.tap(haptic) }
            onTap()
        } label: {
            FunnelBusyFace(
                busy: busy, chromeless: chromeless, gap: CGFloat(look.chipGap),
                fontSize: CGFloat(style.fontSize ?? metrics.type.size)
            ) {
                FunnelButtonFace(label: label, style: style, metrics: metrics)
            }
        }
        .buttonStyle(
            FunnelButtonChrome(
                chromeless: chromeless, style: style, metrics: metrics, look: look,
                enabled: enabled, glass: glass, disabledBackground: disabledBackground,
                disabledText: disabledText, ledgeDepth: ledgeDepth, ledgeColor: ledgeColor,
                heldOpacity: heldOpacity))
        .disabled(!enabled || busy == .dimmed)
        // Every other control while a purchase runs: `busyDimPercent`.
        .opacity(busy == .dimmed ? storeBusy?.dimOpacity ?? LookFormat.fullOpacity : LookFormat.fullOpacity)
        // A held button stays `.disabled` — VoiceOver still reads it dimmed
        // and it never runs its chain — while a clear layer OUTSIDE the
        // disabled subtree hears the tap and reports it as held.
        .overlay {
            if !enabled, let onHeldTap {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onHeldTap)
                    .accessibilityHidden(true)
            }
        }
        // Icon-only, the label is still the button's name (FM2); so it is
        // while spinning, when the drawn label is invisible (an invisible
        // view names nothing).
        .ifLet(metrics.iconOnly || busy == .spinning ? label : nil) { $0.accessibilityLabel(Text($1)) }
        // The spinning button keeps its name and says why it waits.
        .ifLet(busy == .spinning ? copy?.processing : nil) { $0.accessibilityValue(Text($1)) }
        // A hugging button (a link, icon-only, `width: fit`) sits centred
        // in the column unless it asked for a place of its own
        // (`alignSelf`). In a row the row's layout already offers it just
        // its own width, so this frame adds nothing there.
        .frame(
            maxWidth: .infinity,
            alignment: Alignment(horizontal: funnelSelfAlignment(style.alignSelf) ?? .center, vertical: .center))
        .funnelMargins(style)
    }
}

// MARK: - Row card

enum FunnelIndicatorShape {
    /// A circle — single choice, yes/no and a package.
    case radio
    /// A rounded square — multi choice.
    case checkbox
}

/// The leading radio / checkbox: `indicatorSize`, outlined in `accent`,
/// filled `accent` when selected.
struct FunnelSelectionIndicator: View {
    let look: RenderLook
    let selected: Bool
    let shape: FunnelIndicatorShape
    /// The unselected fill: clear on a row card; `card` where the indicator
    /// sits over a picture (a grid tile), so its outline stays readable.
    var restingFill: Color = .clear
    /// Spec F §8 H3: a SELECTED radio's inner dot; nil draws today's plain
    /// filled circle (the web's `SelectionIndicator` `dotColor`).
    var dotColor: String? = nil

    var body: some View {
        let size = CGFloat(look.indicatorSize)
        let stroke = CGFloat(look.selectedBorderWidth)
        Group {
            switch shape {
            case .radio:
                Circle().strokeBorder(look.accentColor, lineWidth: stroke)
                    .background(Circle().fill(selected ? look.accentColor : restingFill))
                    .overlay {
                        if selected, let dot = funnelColor(dotColor) {
                            let d = size * LookFormat.indicatorDotRatio
                            Circle().fill(dot).frame(width: d, height: d)
                        }
                    }
            case .checkbox:
                let r = RoundedRectangle(cornerRadius: CGFloat(look.indicatorCornerRadius))
                r.strokeBorder(look.accentColor, lineWidth: stroke)
                    .background(r.fill(selected ? look.accentColor : restingFill))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The one selectable row a choice option, a yes/no answer and an offering
/// package are all drawn as (`row-card.tsx`): a `card` fill, a
/// `borderWidth` hairline in `border`, `cardRadius`, `rowPaddingY` ×
/// `rowPaddingX` inside the border; selected, the border is
/// `selectedBorderWidth` in `accent`. The border is drawn OVER the padding
/// band (`strokeBorder`), so the thicker selected border never moves the
/// content — the same guarantee the web gets by giving the difference back
/// out of its padding.
struct FunnelRowCard<Content: View>: View {
    let look: RenderLook
    let selected: Bool
    let shape: FunnelIndicatorShape
    /// An option's leading icon, drawn IN PLACE of the indicator: the
    /// row's accent border and its accessibility state still say it is
    /// picked (the web's `OptionRows` and Android draw the same).
    var icon: RenderIcon? = nil
    /// False for a plan TILE (a horizontal package list): the border alone
    /// says which is picked.
    var indicator: Bool = true
    /// Spec F §8 H3: the selected radio's inner dot; nil for none.
    var indicatorDot: String? = nil
    /// A package list's authored card paint (fill, border, widths, radius
    /// per state), in place of the look's; nil is today's.
    var paint: RenderPackageCard? = nil
    /// A styled question row's padding (spec 2026-11-27 A), in place of
    /// the look's `rowPaddingX` / `rowPaddingY`; nil is today's.
    var insets: RenderInsets? = nil
    /// The card's least height, border included; nil sets none.
    var minHeight: CGFloat? = nil
    /// This state's ledge (`FunnelLedge`); nil draws none.
    var ledge: FunnelLedge? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shapeR = RoundedRectangle(cornerRadius: CGFloat(paint?.radius ?? look.cardRadius))
        let restWidth = paint?.borderWidth ?? look.borderWidth
        let fill = paint.map { lookColor(selected ? $0.selectedFill : $0.fill) } ?? look.cardColor
        let stroke =
            paint.map { lookColor(selected ? $0.selectedBorder : $0.border) }
            ?? (selected ? look.accentColor : look.borderColor)
        let width =
            paint.map { selected ? $0.selectedBorderWidth : $0.borderWidth }
            ?? (selected ? look.selectedBorderWidth : look.borderWidth)
        HStack(spacing: CGFloat(look.indicatorGap)) {
            if let icon {
                // Its plate, when it has one, is the slot: the glyph plus
                // the plate's padding, `indicatorGap` before the copy.
                FunnelIconPlate(icon: icon)
            } else if indicator {
                FunnelSelectionIndicator(look: look, selected: selected, shape: shape, dotColor: indicatorDot)
            }
            content()
        }
        // Content sits a hairline + the row padding from the outer edge,
        // exactly where a border-box web row puts it.
        .padding(.vertical, CGFloat((insets?.y ?? look.rowPaddingY) + restWidth))
        .padding(.horizontal, CGFloat((insets?.x ?? look.rowPaddingX) + restWidth))
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .background(shapeR.fill(fill))
        // Behind the fill, so only the part below the card shows; an
        // offset moves the drawing, not the frame, so the row's height and
        // the gap to the next row stay as laid out.
        .background {
            if let ledge, ledge.depth > 0, let color = ledge.color {
                shapeR.fill(color).offset(y: ledge.depth)
            }
        }
        .overlay(shapeR.strokeBorder(stroke, lineWidth: CGFloat(width)))
        .contentShape(shapeR)
    }
}

/// A row's solid offset shadow (spec 2026-11-27 A, the app's
/// `box-shadow: 0 5px 0`): the card's own shape, `depth` pt lower, in this
/// state's colour; nil colour draws none.
struct FunnelLedge {
    let depth: CGFloat
    let color: Color?
}

// MARK: - Activity ring

/// The spinner: an `activitySize` ring, `activityStroke` wide, in `accent`,
/// one quarter open, turning — the web's `FlowActivity`. A `ProgressViewStyle`
/// so the control stays a `ProgressView`, and its VoiceOver announcement
/// stays the system's own localized one. Under Reduce Motion the ring stays
/// drawn and stops turning.
struct FunnelActivityRingStyle: ProgressViewStyle {
    let look: RenderLook

    func makeBody(configuration: Configuration) -> some View {
        FunnelActivityRing(look: look)
    }
}

private struct FunnelActivityRing: View {
    let look: RenderLook
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        let stroke = CGFloat(look.activityStroke)
        Circle()
            .inset(by: stroke / LookFormat.half)
            .trim(from: 0, to: LookFormat.ringArc)
            .stroke(look.accentColor, lineWidth: stroke)
            .frame(width: CGFloat(look.activitySize), height: CGFloat(look.activitySize))
            .rotationEffect(.degrees(turning ? LookFormat.fullTurnDegrees : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .linear(duration: LookFormat.activityTurnSeconds)
                        .repeatForever(autoreverses: false)
                ) { turning = true }
            }
    }
}

// MARK: - Accessibility (spec D7) and drawer copy (localized-chrome D1)

/// How a selectable row announces itself. AXe — and so the E2E — reads no
/// traits on iOS, so the ROLE and its state travel in the accessibility
/// value: a radio (single-choice row, package row, opinion-scale cell) is
/// `positionOf` filled, plus `", " + selected` when it is the selected
/// one; a checkbox (multi-choice row, the legal row) is `checked` /
/// `unchecked`. Every word comes from the screen's `copy` (resolved for
/// its locale by the crate) — this drawer writes none of its own. Both
/// carry `.isButton`; the state lives in the value alone, so VoiceOver
/// never announces "selected" twice.
enum FunnelA11y {
    /// The literal placeholders `positionOf` carries; the crate never
    /// fills them — the drawer does, positionally.
    private static let positionToken = "{n}"
    private static let countToken = "{m}"
    private static let selectedSeparator = ", "

    /// `positionOf` filled — a radio's position, and a rating star's label.
    static func position(_ n: Int, of count: Int, copy: RenderChromeCopy) -> String {
        copy.positionOf
            .replacingOccurrences(of: positionToken, with: String(n))
            .replacingOccurrences(of: countToken, with: String(count))
    }

    static func radioValue(
        _ n: Int, of count: Int, selected: Bool, copy: RenderChromeCopy
    ) -> String {
        position(n, of: count, copy: copy) + (selected ? selectedSeparator + copy.selected : "")
    }

    static func checkboxValue(_ isChecked: Bool, copy: RenderChromeCopy) -> String {
        isChecked ? copy.checked : copy.unchecked
    }
}

/// The screen's drawer copy, installed once by `RovenueFunnelView` for the
/// screen it draws. Optional with no default copy: a view outside a funnel
/// screen announces nothing rather than an invented English string.
private struct FunnelCopyKey: EnvironmentKey {
    static let defaultValue: RenderChromeCopy? = nil
}

extension EnvironmentValues {
    var funnelCopy: RenderChromeCopy? {
        get { self[FunnelCopyKey.self] }
        set { self[FunnelCopyKey.self] = newValue }
    }
}

private struct FunnelRadioModifier: ViewModifier {
    @Environment(\.funnelCopy) private var copy
    let index: Int
    let count: Int
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .ifLet(copy) {
                $0.accessibilityValue(
                    FunnelA11y.radioValue(index + 1, of: count, selected: selected, copy: $1))
            }
            .accessibilityAddTraits(.isButton)
    }
}

private struct FunnelCheckboxModifier: ViewModifier {
    @Environment(\.funnelCopy) private var copy
    let checked: Bool

    func body(content: Content) -> some View {
        content
            .ifLet(copy) { $0.accessibilityValue(FunnelA11y.checkboxValue(checked, copy: $1)) }
            .accessibilityAddTraits(.isButton)
    }
}

/// A rating star (and anything else announced by position alone): the
/// label is `positionOf` filled.
private struct FunnelPositionLabelModifier: ViewModifier {
    @Environment(\.funnelCopy) private var copy
    let position: Int
    let count: Int

    func body(content: Content) -> some View {
        content.ifLet(copy) {
            $0.accessibilityLabel(FunnelA11y.position(position, of: count, copy: $1))
        }
    }
}

extension View {
    /// A radio: `index` is 0-based, the value's N is 1-based.
    func funnelRadio(index: Int, count: Int, selected: Bool) -> some View {
        modifier(FunnelRadioModifier(index: index, count: count, selected: selected))
    }

    func funnelCheckbox(checked: Bool) -> some View {
        modifier(FunnelCheckboxModifier(checked: checked))
    }

    /// Labelled by position: `position` is 1-based.
    func funnelPositionLabel(_ position: Int, of count: Int) -> some View {
        modifier(FunnelPositionLabelModifier(position: position, count: count))
    }
}
