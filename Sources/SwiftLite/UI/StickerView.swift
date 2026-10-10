import AppKit
import Lottie
import SwiftUI

/// Stickers and big animated emoji, drawn without a bubble like the official clients do.
/// .tgs stickers play through Lottie; video (.webm) stickers show TDLib's still preview, since
/// AVFoundation cannot decode WebM.
struct StickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @Environment(\.controlActiveState) private var activeState
    @AppStorage(Preferences.animateStickers) private var animates = true

    let sticker: Sticker

    @State private var picture: Picture?

    private enum Picture {
        case image(NSImage)
        case animation(LottieAnimation)
    }

    var body: some View {
        let size = displaySize
        Group {
            switch picture {
            case .animation(let animation):
                LottieView(animation: animation)
                    .resizable()
                    // A window in the background or the setting turned off stops the animation: no reason
                    // to keep the GPU busy for something nobody is looking at.
                    .playbackMode(isPlaying
                        ? .playing(.fromProgress(0, toProgress: 1, loopMode: .loop))
                        : .paused(at: .currentFrame))
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            case nil:
                Text(sticker.emoji)
                    .font(.system(size: min(size.width, size.height) * 0.5))
                    .opacity(0.3)
            }
        }
        .frame(width: size.width, height: size.height)
        .help(sticker.emoji)
        .task(id: sticker.fileId) { picture = await load() }
    }

    private var isPlaying: Bool {
        animates && activeState != .inactive
    }

    /// Stickers are 512 pixels on the long side; the long side is shown at 160 points (96 for emoji).
    private var displaySize: CGSize {
        let side: CGFloat = sticker.isEmoji ? 96 : 160
        guard sticker.width > 0, sticker.height > 0 else { return CGSize(width: side, height: side) }
        let scale = side / CGFloat(max(sticker.width, sticker.height))
        return CGSize(width: (CGFloat(sticker.width) * scale).rounded(), height: (CGFloat(sticker.height) * scale).rounded())
    }

    private func load() async -> Picture? {
        let pixels = Int((max(displaySize.width, displaySize.height) * displayScale).rounded(.up))
        switch sticker.format {
        case .webp:
            if let path = await model.localFile(id: sticker.fileId, priority: 16),
               let image = await MediaCache.image(atPath: path, pixels: pixels) { return .image(image) }
        case .tgs:
            if let path = await model.localFile(id: sticker.fileId, priority: 16),
               let animation = await MediaCache.animation(atPath: path) { return .animation(animation) }
        case .webm:
            break
        }
        guard let thumbnail = sticker.thumbnailFileId,
              let path = await model.localFile(id: thumbnail, priority: 16),
              let image = await MediaCache.image(atPath: path, pixels: pixels) else { return nil }
        return .image(image)
    }
}
