import Foundation

/// Smaller conveniences: reminders, a reply without opening the chat, and searches that look past the
/// account or the chat on screen.
extension AppModel {
    // MARK: - reminders

    /// A reminder is what it is in Telegram itself: the message, forwarded to Saved Messages at a set time.
    func remind(about message: Message, at date: Date) async {
        guard myUserId != 0, !message.isDeleted, message.isSent else { return }
        guard (try? await request(["@type": "createPrivateChat", "user_id": myUserId, "force": false])) != nil else {
            fail(L("Не удалось открыть «Избранное»"))
            return
        }
        let sent = await perform([
            "@type": "forwardMessages",
            "chat_id": myUserId,
            "from_chat_id": message.chatId,
            "message_ids": [message.id],
            "options": Self.sendOptions(at: date),
            "send_copy": false,
            "remove_caption": false,
        ])
        if sent { showToast(L("Напоминание придёт в «Избранное»")) }
    }

    // MARK: - a reply from the chat list

    /// Sends text to a chat that is not open. Like an answer from a banner, it marks the chat read unless
    /// ghost mode says otherwise.
    func quickReply(_ text: String, to chatId: Int64) async {
        await replyFromNotification(text, to: 0, in: chatId)
    }

    // MARK: - searching

    /// Messages with these words in every chat of this account: what the sidebar shows for the accounts that
    /// are not in the window.
    func messages(matching query: String, limit: Int = 12) async -> [Message] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, isReady else { return [] }
        let found = try? await request([
            "@type": "searchMessages",
            "chat_list": ["@type": "chatListMain"],
            "query": query,
            "offset": "",
            "limit": limit,
            "min_date": 0,
            "max_date": 0,
        ])
        let messages = found?.tdNodes("messages").map { TD.message($0) } ?? []
        resolveSenders(of: messages)
        return messages
    }

    /// Deleted and edited messages kept on this Mac, by their text or any earlier version of it.
    func keptMessages(matching query: String) -> [Message] {
        archive.search(query)
    }
}
