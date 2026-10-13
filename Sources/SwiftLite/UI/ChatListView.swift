import AppKit
import SwiftUI

/// The sidebar: the folder on screen, search, that folder's chats, and the account at its foot.
/// Not private, so the harness can draw it alone — inside a split view its bottom inset cannot be inspected.
struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.showMessageCode) private var showsCode = false
    @AppStorage(Preferences.showIdentifiers) private var showsIdentifiers = false
    @AppStorage(Preferences.ghostMode) private var isGhost = false
    /// The window's own scheme. Everything below is told it is dark, so its ink is white on the indigo.
    @Environment(\.colorScheme) private var scheme
    @Environment(AccountHub.self) private var hub: AccountHub?
    /// Only chats with something unread, and the open one so it does not vanish from under the pointer.
    @State private var showsUnreadOnly = false
    /// Only chats with something written and not sent.
    @State private var showsDraftsOnly = false
    /// Messages found in the accounts that are not in the window, for the words in the search field.
    @State private var foundElsewhere: [(message: Message, owner: AppModel)] = []
    @AppStorage(Preferences.adExemptChats) private var exemptChats = ""

    /// The chats of every account in one list: with more than one account, unless a search is on.
    private var showsAllAccounts: Bool {
        guard let hub else { return false }
        return hub.showsAllAccounts && hub.accounts.count > 1 && model.filter.isEmpty && !model.showsArchive
    }

    var body: some View {
        @Bindable var model = model
        // Computed once per redraw: while searching it filters and sorts every known chat.
        let visible = model.filter.isEmpty ? model.visibleChats.filter(passesFilter) : model.visibleChats
        // The order of what is on screen, for the animation below: a chat with a new message rises to the top
        // rather than the rows being swapped under the eye. Not while the list is still filling at launch,
        // when hundreds of rows arrive at once and would all be sent sliding.
        let order = model.animatesChatList ? visible.prefix(40).map(\.id) : []
        return List(selection: $model.selection) {
            if showsAllAccounts, let hub {
                allAccountsRows(hub)
            } else if !model.filter.isEmpty {
                if !visible.isEmpty {
                    Section { rows(visible) } header: { SectionHeading(title: L("Чаты")) }
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
                        SectionHeading(title: L("Глобальный поиск"), systemImage: "globe")
                    }
                }
                if let hub, hub.accounts.count > 1 {
                    let elsewhere = hub.matches(model.filter, outside: model)
                    if !elsewhere.isEmpty {
                        Section {
                            ForEach(elsewhere) { item in
                                ChatRow(chat: item.chat, showsDraft: false, owner: item.owner)
                                    .environment(item.owner)
                                    .listRowSeparator(.hidden)
                                    .contentShape(Rectangle())
                                    .onTapGesture { hub.open(item.chat.id, in: item.owner.slot) }
                            }
                        } header: {
                            SectionHeading(title: L("Другие аккаунты"), systemImage: "person.2")
                        }
                    }
                }
                if !foundElsewhere.isEmpty, let hub {
                    Section {
                        ForEach(foundElsewhere, id: \.message.id) { item in
                            FoundMessageRow(message: item.message, before: { hub.activate(item.owner.slot) })
                                .environment(item.owner)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        SectionHeading(title: L("Сообщения в других аккаунтах"), systemImage: "person.2")
                    }
                }
                let kept = model.keptMessages(matching: model.filter)
                if !kept.isEmpty {
                    Section {
                        ForEach(kept, id: \.id) { message in
                            FoundMessageRow(message: message)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        SectionHeading(title: L("Удалённые и изменённые"), systemImage: "clock.arrow.circlepath")
                    }
                }
                if !model.foundMessages.isEmpty {
                    Section {
                        ForEach(model.foundMessages) { message in
                            FoundMessageRow(message: message)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        SectionHeading(title: L("Сообщения"), systemImage: "text.magnifyingglass")
                    }
                }
            } else if model.showsArchive {
                Section { rows(visible) } header: { SectionHeading(title: L("Архив"), systemImage: "archivebox.fill") }
            } else if visible.contains(where: \.isPinned) {
                // Pinned chats keep their place at the top and get a header, so the split is obvious at a
                // glance. Without any pinned chat no header is drawn: one would only repeat the list.
                Section { rows(visible.filter(\.isPinned)) } header: {
                    // No pin glyph here: every row under this header already carries one.
                    SectionHeading(title: L("Закреплённые"))
                }
                Section { rows(visible.filter { !$0.isPinned }) } header: { SectionHeading(title: L("Чаты")) }
            } else {
                rows(visible)
            }
        }
        .animation(.smooth(duration: 0.3), value: order)
        // The quick filters fold the list rather than swap it.
        .animation(.smooth(duration: 0.25), value: showsUnreadOnly)
        .animation(.smooth(duration: 0.25), value: showsDraftsOnly)
        // The other accounts are asked after a pause in typing, like the account in the window asks itself.
        .task(id: model.filter) {
            let query = model.filter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count >= 2, let hub, hub.accounts.count > 1 else {
                foundElsewhere = []
                return
            }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            var found: [(message: Message, owner: AppModel)] = []
            for account in hub.accounts where account.id != model.slot {
                guard let owner = hub.model(for: account.id) else { continue }
                for message in await owner.messages(matching: query) { found.append((message, owner)) }
            }
            guard !Task.isCancelled else { return }
            foundElsewhere = found.sorted { $0.message.date > $1.message.date }
        }
        // One menu for the list, built when a row is right-clicked. A menu on every row was built with the
        // row, hundreds of them for a long list, whether or not anyone ever opened one.
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let chat = model.chat(withId: id) {
                chatMenu(chat, in: model)
            }
        }
        .overlay {
            if visible.isEmpty && model.foundMessages.isEmpty && model.foundPublicChats.isEmpty && !showsAllAccounts,
               foundElsewhere.isEmpty, model.keptMessages(matching: model.filter).isEmpty,
               hub?.matches(model.filter, outside: model).isEmpty ?? true {
                ContentUnavailableView(
                    L("Пусто"),
                    systemImage: "text.bubble",
                    description: Text(model.filter.isEmpty
                        ? L("Дождитесь синхронизации или нажмите ⌘⇧R")
                        : L("Ничего не найдено"))
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The header counts what is on screen, so it is handed the list the rows were built from rather
            // than recomputing it: while searching, `model.chats` is still the whole place.
            SidebarHeader(shownChats: visible.count, showsUnreadOnly: $showsUnreadOnly, showsDraftsOnly: $showsDraftsOnly)
        }
        .toolbar {
            // Where Messages keeps "compose": a new chat with someone from your contacts.
            ToolbarItem {
                Button {
                    model.showsNewChat = true
                } label: {
                    Label(L("Новый чат"), systemImage: "square.and.pencil")
                }
                .help(L("Новый чат (⌘N)"))
            }
            ToolbarItem {
                Button {
                    Task { await model.loadChats() }
                } label: {
                    Label(L("Синхронизировать"), systemImage: "arrow.clockwise")
                }
                .help(L("Синхронизировать чаты (⇧⌘R)"))
            }
            ToolbarItem {
                Button {
                    isGhost.toggle()
                } label: {
                    Label(L("Режим призрака"), systemImage: isGhost ? "eye.slash.fill" : "eye")
                }
                .help(isGhost
                    ? L("Режим призрака включён: вы не в сети, не печатаете и ничего не читаете")
                    : L("Включить режим призрака"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                ErrorBanner()
                if let release = Updates.shared.available {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(L("Вышла версия \(release.version)"))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button(L("Скачать")) { NSWorkspace.shared.open(release.page) }
                            .buttonStyle(.plain)
                            .fontWeight(.semibold)
                        Button {
                            Updates.shared.dismiss()
                        } label: {
                            Image(systemName: "xmark").font(.caption.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L("Пропустить эту версию"))
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // The account, like the user card at the bottom of Apple's sidebars.
                HStack(spacing: 9) {
                    Button {
                        Task { await model.showMyProfile() }
                    } label: {
                        HStack(spacing: 9) {
                            Avatar(title: model.accountName, seed: model.myId, photo: model.myPhoto, diameter: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 4) {
                                    Text(model.accountName.isEmpty ? "—" : model.accountName)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    NameBadgeView(key: "u\(model.myId)", size: 14)
                                }
                                Text(isGhost ? L("призрак · не в сети") : TD.count(model.chats.count, L("чат"), L("чата"), L("чатов")))
                                    .font(.subheadline)
                                    .foregroundStyle(isGhost ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Мой профиль"))
                    Spacer(minLength: 4)
                    AccountSwitcher()
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDimStyle())
                    .help(L("Настройки (⌘,)"))
                    .accessibilityLabel(L("Настройки"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .animation(.spring(duration: 0.35, bounce: 0.15), value: Updates.shared.available)
        }
        // The list's own ground and selection give way to the indigo and to the card drawn behind the open chat.
        .scrollContentBackground(.hidden)
        // The indigo runs up behind the toolbar's buttons instead of stopping at a pale band under them.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .hidingTopScrollEdge()
        .background(PlainSelection())
        .environment(\.colorScheme, .dark)
        .background(SidebarGlass())
    }

    /// What a right click on a chat offers. `model` is the account the chat belongs to: in the list of all
    /// accounts that is not always the one in the window, and anything that opens a sheet brings it there first.
    @ViewBuilder
    private func chatMenu(_ chat: Chat, in model: AppModel) -> some View {
        Button(L("Профиль"), systemImage: "person.crop.circle") {
            hub?.activate(model.slot)
            Task { await model.showProfile(of: chat) }
        }
        Divider()
        Button(chat.isPinned ? L("Открепить") : L("Закрепить"), systemImage: chat.isPinned ? "pin.slash" : "pin") {
            Task { await model.toggleChatPinned(chat) }
        }
        if chat.unread > 0 || chat.isMarkedUnread {
            Button(L("Отметить прочитанным"), systemImage: "checkmark.message") { Task { await model.markChatRead(chat) } }
        } else {
            Button(L("Отметить непрочитанным"), systemImage: "message.badge") { Task { await model.markChatUnread(chat) } }
        }
        if chat.isMuted {
            Button(L("Включить уведомления"), systemImage: "bell") { Task { await model.toggleChatMuted(chat) } }
        } else {
            Menu(L("Выключить уведомления"), systemImage: "bell.slash") {
                Button(L("На час")) { Task { await model.muteChat(chat, forSeconds: 3600) } }
                Button(L("На 8 часов")) { Task { await model.muteChat(chat, forSeconds: 8 * 3600) } }
                Button(L("На 2 дня")) { Task { await model.muteChat(chat, forSeconds: 2 * 86_400) } }
                Divider()
                Button(L("Навсегда")) { Task { await model.toggleChatMuted(chat) } }
            }
        }
        Button(chat.isArchived ? L("Вернуть из архива") : L("Архивировать"), systemImage: chat.isArchived ? "tray.and.arrow.up" : "archivebox") {
            Task { await model.toggleChatArchived(chat) }
        }
        Divider()
        if chat.kind != .channel {
            Button(L("Быстрый ответ…"), systemImage: "arrowshape.turn.up.left") {
                guard let text = Dialogs.prompt(L("Ответ в «\(chat.title)»"), hint: L("Сообщение уйдёт сразу, чат не откроется.")), !text.isEmpty else { return }
                Task { await model.quickReply(text, to: chat.id) }
            }
        } else {
            let skipped = AdFilter.isExempt(chat.id)
            Button(skipped ? L("Скрывать рекламу в этом канале") : L("Не скрывать рекламу в этом канале"), systemImage: skipped ? "eye.slash" : "eye") {
                AdFilter.setExempt(!skipped, chatId: chat.id)
            }
        }
        Button(L("Фото и видео чата…"), systemImage: "photo.on.rectangle") {
            hub?.activate(model.slot)
            model.mediaGallery = .chat(chat.id, title: chat.title)
        }
        Button(L("Сохранить чат в Markdown…"), systemImage: "square.and.arrow.down") {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (chat.title.isEmpty ? "chat" : chat.title.replacingOccurrences(of: "/", with: "-")) + ".md"
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            guard panel.runModal() == .OK, let file = panel.url else { return }
            model.exportMarkdown(of: chat, to: file)
        }
        Divider()
        chatActions(chat, in: model)
        if showsCode || showsIdentifiers {
            Divider()
        }
        if showsCode {
            Button(L("Код чата…"), systemImage: "curlybraces") {
                hub?.activate(model.slot)
                Task { await model.inspect(chat) }
            }
        }
        if showsIdentifiers {
            Button(L("Скопировать ID чата"), systemImage: "number.square") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(chat.id), forType: .string)
            }
        }
    }

    /// Clear, block, delete or leave: the things you do to a whole chat.
    @ViewBuilder
    private func chatActions(_ chat: Chat, in model: AppModel) -> some View {
        let isPrivate = chat.kind == .personal || chat.kind == .secret
        Button(L("Очистить историю…"), systemImage: "eraser") {
            let canRevoke = isPrivate && chat.userId != 0 && !chat.isBot
            guard let answer = Dialogs.confirm(L("Очистить историю «\(chat.title)»?"),
                                               message: L("Сообщения пропадут из этого чата."), action: L("Очистить"),
                                               option: canRevoke ? L("Также у собеседника") : nil) else { return }
            Task { await model.clearHistory(of: chat, forEveryone: answer) }
        }
        if isPrivate, chat.userId != 0 {
            Button(chat.isBot ? L("Остановить и заблокировать бота") : L("Заблокировать"), systemImage: "hand.raised") {
                guard Dialogs.confirm(L("Заблокировать \(chat.title)?"), message: L("Он не сможет писать вам и звонить."), action: L("Заблокировать")) else { return }
                Task { _ = await model.setBlocked(true, userId: chat.userId) }
            }
            Button(L("Удалить чат…"), systemImage: "trash", role: .destructive) {
                guard let answer = Dialogs.confirm(L("Удалить чат с \(chat.title)?"), message: L("Чат исчезнет из списка вместе с историей."),
                                                   action: L("Удалить"), option: chat.isBot ? nil : L("Также у собеседника")) else { return }
                Task { await model.deleteChat(chat, forEveryone: answer) }
            }
        } else {
            if chat.kind == .group || chat.kind == .channel, !chat.groupKey.hasPrefix("b") {
                Button(L("Управление чатом…"), systemImage: "person.2.circle") {
                    // Managing opens the chat as well: rights, members and links are one slot of state, and
                    // the topic strip of the open chat reads the same rights.
                    hub?.activate(model.slot)
                    model.selection = chat.id
                    model.managedChat = chat
                }
            }
            Button(chat.kind == .channel ? L("Покинуть канал…") : L("Покинуть группу…"), systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                guard Dialogs.confirm(L("Покинуть «\(chat.title)»?"), message: L("Вернуться можно будет по ссылке или через поиск, если чат публичный."), action: L("Покинуть")) else { return }
                Task { await model.deleteChat(chat, forEveryone: false) }
            }
        }
    }

    /// The sidebar's two quick filters; the open chat stays so it does not vanish from under the pointer.
    private func passesFilter(_ chat: Chat) -> Bool {
        if showsUnreadOnly, !(chat.unread > 0 || chat.isMarkedUnread || chat.unreadMentions > 0), chat.id != model.selection { return false }
        if showsDraftsOnly, chat.draftText.isEmpty, chat.id != model.selection { return false }
        return true
    }

    /// Every account's chats together. A row of the account in the window is selected as usual; a row of
    /// another account brings that account into the window with its chat, so the answer goes from the
    /// account the message came to, without picking it first.
    private func allAccountsRows(_ hub: AccountHub) -> some View {
        let all = hub.allChats.filter { passesFilter($0.chat) || ($0.owner === model && $0.chat.id == model.selection) }
        return ForEach(all) { item in
            let isOwn = item.owner === model
            let isOpen = isOwn && item.chat.id == model.selection
            let row = ChatRow(chat: item.chat, showsDraft: !isOpen, isCard: isOpen && scheme == .light, owner: item.owner)
                .environment(item.owner)
                .listRowSeparator(.hidden)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isOpen ? Color.white.opacity(scheme == .light ? 0.92 : 0.16) : .clear)
                        .padding(.horizontal, 8)
                        .animation(.smooth(duration: 0.18), value: isOpen))
            if isOwn {
                row.tag(item.chat.id)
            } else {
                row.contentShape(Rectangle())
                    .onTapGesture { hub.open(item.chat.id, in: item.owner.slot) }
                    .contextMenu { chatMenu(item.chat, in: item.owner) }
            }
        }
    }

    private func rows(_ visible: [Chat]) -> some View {
        ForEach(visible) { chat in
            // The open chat's draft is in the composer, not in the list.
            let isOpen = chat.id == model.selection
            ChatRow(chat: chat, showsDraft: !isOpen, isCard: isOpen && scheme == .light)
                .tag(chat.id)
                .listRowSeparator(.hidden)
                // The open chat is a white card on the indigo; in the dark, a lighter patch of it.
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isOpen ? Color.white.opacity(scheme == .light ? 0.92 : 0.16) : .clear)
                        .padding(.horizontal, 8)
                        .animation(.smooth(duration: 0.18), value: isOpen))
                .modifier(HoverPrefetch(chatId: chat.id))
                // A two-finger swipe does what the context menu's most common items do.
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if chat.unread > 0 || chat.isMarkedUnread {
                        Button(L("Прочитано"), systemImage: "checkmark.message") { Task { await model.markChatRead(chat) } }
                            .tint(.blue)
                    } else {
                        Button(L("Непрочитано"), systemImage: "message.badge") { Task { await model.markChatUnread(chat) } }
                            .tint(.blue)
                    }
                    Button(chat.isPinned ? L("Открепить") : L("Закрепить"), systemImage: chat.isPinned ? "pin.slash" : "pin") {
                        Task { await model.toggleChatPinned(chat) }
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(chat.isArchived ? L("Вернуть") : L("Архив"), systemImage: chat.isArchived ? "tray.and.arrow.up" : "archivebox") {
                        Task { await model.toggleChatArchived(chat) }
                    }
                    .tint(.indigo)
                    Button(chat.isMuted ? L("Звук") : L("Без звука"), systemImage: chat.isMuted ? "bell" : "bell.slash") {
                        Task { await model.toggleChatMuted(chat) }
                    }
                    .tint(.gray)
                }
        }
    }
}

private struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let showsDraft: Bool
    /// The open chat in a light window: a white card with dark ink. Every other row lies on the indigo.
    var isCard = false
    /// In the list of all accounts: whose chat this is. Its photo sits on the corner of the chat's own.
    var owner: AppModel?

    /// Under the pointer the row lifts a shade, so the list answers before it is clicked.
    @State private var isHovered = false

    /// On the indigo anything drawn in that colour would vanish, so it turns white.
    private var isOnAccent: Bool { !isCard }
    private var accent: Color { isOnAccent ? .white : .brand }

    private var hasNews: Bool { chat.unread > 0 || chat.isMarkedUnread || chat.unreadMentions > 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Avatar(title: chat.title, seed: chat.id, photo: chat.photo, diameter: 48)
                .overlay(alignment: .bottomTrailing) {
                    if chat.presence == .online, !chat.isBot {
                        OnlineDot()
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let owner {
                        Avatar(title: owner.accountName, seed: owner.myId, photo: owner.myPhoto, diameter: 20)
                            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                            .offset(x: -4, y: 4)
                            .help(L("Аккаунт: \(owner.accountName)"))
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
                            .help(L("Секретный чат"))
                    }
                    Text(chat.title.isEmpty ? L("Без названия") : chat.title)
                        .font(hasNews ? .body.weight(.semibold) : .body)
                        .lineLimit(1)
                    NameBadgeView(key: chat.badgeKey, isOnAccent: isOnAccent)
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
                        (Text(L("Черновик: ")).foregroundStyle(isOnAccent ? Color.white : Color.red) + Text(chat.draftText).foregroundStyle(.secondary))
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
                            .foregroundStyle(isOnAccent ? Color.brand : Color.white)
                            .frame(width: 18, height: 18)
                            .background(accent, in: Circle())
                            .help(L("Вас упомянули"))
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isHovered && !isCard ? 0.06 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -1)
        )
        .onHover { inside in
            withAnimation(.smooth(duration: 0.15)) { isHovered = inside }
        }
        .environment(\.colorScheme, isCard ? .light : .dark)
        .accessibilityElement(children: .combine)
    }
}

/// Takes the table's own highlight off the chat list: the open chat is marked by the card behind its row, and
/// the system's accent-coloured bar would be drawn over the indigo. SwiftUI sets the style again on its own
/// schedule, so it is put back whenever this view is laid out.
private struct PlainSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    private final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { [weak self] in self?.apply() } }
        override func layout() { super.layout(); apply() }

        func apply() {
            guard let table = Self.table(in: superview?.superview ?? superview) else { return }
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
        }

        private static func table(in view: NSView?) -> NSTableView? {
            guard let view else { return nil }
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let found = table(in: child) { return found }
            }
            return nil
        }
    }
}

/// The other accounts of this Mac, one click away: their photos with what is unread on them, and a menu of all
/// of them with "add". Every account stays connected, so picking one only changes what the window shows.
private struct AccountSwitcher: View {
    @Environment(AccountHub.self) private var hub: AccountHub?

    var body: some View {
        if let hub {
            let others = hub.accounts.filter { $0.id != hub.activeId }
            ForEach(others.prefix(3)) { account in
                if let other = hub.model(for: account.id) {
                    OtherAccountButton(account: account, model: other) { hub.activate(account.id) }
                }
            }
            Menu {
                ForEach(Array(hub.accounts.enumerated()), id: \.element.id) { index, account in
                    Toggle(title(of: account, number: index + 1), isOn: Binding(
                        get: { account.id == hub.activeId },
                        set: { _ in hub.activate(account.id) }))
                }
                Divider()
                Button(L("Добавить аккаунт…"), systemImage: "plus") { hub.addAccount() }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Аккаунты (⌃1…⌃9)"))
            .accessibilityLabel(L("Аккаунты"))
        }
    }

    private func title(of account: AccountSlot, number: Int) -> String {
        let name = account.name.isEmpty ? L("Новый аккаунт") : account.name
        let unread = hub?.model(for: account.id)?.unreadBadge ?? 0
        return unread > 0 ? "\(name) — \(unread > 999 ? "999+" : String(unread))" : name
    }
}

/// Another account's photo in the sidebar's foot; a dot's worth of badge when something is unread there.
private struct OtherAccountButton: View {
    let account: AccountSlot
    let model: AppModel
    let pick: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: pick) {
            // The photo is a file of that account's own session, so its model draws it.
            Avatar(title: account.name, seed: account.userId, photo: model.myPhoto, diameter: 26)
                .environment(model)
                .overlay(alignment: .topTrailing) {
                    if model.unreadBadge > 0 {
                        Text(model.unreadBadge > 99 ? "99+" : String(model.unreadBadge))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(red: 0x0B / 255, green: 0x07 / 255, blue: 0x30 / 255))
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(.white, in: Capsule())
                            .offset(x: 6, y: -5)
                    }
                }
                .contentShape(Circle())
                .scaleEffect(isHovered ? 1.1 : 1)
        }
        .buttonStyle(PressDimStyle())
        .onHover { inside in
            withAnimation(.spring(duration: 0.25, bounce: 0.35)) { isHovered = inside }
        }
        .help(account.name.isEmpty ? L("Новый аккаунт") : L("Перейти в \(account.name)"))
        .accessibilityLabel(L("Аккаунт \(account.name)"))
    }
}

