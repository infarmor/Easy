import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Photos, videos, GIFs and video messages inside the transcript.
struct MediaView: View {
    let message: Message
    let media: MediaInfo
    /// A fixed cell size inside an album; otherwise the picture's own proportions.
    var fill: CGSize? = nil

    var body: some View {
        switch media.kind {
        case .photo: PhotoView(message: message, media: media, fill: fill)
        case .video, .animation: ClipView(message: message, media: media, fill: fill)
        case .videoNote: VideoNoteView(message: message, media: media)
        case .voiceNote: VoiceNoteView(message: message, media: media)
        }
    }

    /// Keeps the picture's proportions inside a 300×300 box, never thinner than a finger.
    static func size(of media: MediaInfo, fitting side: CGFloat = 300) -> CGSize {
        guard media.width > 0, media.height > 0 else { return CGSize(width: side, height: side * 0.66) }
        let scale = min(side / CGFloat(media.width), side / CGFloat(media.height))
        return CGSize(width: max(CGFloat(media.width) * scale, 90).rounded(), height: max(CGFloat(media.height) * scale, 60).rounded())
    }
}

/// The still picture of a media message: the downloaded image, a thumbnail, or TDLib's blurred preview.
/// The still picture of a media message, sharpening in steps: TDLib's inline blur, a small size, the real one.
struct Poster: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let media: MediaInfo
    let size: CGSize
    /// Photos show the photo itself; clips show their thumbnail.
    let fileId: Int?
    /// A smaller copy to show while `fileId` downloads.
    var previewFileId: Int? = nil

    @State private var image: NSImage?
    @State private var preview: NSImage?

    private var pixels: Int { Int((max(size.width, size.height) * displayScale).rounded(.up)) }

    var body: some View {
        let cached = fileId.flatMap { model.downloadedPath(of: $0) }.flatMap { MediaCache.cachedImage(atPath: $0, pixels: pixels) }
        ZStack {
            // Visible on light and dark backgrounds alike while nothing is loaded yet.
            Rectangle().fill(Color.gray.opacity(0.3))
            if let sharp = image ?? cached {
                Image(nsImage: sharp)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
            } else if let mini = media.minithumbnail.flatMap({ MediaCache.minithumbnail($0, id: fileId ?? media.fileId) }) {
                Image(nsImage: mini)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 6)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(.smooth(duration: 0.2), value: image != nil)
        .task(id: fileId) {
            guard let fileId, cached == nil else { return }
            if let previewFileId, let path = await model.localFile(id: previewFileId, priority: 12) {
                preview = await MediaCache.image(atPath: path, pixels: pixels / 2)
            }
            guard let path = await model.localFile(id: fileId, priority: 8) else { return }
            image = await MediaCache.image(atPath: path, pixels: pixels)
        }
    }
}

