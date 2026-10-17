//  Icon.swift — a funnel icon (spec 2026-10-11-genre-funnel-templates
//  §10.4 V1).
//
//  The geometry, colour, size and each layer's opacity are the tree's
//  (`RenderIcon`): the path data is absolute M/L/C/Z on the `iconGrid` box,
//  normalised by funnel-core's generator, so this file parses four
//  commands, scales the box to `size` and fills. It decides nothing.
//
//  An SF Symbols reference (icon packs spec §2, §4.4) carries its vector
//  fallback's `layers` AND a `systemSymbol`. When this OS has the symbol
//  (`UIImage(systemName:)` resolves) it is drawn with `Image(systemName:)`
//  in the tree's mode, weight, colour and size, mapped through
//  `FunnelSymbolStyle`; otherwise — a symbol newer than the OS — the
//  layers are drawn, exactly as Android and the web draw them.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private enum IconFormat {
    /// `opacity` on the wire is a percent.
    static let opacityPercent = 100.0
    static let pointsPerMoveOrLine = 1
    static let pointsPerCubic = 3
    /// An absent padding, radius or margin is none; an absent opacity is opaque.
    static let none: CGFloat = 0
    static let opaque = 1.0
}

/// The tree's SF Symbol mode and weight names → SwiftUI's — `SF_MODES` /
/// `SF_WEIGHTS` in icons.rs. A name missing here draws the fallback
/// layers rather than guessing.
enum FunnelSymbolStyle {
    static let modes: [String: SymbolRenderingMode] = [
        "monochrome": .monochrome,
        "hierarchical": .hierarchical,
        "palette": .palette,
        "multicolor": .multicolor,
    ]
    static let weights: [String: Font.Weight] = [
        "light": .light,
        "regular": .regular,
        "semibold": .semibold,
        "bold": .bold,
    ]

    /// Whether this OS ships the symbol `name` — the runtime check spec FM3
    /// rests on: a symbol newer than the OS is nil here.
    static func available(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return false
        #endif
    }
}

/// An SF Symbol drawn by the OS, `size` square, in the tree's mode and
/// weight, filled `color` (and the palette's `secondary`).
struct FunnelSystemSymbolView: View {
    let symbol: RenderSystemSymbol
    let mode: SymbolRenderingMode
    let weight: Font.Weight
    let color: Color
    let size: Int

    var body: some View {
        // Scaled to fit the tree's box: a symbol's natural bounds at a font
        // size can exceed that size (brain.fill) and would be clipped. The
        // font carries the weight, which a resizable symbol keeps.
        let image = Image(systemName: symbol.name)
            .resizable()
            .symbolRenderingMode(mode)
            .scaledToFit()
            .font(.system(size: CGFloat(size), weight: weight))
        Group {
            if let secondary = symbol.secondary {
                image.foregroundStyle(color, lookColor(secondary))
            } else {
                image.foregroundStyle(color)
            }
        }
        .frame(width: CGFloat(size), height: CGFloat(size))
        .accessibilityHidden(true)
    }
}

/// One icon, `icon.size` square: the system symbol when the tree names one
/// this OS has, else every layer filled in `icon.color`.
struct FunnelIconGlyph: View {
    let icon: RenderIcon

    var body: some View {
        // The resolver always writes a `#RRGGBB` here (the accent when
        // nothing named one, `painted_icon` in resolve.rs).
        let color = lookColor(icon.color)
        if let symbol = icon.systemSymbol,
           let mode = FunnelSymbolStyle.modes[symbol.mode],
           let weight = FunnelSymbolStyle.weights[symbol.weight],
           FunnelSymbolStyle.available(symbol.name) {
            FunnelSystemSymbolView(symbol: symbol, mode: mode, weight: weight, color: color, size: icon.size)
        } else {
            FunnelIconLayers(icon: icon, color: color)
        }
    }
}

/// The icon's vector layers — its own, or an SF reference's fallback's.
struct FunnelIconLayers: View {
    let icon: RenderIcon
    let color: Color

    var body: some View {
        ZStack {
            ForEach(Array(icon.layers.enumerated()), id: \.offset) { _, layer in
                FunnelIconShape(d: layer.d)
                    .fill(color)
                    .opacity(Double(layer.opacity) / IconFormat.opacityPercent)
            }
        }
        .frame(width: CGFloat(icon.size), height: CGFloat(icon.size))
        .accessibilityHidden(true)
    }
}

