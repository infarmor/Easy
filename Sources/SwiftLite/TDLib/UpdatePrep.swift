import Foundation

/// Fields of a message that `updateMessageContent` replaces, built off the main thread.
struct MessageContentPatch {
    var body: Message.Body
    var attachment: Attachment?
    var sticker: Sticker?
    var media: MediaInfo?
    var caption: String
    var entities: [TextEntity]
    var linkPreview: LinkPreview?
    var document: DocumentInfo?
    var location: LocationInfo?
    var contact: ContactInfo?
    var dice: Dice?
    var poll: Poll?

    static func from(content: TDNode) -> MessageContentPatch {
        MessageContentPatch(
            body: TD.body(of: content),
            attachment: TD.attachment(of: content),
            sticker: TD.sticker(of: content),
            media: TD.media(of: content),
            caption: content.tdText("caption"),
            entities: TD.entities(of: content),
            linkPreview: TD.linkPreview(content.tdNode("link_preview")),
            document: TD.document(of: content),
            location: TD.location(of: content),
            contact: TD.contact(of: content),
            dice: TD.dice(of: content),
            poll: TD.poll(content.tdNode("poll"))
        )
    }

    func apply(to message: inout Message) {
        message.body = body
        message.attachment = attachment
        message.sticker = sticker
        message.media = media
        message.caption = caption
        message.entities = entities
        message.linkPreview = linkPreview
        message.document = document
        message.location = location
        message.contact = contact
        message.dice = dice
        message.poll = poll
    }
}

/// A TDLib update with its expensive models already built. JSON parsing happens on the receive thread;
/// `UpdatePrep` turns the hot payloads into value types on a background queue so `AppModel` on the main
/// actor only merges them into its store.
struct PreparedUpdate {
    let raw: TDNode
    var message: Message?
    var chat: Chat?
    var content: MessageContentPatch?
    var transfer: (fileId: Int, value: FileTransfer)?
    var poll: Poll?
    var userName: String?
    var userPhoto: ProfilePhoto?
    var userBadge: NameBadge?
    var presence: UserPresence?
    var isBot: Bool?
    var folders: [ChatFolder]?
    var draftText: String?
    var markup: ReplyMarkup?
    var interaction: TDNode?
}

enum UpdatePrep {
    /// Pure mapping: safe on any thread. The raw node is kept for fields that still need a main-actor
    /// look-up (open chat, recent-message cache, and the like).
    static func prepare(_ update: TDNode) -> PreparedUpdate {
        var prepared = PreparedUpdate(raw: update)
        switch update.tdType {
        case "updateNewMessage", "updateMessageSendSucceeded", "updateMessageSendFailed":
            prepared.message = update.tdNode("message").map(TD.message)

        case "updateNewChat":
            if let node = update.tdNode("chat") {
                prepared.chat = TD.chat(node)
                prepared.message = node.tdNode("last_message").map(TD.message)
            }

        case "updateChatLastMessage":
            prepared.message = update.tdNode("last_message").map(TD.message)

        case "updateChatDraftMessage":
            prepared.draftText = TD.draftText(of: update.tdNode("draft_message"))

        case "updateMessageContent":
            prepared.content = MessageContentPatch.from(content: update.tdNode("new_content") ?? [:])

        case "updateMessageEdited":
            prepared.markup = TD.replyMarkup(update.tdNode("reply_markup"))

        case "updateMessageInteractionInfo":
            prepared.interaction = update.tdNode("interaction_info")

        case "updateFile":
            if let file = update.tdNode("file") {
                prepared.transfer = (file.tdInt("id"), TD.transfer(file))
            }

        case "updatePoll":
            prepared.poll = TD.poll(update.tdNode("poll"))

        case "updateUser":
            if let user = update.tdNode("user") {
                prepared.userName = TD.displayName(ofUser: user)
                prepared.userPhoto = TD.photo(user.tdNode("profile_photo"))
                prepared.userBadge = TD.nameBadge(
                    status: user.tdNode("emoji_status"),
                    isPremium: user.tdBool("is_premium")
                )
                prepared.presence = TD.presence(user.tdNode("status"))
                prepared.isBot = user.tdNode("type")?.tdType == "userTypeBot"
            }

        case "updateUserStatus":
            prepared.presence = TD.presence(update.tdNode("status"))

        case "updateChatEmojiStatus":
            prepared.userBadge = TD.nameBadge(status: update.tdNode("emoji_status"), isPremium: false)

        case "updateChatPhoto":
            prepared.userPhoto = TD.photo(update.tdNode("photo"))

        case "updateChatFolders":
            prepared.folders = update.tdNodes("chat_folders").map {
                ChatFolder(
                    id: $0.tdInt("id"),
                    title: $0.tdNode("name")?.tdText("text") ?? "",
                    icon: $0.tdNode("icon")?.tdString("name") ?? "",
                    colorId: $0["color_id"] == nil ? -1 : $0.tdInt("color_id")
                )
            }

        default:
            break
        }
        return prepared
    }
}
