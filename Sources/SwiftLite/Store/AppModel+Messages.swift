import AppKit
import Foundation

/// What is done to single messages: picking several, the photo viewer, reactions, pins, translation, polls,
/// stickers, voice notes and the rest of what a message can be.
extension AppModel {
    // MARK: - selecting several messages

    func beginSelection(with message: Message) {
        isSelectingMessages = true
        selectedMessageIds = Set(albumIds(of: message))
    }

    /// A click on a message while selecting; an album is picked or dropped as a whole.
    func toggleSelection(of message: Message) {
        let ids = Set(albumIds(of: message))
        if selectedMessageIds.isSuperset(of: ids) {
            selectedMessageIds.subtract(ids)
        } else {
            selectedMessageIds.formUnion(ids)
        }
    }

    func endSelection() {
        isSelectingMessages = false
        selectedMessageIds = []
    }

    /// Esc closes whatever is on top: the photo viewer, then selection, search and the reply or edit.
    /// One handler instead of a shortcut per bar, which SwiftUI would resolve in no particular order.
    func escape() {
        if viewerMessage != nil {
            viewerMessage = nil
        } else if isSelectingMessages {
            endSelection()
        } else if isSearching {
            endSearch()
        } else if composerContext != nil {
            cancelComposerContext()
        } else if !filter.isEmpty {
            // The window's Esc reaches this before the sidebar's search field does.
            filter = ""
        } else if showsMembersPanel {
            // Last, so Esc closes what is on top of the chat before it closes the chat's own panels.
            showsMembersPanel = false
        }
    }

    /// Return in the sidebar's search opens the first chat found.
    func openFirstSearchResult() {
        guard let target = visibleChats.first?.id ?? foundPublicChats.first else { return }
        wantsComposerFocus = true
        selection = target
    }

    var selectedMessages: [Message] {
        messages.filter { selectedMessageIds.contains($0.id) }
    }

    /// "Имя, 14:32: текст" for each picked message, oldest first, ready for the clipboard.
    func selectionAsText() -> String {
        selectedMessages.map { message in
            "\(name(for: message)), \(message.date.formatted(.dateTime.hour().minute().locale(Loc.locale))):\n\(MessageArchive.text(of: message))"
        }
        .joined(separator: "\n\n")
    }

    /// Deleting several messages is only offered the ways every one of them allows.
    func selectionDeletionOptions() async -> DeletionOptions? {
        var forSelf = true
        var forEveryone = true
        for message in selectedMessages where !message.isDeleted {
            guard let properties = try? await request([
                "@type": "getMessageProperties",
                "chat_id": message.chatId,
                "message_id": message.id,
            ]) else { continue }
            forSelf = forSelf && properties.tdBool("can_be_deleted_only_for_self")
            forEveryone = forEveryone && properties.tdBool("can_be_deleted_for_all_users")
        }
        guard forSelf || forEveryone else {
            fail(L("Часть сообщений нельзя удалить"))
            return nil
        }
        return DeletionOptions(forSelf: forSelf, forEveryone: forEveryone)
    }

    func deleteSelection(forEveryone: Bool) async {
        let picked = selectedMessages
        guard let chatId = picked.first?.chatId else { return }
        let localOnly = picked.filter(\.isDeleted)
        let ids = picked.filter { !$0.isDeleted }.map(\.id)
        func dropLocalOnlyRows() {
            // The ids picked at the start, not the live selection: the delete request may have been awaited,
            // and a click during it would otherwise decide which rows vanish.
            let gone = Set(localOnly.map(\.id))
            for message in localOnly { archive.forget(chatId: chatId, messageId: message.id) }
            messages.removeAll { $0.isDeleted && gone.contains($0.id) }
        }
        guard !ids.isEmpty else {
            dropLocalOnlyRows()
            endSelection()
            return
        }
        // A refused delete keeps the pick: ending selection would throw away work meant to be retried.
        guard await deleteOwn(ids, in: chatId, forEveryone: forEveryone) else { return }
        dropLocalOnlyRows()
        endSelection()
    }