private struct PhotoView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let media: MediaInfo
    let fill: CGSize?

    private var hidden: Bool { media.hasSpoiler && !model.isRevealed(message) }

    var body: some View {
        let size = fill ?? MediaView.size(of: media)
        Poster(media: media, size: size, fileId: media.fileId, previewFileId: media.previewFileId)
            .blur(radius: hidden ? 24 : 0)
            .overlay {
                if hidden {
                    Label("Спойлер", systemImage: "eye.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: Capsule())
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                // A spoiler is revealed by the first click; after that a click opens the viewer.
                if hidden {
                    withAnimation(.smooth(duration: 0.25)) { model.revealSpoiler(of: message) }
                } else {
                    model.viewerMessage = message
                }
            }
            .help("Открыть фото")
    }
}

/// Full-size photo over the conversation: ← and → walk through the chat's photos, Esc or a click outside closes.
struct PhotoViewer: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var image: NSImage?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.82))
                .ignoresSafeArea()
                .onTapGesture { close() }
            if let media = message.media {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Poster(media: media, size: MediaView.size(of: media, fitting: 520), fileId: media.fileId, previewFileId: media.previewFileId)
                            .overlay { ProgressView().controlSize(.small) }
                    }
                }
                .scaleEffect(zoom * pinch)
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 1), 5) })
                .onTapGesture(count: 2) { withAnimation(.smooth(duration: 0.2)) { zoom = zoom > 1 ? 1 : 2.5 } }
                .padding(40)
            }
            VStack {
                HStack(spacing: 14) {
                    if let position = model.viewerPosition {
                        Text("\(position.index + 1) из \(position.count)")
                            .monospacedDigit()
                    }
                    Text(model.name(for: message) + " · " + message.date.formatted(.dateTime.day().month(.wide).hour().minute().locale(Locale(identifier: "ru_RU"))))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { copy() } label: { Image(systemName: "doc.on.doc") }
                        .help("Скопировать фото")
                    Button { save() } label: { Image(systemName: "square.and.arrow.down") }
                        .help("Сохранить…")
                    Button { Task { await model.openAttachment(of: message) } } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Открыть в Просмотре")
                    Button { close() } label: { Image(systemName: "xmark") }
                        .help("Закрыть (Esc)")
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.black.opacity(0.35))
                Spacer()
                if !message.caption.isEmpty {
                    Text(formattedText(message.caption, message.entities))
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.bottom, 20)
                }
            }
            HStack {
                arrow("chevron.left", step: -1, key: .leftArrow)
                Spacer()
                arrow("chevron.right", step: 1, key: .rightArrow)
            }
            .padding(.horizontal, 12)
        }
        .transition(.opacity)
        .task(id: message.id) {
            image = nil
            zoom = 1
            // The largest size is the attachment; it opens sharp even when zoomed in.
            guard let fileId = message.attachment?.fileId,
                  let path = await model.localFile(id: fileId, priority: 32) else { return }
            image = await MediaCache.image(atPath: path, pixels: 3000)
        }
    }

    private func arrow(_ symbol: String, step: Int, key: KeyEquivalent) -> some View {
        Button { model.stepViewer(step) } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .opacity(canStep(step) ? 1 : 0)
        .disabled(!canStep(step))
    }

    private func canStep(_ step: Int) -> Bool {
        guard let position = model.viewerPosition else { return false }
        return (0..<position.count).contains(position.index + step)
    }

    private func close() {
        withAnimation(.smooth(duration: 0.15)) { model.viewerMessage = nil }
    }

    private func copy() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func save() {
        guard let attachment = message.attachment,
              let destination = Dialogs.saveLocation(suggestedName: attachment.name) else { return }
        Task { await model.saveAttachment(of: message, to: destination) }
    }
}

