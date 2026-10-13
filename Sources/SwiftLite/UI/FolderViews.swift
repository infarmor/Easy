import SwiftUI

/// The account's chat folders: their order, and the way to make, change or remove one.
struct FoldersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The folder being edited, with its id; nil id for a new one.
    @State private var editing: EditedFolder?

    struct EditedFolder: Identifiable {
        let id = UUID()
        let folderId: Int?
        let draft: FolderDraft
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.chatFolders) { folder in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(folder.title.isEmpty ? L("Без названия") : folder.title)
                            Spacer()
                            Button(L("Изменить")) { edit(folder.id) }
                            Button(role: .destructive) {
                                remove(folder)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help(L("Удалить папку"))
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in
                        var ids = model.chatFolders.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        Task { await model.reorderFolders(ids) }
                    }
                } header: {
                    Text(L("Папки"))
                } footer: {
                    Text(L("Порядок меняется перетаскиванием. Папки — общие для всех устройств этого аккаунта."))
                }
            }
            .overlay {
                if model.chatFolders.isEmpty {
                    Text(L("Папок пока нет"))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .motion(Motion.standard, value: model.chatFolders)
            HStack {
                Button(L("Новая папка…")) { editing = EditedFolder(folderId: nil, draft: FolderDraft()) }
                Spacer()
                Button(L("Готово")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 420)
        .sheet(item: $editing) { edited in
            FolderEditor(folderId: edited.folderId, draft: edited.draft)
                .environment(model)
        }
    }

    private func edit(_ id: Int) {
        Task {
            guard let draft = await model.loadFolder(id) else { return }
            editing = EditedFolder(folderId: id, draft: draft)
        }
    }

    private func remove(_ folder: ChatFolder) {
        guard Dialogs.confirm(L("Удалить папку «\(folder.title)»?"),
                              message: L("Чаты из неё останутся в списке, удалится только папка."),
                              action: L("Удалить")) else { return }
        Task { await model.deleteFolder(folder.id) }
    }
}

/// One folder: its name, the kinds of chats it takes in, and the chats put in or kept out by hand.
private struct FolderEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folderId: Int?
    @State private var draft: FolderDraft
    @State private var picking: PickedList?
    @State private var isSaving = false

    enum PickedList: String, Identifiable {
        case included, excluded
        var id: String { rawValue }
    }

    init(folderId: Int?, draft: FolderDraft) {
        self.folderId = folderId
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("Название"), text: $draft.name, prompt: Text(L("до 12 символов")))
                        .onChange(of: draft.name) { _, name in
                            if name.count > FolderDraft.maxNameLength { draft.name = String(name.prefix(FolderDraft.maxNameLength)) }
                        }
                    Picker(L("Значок"), selection: $draft.icon) {
                        ForEach(FolderDraft.icons, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    Toggle(L("Контакты"), isOn: $draft.includeContacts)
                    Toggle(L("Не контакты"), isOn: $draft.includeNonContacts)
                    Toggle(L("Группы"), isOn: $draft.includeGroups)
                    Toggle(L("Каналы"), isOn: $draft.includeChannels)
                    Toggle(L("Боты"), isOn: $draft.includeBots)
                } header: {
                    Text(L("Включать все"))
                }
                Section {
                    Toggle(L("Без уведомлений"), isOn: $draft.excludeMuted)
                    Toggle(L("Прочитанные"), isOn: $draft.excludeRead)
                    Toggle(L("Из архива"), isOn: $draft.excludeArchived)
                } header: {
                    Text(L("Не показывать"))
                }
                chatSection(L("Добавленные чаты"), ids: draft.chosenChats, list: .included)
                chatSection(L("Исключённые чаты"), ids: draft.excluded, list: .excluded)
            }
            .formStyle(.grouped)
            .motion(Motion.standard, value: draft.chosenChats)
            .motion(Motion.standard, value: draft.excluded)
            HStack {
                if !draft.isValid {
                    Text(L("Нужны название и хотя бы один чат или тип чатов"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                Button(L("Отмена")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(folderId == nil ? L("Создать") : L("Сохранить")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid || isSaving)
            }
            .padding(16)
            .motion(Motion.standard, value: draft.isValid)
        }
        .frame(width: 480, height: 600)
        .sheet(item: $picking) { list in
            ChatPicker(chosen: list == .included ? Set(draft.chosenChats) : Set(draft.excluded)) { chatId, isOn in
                switch (list, isOn) {
                case (.included, true): draft.include(chatId)
                case (.excluded, true): draft.exclude(chatId)
                case (_, false): draft.forget(chatId)
                }
            }
            .environment(model)
        }
    }

    private func chatSection(_ title: String, ids: [Int64], list: PickedList) -> some View {
        Section {
            ForEach(ids, id: \.self) { chatId in
                HStack {
                    Text(model.chat(withId: chatId)?.title ?? L("Чат \(String(chatId))"))
                        .lineLimit(1)
                    if draft.pinned.contains(chatId) {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        draft.forget(chatId)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Убрать"))
                }
            }
            Button(L("Выбрать чаты…")) { picking = list }
        } header: {
            Text(title)
        }
    }

    private func save() {
        isSaving = true
        Task {
            let done = await model.saveFolder(draft, id: folderId)
            isSaving = false
            if done { dismiss() }
        }
    }
}

/// The account's chats with a search field; a click puts a chat on the list or takes it off.
private struct ChatPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var chosen: Set<Int64>
    let onToggle: (Int64, Bool) -> Void
    @State private var query = ""

    private var shown: [Chat] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.chats.filter { needle.isEmpty || $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(L("Поиск"), text: $query, prompt: Text(L("Поиск")))
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List(shown) { chat in
                Button {
                    let isOn = !chosen.contains(chat.id)
                    if isOn { chosen.insert(chat.id) } else { chosen.remove(chat.id) }
                    onToggle(chat.id, isOn)
                } label: {
                    HStack {
                        Text(chat.title.isEmpty ? L("Без названия") : chat.title)
                            .lineLimit(1)
                        Spacer()
                        if chosen.contains(chat.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.brand)
                                .transition(.pop)
                        }
                    }
                    .contentShape(Rectangle())
                    .motion(Motion.lively, value: chosen.contains(chat.id))
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button(L("Готово")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 380, height: 480)
    }
}