/// A list icon — an option row's, a feature item's, a pack's — inside its
/// plate when the tree gives one: `plate.padding` on every side, filled
/// `plate.background`, corners `plate.radius` (already clamped by the
/// resolver). The box is the glyph plus the padding; nothing here is this
/// drawer's own number. Without a plate the glyph is drawn bare. The web's
/// `IconPlate`.
struct FunnelIconPlate: View {
    let icon: RenderIcon

    var body: some View {
        if let plate = icon.plate {
            FunnelIconGlyph(icon: icon)
                .padding(CGFloat(plate.padding))
                .background(
                    lookColor(plate.background),
                    in: RoundedRectangle(cornerRadius: CGFloat(plate.radius)))
                .fixedSize()
        } else {
            FunnelIconGlyph(icon: icon)
        }
    }
}

/// One layer's path, scaled from the icon grid to the drawn rect. Filled
/// with the non-zero rule (`Shape.fill`'s default), as on the web and
/// Android.
struct FunnelIconShape: Shape {
    let d: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / CGFloat(RenderIcon.iconGrid)
        var path = Path()
        var tokens = FunnelPathTokens(d)
        while let command = tokens.nextCommand() {
            switch command {
            case "M":
                if let p = tokens.points(IconFormat.pointsPerMoveOrLine, scale: scale, in: rect).first {
                    path.move(to: p)
                }
            case "L":
                if let p = tokens.points(IconFormat.pointsPerMoveOrLine, scale: scale, in: rect).first {
                    path.addLine(to: p)
                }
            case "C":
                let p = tokens.points(IconFormat.pointsPerCubic, scale: scale, in: rect)
                if p.count == IconFormat.pointsPerCubic {
                    path.addCurve(to: p[2], control1: p[0], control2: p[1])
                }
            case "Z":
                path.closeSubpath()
            default:
                // The generator writes only the four commands; anything else
                // is a corrupt layer, drawn as far as it went.
                return path
            }
        }
        return path
    }
}

/// A cursor over `M`/`L`/`C`/`Z` path data: a command letter, then its
/// numbers separated by single spaces.
struct FunnelPathTokens {
    private let scalars: [Character]
    private var index = 0

    init(_ d: String) { scalars = Array(d) }

    mutating func nextCommand() -> Character? {
        while index < scalars.count, scalars[index] == " " { index += 1 }
        guard index < scalars.count, scalars[index].isLetter else { return nil }
        defer { index += 1 }
        return scalars[index]
    }

    mutating func number() -> CGFloat? {
        while index < scalars.count, scalars[index] == " " { index += 1 }
        let start = index
        while index < scalars.count, !scalars[index].isLetter, scalars[index] != " " { index += 1 }
        return Double(String(scalars[start..<index])).map { CGFloat($0) }
    }

    mutating func points(_ count: Int, scale: CGFloat, in rect: CGRect) -> [CGPoint] {
        var out: [CGPoint] = []
        for _ in 0..<count {
            guard let x = number(), let y = number() else { return out }
            out.append(CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale))
        }
        return out
    }
}

/// The standalone icon block: the glyph on its plate when the tree gives
/// one (`FunnelIconPlate`, the list icons' own view — spec 2026-10-17-icon-
/// block-plate-and-radius §2.3; an SF symbol draws inside it), inside
/// whatever padding, fill and radius its style carries, wrapped to its
/// content and positioned by `align`.
struct FunnelIconView: View {
    let block: IconBlock
    let look: RenderLook

    init(block: IconBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    var body: some View {
        FunnelIconPlate(icon: block.glyph)
            .padding(.top, block.style.paddingTop.map(CGFloat.init) ?? IconFormat.none)
            .padding(.trailing, block.style.paddingRight.map(CGFloat.init) ?? IconFormat.none)
            .padding(.bottom, block.style.paddingBottom.map(CGFloat.init) ?? IconFormat.none)
            .padding(.leading, block.style.paddingLeft.map(CGFloat.init) ?? IconFormat.none)
            .background(funnelColor(block.style.background))
            .clipShape(RoundedRectangle(cornerRadius: block.style.radius.map(CGFloat.init) ?? IconFormat.none))
            .frame(
                maxWidth: .infinity,
                alignment: Alignment(horizontal: funnelAlignment(block.style.align), vertical: .center)
            )
            .opacity(block.style.opacity.map { Double($0) / IconFormat.opacityPercent } ?? IconFormat.opaque)
            .padding(.top, block.style.marginTop.map(CGFloat.init) ?? IconFormat.none)
            .padding(.bottom, block.style.marginBottom.map(CGFloat.init) ?? IconFormat.none)
    }
}
