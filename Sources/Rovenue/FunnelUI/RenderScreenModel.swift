//  RenderScreenModel.swift — the Swift mirror of funnel-core's RenderScreen.
//
//  RenderScreen is FLAT and already resolved: no conditions, no action
//  tree, no locale maps, no {{placeholders}}. If a field here looks like it
//  needs deriving, the resolver should have settled it — that is a bug in
//  funnel-core, not something to compute in Swift.
//
//  Platform-neutral Foundation only (no SwiftUI) — decoded on whatever
//  thread receives the step.
//
//  Cross-platform contract: packages/funnel-core-rs/src/render.rs is the
//  producing side. `packages/shared/src/funnel/contract/render-fixtures.json` is what
//  keeps the two honest; every screen in it must decode here.

import Foundation

struct RenderStyle: Decodable, Equatable, Sendable {
    let align: String?
    let marginTop: Int?
    let marginBottom: Int?
    let marginLeft: Int?
    let marginRight: Int?
    let paddingTop: Int?
    let paddingRight: Int?
    let paddingBottom: Int?
    let paddingLeft: Int?
    /// `"fit"` (wrap the content), `"fill"` (a horizontal parent's equal
    /// share of what is left), or nil: fill in a vertical parent, hug in a
    /// horizontal one.
    let width: String?
    /// Whole-block alpha 0...100; nil is opaque.
    let opacity: Int?
    let fontSize: Int?
    let fontWeight: Int?
    let fontFamily: String?
    let color: String?
    let background: String?
    /// `var` so a drawer can lend a box the look's radius (the photo frame).
    var radius: Int?
    let height: Int?
    /// An outline's thickness and colour, written by the resolver together
    /// or not at all — so either one being nil means "no outline". Two
    /// fields rather than a CSS shorthand: this drawer wants a `CGFloat`
    /// and a `Color`, not a sentence to parse.
    /// `var` (with `borderStyle`) so the photo frame can swap in its
    /// answered border (spec F §8 H7).
    var borderWidth: Int?
    var borderColor: String?
    /// `"underline"`, or nil for an undecorated label.
    let textDecoration: String?
    /// Tracking in thousandths of an em (−20 = −0.02 em); nil is none.
    let letterSpacing: Int?
    /// Line height as a percent of the font size; nil is the look's.
    let lineHeight: Int?
    /// Where the block sits across its parent's axis (`start|center|end`,
    /// logical), already swapped by the resolver for `mirrorRtl: false`;
    /// nil when the author set none.
    let alignSelf: String?
    /// `"absolute"` for a block out of its parent's flow (spec 2026-11-03-
    /// funnel-absolute-blocks §2), nil in flow — `RenderStyle::position`.
    /// The fields below come with it, every number the resolver's: the
    /// anchor as fractions (`pinX` logical, 0 = leading), the four insets
    /// (margins + an edge-pinned offset; may be negative), a centred axis's
    /// signed shift, and the edges whose device safe-area inset is added.
    let position: String?
    let pinX: Double?
    let pinY: Double?
    let insetTop: Double?
    let insetLeading: Double?
    let insetBottom: Double?
    let insetTrailing: Double?
    let shiftX: Double?
    let shiftY: Double?
    /// `top|bottom|leading|trailing`; nil when the wire left it off (empty).
    let safeAreaEdges: [String]?
    /// An AUTHORED border's dash (`solid|dashed`, spec A Part B), set with
    /// `borderWidth`/`borderColor`; nil for none — a secondary button's
    /// variant outline carries no style.
    var borderStyle: String?
    /// A paint-time rotation in whole degrees (spec E §6), RTL already
    /// applied; nil for none. Image and stack only.
    let rotation: Int?

    /// The wire's one out-of-flow position.
    static let positionAbsolute = "absolute"
    /// The safe-area edges a drawer adds the device inset to.
    static let safeEdgeTop = "top"
    static let safeEdgeBottom = "bottom"
    static let safeEdgeLeading = "leading"
    static let safeEdgeTrailing = "trailing"

    /// Whether the block is out of its parent's flow.
    var isAbsolute: Bool { position == RenderStyle.positionAbsolute }
}

/// One drawn icon — `RenderIcon` in `render.rs` (spec 2026-10-11 §10.4
/// V1): layers of absolute M/L/C/Z path data on the `iconGrid` box, each
/// filled in `color` at its own opacity percent, drawn at `size`. For an
/// SF Symbols reference, `pack`/`name`/`layers` are its vector fallback's
/// and `systemSymbol` is the symbol this OS draws instead when it has it.
struct RenderIcon: Decodable, Equatable, Sendable {
    /// The vector pack `layers` come from — an SF reference's fallback's.
    let pack: String
    let name: String
    let color: String
    let size: Int
    let layers: [RenderIconLayer]
    /// The filled box behind the glyph — `RenderPlate` in `render.rs` —
    /// or nil when the icon is drawn bare.
    let plate: RenderPlate?
    /// The SF Symbol drawn instead of `layers` when this OS has it —
    /// `RenderSystemSymbol` in `render.rs`; nil for a vector icon.
    let systemSymbol: RenderSystemSymbol?
    /// Spec F §7 G6: the site's own weight when authored — `layers` (and
    /// the symbol's weight) are already drawn in it; nil otherwise.
    let weight: String?

    /// The box every icon's path data is drawn on — `icons::ICON_GRID`.
    static let iconGrid = 256
}

/// An icon's plate, fully decided by the crate: a box `padding` pt larger
/// than the glyph on every side, filled `background` (`#RRGGBB`), its
/// corners `radius` pt — already clamped to half the box, so no drawer
/// clamps.
struct RenderPlate: Decodable, Equatable, Sendable {
    let background: String
    let padding: Int
    let radius: Int
}

/// An SF Symbol, fully decided by the crate: its name, rendering mode and
/// weight (wire names, mapped by `FunnelSymbolStyle`), the palette's second
/// colour and the first iOS release with it.
struct RenderSystemSymbol: Decodable, Equatable, Sendable {
    let name: String
    let mode: String
    let weight: String
    /// `#RRGGBB` in `palette` mode; nil otherwise.
    let secondary: String?
    /// e.g. `17.0`; nil when the document carries none.
    let minOs: String?
}

struct RenderIconLayer: Decodable, Equatable, Sendable {
    let d: String
    let opacity: Int
}

/// A media background's legibility gradient — `RenderScrim` in `render.rs`.
struct RenderScrim: Decodable, Hashable, Sendable {
    /// `bottom`, `top` or `full`.
    let edge: String
    let color: String
    /// Percent, at the dense end.
    let opacity: Int
    /// Percent of the screen's height the gradient covers from `edge`.
    let extent: Int

    static let edgeTop = "top"
    static let edgeFull = "full"
}

struct RenderOption: Decodable, Equatable, Sendable {
    let value: String
    let label: String
    let description: String?
    let imageUrl: String?
    /// The option's leading icon, drawn in place of the selection
    /// indicator; nil when it has none.
    let icon: RenderIcon?
    /// Where a tap on this option goes, or nil when it carries no chain.
    let actionPath: String?
    /// Whether this option's own chain may RUN — NOT whether the control
    /// is usable. A pick is how the visitor answers, so the option stays
    /// tappable and only the chain is withheld while another required
    /// question on the page is unanswered. Disabling the control on this
    /// flag would leave a two-question page nobody can fill in.
    let enabled: Bool
    /// The option's authored media (spec B §3.1); nil for none.
    let media: RenderOptionMedia?
    /// The chips its tile draws, in template order; nil for none.
    let chips: [RenderChip]?
    /// Spec F §8 H9: `description`'s marked runs; nil when it carries no
    /// marks (`description` is the plain text either way).
    let descriptionSegments: [RenderSegment]?
}

/// What a bound media `source` resolved to (spec B §5.2) — `RenderMedia` in
/// render.rs: a url, or the visitor's photo by reference.
enum RenderMedia: Decodable, Equatable, Sendable {
    case url(String)
    case photo(String)

    private enum CodingKeys: String, CodingKey { case kind, url, ref }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "photo": self = .photo(try c.decode(String.self, forKey: .ref))
        default: self = .url(try c.decode(String.self, forKey: .url))
        }
    }
}

/// An option's own media — `RenderOptionMedia`.
struct RenderOptionMedia: Decodable, Equatable, Sendable {
    let kind: String
    let url: String
    let poster: String?
}

/// One chip on a tile — `RenderChip`.
struct RenderChip: Decodable, Equatable, Sendable {
    let text: String
    let corner: String
    let icon: RenderIcon?
    let color: String
    let background: String
    /// A filled dot before the text (spec F §6 F4); nil when none.
    let dot: String?
}

/// A picture grid's tile anatomy — `RenderTileStyle`.
struct RenderTileStyle: Decodable, Equatable, Sendable {
    let mediaAspect: String
    let textPlacement: String
    let scrim: String
    let ringColor: String
    let ringWidth: Int
    let indicator: String
    let indicatorColor: String
    let radius: Int
    let videoAutoplay: Bool
    let videoAutoplayOnCellular: Bool
    /// Spec F §6 F4, each nil unless authored: `ring|none`, and
    /// `belowLabel|aboveLabel`.
    let unselectedIndicator: String?
    let descriptionPosition: String?
    /// Spec F §7 G4: the selected indicator's glyph colour; nil is white.
    let indicatorGlyphColor: String?
    /// Spec F §8 H12: the text's padding inside a rich tile, both sides
    /// decided; nil is `look.tileLabelGap`.
    let textInset: RenderInsets?
}

/// A horizontal / vertical pair of insets in pt, both sides decided by
/// the crate — `RenderInsets` (spec F §8 H1/H12).
struct RenderInsets: Decodable, Equatable, Sendable {
    let x: Int
    let y: Int
}

/// A signed move in pt, `x` toward the trailing edge, `y` down —
/// `RenderShift` (spec F §8 H8).
struct RenderShift: Decodable, Equatable, Sendable {
    let x: Int
    let y: Int
}

/// An answered photo frame's border, fully decided (solid; width 0 draws
/// none) — `RenderFrameBorder` (spec F §8 H7).
struct RenderFrameBorder: Decodable, Equatable, Sendable {
    let color: String
    let width: Int
}

/// A card checkout toggle's own look, each nil unless authored —
/// `RenderToggleAppearance` (spec F §8 H4). Web-only block.
struct RenderToggleAppearance: Decodable, Equatable, Sendable {
    let background: String?
    let color: String?
    let borderColor: String?
    let borderWidth: Int?
    let radius: Int?
    let paddingTop: Int?
    let paddingRight: Int?
    let paddingBottom: Int?
    let paddingLeft: Int?
}

