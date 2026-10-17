//  Media.swift — image, video and gallery.
//
//  A URL that does not parse renders a placeholder rather than crashing: a
//  draft saves mid-edit, so a half-typed URL can reach a device.

import AVKit
import SwiftUI

private enum MediaFormat {
    static let videoAspectRatio: CGFloat = 16.0 / 9.0
    static let noBleed: CGFloat = 0
}

struct FunnelImageView: View {
    let block: ImageBlock
    let look: RenderLook

    init(block: ImageBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    var body: some View {
        picture
        // Full width; a radius in the style clips the corners.
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityLabel(block.alt ?? "")
        .funnelStyle(block.style, look.bodyType)
        // A bleeding image cancels the page's side padding — the look's.
        .padding(.horizontal, block.bleed ? -CGFloat(look.pagePaddingX) : MediaFormat.noBleed)
    }

    /// With a fixed height the picture FILLS that box, cropping (aspect
    /// fill); without one it is aspect fit at full width — the rule the
    /// web and Android draw.
    ///
    /// The fill is an overlay on `Color.clear`, never the image itself in
    /// the layout: an aspect-filled image REPORTS the size that fills its
    /// proposal, which is wider than the proposal whenever the box is
    /// narrower than the art (Fern's 4:3 hero at 330 pt high reports 440 pt
    /// against a 402 pt screen), and `.frame(maxWidth: .infinity)` never
    /// shrinks below its child — so the whole column grew and the heading
    /// and CTA ran off the right edge (spec 2026-10-12-open-followups §3).
    /// `Color.clear` takes exactly the proposal; the overlay fills and is
    /// clipped to it. The page background and the question tiles already
    /// draw their fills this way.
    @ViewBuilder
    private var picture: some View {
        if block.style.height != nil {
            Color.clear.overlay(
                AsyncImage(url: URL(string: block.url)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            )
        } else {
            AsyncImage(url: URL(string: block.url)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
        }
    }
}

/// Muted and looping. A funnel screen's video
/// is decoration, not something someone came to watch.
struct FunnelVideoView: View {
    let block: VideoBlock
    let look: RenderLook

    @State private var player: AVPlayer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(block: VideoBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    /// Reduce Motion or Low Power Mode: the poster stands in for the loop.
    private var stillOnly: Bool {
        reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        Group {
            if stillOnly, let poster = block.poster.flatMap(URL.init(string:)) {
                AsyncImage(url: poster) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
            } else if let player {
                VideoPlayer(player: player)
                    .aspectRatio(MediaFormat.videoAspectRatio, contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !stillOnly, let url = URL(string: block.url) else { return }
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
            player.play()
            self.player = player
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .funnelStyle(block.style, look.bodyType)
    }
}

struct FunnelGalleryView: View {
    let block: GalleryBlock
    let look: RenderLook

    init(block: GalleryBlock, look: RenderLook) {
        self.block = block
        self.look = look
    }

    /// `columns` is always filled by the resolver, so no default is
    /// invented here; the tiles sit `look.galleryGap` apart.
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: CGFloat(look.galleryGap)),
            count: max(1, block.columns))
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: CGFloat(look.galleryGap)) {
            ForEach(block.urls, id: \.self) { url in
                AsyncImage(url: URL(string: url)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipped()
            }
        }
        .funnelStyle(block.style, look.bodyType)
    }
}
