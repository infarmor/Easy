import AppKit
import Foundation

/// The chat list, folders, and what an admin does to a group or channel: members, rights, invite links,
/// statistics and forum topics.
extension AppModel {
    // MARK: - chats

    /// Loads the list the sidebar shows: the main one or the archive.
    func loadChats() async {
        let chatList: TDNode
        let list: String
        if showsArchive {
            chatList = ["@type": "chatListArchive"]
            list = "chatListArchive"
        } else if let folder = selectedFolder {
            chatList = ["@type": "chatListFolder", "chat_folder_id": folder]
            list = "chatListFolder\(folder)"
        } else {
            chatList = ["@type": "chatListMain"]
            list = "chatListMain"
        }
        guard bridge != nil, isReady, !loadingChatLists.contains(list) else { return }
        loadingChatLists.insert(list)
        defer { loadingChatLists.remove(list) }

        // Chats and their positions arrive through updates; TDLib answers 404 once the list is complete.
        for _ in 0..<20 {
            do {
                _ = try await request(["@type": "loadChats", "chat_list": chatList, "limit": 100])
            } catch let error as TDError where error.isNotFound {
                return
            } catch {
                fail(error)
                return
            }
        }
    }

    /// The chat that was open when the app was last used opens again, once TDLib has told about it. Only for
    /// the account it belonged to, and only while nothing else has been opened in the meantime.
    func reopenLastChat() {
        let parts = (UserDefaults.standard.string(forKey: Preferences.lastChat) ?? "").split(separator: ":")
        guard parts.count == 2, Int64(parts[0]) == myUserId, let chatId = Int64(parts[1]) else { return }
        Task {
            // Chats arrive over the first seconds; a chat that never does (left, deleted) is simply not opened.
            for _ in 0..<60 {
                guard selection == nil, isReady else { return }
                if knownChats[chatId] != nil {
                    selection = chatId
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// ⌥⇧↓ and ⌥⇧↑: the next chat of the list on screen that has something unread, wrapping around.
    func selectUnreadChat(_ step: Int) {
        let list = visibleChats
        let waiting = list.indices.filter { list[$0].unread > 0 || list[$0].isMarkedUnread || list[$0].unreadMentions > 0 }
        guard !waiting.isEmpty else {
            showToast("Непрочитанных нет")
            return
        }
        let current = list.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : list.count)
        let next = step > 0 ? (waiting.first { $0 > current } ?? waiting[0]) : (waiting.last { $0 < current } ?? waiting[waiting.count - 1])
        selection = list[next].id
    }

    /// Chats of the place on screen that have something unread.
    var unreadChatsOnScreen: [Chat] {
        chats.filter { $0.unread > 0 || $0.isMarkedUnread }
    }

    /// "Прочитать всё" of the folder menu.
    func markAllRead(_ list: [Chat]) async {
        for chat in list { await markRead(chat.id) }
        if !list.isEmpty { showToast("Прочитано: \(TD.count(list.count, "чат", "чата", "чатов"))") }
    }

    func markSelectedRead() async {
        guard let chatId = openChatId ?? selection else { return }
        await markRead(chatId)
    }

    func markChatRead(_ chat: Chat) async {
        await markRead(chat.id)
    }

    func markChatUnread(_ chat: Chat) async {
        await perform(["@type": "toggleChatIsMarkedAsUnread", "chat_id": chat.id, "is_marked_as_unread": true])
    }

    /// Pins in the list on screen: an open folder has its own pinned chats, and `chat.isPinned` of a row in it
    /// is the folder's pin, so pinning there must go to the folder, not the main list.
    func toggleChatPinned(_ chat: Chat) async {
        let list: TDNode
        if !showsArchive, let folder = selectedFolder {
            list = ["@type": "chatListFolder", "chat_folder_id": folder]
        } else {
            list = ["@type": chat.isArchived ? "chatListArchive" : "chatListMain"]
        }
        await perform([
            "@type": "toggleChatIsPinned",
            "chat_list": list,
            "chat_id": chat.id,
            "is_pinned": !chat.isPinned,
        ])
    }

    /// A chat is in either the main list or the archive; TDLib moves it out of the other one.
    func toggleChatArchived(_ chat: Chat) async {
        await perform([
            "@type": "addChatToList",
            "chat_id": chat.id,
            "chat_list": ["@type": chat.isArchived ? "chatListMain" : "chatListArchive"],
        ])
    }

    func toggleChatMuted(_ chat: Chat) async {
        // Only the mute fields change; sound, previews and the rest are sent back as they were.
        var settings = chatNotificationSettings[chat.id] ?? [
            "@type": "chatNotificationSettings",
            "use_default_sound": true,
            "use_default_show_preview": true,
            "use_default_mute_stories": true,
            "use_default_story_sound": true,
            "use_default_show_story_poster": true,
            "use_default_disable_pinned_message_notifications": true,
            "use_default_disable_mention_notifications": true,
        ]
        settings["use_default_mute_for"] = false
        // Anything longer than TDLib's precise range counts as "forever".
        settings["mute_for"] = chat.isMuted ? 0 : Int(Int32.max)
        await perform(["@type": "setChatNotificationSettings", "chat_id": chat.id, "notification_settings": settings])
    }

    /// Chats a message can be forwarded to: the main list first, then the archive.
    func forwardTargets(matching query: String) -> [Chat] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = listableChats
        let main = candidates.filter { $0.order != 0 }.sorted(by: TD.precedes)
        let archived = candidates.filter(\.isArchived).sorted { $0.archiveOrder > $1.archiveOrder }
        return (main + archived).filter { needle.isEmpty || $0.title.lowercased().contains(needle) }
    }

    func prepareForwarding(_ messages: [Message], fromSelection: Bool = false) {
        let sendable = messages.filter { $0.isSent && !$0.isDeleted }
        guard !sendable.isEmpty else { return }
        forwardingBatch = ForwardBatch(messages: sendable, endsSelection: fromSelection)
    }

    func forward(_ batch: [Message], to chat: Chat, endsSelection: Bool = false) async {
        guard let first = batch.first else { return }
        // Albums go whole; TDLib wants the ids in increasing order.
        let ids = Array(Set(batch.flatMap { albumIds(of: $0) })).sorted()
        do {
            if ids.count == 1 {
                let properties = try await request([
                    "@type": "getMessageProperties",
                    "chat_id": first.chatId,
                    "message_id": first.id,
                ])
                guard properties.tdBool("can_be_forwarded") else {
                    fail("Это сообщение нельзя переслать")
                    return
                }
            }
            let sent = try await request([
                "@type": "forwardMessages",
                "chat_id": chat.id,
                "from_chat_id": first.chatId,
                "message_ids": ids,
                "options": ["@type": "messageSendOptions", "disable_notification": false],
                "send_copy": false,
                "remove_caption": false,
            ])
            // A message TDLib could not forward comes back as null.
            let failed = (sent["messages"] as? [Any])?.filter { $0 is NSNull }.count ?? 0
            if failed > 0 {
                fail(ids.count == 1 ? "Не удалось переслать в «\(chat.title)»" : "Не удалось переслать \(failed) из \(ids.count) в «\(chat.title)»")
            } else {
                showToast("Переслано в «\(chat.title.isEmpty ? "чат" : chat.title)»")
            }
            // Only forwarding from the selection bar ends picking; one message sent from its menu leaves it be.
            if isSelectingMessages, endsSelection { endSelection() }
        } catch {
            fail(error)
        }
    }

    // MARK: - chat management

    /// Private chats: gone from the list, and for everyone when asked. Groups and channels: left.
    func deleteChat(_ chat: Chat, forEveryone: Bool) async {
        markClearing(chat.id)
        // The session is ended first, so the other side sees the chat close rather than go quiet.
        if chat.kind == .secret, chat.secretChatId != 0, chat.secretState != .closed {
            _ = try? await request(["@type": "closeSecretChat", "secret_chat_id": chat.secretChatId])
        }
        if chat.kind == .personal || chat.kind == .secret {
            await perform(["@type": "deleteChatHistory", "chat_id": chat.id, "remove_from_chat_list": true, "revoke": forEveryone])
        } else {
            await perform(["@type": "leaveChat", "chat_id": chat.id])
        }
        if selection == chat.id { selection = nil }
    }

    func clearHistory(of chat: Chat, forEveryone: Bool) async {
        markClearing(chat.id)
        await perform(["@type": "deleteChatHistory", "chat_id": chat.id, "remove_from_chat_list": false, "revoke": forEveryone])
        if openChatId == chat.id { messages = [] }
    }

    /// TDLib reports a cleared history as a stream of deletions for a while after the request.
    private func markClearing(_ chatId: Int64) {
        // Counted, not just marked: a second clearing of the same chat inside the half minute used to be
        // cut short by the first one's timer, and the deletions that followed were kept as someone else's.
        clearingChats[chatId, default: 0] += 1
        Task {
            try? await Task.sleep(for: .seconds(30))
            if let left = clearingChats[chatId] { clearingChats[chatId] = left > 1 ? left - 1 : nil }
        }
    }

    func setBlocked(_ blocked: Bool, userId: Int64) async -> Bool {
        var payload: TDNode = [
            "@type": "setMessageSenderBlockList",
            "sender_id": ["@type": "messageSenderUser", "user_id": userId],
        ]
        if blocked { payload["block_list"] = ["@type": "blockListMain"] }
        do {
            _ = try await request(payload)
            showToast(blocked ? "Заблокирован" : "Разблокирован")
            return true
        } catch {
            fail(error)
            return false
        }
    }

    // MARK: - members and administration

    /// Whether the state of this chat is still on screen. The management sheet is opened from the sidebar's
    /// context menu, so its chat is not necessarily the open one — and its loaders used to ask only about
    /// the open chat, which left the sheet empty for any chat the user had not just clicked.
    func isBeingShown(_ chatId: Int64) -> Bool {
        openChatId == chatId || managedChat?.id == chatId
    }

    /// The supergroup behind a chat; nil for private chats, bots and the old basic groups.
    private func supergroupId(of chat: Chat) -> Int64? {
        chat.groupKey.hasPrefix("s") ? Int64(chat.groupKey.dropFirst()) : nil
    }

    /// Who you are in this chat and what that lets you do.
    func loadAccess(of chat: Chat) async {
        // Another chat's answer cannot stand in for this one, so its data goes first. A reload of the chat
        // already on screen keeps what is there until a fresh answer arrives: these two requests are refused
        // often enough that clearing up front would take the topic "+" and the admin menu away for the rest
        // of the session, with nothing on screen to explain why.
        if accessChatId != chat.id {
            accessChatId = chat.id
            chatAccess = ChatAccess()
            members = []
            inviteLinks = []
        }
        guard let id = supergroupId(of: chat) else { return }
        let group = try? await request(["@type": "getSupergroup", "supergroup_id": id])
        let full = try? await request(["@type": "getSupergroupFullInfo", "supergroup_id": id])
        guard isBeingShown(chat.id), let group else { return }
        chatAccess = TD.access(group: group, full: full ?? [:])
    }

    /// A page of members. `query` searches by name; empty gives the ones seen last.
    func loadMembers(of chat: Chat, query: String = "") async {
        guard let id = supergroupId(of: chat) else { return }
        isLoadingMembers = true
        defer { isLoadingMembers = false }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter: TDNode = search.isEmpty
            ? ["@type": "supergroupMembersFilterRecent"]
            : ["@type": "supergroupMembersFilterSearch", "query": search]
        guard let result = try? await request([
            "@type": "getSupergroupMembers", "supergroup_id": id, "filter": filter, "offset": 0, "limit": 200,
        ]), isBeingShown(chat.id) else { return }
        var loaded: [ChatMemberInfo] = []
        // Names cost one request each, so only the ones the transcript never showed are looked up.
        var missing = 40
        for row in result.tdNodes("members") {
            var member = TD.member(row, name: "", photo: nil)
            guard member.userId != 0 else { continue }
            if let name = senderNames["u\(member.userId)"] {
                member.name = name
                member.photo = senderPhotos["u\(member.userId)"]
            } else if missing > 0 {
                missing -= 1
                if let user = try? await request(["@type": "getUser", "user_id": member.userId]) {
                    member.name = TD.displayName(ofUser: user)
                    member.photo = TD.photo(user.tdNode("profile_photo"))
                    remember(member.name, for: "u\(member.userId)")
                    remember(member.photo, for: "u\(member.userId)")
                }
            }
            loaded.append(member)
        }
        guard isBeingShown(chat.id) else { return }
        membersTotal = result.tdInt("total_count")
        members = loaded
    }

    /// Out of the chat for a while or for good. Their messages can go with them.
    func banMember(_ member: ChatMemberInfo, in chat: Chat, minutes: Int, revokeMessages: Bool) async -> Bool {
        let done = await perform([
            "@type": "banChatMember",
            "chat_id": chat.id,
            "member_id": Self.userSender(member.userId),
            "banned_until_date": Self.untilDate(minutes),
            "revoke_messages": revokeMessages,
        ])
        if done { showToast("\(member.name.isEmpty ? "Участник" : member.name) в списке забаненных") }
        return done
    }

    /// Kicked from the chat, or the ban lifted: both are the plain "left" status.
    func removeMember(_ member: ChatMemberInfo, in chat: Chat) async -> Bool {
        await perform(["@type": "setChatMemberStatus", "chat_id": chat.id, "member_id": Self.userSender(member.userId),
                       "status": ["@type": "chatMemberStatusLeft"]])
    }

    /// Silence instead of a ban: the person stays in the chat and may only do what `permissions` allows.
    func restrictMember(_ member: ChatMemberInfo, in chat: Chat, minutes: Int, permissions: [String: Bool] = [:]) async -> Bool {
        await perform([
            "@type": "setChatMemberStatus", "chat_id": chat.id, "member_id": Self.userSender(member.userId),
            "status": [
                "@type": "chatMemberStatusRestricted", "is_member": true,
                "restricted_until_date": Self.untilDate(minutes),
                "permissions": Rights.build(type: "chatPermissions", Rights.permissions, permissions),
            ],
        ])
    }

    /// Admin with an explicit set of rights; nil hands them back to an ordinary member.
    func setMember(_ member: ChatMemberInfo, in chat: Chat, rights: [String: Bool]?) async -> Bool {
        let status: TDNode = rights.map {
            ["@type": "chatMemberStatusAdministrator",
             "rights": Rights.build(type: "chatAdministratorRights", Rights.admin, $0)]
        } ?? ["@type": "chatMemberStatusMember"]
        return await perform(["@type": "setChatMemberStatus", "chat_id": chat.id,
                              "member_id": Self.userSender(member.userId), "status": status])
    }

    /// The member list carries rights too, but it is a page of many chats' worth of guesses; the editor asks
    /// the one member before it lets anything be changed.
    func loadMember(_ member: ChatMemberInfo, in chat: Chat) async -> ChatMemberInfo? {
        guard let node = try? await request(["@type": "getChatMember", "chat_id": chat.id,
                                             "member_id": Self.userSender(member.userId)]) else { return nil }
        return TD.member(node, name: member.name, photo: member.photo)
    }

    /// Everything this member ever said in the chat; needs the "can delete messages" right.
    func deleteMessages(by member: ChatMemberInfo, in chat: Chat) async -> Bool {
        guard BotDialogs.ask("Удалить сообщения «\(member.name)»?",
                             "Из чата у всех пропадут все сообщения этого участника.", action: "Удалить") else { return false }
        let done = await perform(["@type": "deleteChatMessagesBySender", "chat_id": chat.id,
                                  "sender_id": Self.userSender(member.userId)])
        if done { showToast("Сообщения участника удалены") }
        return done
    }

    private static func userSender(_ userId: Int64) -> TDNode {
        ["@type": "messageSenderUser", "user_id": userId]
    }

    /// TDLib reads 0 as "never", which for a ban is the same as forever.
    private static func untilDate(_ minutes: Int) -> Int {
        minutes > 0 ? Int(Date().timeIntervalSince1970) + minutes * 60 : 0
    }

    // MARK: - invite links

    /// Links this account created. The chat's own link comes with `loadAccess`.
    func loadInviteLinks(of chat: Chat) async {
        guard chatAccess.canInvite, let result = try? await request([
            "@type": "getChatInviteLinks", "chat_id": chat.id, "creator_user_id": myUserId,
            "is_revoked": false, "offset_date": 0, "offset_invite_link": "", "limit": 50,
        ]) else { return }
        guard isBeingShown(chat.id) else { return }
        inviteLinks = result.tdNodes("invite_links").map { TD.inviteLink($0) }
    }

    /// A link that dies after `days` or after `memberLimit` people have used it; 0 for neither.
    func createInviteLink(in chat: Chat, name: String, memberLimit: Int, days: Int) async -> Bool {
        let done = await perform([
            "@type": "createChatInviteLink", "chat_id": chat.id, "name": name,
            "expiration_date": days > 0 ? Int(Date().timeIntervalSince1970) + days * 86_400 : 0,
            "member_limit": memberLimit, "creates_join_request": false,
        ])
        if done { await loadInviteLinks(of: chat) }
        return done
    }

    func revokeInviteLink(_ link: InviteLinkInfo, in chat: Chat) async -> Bool {
        let done = await perform(["@type": "revokeChatInviteLink", "chat_id": chat.id, "invite_link": link.url])
        if done { await loadInviteLinks(of: chat) }
        return done
    }

    /// The old one stops working at once, so it is asked for first.
    func replacePrimaryInviteLink(in chat: Chat) async -> Bool {
        guard BotDialogs.ask("Сменить ссылку чата?", "Старая ссылка перестанет работать.", action: "Сменить") else { return false }
        guard let link = try? await request(["@type": "replacePrimaryChatInviteLink", "chat_id": chat.id]) else {
            fail("Ссылку сменить не удалось")
            return false
        }
        let url = link.tdString("invite_link")
        guard !url.isEmpty else { return false }
        if isBeingShown(chat.id) { chatAccess.primaryLink = url }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        showToast("Новая ссылка скопирована")
        return true
    }

    /// Name and description of the chat; the error to show, or nil. Each field is sent on its own: a refused
    /// rename must not leave the description unsaved.
    func setChatInfo(_ chat: Chat, title: String, description: String) async -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Название не может быть пустым" }
        var problem: String?
        if title != chat.title {
            do { _ = try await request(["@type": "setChatTitle", "chat_id": chat.id, "title": title]) }
            catch { problem = Self.describe(error) }
        }
        if description != chatAccess.about {
            do {
                _ = try await request(["@type": "setChatDescription", "chat_id": chat.id, "description": description])
                // Kept as the new baseline: without it a second save of the same text is compared against the
                // old one, and a change back to the original would look like nothing to do.
                chatAccess.about = description
            }
            catch { problem = problem ?? Self.describe(error) }
        }
        return problem
    }

    // MARK: - channel statistics

    /// The channel's own numbers; the card in the management sheet reads them after this returns.
    func loadStatistics(of chat: Chat) async {
        statistics = nil
        let node = try? await request(["@type": "getChatStatistics", "chat_id": chat.id, "is_dark": false])
        guard isBeingShown(chat.id), let node, let stats = TD.stats(node) else { return }
        statistics = stats
    }

    // MARK: - forum topics

    static func topicNode(_ id: Int32) -> TDNode {
        ["@type": "messageTopicForum", "forum_topic_id": Int(id)]
    }

    /// The topic the composer works in, as TDLib wants it.
    var openTopic: TDNode? {
        openTopicId.map { Self.topicNode($0) }
    }

    /// The topic list of a forum. `query` searches on the server, by topic name.
    func loadTopics(of chatId: Int64, query: String = "") async {
        guard isReady else { return }
        let result = try? await request([
            "@type": "getForumTopics", "chat_id": chatId, "query": query,
            "offset_date": 0, "offset_message_id": 0, "offset_forum_topic_id": 0, "limit": 100,
        ])
        guard openChatId == chatId, let result else { return }
        topics = result.tdNodes("topics").map { TD.topic($0) }
    }

    /// Shows one topic's history, or the whole chat again when `id` is nil.
    func open(topic id: Int32?) async {
        guard let chatId = openChatId, id != openTopicId else { return }
        saveDraft(of: chatId)
        openTopicId = id
        messages = []
        canLoadOlder = false
        historyGeneration += 1
        // Matches and the unread marker were found in the topic that was on screen, not in this one.
        endSearch()
        unreadMarkerId = nil
        highlightedMessageId = nil
        scrollTarget = nil
        let draftOfTopic = id.flatMap { topic in topics.first { $0.id == topic }?.draft } ?? ""
        draft = draftOfTopic
        draftBaseline = draftOfTopic
        await loadInitialHistory(chatId)
    }

    /// A new topic. Left without a name Telegram calls it after its first message.
    func createTopic(in chatId: Int64, name: String) async -> Bool {
        let done = await perform([
            "@type": "createForumTopic", "chat_id": chatId, "name": name, "is_name_implicit": name.isEmpty,
            "icon": ["@type": "forumTopicIcon", "color": 0x6FB9F0, "custom_emoji_id": 0],
        ])
        if done { await loadTopics(of: chatId) }
        return done
    }

    func setTopic(_ topic: Topic, in chatId: Int64, closed: Bool) async -> Bool {
        let done = await perform(["@type": "toggleForumTopicIsClosed", "chat_id": chatId,
                                  "forum_topic_id": Int(topic.id), "is_closed": closed])
        if done { await loadTopics(of: chatId) }
        return done
    }

    func renameTopic(_ topic: Topic, in chatId: Int64, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != topic.name else { return false }
        let done = await perform([
            "@type": "editForumTopic", "chat_id": chatId, "forum_topic_id": Int(topic.id), "name": trimmed,
            "edit_icon_custom_emoji": false, "icon_custom_emoji_id": 0,
        ])
        if done { await loadTopics(of: chatId) }
        return done
    }

    /// A link to one topic. TDLib builds it offline, from the chat's own address.
    func copyTopicLink(_ topic: Topic, in chatId: Int64) async {
        guard let link = try? await request(["@type": "getForumTopicLink", "chat_id": chatId,
                                             "forum_topic_id": Int(topic.id)]) else { return }
        let url = link.tdString("link")
        guard !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        showToast("Ссылку на «\(topic.name)» скопировали")
    }

    /// A message of a forum belongs to one topic: its unread count moves with it.
    func noteTopic(of message: Message) {
        guard message.topicId != 0, let index = topics.firstIndex(where: { $0.id == message.topicId }) else { return }
        if message.isOutgoing || message.isService { return }
        topics[index].unread += 1
        topics[index].snippet = TD.snippet(of: message)
    }
}