/// A `photo_upload` question's copy and photo — `RenderPhotoQuestion`.
struct RenderPhotoQuestion: Decodable, Equatable, Sendable {
    let pickLabel: String
    let pickHint: String
    let changeLabel: String
    let privacyLabel: String?
    let sources: [String]
    let photo: RenderMedia?
    /// Spec F §6 F2, each nil unless authored.
    let pickStyle: String?
    let pickIcon: RenderIcon?
    let changePosition: String?
    let changeSurface: RenderSurface?
    let privacyPlacement: String?
    /// Spec F §7 G1, each nil unless authored (plus/pill only): the disc /
    /// plate fill and the glyph (and pill text) colour.
    let pickBackground: String?
    let pickColor: String?
    /// Spec F §7 N1: the camera shortcut's accessible name; nil is "Camera".
    let cameraLabel: String?
    /// The source choice's library entry; nil is "Photo library".
    let libraryLabel: String?
    /// Spec F §8, each nil unless authored: H7 the frame's border once a
    /// photo is in (replaces the block's own), H8 the pick control's move
    /// inside the empty frame, H11 the glyph-to-label gap in pt.
    let answeredBorder: RenderFrameBorder?
    let pickOffset: RenderShift?
    let pickGap: Int?
}

/// A glass stack's surface — `RenderSurface`.
struct RenderSurface: Decodable, Equatable, Sendable {
    let kind: String
    let blurRadius: Int
    let iosMaterial: String
    let saturation: Int
    let tint: String
    let fallback: String
}

struct RenderPackage: Decodable, Equatable, Sendable {
    let identifier: String
    /// Already localized and formatted by the caller. Never reformat it.
    let localizedPrice: String
    let localizedTitle: String?
    let localizedPeriod: String?
    /// The row's pill, interpolated and coloured by the resolver; nil when
    /// the author wrote none or a store value in it was missing.
    let badge: RenderBadge?
    /// The row's second line, under the title; nil on the same rule.
    let caption: String?
    /// The pack's picture, drawn by the shop layouts (`tiles`, `shop`) only.
    let icon: RenderIcon?
    /// Spec F §6 F5c: the pill inline after the title; nil when none.
    let inlineBadge: RenderBadge?
    /// Spec F §6 F5b: the trailing price text (replaces `localizedPrice`)
    /// and its muted suffix; nil when none.
    let priceText: String?
    let priceSuffix: String?
    /// Spec F §7 G2: replaces `localizedPeriod` when non-nil; "" hides the
    /// line.
    let periodText: String?
}

/// A check list's one card — `RenderCheckSurface` (spec F §6 F3c).
struct RenderCheckSurface: Decodable, Equatable, Sendable {
    let background: String?
    let radius: Int?
}

/// An image's overlay pill — `RenderOverlay` (spec F §6 F3/F3b).
struct RenderOverlay: Decodable, Equatable, Sendable {
    let text: String
    let position: String
    let width: String
    let inset: Int
    let color: String
    let background: String?
    let surface: RenderSurface?
    let icon: RenderIcon?
    /// The check whose running phase shows a spinner before the text.
    let activityCheck: String?
    /// The check the text binds, and the text while it runs.
    let check: String?
    let checkingText: String?
    /// Spec F §7 G5, each nil unless authored: `start|center|end`, and the
    /// pill's padding in pt (nil sides: the chip padding).
    let align: String?
    let paddingX: Int?
    let paddingY: Int?
}

/// A package row's badge — `RenderBadge` in `render.rs`: its text and its
/// two `#RRGGBB` colours, decided by the resolver.
struct RenderBadge: Decodable, Equatable, Sendable {
    let text: String
    let background: String
    let color: String
}

/// One comparison-table cell: `kind` is `check`, `dash` or `text`; `text`
/// is set only for a text cell.
struct RenderTableCell: Decodable, Equatable, Sendable {
    let kind: String
    let text: String?
}

struct RenderTableRow: Decodable, Equatable, Sendable {
    let label: String
    let cells: [RenderTableCell]
}

/// One feature-list row: `iconKind` is `emoji` (the glyph in `icon`),
/// `image` (the source in `icon`), `check` (`icon` empty; `glyph` is the
/// set's check) or `icon` (`icon` is the name). `body` is nil when none or
/// hidden.
struct RenderFeature: Decodable, Equatable, Sendable {
    let iconKind: String
    let icon: String
    /// The drawn mark, with its colour and plate, when `iconKind` is
    /// `icon` or `check`; else nil.
    let glyph: RenderIcon?
    let title: String
    let body: String?
}

/// A button's resolved size — `RenderButtonSize` in `render.rs` (spec
/// 2026-10-17-button-icons §4.1a): its row of `look::BUTTON_SIZES` with
/// any authored font size applied, plus the gap between its icon and its
/// label. `md`'s row is exactly the look's `button*` values, so a drawer
/// reads a button's metrics here and invents none.
struct RenderButtonSize: Decodable, Equatable, Sendable {
    let minHeight: Int
    let paddingX: Int
    let paddingY: Int
    let fontSize: Int
    /// The size an icon on this button draws at when it names none.
    let iconSize: Int
    let iconGap: Int
}

/// The parts of a button the resolver sized and gave an icon — a `button`
/// block's, a `purchaseButton` block's and the CTA's alike. Every one is
/// optional on the wire: a tree from a core older than button icons
/// carries none, and that button draws its label alone at the look's `md`.
protocol FunnelButtonParts {
    /// Painted in the label's colour unless the author named one.
    var icon: RenderIcon? { get }
    /// `start`, `end` or `only` (`look::BUTTON_ICON_POSITIONS`) when `icon`
    /// is drawn, else nil.
    var iconPosition: String? { get }
    /// `sm` or `lg`; nil is `md`.
    var size: String? { get }
    var sizeLook: RenderButtonSize? { get }
    /// The impact an accepted tap plays — `none`, `light`, `medium` or
    /// `heavy` (spec 2026-10-19-funnel-motion "Haptics"), already resolved
    /// from the author's tap feel, the page's default and the funnel's
    /// switch. Read, never re-derived.
    var haptic: String { get }
}

// MARK: - Motion (spec 2026-10-19-funnel-motion)

/// A spring as the crate defines it — `RenderSpring` in `render.rs`: mass
/// 1, its damping ratio in percent, its stiffness, the response it is
/// timed to and when it settles. SwiftUI's `.spring(response:
/// dampingFraction:)` takes the first and third with no arithmetic beyond
/// units. The CSS easing the web runs is on the wire too and not read here.
struct RenderSpring: Decodable, Equatable, Sendable {
    let dampingRatio: Int
    let stiffness: Int
    let responseMs: Int
    let settleMs: Int
}

/// Every motion number a screen animates with — `RenderMotionTokens` in
/// `render.rs`, resolved by `look.rs`. Durations are milliseconds, scales
/// and shares percent, distances points, bezier control points thousandths.
/// No drawer keeps a motion number of its own.
struct RenderMotionTokens: Decodable, Equatable, Sendable {
    let fastMs: Int
    let normalMs: Int
    let pageMs: Int
    let slowMs: Int
    /// An exit's duration in percent of its enter speed's (already applied
    /// on a block's `RenderExit`; used here for reduced motion's exit).
    let exitPercent: Int
    /// Every page transition's travel and scale.
    let smooth: RenderSpring
    let snappy: RenderSpring
    let bouncy: RenderSpring
    /// Opacity on the way in and every cross-fade: x1, y1, x2, y2.
    let fadeCurve: [Int]
    /// An element's exit, opacity and travel alike.
    let exitCurve: [Int]
    let elementDistance: Int
    let pageDistance: Int
    /// `push`: how far the page underneath moves toward the leading edge
    /// (percent of the width) and how dark its black wash ends (percent).
    let pushPercent: Int
    let pushDim: Int
    let enterScale: Int
    let popScale: Int
    let fadeThroughScale: Int
    /// `fade_through`: the outgoing page fades over this share of `pageMs`,
    /// the incoming over the rest.
    let fadeThroughSplit: Int
    let pulseScale: Int
    let pulseCycles: Int
    let pulseMs: Int
    /// Already folded into each enter's `delayMs`.
    let cascadeStepMs: Int
    let cascadeMaxMs: Int
    /// A page's element enters start this far into its transition.
    let enterAtPercent: Int
}

/// An element's enter, resolved — `RenderEnter` in `render.rs`.
struct RenderEnter: Decodable, Equatable, Sendable {
    let preset: String
    /// Opacity runs 0 → 1 over this on the fade curve.
    let durationMs: Int
    /// The author's delay, or the cascade's slot.
    let delayMs: Int
    /// `smooth`, `snappy` or `bouncy` — named for the describer; `spring`
    /// is that curve already timed to `durationMs`.
    let curve: String
    let spring: RenderSpring
}

/// An element's exit, resolved — `RenderExit` in `render.rs`: already at
/// the exit share of its speed, on the exit curve.
struct RenderExit: Decodable, Equatable, Sendable {
    let preset: String
    let durationMs: Int
}

/// What one block (or the CTA) animates — `RenderMotion` in `render.rs`;
/// absent on the wire when nothing resolves.
struct RenderMotion: Decodable, Equatable, Sendable {
    let enter: RenderEnter?
    let exit: RenderExit?
    /// `pulse`, on a button, a purchase button or the CTA only.
    let emphasis: String?
}

/// A button's resolved haptic, decoded so that an ABSENT key reads as
/// `none` — the web's default — exactly as `BlockId` defaults an absent id:
/// only absence defaults, a key that is there but unreadable throws.
@propertyWrapper
struct TapHaptic: Decodable, Equatable, Sendable {
    let wrappedValue: String

    init(wrappedValue: String) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        wrappedValue = try String(from: decoder)
    }

    /// No haptic — `look::TAP_FEEL_NONE`.
    static let none = "none"
}

extension KeyedDecodingContainer {
    /// `none` for an ABSENT key, strict when the key is there — see `TapHaptic`.
    func decode(_ type: TapHaptic.Type, forKey key: Key) throws -> TapHaptic {
        guard contains(key) else { return TapHaptic(wrappedValue: TapHaptic.none) }
        return TapHaptic(wrappedValue: try decode(String.self, forKey: key))
    }
}

