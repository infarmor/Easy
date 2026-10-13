import Foundation

/// A chat folder as the editor changes it: TDLib's `chatFolder`, field for field.
struct FolderDraft {
    var name = ""
    /// One of Telegram's icon names ("Custom", "Work", "Cat"…).
    var icon = "Custom"
    /// -1 for no colour, otherwise 0…6.
    var colorId = -1
    var pinned: [Int64] = []
    var included: [Int64] = []
    var excluded: [Int64] = []
    var includeContacts = false
    var includeNonContacts = false
    var includeGroups = false
    var includeChannels = false
    var includeBots = false
    var excludeMuted = false
    var excludeRead = false
    var excludeArchived = false
    var isShareable = false
    /// The name as Telegram had it, with any custom emoji in it: sent back as it was while the text is unchanged.
    var originalName: TDNode?

    static let maxNameLength = 12
    static let icons = ["Custom", "Unread", "Unmuted", "Bots", "Channels", "Groups", "Private", "Setup", "Cat", "Crown",
                        "Favorite", "Flower", "Game", "Home", "Love", "Mask", "Party", "Sport", "Study", "Trade",
                        "Travel", "Work", "Airplane", "Book", "Light", "Like", "Money", "Note", "Palette"]

    init() {}

    init(node: TDNode) {
        let nameNode = node.tdNode("name")
        name = nameNode?.tdText("text") ?? ""
        originalName = nameNode
        icon = node.tdNode("icon")?.tdString("name") ?? "Custom"
        colorId = node["color_id"] == nil ? -1 : node.tdInt("color_id")
        pinned = node.tdInt64s("pinned_chat_ids")
        included = node.tdInt64s("included_chat_ids")
        excluded = node.tdInt64s("excluded_chat_ids")
        includeContacts = node.tdBool("include_contacts")
        includeNonContacts = node.tdBool("include_non_contacts")
        includeGroups = node.tdBool("include_groups")
        includeChannels = node.tdBool("include_channels")
        includeBots = node.tdBool("include_bots")
        excludeMuted = node.tdBool("exclude_muted")
        excludeRead = node.tdBool("exclude_read")
        excludeArchived = node.tdBool("exclude_archived")
        isShareable = node.tdBool("is_shareable")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A folder needs a name of 1–12 characters and something in it: a chat, or a kind of chats.
    var isValid: Bool {
        (1...Self.maxNameLength).contains(trimmedName.count)
            && (!included.isEmpty || !pinned.isEmpty || includeContacts || includeNonContacts || includeGroups
                || includeChannels || includeBots)
    }

    /// Chats put in by hand, pinned ones first.
    var chosenChats: [Int64] { pinned + included.filter { !pinned.contains($0) } }

    mutating func include(_ chatId: Int64) {
        excluded.removeAll { $0 == chatId }
        if !included.contains(chatId), !pinned.contains(chatId) { included.append(chatId) }
    }

    mutating func exclude(_ chatId: Int64) {
        included.removeAll { $0 == chatId }
        pinned.removeAll { $0 == chatId }
        if !excluded.contains(chatId) { excluded.append(chatId) }
    }

    /// Off both lists: whether it shows then depends on the kinds the folder takes in.
    mutating func forget(_ chatId: Int64) {
        included.removeAll { $0 == chatId }
        pinned.removeAll { $0 == chatId }
        excluded.removeAll { $0 == chatId }
    }

    var node: TDNode {
        let nameNode: TDNode
        if let originalName, originalName.tdText("text") == trimmedName {
            nameNode = originalName
        } else {
            nameNode = [
                "@type": "chatFolderName",
                "text": ["@type": "formattedText", "text": trimmedName, "entities": [TDNode]()],
                "animate_custom_emoji": false,
            ]
        }
        return [
            "@type": "chatFolder",
            "name": nameNode,
            "icon": ["@type": "chatFolderIcon", "name": icon],
            "color_id": colorId,
            "is_shareable": isShareable,
            "pinned_chat_ids": pinned,
            "included_chat_ids": included,
            "excluded_chat_ids": excluded,
            "exclude_muted": excludeMuted,
            "exclude_read": excludeRead,
            "exclude_archived": excludeArchived,
            "include_contacts": includeContacts,
            "include_non_contacts": includeNonContacts,
            "include_bots": includeBots,
            "include_groups": includeGroups,
            "include_channels": includeChannels,
        ]
    }
}

extension AppModel {
    // MARK: - chat folders

    func loadFolder(_ id: Int) async -> FolderDraft? {
        do {
            let node = try await request(["@type": "getChatFolder", "chat_folder_id": id])
            return FolderDraft(node: node)
        } catch {
            fail(error)
            return nil
        }
    }

    /// Creates a folder when `id` is nil, otherwise changes that one. The sidebar learns of it from
    /// `updateChatFolders`.
    @discardableResult
    func saveFolder(_ folder: FolderDraft, id: Int?) async -> Bool {
        if let id {
            return await perform(["@type": "editChatFolder", "chat_folder_id": id, "folder": folder.node])
        }
        return await perform(["@type": "createChatFolder", "folder": folder.node])
    }

    /// The chats in it stay where they are; only the folder goes.
    @discardableResult
    func deleteFolder(_ id: Int) async -> Bool {
        await perform(["@type": "deleteChatFolder", "chat_folder_id": id, "leave_chat_ids": [Int64]()])
    }

    /// Folders in a new order, "Все чаты" kept where it is.
    func reorderFolders(_ ids: [Int]) async {
        await perform(["@type": "reorderChatFolders", "chat_folder_ids": ids, "main_chat_list_position": mainListPosition])
    }

    /// The chat list's "add to / remove from folder". A chat put in by hand comes off that list; one a rule
    /// took in (all groups, say) has to be excluded to leave.
    func toggle(_ chat: Chat, inFolder id: Int) async {
        guard var folder = await loadFolder(id) else { return }
        if chat.folderOrders[id] != nil {
            let wasChosen = folder.included.contains(chat.id) || folder.pinned.contains(chat.id)
            if wasChosen { folder.forget(chat.id) } else { folder.exclude(chat.id) }
        } else {
            folder.include(chat.id)
        }
        await saveFolder(folder, id: id)
    }
}
