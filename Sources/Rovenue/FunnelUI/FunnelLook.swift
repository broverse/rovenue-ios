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
    /// `letterSpacing` is thousandths of an em on the wire (−20 = −0.02 em).
    static let letterSpacingPerEm: CGFloat = 1000
    /// A held control reads as held: the spec's "Disabled: 50% opacity",
    /// the same value the web's `HELD_CONTROL_STYLE` wears.
    static let heldOpacity = 0.5
    static let fullOpacity = 1.0
    /// How long the activity ring takes to turn once — the web's
    /// `ACTIVITY_TURN_MS`. Motion, not layout, so it is not in the look.
    static let activityTurnSeconds = 0.8
    static let fullTurnDegrees = 360.0
    /// The ring's drawn arc: three quarters, one quarter open — the web's
    /// `borderTopColor: transparent`.
    static let ringArc: CGFloat = 0.75
    static let half: CGFloat = 2
    static let variantLink = "link"
    /// The look's press scales are percents on the wire (97 = 0.97×).
    static let scalePercent: CGFloat = 100
    static let restingScale: CGFloat = 1
    /// `pressMs` is milliseconds; SwiftUI animations take seconds.
    static let millisecondsPerSecond = 1000.0
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

/// The font a run of copy draws with: the block's own size, weight and
/// family where it set them, the look's `type` otherwise.
func funnelFont(_ style: RenderStyle, _ type: FunnelType) -> Font {
    funnelFont(
        size: CGFloat(style.fontSize ?? type.size), weight: style.fontWeight ?? type.weight,
        family: style.fontFamily)
}