struct RenderCta: Decodable, Equatable, Sendable, FunnelButtonParts {
    /// The CTA is authored nowhere, so this is the theme resolved for the
    /// screen's primary action — a filled button, in `theme.primary_color`.
    /// Drawing it is what stops this view from inventing a second answer
    /// to "what does a primary button look like".
    let style: RenderStyle
    let label: String
    /// False while a visible required question is unanswered. A business
    /// rule the resolver computed; do not re-derive it.
    let enabled: Bool
    let actionPath: String
    /// The page's `cta_icon`, painted — as a `button` block's `icon`.
    let icon: RenderIcon?
    let iconPosition: String?
    /// The page's `cta_size`.
    let size: String?
    let sizeLook: RenderButtonSize?
    /// The page's `cta_tap_feel`, resolved.
    let haptic: String
    /// The page's `cta_motion`, resolved; nil when it animates nothing.
    let motion: RenderMotion?
    /// The page's `cta_disabled_*` (spec F §6 F6); nil is the look's.
    let disabledBackground: String?
    let disabledText: String?

    private enum CodingKeys: String, CodingKey {
        case style, label, enabled, actionPath, icon, iconPosition, size, sizeLook, haptic, motion
        case disabledBackground, disabledText
    }

    /// `style` follows the rule `BlockId` sets for a newly added field:
    /// ONLY ABSENCE DEFAULTS. A synthesized decoder would throw on a
    /// missing key, and — unlike a block, which `LenientBlocks` would merely
    /// drop — a throw here escapes through `decodeIfPresent(RenderCta…)`
    /// into `decodeRenderScreen`'s `try?` and loses the WHOLE SCREEN. An
    /// unstyled CTA still draws; a blank screen does not.
    ///
    /// `contains` rather than `decodeIfPresent`, for the reason spelled out
    /// on `BlockId`: `decodeIfPresent` reports nil for an explicit `null`
    /// too, so a null `style` would default instead of throwing. A key that
    /// is THERE but unreadable is a producer bug, and conflating it with
    /// absence is how that bug becomes unfindable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.contains(.style) ? try c.decode(RenderStyle.self, forKey: .style) : .unstyled
        label = try c.decode(String.self, forKey: .label)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        actionPath = try c.decode(String.self, forKey: .actionPath)
        // Added after the CTA shipped, so absence (an older core) means a
        // label-only `md` CTA. Decoded LENIENTLY — unreadable is nil, as a
        // block's unreadable icon is dropped with its block by
        // `LenientBlocks`: an icon or size this build cannot read must not
        // throw into `decodeRenderScreen`'s `try?` and lose the whole
        // screen. The CTA then draws its label at the look's `md`.
        icon = try? c.decodeIfPresent(RenderIcon.self, forKey: .icon)
        iconPosition = try? c.decodeIfPresent(String.self, forKey: .iconPosition)
        size = try? c.decodeIfPresent(String.self, forKey: .size)
        sizeLook = try? c.decodeIfPresent(RenderButtonSize.self, forKey: .sizeLook)
        // Motion-era fields, lenient on the same rule: a CTA this build
        // cannot animate still draws, still and silent.
        haptic = (try? c.decode(TapHaptic.self, forKey: .haptic).wrappedValue) ?? TapHaptic.none
        motion = try? c.decodeIfPresent(RenderMotion.self, forKey: .motion)
        disabledBackground = try? c.decodeIfPresent(String.self, forKey: .disabledBackground)
        disabledText = try? c.decodeIfPresent(String.self, forKey: .disabledText)
    }
}

extension RenderStyle {
    /// `width`'s written values — the one home of these wire strings.
    static let widthFit = "fit"
    static let widthFill = "fill"
    /// `alignSelf`'s values (logical).
    static let alignSelfStart = "start"
    static let alignSelfCenter = "center"
    static let alignSelfEnd = "end"

    /// What an ABSENT `style` key stands for: nothing set, so every drawer
    /// falls back exactly as it does for a block the author left alone.
    ///
    /// Spelled out field by field on purpose — adding one to `RenderStyle`
    /// then fails to compile here, which is the point: a new field's
    /// absent-value is a decision, not something to inherit by accident.
    static let unstyled = RenderStyle(
        align: nil,
        marginTop: nil,
        marginBottom: nil,
        marginLeft: nil,
        marginRight: nil,
        paddingTop: nil,
        paddingRight: nil,
        paddingBottom: nil,
        paddingLeft: nil,
        width: nil,
        opacity: nil,
        fontSize: nil,
        fontWeight: nil,
        fontFamily: nil,
        color: nil,
        background: nil,
        radius: nil,
        height: nil,
        // No outline and no decoration: an author sets neither, and the
        // resolver writes them only for a button's variant.
        borderWidth: nil,
        borderColor: nil,
        textDecoration: nil,
        // No tracking and the look's line height: an author set neither.
        letterSpacing: nil,
        lineHeight: nil,
        // Placed by its parent's layout: the author set no position.
        alignSelf: nil,
        // In flow: none of the absolute fields.
        position: nil,
        pinX: nil,
        pinY: nil,
        insetTop: nil,
        insetLeading: nil,
        insetBottom: nil,
        insetTrailing: nil,
        shiftX: nil,
        shiftY: nil,
        safeAreaEdges: nil,
        // No authored border, no rotation.
        borderStyle: nil,
        rotation: nil
    )
}

// MARK: - Block payloads
//
// EVERY payload carries `blockId` — the id of the block the author wrote —
// so a drawer can always name what it drew. `""` is how a block the
// document gave no id spells its absence, matching `render.rs`.

/// `blockId`, decoded so that an ABSENT key reads as `""`.
///
/// THE THREE MIRRORS MUST AGREE ABOUT A MISSING FIELD. TypeScript's
/// `str(raw.blockId)` and Kotlin's `strOf("blockId").orEmpty()` both yield
/// `""`; Swift's synthesized `Decodable` instead THROWS on a missing key —
/// for a property with a default value too, which was checked rather than
/// assumed. A throw here is not a decode error a caller sees: `LenientBlocks`
/// turns it into a DROPPED block, so the strictest mirror would be the one
/// that silently loses content the other two draw.
///
/// Absence and emptiness land in the same place because `""` already means
/// "no authored id" in this contract, so nothing is lost by conflating them.
///
/// ONLY ABSENCE DEFAULTS. A key that is THERE but holds something unreadable
/// — a number, an object, an explicit null — throws, and `LenientBlocks`
/// drops that block. Reading it as `""` instead would collapse "the producer
/// sent the wrong type" onto "this block is anonymous", and anonymous is a
/// real value with real behaviour: the builder's canvas leaves those blocks
/// out of its selection map, so they draw but cannot be selected. One
/// meaningful value standing for two different causes is how a bug becomes
/// unfindable.
@propertyWrapper
struct BlockId: Decodable, Equatable, Sendable {
    let wrappedValue: String

    init(wrappedValue: String) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        wrappedValue = try String(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Supplies `""` for an ABSENT key, and decodes strictly when the key is
    /// there. The property wrapper alone cannot do the first half: a
    /// synthesized decoder never reaches the wrapper's initializer when the
    /// key is missing, so the default has to live at the container.
    ///
    /// `contains` rather than `decodeIfPresent`, which cannot draw the line
    /// this exists to draw: it reports nil for an explicit `null` as well as
    /// for an absent key, so a null `blockId` would default instead of
    /// throwing. Decoding `String` (not `BlockId`) is also what keeps this
    /// from calling itself.
    func decode(_ type: BlockId.Type, forKey key: Key) throws -> BlockId {
        guard contains(key) else { return BlockId(wrappedValue: "") }
        return BlockId(wrappedValue: try decode(String.self, forKey: key))
    }
}

/// One run of inline-marked copy (`marks.rs`); nil on the block when the
/// copy carries none.
struct RenderSegment: Decodable, Equatable, Sendable {
    let text: String
    let bold: Bool
    let italic: Bool
    let strike: Bool
    let code: Bool
    let link: String?
    /// A coloured span's hex (spec E §3); nil when uncoloured.
    let color: String?
    /// `[[text]]` (spec F §6 F4b): an outlined box in the text colour;
    /// absent on the wire when false.
    let boxed: Bool?
}

struct HeadingBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let text: String
    let level: Int
    let segments: [RenderSegment]?
}

struct TextBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let text: String
    let segments: [RenderSegment]?
}

struct ImageBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let url: String
    let alt: String?
    /// Edge to edge: the page's side padding is cancelled.
    let bleed: Bool
    /// What a bound image resolved to (spec B §5.2); nil unbound.
    let media: RenderMedia?
    /// Its overlay pill (spec F §6 F3); nil when none or empty.
    let overlay: RenderOverlay?

    /// The photo reference a photo-bound image draws, else nil.
    var photoRef: String? {
        if case .photo(let ref) = media { return ref }
        return nil
    }
}

struct VideoBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let url: String
    /// The still drawn while it loads and under Reduce Motion / Low Power.
    let poster: String?
    /// What a bound video resolved to; nil unbound.
    let media: RenderMedia?
}

struct ButtonBlock: Decodable, Equatable, Sendable, FunnelButtonParts {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let label: String
    let variant: String
    /// The crate's decision that every drawer hugs this button's label
    /// with no padding band or chrome (`link`, `text`) — read, never
    /// re-derived from `variant`.
    let chromeless: Bool
    /// False while a visible required question is unanswered AND this
    /// button's chain would move the visitor on. Unlike an option's, this
    /// IS the control's state: the view disables it.
    let enabled: Bool
    let actionPath: String
    /// Spec 2026-10-17-button-icons §4.3 — see `FunnelButtonParts`.
    let icon: RenderIcon?
    let iconPosition: String?
    let size: String?
    let sizeLook: RenderButtonSize?
    @TapHaptic var haptic: String
    /// iOS 26 Liquid Glass (`regular|prominent`), nil for none — read only
    /// here, every other drawer ignores it (spec 2026-11-03 §4).
    let glass: String?
    /// The held paint (spec F §6 F6); nil is the look's.
    let disabledBackground: String?
    let disabledText: String?
}

struct SpacerBlock: Decodable, Equatable, Sendable {
    @BlockId var blockId: String
    let motion: RenderMotion?
    let size: Int
    /// Takes the height the page column has left (at least `size`).
    let flex: Bool
}

/// A standalone icon — `RenderBlock::Icon`: the glyph inside whatever
/// padding, fill and radius its style carries.
struct IconBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let glyph: RenderIcon
}

struct DividerBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
}

/// An indeterminate spinner (C12). No style and no props: the SCREEN's look
/// decides it (`activitySize`, `activityStroke`, `accent`).
struct ActivityBlock: Decodable, Equatable, Sendable {
    @BlockId var blockId: String
    let motion: RenderMotion?
}

