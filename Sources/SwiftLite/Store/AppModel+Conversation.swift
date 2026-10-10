import AppKit
import Foundation

/// The open chat: its history, sending, replying, editing, drafts, search and scheduled messages.
extension AppModel {
    // MARK: - conversation

    func select(chatId: Int64) async {
        if selection != chatId { selection = chatId }
        guard openChatId != chatId else {
            // The same chat shown again: only a first load that failed needs another try.
            if messages.isEmpty, !loadingHistory { await loadInitialHistory(chatId) }
            return
        }

        openChatId = chatId
        pendingBotStart = startParameters.removeValue(forKey: chatId)
        draft = knownChats[chatId]?.draftText ?? ""
        draftBaseline = draft
        // Set after the baseline, so it counts as a change and is saved as the chat's draft.
        if let pending = pendingDrafts.removeValue(forKey: chatId) {
            quietDraft = pending
            draft = pending
        }
        lastTypingAt = nil
        // Taken before reading: afterwards the chat no longer knows what was new.
        let lastRead = knownChats[chatId]?.lastReadInboxId ?? 0
        let hadUnread = (knownChats[chatId]?.unread ?? 0) > 0
        // Opening the chat in TDLib and reading its history run side by side: the first page does not wait.
        Task { _ = try? await request(["@type": "openChat", "chat_id": chatId]) }
        Task { await loadMemberCount(of: chatId) }
        Task { await loadPinnedMessage(of: chatId) }
        Task { await loadBotControls(of: chatId) }
        Task { await loadScheduledMessages(of: chatId) }
        await loadInitialHistory(chatId)
        // The first page says whether this chat is a forum; only then is a topic list worth asking for.
        if messages.contains(where: { $0.topicId != 0 }) { openChatIsForum = true }
        if openChatIsForum {
            if topics.isEmpty { await loadTopics(of: chatId) }
            // Who may start a topic comes from this account's own rights, so they are read with the list.
            if !chatAccess.canManageTopics, let chat = knownChats[chatId] { await loadAccess(of: chat) }
        }
        if let target = pendingJump, target.chatId == chatId, openChatId == chatId {
            pendingJump = nil
            await jump(to: target.messageId)
            return
        }
        guard openChatId == chatId, hadUnread,
              let firstUnread = messages.first(where: { !$0.isOutgoing && $0.id > lastRead })?.id else { return }
        let row = rowIdByMessage[firstUnread] ?? firstUnread
        unreadMarkerId = row
        scrollTarget = row
    }

