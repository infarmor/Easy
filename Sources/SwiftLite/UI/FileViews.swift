import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let russian = Locale(identifier: "ru_RU")

private func bytes(_ count: Int64) -> String {
    count.formatted(.byteCount(style: .file).locale(russian))
}

/// A file in a message: its Finder icon, name and size; a ring while it travels; a click to download, open or stop.
struct DocumentView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let document: DocumentInfo

    private var transfer: FileTransfer? { model.transfers[document.fileId] }
    private var isUploading: Bool { message.isPending }
    private var isDownloading: Bool { transfer?.isDownloading == true }
    private var isDownloaded: Bool { transfer?.isDownloaded == true }

    var body: some View {
        HStack(spacing: 11) {
            FileIcon(name: document.name, path: isDownloaded ? transfer?.path : nil, side: 44)
                .overlay { progressOverlay }
                .help(primaryHelp)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.trackTitle.isEmpty ? document.name : document.trackTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(status)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
        .contentShape(Rectangle())
        // One gesture pair for the whole card. The icon used to be a button of its own: a double click gave
        // it two clicks, and the second cancelled the download the first had started.
        .onTapGesture(count: 2) { Task { await model.open(document) } }
        .onTapGesture(count: 1) { primaryAction() }
        .contextMenu {
            Button("Открыть") { Task { await model.open(document) } }
            Button("Показать в Finder") { Task { await model.revealInFinder(document) } }
            Divider()
            Button("Сохранить в «Загрузки»") { Task { await model.saveToDownloads(document) } }
            Button("Сохранить как…") {
                guard let destination = Dialogs.saveLocation(suggestedName: document.name) else { return }
                Task { await model.save(document, to: destination) }
            }
        }
        .task(id: document.fileId) { await model.follow(document.fileId) }
    }

    @ViewBuilder
    private var progressOverlay: some View {
        let fraction = isUploading ? (transfer?.uploadFraction ?? 0) : (transfer?.downloadFraction ?? 0)
        if isUploading || isDownloading {
            ZStack {
                Circle().fill(.black.opacity(0.45))
                Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
        } else if !isDownloaded {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .background(Circle().fill(.white).padding(3))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 4, y: 4)
        }
    }

    private var status: String {
        let size = document.size
        if isUploading {
            return "Отправка: \(bytes(transfer?.uploaded ?? 0)) из \(bytes(size))"
        }
        if isDownloading {
            return "\(bytes(transfer?.downloaded ?? 0)) из \(bytes(size))"
        }
        var parts: [String] = []
        if size > 0 { parts.append(bytes(size)) }
        if document.duration > 0 {
            parts.append(Duration.seconds(document.duration).formatted(.time(pattern: .minuteSecond)))
        }
        if !document.fileExtension.isEmpty { parts.append(document.fileExtension.uppercased()) }
        if isDownloaded { parts.append("скачан") }
        return parts.joined(separator: " · ")
    }

    private var primaryHelp: String {
        if isUploading { return "Отменить отправку" }
        if isDownloading { return "Остановить загрузку" }
        return isDownloaded ? "Открыть" : "Скачать"
    }

    private func primaryAction() {
        Task {
            if isUploading || isDownloading {
                await model.cancelTransfer(of: message, fileId: document.fileId)
            } else if isDownloaded {
                await model.open(document)
            } else {
                await model.download(document.fileId)
            }
        }
    }
}

/// The icon Finder shows for this kind of file; the file's own preview once it is on disk.
struct FileIcon: View {
    let name: String
    var path: String?
    let side: CGFloat

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
    }

    private var icon: NSImage {
        // Every redraw of every visible row used to ask AppKit for the image again, and it builds a fresh one
        // each time. The answer only depends on the file (or its kind once the file is gone).
        let onDisk = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let kind = (name as NSString).pathExtension.lowercased()
        let key = (onDisk ? path! : "kind:" + kind) as NSString
        if let cached = Self.icons.object(forKey: key) { return cached }
        let image = onDisk ? NSWorkspace.shared.icon(forFile: key as String)
                           : NSWorkspace.shared.icon(for: UTType(filenameExtension: kind) ?? .data)
        Self.icons.setObject(image, forKey: key)
        return image
    }

    private static let icons = NSCache<NSString, NSImage>()
}

/// Files waiting to go: a caption, "as files" for photos and videos, and a last look before sending.
struct SendFilesSheet: View {
    @Environment(AppModel.self) private var model
    @State private var caption = ""
    @State private var asDocuments = false

