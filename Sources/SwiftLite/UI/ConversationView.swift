import AppKit
import SwiftUI

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let chat: Chat

    @State private var isNearBottom = true
    @State private var isDropTargeted = false
    /// Where the transcript is scrolled to. Going to the newest message is done through this, by asking for
    /// the end of the content, not for the last row: a row that has only just been added is not laid out
    /// yet, so a scroll aimed at it stopped where it guessed the row would be — short of the end, with the
    /// new message left under the composer.
    @State private var position = ScrollPosition(edge: .bottom)
    /// Until this moment the transcript keeps itself at its end while its content settles: the new row gets
    /// its real height, a picture gets its size, the message being sent gets its delivery line.
    @State private var followsEndUntil = Date.distantPast
    /// The transcript has been seen away from its top, so arriving there is the user's doing.
    @State private var hasLeftTop = false

    /// Where the transcript stands against the start of what is loaded.
    private enum TopReach {
        /// Everything loaded fits in the window: there is no top to scroll to.
        case short
        case top
        case away
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            VStack(spacing: 6) {
                if model.isSearching {
                    SearchBar()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let thread = model.commentThread {
                    CommentsBar(thread: thread)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if model.openChatIsForum {
                    TopicBar(chat: chat)
                        .transition(.opacity)
                }
                if let pinned = model.pinnedMessage {
                    PinnedBar(message: pinned)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // The bars above the transcript slide in from under the toolbar instead of appearing in place.
            .motion(.smooth(duration: 0.22), value: model.isSearching)
            .motion(.smooth(duration: 0.22), value: model.pinnedMessage?.id)
            .motion(.smooth(duration: 0.22), value: model.openChatIsForum)
            .motion(.smooth(duration: 0.22), value: model.commentThread?.threadId)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.canLoadOlder {
                            olderButton(proxy)
                        }
                        ForEach(model.transcript) { day in
                            Section {
                                ForEach(day.rows, id: \.message.viewId) { row in
                                    if row.message.id == model.unreadMarkerId {
                                        UnreadSeparator()
                                    }
                                    MessageRow(row: row, chat: RowChat(chat))
                                        .id(row.message.viewId)
                                }
                            } header: {
                                DayHeader(date: day.date)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom)
                .softScrollEdges()
                .overlay {
                    if model.messages.isEmpty {
                        emptyState
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
                } action: { _, nearBottom in
                    isNearBottom = nearBottom
                }
                // Scrolling up to the first loaded message brings the page before it, as every messenger does;
                // the button above it stays for when that request fails. Only an arrival counts: a chat that
                // opens at its top (short, or placed on an old unread message) has not asked for anything, and
                // a failed page must not be asked for again on every frame spent there.
                .onScrollGeometryChange(for: TopReach.self) { geometry in
                    guard geometry.contentSize.height > geometry.containerSize.height + 1 else { return .short }
                    return geometry.contentOffset.y < 120 ? .top : .away
                } action: { _, reach in
                    switch reach {
                    case .short: hasLeftTop = false
                    case .away: hasLeftTop = true
                    case .top: if hasLeftTop { loadOlder(proxy) }
                    }
                }
                // New messages pull the view down only while the end is on screen, or when they are your own:
                // reading older messages is not interrupted.
                // By the id the view knows the message under: a message of yours getting its real id from the
                // server is not a new message, and must not set the transcript scrolling again.
                .onChange(of: model.messages.last?.viewId) { _, newest in
                    // A jump into older history places the view itself.
                    guard newest != nil, model.scrollTarget == nil, !model.isViewingHistory,
                          isNearBottom || model.messages.last?.isOutgoing == true else { return }
                    followsEndUntil = Date().addingTimeInterval(0.8)
                    withAnimation(Motion.respecting(.smooth(duration: 0.2))) { position.scrollTo(edge: .bottom) }
                }
                // The content grew or shrank while the end is being followed: stay at the end.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height
                } action: { _, _ in
                    if Date() < followsEndUntil { position.scrollTo(edge: .bottom) }
                }
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    if model.scrollsWithoutAnimation {
                        // A chat opening on its unread messages is simply there, the divider a little under the top.
                        model.scrollsWithoutAnimation = false
                        proxy.scrollTo(model.viewId(ofMessage: target), anchor: UnitPoint(x: 0.5, y: 0.2))
                    } else {
                        withAnimation(Motion.respecting(.smooth(duration: 0.25))) { proxy.scrollTo(model.viewId(ofMessage: target), anchor: .center) }
                    }
                    model.scrollTarget = nil
                }
                .overlay(alignment: .top) {
                    if let toast = model.toast {
                        ToastView(text: toast)
                            .padding(.top, 10)
                            .padding(.horizontal, 20)
                    }
                }
                // Before the composer's inset, so the buttons stand above the composer instead of on it.
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 14) {
                    if chat.unreadMentions > 0 {
                        MentionButton(count: chat.unreadMentions)
                    }
                    if !isNearBottom || model.isViewingHistory, !model.messages.isEmpty {
                        Button {
                            if model.isViewingHistory {
                                Task { await model.showLatest() }
                            } else {
                                followsEndUntil = Date().addingTimeInterval(0.5)
                                withAnimation(Motion.respecting(.smooth(duration: 0.2))) { position.scrollTo(edge: .bottom) }
                            }
                        } label: {
                            GlassCircleLabel {
                                Image(systemName: "chevron.down")
                                    .font(.body.weight(.semibold))
                            }
                                .overlay(alignment: .top) {
                                    if chat.unread > 0 {
                                        UnreadBadge(count: chat.unread, isMuted: chat.isMuted)
                                            .offset(y: -10)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(L("К последним сообщениям"))
                        .accessibilityLabel(L("К последним сообщениям"))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    }
                    .glassGroup(spacing: 14)
                    .padding(14)
                    .motion(.spring(duration: 0.28, bounce: 0.25), value: isNearBottom)
                }
                // The composer floats over the transcript, which scrolls on under its translucent bar.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.isSelectingMessages {
                        SelectionBar()
                    } else {
                        Composer()
                    }
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(Text(L("Отпустите, чтобы прикрепить")).font(.body.weight(.medium)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let photo = model.viewerMessage {
                PhotoViewer(message: photo)
            }
        }
        .motion(.smooth(duration: 0.2), value: model.toast)
        .motion(.spring(duration: 0.3, bounce: 0.12), value: model.viewerMessage?.id)
        // Links in messages: t.me stays in the app, suspicious addresses are explained before they open.
        .environment(\.openURL, OpenURLAction { url in
            Task { await model.openMessageLink(url) }
            return .handled
        })
        .background {
            Button("") { withAnimation(Motion.respecting(.smooth(duration: 0.15))) { model.escape() } }
                .keyboardShortcut(.cancelAction)
                // Invisible but still in the hierarchy: a `.hidden()` button may lose its shortcut.
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.offerFiles(files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        // The transcript's own ground, so the bubbles sit on a surface instead of floating on the desktop.
        .background(ChatWallpaper().ignoresSafeArea())
        // Still the window's name (the Window menu, Mission Control); the toolbar shows it its own way.
        .navigationTitle(chat.title)
        .toolbar(removing: .title)
        .toolbar {
            // Who you are talking to, in the middle of the toolbar as in Messages; a click opens their profile.
            ToolbarItem(placement: .principal) {
                Button {
                    Task { await model.showProfile(of: chat) }
                } label: {
                    HStack(spacing: 8) {
                        Avatar(title: chat.title, seed: chat.id, photo: chat.photo, diameter: 26)
                            .overlay(alignment: .bottomTrailing) {
                                if chat.presence == .online, !chat.isBot { OnlineDot(diameter: 9) }
                            }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 4) {
                                if chat.kind == .secret {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.green)
                                }
                                Text(chat.title.isEmpty ? L("Без названия") : chat.title)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                NameBadgeView(key: chat.badgeKey, size: 14)
                            }
                            let subtitle = model.subtitle(for: chat)
                            if !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(chat.activity.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.brandInk))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: 320)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // ⌘I itself lives in the Формат menu, which shares the key with italic.
                .help(L("Профиль и сведения (⌘I)"))
                .accessibilityLabel(L("Профиль"))
                // Toolbar and sheet content live outside the window's view tree; the model is passed on explicitly.
                .environment(model)
            }
            ToolbarItem {
                Button {
                    if model.isSearching { model.endSearch() } else { model.isSearching = true }
                } label: {
                    Label(L("Поиск в чате"), systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help(L("Поиск по сообщениям этого чата (⌘F)"))
            }
            ToolbarItem {
                Button {
                    Task { await model.markSelectedRead() }
                } label: {
                    Label(L("Отметить прочитанным"), systemImage: "checkmark.circle")
                }
                .help(L("Отметить сообщения прочитанными"))
            }
            // Only supergroups can list their people; a basic group has no roster to ask for.
            if chat.groupKey.hasPrefix("s") {
                ToolbarItem {
                    Button {
                        model.showsMembersPanel.toggle()
                    } label: {
                        Label(L("Участники"), systemImage: model.showsMembersPanel ? "person.2.fill" : "person.2")
                    }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                    .help(model.showsMembersPanel
                        ? L("Скрыть список участников (⌥⌘M)")
                        : L("Показать список участников (⌥⌘M)"))
                }
            }
        }
        .task { await model.select(chatId: chat.id) }
        .sheet(item: $model.forwardingBatch) { batch in
            ForwardSheet(messages: batch.messages, endsSelection: batch.endsSelection)
                .environment(model)
        }
        .sheet(isPresented: Binding(get: { model.pendingFiles != nil }, set: { if !$0 { model.pendingFiles = nil } })) {
            SendFilesSheet()
                .environment(model)
        }
        .sheet(item: $model.managedChat) { managed in
            ChatManageSheet(chat: managed)
                .environment(model)
        }
    }

    /// An empty transcript is either still loading or a chat nobody has written in yet; TDLib's last message says which.
    @ViewBuilder
    private var emptyState: some View {
        if chat.lastMessageId != 0 {
            // Only while a load runs: a failed one shows its error instead of spinning forever.
            if model.loadingHistory {
                ProgressView()
                    .controlSize(.regular)
                    .transition(.opacity)
            }
        } else if !chat.isBot {
            VStack(spacing: 10) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.brandInk)
                Text(L("Здесь пока нет сообщений"))
                    .font(.system(size: 14, weight: .semibold))
                Text(chat.kind == .channel ? L("Новые публикации появятся здесь") : L("Напишите первым — начните с приветствия"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .transition(.opacity)
        }
    }

    private func olderButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            loadOlder(proxy)
        } label: {
            if model.loadingHistory {
                ProgressView().controlSize(.small)
            } else {
                Text(L("Загрузить более ранние"))
            }
        }
        .buttonStyle(PressDimStyle())
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func loadOlder(_ proxy: ScrollViewProxy) {
        guard model.canLoadOlder, !model.loadingHistory else { return }
        // The row that was on top stays where it was instead of the view jumping. A row is named by its last
        // message, so an album at the top is found by that one: by its first photo the scroll found nothing.
        let anchor = model.transcript.first?.rows.first?.message.id
        Task {
            await model.loadOlder()
            if let anchor, model.transcript.first?.rows.first?.message.id != anchor {
                proxy.scrollTo(model.viewId(ofMessage: anchor), anchor: .top)
            }
        }
    }
}

/// Search inside the open chat: Return searches, the arrows walk through the matches, Esc closes.
private struct SearchBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Поиск в чате"), text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { Task { await model.runSearch() } }
            if model.isSearchRunning {
                ProgressView().controlSize(.small)
            } else if !model.searchResults.isEmpty {
                Text(L("\(model.searchPosition + 1) из \(max(model.searchTotal, model.searchResults.count))"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if !model.searchQuery.isEmpty {
                Text(L("Return — искать"))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Button { Task { await model.stepSearch(1) } } label: { Image(systemName: "chevron.up") }
                .disabled(!model.canStepSearchOlder)
                .help(L("Раньше"))
            Button { Task { await model.stepSearch(-1) } } label: { Image(systemName: "chevron.down") }
                .disabled(model.searchPosition == 0)
                .help(L("Позже"))
            Button { model.endSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .help(L("Закрыть поиск"))
        }
        .buttonStyle(PressDimStyle())
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .onAppear { focused = true }
    }
}

/// Above the comments of a channel post: what they are under, and the way back to the channel.
private struct CommentsBar: View {
    @Environment(AppModel.self) private var model
    let thread: CommentThread

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.closeComments()
            } label: {
                Label(thread.channelTitle.isEmpty ? L("К каналу") : thread.channelTitle, systemImage: "chevron.backward")
                    .lineLimit(1)
            }
            .buttonStyle(PressDimStyle())
            .foregroundStyle(Color.brand)
            .keyboardShortcut("[", modifiers: .command)
            .help(L("Вернуться к посту (⌘[)"))
            Spacer(minLength: 8)
            Label(L("Комментарии"), systemImage: "bubble.left.and.bubble.right")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal, 14)
    }
}

/// Replaces the composer while messages are being picked.
private struct SelectionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.selectedMessageIds.count
        HStack(spacing: 14) {
            Text(count == 0 ? L("Выберите сообщения") : L("Выбрано: \(count)"))
                .font(.body.weight(.medium))
                .monospacedDigit()
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.selectionAsText(), forType: .string)
                model.endSelection()
            } label: {
                Label(L("Скопировать"), systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(count == 0)
            Button {
                model.prepareForwarding(model.selectedMessages, fromSelection: true)
            } label: {
                Label(L("Переслать"), systemImage: "arrowshape.turn.up.right")
            }
            .disabled(count == 0)
            Button(role: .destructive) {
                Task {
                    guard let options = await model.selectionDeletionOptions(),
                          let forEveryone = Dialogs.confirmDeletion(options) else { return }
                    await model.deleteSelection(forEveryone: forEveryone)
                }
            } label: {
                Label(L("Удалить"), systemImage: "trash")
            }
            .disabled(count == 0)
            Button(L("Готово")) { model.endSelection() }
                .buttonStyle(.borderedProminent)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

/// The chat's pinned message above the transcript; a click shows it in place.
/// The topics of a forum supergroup, in a strip above the transcript. "Все" is the chat as one stream,
/// which is how it reads before anyone picks a topic.
struct TopicBar: View {
    @Environment(AppModel.self) private var model
    let chat: Chat

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(id: nil, title: L("Все"), unread: chat.unread)
                ForEach(model.topics) { topic in
                    chip(id: topic.id, title: topic.name, unread: topic.unread, closed: topic.isClosed,
                         color: topic.color, note: topic.snippet)
                }
                if model.chatAccess.canManageTopics {
                    Button { create() } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 26, height: 26)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(PressDimStyle())
                    .help(L("Новая тема"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .hidingEnclosingScrollBars()
        }
        .scrollIndicators(.hidden)
    }

    private func chip(id: Int32?, title: String, unread: Int, closed: Bool = false, color: Int = 0, note: String = "") -> some View {
        let chosen = model.openTopicId == id
        return Button {
            Task { await model.open(topic: id) }
        } label: {
            HStack(spacing: 5) {
                if color != 0 {
                    Circle()
                        .fill(Color(red: Double((color >> 16) & 0xFF) / 255, green: Double((color >> 8) & 0xFF) / 255,
                                    blue: Double(color & 0xFF) / 255))
                        .frame(width: 6, height: 6)
                }
                if closed {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                }
                Text(title.isEmpty ? L("Без названия") : title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(chosen ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(Color.brand),
                                    in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(chosen ? AnyShapeStyle(Color.brand) : AnyShapeStyle(Color.primary.opacity(0.1)), in: Capsule())
            .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(PressDimStyle())
        .help(note.isEmpty ? L("Показать только «\(title)»") : "«\(title)»: \(note)")
        .contextMenu {
            if let id, let topic = model.topics.first(where: { $0.id == id }) {
                Button(L("Скопировать ссылку на тему"), systemImage: "link") {
                    Task { await model.copyTopicLink(topic, in: chat.id) }
                }
                if model.chatAccess.canManageTopics {
                    Button(L("Переименовать тему…"), systemImage: "pencil") { rename(topic) }
                    Button(topic.isClosed ? L("Открыть тему") : L("Закрыть тему"),
                           systemImage: topic.isClosed ? "lock.open" : "lock") {
                        Task { await model.setTopic(topic, in: chat.id, closed: !topic.isClosed) }
                    }
                }
            }
        }
    }

    private func rename(_ topic: Topic) {
        guard let name = Dialogs.prompt(L("Переименовать тему"), hint: L("Как назвать тему «\(topic.name)»?")) else { return }
        Task { await model.renameTopic(topic, in: chat.id, to: name) }
    }

    private func create() {
        guard let name = Dialogs.prompt(L("Новая тема"), hint: L("Название можно оставить пустым: Telegram назовёт её по первому сообщению.")) else { return }
        Task { await model.createTopic(in: chat.id, name: name) }
    }
}

private struct PinnedBar: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        Button {
            Task { await model.jump(to: message.id) }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.brand)
                    .frame(width: 2, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Закреплённое сообщение"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandInk)
                    Text(TD.preview(of: message))
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "pin.fill")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressDimStyle())
        // A card, not a capsule: it carries two lines of text, and a capsule cuts their descenders at the ends.
        .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .help(L("Показать закреплённое сообщение"))
    }
}

/// "Новые сообщения" above the first message that was unread when the chat opened.
struct UnreadSeparator: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.brand.opacity(0.3)).frame(height: 1)
            Text(L("Новые сообщения"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brandInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.brand.opacity(0.12), in: Capsule())
                .fixedSize()
            Rectangle().fill(Color.brand.opacity(0.3)).frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

struct DayHeader: View {
    @Environment(AppModel.self) private var model
    let date: Date
    @State private var picksDate = false
    @State private var picked = Date()

    var body: some View {
        Button {
            picked = date
            picksDate = true
        } label: {
            // A drop of glass on the ground: it floats over the bubbles that scroll under it.
            Text(date.daySeparator)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .glassSurface(in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressDimStyle())
        .help(L("Перейти к дате"))
        // Like Telegram: the date opens a calendar, and a chosen day brings its messages.
        .popover(isPresented: $picksDate, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                DatePicker("", selection: $picked, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.locale, Loc.locale)
                HStack {
                    Button(L("Сегодня")) {
                        picksDate = false
                        Task { await model.showLatest() }
                    }
                    Spacer()
                    Button(L("Перейти")) {
                        picksDate = false
                        let day = picked
                        Task { await model.jump(toDay: day) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}

/// A rounded bubble whose corner by the sender flattens into a small "tail" on the last message of a run,
/// the way Messages draws them.
struct BubbleShape: Shape {
    let isOutgoing: Bool
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(19, rect.height / 2)
        let tail: CGFloat = hasTail ? 5 : radius
        return UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: isOutgoing ? radius : tail,
            bottomTrailingRadius: isOutgoing ? tail : radius,
            topTrailingRadius: radius,
            style: .continuous
        ).path(in: rect)
    }
}