struct ReviewBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let quote: String
    let author: String?
    let rating: Int?
}

struct GalleryBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let urls: [String]
    let columns: Int
}

struct QuestionBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let kind: String
    let required: Bool
    let selected: [String]
    let options: [RenderOption]
    let placeholder: String?
    let suffix: String?
    let min: Double?
    let max: Double?
    let step: Double?
    /// Which contact fields to ask, in render order, each with the
    /// placeholder to show. Already resolved — the collectName/
    /// collectEmail/collectPhone asymmetry was applied by the resolver and
    /// those flags are not even on this type, and the placeholder is the
    /// author's own or the resolver's localized one (spec D1).
    let contactFields: [RenderContactField]
    /// Why the answer cannot be used (`answer_rules.rs`), or nil — empty
    /// included; a contact question's reasons are per field.
    let invalid: RenderInvalidReason?
    let agreementLabel: String?
    let termsUrl: String?
    /// `list`, `grid` or `chips` — decided by the resolver, never by this
    /// drawer.
    let layout: String
    /// Tiles per grid row (2, 3 or 4); 1 for a list or chips.
    let columns: Int
    /// Whether a pick adds to a list of answers rather than replacing the
    /// one answer — the drawer reads this, never the kind string.
    let multiple: Bool
    /// A grid's one tile anatomy; nil for a list or chips.
    let tile: RenderTileKind?
    /// A grid of 3 or more columns: its tiles draw at `tilePaddingDense`
    /// and `tileLabelSizeDense`. Always false off a grid.
    let dense: Bool
    /// A picture grid's authored tile anatomy; nil for none.
    let tileStyle: RenderTileStyle?
    /// A `photo_upload` question's copy and photo; nil for other kinds.
    let photo: RenderPhotoQuestion?
}

/// What every tile of an option grid draws above (or instead of) its
/// label — `TileKind` in render.rs, spelled as the wire spells it.
enum RenderTileKind: String, Decodable, Equatable, Sendable {
    /// Every tile reserves the square image slot.
    case image
    /// The option's icon plate, centred on top.
    case icon
    /// No media: the label alone, centred both ways.
    case text
}

struct PackageListBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let layout: String
    let packages: [RenderPackage]
    let selectedIdentifier: String?
    /// The selected row's border/indicator colour (the block's highlight,
    /// else the accent).
    let highlight: String
    /// A shop layout's selected fill: card mixed toward `highlight`.
    let highlightFill: String
    /// Spec F §7 G3: the period line / price suffix / inline badge size in
    /// pt; nil is the look's ratio.
    let secondaryTextSize: Int?
    /// Spec F §8 H1–H3, each nil unless authored: the row padding (both
    /// sides decided) and row gap in place of the look's, the caption size,
    /// and the selected radio's inner dot.
    let rowPadding: RenderInsets?
    let rowGap: Int?
    let captionTextSize: Int?
    let indicatorDotColor: String?
}

/// A label column plus 1...3 value columns (spec 4.2). W3 draws it.
struct ComparisonTableBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let columns: [String]
    /// The value column drawn with `look.tableHighlight` behind it.
    let highlight: Int?
    let rows: [RenderTableRow]
}

/// Icon + title + optional body rows on one icon column (spec 4.3). W3
/// draws it.
struct FeatureListBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let items: [RenderFeature]
    /// The ONE icon column every item's icon is centred in, so every
    /// title starts at the same x.
    let iconColumn: Int
}

struct PurchaseButtonBlock: Decodable, Equatable, Sendable, FunnelButtonParts {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let label: String
    let variant: String
    /// False while nothing is selected. The resolver decided this.
    let enabled: Bool
    let actionPath: String
    /// As `ButtonBlock`'s.
    let icon: RenderIcon?
    let iconPosition: String?
    let size: String?
    let sizeLook: RenderButtonSize?
    @TapHaptic var haptic: String
    /// As `ButtonBlock`'s.
    let glass: String?
    /// As `ButtonBlock`'s.
    let disabledBackground: String?
    let disabledText: String?
}

/// The two recursive blocks decode their children LENIENTLY, through the
/// same `LenientBlocks` the screen uses. Declaring `children: [RenderBlock]`
/// directly would make one unknown child fail the whole container — the
/// opposite of what the spec requires — so both are written this way and
/// neither may drift from the other.
struct StackBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    /// `vertical`, `horizontal` or `wrap`.
    let direction: String
    let gap: Int
    /// Where the children sit — resolved, defaults applied. `alignX` is
    /// logical (`left` = leading); the children are placed by these three
    /// alone, never by `style.align`.
    let alignX: String
    let alignY: String
    let distribute: String
    /// Figma's "clip content": children, absolute ones included, are cut
    /// to the stack's rounded box. False when absent.
    let clip: Bool
    /// A glass surface (spec E §4.2); nil for none.
    let surface: RenderSurface?
    let children: [RenderBlock]

    private enum CodingKeys: String, CodingKey {
        case style, blockId, motion, direction, gap, alignX, alignY, distribute, clip, surface, children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(RenderStyle.self, forKey: .style)
        _blockId = try c.decode(BlockId.self, forKey: .blockId)
        motion = try c.decodeIfPresent(RenderMotion.self, forKey: .motion)
        direction = try c.decode(String.self, forKey: .direction)
        gap = try c.decode(Int.self, forKey: .gap)
        // The resolver always writes all three; absent is a stack from
        // before they existed — today's top-left packed group.
        alignX = try c.decodeIfPresent(String.self, forKey: .alignX) ?? RenderLayout.alignLeft
        alignY = try c.decodeIfPresent(String.self, forKey: .alignY) ?? RenderLayout.alignTop
        distribute =
            try c.decodeIfPresent(String.self, forKey: .distribute) ?? RenderLayout.distributePacked
        clip = try c.decodeIfPresent(Bool.self, forKey: .clip) ?? false
        surface = try c.decodeIfPresent(RenderSurface.self, forKey: .surface)
        children = try c.decode(LenientBlocks.self, forKey: .children).blocks
    }
}

/// A step bar with an optional back control and label — `RenderBlock::
/// Progress`, every number resolved (`look::progress_geometry`), so this
/// drawer keeps none of its own. At a page's top level it arrives in
/// `RenderScreen.header` (pinned); inside a stack, where it was authored.
struct ProgressBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    /// `solid`, `rounded`, `segmented` or `dashed`.
    let barStyle: String
    let activeColor: String
    let trackColor: String
    /// A segmented bar's current cell colour (spec E §5); nil for none.
    let currentColor: String?
    let showBar: Bool
    let showBack: Bool
    /// False on the first page: the back control is drawn held (dimmed,
    /// no tap). A press runs the session's existing back step.
    let backEnabled: Bool
    /// `chevron` or `arrow`.
    let backIcon: String
    /// The label, already filled (`count` / `percent`); nil for none.
    let labelText: String?
    let current: Int
    let total: Int
    let barHeight: Int
    let barRadius: Double
    /// The gap between segmented cells — segmented only.
    let segmentGap: Int?
    /// A dashed track's dash and gap — dashed only.
    let dashLength: Int?
    let dashGap: Int?
    /// The back control's square hit target and its glyph.
    let backSize: Int
    let backGlyphSize: Int
    let labelSize: Int
    /// The label's opacity, percent.
    let labelOpacity: Int
    /// The gap between back, bar and label.
    let rowGap: Int

    static let styleSegmented = "segmented"
    static let styleDashed = "dashed"
    static let iconArrow = "arrow"

    /// A segmented bar needs its `segmentGap`, a dashed one its
    /// `dashLength` and `dashGap`. The resolver always writes them, so a
    /// bar missing them is structurally wrong — dropped, never drawn with
    /// a number made up here (Kotlin's `hasItsGeometry`, the web's
    /// `hasProgressGeometry`).
    var hasItsGeometry: Bool {
        switch barStyle {
        case Self.styleSegmented: return segmentGap != nil
        case Self.styleDashed: return dashLength != nil && dashGap != nil
        default: return true
        }
    }
}

struct StickyFooterBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let children: [RenderBlock]

    private enum CodingKeys: String, CodingKey { case style, blockId, motion, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(RenderStyle.self, forKey: .style)
        _blockId = try c.decode(BlockId.self, forKey: .blockId)
        motion = try c.decodeIfPresent(RenderMotion.self, forKey: .motion)
        children = try c.decode(LenientBlocks.self, forKey: .children).blocks
    }
}

/// Inline express checkout. Web-only — the publish judge refuses it on
/// native — so this struct exists for the contract (decode + describe),
/// and the view draws the authored fallback, the no-wallet state.
struct ExpressCheckoutBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let children: [RenderBlock]

    private enum CodingKeys: String, CodingKey { case style, blockId, motion, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(RenderStyle.self, forKey: .style)
        _blockId = try c.decode(BlockId.self, forKey: .blockId)
        motion = try c.decodeIfPresent(RenderMotion.self, forKey: .motion)
        children = try c.decode(LenientBlocks.self, forKey: .children).blocks
    }
}

/// One check step — `RenderCheckStep`.
struct RenderCheckStep: Decodable, Equatable, Sendable {
    let id: String
    let label: String
    let status: String
}

/// A photo check — `RenderBlock::Check` (spec C §3.5). `phase` is what the
/// machine knows (`idle|pass|fail|skipped`); `running` is this drawer's own.
struct CheckBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let key: String
    let display: String
    let steps: [RenderCheckStep]
    let phase: String
    let checkingLabel: String
    let badgeText: String?
    let photo: RenderMedia?
    /// Spec F §6 F3: false only when the author hid the list photo.
    let showPhoto: Bool?
    /// F3c, each nil unless authored.
    let rowHeight: Int?
    let divider: String?
    let surface: RenderCheckSurface?
    /// F3d: the forward label while this check runs; nil is `checkingLabel`.
    let ctaCheckingLabel: String?
    /// Spec F §8 H10, each nil unless authored: the step ring's size in pt
    /// and a pending step's ring colour.
    let indicatorSize: Int?
    let pendingColor: String?
    /// Spec F §9 I4: a pending step's label colour; nil unless authored.
    let pendingLabelColor: String?
}

/// One piece of copy with a `checkout.*` slot — `RenderCopyPart`.
enum RenderCopyPart: Decodable, Equatable, Sendable {
    case text(String)
    case slot(String)

    private enum CodingKeys: String, CodingKey { case kind, text, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "slot": self = .slot(try c.decode(String.self, forKey: .name))
        default: self = .text(try c.decode(String.self, forKey: .text))
        }
    }
}

