import AppKit
import SwiftUI

// MARK: - stickers

/// Recent stickers and your installed sets. Cells show still previews: dozens of Lottie animations playing at
/// once in a popover would cost more than they are worth.
struct StickerPanel: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @State private var recent: [Sticker] = []
    @State private var sets: [StickerSetSummary] = []
    /// nil shows the recent ones.
    @State private var selectedSet: Int64?
    @State private var setStickers: [Sticker] = []

    private var shown: [Sticker] { selectedSet == nil ? recent : setStickers }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if shown.isEmpty {
                    Text(selectedSet == nil ? "Здесь появятся стикеры, которые вы отправляли" : "Загрузка…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 6), count: 5), spacing: 6) {
                        ForEach(shown, id: \.fileId) { sticker in
                            Button {
                                done()
                                Task { await model.send(sticker) }
                            } label: {
                                StickerThumb(sticker: sticker, side: 64)
                            }
                            .buttonStyle(.plain)
                            .help(sticker.emoji)
                        }
                    }
                    .padding(10)
                }
            }
            .frame(height: 300)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    tab(isSelected: selectedSet == nil, help: "Недавние") {
                        Image(systemName: "clock").font(.title3).foregroundStyle(.secondary)
                    } action: { selectedSet = nil }
                    ForEach(sets) { set in
                        tab(isSelected: selectedSet == set.id, help: set.title) {
                            if let cover = set.cover {
                                StickerThumb(sticker: cover, side: 26)
                            } else {
                                Text(String(set.title.prefix(1))).font(.body.weight(.semibold))
                            }
                        } action: { selectedSet = set.id }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 376)
        .task {
            recent = await model.recentStickers()
            sets = await model.installedStickerSets()
            if recent.isEmpty, let first = sets.first { selectedSet = first.id }
        }
        .task(id: selectedSet) {
            guard let id = selectedSet else { return }
            setStickers = []
            let loaded = await model.stickers(inSet: id)
            // Switching tabs cancels this task: without the check a slow answer paints the set you left
            // under the tab you are on now.
            guard !Task.isCancelled else { return }
            setStickers = loaded
        }
    }

    private func tab<Label: View>(isSelected: Bool, help: String, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .frame(width: 34, height: 34)
                .background(isSelected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A sticker's still picture: the WebP itself, or the preview TDLib has for animated and video stickers.
struct StickerThumb: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let sticker: Sticker
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Text(sticker.emoji)
                    .font(.system(size: side * 0.5))
                    .opacity(0.35)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .task(id: sticker.fileId) {
            let pixels = Int(side * displayScale)
            let fileId = sticker.format == .webp ? sticker.fileId : (sticker.thumbnailFileId ?? sticker.fileId)
            guard sticker.format == .webp || sticker.thumbnailFileId != nil,
                  let path = await model.localFile(id: fileId, priority: 8) else { return }
            image = await MediaCache.image(atPath: path, pixels: pixels)
        }
    }
}

// MARK: - sending later

struct ScheduleSendPicker: View {
    let send: (Date) -> Void
    @State private var date = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Отправить позже")
                .font(.body.weight(.semibold))
            DatePicker("", selection: $date, in: Date().addingTimeInterval(60)..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "ru_RU"))
            HStack {
                ForEach([("Через час", 3600.0), ("Завтра в 9:00", -1)], id: \.0) { title, offset in
                    Button(title) { send(offset > 0 ? Date().addingTimeInterval(offset) : Self.tomorrowMorning) }
                }
                Spacer()
                Button("Запланировать") { send(date) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private static var tomorrowMorning: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// Messages of the open chat waiting for their time, with "send now" and "delete".
struct ScheduledList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Отложенные")
                .font(.body.weight(.semibold))
                .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.scheduledMessages) { message in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.date.formatted(.dateTime.day().month(.wide).hour().minute().locale(Locale(identifier: "ru_RU"))))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                                Text(TD.preview(of: message))
                                    .font(.callout)
                                    .lineLimit(3)
                            }
                            Spacer(minLength: 8)
                            Button { Task { await model.sendNow(message) } } label: { Image(systemName: "paperplane") }
                                .help("Отправить сейчас")
                            Button { Task { await model.deleteScheduled(message) } } label: { Image(systemName: "trash") }
                                .help("Удалить")
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 320)
    }
}

// MARK: - shared media

/// Photos, files and links of a chat, in its profile: a click on any of them shows it in the conversation.
struct SharedMedia: View {
    @Environment(AppModel.self) private var model
    let chatId: Int64

    @State private var kind = SharedMediaKind.photos
    @State private var items: [Message] = []
    @State private var isLoading = true
    /// Where the next page starts; 0 once the history has nothing older of this kind.
    @State private var next: Int64 = 0

