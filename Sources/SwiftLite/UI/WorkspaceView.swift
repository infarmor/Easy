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
                            .id(chat.id)
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
                        .id(chat.id)
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
    }
}

/// The sidebar: the folder on screen, search, that folder's chats, and the account at its foot.
/// Not private, so the harness can draw it alone — inside a split view its bottom inset cannot be inspected.
struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.showMessageCode) private var showsCode = false
    @AppStorage(Preferences.showIdentifiers) private var showsIdentifiers = false
    @AppStorage(Preferences.ghostMode) private var isGhost = false

    var body: some View {
        @Bindable var model = model
        // Computed once per redraw: while searching it filters and sorts every known chat.
        let visible = model.visibleChats
        // The order of what is on screen, for the animation below: a chat with a new message rises to the top
        // rather than the rows being swapped under the eye. Not while the list is still filling at launch,
        // when hundreds of rows arrive at once and would all be sent sliding.
        let order = model.animatesChatList ? visible.prefix(40).map(\.id) : []
        return List(selection: $model.selection) {
            if !model.filter.isEmpty {
                if !visible.isEmpty {
                    Section { rows(visible) } header: { SectionHeading(title: "Чаты") }
                }
                let found = model.foundPublicChats.compactMap { model.chat(withId: $0) }
                if !found.isEmpty {
                    Section {
                        ForEach(found) { chat in
                            ChatRow(chat: chat, showsDraft: false)
                                .tag(chat.id)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        SectionHeading(title: "Глобальный поиск", systemImage: "globe")
                    }
                }
                if !model.foundMessages.isEmpty {
                    Section {
                        ForEach(model.foundMessages) { message in
                            FoundMessageRow(message: message)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        SectionHeading(title: "Сообщения", systemImage: "text.magnifyingglass")
                    }
                }
            } else if model.showsArchive {
                Section { rows(visible) } header: { SectionHeading(title: "Архив", systemImage: "archivebox.fill") }
            } else if visible.contains(where: \.isPinned) {
                // Pinned chats keep their place at the top and get a header, so the split is obvious at a
                // glance. Without any pinned chat no header is drawn: one would only repeat the list.
                Section { rows(visible.filter(\.isPinned)) } header: {
                    // No pin glyph here: every row under this header already carries one.
                    SectionHeading(title: "Закреплённые")
                }
                Section { rows(visible.filter { !$0.isPinned }) } header: { SectionHeading(title: "Чаты") }
            } else {
                rows(visible)
            }
        }
        .animation(.smooth(duration: 0.3), value: order)
        .overlay {
            if visible.isEmpty && model.foundMessages.isEmpty && model.foundPublicChats.isEmpty {
                ContentUnavailableView(
                    "Пусто",
                    systemImage: "text.bubble",
                    description: Text(model.filter.isEmpty
                        ? "Дождитесь синхронизации или нажмите ⌘⇧R"
                        : "Ничего не найдено")
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The header counts what is on screen, so it is handed the list the rows were built from rather
            // than recomputing it: while searching, `model.chats` is still the whole place.
            SidebarHeader(shownChats: visible.count)
        }
        .toolbar {
            // Where Messages keeps "compose": a new chat with someone from your contacts.
            ToolbarItem {
                Button {
                    model.showsNewChat = true
                } label: {
                    Label("Новый чат", systemImage: "square.and.pencil")
                }
                .help("Новый чат (⌘N)")
            }
            ToolbarItem {
                Button {
                    Task { await model.loadChats() }
                } label: {
                    Label("Синхронизировать", systemImage: "arrow.clockwise")
                }
                .help("Синхронизировать чаты (⇧⌘R)")
            }
            ToolbarItem {
                Button {
                    isGhost.toggle()
                } label: {
                    Label("Режим призрака", systemImage: isGhost ? "eye.slash.fill" : "eye")
                }
                .help(isGhost
                    ? "Режим призрака включён: вы не в сети, не печатаете и ничего не читаете"
                    : "Включить режим призрака")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                ErrorBanner()
                // The account, like the user card at the bottom of Apple's sidebars.
                HStack(spacing: 9) {
                    Button {
                        Task { await model.showMyProfile() }
                    } label: {
                        HStack(spacing: 9) {
                            Avatar(title: model.accountName, seed: model.myId, photo: model.myPhoto, diameter: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.accountName.isEmpty ? "—" : model.accountName)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Text(isGhost ? "призрак · не в сети" : TD.count(model.chats.count, "чат", "чата", "чатов"))
                                    .font(.subheadline)
                                    .foregroundStyle(isGhost ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Мой профиль")
                    Spacer(minLength: 4)
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDimStyle())
                    .help("Настройки (⌘,)")
                    .accessibilityLabel("Настройки")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    /// Clear, block, delete or leave: the things you do to a whole chat.
    @ViewBuilder
    private func chatActions(_ chat: Chat) -> some View {
        let isPrivate = chat.kind == .personal || chat.kind == .secret
        Button("Очистить историю…", systemImage: "eraser") {
            let canRevoke = isPrivate && chat.userId != 0 && !chat.isBot
            guard let answer = Dialogs.confirm("Очистить историю «\(chat.title)»?",
                                               message: "Сообщения пропадут из этого чата.", action: "Очистить",
                                               option: canRevoke ? "Также у собеседника" : nil) else { return }
            Task { await model.clearHistory(of: chat, forEveryone: answer) }
        }
        if isPrivate, chat.userId != 0 {
            Button(chat.isBot ? "Остановить и заблокировать бота" : "Заблокировать", systemImage: "hand.raised") {
                guard Dialogs.confirm("Заблокировать \(chat.title)?", message: "Он не сможет писать вам и звонить.", action: "Заблокировать") else { return }
                Task { _ = await model.setBlocked(true, userId: chat.userId) }
            }
            Button("Удалить чат…", systemImage: "trash", role: .destructive) {
                guard let answer = Dialogs.confirm("Удалить чат с \(chat.title)?", message: "Чат исчезнет из списка вместе с историей.",
                                                   action: "Удалить", option: chat.isBot ? nil : "Также у собеседника") else { return }
                Task { await model.deleteChat(chat, forEveryone: answer) }
            }
        } else {
            if chat.kind == .group || chat.kind == .channel, !chat.groupKey.hasPrefix("b") {
                Button("Управление чатом…", systemImage: "person.2.circle") {
                    // Managing opens the chat as well: rights, members and links are one slot of state, and
                    // the topic strip of the open chat reads the same rights.
                    model.selection = chat.id
                    model.managedChat = chat
                }
            }
            Button(chat.kind == .channel ? "Покинуть канал…" : "Покинуть группу…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                guard Dialogs.confirm("Покинуть «\(chat.title)»?", message: "Вернуться можно будет по ссылке или через поиск, если чат публичный.", action: "Покинуть") else { return }
                Task { await model.deleteChat(chat, forEveryone: false) }
            }
        }
    }

    private func rows(_ visible: [Chat]) -> some View {
        ForEach(visible) { chat in
            // The open chat's draft is in the composer, not in the list.
            ChatRow(chat: chat, showsDraft: chat.id != model.selection)
                .tag(chat.id)
                .listRowSeparator(.hidden)
                .modifier(HoverPrefetch(chatId: chat.id))
                // A two-finger swipe does what the context menu's most common items do.
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if chat.unread > 0 || chat.isMarkedUnread {
                        Button("Прочитано", systemImage: "checkmark.message") { Task { await model.markChatRead(chat) } }
                            .tint(.blue)
                    } else {
                        Button("Непрочитано", systemImage: "message.badge") { Task { await model.markChatUnread(chat) } }
                            .tint(.blue)
                    }
                    Button(chat.isPinned ? "Открепить" : "Закрепить", systemImage: chat.isPinned ? "pin.slash" : "pin") {
                        Task { await model.toggleChatPinned(chat) }
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(chat.isArchived ? "Вернуть" : "Архив", systemImage: chat.isArchived ? "tray.and.arrow.up" : "archivebox") {
                        Task { await model.toggleChatArchived(chat) }
                    }
                    .tint(.indigo)
                    Button(chat.isMuted ? "Звук" : "Без звука", systemImage: chat.isMuted ? "bell" : "bell.slash") {
                        Task { await model.toggleChatMuted(chat) }
                    }
                    .tint(.gray)
                }
                .contextMenu {
                    Button("Профиль", systemImage: "person.crop.circle") { Task { await model.showProfile(of: chat) } }
                    Divider()
                    Button(chat.isPinned ? "Открепить" : "Закрепить", systemImage: chat.isPinned ? "pin.slash" : "pin") {
                        Task { await model.toggleChatPinned(chat) }
                    }
                    if chat.unread > 0 || chat.isMarkedUnread {
                        Button("Отметить прочитанным", systemImage: "checkmark.message") { Task { await model.markChatRead(chat) } }
                    } else {
                        Button("Отметить непрочитанным", systemImage: "message.badge") { Task { await model.markChatUnread(chat) } }
                    }
                    if chat.isMuted {
                        Button("Включить уведомления", systemImage: "bell") { Task { await model.toggleChatMuted(chat) } }
                    } else {
                        Menu("Выключить уведомления", systemImage: "bell.slash") {
                            Button("На час") { Task { await model.muteChat(chat, forSeconds: 3600) } }
                            Button("На 8 часов") { Task { await model.muteChat(chat, forSeconds: 8 * 3600) } }
                            Button("На 2 дня") { Task { await model.muteChat(chat, forSeconds: 2 * 86_400) } }
                            Divider()
                            Button("Навсегда") { Task { await model.toggleChatMuted(chat) } }
                        }
                    }
                    Button(chat.isArchived ? "Вернуть из архива" : "Архивировать", systemImage: chat.isArchived ? "tray.and.arrow.up" : "archivebox") {
                        Task { await model.toggleChatArchived(chat) }
                    }
                    Divider()
                    chatActions(chat)
                    if showsCode || showsIdentifiers {
                        Divider()
                    }
                    if showsCode {
                        Button("Код чата…", systemImage: "curlybraces") { Task { await model.inspect(chat) } }
                    }
                    if showsIdentifiers {
                        Button("Скопировать ID чата", systemImage: "number.square") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(String(chat.id), forType: .string)
                        }
                    }
                }
        }
    }
}

private struct ChatRow: View {
    @Environment(AppModel.self) private var model
    /// Raised on the selected row of a key window, which the list fills with the accent colour: anything
    /// drawn in that colour would vanish there, so it turns white.
    @Environment(\.backgroundProminence) private var prominence
    let chat: Chat

    private var isOnAccent: Bool { prominence == .increased }
    private var accent: Color { isOnAccent ? .white : .accentColor }
    let showsDraft: Bool

    private var hasNews: Bool { chat.unread > 0 || chat.isMarkedUnread || chat.unreadMentions > 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Avatar(title: chat.title, seed: chat.id, photo: chat.photo, diameter: 48)
                .overlay(alignment: .bottomTrailing) {
                    if chat.presence == .online, !chat.isBot {
                        OnlineDot()
                    }
                }
                // Hovering the avatar tells when a private contact was last seen.
                .help(chat.userId != 0 ? model.subtitle(for: chat) : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Unread chats stand out by weight, as in Mail and Messages; read ones are calmer.
                    if chat.kind == .secret {
                        // Telegram's own mark for an end-to-end encrypted chat.
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(isOnAccent ? Color.white : Color.green)
                            .help("Секретный чат")
                    }
                    Text(chat.title.isEmpty ? "Без названия" : chat.title)
                        .font(hasNews ? .body.weight(.semibold) : .body)
                        .lineLimit(1)
                    if chat.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    if let date = chat.snippetDate {
                        Text(date.chatListStamp)
                            .font(.subheadline)
                            .foregroundStyle(chat.unread > 0 && !chat.isMuted ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    }
                }
                HStack(spacing: 6) {
                    if chat.activity.isEmpty, showsDraft, !chat.draftText.isEmpty {
                        (Text("Черновик: ").foregroundStyle(isOnAccent ? Color.white : Color.red) + Text(chat.draftText).foregroundStyle(.secondary))
                            .font(.callout)
                            .lineLimit(2)
                    } else if chat.activity.isEmpty {
                        Group {
                            if chat.snippetSender.isEmpty || chat.snippet.isEmpty {
                                Text(chat.snippet.isEmpty ? chat.kind.label : chat.snippet)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(chat.snippetSender + ": ").foregroundStyle(.primary.opacity(0.85))
                                    + Text(chat.snippet).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .lineLimit(2)
                    } else {
                        HStack(spacing: 5) {
                            TypingDots()
                            Text(chat.activity)
                                .font(.callout)
                                .lineLimit(2)
                        }
                        .foregroundStyle(accent)
                    }
                    Spacer(minLength: 6)
                    if chat.unreadMentions > 0 {
                        // Someone mentioned you: Telegram's "@" before the count, never grey even when muted.
                        Text("@")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOnAccent ? Color.accentColor : Color.white)
                            .frame(width: 18, height: 18)
                            .background(accent, in: Circle())
                            .help("Вас упомянули")
                    }
                    if chat.unread > 0 {
                        UnreadBadge(count: chat.unread, isMuted: chat.isMuted, isOnAccent: isOnAccent)
                    } else if chat.isMarkedUnread {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 8, height: 8)
                    } else if chat.isPinned {
                        // Messages keeps the pin where the badge would be: a pinned chat with news shows the news.
                        Image(systemName: "pin.fill")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(45))
                    }
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

/// A message found by the sidebar search; a click opens its chat at the message.
private struct FoundMessageRow: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        let chat = model.chat(withId: message.chatId)
        Button {
            model.open(message)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Avatar(title: chat?.title ?? "", seed: message.chatId, photo: chat?.photo, diameter: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(chat?.title ?? "Чат")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(message.date.chatListStamp)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(TD.preview(of: message))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
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
                Text("iGram")
                    .font(.system(size: 22, weight: .semibold))
                Text("Выберите чат слева")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                shortcut("⌘K", "найти чат, человека или канал")
                shortcut("⌥⌘↑ ↓", "предыдущий и следующий чат")
                shortcut("⌥⇧↑ ↓", "к чату с непрочитанным")
                shortcut("⌘F", "поиск в чате")
                shortcut("⌘I", "профиль собеседника")
                shortcut("⌥⌘M", "список участников в группе")
                shortcut("⌘⇧V", "отправить из буфера")
                shortcut("⌘⇧G", "режим призрака")
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

/// Asks for a chat's history when the pointer rests on it for a moment. Rows that only slide under a still
/// pointer while the list scrolls do not count, so scrolling does not fire a request per row.
private struct HoverPrefetch: ViewModifier {
    @Environment(AppModel.self) private var model
    let chatId: Int64
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onHover { inside in
            pending?.cancel()
            guard inside else { return }
            pending = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                model.prefetchHistory(of: chatId)
            }
        }
        // A row scrolled away under the pointer gets no "left" event; its wait must not outlive it.
        .onDisappear { pending?.cancel() }
    }
}

/// The place the list shows, with the folders behind its name, and the search field.
private struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isSearchFocused: Bool

    /// Chats the list is showing right now — the place's own, or the matches while searching.
    let shownChats: Int

    var body: some View {
        @Bindable var model = model
        let footnote = placeFootnote
        return VStack(spacing: 8) {
            // The place the list shows, and the way to another one: Telegram's folders and the archive sit in
            // this menu, as the mailboxes of Messages and Mail sit behind their own title.
            HStack(spacing: 6) {
                Menu {
                    Toggle(placeTitle("Все чаты", model.mainUnread), isOn: chosen(folder: nil))
                    ForEach(model.chatFolders) { folder in
                        Toggle(placeTitle(folder.title.isEmpty ? "Без названия" : folder.title,
                                          model.folderUnread[folder.id] ?? UnreadTally()),
                               isOn: chosen(folder: folder.id))
                    }
                    Divider()
                    Toggle(placeTitle("Архив", model.archiveUnread), isOn: Binding(
                        get: { model.showsArchive },
                        set: { model.showsArchive = $0 }))
                    Divider()
                    Button("Прочитать всё здесь…", systemImage: "checkmark.message") {
                        let waiting = model.unreadChatsOnScreen
                        guard Dialogs.confirm("Отметить прочитанными \(TD.count(waiting.count, "чат", "чата", "чатов"))?",
                                              message: "Все сообщения в «\(place)» будут отмечены прочитанными.",
                                              action: "Прочитать") else { return }
                        Task { await model.markAllRead(waiting) }
                    }
                    .disabled(model.unreadChatsOnScreen.isEmpty)
                } label: {
                    HStack(spacing: 4) {
                        Text(place)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Папки и архив")
                .accessibilityLabel("Папка: \(place)")
                Spacer(minLength: 4)
                if !footnote.isEmpty {
                    Text(footnote)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Поиск", text: $model.filter, prompt: Text("Поиск"))
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isSearchFocused)
                    .onSubmit { model.openFirstSearchResult() }
                    .onExitCommand { model.filter = ""; isSearchFocused = false }
                if !model.filter.isEmpty {
                    Button {
                        model.filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Очистить")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("Чаты, люди и сообщения (⌘K)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .animation(.smooth(duration: 0.15), value: model.filter.isEmpty)
        .onChange(of: model.searchChatsRequest) { _, _ in isSearchFocused = true }
    }

    /// A menu row: the place and what is unread in it.
    private func placeTitle(_ title: String, _ unread: UnreadTally) -> String {
        unread.count > 0 ? "\(title) — \(unread.count > 999 ? "999+" : String(unread.count))" : title
    }

    /// A folder's row is ticked while it is the one on screen; picking it leaves the archive.
    private func chosen(folder: Int?) -> Binding<Bool> {
        Binding(
            get: { !model.showsArchive && model.selectedFolder == folder },
            set: { _ in
                model.showsArchive = false
                model.selectedFolder = folder
            })
    }

    /// Which place the list is showing.
    private var place: String {
        if model.showsArchive { return "Архив" }
        guard let id = model.selectedFolder else { return "Все чаты" }
        return model.chatFolders.first { $0.id == id }?.title ?? "Папка"
    }

    /// How big that place is and, when there is news, how much of it. The folder menu's counts already say which
    /// place has unread; this says whether the list on screen is waiting for anything. Empty while searching:
    /// the matches come from everywhere, so a count of the place would be a different number than the rows.
    private var placeFootnote: String {
        guard model.filter.isEmpty else { return "" }
        let tally: UnreadTally
        if model.showsArchive {
            tally = model.archiveUnread
        } else if let folder = model.selectedFolder {
            tally = model.folderUnread[folder] ?? UnreadTally()
        } else {
            tally = model.mainUnread
        }
        let chats = TD.count(shownChats, "чат", "чата", "чатов")
        guard tally.count > 0 else { return chats }
        return "\(chats) · \(TD.count(tally.count, "новое", "новых", "новых"))"
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
            TextField("Кому", text: $query, prompt: Text("Имя или @username"))
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
                            Text(person.name.isEmpty ? "Без имени" : person.name)
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
                        ContentUnavailableView(query.isEmpty ? "Контактов нет" : "Никого не нашлось", systemImage: "person.crop.circle.badge.questionmark",
                                               description: Text("Человека не из контактов можно найти через поиск в боковой панели"))
                    }
                }
            }
            Divider()
            HStack {
                Button("Избранное") {
                    dismiss()
                    Task { await model.openSavedMessages() }
                }
                Spacer()
                Button("Отмена") { dismiss() }
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