struct RenderCardToggle: Decodable, Equatable, Sendable {
    let label: String
    let icon: RenderIcon?
    let initiallyOpen: Bool
    /// Spec F §8 H4: the toggle's own look; nil unless authored.
    let appearance: RenderToggleAppearance?
    /// Spec F §9 I2: `start|center|end`, nil unless authored (label at the
    /// start, chevron at the end); and `false` when the chevron is hidden
    /// (nil draws it).
    let align: String?
    let chevron: Bool?
}

struct RenderCardEmail: Decodable, Equatable, Sendable {
    let label: String
    let placeholder: String
}

struct RenderCardSummary: Decodable, Equatable, Sendable {
    let productLine: [RenderCopyPart]?
    let totalLabel: [RenderCopyPart]?
}

struct RenderCardFields: Decodable, Equatable, Sendable {
    let background: String
    let border: String
    let radius: Int
    let labelColor: String
    let textColor: String
    let placeholderColor: String
}

/// The inline card form — `RenderBlock::CardCheckout`. Web-only (the judge
/// refuses it on native), so it exists here for the contract.
struct CardCheckoutBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let toggle: RenderCardToggle?
    let email: RenderCardEmail
    let summary: RenderCardSummary?
    let taxRows: Bool
    let payLabel: [RenderCopyPart]
    let note: String?
    let legal: String?
    let brands: [String]
    let fields: RenderCardFields
    let unavailable: String
    let enabled: Bool
    /// Spec F §8 H5: the line under the collapsed toggle; nil unless drawn.
    let noteWhenCollapsed: String?
    /// Spec F §9 I3: that line's marked runs, the brand marks beside the
    /// collapsed toggle, and both notes' text size (nil is the muted size).
    let noteWhenCollapsedSegments: [RenderSegment]?
    let brandsWhenCollapsed: Bool
    let noteTextSize: Int?

    private enum CodingKeys: String, CodingKey {
        case style, blockId, motion, toggle, email, summary, taxRows, payLabel, note, legal, brands
        case fields, unavailable, enabled, noteWhenCollapsed
        case noteWhenCollapsedSegments, brandsWhenCollapsed, noteTextSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(RenderStyle.self, forKey: .style)
        _blockId = try c.decode(BlockId.self, forKey: .blockId)
        motion = try c.decodeIfPresent(RenderMotion.self, forKey: .motion)
        toggle = try c.decodeIfPresent(RenderCardToggle.self, forKey: .toggle)
        email = try c.decode(RenderCardEmail.self, forKey: .email)
        summary = try c.decodeIfPresent(RenderCardSummary.self, forKey: .summary)
        taxRows = try c.decodeIfPresent(Bool.self, forKey: .taxRows) ?? false
        payLabel = try c.decode([RenderCopyPart].self, forKey: .payLabel)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        legal = try c.decodeIfPresent(String.self, forKey: .legal)
        brands = try c.decodeIfPresent([String].self, forKey: .brands) ?? []
        fields = try c.decode(RenderCardFields.self, forKey: .fields)
        unavailable = try c.decode(String.self, forKey: .unavailable)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        noteWhenCollapsed = try c.decodeIfPresent(String.self, forKey: .noteWhenCollapsed)
        noteWhenCollapsedSegments = try c.decodeIfPresent([RenderSegment].self, forKey: .noteWhenCollapsedSegments)
        brandsWhenCollapsed = try c.decodeIfPresent(Bool.self, forKey: .brandsWhenCollapsed) ?? false
        noteTextSize = try c.decodeIfPresent(Int.self, forKey: .noteTextSize)
    }
}

/// A carousel's indicator — `RenderIndicator` (spec CL §4.3; renamed from
/// `RenderDots`); absent on the wire for `none` and on a marquee.
struct RenderIndicator: Decodable, Equatable, Sendable {
    /// `dots|pill|bars|counter`.
    let style: String
    /// `below|overlayBottom|overlayTop`.
    let position: String
    let activeColor: String
    let inactiveColor: String
    let size: Int
}

/// One drop shadow — `RenderShadow`: offset y, blur and an `#RRGGBBAA` colour.
struct RenderShadow: Decodable, Equatable, Sendable {
    let y: Int
    let blur: Int
    let color: String
}

/// A slide's card — `RenderCarouselCard` (spec CL §4.2); absent for `none`.
struct RenderCarouselCard: Decodable, Equatable, Sendable {
    /// `elevated|outlined|glass`.
    let style: String
    let radius: Int
    let padding: Int
    /// The fill; glass's tint for `glass`.
    let background: String
    /// `outlined` only.
    let borderColor: String?
    /// `elevated` only: `look.carousel.cardShadow`.
    let shadow: RenderShadow?
    /// `glass` only: spec E's surface.
    let glass: RenderSurface?
    /// `glass` only: the strength it was resolved at.
    let strength: String?
}

/// Previous/next arrows — `RenderArrows` (spec CL §4.4).
struct RenderArrows: Decodable, Equatable, Sendable {
    /// `overlay|below`.
    let position: String
    let previousLabel: String
    let nextLabel: String
}

/// A marquee's drift — `RenderMarquee` (spec CL §4.1, §7).
struct RenderMarquee: Decodable, Equatable, Sendable {
    let pxPerS: Int
    /// `forward|backward`, logical (RTL mirrors the physical drift).
    let direction: String
    let pauseLabel: String
    let playLabel: String
}

/// `look.carousel` — `RenderCarouselLook` (spec CL §4.7): every number a
/// carousel drawer reads, so no drawer keeps one of its own. Percentages
/// are whole percent; lengths points.
struct RenderCarouselLook: Decodable, Equatable, Sendable {
    let neighbourScale: Int
    let neighbourOpacity: Int
    let stackDepth: Int
    let stackOffset: Int
    let stackScaleStep: Int
    let throwDistance: Int
    let throwTilt: Int
    let swipeThreshold: Int
    let flingVelocity: Int
    let dragSlop: Int
    let pillFactor: Int
    let barGap: Int
    let indicatorPitch: Int
    let indicatorMargin: Int
    let overlayInset: Int
    let counterPaddingX: Int
    let counterPaddingY: Int
    let counterWeight: Int
    let counterTextFactor: Int
    let arrowSize: Int
    let arrowInset: Int
    let arrowFillOpacity: Int
    let pauseSize: Int
    let cardPadding: Int
    let cardBorderWidth: Int
    let cardShadow: RenderShadow
    let cardElevation: Int
    let marqueeSlowPxPerS: Int
    let marqueeNormalPxPerS: Int
    let marqueeFastPxPerS: Int
}

/// A horizontal pager — `RenderBlock::Carousel` (layouts, cards,
/// indicators, transitions: spec CL §5.1); each child is one slide.
struct CarouselBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    /// `peek|paged|scale|stack|fade|marquee`.
    let layout: String
    let itemWidth: Int
    let align: String
    let gap: Int
    let card: RenderCarouselCard?
    let indicator: RenderIndicator?
    /// `counterOf` filled per slide; empty unless the indicator is a `counter`.
    let counterLabels: [String]
    let arrows: RenderArrows?
    /// Movement: a copy of the named look spring.
    let curve: RenderSpring
    /// Opacity and size: the named look speed, on `look.motion.fadeCurve`.
    let fadeMs: Int
    let marquee: RenderMarquee?
    let autoplayMs: Int?
    let looping: Bool
    /// `stack`: the height its depth cards add under the top card.
    let deckExtra: Int
    /// How far the pager's clip is pushed out (shadows, depth cards).
    let bleed: Int
    let children: [RenderBlock]

    private enum CodingKeys: String, CodingKey {
        case style, blockId, motion, layout, itemWidth, align, gap, card, indicator, counterLabels, arrows
        case curve, fadeMs, marquee, autoplayMs, looping, deckExtra, bleed, children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(RenderStyle.self, forKey: .style)
        _blockId = try c.decode(BlockId.self, forKey: .blockId)
        motion = try c.decodeIfPresent(RenderMotion.self, forKey: .motion)
        itemWidth = try c.decode(Int.self, forKey: .itemWidth)
        align = try c.decode(String.self, forKey: .align)
        gap = try c.decode(Int.self, forKey: .gap)
        layout = try c.decode(String.self, forKey: .layout)
        card = try c.decodeIfPresent(RenderCarouselCard.self, forKey: .card)
        indicator = try c.decodeIfPresent(RenderIndicator.self, forKey: .indicator)
        counterLabels = try c.decodeIfPresent([String].self, forKey: .counterLabels) ?? []
        arrows = try c.decodeIfPresent(RenderArrows.self, forKey: .arrows)
        curve = try c.decode(RenderSpring.self, forKey: .curve)
        fadeMs = try c.decode(Int.self, forKey: .fadeMs)
        marquee = try c.decodeIfPresent(RenderMarquee.self, forKey: .marquee)
        autoplayMs = try c.decodeIfPresent(Int.self, forKey: .autoplayMs)
        looping = try c.decodeIfPresent(Bool.self, forKey: .looping) ?? false
        deckExtra = try c.decode(Int.self, forKey: .deckExtra)
        bleed = try c.decode(Int.self, forKey: .bleed)
        children = try c.decode(LenientBlocks.self, forKey: .children).blocks
    }
}

/// One accordion item — `RenderAccordionItem`.
struct RenderAccordionItem: Decodable, Equatable, Sendable {
    @BlockId var blockId: String
    let style: RenderStyle
    let title: String
    let open: Bool
    let children: [RenderBlock]

    private enum CodingKeys: String, CodingKey { case blockId, style, title, open, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _blockId = try c.decode(BlockId.self, forKey: .blockId)
        style = try c.decode(RenderStyle.self, forKey: .style)
        title = try c.decode(String.self, forKey: .title)
        open = try c.decode(Bool.self, forKey: .open)
        children = try c.decode(LenientBlocks.self, forKey: .children).blocks
    }
}

/// Expandable items — `RenderBlock::Accordion`.
struct AccordionBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let mode: String
    let chevron: String
    let gap: Int
    let titleColor: String
    let titleSize: Int
    let items: [RenderAccordionItem]
    /// Spec F §7 N1: the item state read aloud; nil is "expanded" /
    /// "collapsed".
    let expandedLabel: String?
    let collapsedLabel: String?
}

// MARK: - Spec NE (2026-11-10-funnel-new-elements) §5.1, §6

