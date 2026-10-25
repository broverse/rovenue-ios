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
    let radius: Int?
    let height: Int?
    /// An outline's thickness and colour, written by the resolver together
    /// or not at all — so either one being nil means "no outline". Two
    /// fields rather than a CSS shorthand: this drawer wants a `CGFloat`
    /// and a `Color`, not a sentence to parse.
    let borderWidth: Int?
    let borderColor: String?
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

    private enum CodingKeys: String, CodingKey {
        case style, label, enabled, actionPath, icon, iconPosition, size, sizeLook, haptic, motion
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
        alignSelf: nil
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
}

struct VideoBlock: Decodable, Equatable, Sendable {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let url: String
    /// The still drawn while it loads and under Reduce Motion / Low Power.
    let poster: String?
}

struct ButtonBlock: Decodable, Equatable, Sendable, FunnelButtonParts {
    let style: RenderStyle
    @BlockId var blockId: String
    let motion: RenderMotion?
    let label: String
    let variant: String
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
    let children: [RenderBlock]

    private enum CodingKeys: String, CodingKey {
        case style, blockId, motion, direction, gap, alignX, alignY, distribute, children
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

    private enum Discriminator: String, Decodable {
        case heading, text, image, video, button, spacer, icon, divider, activity, review
        case gallery, stack, progress, question, packageList, purchaseButton, stickyFooter
        case expressCheckout, comparisonTable, featureList
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
    let rowPaddingX: Int
    let rowPaddingY: Int
    let rowGap: Int
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
    let blocks: [RenderBlock]
    let cta: RenderCta?

    private enum CodingKeys: String, CodingKey {
        case screenId, index, total, transition, cascade, haptics, autoAdvanceMs, permission,
            backgroundColor, background, look, copy, safeArea, statusBar, scheme, layout, padding,
            header, blocks, cta
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