/// Videos play in place after a click; GIFs loop silently on their own, like in the official clients.
private struct ClipView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    @AppStorage(Preferences.animateStickers) private var animates = true
    let message: Message
    let media: MediaInfo
    let fill: CGSize?

    @State private var player: AVPlayer?
    @State private var looper: AVPlayerLooper?
    @State private var isLoading = false

    /// Larger GIFs wait for a click instead of downloading on their own.
    private static let autoplayLimit: Int64 = 8 * 1024 * 1024

    var body: some View {
        let size = fill ?? MediaView.size(of: media)
        ZStack {
            if let player, media.kind == .video {
                PlayerControlsView(player: player)
            } else if let player {
                PlayerLayerView(player: player)
            } else {
                Poster(media: media, size: size, fileId: media.thumbnailFileId)
                overlay
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if player == nil { Task { await start() } } }
        .task(id: media.fileId) {
            if media.kind == .animation, animates, media.fileSize <= Self.autoplayLimit { await start() }
        }
        .onChange(of: activeState) { _, state in
            guard media.kind == .animation else { return }
            state == .inactive ? player?.pause() : player?.play()
        }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var overlay: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white, .black.opacity(0.45))
        }
        VStack {
            Spacer()
            HStack {
                Text(media.kind == .animation ? "GIF" : Self.duration(media.duration))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                Spacer()
            }
        }
        .padding(6)
    }

    private func start() async {
        // Scrolling back to a GIF finds it paused, still holding its player: resume, or it stays a still frame.
        if let player { player.play(); return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let path = await model.localFile(id: media.fileId, priority: 16) else { return }
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        if media.kind == .animation {
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        } else {
            player = AVPlayer(playerItem: item)
        }
        if media.kind == .video || activeState != .inactive { player?.play() }
    }

    static func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A round video message: a click plays it with sound, another click pauses.
private struct VideoNoteView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let media: MediaInfo

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = false

    private let side: CGFloat = 200

    var body: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player)
            } else {
                Poster(media: media, size: CGSize(width: side, height: side), fileId: media.thumbnailFileId)
            }
            if isLoading {
                ProgressView().controlSize(.small)
            } else if !isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay { progressRing }
        .contentShape(Circle())
        .onTapGesture { Task { await toggle() } }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            isPlaying = false
            player?.seek(to: .zero)
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
        .help("Видеосообщение, \(ClipView.duration(media.duration))")
    }

    @ViewBuilder
    private var progressRing: some View {
        if let player, isPlaying {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let duration = player.currentItem?.duration.seconds ?? 0
                let progress = duration > 0 ? player.currentTime().seconds / duration : 0
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.5)
            }
        }
    }

    private func toggle() async {
        if let player {
            isPlaying ? player.pause() : player.play()
            isPlaying.toggle()
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let path = await model.localFile(id: media.fileId, priority: 32) else { return }
        let player = AVPlayer(url: URL(fileURLWithPath: path))
        self.player = player
        player.play()
        isPlaying = true
        model.noteVideoMessagePlayed(message)
    }
}

/// Photos and videos sent together, laid out by their own proportions the way Telegram and Photos do it:
/// each row is as tall as its pictures need to span the album's width side by side, so a landscape shot stays
/// wide and a portrait one stays tall instead of both being cut to squares.
struct AlbumView: View {
    let messages: [Message]

    static let width: CGFloat = 300
    static let gap: CGFloat = 3

    var body: some View {
        let rows = Self.layout(messages.filter { $0.media != nil })
        VStack(spacing: Self.gap) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: Self.gap) {
                    ForEach(rows[index], id: \.message.id) { cell in
                        if let media = cell.message.media {
                            MediaView(message: cell.message, media: media, fill: cell.size)
                        }
                    }
                }
            }
        }
    }

    struct Cell {
        var message: Message
        var size: CGSize
    }

    /// How many pictures go in each row, for every album size Telegram allows.
    static func rowSizes(for count: Int) -> [Int] {
        switch count {
        case ...0: []
        case 1: [1]
        case 2: [2]
        case 3: [1, 2]
        case 4: [1, 3]
        case 5: [2, 3]
        case 6: [3, 3]
        case 7: [2, 2, 3]
        case 8: [2, 3, 3]
        case 9: [3, 3, 3]
        default: [2, 2, 3, 3]
        }
    }

    static func layout(_ items: [Message]) -> [[Cell]] {
        var rows: [[Cell]] = []
        var rest = items[...]
        var sizes = rowSizes(for: items.count)
        // Whatever the table does not cover goes three to a row.
        let covered = sizes.reduce(0, +)
        if covered < items.count { sizes += Array(repeating: 3, count: (items.count - covered + 2) / 3) }
        for size in sizes where !rest.isEmpty {
            let row = Array(rest.prefix(size))
            rest = rest.dropFirst(size)
            // Width over height; a picture of unknown size counts as a square, and extremes are reined in so
            // a panorama does not squeeze its neighbour to a sliver.
            let ratios = row.map { message -> CGFloat in
                guard let media = message.media, media.width > 0, media.height > 0 else { return 1 }
                return min(max(CGFloat(media.width) / CGFloat(media.height), 0.6), 2.2)
            }
            let free = width - gap * CGFloat(row.count - 1)
            let total = ratios.reduce(0, +)
            // The height at which the row exactly spans the width; kept within what reads well in a chat.
            let height = min(max(free / total, 70), row.count == 1 ? 300 : 200).rounded()
            var cells: [Cell] = []
            var used: CGFloat = 0
            for (index, message) in row.enumerated() {
                // The last cell takes what is left, so rounding never leaves a hairline at the edge.
                let cellWidth = index == row.count - 1 ? free - used : (free * ratios[index] / total).rounded()
                used += cellWidth
                cells.append(Cell(message: message, size: CGSize(width: cellWidth, height: height)))
            }
            rows.append(cells)
        }
        return rows
    }
}