/// `look.elements` — `RenderElementsLook`: every number a new-element
/// drawer reads. Lengths points, opacities percent, durations ms, ratios
/// per mille.
struct RenderElementsLook: Decodable, Equatable, Sendable {
    let popup: RenderPopupLook
    let countdown: RenderCountdownLook
    let loader: RenderLoaderLook
    let chart: RenderChartLook
    let lottie: RenderLottieLook
    /// One polite announcement per page per this window; a newer message
    /// replaces a queued one.
    let announceDebounceMs: Int
}

struct RenderPopupLook: Decodable, Equatable, Sendable {
    let scrimOpacity: Int
    let sheetRadius: Int
    let dialogRadius: Int
    let dialogMaxWidth: Int
    let padding: Int
    let closeSize: Int
    let closeHit: Int
    /// Web `exit` only: armed this long after the page's first frame.
    let exitArmMs: Int
}

struct RenderCountdownLook: Decodable, Equatable, Sendable {
    let boxRadius: Int
    let boxPadding: Int
    let boxGap: Int
    /// The digits' size against the body text size, percent.
    let digitScale: Int
    let separator: String
    let tabularDigits: Bool
    /// Days show from this much remaining, hours from this much; minutes
    /// and seconds always.
    let daysFromMs: Int
    let hoursFromMs: Int
    let tickMs: Int
}

struct RenderLoaderLook: Decodable, Equatable, Sendable {
    let ringSize: Int
    let ringStroke: Int
    let barHeight: Int
    let barRadius: Int
    let stepRowHeight: Int
    let stepGap: Int
}

struct RenderChartLook: Decodable, Equatable, Sendable {
    let height: Int
    let strokeWidth: Int
    let markerRadius: Int
    let areaOpacity: Int
    let barRadius: Int
    let barGap: Int
    /// The projection's ease, by name; the resolver already sampled it.
    let curve: String
    let curveSamples: Int
    /// Headroom above / below the curve, per mille of the plot box.
    let yPad: Int
}

struct RenderLottieLook: Decodable, Equatable, Sendable {
    /// Plays once this share of it is on screen, per mille.
    let visibleThreshold: Int
}

/// One countdown unit's words: short (drawn) and long (the accessible
/// label), each in the `one` and `other` forms.
struct RenderUnitWord: Decodable, Equatable, Sendable {
    let shortOne: String
    let shortOther: String
    let longOne: String
    let longOther: String
}

struct RenderCountdownUnits: Decodable, Equatable, Sendable {
    let days: RenderUnitWord
    let hours: RenderUnitWord
    let minutes: RenderUnitWord
    let seconds: RenderUnitWord
}

/// A countdown — `RenderBlock::Countdown`. `deadlineMs` is absolute epoch
/// ms; nil while an evergreen key has no anchor yet (the host asks the
/// session's `countdownAnchor`). Remaining = deadline − now; days show
/// only from `look.elements.countdown.daysFromMs`, hours only from
/// `hoursFromMs`; a unit word is `one` for a count in `pluralOne`.
struct CountdownBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let key: String
    /// `evergreen|deadline`.
    let mode: String
    /// `boxes|inline`.
    let display: String
    let label: String?
    /// `zeros|hide|text`.
    let atZero: String
    /// Drawn at zero (`text`) and announced at zero (always).
    let expiredText: String
    let deadlineMs: Int?
    let durationMs: Int?
    let expired: Bool
    let units: RenderCountdownUnits
    let pluralOne: [Int]
}

/// A popup — `RenderBlock::Popup` (spec NE §4.2). In the tree while its
/// page is eligible; `open` is the session's show flag. Takes no layout
/// space: a drawer lays it over the page.
struct PopupBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    /// `sheet|dialog`.
    let presentation: String
    /// `action|enter|exit`.
    let trigger: String
    let delayMs: Int
    let oncePerSession: Bool
    let closeButton: Bool
    let scrimDismiss: Bool
    /// The accessible name: the author's label, else the first heading
    /// child's text.
    let label: String?
    let closeLabel: String
    let open: Bool
    let children: [RenderBlock]

    private enum CodingKeys: String, CodingKey {
        case style, blockId, motion, presentation, trigger, delayMs, oncePerSession
        case closeButton, scrimDismiss, label, closeLabel, open, children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(RenderStyle.self, forKey: .style)
        _blockId = try c.decode(BlockId.self, forKey: .blockId)
        motion = try c.decodeIfPresent(RenderMotion.self, forKey: .motion)
        presentation = try c.decode(String.self, forKey: .presentation)
        trigger = try c.decode(String.self, forKey: .trigger)
        delayMs = try c.decode(Int.self, forKey: .delayMs)
        oncePerSession = try c.decode(Bool.self, forKey: .oncePerSession)
        closeButton = try c.decode(Bool.self, forKey: .closeButton)
        scrimDismiss = try c.decode(Bool.self, forKey: .scrimDismiss)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        closeLabel = try c.decode(String.self, forKey: .closeLabel)
        open = try c.decode(Bool.self, forKey: .open)
        children = try c.decode(LenientBlocks.self, forKey: .children).blocks
    }
}

struct RenderLoaderStep: Decodable, Equatable, Sendable {
    let label: String
    /// When this step completes, ms from the loader's start.
    let endsMs: Int
}

/// A determinate loader — `RenderBlock::Loader` (spec NE §4.3):
/// progress‰ = elapsed × 1000 / `durationMs` (elapsed from the page's first
/// frame, frozen while backgrounded); step i ends at `steps[i].endsMs`.
struct LoaderBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let durationMs: Int
    /// `bar|ring|none`.
    let indicator: String
    let showPercent: Bool
    let steps: [RenderLoaderStep]
    let holdCta: Bool
}

/// A Lottie — `RenderBlock::Lottie` (spec NE §4.4): a `width` (nil = the
/// content width) by width × 1000 / `aspectPermille` box. `playback` is
/// false where this target ships no player (native, P186): draw `poster`.
struct LottieBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let url: String
    let aspectPermille: Int
    let width: Int?
    let looping: Bool
    let speedPercent: Int
    /// `first|last` — the reduced-motion and failure frame.
    let still: String
    let poster: String?
    /// nil = decorative.
    let label: String?
    let playback: Bool
}

struct RenderChartBar: Decodable, Equatable, Sendable {
    let label: String
    /// The value, formatted in the visitor's language (with the unit).
    let value: String
    /// Per mille of the plot box's height.
    let height: Int
    let highlight: Bool
}

/// A chart — `RenderBlock::Chart` (spec NE §4.5), geometry drawn by the
/// resolver: every point is per mille of the plot box, x in READING order
/// (flip in RTL, `x' = 1000 − x`), y from the top. Drawers multiply.
struct ChartBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    /// `projection|bars`.
    let kind: String
    /// `line|area`.
    let fill: String
    /// Projection only: `[x‰, y‰]` pairs. Empty (omitted) for bars.
    let points: [[Int]]
    let startValue: String?
    let endValue: String?
    let startLabel: String?
    let endLabel: String?
    let marker: String?
    let unit: String?
    /// Bars only. Empty (omitted) for a projection.
    let bars: [RenderChartBar]
    /// The accessible summary.
    let label: String

    private enum CodingKeys: String, CodingKey {
        case style, blockId, motion, kind, fill, points, startValue, endValue, startLabel, endLabel
        case marker, unit, bars, label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(RenderStyle.self, forKey: .style)
        _blockId = try c.decode(BlockId.self, forKey: .blockId)
        motion = try c.decodeIfPresent(RenderMotion.self, forKey: .motion)
        kind = try c.decode(String.self, forKey: .kind)
        fill = try c.decode(String.self, forKey: .fill)
        points = try c.decodeIfPresent([[Int]].self, forKey: .points) ?? []
        startValue = try c.decodeIfPresent(String.self, forKey: .startValue)
        endValue = try c.decodeIfPresent(String.self, forKey: .endValue)
        startLabel = try c.decodeIfPresent(String.self, forKey: .startLabel)
        endLabel = try c.decodeIfPresent(String.self, forKey: .endLabel)
        marker = try c.decodeIfPresent(String.self, forKey: .marker)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        bars = try c.decodeIfPresent([RenderChartBar].self, forKey: .bars) ?? []
        label = try c.decode(String.self, forKey: .label)
    }
}

struct RenderConsentCategory: Decodable, Equatable, Sendable {
    /// `analytics|ads|experiments`.
    let id: String
    let label: String
}

/// The web-only consent element — `RenderBlock::CookieConsent` (spec NE
/// §4.6). The capability table keeps it off native funnels; decoded here
/// so a forward-version screen carrying one still decodes and describes.
struct CookieConsentBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    /// `banner|inline`.
    let display: String
    let title: String
    let body: String
    let categories: [RenderConsentCategory]
    let customize: Bool
    let policyUrl: String?
    let policyLabel: String
    let acceptAllLabel: String
    let onlyNecessaryLabel: String
    let customizeLabel: String
    let saveLabel: String
}

// MARK: - The block union

enum RenderBlock: Decodable, Equatable, Sendable {
    case heading(HeadingBlock)
    case text(TextBlock)
    case image(ImageBlock)
    case video(VideoBlock)
    case button(ButtonBlock)
    case spacer(SpacerBlock)
    case icon(IconBlock)
    case divider(DividerBlock)
    case activity(ActivityBlock)
    case review(ReviewBlock)
    case gallery(GalleryBlock)
    case stack(StackBlock)
    case progress(ProgressBlock)
    case question(QuestionBlock)
    case packageList(PackageListBlock)
    case comparisonTable(ComparisonTableBlock)
    case featureList(FeatureListBlock)
    case purchaseButton(PurchaseButtonBlock)
    case stickyFooter(StickyFooterBlock)
    case expressCheckout(ExpressCheckoutBlock)
    case check(CheckBlock)
    case cardCheckout(CardCheckoutBlock)
    case carousel(CarouselBlock)
    case accordion(AccordionBlock)
    // Spec NE §5.1.
    case countdown(CountdownBlock)
    case popup(PopupBlock)
    case loader(LoaderBlock)
    case lottie(LottieBlock)
    case chart(ChartBlock)
    case cookieConsent(CookieConsentBlock)

    private enum Discriminator: String, Decodable {
        case heading, text, image, video, button, spacer, icon, divider, activity, review
        case gallery, stack, progress, question, packageList, purchaseButton, stickyFooter
        case expressCheckout, comparisonTable, featureList
        case check, cardCheckout, carousel, accordion
        case countdown, popup, loader, lottie, chart, cookieConsent
    }

    private enum TypeKey: String, CodingKey { case type }

