import AVKit
import SwiftUI

/// People and channels with stories up, under the search field: your own first, then the unwatched. A row
/// that shows what fits and keeps the rest in a menu — a scroll view here would grow a scroll bar on Macs
/// set to always show them.
struct StoriesRow: View {
    @Environment(AppModel.self) private var model

    private static let shown = 5

    var body: some View {
        let chats = model.storyChats.compactMap { story in model.chat(withId: story.id).map { (story, $0) } }
        HStack(spacing: 10) {
            Button {
                pickStory()
            } label: {
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                }
                .frame(width: 40, height: 40)
                .contentShape(Circle())
            }
            .buttonStyle(PressDimStyle())
            .help(L("Опубликовать историю"))
            .accessibilityLabel(L("Опубликовать историю"))
            ForEach(chats.prefix(Self.shown), id: \.0.id) { story, chat in
                Button {
                    model.storyViewer = AppModel.StoryTarget(id: chat.id, name: chat.title)
                } label: {
                    Avatar(title: chat.title, seed: chat.id, photo: chat.photo, diameter: 34)
                        .padding(3)
                        .overlay(Circle().strokeBorder(story.hasUnseen ? Color.white : Color.white.opacity(0.25), lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(PressDimStyle())
                .help(chat.id == model.myId ? L("Моя история") : chat.title)
                .accessibilityLabel(L("Истории: \(chat.title)"))
            }
            if chats.count > Self.shown {
                Menu {
                    ForEach(chats.dropFirst(Self.shown), id: \.0.id) { _, chat in
                        Button(chat.title.isEmpty ? L("Без названия") : chat.title) {
                            model.storyViewer = AppModel.StoryTarget(id: chat.id, name: chat.title)
                        }
                    }
                } label: {
                    Text("+\(chats.count - Self.shown)")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Остальные истории"))
            }
            Spacer(minLength: 0)
        }
        .motion(.smooth(duration: 0.25), value: model.storyChats)
    }

    private func pickStory() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = L("Фото или видео для истории")
        guard panel.runModal() == .OK, let file = panel.url else { return }
        model.storyDraft = file
    }
}

/// The last step before a story goes up: what it is, a caption, and who may see it.
struct StoryPostSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: URL

    @State private var caption = ""
    @State private var audience = AppModel.StoryAudience.everyone
    @State private var isPosting = false
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image = NSImage(contentsOf: file) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "film").font(.system(size: 40))
                        Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.85))
            VStack(alignment: .leading, spacing: 10) {
                TextField(L("Подпись"), text: $caption, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Picker(L("Кто увидит"), selection: $audience) {
                    Text(L("Все")).tag(AppModel.StoryAudience.everyone)
                    Text(L("Мои контакты")).tag(AppModel.StoryAudience.contacts)
                }
                Text(L("История видна сутки. Лучше всего выглядит вертикальный кадр 9:16."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L("Отмена")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(isPosting ? L("Публикация…") : L("Опубликовать")) { post() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brand)
                        .disabled(isPosting)
                }
            }
            .padding(14)
        }
        .frame(width: 400, height: 620)
    }

    private func post() {
        isPosting = true
        error = ""
        Task {
            let problem = await model.postStory(file: file, caption: caption, audience: audience)
            isPosting = false
            if let problem {
                error = problem
            } else {
                model.showToast(L("История опубликована"))
                dismiss()
            }
        }
    }
}

/// Photos and videos as a grid: of one chat, or of every chat this account has. A click goes to the message.
struct MediaGallerySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: AppModel.MediaScope

    @State private var items: [Message] = []
    @State private var isLoading = true
    /// Where the next page starts; nil once there is nothing older.
    @State private var nextMessage: Int64?
    @State private var nextOffset: String?

    private static let cell: CGFloat = 132

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                if !items.isEmpty {
                    Text(L("\(items.count) шт."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell), spacing: 3)], spacing: 3) {
                    ForEach(items, id: \.viewKey) { message in
                        if let media = message.media {
                            Poster(media: media, size: CGSize(width: Self.cell, height: Self.cell),
                                   fileId: media.previewFileId ?? media.fileId)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { model.showFromGallery(message) }
                                .help(caption(of: message))
                                // The last cell coming into view brings the next page.
                                .onAppear {
                                    if message.viewKey == items.last?.viewKey { Task { await load(more: true) } }
                                }
                        }
                    }
                }
                .padding(3)
                if isLoading {
                    ProgressView().controlSize(.small).padding(16)
                } else if items.isEmpty {
                    Text(L("Фото здесь пока нет"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Готово")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 600)
        .task { await load(more: false) }
    }

    private var title: String {
        switch scope {
        case .everywhere: L("Фото и видео из всех чатов")
        case .chat(_, let title): L("Медиа: \(title)")
        }
    }

    private func caption(of message: Message) -> String {
        let chat = model.chat(withId: message.chatId)?.title ?? ""
        return (chat.isEmpty ? "" : chat + " · ") + message.date.shortDate
    }

    private func load(more: Bool) async {
        if more {
            guard !isLoading, nextMessage != nil || nextOffset != nil else { return }
        }
        isLoading = true
        defer { isLoading = false }
        var page: [Message] = []
        switch scope {
        case .everywhere:
            guard let found = await model.mediaEverywhere(from: more ? (nextOffset ?? "") : "") else { return }
            page = found.messages
            nextOffset = found.next.isEmpty ? nil : found.next
        case .chat(let chatId, _):
            guard let found = await model.sharedMedia(.photos, in: chatId, from: more ? (nextMessage ?? 0) : 0) else { return }
            page = found.messages
            nextMessage = found.next == 0 ? nil : found.next
        }
        let known = Set(items.map(\.viewKey))
        items += page.filter { $0.media != nil && !known.contains($0.viewKey) }
    }
}

private extension Message {
    /// Message ids repeat between chats, and the gallery of all chats mixes them.
    var viewKey: String { "\(chatId):\(id)" }
}
