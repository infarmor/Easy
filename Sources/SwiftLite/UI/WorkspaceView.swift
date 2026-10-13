import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return NavigationSplitView(sidebar: {
            ChatListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
        }, detail: {
            HStack(spacing: 0) {
                Group {
                    if let chat = model.selectedChat {
                        ConversationView(chat: chat)
                            // The same person is the same chat id in two accounts; the account is part of it.
                            .id(model.slot + ":" + String(chat.id))
                            .transition(.opacity)
                    } else {
                        // The wallpaper belongs to a conversation; with none open the window shows its glass.
                        EmptyDetailView().background(WindowGlass())
                            .transition(.opacity)
                    }
                }
                // One conversation gives way to the next instead of being cut to it.
                .animation(.easeOut(duration: 0.16), value: model.selectedChat?.id)
                if model.showsMembersColumn, let chat = model.selectedChat {
                    Divider()
                    MembersPanel(chat: chat)
                        .id(model.slot + ":" + String(chat.id))
                }
            }
        })
        .sheet(item: $model.inspectedCode) { code in
            CodeSheet(code: code)
                .environment(model)
        }
        .sheet(item: $model.profile) { info in
            ProfileSheet(info: info)
                .environment(model)
        }
        .sheet(isPresented: $model.showsNewChat) {
            NewChatSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showsCreateChat) {
            CreateChatSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showsDownloads) {
            DownloadsSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showsFolders) {
            FoldersSheet()
                .environment(model)
        }
        .sheet(item: $model.mediaGallery) { scope in
            MediaGallerySheet(scope: scope)
                .environment(model)
        }
        .sheet(item: $model.storyViewer) { target in
            StoryViewer(chatId: target.id, name: target.name)
                .environment(model)
        }
        .sheet(isPresented: Binding(get: { model.storyDraft != nil }, set: { if !$0 { model.storyDraft = nil } })) {
            if let file = model.storyDraft {
                StoryPostSheet(file: file)
                    .environment(model)
            }
        }
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 4) {
                Text("Easy")
                    .font(.system(size: 22, weight: .semibold))
                Text(L("Выберите чат слева"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                shortcut("⌘K", L("найти чат, человека или канал"))
                shortcut("⌥⌘↑ ↓", L("предыдущий и следующий чат"))
                shortcut("⌃⇧↑ ↓", L("к чату с непрочитанным"))
                shortcut("⌘F", L("поиск в чате"))
                shortcut("⌘I", L("профиль собеседника"))
                shortcut("⌥⌘M", L("список участников в группе"))
                shortcut("⌘⇧V", L("отправить из буфера"))
                shortcut("⌘⇧G", L("режим призрака"))
            }
            .padding(14)
            .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(size: 12, weight: .medium).monospaced())
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(action)
                .font(.callout)
        }
    }
}

/// Three dots taking turns, like the typing bubble in Messages. Only rows where someone is typing draw it.
struct TypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 4, height: 4)
                        .opacity(index == phase ? 1 : 0.35)
                }
            }
            .animation(.smooth(duration: 0.25), value: phase)
        }
        .accessibilityHidden(true)
    }
}

/// "Новый чат": your contacts, narrowed as you type; Return opens the first, a click opens any.
struct NewChatSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var people: [AppModel.Contact] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            TextField(L("Кому"), text: $query, prompt: Text(L("Имя или @username")))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let first = people.first { open(first) } }
                .padding(12)
            List(people) { person in
                Button {
                    open(person)
                } label: {
                    HStack(spacing: 10) {
                        Avatar(title: person.name, seed: person.id, photo: person.photo, diameter: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.name.isEmpty ? L("Без имени") : person.name)
                                .font(.body)
                                .lineLimit(1)
                            Text([person.username.isEmpty ? "" : "@" + person.username, person.status]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if people.isEmpty {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        ContentUnavailableView(query.isEmpty ? L("Контактов нет") : L("Никого не нашлось"), systemImage: "person.crop.circle.badge.questionmark",
                                               description: Text(L("Человека не из контактов можно найти через поиск в боковой панели")))
                    }
                }
            }
            Divider()
            HStack {
                Button(L("Избранное")) {
                    dismiss()
                    Task { await model.openSavedMessages() }
                }
                Button(L("Группа, канал или контакт…")) {
                    dismiss()
                    // A second sheet can only come up once this one has finished going away.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        model.showsCreateChat = true
                    }
                }
                Spacer()
                Button(L("Отмена")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 380, height: 480)
        .onAppear { focused = true }
        .task(id: query) {
            // A name is typed in a burst; only the pause after it is worth a request.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let found = await model.contacts(matching: query)
            guard !Task.isCancelled else { return }
            people = found
            isLoading = false
        }
    }

    private func open(_ person: AppModel.Contact) {
        dismiss()
        model.wantsComposerFocus = true
        Task { await model.openPrivateChat(with: person.id) }
    }
}