    /// Thrown for a `type` this build does not know. `LenientBlocks` turns
    /// it into a dropped element rather than a failed screen.
    struct UnknownType: Error {}

    /// Thrown for a progress bar missing the geometry its `barStyle` draws
    /// with; `LenientBlocks` drops it like an unknown type.
    struct MissingGeometry: Error {}

    init(from decoder: Decoder) throws {
        let typed = try decoder.container(keyedBy: TypeKey.self)
        guard let kind = try? typed.decode(Discriminator.self, forKey: .type) else {
            throw UnknownType()
        }
        switch kind {
        case .heading: self = .heading(try HeadingBlock(from: decoder))
        case .text: self = .text(try TextBlock(from: decoder))
        case .image: self = .image(try ImageBlock(from: decoder))
        case .video: self = .video(try VideoBlock(from: decoder))
        case .button: self = .button(try ButtonBlock(from: decoder))
        case .spacer: self = .spacer(try SpacerBlock(from: decoder))
        case .icon: self = .icon(try IconBlock(from: decoder))
        case .divider: self = .divider(try DividerBlock(from: decoder))
        case .activity: self = .activity(try ActivityBlock(from: decoder))
        case .review: self = .review(try ReviewBlock(from: decoder))
        case .gallery: self = .gallery(try GalleryBlock(from: decoder))
        case .stack: self = .stack(try StackBlock(from: decoder))
        case .progress:
            let progress = try ProgressBlock(from: decoder)
            guard progress.hasItsGeometry else { throw MissingGeometry() }
            self = .progress(progress)
        case .question: self = .question(try QuestionBlock(from: decoder))
        case .packageList: self = .packageList(try PackageListBlock(from: decoder))
        case .comparisonTable: self = .comparisonTable(try ComparisonTableBlock(from: decoder))
        case .featureList: self = .featureList(try FeatureListBlock(from: decoder))
        case .purchaseButton: self = .purchaseButton(try PurchaseButtonBlock(from: decoder))
        case .stickyFooter: self = .stickyFooter(try StickyFooterBlock(from: decoder))
        case .expressCheckout: self = .expressCheckout(try ExpressCheckoutBlock(from: decoder))
        case .check: self = .check(try CheckBlock(from: decoder))
        case .cardCheckout: self = .cardCheckout(try CardCheckoutBlock(from: decoder))
        case .carousel: self = .carousel(try CarouselBlock(from: decoder))
        case .accordion: self = .accordion(try AccordionBlock(from: decoder))
        case .countdown: self = .countdown(try CountdownBlock(from: decoder))
        case .popup: self = .popup(try PopupBlock(from: decoder))
        case .loader: self = .loader(try LoaderBlock(from: decoder))
        case .lottie: self = .lottie(try LottieBlock(from: decoder))
        case .chart: self = .chart(try ChartBlock(from: decoder))
        case .cookieConsent: self = .cookieConsent(try CookieConsentBlock(from: decoder))
        }
    }
}

/// Decodes a block list, DROPPING any entry whose type this build does not
/// know. A forward-version screen must still draw everything else.
struct LenientBlocks: Decodable, Equatable, Sendable {
    let blocks: [RenderBlock]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [RenderBlock] = []
        while !container.isAtEnd {
            if let block = try? container.decode(RenderBlock.self) {
                out.append(block)
            } else {
                // Decoding into a throwaway still advances the cursor,
                // which is what makes skipping possible at all.
                _ = try? container.decode(AnySkipped.self)
            }
        }
        blocks = out
    }

    private struct AnySkipped: Decodable, Equatable, Sendable {}
}

/// One `contact_info` sub-field — `RenderContactField` in `render.rs`: the
/// answer key it writes and the placeholder it shows, both resolved.
struct RenderContactField: Decodable, Equatable, Sendable {
    let key: String
    let placeholder: String
    /// Why this field's value cannot be used, or nil — empty included.
    let invalid: RenderInvalidReason?
}

/// Why an answer cannot be used — `InvalidReason` in `answer_rules.rs`,
/// tagged by `kind` (`email`, `phone`, `number`, `numberLow`,
/// `numberHigh`, `date`, `tooLong`); a range reason carries its bound,
/// which fills the copy's `{min}` / `{max}`.
struct RenderInvalidReason: Decodable, Equatable, Sendable {
    let kind: String
    let min: Double?
    let max: Double?
}

/// The drawer copy a screen speaks with — `RenderChromeCopy` in
/// `render.rs`, resolved for the screen's locale by
/// `funnel-core-rs/src/chrome_copy.rs` (spec D1). Every accessibility
/// string and contact placeholder this drawer shows comes from here or
/// from the block; none is written in Swift. `positionOf` carries the
/// literal `{n}` / `{m}` the drawer fills (see `FunnelA11y`).
///
/// Synthesized and strict: every field is required, as it is on the wire.
struct RenderChromeCopy: Decodable, Equatable, Sendable {
    let contactName: String
    let contactEmail: String
    let contactPhone: String
    let positionOf: String
    let selected: String
    let checked: String
    let unchecked: String
    let loading: String
    let back: String
    /// A comparison table's check cell, read aloud.
    let included: String
    /// A comparison table's dash cell, read aloud.
    let notIncluded: String
    /// The messages shown under a field whose answer cannot be used, one
    /// per `RenderInvalidReason` kind; `numberTooLow` keeps a literal
    /// `{min}` and `numberTooHigh` a literal `{max}` the drawer fills.
    let invalidEmail: String
    let invalidPhone: String
    let invalidNumber: String
    let numberTooLow: String
    let numberTooHigh: String
    let invalidDate: String
    let tooLong: String
}

/// The shared look a screen's blocks draw with — `RenderLook` in
/// `render.rs`, resolved once by `funnel-core-rs/src/look.rs`. Every
/// length, size, weight and colour this drawer uses comes from here or
/// from a block's own `RenderStyle` (which wins); none is invented in
/// Swift. Lengths are points; weights are CSS weights; `lineHeight` is a
/// percentage (145 = 1.45×); colours are opaque `#RRGGBB`.
///
/// Synthesized and strict: every field is required, as it is on the wire.
struct RenderLook: Decodable, Equatable, Sendable {
    let pagePaddingX: Int
    let pagePaddingTop: Int
    let pagePaddingBottom: Int
    let blockGap: Int
    let textSize: Int
    let textWeight: Int
    let lineHeight: Int
    /// Level 1, 2, 3+ — read through `headingSize(level:)`.
    let headingSizes: [Int]
    let headingWeight: Int
    let mutedTextSize: Int
    /// Option labels and a link's label.
    let labelWeight: Int
    /// A package row's title and price.
    let emphasisWeight: Int
    let buttonMinHeight: Int
    let buttonPaddingX: Int
    let buttonPaddingY: Int
    let buttonFontSize: Int
    let buttonFontWeight: Int
    let linkFontSize: Int
    let linkMinHeight: Int
    let cardPadding: Int
    let cardGap: Int
    let cardRadius: Int
    /// `var` so a package list can stand an authored row padding / gap in
    /// for these (spec F §8 H1, `FunnelPackageListView`).
    var rowPaddingX: Int
    var rowPaddingY: Int
    var rowGap: Int
    let indicatorSize: Int
    /// The multi-choice (checkbox) indicator's corner; single choice is a circle.
    let indicatorCornerRadius: Int
    /// Between a row's indicator and its content.
    let indicatorGap: Int
    let borderWidth: Int
    let selectedBorderWidth: Int
    let activitySize: Int
    /// The spinner ring's stroke width.
    let activityStroke: Int
    /// A single-line, date or contact field's minimum height (spec D1).
    let fieldMinHeight: Int
    /// Every field's padding inside its border.
    let fieldPaddingX: Int
    let fieldPaddingY: Int
    /// A long-text field's minimum height.
    let longTextMinHeight: Int
    /// An opinion-scale cell's minimum height.
    let scaleCellMinHeight: Int
    /// Between opinion-scale cells, and between rating stars.
    let scaleGap: Int
    let starSize: Int
    let sliderTrackHeight: Int
    let sliderThumbSize: Int
    /// A held-down button / CTA / purchase button's scale, in percent
    /// (97 = 0.97x).
    let pressScale: Int
    /// A held-down choice / yes-no / package row's scale, in percent.
    let rowPressScale: Int
    /// The press animation's duration in milliseconds, both ways.
    let pressMs: Int
    /// A package row's badge pill: size, weight, padding, radius (999 =
    /// a pill; clamp to half the height), and its overlap of the row's top
    /// edge, which the row reserves.
    let badgeFontSize: Int
    let badgeWeight: Int
    let badgePaddingX: Int
    let badgePaddingY: Int
    let badgeRadius: Int
    let badgeOffsetY: Int
    /// The shop package layouts: a pack's icon size, its title (the
    /// quantity) size, a tile's ribbon band height.
    let packIconSize: Int
    let packTitleSize: Int
    let packRibbonHeight: Int
    /// A comparison table: value-column width, row padding, header size
    /// and weight, check glyph size.
    let tableValueColumnWidth: Int
    let tableRowPaddingY: Int
    let tableHeaderSize: Int
    let tableHeaderWeight: Int
    let tableCheckSize: Int
    /// A feature list: icon size, icon-to-text gap, row gap.
    let featureIconSize: Int
    let featureIconGap: Int
    let featureItemGap: Int
    /// An option grid: tile gap, media-to-label gap, tile corner, a
    /// tile's minimum height and inset, an `icon` tile's glyph, and the
    /// lines a tile's label clamps to.
    let tileGap: Int
    let tileLabelGap: Int
    let tileRadius: Int
    let tileMinHeight: Int
    let tilePadding: Int
    let tileIconSize: Int
    let tileLabelLines: Int
    /// A dense grid's tile inset and label size, in place of
    /// `tilePadding` and the row's primary size.
    let tilePaddingDense: Int
    let tileLabelSizeDense: Int
    /// Wrapping chips: the gap (both axes), the inset, and the corner —
    /// clamped by the drawer to half the chip's height.
    let chipGap: Int
    let chipPaddingX: Int
    let chipPaddingY: Int
    let chipRadius: Int
    /// Between a gallery's tiles.
    let galleryGap: Int
    let text: String
    /// `var` so a package list can draw its selection in its own
    /// `highlight` (`FunnelPackageListView`); decoded like every field.
    var accent: String
    let card: String
    let border: String
    let muted: String
    /// Text drawn ON an `accent` fill — a selected opinion-scale cell.
    let onAccent: String
    /// The theme's "success" colour for this surface.
    let success: String
    /// Text drawn ON a `success` fill.
    let onSuccess: String
    /// A comparison table's highlighted column background.
    let tableHighlight: String
    /// A refused answer's message under its field, for this surface.
    let danger: String
    /// Every motion number this screen animates with (spec
    /// 2026-10-19-funnel-motion) — required like every look field: the
    /// bundled core resolves it on every look.
    let motion: RenderMotionTokens
    /// Every number a carousel drawer reads (spec CL §4.7) — required like
    /// `motion`: the bundled core resolves it on every look.
    let carousel: RenderCarouselLook
    /// Every number a new-element drawer reads (spec NE §6) — required
    /// like `carousel`: the bundled core resolves it on every look.
    let elements: RenderElementsLook