    /// A photo of an album stands for the whole album: forwarding or deleting takes all of it.
    func albumIds(of message: Message) -> [Int64] {
        guard message.albumId != 0 else { return [message.id] }
        let ids = messages.filter { $0.albumId == message.albumId && $0.chatId == message.chatId && !$0.isDeleted }.map(\.id)
        return ids.isEmpty ? [message.id] : ids.sorted()
    }

    // MARK: - photo viewer

    func revealSpoiler(of message: Message) { revealedSpoilers.insert(message.id) }

    func isRevealed(_ message: Message) -> Bool { revealedSpoilers.contains(message.id) }

    /// Photos of the loaded history, oldest first: the viewer's ← and → walk through them.
    private var viewerPhotos: [Message] {
        messages.filter { $0.media?.kind == .photo && !$0.isDeleted }
    }

    /// Index and total of the open photo among the chat's photos. Walked by index over a local copy: this is
    /// read five times per viewer redraw (the counter plus twice per arrow), and a `filter` here copied every
    /// matching message — 784 bytes each — instead of only counting it.
    var viewerPosition: (index: Int, count: Int)? {
        guard let current = viewerMessage else { return nil }
        let history = messages
        var count = 0
        var found = -1
        for position in history.indices
        where history[position].media?.kind == .photo && !history[position].isDeleted {
            if history[position].id == current.id { found = count }
            count += 1
        }
        guard found >= 0 else { return nil }
        return (found, count)
    }

    func stepViewer(_ step: Int) {
        // One snapshot: taking the list twice could shift the indices between the two reads.
        let photos = viewerPhotos
        guard let current = viewerMessage, let index = photos.firstIndex(where: { $0.id == current.id }) else { return }
        let next = index + step
        guard photos.indices.contains(next) else { return }
        viewerMessage = photos[next]
    }

    // MARK: - reactions

    /// The reactions offered in the menu, like the official quick-reaction bar.
    static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    // MARK: - keeping and sharing one message

    /// "В Избранное": a copy of the message, or of its whole album, in the chat with yourself.
    func saveToSavedMessages(_ message: Message) async {
        guard myUserId != 0,
              let node = try? await request(["@type": "createPrivateChat", "user_id": myUserId, "force": false]) else { return }
        // The chat object is only needed for its id and name; the forward itself reports what happened.
        var saved = knownChats[node.tdInt64("id")] ?? TD.chat(node)
        saved.title = L("Избранное")
        await forward([message], to: saved)
    }