/// A font at an exact size — a row's secondary size is a ratio of its
/// primary one, so it need not be whole. `family` is the AUTHORED name;
/// one the device does not have draws in the system face.
func funnelFont(size: CGFloat, weight: Int, family: String?) -> Font {
    let w = funnelFontWeight(weight)
    guard let family = funnelResolvedFontFamily(family) else {
        return .system(size: size, weight: w)
    }
    return .custom(family, size: size).weight(w)
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
/// The schema only admits 400–700 today, so off-row weights are latent.
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
func funnelItalicFont(size: CGFloat, weight: Int, family: String?) -> Font? {
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
    return Font(CTFontCreateWithFontDescriptor(nearest, size, nil))
}

/// The DRAWN face's own line height at `size` — ascent + descent + leading,
/// as CoreText measures it: the authored family when the device has it,
/// the system face otherwise (spec D9). SwiftUI lays a line out at exactly
/// this, so it is what the look's `lineHeight` is added on top of.
private func naturalLineHeight(_ size: CGFloat, family: String?) -> CGFloat {
    let font: CTFont
    if let family = funnelResolvedFontFamily(family) {
        font = CTFontCreateWithName(family as CFString, size, nil)
    } else {
        font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("" as CFString, size, nil)
    }
    return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
}

/// The CSS line box the look's `lineHeight` gives a line at `size`.
func funnelLineBox(_ look: RenderLook, size: CGFloat) -> CGFloat {
    funnelLineBox(percent: look.lineHeight, size: size)
}

/// The CSS line box a line height of `percent` gives a line at `size` — a
/// block's own `lineHeight`, or the look's.
func funnelLineBox(percent: Int, size: CGFloat) -> CGFloat {
    size * CGFloat(percent) / LookFormat.lineHeightPercent
}

/// The leading the look's `lineHeight` adds to a line at `size` in
/// `family`: the CSS `line-height` a web line box has, minus what SwiftUI
/// already draws for that face.
func funnelExtraLeading(_ look: RenderLook, size: CGFloat, family: String?) -> CGFloat {
    funnelExtraLeading(percent: look.lineHeight, size: size, family: family)
}

/// The leading a line height of `percent` adds over the face's own. A
/// line height tighter than the face's natural one (a 1.15 display
/// heading) adds none: SwiftUI cannot draw negative leading.
func funnelExtraLeading(percent: Int, size: CGFloat, family: String?) -> CGFloat {
    max(0, funnelLineBox(percent: percent, size: size) - naturalLineHeight(size, family: family))
}

/// Tracking a block's `letterSpacing` (thousandths of an em) asks for at
/// `size`, in points; nil when it asks for none.
func funnelTracking(_ style: RenderStyle, size: CGFloat) -> CGFloat? {
    style.letterSpacing.map { CGFloat($0) * size / LookFormat.letterSpacingPerEm }
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

    init(look: RenderLook, style: RenderStyle) {
        primary = CGFloat(style.fontSize ?? look.textSize)
        secondary = primary * CGFloat(look.mutedTextSize) / CGFloat(look.textSize)
        family = style.fontFamily
    }

    func primaryFont(weight: Int) -> Font { funnelFont(size: primary, weight: weight, family: family) }
    func secondaryFont(weight: Int) -> Font {
        funnelFont(size: secondary, weight: weight, family: family)
    }
}

// MARK: - Modifiers

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
        self
            .font(funnelFont(style, type))
            .ifLet(funnelColor(style.color)) { $0.foregroundColor($1) }
    }

    /// The look's `lineHeight`, laid out the way CSS lays it out: the extra
    /// leading goes between lines AND half of it above the first and below
    /// the last, so a one-line block is as tall as it is on the web.
    func funnelLineHeight(_ look: RenderLook, size: Int, family: String?) -> some View {
        funnelLineHeight(look, size: CGFloat(size), family: family)
    }

    func funnelLineHeight(_ look: RenderLook, size: CGFloat, family: String?, percent: Int? = nil) -> some View {
        let extra = funnelExtraLeading(percent: percent ?? look.lineHeight, size: size, family: family)
        return self
            .lineSpacing(extra)
            .padding(.vertical, extra / LookFormat.half)
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

/// How a purchase or restore ended, for the success / error haptic. A
/// cancelled sheet or a deferred (Ask to Buy) purchase is `quiet`.
enum FunnelStoreOutcome: Equatable {
    case success
    case failure
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

    /// A thrown purchase or restore: quiet when the visitor cancelled,
    /// otherwise a real failure.
    static func of(_ error: Error) -> FunnelStoreOutcome {
        (error as? RovenueError)?.kind == .purchaseCanceled ? .quiet : .failure
    }
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

    init(variant: String, look: RenderLook, parts: FunnelButtonParts) {
        let size = parts.sizeLook
        if variant == LookFormat.variantLink {
            // A link keeps the look's own link height and type unless the
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
/// A `link` carries no fill and no padding band: it hugs its label at the
/// link's own type and min height; the caller centres it. An icon-only
/// button is a `minHeight` square that hugs its icon; a radius of at
/// least half its height draws it as a circle.
struct FunnelButtonChrome: ButtonStyle {
    let variant: String
    let style: RenderStyle
    let metrics: FunnelButtonMetrics
    let look: RenderLook
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLink: Bool { variant == LookFormat.variantLink }
    /// A link hugs its label; so does any button whose width is `fit`.
    private var hugs: Bool { isLink || style.width == RenderStyle.widthFit }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(style.radius ?? 0))
        let side = CGFloat(metrics.minHeight)
        let hit = metrics.hitExtension
        return configuration.label
            .funnelTypography(style, metrics.type)
            .multilineTextAlignment(.center)
            .modifier(FunnelButtonFrame(metrics: metrics, fullWidth: !hugs, side: side))
            .ifLet(style.height) { $0.frame(height: CGFloat($1)) }
            .background(shape.fill(funnelColor(style.background) ?? .clear))
            .ifLet(style.borderWidth.flatMap { w in funnelColor(style.borderColor).map { (w, $0) } }) {
                $0.overlay(shape.strokeBorder($1.1, lineWidth: CGFloat($1.0)))
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
            .funnelHeld(enabled)
            // A held control never presses.
            .funnelPressed(
                enabled && configuration.isPressed, scale: look.buttonPressedScale, look: look,
                reduceMotion: reduceMotion)
    }
}

/// The box a button's face is laid in: the size's padding band and min
/// height, full width unless a link — or, icon-only, a `minHeight` square.
private struct FunnelButtonFrame: ViewModifier {
    let metrics: FunnelButtonMetrics
    let fullWidth: Bool
    let side: CGFloat

    func body(content: Content) -> some View {
        if metrics.iconOnly {
            content.frame(width: side, height: side)
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
                FunnelIconGlyph(icon: icon)
            } else {
                HStack(spacing: CGFloat(metrics.iconGap)) {
                    if position == FunnelButtonIconPosition.start { FunnelIconGlyph(icon: icon) }
                    funnelLabel(label, style)
                    if position == FunnelButtonIconPosition.end { FunnelIconGlyph(icon: icon) }
                }
            }
        } else {
            funnelLabel(label, style)
        }
    }
}

/// A full-width (or, for a link and an icon-only button, centred and
/// hugging) button.
struct FunnelChromeButton: View {
    let label: String
    let variant: String
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
    @Environment(\.funnelHaptics) private var haptics

    init(
        label: String, variant: String, style: RenderStyle, look: RenderLook, enabled: Bool,
        parts: FunnelButtonParts, onTap: @escaping () -> Void, onHeldTap: (() -> Void)? = nil
    ) {
        self.label = label
        self.variant = variant
        self.style = style
        self.look = look
        self.enabled = enabled
        self.metrics = FunnelButtonMetrics(variant: variant, look: look, parts: parts)
        self.onTap = onTap
        self.onHeldTap = onHeldTap
        self.haptic = parts.haptic
    }

    var body: some View {
        Button {
            // `.disabled` already refuses a held button's tap; the guard
            // keeps the haptic honest if that ever changes.
            if enabled { haptics.tap(haptic) }
            onTap()
        } label: {
            FunnelButtonFace(label: label, style: style, metrics: metrics)
        }
        .buttonStyle(
            FunnelButtonChrome(
                variant: variant, style: style, metrics: metrics, look: look, enabled: enabled))
        .disabled(!enabled)
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
        // Icon-only, the label is still the button's name (FM2).
        .ifLet(metrics.iconOnly ? label : nil) { $0.accessibilityLabel(Text($1)) }
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

    var body: some View {
        let size = CGFloat(look.indicatorSize)
        let stroke = CGFloat(look.selectedBorderWidth)
        Group {
            switch shape {
            case .radio:
                Circle().strokeBorder(look.accentColor, lineWidth: stroke)
                    .background(Circle().fill(selected ? look.accentColor : restingFill))
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shapeR = RoundedRectangle(cornerRadius: CGFloat(look.cardRadius))
        HStack(spacing: CGFloat(look.indicatorGap)) {
            if let icon {
                // Its plate, when it has one, is the slot: the glyph plus
                // the plate's padding, `indicatorGap` before the copy.
                FunnelIconPlate(icon: icon)
            } else if indicator {
                FunnelSelectionIndicator(look: look, selected: selected, shape: shape)
            }
            content()
        }
        // Content sits a hairline + the row padding from the outer edge,
        // exactly where a border-box web row puts it.
        .padding(.vertical, CGFloat(look.rowPaddingY + look.borderWidth))
        .padding(.horizontal, CGFloat(look.rowPaddingX + look.borderWidth))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shapeR.fill(look.cardColor))
        .overlay(
            shapeR.strokeBorder(
                selected ? look.accentColor : look.borderColor,
                lineWidth: CGFloat(selected ? look.selectedBorderWidth : look.borderWidth)))
        .contentShape(shapeR)
    }
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
