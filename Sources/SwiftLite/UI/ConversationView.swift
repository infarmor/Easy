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
                if model.openChatIsForum {
                    TopicBar(chat: chat)
                        .transition(.opacity)
                }
                if let pinned = model.pinnedMessage {
                    PinnedBar(message: pinned)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // The bars above the transcript slide in from under the toolbar instead of appearing in place.
            .animation(.smooth(duration: 0.22), value: model.isSearching)
            .animation(.smooth(duration: 0.22), value: model.pinnedMessage?.id)
            .animation(.smooth(duration: 0.22), value: model.openChatIsForum)
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
                    withAnimation(.smooth(duration: 0.2)) { position.scrollTo(edge: .bottom) }
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
                        withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(model.viewId(ofMessage: target), anchor: .center) }
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
                                withAnimation(.smooth(duration: 0.2)) { position.scrollTo(edge: .bottom) }
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
                    .animation(.spring(duration: 0.28, bounce: 0.25), value: isNearBottom)
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
        .animation(.smooth(duration: 0.2), value: model.toast)
        .animation(.spring(duration: 0.3, bounce: 0.12), value: model.viewerMessage?.id)
        // Links in messages: t.me stays in the app, suspicious addresses are explained before they open.
        .environment(\.openURL, OpenURLAction { url in
            Task { await model.openMessageLink(url) }
            return .handled
        })
        .background {
            Button("") { withAnimation(.smooth(duration: 0.15)) { model.escape() } }
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
        .buttonStyle(.plain)
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

/// The card under a message with a link, as in the official clients; a click opens the page.
private struct LinkPreviewCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.bubbleAccent) private var accent
    let preview: LinkPreview

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.siteName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                if !preview.title.isEmpty {
                    Text(preview.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                }
                if !preview.description.isEmpty {
                    Text(preview.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if let photo = preview.photo {
                Poster(media: photo, size: CGSize(width: 54, height: 54), fileId: photo.fileId, previewFileId: photo.previewFileId)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { openURL(preview.url) }
        .help(preview.url.absoluteString)
    }
}

/// The translation of a message, under its own text. Told apart from the original by the language line.
private struct TranslationCard: View {
    @Environment(\.bubbleAccent) private var accent
    let translation: AppModel.Translation
    let fontSize: Double
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.subheadline)
                Text(AppModel.languageName(translation.languageCode))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button(action: hide) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(L("Скрыть перевод"))
            }
            .foregroundStyle(accent)
            Text(formattedText(translation.text, translation.entities))
                .font(.system(size: fontSize))
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
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
                    .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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

/// The little a message row needs from its chat. Typing, presence and unread counts change the chat
/// constantly; passing only these keeps every visible message from redrawing on each of those updates.
struct RowChat: Equatable {
    let id: Int64
    let kind: ChatKind
    let lastReadOutboxId: Int64

    init(_ chat: Chat) {
        id = chat.id
        kind = chat.kind
        lastReadOutboxId = chat.lastReadOutboxId
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Preferences.messageFontSize) private var messageFontSize = 14
    @AppStorage(Preferences.chatBackground) private var chatBackground = ChatBackground.glass.rawValue
    @AppStorage(Preferences.showMessageCode) private var showsCode = false
    @AppStorage(Preferences.showIdentifiers) private var showsIdentifiers = false
    @AppStorage(Preferences.securityTools) private var securityTools = true
    @AppStorage(Preferences.markLocalEdits) private var marksLocalEdits = false
    // Read so the row is drawn again when either setting changes; `AdFilter` reads the values itself.
    @AppStorage(Preferences.hideAds) private var hidesAds = true
    @AppStorage(Preferences.filterWords) private var filterWords = ""
    /// A message the filter folded away, shown after all because it was asked for.
    @State private var isRevealed = false

    let row: TranscriptRow
    let chat: RowChat
    /// Width of the bubble, which the keyboard under it follows.
    @State private var contentWidth: CGFloat = 0
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A message that has just arrived grows out of the corner its tail points to; this says it has done so.
    @State private var hasSettled = false
    /// Bumped when this row's custom emoji have been decoded, so the text and reactions are drawn again.
    @State private var emojiRound = 0

    private var message: Message { row.message }

    private var hiddenReason: AdFilter.Reason? {
        guard hidesAds || !filterWords.isEmpty else { return nil }
        return AdFilter.reason(for: message, in: chat.kind)
    }

    var body: some View {
        if case .service(let text) = message.body {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else if !isRevealed, !model.isSelectingMessages, let reason = hiddenReason {
            // Folded, not removed: the post is one click away, and the transcript keeps its place.
            Button {
                withAnimation(.smooth(duration: 0.2)) { isRevealed = true }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                    Text(reason == .advertisement ? L("Реклама скрыта") : L("Скрыто фильтром"))
                    Text(L("Показать")).foregroundStyle(Color.brandInk)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .glassSurface(in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressDimStyle())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if model.isSelectingMessages {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.brandInk) : AnyShapeStyle(.tertiary))
                        .padding(.bottom, 4)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if message.isOutgoing {
                    Spacer(minLength: 60)
                } else if showsSenders {
                    senderSlot
                }
                bubble
                    // Beside the bubble, outside its frame: pinned to the bubble's edge and moved out by their own
                    // known width, so they never cover the bubble and never move the layout.
                    .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
                        if isHovered, showsHoverActions {
                            hoverActions
                                .frame(width: Self.hoverActionsWidth)
                                .offset(x: message.isOutgoing ? -(Self.hoverActionsWidth + 8) : Self.hoverActionsWidth + 8)
                                .transition(.opacity)
                        }
                    }
                if !message.isOutgoing {
                    Spacer(minLength: 60)
                }
            }
            .scaleEffect(arrives && !hasSettled ? 0.86 : 1, anchor: message.isOutgoing ? .bottomTrailing : .bottomLeading)
            .opacity(arrives && !hasSettled ? 0 : 1)
            .onAppear {
                guard !hasSettled else { return }
                if arrives {
                    withAnimation(.spring(duration: 0.34, bounce: 0.3)) { hasSettled = true }
                } else {
                    hasSettled = true
                }
            }
            // The whole width of the row counts, empty side included: on the way from the bubble to its
            // buttons the pointer crosses the gap between them, and without this the buttons faded first.
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(.smooth(duration: 0.12)) { isHovered = inside }
            }
            // While picking messages a click anywhere on the row picks it, instead of opening media or links.
            .overlay {
                if model.isSelectingMessages {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggleSelection(of: message) }
                }
            }
            .animation(.smooth(duration: 0.15), value: model.isSelectingMessages)
            // Messages of one run sit close together; runs are set apart.
            .padding(.top, row.showsSender ? 8 : 1.5)
            .padding(.bottom, row.endsGroup ? 6 : 1.5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.brand.opacity(0.1))
                        .padding(.horizontal, -8)
                } else if model.highlightedMessageId == message.id {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.brand.opacity(0.12))
                        .padding(.horizontal, -8)
                }
            }
            .animation(.smooth(duration: 0.3), value: model.highlightedMessageId == message.id)
        }
    }

    /// Whether this row is a message coming in right now, as opposed to history being laid out. Yours counts
    /// while it is being sent; the copy that replaces it once the server has it is the same message to the
    /// eye and must not jump a second time.
    private var arrives: Bool {
        guard !reduceMotion else { return false }
        return message.isPending || (!message.isOutgoing && abs(message.date.timeIntervalSinceNow) < 2)
    }

    /// Three 26-point buttons, 2 points apart, 3 points of padding on each side.
    private static let hoverActionsWidth: CGFloat = 3 * 26 + 2 * 2 + 2 * 3

    private var showsHoverActions: Bool {
        !model.isSelectingMessages && message.isSent && !message.isDeleted && !message.isService
    }

    /// Reply, a quick 👍 and forward, like the hover buttons of Telegram Desktop and Messages.
    private var hoverActions: some View {
        HStack(spacing: 2) {
            hoverButton("arrowshape.turn.up.left", help: L("Ответить")) { model.beginReply(to: message) }
            Button {
                Task { await model.toggleReaction(AppModel.quickReactions[0], on: message) }
            } label: {
                Text(AppModel.quickReactions[0]).font(.body).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(L("Поставить \(AppModel.quickReactions[0])"))
            .accessibilityLabel(L("Поставить реакцию"))
            hoverButton("arrowshape.turn.up.right", help: L("Переслать")) {
                model.prepareForwarding([message])
            }
        }
        .padding(.horizontal, 3)
        .glassSurface(in: Capsule(), interactive: true)
        .fixedSize()
    }

    private func hoverButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    /// Custom emoji of the text and of the reactions under it.
    private var customEmojiIds: [Int64] {
        CustomEmoji.ids(in: message.entities) + message.reactions.compactMap { $0.customEmojiId != 0 ? $0.customEmojiId : nil }
    }

    private func loadCustomEmoji() async {
        if await CustomEmoji.load(customEmojiIds, with: model) { emojiRound += 1 }
    }

    private var isSelected: Bool {
        model.isSelectingMessages && model.selectedMessageIds.contains(message.id)
    }

    /// Only groups have several authors; private chats and channels speak with one voice.
    private var showsSenders: Bool {
        chat.kind == .group || chat.kind == .other
    }

    /// The avatar stands next to the last message of a run, where the tail points.
    @ViewBuilder
    private var senderSlot: some View {
        if row.endsGroup {
            Avatar(title: senderName, seed: seed, photo: model.photo(for: message), diameter: 30)
                .onTapGesture { Task { await model.showProfile(ofSender: message) } }
                .help(L("Профиль"))
                .padding(.bottom, showsStatus ? 16 : 0)
        } else {
            Color.clear.frame(width: 30, height: 1)
        }
    }

    /// Buttons a bot attached under this message.
    private var inlineRows: [[BotButton]]? {
        guard let markup = message.markup, markup.kind == .inline, !markup.rows.isEmpty else { return nil }
        return markup.rows
    }

    /// Surfaces that draw themselves — a sticker, a round video note, an album grid, a bare photo, a message
    /// that is only emoji — have no bubble to hold the author and the time, so those stay outside them.
    /// Everything else carries them inside, the way Telegram does.
    private var carriesOwnSurface: Bool {
        message.sticker != nil || message.media?.kind == .videoNote || row.album.count > 1
            || bigEmoji != nil || (message.media != nil && isBareMedia)
    }

    @ViewBuilder
    private var mainContent: some View {
        if carriesOwnSurface {
            ownSurface
        } else {
            bubbleBody
        }
    }

    @ViewBuilder
    private var ownSurface: some View {
        if let sticker = message.sticker {
            StickerView(sticker: sticker)
        } else if let media = message.media, media.kind == .videoNote {
            MediaView(message: message, media: media)
        } else if row.album.count > 1 {
            albumBody
        } else if let emoji = bigEmoji {
            Text(emoji)
                .font(.system(size: 44))
                .textSelection(.enabled)
        } else if let media = message.media, isBareMedia {
            // A photo or video without words is shown on its own, like in Messages, with the time on it.
            MediaView(message: message, media: media)
                .overlay { failureOutline(radius: 16) }
                .overlay(alignment: .bottomTrailing) {
                    if timeOnMedia { mediaTimeBadge }
                }
        }
    }

    private var bubble: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
            // Above the bubble, as Messages names the author in a group.
            if row.showsSender, !message.isOutgoing, showsSenders {
                senderLine.padding(.leading, 12)
            }
            if let rows = inlineRows {
                mainContent
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                InlineKeyboard(message: message, rows: rows)
                    .frame(width: max(contentWidth, 240))
            } else {
                mainContent
            }
            if !message.reactions.isEmpty {
                reactionsRow
            }
            // Under the bubble rather than in it: "Доставлено 14:32" is about the bubble, not part of what
            // was said.
            if showsStatus {
                statusLine
                    .padding(.horizontal, 6)
            }
        }
        .opacity(message.isDeleted ? 0.7 : 1)
        .contextMenu { menu }
        .task(id: message.replyToId) { await model.loadRepliedMessage(for: message) }
        .task(id: customEmojiIds) { await loadCustomEmoji() }
    }

    /// An album: the grid, with the one caption the album has (Telegram puts it on one of the photos).
    private var albumBody: some View {
        let caption = row.album.first { !$0.caption.isEmpty }
        return BubbleStack(spacing: 6) {
            AlbumView(messages: row.album)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .layoutValue(key: BubblePartKey.self, value: .media)
            if let caption {
                Text(formattedText(caption.caption, caption.entities))
                    .font(.system(size: Double(messageFontSize)))
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
            }
        }
        .padding(caption == nil ? 0 : 4)
        .bubbleInk(isOutgoing: message.isOutgoing && caption != nil)
        .background(caption == nil ? AnyShapeStyle(Color.clear) : bubbleColor, in: BubbleShape(isOutgoing: message.isOutgoing, hasTail: row.endsGroup))
    }

    private var bigEmoji: String? {
        guard case .text(let text) = message.body, message.media == nil, message.sticker == nil, !message.isForwarded,
              message.replyToId == 0, message.foreignReply == nil, message.linkPreview == nil, message.entities.isEmpty,
              text.isBigEmoji else { return nil }
        return text
    }

    /// Photos, videos and GIFs without a caption carry their time in a plaque on the picture.
    private var timeOnMedia: Bool {
        guard let kind = message.media?.kind, isBareMedia else { return false }
        return kind == .photo || kind == .video || kind == .animation
    }

    private var mediaTimeBadge: some View {
        HStack(spacing: 3) {
            Text(message.date.timeStamp)
            if message.isOutgoing, message.isSent {
                Text(isRead ? "✓✓" : "✓")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(7)
        .allowsHitTesting(false)
    }

    private var isBareMedia: Bool {
        message.media?.kind != .voiceNote && message.caption.isEmpty && !message.isForwarded && message.replyToId == 0
            && message.foreignReply == nil
    }

    /// Time and delivery show once per run; anything unusual about a message shows on it directly.
    private var showsStatus: Bool {
        (row.endsGroup && !timeOnMedia) || message.isPending || message.isFailed || message.isDeleted || message.isPinned
            || message.isEdited || message.hasEditHistory || showsIdentifiers || (marksLocalEdits && message.localText != nil)
    }

    private var bubbleBody: some View {
        BubbleStack(spacing: 4) {
            if message.isForwarded {
                Label(forwardName.map { L("Переслано от \($0)") } ?? L("Переслано"), systemImage: "arrowshape.turn.up.right")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(message.isOutgoing ? Color.white : Color.brandInk)
            }
            if let replied = row.reply {
                ReplyQuote(
                    name: model.name(for: replied),
                    text: TD.preview(of: replied),
                    tint: message.isOutgoing ? .white : Palette.tint(for: Self.seed(of: replied, in: chat)),
                    textStyle: secondaryInk
                ) {
                    Task { await model.jump(to: replied.id) }
                }
                .layoutValue(key: BubblePartKey.self, value: .fill)
            } else if let foreign = message.foreignReply {
                // The quote of a message from another chat; a click goes there when the chat is in reach.
                ReplyQuote(
                    name: foreignName(foreign),
                    text: foreign.text,
                    tint: message.isOutgoing ? .white : Color.brandInk,
                    textStyle: secondaryInk
                ) {
                    model.open(foreign)
                }
                .layoutValue(key: BubblePartKey.self, value: .fill)
            }
            if let poll = message.poll {
                PollView(message: message, poll: poll)
            } else if let location = message.location {
                LocationCard(location: location)
                    .layoutValue(key: BubblePartKey.self, value: .fill)
                if !message.caption.isEmpty {
                    messageText(message.caption)
                }
            } else if let contact = message.contact {
                ContactCard(contact: contact)
                    .layoutValue(key: BubblePartKey.self, value: .fill)
            } else if let dice = message.dice {
                DiceView(dice: dice)
            } else if let document = message.document {
                DocumentView(message: message, document: document)
                if !message.caption.isEmpty {
                    messageText(message.caption)
                }
            } else if let media = message.media {
                MediaView(message: message, media: media)
                    .padding(.horizontal, -6)
                    .padding(.top, message.isForwarded || message.replyToId != 0 ? 0 : -4)
                    .layoutValue(key: BubblePartKey.self, value: .media)
                if !message.caption.isEmpty {
                    messageText(message.caption)
                }
            } else {
                content
            }
            if let translation = model.translation(of: message) {
                TranslationCard(translation: translation, fontSize: Double(messageFontSize)) {
                    model.hideTranslation(of: message)
                }
                .layoutValue(key: BubblePartKey.self, value: .fill)
            } else if model.isTranslating(message) {
                Label(L("Перевод…"), systemImage: "globe")
                    .font(.system(size: Double(messageFontSize - 1)))
                    .foregroundStyle(.secondary)
            }
            if let preview = message.linkPreview {
                LinkPreviewCard(preview: preview)
                    .layoutValue(key: BubblePartKey.self, value: .fill)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .bubbleInk(isOutgoing: message.isOutgoing)
        .background(bubbleColor, in: BubbleShape(isOutgoing: message.isOutgoing, hasTail: row.endsGroup))
        .overlay { failureOutline(radius: 18) }
    }

    @ViewBuilder
    private func failureOutline(radius: CGFloat) -> some View {
        if message.isFailed || message.isDeleted {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.red.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: message.isDeleted ? [4] : []))
        }
    }

    private var secondaryInk: AnyShapeStyle {
        AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch message.body {
        case .text(let text):
            messageText(text)
        case .attachment(let name):
            Label(name, systemImage: "doc.fill")
                .font(.system(size: Double(messageFontSize)))
        case .unsupported(let name):
            Label(name, systemImage: "questionmark.square.dashed")
                .font(.system(size: Double(messageFontSize - 1)))
                .foregroundStyle(secondaryInk)
        case .service(let text):
            Text(text)
                .font(.system(size: Double(messageFontSize)))
        }
    }

    /// A local edit replaces the words (its own, without the original formatting).
    private func messageText(_ text: String) -> some View {
        let shown = message.localText ?? text
        let entities = message.localText == nil ? message.entities : []
        // Plain text, most messages, is drawn as is: wrapping it in an AttributedString copied it on every redraw.
        // `emojiRound` is read so the text is drawn again once this row's custom emoji have been decoded.
        let pictured = emojiRound >= 0 && !customEmojiIds.isEmpty
            ? CustomEmoji.text(shown, entities, fontSize: Double(messageFontSize)) : nil
        let words: Text = pictured ?? (entities.isEmpty ? Text(verbatim: shown) : Text(formattedText(shown, entities)))
        return words
            .font(.system(size: Double(messageFontSize)))
            .lineSpacing(1.5)
            .textSelection(.enabled)
    }

    /// Reactions as small capsules; yours are tinted, and a click adds or takes back your own.
    private var reactionsRow: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions, id: \.key) { reaction in
                Button {
                    Task { await model.toggleReaction(reaction.emoji, customEmojiId: reaction.customEmojiId, on: message) }
                } label: {
                    HStack(spacing: 3) {
                        if reaction.customEmojiId == 0 {
                            Text(reaction.emoji).font(.callout)
                        } else if emojiRound >= 0, let picture = CustomEmoji.image(reaction.customEmojiId, side: 16) {
                            Image(nsImage: picture)
                        } else {
                            // Until its picture arrives the capsule keeps its shape.
                            Color.clear.frame(width: 16, height: 16)
                        }
                        Text(reaction.count.formatted(.number.notation(.compactName)))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(reaction.count)))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        reaction.isChosen ? AnyShapeStyle(Color.brand.opacity(0.25)) : AnyShapeStyle(Color.primary.opacity(0.07)),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(reaction.isChosen ? Color.brand.opacity(0.6) : .clear))
                }
                .buttonStyle(.plain)
                .help(reaction.isChosen ? L("Убрать реакцию") : reaction.emoji.isEmpty ? L("Поставить такую же") : L("Поставить \(reaction.emoji)"))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        // A reaction lands with a little bounce, and the others make room for it.
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.38), value: message.reactions)
    }

    /// The author's name in their own colour: inside the bubble where there is one, above the surface where
    /// there is not.
    @ViewBuilder
    private var senderLine: some View {
        if !message.isOutgoing, showsSenders {
            HStack(spacing: 3) {
                Text(senderName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                NameBadgeView(key: message.senderKey, size: 13)
            }
            .onTapGesture { Task { await model.showProfile(ofSender: message) } }
        }
    }

    /// Under the last message of a run: "Прочитано 14:32" for your own, the time for others'.
    private var statusLine: some View {
        HStack(spacing: 4) {
            if message.isDeleted {
                Label(L("удалено"), systemImage: "trash")
                    .foregroundStyle(.red)
            } else if message.isEdited || message.hasEditHistory {
                Text(L("изменено"))
            }
            if marksLocalEdits, message.localText != nil {
                Label(L("изменено локально"), systemImage: "pencil.and.outline")
                    .foregroundStyle(.orange)
                    .help(L("Текст изменён только на этом Mac. На сервере и у собеседника он прежний."))
            }
            if message.isPinned {
                Image(systemName: "pin.fill")
            }
            if message.isOutgoing {
                delivery
            }
            if message.viewCount > 0 {
                Label(message.viewCount.formatted(.number.notation(.compactName)), systemImage: "eye")
                    .help(L("Просмотры"))
            }
            Text(message.date.timeStamp)
            if showsIdentifiers {
                Text("· id \(String(message.id))")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var delivery: some View {
        if message.isPending {
            Label(L("Отправка"), systemImage: "clock")
        } else if message.isFailed {
            Label(L("Не отправлено"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if !message.isDeleted {
            Text(isRead ? L("Прочитано") : L("Доставлено"))
        }
    }

    @ViewBuilder
    private var menu: some View {
        // Grouped like the system's menus: talk, the text itself, the file, the author, your own tools, delete.
        if message.isSent, !message.isDeleted {
            Button(L("Ответить"), systemImage: "arrowshape.turn.up.left") { model.beginReply(to: message) }
            Menu(L("Реакция"), systemImage: "face.smiling") {
                ForEach(AppModel.quickReactions, id: \.self) { emoji in
                    Button(emoji) { Task { await model.toggleReaction(emoji, on: message) } }
                }
            }
            Button(row.album.count > 1 ? L("Переслать альбом…") : L("Переслать…"), systemImage: "arrowshape.turn.up.right") {
                model.prepareForwarding([message])
            }
            Button(L("В Избранное"), systemImage: "bookmark") { Task { await model.saveToSavedMessages(message) } }
            Button(L("Выбрать"), systemImage: "checkmark.circle") { model.beginSelection(with: message) }
            Divider()
        }
        if model.canEdit(message) {
            Button(L("Изменить"), systemImage: "pencil") { Task { await model.beginEdit(message) } }
        }
        Button(L("Скопировать текст"), systemImage: "doc.on.doc") { copyText() }
        if !message.isDeleted, model.canTranslate(message) {
            if model.translation(of: message) != nil {
                Button(L("Скрыть перевод"), systemImage: "globe") { model.hideTranslation(of: message) }
            } else {
                Button(L("Перевести"), systemImage: "globe") { Task { await model.translate(message) } }
            }
        }
        if message.isSent, !message.isDeleted {
            Button(message.isPinned ? L("Открепить") : L("Закрепить"), systemImage: message.isPinned ? "pin.slash" : "pin") {
                Task { await model.togglePin(message) }
            }
        }
        if message.isFailed {
            Button(L("Отправить ещё раз"), systemImage: "arrow.clockwise") { Task { await model.resend(message) } }
        }
        if message.isSent, !message.isDeleted, chat.kind == .group || chat.kind == .channel {
            Button(L("Скопировать ссылку на сообщение"), systemImage: "link") { Task { await model.copyLink(to: message) } }
        }
        if message.attachment != nil, !message.isDeleted {
            Divider()
            if message.media?.kind == .photo {
                Button(L("Скопировать фото"), systemImage: "photo.on.rectangle") { Task { await model.copyPhoto(of: message) } }
            }
            Button(L("Открыть вложение"), systemImage: "arrow.up.forward.app") { Task { await model.openAttachment(of: message) } }
            Button(L("Сохранить вложение…"), systemImage: "square.and.arrow.down") { saveAttachment() }
        }
        Divider()
        if !message.senderKey.isEmpty {
            Button(message.isOutgoing ? L("Мой профиль") : L("Профиль отправителя"), systemImage: "person.crop.circle") {
                Task { await model.showProfile(ofSender: message) }
            }
        }
        if message.hasEditHistory {
            Button(L("История изменений…"), systemImage: "clock.arrow.circlepath") { model.showEditHistory(of: message) }
        }
        if !message.isService, message.sticker == nil {
            Button(L("Изменить локально…"), systemImage: "square.and.pencil") {
                if let text = Dialogs.editLocally(message.localText ?? MessageArchive.text(of: message)) {
                    model.setLocalText(text, of: message)
                }
            }
            if message.localText != nil {
                Button(L("Вернуть оригинал"), systemImage: "arrow.uturn.backward") { model.setLocalText(nil, of: message) }
            }
        }
        if securityTools {
            Menu(L("Безопасность"), systemImage: "lock.shield") {
                Button(L("Индикаторы (IOC)…"), systemImage: "list.bullet.rectangle") { model.showIndicators(in: [message]) }
                if message.attachment != nil || message.media != nil, !message.isDeleted {
                    Button(L("SHA-256 файла…"), systemImage: "number") { Task { await model.showHash(of: message) } }
                }
                Button(L("Скопировать обезвреженным"), systemImage: "link.badge.plus") {
                    copy(SecurityTools.defang(MessageArchive.text(of: message)))
                }
            }
        }
        if showsCode, !message.isDeleted {
            Button(L("Код сообщения…"), systemImage: "curlybraces") { Task { await model.inspect(message) } }
        }
        if showsIdentifiers {
            Button(L("Скопировать ID сообщения"), systemImage: "number.square") { copy(String(message.id)) }
        }
        Divider()
        if message.isDeleted {
            Button(L("Убрать из сохранённых"), systemImage: "trash", role: .destructive) {
                Task { await model.delete(message, forEveryone: false) }
            }
        } else {
            Button(row.album.count > 1 ? L("Удалить альбом…") : L("Удалить…"), systemImage: "trash", role: .destructive) { deleteMessage() }
        }
    }

    private var isRead: Bool {
        chat.lastReadOutboxId > 0 && message.id <= chat.lastReadOutboxId
    }

    /// The two bubbles of Messages: the accent colour for yours, lit from above the way Messages lights its
    /// own; a quiet grey for theirs, or white where the ground is grey.
    private var bubbleColor: AnyShapeStyle {
        if message.isOutgoing {
            return AnyShapeStyle(LinearGradient(
                colors: [Color.brand.mix(with: .white, by: 0.16), Color.brand.mix(with: .black, by: 0.04)],
                startPoint: .top, endPoint: .bottom))
        }
        if colorScheme == .dark { return AnyShapeStyle(Color(white: 0.23)) }
        // The glass and the indigo wash are grounds with a tone of their own, and a grey bubble sinks into
        // them; there theirs are white. Only the flat white ground keeps the grey.
        return AnyShapeStyle(chatBackground == ChatBackground.plain.rawValue ? Color(white: 0.915) : Color.white)
    }

    private var senderName: String {
        model.name(for: message)
    }

    /// The author's name, the name a hidden author chose, or nil when the origin chat is out of reach.
    private var forwardName: String? {
        if let name = model.senderNames[message.forwardSenderKey], !name.isEmpty { return name }
        return message.forwardSenderName.isEmpty ? nil : message.forwardSenderName
    }

    private func foreignName(_ reply: ForeignReply) -> String {
        if let name = model.senderNames[reply.senderKey], !name.isEmpty { return name }
        return reply.senderName.isEmpty ? L("Из другого чата") : reply.senderName
    }

    private var seed: Int64 {
        Self.seed(of: message, in: chat)
    }

    static func seed(of message: Message, in chat: RowChat) -> Int64 {
        if message.isOutgoing { return chat.id }
        return Int64(message.senderKey.unicodeScalars.reduce(7) { $0 + Int($1.value) })
    }

    private func copyText() {
        copy(MessageArchive.text(of: message))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveAttachment() {
        guard let attachment = message.attachment,
              let destination = Dialogs.saveLocation(suggestedName: attachment.name) else { return }
        Task { await model.saveAttachment(of: message, to: destination) }
    }

    private func deleteMessage() {
        Task {
            guard let options = await model.deletionOptions(for: message),
                  let forEveryone = Dialogs.confirmDeletion(options) else { return }
            await model.delete(message, forEveryone: forEveryone)
        }
    }
}

/// The quoted message at the top of a reply; a click scrolls to it.
/// What a part of a bubble does to its width.
private enum BubblePart {
    /// Text: as wide as it needs, wrapping at the column's width.
    case text
    /// The reply quote or a link card: stretches to the bubble's width but does not widen it (much).
    case fill
    /// A photo, video or album grid: the bubble is exactly as wide, and a caption wraps under it.
    case media
}

private struct BubblePartKey: LayoutValueKey {
    static let defaultValue = BubblePart.text
}

/// A bubble's column: text and media decide the width, up to a comfortable reading measure; quotes and
/// cards follow it. A plain VStack would let a quote with a spacer stretch the bubble across the window.
private struct BubbleStack: Layout {
    var spacing: CGFloat = 4
    /// Lines longer than this are hard to read; the official apps stop about here too.
    var maxWidth: CGFloat = 520
    /// How far a quote alone may widen a short message.
    var fillerWidth: CGFloat = 260

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = columnWidth(proposal, subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let width = subview[BubblePartKey.self] == .text ? min(size.width, bounds.width) : bounds.width
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: width, height: size.height))
            y += size.height + spacing
        }
    }

    private func columnWidth(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let limit = min(proposal.width ?? maxWidth, maxWidth)
        // A picture has its own size; words around it follow it instead of stretching the bubble past it.
        let media = subviews.filter { $0[BubblePartKey.self] == .media }.map { $0.sizeThatFits(.unspecified).width }
        if let widest = media.max(), widest > 0 { return min(widest, limit) }
        var width: CGFloat = 0
        for subview in subviews {
            if subview[BubblePartKey.self] == .fill {
                width = max(width, min(subview.sizeThatFits(.unspecified).width, fillerWidth, limit))
            } else {
                width = max(width, min(subview.sizeThatFits(ProposedViewSize(width: limit, height: nil)).width, limit))
            }
        }
        return width
    }
}

private struct ReplyQuote: View {
    let name: String
    let text: String
    let tint: Color
    let textStyle: AnyShapeStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(textStyle)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.trailing, 8)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Перейти к сообщению"))
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountHub.self) private var hub: AccountHub?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recorder = VoiceRecorder()
    @State private var showsStickers = false
    @State private var showsSchedule = false
    @State private var showsScheduled = false
    @State private var showsLocation = false
    /// The caret or the selected words of the field, which the formatting commands wrap.
    @State private var selection: TextSelection?
    @AppStorage(Preferences.sendWithCommandReturn) private var sendsWithCommandReturn = false

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            if let context = model.composerContext {
                ComposerContextBar(context: context)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    // Rises out of the field it belongs to.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !model.suggestions.isEmpty, !needsStart {
                SuggestionList(suggestions: model.suggestions)
            }
            if needsStart {
                Button {
                    Task { await model.startBot() }
                } label: {
                    Text(L("Запустить"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(.white)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            } else {
                inputRow
            }
            if let keyboard = model.replyKeyboard, model.isReplyKeyboardShown, !needsStart {
                ReplyKeyboardPanel(markup: keyboard)
            }
        }
        .animation(.smooth(duration: 0.18), value: model.isReplyKeyboardShown)
        .animation(.smooth(duration: 0.18), value: model.replyKeyboard)
        .animation(.smooth(duration: 0.15), value: model.suggestions)
        .animation(.smooth(duration: 0.2), value: model.composerContext)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .onChange(of: model.composerContext) { _, context in
            if context != nil { focused = true }
        }
        // A sent or cleared message leaves no text for the old selection to point into.
        .onChange(of: model.draft.isEmpty) { _, isEmpty in
            if isEmpty { selection = nil }
        }
        .onChange(of: selection) { _, _ in
            let has = selectedRange.map { !$0.isEmpty } ?? false
            if model.composerHasSelection != has { model.composerHasSelection = has }
        }
        .onChange(of: model.formatRequest) { _, request in
            guard let request else { return }
            model.formatRequest = nil
            apply(request.format)
        }
        // Asked for before this chat's composer existed, or while it was already on screen.
        .onAppear { takeFocusIfAsked() }
        .onChange(of: model.wantsComposerFocus) { _, _ in takeFocusIfAsked() }
        // Leaving the chat mid-recording drops the recording instead of leaving the microphone on.
        .onDisappear { if recorder.isRecording { recorder.cancel() } }
        // ⌘V with a picture or files copied opens the send sheet; text pastes into the field as usual.
        .background {
            PasteInterceptor(handle: {
                guard AppModel.pasteboardHoldsAttachment() else { return false }
                Task { await model.sendPasteboard() }
                return true
            }, type: { characters in
                // A letter typed while the keyboard is in the chat list or nowhere starts the message: the
                // field takes the letter and the keyboard, with the caret after it.
                guard !needsStart, !model.isSelectingMessages, !recorder.isRecording, model.viewerMessage == nil else { return false }
                model.draft += characters
                focused = true
                let end = TextSelection(insertionPoint: model.draft.endIndex)
                selection = end
                // Again once the field has the keyboard: taking it selects the whole text, and the next
                // letter would replace what was just typed.
                DispatchQueue.main.async { selection = TextSelection(insertionPoint: model.draft.endIndex) }
                return true
            })
        }
    }

    private var openChat: Chat? {
        model.selectedChat
    }

    /// The selected stretch of the draft; empty for a bare caret, nil when the field has never had the keyboard.
    private var selectedRange: Range<String.Index>? {
        guard case .selection(let range)? = selection?.indices,
              range.upperBound <= model.draft.endIndex else { return nil }
        return range
    }

    /// Wraps the selection in a format's marks; without a selection the marks go in at the caret, or at the
    /// end, with the caret left between them.
    private func apply(_ format: TextFormat) {
        let range = selectedRange ?? model.draft.endIndex..<model.draft.endIndex
        let wrapped = format.wrap(model.draft, range)
        model.draft = wrapped.text
        focused = true
        // After the text has reached the field: a selection set first is measured against the old text.
        // And only if it is still that text — positions in a string mean nothing in another one.
        DispatchQueue.main.async {
            if model.draft == wrapped.text { selection = TextSelection(range: wrapped.selection) }
        }
    }

    /// The system's own picker (⌃⌘Space), which types into whatever field has the keyboard.
    private func showEmojiPicker() {
        focused = true
        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
    }

    private func takeFocusIfAsked() {
        guard model.wantsComposerFocus else { return }
        model.wantsComposerFocus = false
        focused = true
    }

    /// A bot you have never written to, or one opened through a start link, waits for "Запустить".
    private var needsStart: Bool {
        guard let chat = openChat, chat.isBot else { return false }
        return model.pendingBotStart != nil || (model.messages.isEmpty && !model.loadingHistory && chat.lastMessageId == 0)
    }

    private var placeholder: String {
        switch openChat?.secretState {
        case .pending: return L("Отправится, когда собеседник появится в сети")
        case .closed: return L("Секретный чат закрыт")
        default: break
        }
        let hint = model.replyKeyboard?.placeholder ?? ""
        if !hint.isEmpty { return hint }
        // With several accounts the field says which of them the message goes from.
        if let hub, hub.accounts.count > 1, !model.accountName.isEmpty { return L("Сообщение от \(model.accountName)") }
        return L("Сообщение")
    }

    private var inputRow: some View {
        @Bindable var model = model
        return HStack(alignment: .bottom, spacing: 10) {
            if recorder.isRecording {
                recordingBar
            } else {
                if let menu = model.botMenu, !menu.appURL.isEmpty || !menu.commands.isEmpty {
                    BotMenuButton(menu: menu)
                }
                Menu {
                    Button(L("Фото и файлы…"), systemImage: "doc.on.doc") { attachFiles() }
                    Button(L("Вставить из буфера"), systemImage: "doc.on.clipboard") { Task { await model.sendPasteboard() } }
                    Divider()
                    Button(L("Стикеры"), systemImage: "face.smiling") { showsStickers = true }
                    Button(L("Эмодзи и символы"), systemImage: "character.cursor.ibeam") { showEmojiPicker() }
                    if model.composerContext?.kind != .edit {
                        Button(L("Голосовое сообщение"), systemImage: "mic") { startRecording() }
                        Divider()
                        Button(L("Кости"), systemImage: "die.face.5") { Task { await model.sendDice("🎲") } }
                        Button(L("Геолокация…"), systemImage: "mappin") { showsLocation = true }
                    }
                } label: {
                    GlassCircleLabel(diameter: 36) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .popover(isPresented: $showsLocation, arrowEdge: .top) {
                    LocationPanel { showsLocation = false }
                }
                .help(L("Файлы, фото, стикеры, голосовые, кости и геолокация. Файлы можно и просто перетащить в чат"))
                .accessibilityLabel(L("Прикрепить"))

                HStack(alignment: .bottom, spacing: 6) {
                    TextField(placeholder, text: $model.draft, selection: $selection, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...8)
                        .focused($focused)
                        .padding(.vertical, 6)
                        .onSubmit {
                            Task { await model.send() }
                        }
                        // The other way round for people who write at length: Return is a new line and
                        // ⌘Return sends. ⌘Return sends in either mode.
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.command) {
                                Task { await model.send() }
                                return .handled
                            }
                            guard sendsWithCommandReturn, press.modifiers.isDisjoint(with: [.option, .shift, .control]) else { return .ignored }
                            let at = selectedRange ?? model.draft.endIndex..<model.draft.endIndex
                            let caret = model.draft.distance(from: model.draft.startIndex, to: at.lowerBound) + 1
                            model.draft.replaceSubrange(at, with: "\n")
                            let written = model.draft
                            DispatchQueue.main.async {
                                guard model.draft == written else { return }
                                selection = TextSelection(insertionPoint: written.index(written.startIndex, offsetBy: caret))
                            }
                            return .handled
                        }
                        .onChange(of: model.draft) { _, _ in
                            model.noteTyping()
                        }
                        // Tab takes the first person or command offered above the field.
                        .onKeyPress(.tab) {
                            guard let first = model.suggestions.first else { return .ignored }
                            Task { await model.accept(first) }
                            return .handled
                        }
                        // ↑ in an empty field edits your last message.
                        .onKeyPress(.upArrow) {
                            guard model.draft.isEmpty, model.composerContext == nil else { return .ignored }
                            Task { await model.editLastMessage() }
                            return .handled
                        }
                        .help((sendsWithCommandReturn ? L("⌘Return — отправить, Return — новая строка") : L("Return — отправить, Option-Return — новая строка"))
                            + L(", ↑ — изменить последнее. ")
                            + L("Выделите слова и нажмите ⌘B, ⌘I или ⌘K, либо пишите разметкой: **жирный**, __курсив__, `код`"))

                    if !model.scheduledMessages.isEmpty {
                        fieldButton("clock", help: L("Отложенные сообщения: \(model.scheduledMessages.count)")) { showsScheduled = true }
                            .popover(isPresented: $showsScheduled, arrowEdge: .top) { ScheduledList() }
                    }
                    if model.replyKeyboard != nil, !canSend {
                        fieldButton(model.isReplyKeyboardShown ? "keyboard.chevron.compact.down" : "keyboard",
                                    help: model.isReplyKeyboardShown ? L("Скрыть клавиатуру бота") : L("Показать клавиатуру бота")) {
                            model.isReplyKeyboardShown.toggle()
                        }
                    }
                    fieldButton("face.smiling", help: L("Стикеры")) { showsStickers.toggle() }
                        .popover(isPresented: $showsStickers, arrowEdge: .top) {
                            StickerPanel { showsStickers = false }
                        }

                    if canSend {
                        Button {
                            Task { await model.send() }
                        } label: {
                            Image(systemName: model.composerContext?.kind == .edit ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 26))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.brand)
                        }
                        .buttonStyle(PressDimStyle())
                        .padding(.bottom, 2)
                        .transition(.scale.combined(with: .opacity))
                        .help(L("Отправить. Правый клик — без звука или по расписанию"))
                        .accessibilityLabel(model.composerContext?.kind == .edit ? L("Сохранить изменения") : L("Отправить"))
                        .contextMenu {
                            if model.composerContext?.kind != .edit {
                                Button(L("Отправить без звука")) { Task { await model.send(silently: true) } }
                                Button(L("Отправить позже…")) { showsSchedule = true }
                            }
                        }
                        .popover(isPresented: $showsSchedule, arrowEdge: .top) {
                            ScheduleSendPicker { date in
                                showsSchedule = false
                                Task { await model.send(at: date) }
                            }
                        }
                    } else if model.composerContext?.kind != .edit {
                        Button {
                            startRecording()
                        } label: {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 28)
                        }
                        .buttonStyle(PressDimStyle())
                        .help(L("Записать голосовое сообщение"))
                        .accessibilityLabel(L("Записать голосовое сообщение"))
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, canSend ? 4 : 10)
                .padding(.vertical, 2)
                .frame(minHeight: 36)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .animation(.smooth(duration: 0.15), value: canSend)
            }
        }
    }

    /// While a voice message records: the time, a pulsing dot, cancel and send.
    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button {
                recorder.cancel()
            } label: {
                GlassCircleLabel(diameter: 36) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(L("Отменить запись"))
            .accessibilityLabel(L("Отменить запись"))
            HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(recorder.level) * 0.6)
                .animation(reduceMotion ? nil : .smooth(duration: 0.08), value: recorder.level)
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                .font(.body.weight(.medium).monospacedDigit())
            Text(L("Запись…"))
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task {
                    guard let recording = await recorder.finish() else {
                        model.showToast(L("Слишком короткое сообщение"))
                        return
                    }
                    await model.sendVoiceNote(at: recording.file, duration: recording.duration, waveform: recording.waveform)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.brand)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .help(L("Отправить голосовое (Return)"))
            .accessibilityLabel(L("Отправить голосовое сообщение"))
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(minHeight: 34)
            .glassSurface(in: Capsule())
        }
    }

    private func startRecording() {
        Task {
            if !(await recorder.start()) {
                model.report(L("Нет доступа к микрофону: разрешите его в Системных настройках → Конфиденциальность → Микрофон."))
            }
        }
    }

    private func fieldButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 28)
        }
        .buttonStyle(PressDimStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private var canSend: Bool {
        // Editing to an empty caption is a valid send, so the button stays up while a message is being edited.
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.composerContext?.kind == .edit
    }

    private func attachFiles() {
        let urls = Dialogs.chooseFiles()
        guard !urls.isEmpty else { return }
        model.offerFiles(urls)
    }
}

