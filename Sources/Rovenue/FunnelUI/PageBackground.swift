//  PageBackground.swift — a page's own background (spec D3), drawn the way
//  the web's `page-frame.tsx` draws it.
//
//  The resolver already chose everything: `backgroundColor` is the page's
//  base colour (a colour page's value, a gradient's first stop, the media
//  base under a photo or video), `background` what goes over it, and a
//  gradient always carries its angle. This file only paints: colour → a
//  fill; gradient → a linear gradient at the CSS angle; image → an
//  aspect-filled photo; video → a muted, looping, aspect-filled video. A
//  photo or video is drawn at `opacity` over the base, which is exactly a
//  scrim of the base at `1 − opacity`; one that never loads leaves the
//  base showing. The whole layer runs under the system bars.

import SwiftUI

#if canImport(UIKit)
    import AVFoundation
    import UIKit
#endif

private enum BackgroundFormat {
    /// A media background with no authored opacity is opaque — the web's
    /// `OPAQUE`, applied only when drawing.
    static let opaque = 1.0
    static let half: CGFloat = 2
    static let degreesToRadians = Double.pi / 180
    /// `opacity` and `extent` are percents on the wire.
    static let percent = 100.0
    static let clear = 0.0
}

struct FunnelPageBackground: View {
    /// The page's base colour, already resolved.
    let base: Color
    let background: RenderBackground?

    var body: some View {
        ZStack {
            base
            if let background { layer(background) }
            // The legibility gradient over the media, under the content.
            if let scrim = background?.scrim { FunnelScrim(scrim: scrim) }
        }
        .ignoresSafeArea()
    }

    /// A still, aspect-filled — an image background, or a video's poster.
    private func still(_ url: URL) -> some View {
        Color.clear
            .overlay(
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            )
            .clipped()
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion or Low Power Mode: a video background shows its
    /// poster and does not play.
    private var stillOnly: Bool {
        reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    @ViewBuilder
    private func layer(_ b: RenderBackground) -> some View {
        switch b.kind {
        case RenderBackground.kindColor:
            if let color = funnelColor(b.value) { color }
        case RenderBackground.kindGradient:
            if let from = funnelColor(b.value), let angle = b.angle {
                FunnelCssGradient(
                    from: from, to: funnelColor(b.value2) ?? from, angleDegrees: angle)
            }
        case RenderBackground.kindImage:
            if let url = URL(string: b.value) {
                still(url).opacity(b.opacity ?? BackgroundFormat.opaque)
            }
        case RenderBackground.kindVideo:
            ZStack {
                // The poster shows while the video loads, and instead of it
                // under Reduce Motion / Low Power.
                if let poster = b.poster.flatMap(URL.init(string:)) { still(poster) }
                #if canImport(UIKit)
                    if !stillOnly, let url = URL(string: b.value) {
                        // A new URL is a new player, never the old one updated.
                        FunnelLoopingVideo(url: url).id(url)
                    }
                #endif
            }
            .opacity(b.opacity ?? BackgroundFormat.opaque)
        default:
            // A kind this build does not know leaves the base showing.
            EmptyView()
        }
    }
}

/// The scrim the tree resolved (`RenderScrim`): from `edge`, `color` at
/// `opacity` fading to clear over `extent` of the height — or, for `full`,
/// one even wash. Its numbers are the resolver's.
private struct FunnelScrim: View {
    let scrim: RenderScrim

    var body: some View {
        let color = funnelColor(scrim.color) ?? .black
        let dense = color.opacity(Double(scrim.opacity) / BackgroundFormat.percent)
        if scrim.edge == RenderScrim.edgeFull {
            dense
        } else {
            let fromTop = scrim.edge == RenderScrim.edgeTop
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: dense, location: BackgroundFormat.clear),
                    .init(
                        color: color.opacity(BackgroundFormat.clear),
                        location: CGFloat(Double(scrim.extent) / BackgroundFormat.percent)),
                ]),
                startPoint: fromTop ? .top : .bottom,
                endPoint: fromTop ? .bottom : .top)
        }
    }
}

