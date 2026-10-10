import AppKit
import Lottie
import SwiftUI

/// Stickers and big animated emoji, drawn without a bubble like the official clients do.
/// .tgs stickers play through Lottie; video (.webm) stickers through `WebMVideo`, which decodes them itself
/// because nothing in macOS plays a WebM with its transparency. One that cannot be decoded shows TDLib's
/// still preview.
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
        case video(WebMVideo.Clip)
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
            case .video(let clip):
                VideoStickerPlayer(clip: clip, isPlaying: isPlaying)
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
            if animates, let path = await model.localFile(id: sticker.fileId, priority: 16) {
                let clip = await Task.detached(priority: .utility) { () -> WebMVideo.Clip? in
                    // Telegram caps a video sticker at 256 KB; anything far beyond that is not one.
                    guard let data = FileManager.default.contents(atPath: path), data.count <= 2 * 1024 * 1024 else { return nil }
                    return WebMVideo.parse(data)
                }.value
                if let clip { return .video(clip) }
            }
        }
        guard let thumbnail = sticker.thumbnailFileId,
              let path = await model.localFile(id: thumbnail, priority: 16),
              let image = await MediaCache.image(atPath: path, pixels: pixels) else { return nil }
        return .image(image)
    }
}

/// A video sticker playing in a loop. Frames are decoded one at a time, just before they are shown, on a
/// queue of the view's own: nothing is kept but the frame on screen, so a chat full of stickers costs their
/// decoders and not their footage.
struct VideoStickerPlayer: NSViewRepresentable {
    let clip: WebMVideo.Clip
    let isPlaying: Bool

    func makeNSView(context: Context) -> VideoStickerView {
        let view = VideoStickerView()
        view.show(clip)
        return view
    }

    func updateNSView(_ view: VideoStickerView, context: Context) {
        view.isPlaying = isPlaying
    }

    static func dismantleNSView(_ view: VideoStickerView, coordinator: ()) {
        view.stop()
    }
}

final class VideoStickerView: NSView {
    private let queue = DispatchQueue(label: "ru.anemia.swiftlite.sticker", qos: .userInitiated)
    /// Touched on `queue` only.
    private nonisolated(unsafe) var renderer: WebMVideo.Renderer?
    /// Bumped to end the loop that is running: a loop keeps going only while it is still the newest.
    private nonisolated(unsafe) var round = 0
    private let lock = NSLock()

    var isPlaying = true {
        didSet {
            guard isPlaying != oldValue else { return }
            isPlaying ? run() : halt()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }

    func show(_ clip: WebMVideo.Clip) {
        queue.async { [weak self] in self?.renderer = WebMVideo.Renderer(clip: clip) }
        run()
    }

    /// Off screen nothing plays: a recycled row must not keep decoding into a view nobody sees.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { halt() } else if isPlaying { run() }
    }

    func stop() {
        halt()
        queue.async { [weak self] in self?.renderer = nil }
    }

    private func halt() {
        lock.lock()
        round += 1
        lock.unlock()
    }

    private func run() {
        lock.lock()
        round += 1
        let mine = round
        lock.unlock()
        step(mine)
    }

    private func step(_ mine: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.round
            self.lock.unlock()
            guard current == mine, let frame = self.renderer?.nextFrame() else { return }
            let image = frame.image
            DispatchQueue.main.async { [weak self] in
                // Without an implicit animation: CALayer would cross-fade every frame into the next.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.layer?.contents = image
                CATransaction.commit()
            }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(frame.hold)) { [weak self] in self?.step(mine) }
        }
    }
}