/// People to mention or commands to send for the word being typed; a click or Tab takes one.
private struct SuggestionList: View {
    @Environment(AppModel.self) private var model
    let suggestions: [ComposerSuggestion]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    Task { await model.accept(suggestion) }
                } label: {
                    HStack(spacing: 9) {
                        if case .mention = suggestion.kind {
                            Avatar(title: suggestion.title, seed: suggestion.seed, photo: suggestion.photo, diameter: 24)
                        }
                        Text(suggestion.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(suggestion.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if suggestion.id == suggestions.first?.id {
                            Text("Tab")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
            }
        }
        .padding(.vertical, 5)
        .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity)
    }
}

private struct ComposerContextBar: View {
    @Environment(AppModel.self) private var model
    let context: ComposerContext

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: context.kind == .edit ? "pencil" : "arrowshape.turn.up.left")
                .foregroundStyle(Color.brandInk)
            VStack(alignment: .leading, spacing: 1) {
                Text(context.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandInk)
                Text(context.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                model.cancelComposerContext()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Отменить (Esc)"))
        }
    }
}

/// Catches ⌘V in the conversation's window before the text field does. Only the main window: sheets (the
/// caption field of the send sheet) paste as usual. The key is matched by its position, so ⌘V works in the
/// Russian layout too, where the key reads «м».
private struct PasteInterceptor: NSViewRepresentable {
    let handle: () -> Bool
    /// Text typed while no field has the keyboard; true when the composer took it.
    let type: (String) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.type = type
        context.coordinator.install(on: view, handle: handle)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handle = handle
        context.coordinator.type = type
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var handle: () -> Bool = { false }
        var type: (String) -> Bool = { _ in false }
        private var monitor: Any?
        private weak var view: NSView?
        /// kVK_ANSI_V.
        private static let keyV: UInt16 = 9

        func install(on view: NSView, handle: @escaping () -> Bool) {
            self.view = view
            self.handle = handle
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Plain values out of the event first: the event itself is not passed into the main-actor code.
                let isCommandV = event.keyCode == Self.keyV
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                let windowNumber = event.windowNumber
                // Plain typing: no ⌘, ⌃ or ⌥, and something that prints — not an arrow, Tab, Return or Esc.
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let typed = event.characters ?? ""
                let prints = flags.isDisjoint(with: [.command, .control, .option, .function]) && !typed.isEmpty
                    && typed.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
                if prints {
                    let taken = MainActor.assumeIsolated { () -> Bool in
                        guard let self, let window = self.view?.window, window.windowNumber == windowNumber,
                              window.attachedSheet == nil, window.isKeyWindow,
                              // A field that already has the keyboard keeps it: the search, a selected text.
                              !(window.firstResponder is NSText) else { return false }
                        return self.type(typed)
                    }
                    return taken ? nil : event
                }
                guard isCommandV else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.view?.window, window.windowNumber == windowNumber,
                          window.attachedSheet == nil else { return false }
                    return self.handle()
                }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