/// A voice message: play button, waveform (click to jump), elapsed and total time.
private struct VoiceNoteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.bubbleAccent) private var accent
    /// The button is a disc of the accent with the glyph cut in the other colour; in your own bubble the two
    /// trade places.
    private var glyph: Color { message.isOutgoing ? Color.accentColor : .white }
    let message: Message
    let media: MediaInfo
    @State private var isLoading = false

    private static let barCount = 44
    private static let width: CGFloat = 190

    private var voice: VoicePlayer { .shared }
    private var isCurrent: Bool { voice.currentFileId == media.fileId }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await toggle() }
            } label: {
                ZStack {
                    Circle().fill(accent)
                    if isLoading {
                        ProgressView().controlSize(.small).tint(glyph)
                    } else {
                        Image(systemName: isCurrent && voice.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(glyph)
                            .offset(x: isCurrent && voice.isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            // Redraws ten times a second only while this message is the one playing.
            TimelineView(.periodic(from: .now, by: isCurrent && voice.isPlaying ? 0.1 : 3600)) { _ in
                VStack(alignment: .leading, spacing: 3) {
                    bars(progress: isCurrent ? voice.progress : 0)
                        .frame(width: Self.width, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard isCurrent else { return }
                            voice.seek(to: location.x / Self.width)
                        }
                    Text(timeLabel)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var timeLabel: String {
        let total = ClipView.duration(media.duration)
        guard isCurrent, voice.elapsed > 0 else { return total }
        return "\(ClipView.duration(Int(voice.elapsed))) / \(total)"
    }

    /// The waveform squeezed or stretched to a fixed number of bars; played ones take the accent colour.
    private func bars(progress: Double) -> some View {
        let heights = Self.resample(media.waveform, to: Self.barCount)
        return HStack(alignment: .center, spacing: 2) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(Double(index) / Double(heights.count) < progress ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary.opacity(message.isOutgoing ? 0.6 : 0.45)))
                    .frame(width: 2.3, height: max(3, 22 * CGFloat(heights[index]) / 31))
            }
        }
    }

    static func resample(_ samples: [UInt8], to count: Int) -> [UInt8] {
        guard !samples.isEmpty else { return Array(repeating: 4, count: count) }
        return (0..<count).map { bar in
            let start = bar * samples.count / count
            let end = max(start + 1, (bar + 1) * samples.count / count)
            return samples[start..<min(end, samples.count)].max() ?? 0
        }
    }

    private func toggle() async {
        if isCurrent {
            voice.toggle()
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let path = await model.localFile(id: media.fileId, priority: 32) else { return }
        // Decoding a minute of Opus takes a moment; it happens off the main thread.
        let playable = await Task.detached(priority: .userInitiated) {
            OggOpus.playableFile(for: URL(fileURLWithPath: path))
        }.value
        guard let playable else {
            model.report("Не удалось воспроизвести голосовое сообщение")
            return
        }
        voice.play(playable, fileId: media.fileId)
        model.noteVideoMessagePlayed(message)
    }
}

/// AppKit's player with its usual controls. SwiftUI's `VideoPlayer` from AVKit crashes on macOS 27
/// while its metadata is set up, so the AppKit view is wrapped instead.
struct PlayerControlsView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}

/// AVPlayerLayer without controls, filling its frame.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
