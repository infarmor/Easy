import Foundation

/// Stories in the sidebar and a story of your own; the gallery of photos and videos.
extension AppModel {
    struct StoryChat: Identifiable, Equatable {
        var id: Int64
        var order: Int64
        /// The newest story has not been watched yet.
        var hasUnseen: Bool
        var count: Int
    }

    struct StoryTarget: Identifiable, Equatable {
        var id: Int64
        var name: String
    }

    enum MediaScope: Identifiable, Equatable {
        case everywhere
        case chat(Int64, title: String)

        var id: String {
            switch self {
            case .everywhere: "all"
            case .chat(let id, _): String(id)
            }
        }
    }

    // MARK: - stories in the sidebar

    /// Asks for the list once; TDLib then keeps it current through `updateChatActiveStories`.
    func loadStories() async {
        for _ in 0..<2 {
            guard (try? await request(["@type": "loadActiveStories", "story_list": ["@type": "storyListMain"]])) != nil else { return }
        }
    }

    /// One chat's stories changed: new ones, watched ones, or none left.
    func noteActiveStories(_ active: TDNode) {
        let chatId = active.tdInt64("chat_id")
        guard chatId != 0 else { return }
        let stories = active.tdNodes("stories")
        // Only the main list is shown; a chat moved to the hidden one, or without stories, leaves the row.
        let isListed = active.tdNode("list")?.tdType == "storyListMain"
        storyChats.removeAll { $0.id == chatId }
        guard isListed, let newest = stories.map({ $0.tdInt("story_id") }).max() else { return }
        storyChats.append(StoryChat(id: chatId, order: active.tdInt64("order"),
                                    hasUnseen: newest > active.tdInt("max_read_story_id"), count: stories.count))
        // Your own first, then what has not been watched, then Telegram's order.
        storyChats.sort { a, b in
            if (a.id == myUserId) != (b.id == myUserId) { return a.id == myUserId }
            if a.hasUnseen != b.hasUnseen { return a.hasUnseen }
            return a.order > b.order
        }
    }

    // MARK: - a story of your own

    enum StoryAudience: Hashable { case everyone, contacts }

    /// Posts a photo or a video as a story for a day. The error to show, or nil when it is up.
    func postStory(file: URL, caption: String, audience: StoryAudience) async -> String? {
        guard myUserId != 0 else { return L("Сначала войдите в аккаунт") }
        let isVideo = ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased())
        let source: TDNode = ["@type": "inputFileLocal", "path": file.path]
        let content: TDNode = isVideo
            ? ["@type": "inputStoryContentVideo", "video": source, "added_sticker_file_ids": [Int](), "duration": 0,
               "cover_frame_timestamp": 0, "is_animation": false]
            : ["@type": "inputStoryContentPhoto", "photo": source, "added_sticker_file_ids": [Int]()]
        do {
            _ = try await request([
                "@type": "postStory",
                "chat_id": myUserId,
                "content": content,
                "caption": TD.formattedText(caption.trimmingCharacters(in: .whitespacesAndNewlines)),
                "privacy_settings": audience == .everyone
                    ? ["@type": "storyPrivacySettingsEveryone", "except_user_ids": [Int64]()]
                    : ["@type": "storyPrivacySettingsContacts", "except_user_ids": [Int64]()],
                "album_ids": [Int](),
                "active_period": 86_400,
                "is_posted_to_chat_page": true,
                "protect_content": false,
            ])
            return nil
        } catch {
            let message = Self.describe(error)
            if message.contains("PREMIUM") { return L("Telegram разрешает публиковать истории этому аккаунту только с Premium") }
            if message.contains("STORIES_TOO_MUCH") { return L("Слишком много активных историй — дождитесь, пока старые истекут") }
            return message
        }
    }

    // MARK: - the gallery

    /// Photos and videos of every chat, newest first; `offset` is what the page before returned.
    func mediaEverywhere(from offset: String = "") async -> (messages: [Message], next: String)? {
        guard let found = try? await request([
            "@type": "searchMessages", "query": "", "offset": offset, "limit": 60,
            "filter": ["@type": "searchMessagesFilterPhotoAndVideo"], "min_date": 0, "max_date": 0,
        ]) else { return nil }
        return (found.tdNodes("messages").map { TD.message($0) }, found.tdString("next_offset"))
    }

    /// From the gallery to the message in its chat.
    func showFromGallery(_ message: Message) {
        mediaGallery = nil
        open(message)
    }
}
