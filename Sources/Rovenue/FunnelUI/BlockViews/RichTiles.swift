//  RichTiles.swift — a picture grid's authored tile anatomy (Spec B §4):
//  `tileStyle` (media aspect, text placement, scrim, selected ring and
//  indicator, radius, video autoplay), the option's own media (an image, or
//  a muted looping video with its poster), and the per-option chips the
//  resolver already filtered and filled.
//
//  Drawn only when the resolver sends `tileStyle`; a grid without one keeps
//  `FunnelOptionTiles`' plain tile, untouched.
//
//  Video plays muted, looped, inline and without controls, only while the
//  tile is on screen, at most `FunnelTileVideoBudget.maxPlaying` at once;
//  every other tile shows its poster. Reduce Motion and Low Power Mode show
//  posters only (the author cannot override that); `videoAutoplay: false`
//  plays only the selected tile; `videoAutoplayOnCellular: false` shows
//  posters on a cellular path.

import Combine
import Foundation
import Network
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

private enum TileFormat {
    static let aspectSquare: CGFloat = 1
    /// Width over height for each `mediaAspect`.
    static let aspectPortrait: CGFloat = 3.0 / 4.0
    static let aspectTall: CGFloat = 9.0 / 16.0
    static let aspectLandscape: CGFloat = 16.0 / 9.0
    static let mediaVideo = "video"
    static let placementBelow = "below"
    static let placementOverlayTop = "overlayTop"
    static let placementOverlayBottom = "overlayBottom"
    static let scrimNone = "none"
    static let scrimTop = "top"
    static let scrimBottom = "bottom"
    static let scrimFull = "full"
    static let indicatorNone = "none"
    static let indicatorCheck = "check"
    /// Spec F §6 F4: an unselected tile without its indicator, and the
    /// description above the label (every placement, overlays included).
    static let unselectedNone = "none"
    static let descriptionAbove = "aboveLabel"
    /// A chip's dot is half its text size across (`CHIP_DOT_RATIO`, web).
    static let chipDotRatio: CGFloat = 0.5
    static let cornerTopStart = "topStart"
    static let cornerTopEnd = "topEnd"
    static let cornerBottomStart = "bottomStart"
    static let cornerBottomEnd = "bottomEnd"
    /// The scrim's darkest stop: black at this opacity, fading to clear —
    /// what keeps overlaid copy readable on any media.
    static let scrimOpacity = 0.6
    /// Overlaid copy sits on the scrim, so it is light whatever the theme.
    static let overlayText = Color.white
    static let checkGlyph = "checkmark"
    /// The check glyph inside its disc, as a share of the disc.
    static let checkGlyphShare: CGFloat = 0.55
}

/// A tile's media aspect (width over height) for a `mediaAspect`.
private func tileAspect(_ name: String) -> CGFloat {
    switch name {
    case "portrait": return TileFormat.aspectPortrait
    case "tall": return TileFormat.aspectTall
    case "landscape": return TileFormat.aspectLandscape
    default: return TileFormat.aspectSquare
    }
}

/// One rich tile — the label, chips, ring and indicator over or under the
/// option's media.
struct FunnelRichTile: View {
    let option: RenderOption
    let style: RenderTileStyle
    let look: RenderLook
    let labelFont: Font
    let labelSize: CGFloat
    let rowText: FunnelRowText
    let selected: Bool
    let shape: FunnelIndicatorShape