/// CSS `linear-gradient(<angle>deg, from, to)`: 0° runs bottom → top, 90°
/// left → right, and the gradient line is exactly long enough that the
/// box's corners land on the two stops — so a 180° gradient's first
/// stop is the top edge and its last the bottom edge, as on the web.
private struct FunnelCssGradient: View {
    let from: Color
    let to: Color
    let angleDegrees: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let radians = angleDegrees * BackgroundFormat.degreesToRadians
            let dx = CGFloat(sin(radians))
            let dy = CGFloat(-cos(radians))
            let half = (abs(w * dx) + abs(h * dy)) / BackgroundFormat.half
            let cx = w / BackgroundFormat.half
            let cy = h / BackgroundFormat.half
            // Unit points relative to the box; a zero-sized box has none.
            let unit = { (x: CGFloat, y: CGFloat) in
                UnitPoint(x: w > 0 ? x / w : 0, y: h > 0 ? y / h : 0)
            }
            LinearGradient(
                colors: [from, to],
                startPoint: unit(cx - dx * half, cy - dy * half),
                endPoint: unit(cx + dx * half, cy + dy * half))
        }
    }
}

#if canImport(UIKit)

    /// A looping, aspect-filled video — `AVPlayerLayer`, no controls. It
    /// plays a VIDEO-ONLY composition of the asset: with no audio track in
    /// the item, the background can never touch the host's audio (its
    /// session, its route, a playing podcast). The audio session is never
    /// configured here. It does not keep the display awake, never goes to
    /// AirPlay, and resumes when the app comes back to the foreground.
    private struct FunnelLoopingVideo: UIViewRepresentable {
        let url: URL

        func makeUIView(context: Context) -> PlayerView {
            let view = PlayerView()
            view.playerLayer.videoGravity = .resizeAspectFill
            view.isUserInteractionEnabled = false
            view.load { await Self.videoOnlyItem(url) }
            return view
        }

        func updateUIView(_ view: PlayerView, context: Context) {}

        static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
            view.stop()
        }

        private static func videoOnlyItem(_ url: URL) async -> AVPlayerItem? {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                let duration = try? await asset.load(.duration),
                let transform = try? await track.load(.preferredTransform)
            else { return nil }
            let composition = AVMutableComposition()
            guard
                let video = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            do {
                try video.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            } catch {
                return nil
            }
            video.preferredTransform = transform
            return AVPlayerItem(asset: composition)
        }

        final class PlayerView: UIView {
            private var looper: AVPlayerLooper?
            private var activeObserver: NSObjectProtocol?
            private var loading: Task<Void, Never>?
            private var stopped = false

            /// Loads the item off the view, then starts it — unless the
            /// view was dismantled meanwhile: `stop` cancels the load, and
            /// a load that finishes anyway never starts a player. An
            /// unreachable or trackless URL leaves the base colour showing.
            func load(_ item: @escaping @Sendable () async -> AVPlayerItem?) {
                loading = Task { @MainActor [weak self] in
                    guard let loaded = await item(), !Task.isCancelled,
                        let self, !self.stopped
                    else { return }
                    self.start(loaded)
                }
            }

            private func start(_ item: AVPlayerItem) {
                let player = AVQueuePlayer()
                player.isMuted = true
                player.preventsDisplaySleepDuringVideoPlayback = false
                player.allowsExternalPlayback = false
                looper = AVPlayerLooper(player: player, templateItem: item)
                playerLayer.player = player
                activeObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
                ) { [weak player] _ in player?.play() }
                player.play()
            }

            func stop() {
                stopped = true
                loading?.cancel()
                loading = nil
                playerLayer.player?.pause()
                looper = nil
                if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
                activeObserver = nil
            }

            override class var layerClass: AnyClass { AVPlayerLayer.self }
            var playerLayer: AVPlayerLayer {
                // swiftlint:disable:next force_cast
                layer as! AVPlayerLayer
            }
        }
    }

#endif