    /// `headingSizes[min(level, 3) - 1]` — the clamp `render.rs`'s
    /// `heading_size` makes every drawer use, so a level-4+ heading reads
    /// the last size rather than an index that is not there.
    func headingSize(level: Int) -> Int {
        guard let last = headingSizes.indices.last else { return textSize }
        return headingSizes[Swift.min(Swift.max(level, 1) - 1, last)]
    }
}

/// A page's own background, resolved — `RenderBackground` in `render.rs`
/// (spec D3). `kind` is `color`, `gradient`, `image` or `video`; a page
/// that authored none (or `none`) has no background at all. The optional
/// attributes are `null` on the wire. A gradient ALWAYS carries its angle:
/// the resolver fills it, so no drawer keeps a default, and a gradient
/// without one is a producer bug that fails the screen — as it does on
/// the web.
struct RenderBackground: Decodable, Hashable, Sendable {
    let kind: String
    let value: String
    let value2: String?
    let angle: Double?
    let opacity: Double?
    /// Image/video only: the legibility gradient over the media.
    let scrim: RenderScrim?
    /// Video only: the still drawn while loading and under Reduce Motion.
    let poster: String?

    static let kindColor = "color"
    static let kindGradient = "gradient"
    static let kindImage = "image"
    static let kindVideo = "video"

    private enum CodingKeys: String, CodingKey { case kind, value, value2, angle, opacity, scrim, poster }

    struct GradientWithoutAngle: Error {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        value = try c.decode(String.self, forKey: .value)
        value2 = try c.decode(String?.self, forKey: .value2)
        angle = try c.decode(Double?.self, forKey: .angle)
        opacity = try c.decode(Double?.self, forKey: .opacity)
        scrim = try c.decode(RenderScrim?.self, forKey: .scrim)
        poster = try c.decode(String?.self, forKey: .poster)
        if kind == Self.kindGradient && angle == nil { throw GradientWithoutAngle() }
    }
}

struct RenderScreen: Decodable, Equatable, Sendable {
    let screenId: String
    /// Position in the funnel's page order, for a progress indicator.
    let index: Int
    let total: Int
    /// The transition that brings this screen in when it is reached going
    /// forward. A step's own `transition` is what a navigation plays (back
    /// plays the mirror of the one that brought the page being left).
    let transition: String
    /// Whether blocks with an enter and no delay of their own cascade —
    /// already folded into each enter's `delayMs`; read only by the
    /// describer. Off on the wire when absent.
    let cascade: Bool
    /// The funnel's haptics switch: false silences every haptic this screen
    /// would play, the automatic ones included. On when absent.
    let haptics: Bool
    /// How long this screen shows before it advances itself, in
    /// milliseconds — `nil` when it does not. R2: the host owns the clock,
    /// so this is a schedule to arm, never a countdown to compute. A timed
    /// screen's `cta` is always `nil` (R4); do not treat one as implying
    /// the other absent.
    let autoAdvanceMs: Int?
    /// Set only on a permission screen. This — not an effect — is how a
    /// façade knows to raise the prompt: it is declarative and survives a
    /// redraw.
    let permission: String?
    /// The page's base colour: the theme's, or — when the page has its own
    /// background — that background's (a colour page's value, a
    /// gradient's first stop, the media base under a photo or video).
    let backgroundColor: String?
    /// The page's own background, drawn over `backgroundColor` and under
    /// the system bars. Required on the wire, `null` for none.
    let background: RenderBackground?
    /// Required — every screen resolves one, themed or not. No default:
    /// a screen without it is a producer bug, not an unstyled screen.
    let look: RenderLook
    /// Required, like `look`: the drawer copy for this screen's locale.
    let copy: RenderChromeCopy
    /// Whether the content is inset by the device safe area; the page
    /// background is edge to edge either way. On when absent.
    let safeArea: Bool
    /// Whether the status bar shows over this screen. On when absent.
    let statusBar: Bool
    /// `dark` when the screen was resolved in the funnel's dark palette —
    /// informational, the colours already are; nil when light.
    let scheme: String?
    /// The scrolling body's layout, resolved.
    let layout: RenderLayout
    /// The page padding around the body, resolved.
    let padding: RenderPadding
    /// The pinned header region above the scrolling body: the page's
    /// top-level progress block. Empty when the page has none.
    let header: [RenderBlock]
    /// The screen-pinned layer (`RenderScreen::overlay`): top-level absolute
    /// blocks with `fixed`, drawn above everything, pinned to the screen
    /// rather than the scroll. Empty when the page has none.
    let overlay: [RenderBlock]
    let blocks: [RenderBlock]
    let cta: RenderCta?

    private enum CodingKeys: String, CodingKey {
        case screenId, index, total, transition, cascade, haptics, autoAdvanceMs, permission,
            backgroundColor, background, look, copy, safeArea, statusBar, scheme, layout, padding,
            header, overlay, blocks, cta
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenId = try c.decode(String.self, forKey: .screenId)
        index = try c.decode(Int.self, forKey: .index)
        total = try c.decode(Int.self, forKey: .total)
        transition = try c.decode(String.self, forKey: .transition)
        // Both left off the wire at their default (`skip_serializing_if`).
        cascade = try c.decodeIfPresent(Bool.self, forKey: .cascade) ?? false
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
        autoAdvanceMs = try c.decodeIfPresent(Int.self, forKey: .autoAdvanceMs)
        permission = try c.decodeIfPresent(String.self, forKey: .permission)
        backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor)
        // `decode`, not `decodeIfPresent`: the key is required, its value
        // may be null.
        background = try c.decode(RenderBackground?.self, forKey: .background)
        look = try c.decode(RenderLook.self, forKey: .look)
        copy = try c.decode(RenderChromeCopy.self, forKey: .copy)
        // Left off the wire at their default (`skip_serializing_if`).
        safeArea = try c.decodeIfPresent(Bool.self, forKey: .safeArea) ?? true
        statusBar = try c.decodeIfPresent(Bool.self, forKey: .statusBar) ?? true
        scheme = try c.decodeIfPresent(String.self, forKey: .scheme)
        // The resolver always writes both. Absent is a screen from before
        // they existed: today's column in the look's padding.
        layout = try c.decodeIfPresent(RenderLayout.self, forKey: .layout) ?? .column
        padding = try c.decodeIfPresent(RenderPadding.self, forKey: .padding) ?? RenderPadding(look: look)
        header = try c.decodeIfPresent(LenientBlocks.self, forKey: .header)?.blocks ?? []
        overlay = try c.decodeIfPresent(LenientBlocks.self, forKey: .overlay)?.blocks ?? []
        cta = try c.decodeIfPresent(RenderCta.self, forKey: .cta)
        blocks = try c.decode(LenientBlocks.self, forKey: .blocks).blocks
    }
}

/// A screen's body layout — `RenderLayout` in `render.rs`, every field
/// resolved. `alignX`/`alignY` are logical and already swapped by the
/// resolver for `mirrorRtl: false`.
struct RenderLayout: Decodable, Equatable, Sendable {
    let direction: String
    let alignX: String
    let alignY: String
    let distribute: String
    /// The space the body adds between its top-level blocks; `0` with
    /// `gapAuthored` false means the look's rhythm stays in each block's
    /// top margin. Never add `look.blockGap` on top.
    let gap: Double
    /// Whether `gap` is the author's. False when absent.
    let gapAuthored: Bool

    // The wire's values and defaults — `look.rs` (`LAYOUT_VERTICAL`,
    // `ALIGN_*`, `DISTRIBUTE_PACKED`, `RHYTHM_BODY_GAP`).
    static let directionVertical = "vertical"
    static let directionHorizontal = "horizontal"
    static let directionWrap = "wrap"
    static let alignLeft = "left"
    static let alignCenter = "center"
    static let alignRight = "right"
    static let alignTop = "top"
    static let alignBottom = "bottom"
    static let distributePacked = "packed"
    static let distributeSpaceBetween = "space-between"
    static let distributeSpaceAround = "space-around"
    static let distributeSpaceEvenly = "space-evenly"
    static let rhythmBodyGap = 0.0

    /// Today's page: a top-left packed column spaced by the rhythm.
    static let column = RenderLayout(
        direction: directionVertical, alignX: alignLeft, alignY: alignTop,
        distribute: distributePacked, gap: rhythmBodyGap, gapAuthored: false)

    init(
        direction: String, alignX: String, alignY: String, distribute: String, gap: Double,
        gapAuthored: Bool
    ) {
        self.direction = direction
        self.alignX = alignX
        self.alignY = alignY
        self.distribute = distribute
        self.gap = gap
        self.gapAuthored = gapAuthored
    }

    private enum CodingKeys: String, CodingKey {
        case direction, alignX, alignY, distribute, gap, gapAuthored
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decode(String.self, forKey: .direction)
        alignX = try c.decode(String.self, forKey: .alignX)
        alignY = try c.decode(String.self, forKey: .alignY)
        distribute = try c.decode(String.self, forKey: .distribute)
        gap = try c.decode(Double.self, forKey: .gap)
        gapAuthored = try c.decodeIfPresent(Bool.self, forKey: .gapAuthored) ?? false
    }
}

/// A screen's padding per side — `RenderPadding` in `render.rs`.
struct RenderPadding: Decodable, Equatable, Sendable {
    let top: Double
    let right: Double
    let bottom: Double
    let left: Double

    init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    /// The look's page padding — what the resolver writes for a page whose
    /// author set none.
    init(look: RenderLook) {
        self.init(
            top: Double(look.pagePaddingTop), right: Double(look.pagePaddingX),
            bottom: Double(look.pagePaddingBottom), left: Double(look.pagePaddingX))
    }
}

/// `nil` when the payload is structurally wrong. An unknown BLOCK type is
/// not structurally wrong — it is dropped.
func decodeRenderScreen(_ json: String) -> RenderScreen? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(RenderScreen.self, from: data)
}