    var body: some View {
        let r = RoundedRectangle(cornerRadius: CGFloat(style.radius))
        VStack(spacing: 0) {
            media
            if style.textPlacement == TileFormat.placementBelow {
                label.padding(labelInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(look.cardColor)
        .clipShape(r)
        .overlay(
            r.strokeBorder(
                selected ? (funnelColor(style.ringColor) ?? look.accentColor) : look.borderColor,
                lineWidth: CGFloat(selected ? style.ringWidth : look.borderWidth)))
        .contentShape(r)
    }

    private var media: some View {
        look.borderColor
            .aspectRatio(tileAspect(style.mediaAspect), contentMode: .fit)
            .overlay { FunnelTileMedia(option: option, style: style, selected: selected) }
            .overlay { scrim }
            .overlay(alignment: overlayAlignment) {
                if style.textPlacement != TileFormat.placementBelow {
                    label
                        .foregroundColor(TileFormat.overlayText)
                        .padding(labelInset)
                }
            }
            .overlay { chipsLayer.padding(CGFloat(look.tileLabelGap)) }
            .overlay(alignment: .topTrailing) {
                indicator.padding(CGFloat(look.tileLabelGap))
            }
            .clipped()
            .contentShape(Rectangle())
    }

    /// The copy's padding (spec F §8 H12): the authored text inset — y
    /// top/bottom, x leading/trailing — else the look's label gap.
    private var labelInset: EdgeInsets {
        guard let inset = style.textInset else {
            let gap = CGFloat(look.tileLabelGap)
            return EdgeInsets(top: gap, leading: gap, bottom: gap, trailing: gap)
        }
        let x = CGFloat(inset.x)
        let y = CGFloat(inset.y)
        return EdgeInsets(top: y, leading: x, bottom: y, trailing: x)
    }

    private var overlayAlignment: Alignment {
        style.textPlacement == TileFormat.placementOverlayTop ? .top : .bottom
    }

    private var label: some View {
        VStack(spacing: 0) {
            if descriptionAbove { descriptionText }
            Text(option.label)
                .font(labelFont)
                .lineLimit(look.tileLabelLines)
                .funnelLineHeight(look, size: labelSize, family: rowText.family)
            if !descriptionAbove { descriptionText }
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// Spec F §6 F4 `descriptionPosition: aboveLabel` (WG03's "HD 10s").
    private var descriptionAbove: Bool { style.descriptionPosition == TileFormat.descriptionAbove }

    @ViewBuilder
    private var descriptionText: some View {
        if let description = option.description, !description.isEmpty {
            FunnelDescriptionCopy(text: description, segments: option.descriptionSegments, rowText: rowText, look: look)
                .font(rowText.secondaryFont(weight: look.textWeight))
                .opacity(style.textPlacement == TileFormat.placementBelow ? 1 : LookOverlay.descriptionOpacity)
                .ifLet(style.textPlacement == TileFormat.placementBelow ? look.mutedColor : nil) {
                    $0.foregroundColor($1)
                }
                .funnelLineHeight(look, size: rowText.secondary, family: rowText.family)
        }
    }

    /// The scrim behind overlaid copy. `none` draws nothing.
    @ViewBuilder
    private var scrim: some View {
        let dark = Color.black.opacity(TileFormat.scrimOpacity)
        switch style.scrim {
        case TileFormat.scrimBottom:
            LinearGradient(colors: [.clear, dark], startPoint: .center, endPoint: .bottom)
        case TileFormat.scrimTop:
            LinearGradient(colors: [dark, .clear], startPoint: .top, endPoint: .center)
        case TileFormat.scrimFull:
            dark
        default:
            EmptyView()
        }
    }

    /// The option's chips in their corners, in template order; two in one
    /// corner stack vertically (Spec B §4.2). A chip in the indicator's
    /// corner starts below the indicator.
    private var chipsLayer: some View {
        let chips = option.chips ?? []
        let gap = CGFloat(look.chipGap)
        return ZStack {
            ForEach([TileFormat.cornerTopStart, TileFormat.cornerTopEnd, TileFormat.cornerBottomStart, TileFormat.cornerBottomEnd], id: \.self) { corner in
                let here = chips.filter { $0.corner == corner }
                if !here.isEmpty {
                    VStack(alignment: horizontal(corner), spacing: gap) {
                        ForEach(Array(here.enumerated()), id: \.offset) { _, chip in chipView(chip) }
                    }
                    .padding(.top, corner == TileFormat.cornerTopEnd && style.indicator != TileFormat.indicatorNone
                        ? CGFloat(look.indicatorSize) + gap : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(corner))
                }
            }
        }
    }

    /// Whether the indicator draws on this tile now: never for `none`, and
    /// not on an unselected tile whose `unselected.indicator` is `none`.
    private var hasIndicator: Bool {
        style.indicator != TileFormat.indicatorNone
            && (selected || style.unselectedIndicator != TileFormat.unselectedNone)
    }

    private func horizontal(_ corner: String) -> HorizontalAlignment {
        corner == TileFormat.cornerTopEnd || corner == TileFormat.cornerBottomEnd ? .trailing : .leading
    }

    private func alignment(_ corner: String) -> Alignment {
        switch corner {
        case TileFormat.cornerTopEnd: return .topTrailing
        case TileFormat.cornerBottomStart: return .bottomLeading
        case TileFormat.cornerBottomEnd: return .bottomTrailing
        default: return .topLeading
        }
    }

    private func chipView(_ chip: RenderChip) -> some View {
        HStack(spacing: CGFloat(look.badgePaddingX) / LookOverlay.half) {
            // A two-colour chip (spec F §6 F4): a filled dot before the text.
            if let dot = funnelColor(chip.dot) {
                let side = (CGFloat(look.badgeFontSize) * TileFormat.chipDotRatio).rounded()
                Circle().fill(dot).frame(width: side, height: side).accessibilityHidden(true)
            }
            if let icon = chip.icon { FunnelIconPlate(icon: icon) }
            Text(chip.text)
        }
        .font(.system(size: CGFloat(look.badgeFontSize), weight: funnelFontWeight(look.badgeWeight)))
        .foregroundColor(funnelColor(chip.color) ?? look.onAccentColor)
        .padding(.horizontal, CGFloat(look.badgePaddingX))
        .padding(.vertical, CGFloat(look.badgePaddingY))
        .background(funnelColor(chip.background) ?? look.accentColor, in: Capsule())
        .lineLimit(1)
    }

    /// `corner`: the radio/checkbox mark, resting and selected, in the
    /// indicator colour; `check`: a disc with a check, only when selected;
    /// `none`: nothing.
    @ViewBuilder
    private var indicator: some View {
        let color = funnelColor(style.indicatorColor) ?? look.accentColor
        let size = CGFloat(look.indicatorSize)
        switch style.indicator {
        case _ where !hasIndicator:
            EmptyView()
        case TileFormat.indicatorCheck:
            if selected {
                Circle().fill(color)
                    .overlay(
                        Image(systemName: TileFormat.checkGlyph)
                            .font(.system(size: size * TileFormat.checkGlyphShare, weight: .bold))
                            // Spec F §7 G4: the authored glyph colour; the
                            // plate keeps `indicatorColor`.
                            .foregroundColor(funnelColor(style.indicatorGlyphColor) ?? look.onAccentColor))
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
        default:
            Group {
                switch shape {
                case .radio:
                    Circle().strokeBorder(color, lineWidth: CGFloat(look.selectedBorderWidth))
                        .background(Circle().fill(selected ? color : look.cardColor))
                case .checkbox:
                    let r = RoundedRectangle(cornerRadius: CGFloat(look.indicatorCornerRadius))
                    r.strokeBorder(color, lineWidth: CGFloat(look.selectedBorderWidth))
                        .background(r.fill(selected ? color : look.cardColor))
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}

private enum LookOverlay {
    static let half: CGFloat = 2
    /// An overlaid description reads one step quieter than its label.
    static let descriptionOpacity = 0.8
}

/// The option's media filling its slot: the video when this tile may play,
/// else the still — the image, or the video's poster (`imageUrl`, which
/// the resolver fills from either, P10).
private struct FunnelTileMedia: View {
    let option: RenderOption
    let style: RenderTileStyle
    let selected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var path = FunnelNetworkPath.shared
    @State private var visible = false
    @StateObject private var slot = FunnelTileVideoSlot()

    private var videoURL: URL? {
        guard let media = option.media, media.kind == TileFormat.mediaVideo else { return nil }
        return URL(string: media.url)
    }

    /// Whether this tile wants to play, before the budget says yes.
    private var wantsPlayback: Bool {
        guard videoURL != nil, visible else { return false }
        if reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if !style.videoAutoplay { return selected }
        if path.isCellular && !style.videoAutoplayOnCellular { return false }
        return true
    }

    var body: some View {
        ZStack {
            if let still = (option.imageUrl ?? option.media?.poster).flatMap(URL.init(string:)) {
                FunnelAsyncImage(url: still) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
            #if canImport(UIKit)
                if let url = videoURL, slot.granted {
                    FunnelLoopingVideo(url: url)
                }
            #endif
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { visible = onScreen(proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { visible = onScreen($0) }
            }
        )
        .onChange(of: wantsPlayback) { slot.request($0) }
        .onAppear { slot.request(wantsPlayback) }
        .onDisappear { slot.request(false) }
    }

    @MainActor
    private func onScreen(_ frame: CGRect) -> Bool {
        #if canImport(UIKit)
            let screen = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first ?? .zero
            return frame.intersects(screen) && !frame.isEmpty
        #else
            return false
        #endif
    }
}

/// At most `maxPlaying` tile and slide videos play at once (Spec B §4.3);
/// a request past it shows the poster until a slot frees.
@MainActor
final class FunnelTileVideoBudget {
    static let shared = FunnelTileVideoBudget()
    static let maxPlaying = 4

    private var holders: Set<UUID> = []
    private var waiting: [UUID] = []
    private var grants: [UUID: (Bool) -> Void] = [:]

    func request(_ id: UUID, wants: Bool, grant: @escaping (Bool) -> Void) {
        if wants {
            guard !holders.contains(id) else { return }
            grants[id] = grant
            if holders.count < Self.maxPlaying {
                holders.insert(id)
                grant(true)
            } else if !waiting.contains(id) {
                waiting.append(id)
                grant(false)
            }
        } else {
            waiting.removeAll { $0 == id }
            grants[id] = nil
            if holders.remove(id) != nil {
                grant(false)
                if let next = waiting.first {
                    waiting.removeFirst()
                    holders.insert(next)
                    grants[next]?(true)
                }
            }
        }
    }
}

/// One view's claim on `FunnelTileVideoBudget`; released when the view goes.
@MainActor
final class FunnelTileVideoSlot: ObservableObject {
    @Published private(set) var granted = false
    private let id = UUID()

    func request(_ wants: Bool) {
        FunnelTileVideoBudget.shared.request(id, wants: wants) { [weak self] in self?.granted = $0 }
    }

    deinit {
        let id = id
        Task { @MainActor in FunnelTileVideoBudget.shared.request(id, wants: false) { _ in } }
    }
}

/// Whether the device's current path is cellular — `NWPathMonitor`.
final class FunnelNetworkPath: ObservableObject {
    static let shared = FunnelNetworkPath()
    @Published private(set) var isCellular = false
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            DispatchQueue.main.async { self?.isCellular = cellular }
        }
        monitor.start(queue: DispatchQueue(label: "dev.rovenue.funnel.network-path"))
    }
}
