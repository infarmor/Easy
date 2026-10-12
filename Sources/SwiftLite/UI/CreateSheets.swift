import AVKit
import SwiftUI

/// A new group, a new channel, or a contact by phone number.
struct CreateChatSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Kind: Hashable { case group, channel, contact }

    @State private var kind = Kind.group
    @State private var title = ""
    @State private var about = ""
    @State private var phone = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var query = ""
    @State private var people: [AppModel.Contact] = []
    @State private var chosen: Set<Int64> = []
    @State private var isWorking = false
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $kind) {
                Text(L("Группа")).tag(Kind.group)
                Text(L("Канал")).tag(Kind.channel)
                Text(L("Контакт")).tag(Kind.contact)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Form {
                switch kind {
                case .group:
                    TextField(L("Название"), text: $title)
                    Section(L("Кого добавить")) {
                        TextField(L("Поиск по имени"), text: $query)
                        if people.isEmpty {
                            Text(L("Контактов нет")).foregroundStyle(.secondary)
                        }
                        ForEach(people.filter { $0.status != L("бот") || chosen.contains($0.id) }) { person in
                            Toggle(isOn: Binding(
                                get: { chosen.contains(person.id) },
                                set: { if $0 { chosen.insert(person.id) } else { chosen.remove(person.id) } })) {
                                HStack(spacing: 8) {
                                    Avatar(title: person.name, seed: person.id, photo: person.photo, diameter: 24)
                                    Text(person.name.isEmpty ? L("Без имени") : person.name).lineLimit(1)
                                }
                            }
                        }
                    }
                case .channel:
                    TextField(L("Название"), text: $title)
                    TextField(L("Описание"), text: $about, axis: .vertical)
                        .lineLimit(2...4)
                case .contact:
                    TextField(L("Номер телефона"), text: $phone, prompt: Text(verbatim: "+79991234567"))
                    TextField(L("Имя"), text: $firstName)
                    TextField(L("Фамилия"), text: $lastName)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button(L("Отмена")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(kind == .contact ? L("Добавить") : L("Создать")) { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brand)
                    .disabled(isWorking)
            }
            .padding(12)
        }
        .frame(width: 420, height: 520)
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            people = await model.contacts(matching: query)
        }
    }

    private func create() {
        isWorking = true
        error = ""
        Task {
            let problem: String?
            switch kind {
            case .group: problem = await model.createGroup(title: title, members: Array(chosen))
            case .channel: problem = await model.createChannel(title: title, about: about)
            case .contact: problem = await model.addContact(phone: phone, firstName: firstName, lastName: lastName)
            }
            isWorking = false
            if let problem { error = problem } else { dismiss() }
        }
    }
}

/// The files this account has downloaded: found by name, opened, or shown in Finder.
struct DownloadsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var files: [AppModel.DownloadedFile]?
    @State private var kind: AppModel.DownloadedFile.Kind?
    @State private var query = ""

    private var shown: [AppModel.DownloadedFile] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return (files ?? []).filter { (kind == nil || $0.kind == kind) && (needle.isEmpty || $0.name.lowercased().contains(needle)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $kind) {
                    Text(L("Все")).tag(AppModel.DownloadedFile.Kind?.none)
                    Text(L("Файлы")).tag(AppModel.DownloadedFile.Kind?.some(.documents))
                    Text(L("Фото")).tag(AppModel.DownloadedFile.Kind?.some(.photos))
                    Text(L("Видео")).tag(AppModel.DownloadedFile.Kind?.some(.videos))
                    Text(L("Аудио")).tag(AppModel.DownloadedFile.Kind?.some(.music))
                    Text(L("Голосовые")).tag(AppModel.DownloadedFile.Kind?.some(.voice))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField(L("Поиск по имени"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            .padding(12)
            List(shown.prefix(500)) { file in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file) + " · " + file.date.chatListStamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(L("Открыть")) { model.openDownloaded(file) }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help(L("Показать в Finder"))
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if files == nil {
                    ProgressView().controlSize(.small)
                } else if shown.isEmpty {
                    ContentUnavailableView(L("Пусто"), systemImage: "tray", description: Text(L("Скачанных файлов нет")))
                }
            }
            Divider()
            HStack {
                if let files {
                    let size = ByteCountFormatter.string(fromByteCount: Int64(files.reduce(0) { $0 + $1.size }), countStyle: .file)
                    Text(L("Файлов: \(files.count) · \(size)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Готово")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 520)
        .task { files = await model.downloadedFiles() }
    }
}

/// Someone's stories, one at a time: the picture or the video, its caption, and a field to answer.
struct StoryViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    let name: String

    @State private var stories: [AppModel.StoryItem]?
    @State private var index = 0
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var answer = ""
    @State private var isLoading = false

    private var story: AppModel.StoryItem? {
        guard let stories, stories.indices.contains(index) else { return nil }
        return stories[index]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name.isEmpty ? L("История") : name).font(.headline).lineLimit(1)
                    if let story, let stories {
                        Text("\(index + 1) / \(stories.count) · " + story.date.chatListStamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    step(-1)
                } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button {
                    step(1)
                } label: { Image(systemName: "chevron.right") }
                    .disabled(index + 1 >= (stories?.count ?? 0))
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .padding(12)
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .id(story?.id)
                        .transition(.opacity)
                } else if stories?.isEmpty == true {
                    Text(L("Сейчас историй нет")).foregroundStyle(.white.opacity(0.7))
                } else if isLoading || stories == nil {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text(L("Эту историю здесь показать нельзя")).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.25), value: image)
            if let story, !story.caption.isEmpty {
                Text(story.caption)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            HStack {
                if let story, story.canBeReplied, chatId > 0 {
                    TextField(L("Ответить на историю"), text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send(story) }
                    Button(L("Отправить")) { send(story) }
                        .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Spacer()
                }
                Button(L("Готово")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 680)
        .task {
            stories = await model.activeStories(of: chatId)
            await show()
        }
        .onDisappear { player?.pause() }
    }

    private func step(_ by: Int) {
        guard let stories, stories.indices.contains(index + by) else { return }
        index += by
        Task { await show() }
    }

    private func show() async {
        player?.pause()
        player = nil
        image = nil
        guard let story else { return }
        let shown = story.id
        isLoading = true
        defer { if self.story?.id == shown { isLoading = false } }
        if let fileId = story.videoFileId, let path = await model.localFile(id: fileId, priority: 32) {
            guard self.story?.id == shown else { return }
            let video = AVPlayer(url: URL(fileURLWithPath: path))
            player = video
            video.play()
        } else if let fileId = story.photoFileId, let path = await model.localFile(id: fileId, priority: 32) {
            guard self.story?.id == shown else { return }
            image = NSImage(contentsOfFile: path)
        }
        if self.story?.id == shown, player != nil || image != nil { model.noteStoryOpened(story) }
    }

    private func send(_ story: AppModel.StoryItem) {
        let text = answer
        answer = ""
        Task {
            if await model.reply(to: story, text: text) { model.showToast(L("Ответ отправлен")) } else { answer = text }
        }
    }
}
