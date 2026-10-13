import Foundation

/// The comments under a channel post. They live in the channel's discussion group, as a thread of it: the
/// group opens showing that thread only, and what is written there goes into it.
struct CommentThread: Equatable {
    /// The discussion group.
    let chatId: Int64
    let threadId: Int64
    /// Where the post is, to go back to.
    let postChatId: Int64
    let postId: Int64
    let channelTitle: String
    /// The posts the thread starts from, as copies in the group; shown above the comments.
    let roots: [Int64]
    let draft: String
}

extension AppModel {
    // MARK: - comments

    /// Opens the comments of a channel post in its discussion group.
    func openComments(of post: Message) async {
        let info: TDNode
        do {
            info = try await request(["@type": "getMessageThread", "chat_id": post.chatId, "message_id": post.id])
        } catch {
            fail(error)
            return
        }
        let groupId = info.tdInt64("chat_id")
        guard groupId != 0, info.tdInt64("message_thread_id") != 0 else {
            showToast(L("У этого поста нет комментариев"))
            return
        }
        let roots = info.tdNodes("messages")
        let thread = CommentThread(
            chatId: groupId,
            threadId: info.tdInt64("message_thread_id"),
            postChatId: post.chatId,
            postId: post.id,
            channelTitle: knownChats[post.chatId]?.title ?? "",
            roots: roots.map { $0.tdInt64("id") },
            draft: TD.draftText(of: info.tdNode("draft_message"))
        )
        if openChatId == groupId {
            await enter(thread)
        } else {
            // The chat switch clears what was open; the thread waits for the group in `select`.
            pendingThread = thread
            selection = groupId
        }
    }

    /// Back to the channel, at the post the comments were under.
    func closeComments() {
        guard let thread = commentThread else { return }
        if openChatId == thread.postChatId {
            Task { await jump(to: thread.postId) }
        } else {
            pendingJump = (chatId: thread.postChatId, messageId: thread.postId)
            selection = thread.postChatId
        }
    }

    /// Takes a thread waiting for the chat that is opening; called by `select` before the first page loads.
    func adoptPendingThread(for chatId: Int64) {
        guard let thread = pendingThread else { return }
        pendingThread = nil
        guard thread.chatId == chatId else { return }
        commentThread = thread
        draft = thread.draft
        draftBaseline = thread.draft
    }

    /// The group is already open: the transcript switches to the thread in place, as a forum's does to a topic.
    private func enter(_ thread: CommentThread) async {
        guard let chatId = openChatId, chatId == thread.chatId, commentThread != thread else { return }
        saveDraft(of: chatId)
        commentThread = thread
        messages = []
        canLoadOlder = false
        historyGeneration += 1
        endSearch()
        unreadMarkerId = nil
        highlightedMessageId = nil
        scrollTarget = nil
        draft = thread.draft
        draftBaseline = thread.draft
        await loadInitialHistory(chatId)
    }

    /// The thread's history, with the posts it starts from once its beginning is reached: they belong above
    /// the first comment. A short page is that beginning; roots already on screen are not brought again, or
    /// "load older" would never run out.
    func threadHistory(_ thread: CommentThread, from messageId: Int64, offset: Int, limit: Int) async throws -> [TDNode] {
        let page = try await request([
            "@type": "getMessageThreadHistory",
            "chat_id": thread.chatId,
            "message_id": thread.threadId,
            "from_message_id": messageId,
            "offset": offset,
            "limit": limit,
        ]).tdNodes("messages")
        guard offset == 0, page.count < limit else { return page }
        let have = Set(page.map { $0.tdInt64("id") })
        let roots = thread.roots.filter { !have.contains($0) && messageIndex[$0] == nil }
        var nodes = page
        for id in roots {
            if let node = try? await request(["@type": "getMessage", "chat_id": thread.chatId, "message_id": id]) {
                nodes.append(node)
            }
        }
        return nodes
    }

    /// Whether a message that just arrived belongs in the transcript on screen: in a forum topic or a comment
    /// thread only that topic's or thread's messages do, not the rest of the chat's.
    func belongsOnScreen(_ message: Message) -> Bool {
        guard message.chatId == openChatId else { return false }
        if let thread = commentThread {
            return message.threadId == thread.threadId || thread.roots.contains(message.id)
        }
        if let topic = openTopicId, message.topicId != 0 {
            return message.topicId == topic
        }
        return true
    }
}