    private static let cell: CGFloat = 90

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $kind) {
                ForEach(SharedMediaKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if items.isEmpty {
                Group {
                    if isLoading { ProgressView().controlSize(.small) } else { Text(emptyLabel).foregroundStyle(.secondary) }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                switch kind {
                case .photos: grid
                case .files, .links: list
                }
                if next != 0 {
                    Button(isLoading ? "Загрузка…" : "Показать ещё") { Task { await load(more: true) } }
                        .buttonStyle(.link)
                        .disabled(isLoading)
                }
            }
        }
        .task(id: kind) { await load(more: false) }
    }

    private var emptyLabel: String {
        switch kind {
        case .photos: "Фото здесь пока нет"
        case .files: "Файлов здесь пока нет"
        case .links: "Ссылок здесь пока нет"
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: 3), count: 4), spacing: 3) {
            ForEach(items) { message in
                if let media = message.media {
                    Poster(media: media, size: CGSize(width: Self.cell, height: Self.cell),
                           fileId: media.previewFileId ?? media.fileId)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { model.showInChat(message) }
                        .help("Показать в чате · " + message.date.shortDate)
                }
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(items) { message in
                Button { model.showInChat(message) } label: {
                    HStack(spacing: 10) {
                        if let document = message.document {
                            FileIcon(name: document.name, path: nil, side: 30)
                        } else {
                            Image(systemName: "link")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(of: message))
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(detail(of: message))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
                .help("Показать в чате")
                if message.id != items.last?.id { Divider().padding(.leading, 50) }
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    /// The first address a message carries: the one its card previews, or the first link in its text.
    private func link(of message: Message) -> URL? {
        if let preview = message.linkPreview { return preview.url }
        for entity in message.entities {
            if case .link(let url) = entity.style { return url }
        }
        return nil
    }

    private func title(of message: Message) -> String {
        if let document = message.document { return document.trackTitle.isEmpty ? document.name : document.trackTitle }
        if let title = message.linkPreview?.title, !title.isEmpty { return title }
        return link(of: message)?.host() ?? TD.preview(of: message)
    }

    private func detail(of message: Message) -> String {
        let day = message.date.shortDate
        if let document = message.document {
            return document.size.formatted(.byteCount(style: .file).locale(Locale(identifier: "ru_RU"))) + " · " + day
        }
        return (link(of: message)?.absoluteString ?? "") + " · " + day
    }

    private func load(more: Bool) async {
        if !more { items = []; next = 0 }
        isLoading = true
        defer { isLoading = false }
        let shown = kind
        let page = await model.sharedMedia(shown, in: chatId, from: more ? next : 0)
        // The tab was switched while this page travelled: it belongs under the other one.
        guard !Task.isCancelled, shown == kind else { return }
        let known = Set(items.map(\.id))
        items += (page?.messages ?? []).filter { !known.contains($0.id) }
        next = page?.next ?? 0
    }
}

// MARK: - polls

/// A poll or quiz inside its bubble: tap an answer to vote; results with bars once you have voted.
struct PollView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.bubbleAccent) private var accent
    let message: Message
    let poll: Poll
    @State private var picked: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(poll.question)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(kindLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(poll.options.indices, id: \.self) { index in
                option(index)
            }
            HStack {
                Text(TD.count(poll.totalVoters, "голос", "голоса", "голосов"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if poll.allowsMultipleAnswers, !poll.showsResults, !picked.isEmpty {
                    Button("Проголосовать") {
                        let chosen = picked.sorted()
                        picked = []
                        Task { await model.vote(chosen, in: message) }
                    }
                    .controlSize(.small)
                } else if poll.hasVoted, !poll.isQuiz, !poll.isClosed {
                    Button("Отменить голос") { Task { await model.vote([], in: message) } }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .font(.subheadline)
                }
            }
            if poll.isQuiz, poll.hasVoted, !poll.explanation.isEmpty {
                Label(poll.explanation, systemImage: "lightbulb")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
    }

    private var kindLabel: String {
        var parts = [poll.isQuiz ? "Викторина" : "Опрос", poll.isAnonymous ? "анонимный" : "открытый"]
        if poll.allowsMultipleAnswers { parts.append("можно выбрать несколько") }
        if poll.isClosed { parts.append("завершён") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func option(_ index: Int) -> some View {
        let item = poll.options[index]
        if poll.showsResults {
            let isCorrect = poll.isQuiz && poll.correctOptions.contains(index)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(item.percentage)%")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .frame(width: 38, alignment: .leading)
                    Text(item.text).font(.callout)
                    if item.isChosen {
                        Image(systemName: poll.isQuiz && !isCorrect ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(poll.isQuiz && !isCorrect ? Color.red : accent)
                    }
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(isCorrect ? Color.green : accent)
                        .frame(width: max(4, proxy.size.width * CGFloat(item.percentage) / 100))
                }
                .frame(height: 4)
            }
        } else {
            Button {
                if poll.allowsMultipleAnswers {
                    if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
                } else {
                    Task { await model.vote([index], in: message) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: picked.contains(index) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked.contains(index) ? accent : .secondary)
                    Text(item.text)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(poll.isClosed)
        }
    }
}

// MARK: - mentions

/// "@" over the transcript while someone mentioned you in a message you have not seen.
struct MentionButton: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        Button {
            Task { await model.jumpToUnreadMention() }
        } label: {
            GlassCircleLabel {
                Text("@").font(.title3.weight(.semibold))
            }
                .overlay(alignment: .top) {
                    UnreadBadge(count: count, isMuted: false).offset(y: -10)
                }
        }
        .buttonStyle(.plain)
        .help("К непрочитанному упоминанию")
        .accessibilityLabel("К непрочитанному упоминанию")
    }
}

// MARK: - places

/// A point typed in by hand: a desktop window has no map to pick a place from, so the coordinates are what
/// the user has. The message arrives as a card that opens in Карты.
struct LocationPanel: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Геолокация")
                .font(.body.weight(.semibold))
            HStack {
                TextField("Широта", text: $latitude)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Широта")
                TextField("Долгота", text: $longitude)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Долгота")
            }
            Text("Например, 55.7558 и 37.6173")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отправить") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(point == nil)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// Both fields must read as numbers inside their ranges; a comma instead of a dot is the usual slip.
    private var point: (latitude: Double, longitude: Double)? {
        func number(_ text: String) -> Double? {
            Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        guard let latitude = number(latitude), let longitude = number(longitude),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return (latitude, longitude)
    }

    private func send() {
        guard let point else { return }
        done()
        Task { await model.sendLocation(latitude: point.latitude, longitude: point.longitude) }
    }
}