    /// A t.me link to the message. Only messages of public or private supergroups and channels have one.
    func copyLink(to message: Message) async {
        guard let link = try? await request([
            "@type": "getMessageLink", "chat_id": message.chatId, "message_id": message.id,
            "media_timestamp": 0, "checklist_task_id": 0, "poll_option_id": "", "for_album": false, "in_message_thread": false,
        ]), !link.tdString("link").isEmpty else {
            showToast(L("У сообщений этого чата нет ссылок"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.tdString("link"), forType: .string)
        showToast(link.tdBool("is_public") ? L("Ссылка скопирована") : L("Ссылка скопирована — откроется только у участников"))
    }

    /// The photo itself on the pasteboard, ready to paste into another app.
    func copyPhoto(of message: Message) async {
        guard let fileId = message.attachment?.fileId, let path = await localFile(id: fileId, priority: 32),
              let image = NSImage(contentsOfFile: path) else {
            fail(L("Не удалось скопировать фото"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showToast(L("Фото скопировано"))
    }

    // MARK: - custom emoji

    /// Fetches the pictures of custom emoji that are not in hand yet. A still picture each: the sticker
    /// itself when it is one, its preview when the emoji is animated.
    func loadCustomEmoji(_ ids: [Int64]) async {
        let wanted = Set(ids).filter { customEmoji[$0] == nil && !loadingCustomEmoji.contains($0) }
        guard !wanted.isEmpty else { return }
        loadingCustomEmoji.formUnion(wanted)
        defer { loadingCustomEmoji.subtract(wanted) }
        // int64 goes to TDLib as a string.
        guard let found = try? await request(["@type": "getCustomEmojiStickers",
                                              "custom_emoji_ids": wanted.map(String.init)]) else { return }
        for node in found.tdNodes("stickers") {
            let id = node.tdNode("full_type")?.tdInt64("custom_emoji_id") ?? 0
            guard id != 0, let sticker = TD.sticker(node, isEmoji: true) else { continue }
            if node.tdNode("full_type")?.tdBool("needs_repainting") == true { templateEmoji.insert(id) }
            let fileId = sticker.format == .webp ? sticker.fileId : sticker.thumbnailFileId
            guard let fileId, let path = await localFile(id: fileId, priority: 4) else { continue }
            customEmoji[id] = path
        }
        // An emoji with no picture to show (deleted, or a format with no preview) is remembered as such:
        // asked for again by every row that scrolls into view, it cost a request each time.
        for id in wanted where customEmoji[id] == nil { customEmoji[id] = "" }
    }

    func toggleReaction(_ emoji: String, customEmojiId: Int64 = 0, on message: Message) async {
        let same = { (reaction: Reaction) in reaction.emoji == emoji && reaction.customEmojiId == customEmojiId }
        let chosen = message.reactions.contains { same($0) && $0.isChosen }
        let before = messageIndex[message.id].map { messages[$0].reactions }
        // Shown at once; TDLib's update replaces it with the real numbers.
        if let index = messageIndex[message.id] {
            var reactions = messages[index].reactions
            if let existing = reactions.firstIndex(where: same) {
                reactions[existing].isChosen.toggle()
                reactions[existing].count += chosen ? -1 : 1
                if reactions[existing].count <= 0 { reactions.remove(at: existing) }
            } else {
                reactions.append(Reaction(emoji: emoji, count: 1, isChosen: true, customEmojiId: customEmojiId))
            }
            var updated = messages[index]
            updated.reactions = reactions
            replaceMessage(at: index, with: updated)
        }
        let type: TDNode = customEmojiId != 0
            ? ["@type": "reactionTypeCustomEmoji", "custom_emoji_id": String(customEmojiId)]
            : ["@type": "reactionTypeEmoji", "emoji": emoji]
        do {
            if chosen {
                _ = try await request(["@type": "removeMessageReaction", "chat_id": message.chatId, "message_id": message.id, "reaction_type": type])
            } else {
                _ = try await request([
                    "@type": "addMessageReaction",
                    "chat_id": message.chatId,
                    "message_id": message.id,
                    "reaction_type": type,
                    "is_big": false,
                    "update_recent_reactions": true,
                ])
            }
        } catch {
            // Refused (chats can allow only some reactions): no update will come, so the guess is taken back.
            if let before, let index = messageIndex[message.id], messages[index].chatId == message.chatId {
                var restored = messages[index]
                restored.reactions = before
                replaceMessage(at: index, with: restored)
            }
            if let tdError = error as? TDError, tdError.message.uppercased().contains("REACTION") {
                showToast(emoji.isEmpty ? L("Эта реакция в этом чате недоступна") : L("\(emoji) в этом чате недоступна"))
            } else {
                fail(error)
            }
        }
    }

    // MARK: - pinned message

    func loadPinnedMessage(of chatId: Int64) async {
        let node = try? await request(["@type": "getChatPinnedMessage", "chat_id": chatId])
        guard openChatId == chatId else { return }
        pinnedMessage = node.map { TD.message($0) }
    }

    /// Changes how a message reads on this Mac only. Nothing is sent; nil restores the original.
    func setLocalText(_ text: String?, of message: Message) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) || trimmed == MessageArchive.text(of: message) ? nil : text
        archive.setLocalText(value, for: message)
        if let index = messageIndex[message.id], messages[index].chatId == message.chatId {
            var updated = messages[index]
            updated.localText = value
            replaceMessage(at: index, with: updated)
        }
    }

    func showEditHistory(of message: Message) {
        guard let entry = archive.entry(chatId: message.chatId, messageId: message.id), !entry.versions.isEmpty else { return }
        let versions = entry.versions.enumerated().map { index, version in
            L("Версия \(index + 1), заменена \(version.replacedAt.formatted(.dateTime.day().month(.wide).hour().minute().locale(Loc.locale))):\n\(version.text)")
        }
        inspectedCode = InspectedCode(
            title: L("История изменений"),
            json: (versions + [L("Сейчас:\n\(MessageArchive.text(of: message))")]).joined(separator: "\n\n"),
            isCode: false
        )
    }

    func clearArchive() {
        archive.clear()
        // One assignment: changing the messages one by one rebuilt the transcript for each of them.
        messages = messages.filter { !$0.isDeleted }.map { message in
            var cleared = message
            cleared.hasEditHistory = false
            return cleared
        }
    }

    // MARK: - translation

    /// A language `translateText` accepts.
    struct TranslationLanguage: Identifiable {
        var code: String
        var name: String
        var id: String { code }
    }

    /// The languages `translateText` accepts, kept to those worth an entry in the settings list.
    static let translationLanguages: [TranslationLanguage] = [
        .init(code: "ru", name: L("Русский")), .init(code: "en", name: L("Английский")),
        .init(code: "uk", name: L("Украинский")), .init(code: "be", name: L("Белорусский")),
        .init(code: "de", name: L("Немецкий")), .init(code: "fr", name: L("Французский")),
        .init(code: "es", name: L("Испанский")), .init(code: "it", name: L("Итальянский")),
        .init(code: "pt", name: L("Португальский")), .init(code: "pl", name: L("Польский")),
        .init(code: "nl", name: L("Нидерландский")), .init(code: "tr", name: L("Турецкий")),
        .init(code: "ar", name: L("Арабский")), .init(code: "fa", name: L("Персидский")),
        .init(code: "zh", name: L("Китайский")), .init(code: "ja", name: L("Японский")),
        .init(code: "ko", name: L("Корейский")), .init(code: "hi", name: L("Хинди")),
    ]

    /// A translated message. Formatting comes back only for a Telegram Premium account, and the language is
    /// kept with the text: changing the setting must not relabel what is already on screen.
    struct Translation: Equatable {
        var text: String
        var entities: [TextEntity]
        var languageCode: String
    }

    private static func translationKey(_ message: Message) -> String {
        "\(message.chatId):\(message.id)"
    }

    /// The words of a message: what you rewrote locally is what reads on screen, so that is what goes.
    static func translatableText(of message: Message) -> String {
        if let local = message.localText { return local }
        if case .text(let text) = message.body { return text }
        return message.caption
    }

    func translation(of message: Message) -> Translation? {
        translations[Self.translationKey(message)]
    }

    func isTranslating(_ message: Message) -> Bool {
        translatingIds.contains(Self.translationKey(message))
    }

    func canTranslate(_ message: Message) -> Bool {
        !Self.translatableText(of: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func languageName(_ code: String) -> String {
        translationLanguages.first { $0.code == code }?.name ?? code
    }

    func translate(_ message: Message) async {
        let key = Self.translationKey(message)
        let code = Preferences.translationLanguage
        guard canTranslate(message), translations[key] == nil, !translatingIds.contains(key) else { return }
        translatingIds.insert(key)
        defer { translatingIds.remove(key) }
        do {
            let result = try await request([
                "@type": "translateText",
                "text": TD.formattedText(Self.translatableText(of: message)),
                "to_language_code": code,
                "tone": "neutral",
            ])
            let translation = Translation(text: result.tdText("text"), entities: TD.entities(result), languageCode: code)
            guard translation.text.isEmpty == false else { return }
            translations[key] = translation
        } catch let error as TDError where error.isSessionClosed || error.isNotFound {
            // A session that ended and a refused language leave the bubble as it was, quietly.
        } catch {
            fail(error)
        }
    }

    func hideTranslation(of message: Message) {
        translations[Self.translationKey(message)] = nil
    }

    // MARK: - polls

    /// Indices of the chosen answers; an empty list takes the vote back.
    func vote(_ options: [Int], in message: Message) async {
        await perform(["@type": "setPollAnswer", "chat_id": message.chatId, "message_id": message.id, "option_ids": options])
    }

    // MARK: - mentions

    /// "@" over the transcript: the oldest mention of you that is still unread. TDLib answers in decreasing
    /// message ids, so the oldest of the page is `last`; with `first` the button jumped to the newest mention.
    func jumpToUnreadMention() async {
        guard let chatId = openChatId,
              let found = try? await request([
                  "@type": "searchChatMessages", "chat_id": chatId, "query": "", "from_message_id": 0,
                  "offset": 0, "limit": 100, "filter": ["@type": "searchMessagesFilterUnreadMention"],
              ]),
              let node = found.tdNodes("messages").last else { return }
        let id = node.tdInt64("id")
        await jump(to: id)
        // Viewing the mention reads the chat up to it, which ghost mode promises not to do.
        guard Preferences.readsAutomatically else { return }
        _ = try? await request(["@type": "viewMessages", "chat_id": chatId, "message_ids": [id], "force_read": true])
    }

    // MARK: - stickers

    func installedStickerSets() async -> [StickerSetSummary] {
        guard let result = try? await request(["@type": "getInstalledStickerSets", "sticker_type": ["@type": "stickerTypeRegular"]]) else { return [] }
        return result.tdNodes("sets").map {
            StickerSetSummary(id: $0.tdInt64("id"), title: $0.tdString("title"),
                              cover: $0.tdNodes("covers").first.flatMap { TD.sticker($0, isEmoji: false) })
        }
    }

    func recentStickers() async -> [Sticker] {
        guard let result = try? await request(["@type": "getRecentStickers", "is_attached": false]) else { return [] }
        return result.tdNodes("stickers").compactMap { TD.sticker($0, isEmoji: false) }
    }

    func stickers(inSet id: Int64) async -> [Sticker] {
        guard let result = try? await request(["@type": "getStickerSet", "set_id": id]) else { return [] }
        return result.tdNodes("stickers").compactMap { TD.sticker($0, isEmoji: false) }
    }

    func send(_ sticker: Sticker) async {
        guard let chatId = openChatId else { return }
        if isViewingHistory { await showLatest() }
        var payload: TDNode = [
            "@type": "sendMessage",
            "chat_id": chatId,
            "options": Self.sendOptions(),
            "input_message_content": [
                "@type": "inputMessageSticker",
                "sticker": [
                    "@type": "inputSticker",
                    "sticker": ["@type": "inputFileId", "id": sticker.fileId],
                    "width": sticker.width,
                    "height": sticker.height,
                ],
                "emoji": sticker.emoji,
            ] as TDNode,
        ]
        if let context = composerContext, context.kind == .reply {
            payload["reply_to"] = TD.replyTo(context.messageId)
        }
        // Cleared only once TDLib took the message: a refused send would otherwise drop the reply it belongs to.
        guard await perform(payload) else { return }
        composerContext = nil
        await readAfterReplying(in: chatId)
    }

    // MARK: - voice messages

    /// A recorded Ogg/Opus file goes out as a voice message, with its duration and waveform.
    func sendVoiceNote(at file: URL, duration: Int, waveform: Data) async {
        await sendContent([
            "@type": "inputMessageVoiceNote",
            "voice_note": [
                "@type": "inputVoiceNote",
                "voice_note": ["@type": "inputFileLocal", "path": file.path],
                "duration": duration,
                "waveform": waveform.base64EncodedString(),
            ],
        ] as TDNode)
    }

    // MARK: - dice and places

    /// A dice or a dart thrown into the open chat; Telegram animates it and answers with what it landed on.
    func sendDice(_ emoji: String) async {
        await sendContent(["@type": "inputMessageDice", "emoji": emoji, "clear_draft": true])
    }

    /// A point on the map, typed in by hand: a desktop window has no map to pick a place from.
    func sendLocation(latitude: Double, longitude: Double) async {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return }
        await sendContent([
            "@type": "inputMessageLocation",
            "location": ["@type": "location", "latitude": latitude, "longitude": longitude, "horizontal_accuracy": 0],
        ])
    }

    /// One message of a kind the composer does not type, sent where a typed message would go.
    private func sendContent(_ content: TDNode) async {
        guard let chatId = openChatId else { return }
        if isViewingHistory { await showLatest() }
        var payload: TDNode = [
            "@type": "sendMessage",
            "chat_id": chatId,
            "options": Self.sendOptions(),
            "input_message_content": content,
        ]
        if let topic = openTopic { payload["topic_id"] = topic }
        if let context = composerContext, context.kind == .reply {
            payload["reply_to"] = TD.replyTo(context.messageId)
        }
        // Cleared only once TDLib took the message: a refused send would otherwise drop the reply it belongs to.
        guard await perform(payload) else { return }
        composerContext = nil
        await readAfterReplying(in: chatId)
    }
}