/// A message found by the sidebar search; a click opens its chat at the message.
private struct FoundMessageRow: View {
    @Environment(AppModel.self) private var model
    let message: Message
    /// For a message of another account: what brings that account into the window first.
    var before: (() -> Void)? = nil

    var body: some View {
        let chat = model.chat(withId: message.chatId)
        Button {
            before?()
            model.open(message)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Avatar(title: chat?.title ?? "", seed: message.chatId, photo: chat?.photo, diameter: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(chat?.title ?? L("Чат"))
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
    @Environment(AccountHub.self) private var hub: AccountHub?
    @FocusState private var isSearchFocused: Bool

    private var showsAllAccounts: Bool {
        guard let hub else { return false }
        return hub.showsAllAccounts && hub.accounts.count > 1 && !model.showsArchive
    }

    /// Chats the list is showing right now — the place's own, or the matches while searching.
    let shownChats: Int
    @Binding var showsUnreadOnly: Bool
    @Binding var showsDraftsOnly: Bool

    var body: some View {
        @Bindable var model = model
        let footnote = placeFootnote
        return VStack(spacing: 8) {
            // The place the list shows, and the way to another one: Telegram's folders and the archive sit in
            // this menu, as the mailboxes of Messages and Mail sit behind their own title.
            HStack(spacing: 6) {
                Menu {
                    if let hub, hub.accounts.count > 1 {
                        Toggle(L("Все аккаунты"), isOn: Binding(
                            get: { showsAllAccounts },
                            set: { _ in
                                model.showsArchive = false
                                model.selectedFolder = nil
                                hub.showsAllAccounts = true
                            }))
                        Divider()
                    }
                    Toggle(placeTitle(L("Все чаты"), model.mainUnread), isOn: chosen(folder: nil))
                    ForEach(model.chatFolders) { folder in
                        Toggle(placeTitle(folder.title.isEmpty ? L("Без названия") : folder.title,
                                          model.folderUnread[folder.id] ?? UnreadTally()),
                               isOn: chosen(folder: folder.id))
                    }
                    Divider()
                    Toggle(placeTitle(L("Архив"), model.archiveUnread), isOn: Binding(
                        get: { model.showsArchive },
                        set: { model.showsArchive = $0 }))
                    Divider()
                    Toggle(L("Только с черновиками"), isOn: $showsDraftsOnly)
                    Button(L("Избранное"), systemImage: "bookmark") { Task { await model.openSavedMessages() } }
                    Button(L("Загрузки…"), systemImage: "arrow.down.circle") { model.showsDownloads = true }
                    Button(L("Фото и видео…"), systemImage: "photo.on.rectangle") { model.mediaGallery = .everywhere }
                    Divider()
                    Button(L("Прочитать всё здесь…"), systemImage: "checkmark.message") {
                        let waiting = model.unreadChatsOnScreen
                        guard Dialogs.confirm(L("Отметить прочитанными \(TD.count(waiting.count, L("чат"), L("чата"), L("чатов")))?"),
                                              message: L("Все сообщения в «\(place)» будут отмечены прочитанными."),
                                              action: L("Прочитать")) else { return }
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
                .help(L("Папки и архив"))
                .accessibilityLabel(L("Папка: \(place)"))
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
                TextField(L("Поиск"), text: $model.filter, prompt: Text(L("Поиск")))
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isSearchFocused)
                    .onSubmit { model.openFirstSearchResult() }
                    .onExitCommand { model.filter = ""; isSearchFocused = false }
                if model.filter.isEmpty {
                    Button {
                        showsUnreadOnly.toggle()
                    } label: {
                        Image(systemName: showsUnreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .foregroundStyle(showsUnreadOnly ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .help(showsUnreadOnly ? L("Показать все чаты") : L("Только непрочитанные"))
                    .accessibilityLabel(L("Только непрочитанные"))
                }
                if !model.filter.isEmpty {
                    Button {
                        model.filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Очистить"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help(L("Чаты, люди и сообщения (⌘K)"))
            if model.filter.isEmpty {
                StoriesRow()
            }
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
            get: { !model.showsArchive && model.selectedFolder == folder && !showsAllAccounts },
            set: { _ in
                // A folder is one account's: picking it leaves the list of all accounts.
                hub?.showsAllAccounts = false
                model.showsArchive = false
                model.selectedFolder = folder
            })
    }

    /// Which place the list is showing.
    private var place: String {
        if model.showsArchive { return L("Архив") }
        if showsAllAccounts { return L("Все аккаунты") }
        guard let id = model.selectedFolder else { return L("Все чаты") }
        return model.chatFolders.first { $0.id == id }?.title ?? L("Папка")
    }

    /// How big that place is and, when there is news, how much of it. The folder menu's counts already say which
    /// place has unread; this says whether the list on screen is waiting for anything. Empty while searching:
    /// the matches come from everywhere, so a count of the place would be a different number than the rows.
    private var placeFootnote: String {
        guard model.filter.isEmpty else { return "" }
        if showsAllAccounts, let hub {
            let unread = hub.unreadTotal
            return unread > 0 ? TD.count(unread, L("новое"), L("новых"), L("новых")) : TD.count(hub.accounts.count, L("аккаунт"), L("аккаунта"), L("аккаунтов"))
        }
        let tally: UnreadTally
        if model.showsArchive {
            tally = model.archiveUnread
        } else if let folder = model.selectedFolder {
            tally = model.folderUnread[folder] ?? UnreadTally()
        } else {
            tally = model.mainUnread
        }
        let chats = TD.count(shownChats, L("чат"), L("чата"), L("чатов"))
        guard tally.count > 0 else { return chats }
        return "\(chats) · \(TD.count(tally.count, L("новое"), L("новых"), L("новых")))"
    }
}