    /// ⌥⌘↑ and ⌥⌘↓ walk through the chat list.
    func selectAdjacentChat(_ step: Int) {
        let list = visibleChats
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : list.count)
        let next = min(max(current + step, 0), list.count - 1)
        selection = list[next].id
    }

    /// ⌘1…⌘9 open the n-th chat of the list on screen.
    func selectChat(number: Int) {
        let list = visibleChats
        guard list.indices.contains(number - 1) else { return }
        selection = list[number - 1].id
    }

    /// Supergroup member counts in updates are often 0 ("unknown"); the full info has the real number.
    /// The online count arrives by itself as `updateChatOnlineMemberCount` once the chat is open.
    private func loadMemberCount(of chatId: Int64) async {
        guard let key = knownChats[chatId]?.groupKey, let id = Int64(key.dropFirst()) else { return }
        if key.hasPrefix("s"), let info = try? await request(["@type": "getSupergroupFullInfo", "supergroup_id": id]) {
            noteMemberCount(info.tdInt("member_count"), for: key)
        } else if key.hasPrefix("b"), let info = try? await request(["@type": "getBasicGroupFullInfo", "basic_group_id": id]) {
            noteMemberCount(info.tdNodes("members").count, for: key)
        }
    }

    func noteMemberCount(_ count: Int, for groupKey: String) {
        guard count > 0 else { return }
        groupMemberCounts[groupKey] = count
        if let chatId = chatIdByGroupKey[groupKey] { updateChat(chatId) { $0.memberCount = count } }
    }

    func loadOlder() async {
        // A message the archive brought back is a ghost: TDLib has no such id, and asking for history "before"
        // it gets nothing — which used to be read as the start of the chat. Anchor on the oldest real message.
        guard let chatId = openChatId, let oldest = messages.first(where: { !$0.isDeleted }) ?? messages.first,
              canLoadOlder, !loadingHistory else { return }
        let generation = beginHistoryLoad()
        defer { endHistoryLoad(generation) }

        do {
            let page = try await loadHistory(chatId: chatId, from: oldest.id, generation: generation)
            guard generation == historyGeneration else { return }
            canLoadOlder = !page.isEmpty
        } catch {
            guard generation == historyGeneration else { return }
            fail(error)
        }
    }

    /// Return sends; the send button's menu sends without sound or at a set time.
    func send(silently: Bool = false, at date: Date? = nil) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An edit may legitimately empty a caption out, so only a fresh message needs text.
        guard let chatId = openChatId, !text.isEmpty || composerContext?.kind == .edit else { return }
        if let context = composerContext, context.kind == .edit {
            await commitEdit(context, text: text, chatId: chatId)
            return
        }
        // A new message belongs after the latest ones, not at the end of an older stretch.
        if isViewingHistory { await showLatest() }

        let context = composerContext
        draft = ""
        draftBaseline = ""
        composerContext = nil
        draftSaveTask?.cancel()

        var payload: TDNode = [
            "@type": "sendMessage",
            "chat_id": chatId,
            "options": Self.sendOptions(silently: silently, at: date),
            "input_message_content": TD.inputText(text, clearDraft: true, markup: true),
        ]
        if let topic = openTopic { payload["topic_id"] = topic }
        if let context { payload["reply_to"] = TD.replyTo(context.messageId) }

        do {
            _ = try await request(payload)
            if let date {
                showToast("Отправится " + date.formatted(.dateTime.day().month(.wide).hour().minute().locale(Locale(identifier: "ru_RU"))))
                await loadScheduledMessages(of: chatId)
            }
            await readAfterReplying(in: chatId)
        } catch {
            // A cancelled request was already handed to TDLib, so the message is on its way; putting the text
            // back into the composer would only invite sending it a second time.
            if !(error is CancellationError), openChatId == chatId, draft.isEmpty {
                // The baseline goes back with the text, or the restored draft reads as typing: a "печатает…"
                // goes to the peer and the failed message overwrites the chat's draft on the server.
                draft = text
                draftBaseline = text
                composerContext = context
            }
            fail(error)
        }
    }

    static func sendOptions(silently: Bool = false, at date: Date? = nil) -> TDNode {
        var options: TDNode = ["@type": "messageSendOptions", "disable_notification": silently]
        if let date {
            options["scheduling_state"] = ["@type": "messageSchedulingStateSendAtDate", "send_date": Int(date.timeIntervalSince1970)]
        }
        return options
    }

    /// Answering gives presence away anyway, so ghost mode may read the chat then (AyuGram does the same).
    func readAfterReplying(in chatId: Int64) async {
        guard Preferences.isOn(Preferences.ghostMode), Preferences.isOn(Preferences.ghostReadOnReply) else { return }
        await markRead(chatId)
    }

    /// Chosen, dropped or pasted files go to the send sheet first, where a caption and "as files" can be set.
    func offerFiles(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard openChatId != nil, !files.isEmpty else { return }
        pendingFiles = (pendingFiles ?? []) + files
    }

    func sendFiles(_ urls: [URL], asDocuments: Bool = false, caption: String = "") async {
        guard let chatId = openChatId, !urls.isEmpty else { return }
        if isViewingHistory { await showLatest() }
        // Held until the files are on their way: dropped up front, a refused send lost the reply it belonged to.
        let reply = composerContext?.kind == .reply ? composerContext : nil

        // Photos and videos go together as albums of up to ten, like the official clients; files likewise, separately.
        let contents = await TD.inputContents(for: urls, asDocuments: asDocuments, caption: caption)
        var batches: [[TDNode]] = []
        for content in contents {
            if let last = batches.last?.last, Self.albumKind(of: last) == Self.albumKind(of: content),
               batches[batches.count - 1].count < 10 {
                batches[batches.count - 1].append(content)
            } else {
                batches.append([content])
            }
        }
        for batch in batches {
            var payload: TDNode = [
                "chat_id": chatId,
                "options": ["@type": "messageSendOptions", "disable_notification": false],
            ]
            if batch.count > 1 {
                payload["@type"] = "sendMessageAlbum"
                payload["input_message_contents"] = batch
            } else {
                payload["@type"] = "sendMessage"
                payload["input_message_content"] = batch[0]
            }
            if let reply { payload["reply_to"] = TD.replyTo(reply.messageId) }
            if let topic = openTopic { payload["topic_id"] = topic }
            do {
                _ = try await request(payload)
            } catch {
                fail(error)
                return
            }
        }
        if let reply, composerContext == reply { composerContext = nil }
        await readAfterReplying(in: chatId)
    }

    /// Photos and videos can share an album; documents only with documents.
    private static func albumKind(of content: TDNode) -> String {
        switch content.tdType {
        case "inputMessagePhoto", "inputMessageVideo": "media"
        default: content.tdType
        }
    }

    // MARK: - mentions and commands while typing

    /// The word at the end of the composer, when it starts a mention.
    private static func mentionQuery(in draft: String) -> String? {
        guard let word = draft.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace).last,
              word.hasPrefix("@"), word.count <= 33 else { return nil }
        return String(word.dropFirst())
    }

    private func refreshSuggestions(in chatId: Int64) {
        suggestionTask?.cancel()
        guard composerContext?.kind != .edit, let chat = knownChats[chatId] else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        // "/" and nothing but a command's name after it: the open bot's own commands, already in hand.
        if draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace), let commands = botMenu?.commands, !commands.isEmpty {
            let typed = draft.dropFirst().lowercased()
            suggestions = commands.filter { $0.command.lowercased().hasPrefix(typed) }.prefix(8).map {
                ComposerSuggestion(id: "/" + $0.command, title: "/" + $0.command, detail: $0.description, kind: .command($0.command))
            }
            return
        }
        // People are only worth offering where there are several to choose from.
        guard chat.kind == .group, let query = Self.mentionQuery(in: draft) else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        suggestionTask = Task {
            // Typing a name is a burst of keys; only the one it pauses on is asked about.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let found = try? await request([
                "@type": "searchChatMembers", "chat_id": chatId, "query": query, "limit": 8,
                "filter": ["@type": "chatMembersFilterMention"],
            ]) else { return }
            var people: [ComposerSuggestion] = []
            for member in found.tdNodes("members") {
                let userId = (member.tdNode("member_id") ?? [:]).tdInt64("user_id")
                guard userId != 0, userId != myUserId,
                      let user = try? await request(["@type": "getUser", "user_id": userId]) else { continue }
                let username = (user.tdNode("usernames")?["active_usernames"] as? [String])?.first ?? ""
                let name = TD.displayName(ofUser: user)
                people.append(ComposerSuggestion(
                    id: "u\(userId)", title: name.isEmpty ? "Пользователь" : name,
                    detail: username.isEmpty ? "" : "@" + username,
                    photo: TD.photo(user.tdNode("profile_photo")), seed: userId,
                    kind: .mention(userId: userId, username: username)))
            }
            guard !Task.isCancelled, openChatId == chatId, Self.mentionQuery(in: draft) == query else { return }
            suggestions = people
        }
    }

    /// A suggestion was picked: a mention replaces the word being typed, a command is sent as it is.
    func accept(_ suggestion: ComposerSuggestion) async {
        guard let chatId = openChatId else { return }
        suggestionTask?.cancel()
        suggestions = []
        switch suggestion.kind {
        case .command(let command):
            draft = ""
            await sendText("/" + command, to: chatId)
        case .mention(let userId, let username):
            guard let query = Self.mentionQuery(in: draft) else { return }
            // Someone without a username is mentioned by name, as a link to their account: the same markup
            // the message is parsed with turns it into a real mention.
            let name = suggestion.title.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            let mention = username.isEmpty ? "[\(name)](tg://user?id=\(userId))" : "@" + username
            draft = String(draft.dropLast(query.count + 1)) + mention + " "
        }
    }

    /// Called by the composer on every change of `draft`.
    func noteTyping() {
        guard let chatId = openChatId else { return }
        scheduleDraftSave(for: chatId)
        refreshSuggestions(in: chatId)

        guard Preferences.sendsTyping,
              composerContext?.kind != .edit,
              draft != draftBaseline,
              draft != quietDraft,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = Date()
        if let lastTypingAt, now.timeIntervalSince(lastTypingAt) < 4 { return }
        lastTypingAt = now
        var payload: TDNode = [
            "@type": "sendChatAction",
            "chat_id": chatId,
            "action": ["@type": "chatActionTyping"],
        ]
        if let topic = openTopic { payload["topic_id"] = topic }
        Task {
            _ = try? await request(payload)
        }
    }

    func beginReply(to message: Message) {
        guard message.chatId == openChatId, message.isSent else { return }
        if composerContext?.kind == .edit { finishEditing() }
        composerContext = ComposerContext(
            kind: .reply,
            messageId: message.id,
            title: "Ответ: \(name(for: message))",
            preview: TD.preview(of: message)
        )
    }

    /// Text messages edit their text; photos, videos and files edit their caption.
    static func editableText(of message: Message) -> (text: String, isCaption: Bool)? {
        guard !message.isDeleted, message.sticker == nil, message.media?.kind != .videoNote else { return nil }
        if message.attachment == nil, message.media == nil, case .text(let text) = message.body { return (text, false) }
        if message.attachment != nil || message.media != nil { return (message.caption, true) }
        return nil
    }

    /// Deleted copies kept by the archive and forwarded messages can never be edited: ↑ skips them and takes
    /// the last message that can, instead of stopping at one TDLib will refuse.
    func canEdit(_ message: Message) -> Bool {
        message.isOutgoing && message.isSent && !message.isDeleted && !message.isForwarded
            && Self.editableText(of: message) != nil
    }

    /// ↑ in an empty composer edits the last own message, as in the official clients.
    func editLastMessage() async {
        guard draft.isEmpty, composerContext == nil,
              let last = messages.last(where: { canEdit($0) }) else { return }
        await beginEdit(last)
    }

    func beginEdit(_ message: Message) async {
        guard message.chatId == openChatId, message.isSent, let editable = Self.editableText(of: message) else { return }
        do {
            let properties = try await request([
                "@type": "getMessageProperties",
                "chat_id": message.chatId,
                "message_id": message.id,
            ])
            guard properties.tdBool("can_be_edited") else {
                fail("Это сообщение уже нельзя изменить")
                return
            }
        } catch {
            fail(error)
            return
        }
        // Formatting comes back as the markup that makes it: the composer holds plain text, and saving an edit
        // without this sent the words alone, stripping every bold word and hidden link the message had.
        var text = editable.text
        var kept: [TDNode] = []
        if !message.entities.isEmpty,
           let node = try? await request(["@type": "getMessage", "chat_id": message.chatId, "message_id": message.id]),
           let content = node.tdNode("content"),
           let formatted = content.tdNode(editable.isCaption ? "caption" : "text"),
           let marked = TD.markdownText(of: formatted) {
            text = marked.text
            kept = marked.kept
        }
        guard message.chatId == openChatId else { return }

        if composerContext?.kind != .edit { stashedDraft = draft }
        composerContext = ComposerContext(
            kind: .edit,
            messageId: message.id,
            title: editable.isCaption ? "Редактирование подписи" : "Редактирование",
            preview: TD.preview(of: message),
            editsCaption: editable.isCaption
        )
        editBaseline = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Offsets are counted in the text as the composer gets it; trimming on save only ever cuts the ends.
        editText = text
        editEntities = kept
        draft = text
    }

    func cancelComposerContext() {
        if composerContext?.kind == .edit {
            finishEditing()
        } else {
            composerContext = nil
        }
    }

    func togglePin(_ message: Message) async {
        if message.isPinned {
            await perform(["@type": "unpinChatMessage", "chat_id": message.chatId, "message_id": message.id])
        } else {
            await perform([
                "@type": "pinChatMessage",
                "chat_id": message.chatId,
                "message_id": message.id,
                "disable_notification": true,
                "only_for_self": false,
            ])
        }
    }

    func resend(_ message: Message) async {
        // TDLib deletes the failed copy; that deletion is ours, not someone else's.
        let key = "\(message.chatId):\(message.id)"
        ownDeletions.insert(key)
        do {
            _ = try await request(["@type": "resendMessages", "chat_id": message.chatId, "message_ids": [message.id]])
        } catch {
            ownDeletions.remove(key)
            fail(error)
        }
    }

    func deletionOptions(for message: Message) async -> DeletionOptions? {
        do {
            let properties = try await request([
                "@type": "getMessageProperties",
                "chat_id": message.chatId,
                "message_id": message.id,
            ])
            let options = DeletionOptions(
                forSelf: properties.tdBool("can_be_deleted_only_for_self"),
                forEveryone: properties.tdBool("can_be_deleted_for_all_users")
            )
            guard options.forSelf || options.forEveryone else {
                fail("Это сообщение нельзя удалить")
                return nil
            }
            return options
        } catch {
            fail(error)
            return nil
        }
    }

    func delete(_ message: Message, forEveryone: Bool) async {
        if message.isDeleted {
            // Only the local archive still has it.
            archive.forget(chatId: message.chatId, messageId: message.id)
            messages.removeAll { $0.id == message.id }
            return
        }
        let ids = albumIds(of: message)
        await deleteOwn(ids, in: message.chatId, forEveryone: forEveryone)
    }

    /// Marks the deletion as ours before asking, so the archive does not keep what you delete yourself; a
    /// refused request takes the mark back, or a later deletion by someone else would go unsaved.
    @discardableResult
    func deleteOwn(_ ids: [Int64], in chatId: Int64, forEveryone: Bool) async -> Bool {
        let keys = ids.map { "\(chatId):\($0)" }
        ownDeletions.formUnion(keys)
        do {
            _ = try await request(["@type": "deleteMessages", "chat_id": chatId, "message_ids": ids, "revoke": forEveryone])
            return true
        } catch {
            ownDeletions.subtract(keys)
            fail(error)
            return false
        }
    }

    // MARK: - replies

    /// The message a reply quotes: from the loaded history, or fetched separately.
    func repliedMessage(for message: Message) -> Message? {
        guard message.replyToId != 0 else { return nil }
        if let position = messageIndex[message.replyToId] { return messages[position] }
        return replyPreviews[message.replyToId]
    }

    func loadRepliedMessage(for message: Message) async {
        let id = message.replyToId
        guard id != 0, message.chatId == openChatId, repliedMessage(for: message) == nil,
              !loadingReplies.contains(id) else { return }
        loadingReplies.insert(id)
        defer { loadingReplies.remove(id) }
        guard let node = try? await request(["@type": "getRepliedMessage", "chat_id": message.chatId, "message_id": message.id]),
              message.chatId == openChatId else { return }
        let original = TD.message(node)
        replyPreviews[id] = original
        resolveSenders(of: [original])
    }

    /// Shows any message of the open chat: in place when it is loaded, otherwise with the history around it.
    /// The calendar under a date header: the last message of the chosen day, or the closest one before it.
    func jump(toDay day: Date) async {
        guard let chatId = openChatId else { return }
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
        guard let found = try? await request([
            "@type": "getChatMessageByDate", "chat_id": chatId, "date": Int(end.timeIntervalSince1970) - 1,
        ]), found.tdInt64("id") != 0, openChatId == chatId else {
            showToast("В этот день сообщений нет")
            return
        }
        await jump(to: found.tdInt64("id"))
    }

    func jump(to messageId: Int64) async {
        guard let chatId = openChatId else { return }
        if messageIndex[messageId] != nil {
            focus(on: messageId)
            return
        }
        // In a forum the quoted message may belong to another topic; a chat-wide window dropped into a
        // topic's transcript would show messages that are not part of it, so the topic is switched to first.
        if let current = openTopicId,
           let found = try? await request(["@type": "getMessage", "chat_id": chatId, "message_id": messageId]),
           found.tdNode("topic_id")?.tdType == "messageTopicForum" {
            let owner = Int32(found.tdNode("topic_id")?.tdInt("forum_topic_id") ?? 0)
            if owner != 0, owner != current {
                await open(topic: owner)
                if messageIndex[messageId] != nil {
                    focus(on: messageId)
                    return
                }
            }
        }
        let generation = beginHistoryLoad()
        defer { endHistoryLoad(generation) }
        var nodes: [TDNode] = []
        // The first answer may come from the local database only; one more try picks up the server's.
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            nodes = (try? await history(chatId: chatId, from: messageId, offset: -25)) ?? []
            if nodes.contains(where: { $0.tdInt64("id") == messageId }) { break }
        }
        guard generation == historyGeneration, openChatId == chatId, !nodes.isEmpty else { return }
        isViewingHistory = true
        messages = []
        merge(nodes.map { TD.message($0) })
        canLoadOlder = true
        focus(on: messageId)
    }

    /// Back from an older stretch of history to the latest messages.
    func showLatest() async {
        guard let chatId = openChatId else { return }
        if isViewingHistory {
            isViewingHistory = false
            messages = []
            await loadInitialHistory(chatId)
        }
        if let newest = messages.last?.id { scrollTarget = newest }
    }

    // MARK: - search

    /// Typing in the sidebar search also looks through messages of all chats, after a short pause.
    func scheduleMessageSearch() {
        messageSearchTask?.cancel()
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, isReady else {
            foundMessages = []
            foundPublicChats = []
            return
        }
        messageSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            // The chats found by name already come from both lists; the messages used to come from the main
            // one alone, so anything said in an archived chat could not be found from here at all.
            var messages: [Message] = []
            for list in ["chatListMain", "chatListArchive"] {
                let found = try? await request([
                    "@type": "searchMessages",
                    "chat_list": ["@type": list],
                    "query": query,
                    "offset": "",
                    "limit": 30,
                    "min_date": 0,
                    "max_date": 0,
                ])
                guard !Task.isCancelled, filter.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                messages += found?.tdNodes("messages").map { TD.message($0) } ?? []
            }
            messages.sort { $0.date > $1.date }
            resolveSenders(of: messages)
            foundMessages = messages
            // People, bots, groups and channels by name or @username, beyond your own chats.
            let publicChats = try? await request(["@type": "searchPublicChats", "query": query])
            guard !Task.isCancelled, filter.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            let mine = listedChatIds
            foundPublicChats = (publicChats?.tdInt64s("chat_ids") ?? []).filter { !mine.contains($0) }
        }
    }

    /// Opens the result's chat right at the message.
    func open(_ result: Message) {
        if openChatId == result.chatId {
            Task { await jump(to: result.id) }
        } else {
            pendingJump = (chatId: result.chatId, messageId: result.id)
            selection = result.chatId
        }
    }

    /// A command of the Формат menu. Without an open chat there is no composer to take it, and a request left
    /// waiting would be applied to whichever chat opened next.
    func format(_ format: TextFormat) {
        guard openChatId != nil else { return }
        formatRequest = FormatRequest(format: format)
    }

    /// ⌘I: italic while words are selected in the composer, the profile of the open chat otherwise.
    func italicOrProfile() {
        if composerHasSelection {
            formatRequest = FormatRequest(format: .italic)
        } else if let chat = selectedChat {
            Task { await showProfile(of: chat) }
        }
    }

    /// ⌘K: a link on the selected words, the sidebar's chat search otherwise.
    func linkOrFindChat() {
        if composerHasSelection {
            formatRequest = FormatRequest(format: .link)
        } else {
            searchChatsRequest += 1
        }
    }

    /// A quote of a message from another chat was clicked: that chat opens at the message, when this account
    /// can see it.
    func open(_ reply: ForeignReply) {
        guard reply.chatId != 0, reply.messageId != 0, knownChats[reply.chatId] != nil else {
            showToast("Это сообщение из чата, которого у вас нет")
            return
        }
        if openChatId == reply.chatId {
            Task { await jump(to: reply.messageId) }
        } else {
            pendingJump = (chatId: reply.chatId, messageId: reply.messageId)
            selection = reply.chatId
        }
    }

    func chat(withId chatId: Int64) -> Chat? {
        knownChats[chatId]
    }

    func runSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chatId = openChatId, !query.isEmpty else { return }
        isSearchRunning = true
        defer { isSearchRunning = false }
        let found = try? await request(searchRequest(query, in: chatId, from: 0))
        // Closed, or asked again with other words while this one was running: its answer is stale.
        guard openChatId == chatId, isSearching,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        searchResults = found?.tdNodes("messages").map { $0.tdInt64("id") } ?? []
        searchTotal = max(found?.tdInt("total_count") ?? 0, searchResults.count)
        searchNextFrom = found?.tdInt64("next_from_message_id") ?? 0
        searchedQuery = query
        searchPosition = 0
        if let first = searchResults.first { await jump(to: first) }
    }

    private func searchRequest(_ query: String, in chatId: Int64, from messageId: Int64) -> TDNode {
        var payload: TDNode = [
            "@type": "searchChatMessages",
            "chat_id": chatId,
            "query": query,
            "from_message_id": messageId,
            "offset": 0,
            "limit": 100,
        ]
        // In a topic the search stays inside that topic, the way the transcript does.
        if let topic = openTopic { payload["topic_id"] = topic }
        return payload
    }

    /// Whether "раньше" has somewhere to go: a match already in hand, or a page of them still on the server.
    var canStepSearchOlder: Bool {
        searchPosition + 1 < searchResults.count || searchNextFrom != 0
    }

    /// +1 goes to an older match, -1 to a newer one. Walking past the last match in hand brings the next
    /// hundred: the search used to end there, however many more the chat held.
    func stepSearch(_ step: Int) async {
        guard !searchResults.isEmpty else { return }
        if step > 0, searchPosition + 1 >= searchResults.count, searchNextFrom != 0, !isSearchRunning,
           let chatId = openChatId {
            isSearchRunning = true
            let query = searchedQuery
            let found = try? await request(searchRequest(query, in: chatId, from: searchNextFrom))
            isSearchRunning = false
            guard openChatId == chatId, isSearching, searchedQuery == query else { return }
            let known = Set(searchResults)
            let more = (found?.tdNodes("messages").map { $0.tdInt64("id") } ?? []).filter { !known.contains($0) }
            searchResults += more
            // A page that brings nothing new ends the walk, whatever the server says comes next.
            searchNextFrom = more.isEmpty ? 0 : (found?.tdInt64("next_from_message_id") ?? 0)
            searchTotal = max(searchTotal, searchResults.count)
        }
        searchPosition = min(max(searchPosition + step, 0), searchResults.count - 1)
        await jump(to: searchResults[searchPosition])
    }

    func endSearch() {
        isSearching = false
        searchQuery = ""
        searchResults = []
        searchPosition = 0
        searchTotal = 0
        searchNextFrom = 0
        searchedQuery = ""
    }

    // MARK: - scheduled messages

    func loadScheduledMessages(of chatId: Int64) async {
        guard let result = try? await request(["@type": "getChatScheduledMessages", "chat_id": chatId]),
              openChatId == chatId else { return }
        scheduledMessages = result.tdNodes("messages").map { TD.message($0) }.sorted { $0.date < $1.date }
    }

    /// Sends a scheduled message right away.
    func sendNow(_ message: Message) async {
        await perform(["@type": "editMessageSchedulingState", "chat_id": message.chatId, "message_id": message.id])
        await loadScheduledMessages(of: message.chatId)
    }

    func deleteScheduled(_ message: Message) async {
        await perform(["@type": "deleteMessages", "chat_id": message.chatId, "message_ids": [message.id], "revoke": true])
        await loadScheduledMessages(of: message.chatId)
    }

    // MARK: - history

    private static let historyPageSize = 50

    func loadInitialHistory(_ chatId: Int64) async {
        let generation = beginHistoryLoad()
        defer { endHistoryLoad(generation) }

        // What TDLib has on disk is on screen at once; the page from the server follows and fills in.
        if messages.isEmpty, openTopicId == nil, let local = try? await history(chatId: chatId, from: 0, onlyLocal: true),
           generation == historyGeneration, !local.isEmpty {
            merge(local.map { TD.message($0) })
        }
        do {
            let page = try await loadHistory(chatId: chatId, from: 0, generation: generation)
            guard generation == historyGeneration else { return }
            // The disk page can reach past a gap in the stored history. Behind a full server page, anything
            // older is dropped and comes back in order through "load older".
            if page.count >= Self.historyPageSize, let oldest = page.last?.tdInt64("id"), oldest != 0 {
                let contiguous = messages.filter { $0.id >= oldest }
                if contiguous.count != messages.count { messages = contiguous }
            }
            canLoadOlder = !page.isEmpty
            if Preferences.readsAutomatically { await markRead(chatId) }
        } catch {
            guard generation == historyGeneration else { return }
            fail(error)
        }
    }

    /// Switching chats bumps the generation, so pages that arrive for a chat the user left are dropped.
    private func beginHistoryLoad() -> Int {
        historyGeneration += 1
        loadingHistory = true
        return historyGeneration
    }

    private func endHistoryLoad(_ generation: Int) {
        if generation == historyGeneration { loadingHistory = false }
    }

    /// TDLib answers `getChatHistory` from its own database and preloads the rest from the server in the
    /// background without any "history loaded" update, so the first page is often a single message.
    /// Re-request until the page stops growing, then stop.
    private func loadHistory(chatId: Int64, from messageId: Int64, generation: Int) async throws -> [TDNode] {
        var nodes = try await history(chatId: chatId, from: messageId)
        var previousCount = -1
        var attempts = 0

        while generation == historyGeneration {
            mergeUnseen(nodes)
            let settled = nodes.count >= Self.historyPageSize || nodes.count == previousCount
            guard !settled, attempts < 5 else { break }
            previousCount = nodes.count
            attempts += 1
            try? await Task.sleep(for: .milliseconds(150))
            nodes = try await history(chatId: chatId, from: messageId)
        }
        return nodes
    }

    /// A retry of the first page mostly repeats what the page before it brought, and parsing a message costs
    /// ~8 µs: a thousand of them is 8 ms of the main thread for nothing. Ids already on screen are dropped
    /// before that; a message that changes does so through its own update.
    private func mergeUnseen(_ nodes: [TDNode]) {
        let unseen = nodes.filter { messageIndex[$0.tdInt64("id")] == nil }
        guard !unseen.isEmpty else { return }
        merge(unseen.map { TD.message($0) })
    }

    /// With offset 0 the page starts right below `from_message_id` (the message itself is excluded),
    /// so an empty page means the beginning of the chat was reached.
    private func history(chatId: Int64, from messageId: Int64, offset: Int = 0, onlyLocal: Bool = false) async throws -> [TDNode] {
        // A topic's history has its own request, and that one has no local-only mode.
        if let topic = openTopicId {
            return try await request([
                "@type": "getForumTopicHistory",
                "chat_id": chatId,
                "forum_topic_id": Int(topic),
                "from_message_id": messageId,
                "offset": offset,
                "limit": Self.historyPageSize,
            ]).tdNodes("messages")
        }
        return try await request([
            "@type": "getChatHistory",
            "chat_id": chatId,
            "from_message_id": messageId,
            "offset": offset,
            "limit": Self.historyPageSize,
            "only_local": onlyLocal,
        ]).tdNodes("messages")
    }

    /// Pointing at a chat in the list asks TDLib for its latest page ahead of time, so the click finds it
    /// already on disk. Each chat once per session, a few at a time.
    func prefetchHistory(of chatId: Int64) {
        guard isReady, chatId != openChatId, !prefetchedChats.contains(chatId), prefetchesRunning < 3 else { return }
        prefetchedChats.insert(chatId)
        prefetchesRunning += 1
        Task {
            defer { prefetchesRunning -= 1 }
            _ = try? await request([
                "@type": "getChatHistory", "chat_id": chatId, "from_message_id": 0, "offset": 0,
                "limit": Self.historyPageSize, "only_local": false,
            ])
        }
    }

    func leaveOpenChat() {
        guard let chatId = openChatId else { return }
        saveDraft(of: chatId)
        openChatId = nil
        clearConversation()
        Task { _ = try? await request(["@type": "closeChat", "chat_id": chatId]) }
    }

    /// What the transcript and the composer hold about the chat that was open, including the scroll back in
    /// history. Separate from `leaveOpenChat`, because `resetSession` clears `openChatId` first to keep the
    /// draft out of a dying session and so cannot go through it.
    func clearConversation() {
        historyGeneration += 1
        draftSaveTask?.cancel()
        draftSaveTask = nil
        messages = []
        translations = [:]
        translatingIds = []
        canLoadOlder = false
        loadingHistory = false
        composerContext = nil
        composerHasSelection = false
        formatRequest = nil
        stashedDraft = ""
        editBaseline = nil
        editText = ""
        editEntities = []
        suggestionTask?.cancel()
        suggestions = []
        draft = ""
        draftBaseline = ""
        draftSaveRound += 1
        lastTypingAt = nil
        quietDraft = nil
        replyPreviews = [:]
        scrollTarget = nil
        highlightedMessageId = nil
        unreadMarkerId = nil
        pinnedMessage = nil
        viewerMessage = nil
        revealedSpoilers = []
        pendingFiles = nil
        replyKeyboard = nil
        replyKeyboardBotId = 0
        isReplyKeyboardShown = true
        scheduledMessages = []
        topics = []
        openTopicId = nil
        openChatIsForum = false
        // Rights and statistics belong to one chat; left over, they would gate the next chat's controls.
        chatAccess = ChatAccess()
        members = []
        membersTotal = 0
        inviteLinks = []
        statistics = nil
        // The management sheet holds the chat it was opened for, so it has to go with that chat.
        managedChat = nil
        botMenu = nil
        pendingBotStart = nil
        pendingButton = nil
        endSelection()
        isViewingHistory = false
        endSearch()
    }

    func markRead(_ chatId: Int64) async {
        guard let chat = knownChats[chatId] else { return }
        let isOpen = chatId == openChatId
        var newest = chat.lastMessageId
        if isOpen, let loaded = messages.last(where: \.isSent)?.id {
            newest = max(newest, loaded)
        }

        if newest != 0 {
            _ = try? await request([
                "@type": "viewMessages",
                "chat_id": chatId,
                "message_ids": [newest],
                "source": ["@type": isOpen ? "messageSourceChatHistory" : "messageSourceChatList"],
                "force_read": true,
            ])
        }
        if chat.isMarkedUnread {
            _ = try? await request(["@type": "toggleChatIsMarkedAsUnread", "chat_id": chatId, "is_marked_as_unread": false])
        }
        if chat.unreadMentions > 0 {
            _ = try? await request(["@type": "readAllChatMentions", "chat_id": chatId])
        }
        if chat.unreadReactions > 0 {
            _ = try? await request(["@type": "readAllChatReactions", "chat_id": chatId])
        }
        // A topic's counter is the client's own, so reading has to clear it here: the open topic when one is
        // picked, the whole chat's topics when the chat is read as one stream.
        guard isOpen else { return }
        if let topic = openTopicId {
            if let index = topics.firstIndex(where: { $0.id == topic }) { topics[index].unread = 0 }
        } else {
            for index in topics.indices { topics[index].unread = 0 }
        }
    }

    /// Incoming messages count as read only while the user can actually see them.
    func scheduleMarkRead() {
        guard Preferences.readsAutomatically, NSApp?.isActive == true, !readPending,
              let chatId = openChatId else { return }
        readPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            readPending = false
            guard openChatId == chatId else { return }
            await markRead(chatId)
        }
    }

    func applicationBecameActive() {
        updateOnlineStatus()
        guard let chatId = openChatId, let chat = knownChats[chatId] else { return }
        if chat.unread > 0 || chat.isMarkedUnread || chat.unreadMentions > 0 || chat.unreadReactions > 0 {
            scheduleMarkRead()
        }
    }

    // MARK: - drafts and edits

    /// The chat's own draft: while a message is being edited the composer holds that message instead.
    var chatDraftText: String {
        composerContext?.kind == .edit ? stashedDraft : draft
    }

    private func scheduleDraftSave(for chatId: Int64) {
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, openChatId == chatId else { return }
            saveDraft(of: chatId)
        }
    }

    func saveDraft(of chatId: Int64) {
        let text = chatDraftText
        guard text != draftBaseline else { return }
        let saved = draftBaseline
        draftBaseline = text
        draftSaveRound += 1
        let round = draftSaveRound
        // The chat list shows "Черновик:" right away instead of waiting for TDLib's echo.
        updateChat(chatId) { $0.draftText = text }
        let payload = draftRequest(for: chatId, text: text)
        Task {
            guard await !self.draftAccepted(payload) else { return }
            // TDLib keeps nothing where you cannot post, so the echo has to come back down: a "Черновик:" that
            // never reached the server is lost on relaunch and blocks the drafts that come from other devices.
            // Only the newest save may undo itself — an older refusal must not push back a draft that has since
            // been typed again, or accepted, in the same chat.
            guard round == draftSaveRound, openChatId == chatId, chatDraftText == text else { return }
            draftBaseline = saved
            updateChat(chatId) { $0.draftText = saved }
        }
    }

    /// `setChatDraftMessage` on the side: a request that never ran counts as accepted, only a refusal is undone.
    private func draftAccepted(_ payload: TDNode) async -> Bool {
        do { _ = try await request(payload); return true } catch { return error is CancellationError }
    }

    func draftRequest(for chatId: Int64, text: String) -> TDNode {
        var payload: TDNode = ["@type": "setChatDraftMessage", "chat_id": chatId]
        if let topic = openTopic { payload["topic_id"] = topic }
        if let draftMessage = TD.draftMessage(text) { payload["draft_message"] = draftMessage }
        return payload
    }

    /// A draft changed elsewhere (another device, or cleared by TDLib after sending) replaces the composer
    /// text only when nothing typed here is waiting to be saved.
    func adoptRemoteDraft(_ text: String) {
        guard chatDraftText == draftBaseline else { return }
        draftBaseline = text
        let current = chatDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if composerContext?.kind == .edit {
            stashedDraft = text
        } else {
            draft = text
        }
    }

    private func commitEdit(_ context: ComposerContext, text: String, chatId: Int64) async {
        let unchanged = editBaseline.map { $0 == text }
            ?? (messages.first { $0.id == context.messageId }.flatMap { Self.editableText(of: $0)?.text } == text)
        if unchanged {
            finishEditing()
            return
        }
        // Leading whitespace was trimmed off `text`; entities are placed against the untrimmed draft.
        let lead = draft.prefix { $0.isWhitespace || $0.isNewline }
        let kept = TD.carry(editEntities, from: editText, to: String(lead) + text).compactMap { entity -> TDNode? in
            var moved = entity
            moved["offset"] = entity.tdInt("offset") - lead.utf16.count
            return entity.tdInt("offset") >= lead.utf16.count ? moved : nil
        }
        let payload: TDNode = context.editsCaption
            ? [
                "@type": "editMessageCaption",
                "chat_id": chatId,
                "message_id": context.messageId,
                "caption": TD.markedUp(text, keeping: kept),
            ]
            : [
                "@type": "editMessageText",
                "chat_id": chatId,
                "message_id": context.messageId,
                "input_message_content": ["@type": "inputMessageText", "text": TD.markedUp(text, keeping: kept),
                                          "clear_draft": false] as TDNode,
            ]
        do {
            let edited = try await request(payload)
            if openChatId == chatId { merge([TD.message(edited)]) }
            if composerContext == context { finishEditing() }
        } catch {
            fail(error)
        }
    }

    private func finishEditing() {
        editBaseline = nil
        editText = ""
        editEntities = []
        composerContext = nil
        draft = stashedDraft
        stashedDraft = ""
    }

    func downloadedFile(of message: Message) async -> URL? {
        guard let attachment = message.attachment else { return nil }
        do {
            let file = try await request([
                "@type": "downloadFile",
                "file_id": attachment.fileId,
                "priority": 32,
                "offset": 0,
                "limit": 0,
                "synchronous": true,
            ])
            let local = file.tdNode("local") ?? [:]
            guard local.tdBool("is_downloading_completed"), !local.tdString("path").isEmpty else {
                fail("Не удалось скачать «\(attachment.name)»")
                return nil
            }
            return URL(fileURLWithPath: local.tdString("path"))
        } catch {
            fail(error)
            return nil
        }
    }
}