    private var files: [URL] { model.pendingFiles ?? [] }
    private var hasMedia: Bool {
        files.contains { ["jpg", "jpeg", "png", "webp", "heic", "gif", "mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(files.count == 1 ? "Отправить файл" : "Отправить \(TD.count(files.count, "файл", "файла", "файлов"))")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(files, id: \.self) { file in
                        row(file)
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Подпись", text: $caption, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if hasMedia {
                    Toggle("Отправить фото и видео как файлы, без сжатия", isOn: $asDocuments)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
            }
            .padding(14)

            HStack {
                Button("Добавить…") { model.offerFiles(Dialogs.chooseFiles()) }
                Spacer()
                Button("Отмена", role: .cancel) { model.pendingFiles = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Отправить") { send() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 460)
    }

    private func row(_ file: URL) -> some View {
        HStack(spacing: 10) {
            FilePreview(url: file)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(size(of: file))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.pendingFiles?.removeAll { $0 == file }
                if model.pendingFiles?.isEmpty == true { model.pendingFiles = nil }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Убрать")
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func size(of file: URL) -> String {
        let value = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return bytes(Int64(value))
    }

    private func send() {
        let chosen = files
        let text = caption
        let plain = asDocuments
        model.pendingFiles = nil
        Task { await model.sendFiles(chosen, asDocuments: plain, caption: text) }
    }
}

/// A picture's own thumbnail, or the Finder icon for anything else.
private struct FilePreview: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                FileIcon(name: url.lastPathComponent, path: url.path, side: 40)
            }
        }
        .task(id: url) {
            guard ["jpg", "jpeg", "png", "webp", "heic", "gif"].contains(url.pathExtension.lowercased()) else { return }
            thumbnail = await MediaCache.image(atPath: url.path, pixels: 96)
        }
    }
}

/// A place a message points at. A click opens it in Maps; Telegram sends no picture of the place itself.
struct LocationCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.bubbleAccent) private var accent
    let location: LocationInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !location.title.isEmpty {
                Text(location.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }
            if !location.address.isEmpty {
                Text(location.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 5) {
                Image(systemName: location.expiresAt == nil ? "mappin.circle.fill" : "location.circle.fill")
                    .font(.body)
                Text(coordinates)
                    .font(.subheadline.monospacedDigit())
                if let expiresAt = location.expiresAt {
                    Text("до \(expiresAt.timeStamp)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(accent)
        }
        .padding(10)
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if let url = mapsURL { openURL(url) } }
        .help("Открыть в Картах")
    }

    private var coordinates: String {
        String(format: "%.5f, %.5f", location.latitude, location.longitude)
    }

    /// Built from the numbers alone, so the address of the place cannot carry a host of its own.
    private var mapsURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [
            URLQueryItem(name: "ll", value: String(format: "%.6f,%.6f", location.latitude, location.longitude)),
            URLQueryItem(name: "q", value: location.title.isEmpty ? coordinates : location.title),
        ]
        return components.url
    }
}

/// A phone number someone shared, with the account behind it when the sender's contact book knows one.
struct ContactCard: View {
    @Environment(AppModel.self) private var model
    let contact: ContactInfo

    var body: some View {
        HStack(spacing: 11) {
            Avatar(title: contact.name, seed: seed, photo: contact.userId == 0 ? nil : model.photo(ofUser: contact.userId),
                   diameter: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(contact.phone)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { share() }
        .contextMenu {
            Button("Скопировать номер", systemImage: "doc.on.doc") { share() }
            if contact.userId != 0 {
                Button("Открыть профиль", systemImage: "person.crop.circle") {
                    Task { await model.showProfile(ofUser: contact.userId) }
                }
            }
        }
    }

    /// The tint must not change between launches, so the seed is a sum of the number's bytes: `hashValue`
    /// is randomized per process.
    private var seed: Int64 {
        contact.userId != 0 ? contact.userId : contact.phone.utf8.reduce(0) { $0 + Int64($1) }
    }

    private func share() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(contact.phone, forType: .string)
    }
}

/// The throw itself, drawn big the way Telegram draws it, with what it landed on.
struct DiceView: View {
    let dice: Dice

    var body: some View {
        VStack(spacing: 0) {
            Text(dice.emoji)
                .font(.system(size: 44))
            Text("Выпало: \(dice.value)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 80)
    }
}
