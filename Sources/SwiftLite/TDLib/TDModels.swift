import AVFoundation
import Foundation
import ImageIO

enum ChatKind: Equatable {
    case personal, group, channel, secret, other

    var label: String {
        switch self {
        case .personal: "личный чат"
        case .group: "группа"
        case .channel: "канал"
        case .secret: "секретный чат"
        case .other: "чат"
        }
    }
}

/// A secret chat exists on this Mac only and has to be agreed on by both sides before anything can be said.
enum SecretChatState: Equatable {
    /// The other side has not come online to accept it yet.
    case pending
    case ready
    /// Ended by either side; its history stays, nothing more can be sent.
    case closed

    init?(_ node: TDNode?) {
        switch node?.tdType {
        case "secretChatStatePending": self = .pending
        case "secretChatStateReady": self = .ready
        case "secretChatStateClosed": self = .closed
        default: return nil
        }
    }
}

struct Chat: Identifiable, Equatable {
    var id: Int64
    var title: String
    var kind: ChatKind
    /// Position in the main chat list; 0 means the chat is not in it (archived, left, only referenced).
    /// `AppModel.chats` puts the archive position here while the archive is shown.
    var order: Int64
    var isPinned: Bool
    /// Position in the archive; 0 means the chat is not archived.
    var archiveOrder: Int64
    var isPinnedInArchive: Bool
    var unread: Int
    var isMarkedUnread: Bool
    var snippet: String
    var snippetDate: Date?
    /// First name of whoever wrote the last message of a group, shown before the preview ("Иван: …").
    var snippetSender: String = ""
    var lastReadInboxId: Int64
    var lastReadOutboxId: Int64
    /// Newest message with a server id: `viewMessages` needs one to mark the chat read.
    var lastMessageId: Int64
    var unreadMentions: Int
    var unreadReactions: Int
    var draftText: String
    /// Own setting or the scope default; `AppModel.chats` fills it in.
    var isMuted: Bool
    var photo: ProfilePhoto?
    /// The other user of a private chat; 0 for groups and channels.
    var userId: Int64
    /// "s<id>" for supergroups and channels, "b<id>" for basic groups: member counts arrive with those objects.
    var groupKey: String
    /// Last seen of the other user in a private chat; nil for groups, channels and unknown users.
    var presence: UserPresence?
    var isBot: Bool
    var memberCount: Int
    var onlineMemberCount: Int
    /// "печатает…" and the like; empty while nobody in the chat is doing anything.
    var activity: String
    /// The message whose keyboard a bot put under the composer; 0 when there is none.
    var replyMarkupMessageId: Int64 = 0
    /// A supergroup split into topics. TDLib does not say it in the chat object, so the client learns it from
    /// the messages: only a forum's messages carry a topic id.
    var isForum = false
    /// Order in each chat folder the chat is in, by folder id (Telegram's "Личные", "Каналы"…).
    var folderOrders: [Int: Int64] = [:]
    /// Folders where the chat is pinned to the top.
    var pinnedInFolders: Set<Int> = []
    /// The end-to-end encrypted session behind a secret chat; 0 for every other kind.
    var secretChatId: Int = 0
    /// Where that session stands; nil until TDLib has said, and for every other kind of chat.
    var secretState: SecretChatState?

    var isArchived: Bool { archiveOrder != 0 }
    /// Only a supergroup or a channel has a member list TDLib can page through; a basic group and a private
    /// chat do not, so nothing that offers "its people" should pretend otherwise.
    var hasRoster: Bool { groupKey.hasPrefix("s") }
}

/// A chat or profile photo: the small 160×160 JPEG plus the blurred inline preview shown while it downloads.
struct ProfilePhoto: Equatable {
    var fileId: Int
    /// Non-empty when TDLib already has the file on disk.
    var localPath: String
    var minithumbnail: Data?
}

/// Last seen of a user, as precise as their privacy settings allow.
enum UserPresence: Equatable {
    case online
    case offline(since: Date)
    case recently
    case lastWeek
    case lastMonth
    case longAgo
}

/// What this account may do in a group or a channel, read from the group's own status fields.
struct ChatAccess: Equatable {
    var isCreator = false
    var isAdmin = false
    var canChangeInfo = false
    var canInvite = false
    var canRestrict = false
    var canPromote = false
    var canDeleteMessages = false
    var canManageTopics = false
    /// Hidden member lists refuse `getSupergroupMembers` all together.
    var canGetMembers = false
    var isChannel = false
    var about = ""
    /// The group's own link, when it has one.
    var primaryLink = ""
    var memberCount = 0

    var canManage: Bool { isCreator || isAdmin }
}

/// One member of a group or channel, and what they may do there.
struct ChatMemberInfo: Identifiable, Equatable {
    enum Rank: Equatable {
        case owner, admin, member, restricted, banned

        var label: String {
            switch self {
            case .owner: return "владелец"
            case .admin: return "администратор"
            case .member: return "участник"
            case .restricted: return "ограничен"
            case .banned: return "забанен"
            }
        }
    }

    /// 0 when the member is a chat rather than a person; those cannot be listed or changed from here.
    var userId: Int64
    var name = ""
    var photo: ProfilePhoto?
    var rank: Rank = .member
    /// Whether this account may change them; TDLib decides that by the ranks of both.
    var canBeEdited = false
    /// Their admin rights, keyed by TDLib's own field names; empty unless they are an administrator.
    var rights: [String: Bool] = [:]
    /// What a restricted member is left allowed to do.
    var permissions: [String: Bool] = [:]
    /// When a ban or a restriction ends; 0 means forever, or that neither applies.
    var untilDate = 0

    var id: Int64 { userId }
}

/// Headline numbers of a channel. TDLib also returns graphs for the same figures, but those come as a
/// chart specification rather than numbers, and nothing here draws that.
struct ChannelStats: Equatable {
    var from: Date
    var to: Date
    var members: Double
    var membersGrowth: Double
    var meanViews: Double
    var meanShares: Double
    var meanReactions: Double
}

/// An invite link of a group or channel. `getChatInviteLinks` is asked for the active ones this account made.
struct InviteLinkInfo: Identifiable, Equatable {
    var url: String
    var name: String
    /// nil means the link does not expire.
    var expirationDate: Date?
    /// 0 means no limit on the number of people who may join.
    var memberLimit = 0
    var memberCount = 0

    var id: String { url }
}

/// One switch of a Telegram rights object: TDLib's field name and what it is called here.
struct RightsFlag: Identifiable {
    var key: String
    var label: String
    var id: String { key }
}

/// The two rights objects TDLib uses for administrators and for restricted members. Telegram itself offers
/// these as check boxes, so they are listed here rather than guessed at by whoever builds a request.
enum Rights {
    static let admin: [RightsFlag] = [
        .init(key: "can_manage_chat", label: "Управлять чатом"),
        .init(key: "can_change_info", label: "Менять название и фото"),
        .init(key: "can_post_messages", label: "Публиковать в канале"),
        .init(key: "can_edit_messages", label: "Редактировать чужие сообщения"),
        .init(key: "can_delete_messages", label: "Удалять сообщения"),
        .init(key: "can_invite_users", label: "Приглашать участников"),
        .init(key: "can_restrict_members", label: "Ограничивать участников"),
        .init(key: "can_pin_messages", label: "Закреплять сообщения"),
        .init(key: "can_manage_topics", label: "Управлять темами"),
        .init(key: "can_promote_members", label: "Назначать администраторов"),
        .init(key: "can_manage_video_chats", label: "Управлять видеочатами"),
        .init(key: "can_post_stories", label: "Публиковать истории"),
        .init(key: "can_edit_stories", label: "Редактировать истории"),
        .init(key: "can_delete_stories", label: "Удалять истории"),
        .init(key: "can_manage_direct_messages", label: "Писать лично от имени чата"),
        .init(key: "can_manage_tags", label: "Выдавать участникам метки"),
        .init(key: "can_send_welcome_messages", label: "Приветственные сообщения"),
        .init(key: "is_anonymous", label: "Действовать анонимно"),
    ]

    static let permissions: [RightsFlag] = [
        .init(key: "can_send_basic_messages", label: "Писать сообщения"),
        .init(key: "can_send_audios", label: "Аудио"),
        .init(key: "can_send_documents", label: "Файлы"),
        .init(key: "can_send_photos", label: "Фото"),
        .init(key: "can_send_videos", label: "Видео"),
        .init(key: "can_send_video_notes", label: "Видеосообщения"),
        .init(key: "can_send_voice_notes", label: "Голосовые"),
        .init(key: "can_send_polls", label: "Опросы"),
        .init(key: "can_send_other_messages", label: "Стикер, GIF и прочее"),
        .init(key: "can_add_link_previews", label: "Превью ссылок"),
        .init(key: "can_react_to_messages", label: "Ставить реакции"),
        .init(key: "can_edit_tag", label: "Менять свою метку"),
        .init(key: "can_change_info", label: "Менять информацию чата"),
        .init(key: "can_invite_users", label: "Приглашать участников"),
        .init(key: "can_pin_messages", label: "Закреплять сообщения"),
        .init(key: "can_create_topics", label: "Создавать темы"),
    ]

    /// The rights an editor of a group gets by default: everything but the ones that hand the chat away.
    static let editorDefaults: [String: Bool] = [
        "can_manage_chat": true, "can_change_info": true, "can_post_messages": true, "can_edit_messages": true,
        "can_delete_messages": true, "can_invite_users": true, "can_restrict_members": true,
        "can_pin_messages": true, "can_manage_topics": true,
    ]

    /// Only the flags we know about; anything else TDLib sends is not something this UI can edit.
    static func read(_ node: TDNode) -> [String: Bool] {
        var values: [String: Bool] = [:]
        for flag in admin + permissions where node[flag.key] != nil && values[flag.key] == nil {
            values[flag.key] = node.tdBool(flag.key)
        }
        return values
    }

    /// A complete rights object: TDLib reads a missing field as false, and a half-filled request would
    /// quietly take rights away, so every flag is sent.
    static func build(type: String, _ flags: [RightsFlag], _ values: [String: Bool]) -> TDNode {
        var node: TDNode = ["@type": type]
        for flag in flags { node[flag.key] = values[flag.key] == true }
        return node
    }

    /// One line under a member's name: what they may do, or what they are still allowed.
    static func summary(_ values: [String: Bool], _ flags: [RightsFlag]) -> String {
        let on = flags.filter { values[$0.key] == true }.map(\.label)
        if on.isEmpty { return "" }
        if on.count > 3 { return "\(on.prefix(3).joined(separator: ", ")) и ещё \(on.count - 3)" }
        return on.joined(separator: ", ")
    }
}

struct Sticker: Equatable {
    enum Format: Equatable {
        case webp, tgs, webm
    }

    var fileId: Int
    var format: Format
    var width: Int
    var height: Int
    var emoji: String
    /// WebP or JPEG preview: the fallback picture, and the only one a video sticker has here.
    var thumbnailFileId: Int?
    /// Big animated emoji are drawn smaller than stickers.
    var isEmoji: Bool
}

/// A file sent as a document (or a music track): what its card shows.
struct DocumentInfo: Equatable {
    var fileId: Int
    var name: String
    var size: Int64
    var mimeType: String
    /// "Artist — Title" for music, empty otherwise.
    var trackTitle: String = ""
    var duration: Int = 0

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

/// How far a file is on its way down or up, from `updateFile`.
struct FileTransfer: Equatable {
    var size: Int64
    var downloaded: Int64
    var uploaded: Int64
    var isDownloading: Bool
    var isUploading: Bool
    var isDownloaded: Bool
    var path: String

    var downloadFraction: Double { size > 0 ? min(1, Double(downloaded) / Double(size)) : 0 }
    var uploadFraction: Double { size > 0 ? min(1, Double(uploaded) / Double(size)) : 0 }
}

/// The downloadable file behind a media message.
struct Attachment: Equatable {
    var fileId: Int
    var name: String
}

/// The card under a message with a link: site, title, description and a picture when there is one.
struct LinkPreview: Equatable {
    var url: URL
    var siteName: String
    var title: String
    var description: String
    var photo: MediaInfo?
}

/// One emoji reaction under a message.
struct Reaction: Equatable {
    /// Empty for a custom emoji, which is a picture named by `customEmojiId`.
    var emoji: String
    var count: Int
    /// You reacted with it.
    var isChosen: Bool
    var customEmojiId: Int64 = 0

    /// What tells one reaction of a message from another.
    var key: String { customEmojiId != 0 ? "c\(customEmojiId)" : emoji }
}

/// Formatting of a text or caption, in UTF-16 offsets as TDLib sends them.
struct TextEntity: Hashable {
    enum Style: Hashable {
        case bold, italic, underline, strikethrough, code, spoiler
        case link(URL)
        /// One of Telegram's own emoji, drawn over the ordinary emoji that stands in for it in the text.
        case customEmoji(Int64)
    }

    var offset: Int
    var length: Int
    var style: Style
}

/// A picture or clip drawn inside the transcript.
struct MediaInfo: Equatable {
    enum Kind: Equatable {
        case photo, video, animation, videoNote, voiceNote
    }

    var kind: Kind
    /// The photo size picked for the bubble, or the video file.
    var fileId: Int
    var fileSize: Int64
    /// Still frame of a video, GIF or video message.
    var thumbnailFileId: Int?
    var minithumbnail: Data?
    var width: Int
    var height: Int
    var duration: Int
    var hasSpoiler: Bool
    /// Loudness bars of a voice message, 0...31 each.
    var waveform: [UInt8] = []
    /// A smaller size of the same photo that arrives first while the sharp one downloads.
    var previewFileId: Int?
}

/// A point on the map a message carries: a bare location, a venue or one being broadcast.
struct LocationInfo: Equatable {
    var latitude: Double
    var longitude: Double
    /// Where the sender said the point is, when they named the place.
    var title = ""
    var address = ""
    /// A live location stops broadcasting at this date; nil for a point sent once.
    var expiresAt: Date?
}

/// A contact card shared in a message.
struct ContactInfo: Equatable {
    var name: String
    var phone: String
    /// The Telegram account behind the card, when the shared contact is one of the user's own.
    var userId: Int64
}

/// A dice or a dart: what was thrown and what came out.
struct Dice: Equatable {
    var emoji: String
    var value: Int
}

/// One button of a bot keyboard.
struct BotButton: Hashable, Identifiable {
    enum Action: Hashable {
        case url(String)
        case loginUrl(url: String, id: Int64)
        case webApp(String)
        /// Base64 data sent back to the bot with `getCallbackQueryAnswer`.
        case callback(String)
        case switchInline(query: String, inCurrentChat: Bool)
        case user(Int64)
        case copy(String)
        case disabled
        /// Reply keyboard: the label is sent as a message.
        case text
        /// Reply keyboard: a mini app that may send data back with `sendWebAppData`.
        case keyboardWebApp(String)
        /// Games, payments, password-protected callbacks, sharing a phone or a chat.
        case unsupported
    }

    enum Style: Hashable {
        case plain, primary, danger, success

        init(_ type: String?) {
            switch type {
            case "buttonStylePrimary": self = .primary
            case "buttonStyleDanger": self = .danger
            case "buttonStyleSuccess": self = .success
            default: self = .plain
            }
        }
    }

    var row: Int
    var column: Int
    var text: String
    var action: Action
    var style: Style = .plain

    var id: String { "\(row):\(column)" }

    /// SF Symbol shown in the corner, as the official clients mark links and apps.
    var symbol: String? {
        switch action {
        case .url, .loginUrl: "arrow.up.right"
        case .webApp, .keyboardWebApp: "square.grid.2x2"
        case .switchInline: "arrowshape.turn.up.right"
        case .copy: "doc.on.doc"
        case .user: "person"
        case .unsupported: "exclamationmark.circle"
        default: nil
        }
    }
}

/// The menu button and commands of a bot chat, from the bot's full info.
struct BotMenu: Equatable {
    struct Command: Equatable, Identifiable {
        var command: String
        var description: String
        var id: String { command }
    }

    var botUserId: Int64
    /// The menu button opens this mini app; empty when the bot has none.
    var appTitle: String
    var appURL: String
    var commands: [Command]
}

/// What the profile sheet shows, for a person, a bot, a group or a channel.
struct ProfileInfo: Identifiable {
    let id = UUID()
    var title: String
    var photo: ProfilePhoto?
    var seed: Int64
    /// "в сети", "бот", "1 234 участника".
    var subtitle: String
    /// The user id, or the chat id in Bot API form (-100… for supergroups and channels).
    var telegramId: Int64
    /// The supergroup or basic group id behind a chat id; 0 for people.
    var innerId: Int64 = 0
    var dataCenter: Int?
    var usernames: [String] = []
    var phone: String = ""
    var about: String = ""
    var badges: [String] = []
    var facts: [(String, String)] = []
    /// The private chat to open with "Написать"; 0 when there is none.
    var userId: Int64 = 0
    var isSelf = false
    /// You blocked this person or bot.
    var isBlocked = false
    var raw: TDNode?

    /// The chat whose history holds what was shared with them: a private chat goes by its user's id.
    var chatId: Int64 { userId != 0 ? userId : telegramId }
}

/// A mini app open in its own window.
struct WebAppSession: Identifiable, Equatable {
    let id = UUID()
    /// From `openWebApp`; 0 for apps opened otherwise, which need no `closeWebApp`.
    var launchId: Int64
    var chatId: Int64
    var botUserId: Int64
    var botName: String
    var url: URL
    /// Navigation away from the app's own origin goes to the browser.
    var requiresSameOrigin: Bool
    /// Set for keyboard buttons: the app may answer with `sendWebAppData` under this label.
    var keyboardButtonText: String?
}

/// A folder of the chat list, as set up in Telegram.
/// One folder of the chat list. TDLib names its icon from a fixed list and gives its colour, so the sidebar
/// rail can draw what Telegram draws instead of inventing a letter.
struct ChatFolder: Identifiable, Equatable {
    var id: Int
    var title: String
    /// "All", "Unread", "Unmuted", "Bots", "Channels", "Groups", "Private", "Custom", and the emoji-named ones.
    var icon: String = ""
    /// Telegram's chosen colour for the icon, from -1 (disabled) to 6.
    var colorId: Int = -1
}

/// Unread messages of one place of the sidebar, and whether every one of them sits in a muted chat — a folder
/// of nothing but muted news is marked grey, the way Telegram marks it.
struct UnreadTally: Equatable {
    private(set) var count = 0
    private(set) var isSilent = true

    mutating func add(_ unread: Int, isMuted: Bool) {
        guard unread > 0 else { return }
        count += unread
        if !isMuted { isSilent = false }
    }
}

/// A topic of a forum supergroup: one thread with its own history, draft and unread count.
struct Topic: Identifiable, Equatable {
    var id: Int32
    var name: String
    /// Telegram's own colour for the topic's icon, as RGB.
    var color: Int = 0
    var isClosed = false
    var unread = 0
    var snippet = ""
    var draft = ""
}

/// An installed sticker set as a tab of the sticker panel.
struct StickerSetSummary: Identifiable, Equatable {
    var id: Int64
    var title: String
    var cover: Sticker?
}

/// A poll or a quiz with its current results.
struct Poll: Equatable {
    struct Option: Equatable {
        var text: String
        var voterCount: Int
        var percentage: Int
        var isChosen: Bool
    }

    var id: Int64
    var question: String
    var options: [Option]
    var totalVoters: Int
    var isQuiz: Bool
    /// Indices of the right answers of a quiz, known once you have answered.
    var correctOptions: [Int]
    var explanation: String
    var allowsMultipleAnswers: Bool
    var isAnonymous: Bool
    var isClosed: Bool

    var hasVoted: Bool { options.contains(where: \.isChosen) }
    /// Results show after voting, when the poll is closed, and always to the author of a closed quiz.
    var showsResults: Bool { hasVoted || isClosed }
}

struct ReplyMarkup: Hashable {
    enum Kind: Hashable {
        /// Buttons under the message.
        case inline
        /// A keyboard shown instead of (or next to) the composer.
        case keyboard
        case forceReply
        case remove
    }

    var kind: Kind
    var rows: [[BotButton]] = []
    var isOneTime = false
    var isPersistent = false
    var placeholder = ""
}

/// The quoted message of a reply across chats, as Telegram sends it with the reply itself.
struct ForeignReply: Equatable {
    /// 0 when the chat is one this account cannot see.
    var chatId: Int64
    var messageId: Int64
    /// The author as a sender key, or only a name when they hide their account.
    var senderKey: String
    var senderName: String
    var text: String
}

struct Message: Identifiable, Equatable {
    enum Body: Equatable {
        case text(String)
        case attachment(String)
        case service(String)
        case unsupported(String)
    }

    /// "вступил в группу" and the like: a centered line, not a bubble.
    var isService: Bool {
        if case .service = body { return true }
        return false
    }

    var id: Int64
    var chatId: Int64
    var senderKey: String
    var isOutgoing: Bool
    var body: Body
    var date: Date
    var isPending: Bool
    var isFailed: Bool
    var isPinned: Bool
    var attachment: Attachment?
    /// Stickers and big animated emoji are drawn as pictures instead of a text bubble.
    var sticker: Sticker?
    var media: MediaInfo?
    /// Photos and videos sent together share this id and are drawn as one album.
    var albumId: Int64 = 0
    var caption: String = ""
    /// Bold, links and the like, for the text of a text message or the caption of a media one.
    /// Buttons a bot attached: under the bubble (inline) or for the composer.
    var markup: ReplyMarkup?
    /// Text you changed on this Mac only; the message on the server is untouched. Always marked in the bubble.
    var localText: String?
    /// A document or music file, drawn as a file card.
    var document: DocumentInfo?
    /// A map point, a venue or a live location, drawn as a place card.
    var location: LocationInfo?
    /// A shared phone number, drawn as a contact card.
    var contact: ContactInfo?
    /// A dice or a dart, drawn as the throw itself.
    var dice: Dice?
    /// Waits to be sent at a set time; such messages live in their own list, not in the history.
    var isScheduled = false
    var poll: Poll?
    /// The bot an inline message was sent through; its buttons belong to that bot.
    var viaBotUserId: Int64 = 0
    var entities: [TextEntity] = []
    var isEdited = false
    /// The message the reply quotes, when it is in the same chat.
    var replyToId: Int64 = 0
    /// What the reply quotes when that message lives in another chat.
    var foreignReply: ForeignReply?
    /// Who wrote a forwarded message: a sender key, or just a name when the author hides their account.
    var forwardSenderKey = ""
    var forwardSenderName = ""
    /// Deleted by someone else and kept by the local archive (AyuGram's "saved deleted messages").
    var isDeleted = false
    /// The local archive has earlier versions of the text.
    var hasEditHistory = false
    var reactions: [Reaction] = []
    /// Views of a channel post; 0 elsewhere.
    var viewCount = 0
    var linkPreview: LinkPreview?
    /// The topic of a forum supergroup this message belongs to; 0 outside a forum, where the whole chat is
    /// one stream.
    var topicId: Int32 = 0

    var isForwarded: Bool { !forwardSenderKey.isEmpty || !forwardSenderName.isEmpty }

    /// Only messages that reached the server can be replied to, pinned or edited.
    var isSent: Bool { !isPending && !isFailed }
}

enum TD {
    static func chat(_ node: TDNode) -> Chat {
        var snippet = ""
        var snippetDate: Date?
        var lastMessageId: Int64 = 0
        if let last = node.tdNode("last_message") {
            let message = self.message(last)
            snippet = Self.snippet(of: message)
            snippetDate = message.date
            if message.isSent { lastMessageId = message.id }
        }
        let type = node.tdNode("type") ?? [:]
        let groupKey = switch type.tdType {
        case "chatTypeSupergroup": "s\(type.tdInt64("supergroup_id"))"
        case "chatTypeBasicGroup": "b\(type.tdInt64("basic_group_id"))"
        default: ""
        }

        var chat = Chat(
            id: node.tdInt64("id"),
            title: node.tdString("title"),
            kind: kind(of: node),
            order: 0,
            isPinned: false,
            archiveOrder: 0,
            isPinnedInArchive: false,
            unread: node.tdInt("unread_count"),
            isMarkedUnread: node.tdBool("is_marked_as_unread"),
            snippet: snippet,
            snippetDate: snippetDate,
            lastReadInboxId: node.tdInt64("last_read_inbox_message_id"),
            lastReadOutboxId: node.tdInt64("last_read_outbox_message_id"),
            lastMessageId: lastMessageId,
            unreadMentions: node.tdInt("unread_mention_count"),
            unreadReactions: node.tdInt("unread_reaction_count"),
            draftText: draftText(of: node.tdNode("draft_message")),
            isMuted: false,
            photo: photo(node.tdNode("photo")),
            // Private and secret chats name their user; a private chat's id is that user's id.
            userId: type.tdInt64("user_id"),
            groupKey: groupKey,
            presence: nil,
            isBot: false,
            memberCount: 0,
            onlineMemberCount: 0,
            activity: ""
        )
        chat.replyMarkupMessageId = node.tdInt64("reply_markup_message_id")
        chat.secretChatId = type.tdType == "chatTypeSecret" ? type.tdInt("secret_chat_id") : 0
        applyPositions(node.tdNodes("positions"), to: &chat)
        return chat
    }

    /// `chatStatisticsChannel`; a group answers with `chatStatisticsSupergroup`, whose counts sit under
    /// other names, so both are read here.
    static func stats(_ node: TDNode) -> ChannelStats? {
        guard node.tdType == "chatStatisticsChannel" || node.tdType == "chatStatisticsSupergroup" else { return nil }
        let period = node.tdNode("period") ?? [:]
        let members = node.tdNode("member_count") ?? [:]
        func value(_ node: TDNode, _ key: String, _ fallback: String? = nil) -> Double {
            if let held = node.tdNode(key) { return held.tdDouble("value") }
            return fallback.flatMap { node.tdNode($0) }?.tdDouble("value") ?? 0
        }
        return ChannelStats(
            from: Date(timeIntervalSince1970: TimeInterval(period.tdInt("start_date"))),
            to: Date(timeIntervalSince1970: TimeInterval(period.tdInt("end_date"))),
            members: members.tdDouble("value"),
            membersGrowth: members.tdDouble("growth_rate_percentage"),
            meanViews: value(node, "mean_message_view_count", "viewer_count"),
            meanShares: value(node, "mean_message_share_count"),
            meanReactions: value(node, "mean_message_reaction_count")
        )
    }

    /// One row of `getSupergroupMembers`. Names come from the user the client already knows.
    static func member(_ node: TDNode, name: String, photo: ProfilePhoto?) -> ChatMemberInfo {
        var member = ChatMemberInfo(userId: (node.tdNode("member_id") ?? [:]).tdInt64("user_id"), name: name, photo: photo)
        let status = node.tdNode("status") ?? [:]
        switch status.tdType {
        case "chatMemberStatusCreator":
            member.rank = .owner
        case "chatMemberStatusAdministrator":
            member.rank = .admin
            member.canBeEdited = status.tdBool("can_be_edited")
            member.rights = Rights.read(status.tdNode("rights") ?? [:])
        case "chatMemberStatusRestricted":
            member.rank = .restricted
            member.untilDate = status.tdInt("restricted_until_date")
            member.permissions = Rights.read(status.tdNode("permissions") ?? [:])
        case "chatMemberStatusBanned":
            member.rank = .banned
            member.untilDate = status.tdInt("banned_until_date")
        default:
            member.rank = .member
        }
        return member
    }

    static func inviteLink(_ node: TDNode) -> InviteLinkInfo {
        let expiration = node.tdInt("expiration_date")
        return InviteLinkInfo(
            url: node.tdString("invite_link"),
            name: node.tdString("name"),
            expirationDate: expiration > 0 ? Date(timeIntervalSince1970: TimeInterval(expiration)) : nil,
            memberLimit: node.tdInt("member_limit"),
            memberCount: node.tdInt("member_count")
        )
    }

    /// `supergroup` plus `supergroupFullInfo`: the first says who you are there, the second what you may do.
    static func access(group: TDNode, full: TDNode) -> ChatAccess {
        let status = group.tdNode("status") ?? [:]
        var access = ChatAccess(
            canGetMembers: full.tdBool("can_get_members"),
            isChannel: group.tdBool("is_channel"),
            about: full.tdString("description"),
            memberCount: full.tdInt("member_count") != 0 ? full.tdInt("member_count") : group.tdInt("member_count")
        )
        access.primaryLink = full.tdNode("invite_link")?.tdString("invite_link") ?? ""
        switch status.tdType {
        case "chatMemberStatusCreator":
            access.isCreator = true
            access.isAdmin = true
            access.canChangeInfo = true
            access.canInvite = true
            access.canRestrict = true
            access.canPromote = true
            access.canDeleteMessages = true
            access.canManageTopics = true
        case "chatMemberStatusAdministrator":
            access.isAdmin = true
            let rights = status.tdNode("rights") ?? [:]
            access.canChangeInfo = rights.tdBool("can_change_info")
            access.canInvite = rights.tdBool("can_invite_users")
            access.canRestrict = rights.tdBool("can_restrict_members")
            access.canPromote = rights.tdBool("can_promote_members")
            access.canDeleteMessages = rights.tdBool("can_delete_messages")
            access.canManageTopics = rights.tdBool("can_manage_topics")
        default:
            break
        }
        return access
    }

    /// One topic of a forum supergroup, as `getForumTopics` returns it.
    static func topic(_ node: TDNode) -> Topic {
        let info = node.tdNode("info") ?? [:]
        var topic = Topic(
            id: Int32(info.tdInt("forum_topic_id")),
            name: info.tdString("name"),
            color: info.tdNode("icon")?.tdInt("color") ?? 0,
            isClosed: info.tdBool("is_closed"),
            unread: node.tdInt("unread_count"),
            draft: draftText(of: node.tdNode("draft_message"))
        )
        if let last = node.tdNode("last_message") { topic.snippet = snippet(of: self.message(last)) }
        return topic
    }

    static func message(_ node: TDNode) -> Message {
        let state = node.tdNode("sending_state")?.tdType
        let content = node.tdNode("content") ?? [:]
        let chatId = node.tdInt64("chat_id")

        var message = Message(
            id: node.tdInt64("id"),
            chatId: chatId,
            senderKey: senderKey(node.tdNode("sender_id")),
            isOutgoing: node.tdBool("is_outgoing"),
            body: body(of: content),
            date: Date(timeIntervalSince1970: TimeInterval(node.tdInt("date"))),
            isPending: state == "messageSendingStatePending",
            isFailed: state == "messageSendingStateFailed",
            isPinned: node.tdBool("is_pinned"),
            attachment: attachment(of: content),
            sticker: sticker(of: content),
            media: media(of: content),
            albumId: node.tdInt64("media_album_id"),
            caption: content.tdText("caption"),
            entities: entities(of: content),
            isEdited: node.tdInt("edit_date") > 0
        )
        applyInteraction(node.tdNode("interaction_info"), to: &message)
        message.linkPreview = linkPreview(content.tdNode("link_preview"))
        message.markup = replyMarkup(node.tdNode("reply_markup"))
        message.viaBotUserId = node.tdInt64("via_bot_user_id")
        message.isScheduled = node.tdNode("scheduling_state") != nil
        message.document = document(of: content)
        message.location = location(of: content)
        message.contact = contact(of: content)
        message.dice = dice(of: content)
        message.poll = poll(content.tdNode("poll"))
        if let reply = node.tdNode("reply_to"), reply.tdType == "messageReplyToMessage" {
            let origin = reply.tdInt64("chat_id")
            if origin == chatId || (origin == 0 && reply.tdInt64("message_id") != 0) {
                message.replyToId = reply.tdInt64("message_id")
            } else {
                message.foreignReply = foreignReply(reply)
            }
        }
        if let topic = node.tdNode("topic_id"), topic.tdType == "messageTopicForum" {
            message.topicId = Int32(topic.tdInt("forum_topic_id"))
        }
        if let origin = node.tdNode("forward_info")?.tdNode("origin") {
            switch origin.tdType {
            case "messageOriginUser": message.forwardSenderKey = "u\(origin.tdInt64("sender_user_id"))"
            case "messageOriginChat": message.forwardSenderKey = "c\(origin.tdInt64("sender_chat_id"))"
            case "messageOriginChannel": message.forwardSenderKey = "c\(origin.tdInt64("chat_id"))"
            default: message.forwardSenderName = origin.tdString("sender_name")
            }
        }
        return message
    }

    /// A reply to a message of another chat. That message cannot be looked up in this chat's history, so
    /// Telegram sends who wrote it and what it said along with the reply; nil when it sent neither.
    static func foreignReply(_ reply: TDNode) -> ForeignReply? {
        var text = reply.tdNode("quote")?.tdText("text") ?? ""
        if text.isEmpty, let content = reply.tdNode("content") {
            switch body(of: content) {
            case .text(let value), .attachment(let value), .service(let value): text = value
            case .unsupported: text = "Сообщение"
            }
        }
        var senderKey = ""
        var senderName = ""
        if let origin = reply.tdNode("origin") {
            switch origin.tdType {
            case "messageOriginUser": senderKey = "u\(origin.tdInt64("sender_user_id"))"
            case "messageOriginChat": senderKey = "c\(origin.tdInt64("sender_chat_id"))"
            case "messageOriginChannel": senderKey = "c\(origin.tdInt64("chat_id"))"
            default: senderName = origin.tdString("sender_name")
            }
        }
        guard !text.isEmpty || !senderKey.isEmpty || !senderName.isEmpty else { return nil }
        if text.utf8.contains(0x0A) { text = text.replacingOccurrences(of: "\n", with: " ") }
        return ForeignReply(chatId: reply.tdInt64("chat_id"), messageId: reply.tdInt64("message_id"),
                            senderKey: senderKey, senderName: senderName, text: String(text.prefix(160)))
    }

    static func document(of content: TDNode) -> DocumentInfo? {
        switch content.tdType {
        case "messageDocument":
            guard let document = content.tdNode("document"), let file = document.tdNode("document"), file.tdInt("id") != 0 else { return nil }
            return DocumentInfo(fileId: file.tdInt("id"), name: document.tdString("file_name").isEmpty ? "Файл" : document.tdString("file_name"),
                                size: fileSize(file), mimeType: document.tdString("mime_type"))
        case "messageAudio":
            guard let audio = content.tdNode("audio"), let file = audio.tdNode("audio"), file.tdInt("id") != 0 else { return nil }
            let title = [audio.tdString("performer"), audio.tdString("title")].filter { !$0.isEmpty }.joined(separator: " — ")
            return DocumentInfo(fileId: file.tdInt("id"), name: audio.tdString("file_name").isEmpty ? "Аудио" : audio.tdString("file_name"),
                                size: fileSize(file), mimeType: audio.tdString("mime_type"), trackTitle: title, duration: audio.tdInt("duration"))
        default:
            return nil
        }
    }

    static func location(of content: TDNode) -> LocationInfo? {
        var title = ""
        var address = ""
        var expiresAt: Date?
        let point: TDNode?
        switch content.tdType {
        case "messageLocation":
            point = content.tdNode("location")
        case "messageVenue":
            let venue = content.tdNode("venue") ?? [:]
            point = venue.tdNode("location")
            title = venue.tdString("title")
            address = venue.tdString("address")
        case "messageLiveLocation":
            point = content.tdNode("location")
            let seconds = content.tdInt("expires_in")
            expiresAt = seconds > 0 ? Date().addingTimeInterval(TimeInterval(seconds)) : nil
        default:
            return nil
        }
        guard let point, point.tdType == "location" else { return nil }
        let latitude = point.tdDouble("latitude")
        let longitude = point.tdDouble("longitude")
        // 0,0 is a real place, but never one a message means.
        guard latitude != 0 || longitude != 0 else { return nil }
        return LocationInfo(latitude: latitude, longitude: longitude, title: title, address: address, expiresAt: expiresAt)
    }

    static func contact(of content: TDNode) -> ContactInfo? {
        guard content.tdType == "messageContact", let node = content.tdNode("contact") else { return nil }
        let name = [node.tdString("first_name"), node.tdString("last_name")].filter { !$0.isEmpty }.joined(separator: " ")
        let phone = node.tdString("phone_number")
        guard !name.isEmpty || !phone.isEmpty else { return nil }
        return ContactInfo(name: name.isEmpty ? "Контакт" : name, phone: phone, userId: node.tdInt64("user_id"))
    }

    static func dice(of content: TDNode) -> Dice? {
        guard content.tdType == "messageDice" else { return nil }
        return Dice(emoji: content.tdString("emoji"), value: content.tdInt("value"))
    }

    static func transfer(_ file: TDNode) -> FileTransfer {
        let local = file.tdNode("local") ?? [:]
        let remote = file.tdNode("remote") ?? [:]
        return FileTransfer(
            size: fileSize(file),
            downloaded: local.tdInt64("downloaded_size"),
            uploaded: remote.tdInt64("uploaded_size"),
            isDownloading: local.tdBool("is_downloading_active"),
            isUploading: remote.tdBool("is_uploading_active"),
            isDownloaded: local.tdBool("is_downloading_completed"),
            path: local.tdString("path")
        )
    }

    static func poll(_ node: TDNode?) -> Poll? {
        guard let node, node.tdType == "poll" else { return nil }
        let type = node.tdNode("type")
        return Poll(
            id: node.tdInt64("id"),
            question: node.tdText("question"),
            options: node.tdNodes("options").map {
                Poll.Option(text: $0.tdText("text"), voterCount: $0.tdInt("voter_count"),
                            percentage: $0.tdInt("vote_percentage"), isChosen: $0.tdBool("is_chosen"))
            },
            totalVoters: node.tdInt("total_voter_count"),
            isQuiz: type?.tdType == "pollTypeQuiz",
            correctOptions: (type?["correct_option_ids"] as? [NSNumber])?.map(\.intValue)
                ?? (type?["correct_option_id"] as? NSNumber).map { $0.intValue >= 0 ? [$0.intValue] : [] } ?? [],
            explanation: type?.tdText("explanation") ?? "",
            allowsMultipleAnswers: node.tdBool("allows_multiple_answers"),
            isAnonymous: node.tdBool("is_anonymous"),
            isClosed: node.tdBool("is_closed")
        )
    }

    /// Bot keyboards: buttons under a message, or a keyboard for the composer.
    static func replyMarkup(_ node: TDNode?) -> ReplyMarkup? {
        guard let node else { return nil }
        switch node.tdType {
        case "replyMarkupInlineKeyboard":
            let rows = buttonRows(node, inline: true)
            return rows.isEmpty ? nil : ReplyMarkup(kind: .inline, rows: rows)
        case "replyMarkupShowKeyboard":
            return ReplyMarkup(
                kind: .keyboard,
                rows: buttonRows(node, inline: false),
                isOneTime: node.tdBool("one_time"),
                isPersistent: node.tdBool("is_persistent"),
                placeholder: node.tdString("input_field_placeholder")
            )
        case "replyMarkupForceReply":
            return ReplyMarkup(kind: .forceReply, placeholder: node.tdString("input_field_placeholder"))
        case "replyMarkupRemoveKeyboard":
            return ReplyMarkup(kind: .remove)
        default:
            return nil
        }
    }

    private static func buttonRows(_ node: TDNode, inline: Bool) -> [[BotButton]] {
        guard let rows = node["rows"] as? [[TDNode]] else { return [] }
        return rows.enumerated().compactMap { rowIndex, row in
            let buttons = row.enumerated().map { column, button in
                BotButton(
                    row: rowIndex,
                    column: column,
                    text: button.tdString("text"),
                    action: inline ? inlineAction(button.tdNode("type")) : keyboardAction(button.tdNode("type")),
                    style: BotButton.Style(button.tdNode("style")?.tdType)
                )
            }
            return buttons.isEmpty ? nil : buttons
        }
    }

    private static func inlineAction(_ type: TDNode?) -> BotButton.Action {
        guard let type else { return .unsupported }
        switch type.tdType {
        case "inlineKeyboardButtonTypeUrl": return .url(type.tdString("url"))
        case "inlineKeyboardButtonTypeLoginUrl": return .loginUrl(url: type.tdString("url"), id: type.tdInt64("id"))
        case "inlineKeyboardButtonTypeWebApp": return .webApp(type.tdString("url"))
        case "inlineKeyboardButtonTypeCallback": return .callback(type.tdString("data"))
        case "inlineKeyboardButtonTypeSwitchInline":
            return .switchInline(query: type.tdString("query"),
                                 inCurrentChat: type.tdNode("target_chat")?.tdType == "targetChatCurrent")
        case "inlineKeyboardButtonTypeUser": return .user(type.tdInt64("user_id"))
        case "inlineKeyboardButtonTypeCopyText": return .copy(type.tdString("text"))
        case "inlineKeyboardButtonTypeDisabled": return .disabled
        default: return .unsupported
        }
    }

    private static func keyboardAction(_ type: TDNode?) -> BotButton.Action {
        switch type?.tdType {
        case "keyboardButtonTypeText", nil: return .text
        case "keyboardButtonTypeWebApp": return .keyboardWebApp(type?.tdString("url") ?? "")
        default: return .unsupported
        }
    }

    /// Reactions (emoji and custom emoji; paid stars are left out) and channel view counts.
    static func applyInteraction(_ info: TDNode?, to message: inout Message) {
        message.viewCount = info?.tdInt("view_count") ?? 0
        message.reactions = (info?.tdNode("reactions")?.tdNodes("reactions") ?? []).compactMap { reaction in
            guard let type = reaction.tdNode("type") else { return nil }
            switch type.tdType {
            case "reactionTypeEmoji":
                return Reaction(emoji: type.tdString("emoji"), count: reaction.tdInt("total_count"), isChosen: reaction.tdBool("is_chosen"))
            case "reactionTypeCustomEmoji":
                let id = type.tdInt64("custom_emoji_id")
                guard id != 0 else { return nil }
                return Reaction(emoji: "", count: reaction.tdInt("total_count"), isChosen: reaction.tdBool("is_chosen"), customEmojiId: id)
            default:
                return nil
            }
        }
    }

    /// "u<id>" for users, "c<id>" for chats posting as themselves.
    static func senderKey(_ sender: TDNode?) -> String {
        switch sender?.tdType {
        case "messageSenderUser": "u\(sender?.tdInt64("user_id") ?? 0)"
        case "messageSenderChat": "c\(sender?.tdInt64("chat_id") ?? 0)"
        default: ""
        }
    }

    /// `chatPhotoInfo` and `profilePhoto` share the fields used here.
    static func photo(_ node: TDNode?) -> ProfilePhoto? {
        guard let node, let small = node.tdNode("small"), small.tdInt("id") != 0 else { return nil }
        let local = small.tdNode("local") ?? [:]
        return ProfilePhoto(
            fileId: small.tdInt("id"),
            localPath: local.tdBool("is_downloading_completed") ? local.tdString("path") : "",
            minithumbnail: node.tdNode("minithumbnail").flatMap { Data(base64Encoded: $0.tdString("data")) }
        )
    }

    static func snippet(of message: Message) -> String {
        var text = preview(of: message)
        if message.isOutgoing { text = "Вы: " + text }
        return String(text.prefix(120))
    }

    /// One line of the message for the chat list and the composer's reply/edit bar.
    static func preview(of message: Message) -> String {
        let text: String
        switch message.body {
        case .text(let value): text = value
        case .attachment(let label), .service(let label), .unsupported(let label): text = label
        }
        // The usual preview is a short single line, and replacingOccurrences() bridged the whole text to
        // NSString even then.
        var result = text
        if result.utf8.contains(0x0A) { result = result.replacingOccurrences(of: "\n", with: " ") }
        if result.utf8.count > 120 { result = String(result.prefix(120)) }
        return result
    }

    /// The data center a file lives in, read from its persistent id (the Bot API `file_id` format:
    /// base64url, zero runs packed as 0x00 + count, then int32 type and int32 DC). A profile photo is kept
    /// in its owner's data center, which is how clients show a user's DC.
    static func dataCenter(ofRemoteFileId id: String) -> Int? {
        var base64 = id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let packed = Data(base64Encoded: base64), !packed.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(packed.count * 2)
        var zeroRun = false
        for byte in packed {
            if zeroRun {
                bytes.append(contentsOf: repeatElement(0, count: Int(byte)))
                zeroRun = false
            } else if byte == 0 {
                zeroRun = true
            } else {
                bytes.append(byte)
            }
        }
        guard bytes.count >= 8 else { return nil }
        let dc = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        return (1...5).contains(dc) ? dc : nil
    }

    /// Where Telegram's data centers stand.
    static func dataCenterLocation(_ dc: Int) -> String {
        switch dc {
        case 1, 3: "Майами, США"
        case 2, 4: "Амстердам, Нидерланды"
        case 5: "Сингапур"
        default: ""
        }
    }

    static func displayName(ofUser user: TDNode) -> String {
        if user.tdNode("type")?.tdType == "userTypeDeleted" { return "Удалённый аккаунт" }
        let parts = [user.tdString("first_name"), user.tdString("last_name")].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        let username = (user.tdNode("usernames")?["active_usernames"] as? [String])?.first ?? ""
        return username.isEmpty ? "" : "@" + username
    }

    // MARK: - presence

    private static let russian = Locale(identifier: "ru_RU")

    static func presence(_ status: TDNode?) -> UserPresence? {
        guard let status else { return nil }
        switch status.tdType {
        case "userStatusOnline":
            // TDLib reports the expiry itself, but a stale value must not read as "в сети".
            let expires = Date(timeIntervalSince1970: TimeInterval(status.tdInt("expires")))
            return expires < Date() ? .offline(since: expires) : .online
        case "userStatusOffline": return .offline(since: Date(timeIntervalSince1970: TimeInterval(status.tdInt("was_online"))))
        case "userStatusRecently": return .recently
        case "userStatusLastWeek": return .lastWeek
        case "userStatusLastMonth": return .lastMonth
        case "userStatusEmpty": return .longAgo
        default: return nil
        }
    }

    /// Absolute times on purpose: "был(а) в 14:32" stays true without re-rendering every minute.
    static func describe(_ presence: UserPresence, now: Date = Date()) -> String {
        switch presence {
        case .online:
            return "в сети"
        case .offline(let since):
            let calendar = Calendar.current
            let time = since.formatted(.dateTime.hour().minute().locale(russian))
            if calendar.isDateInToday(since) { return "был(а) в \(time)" }
            if calendar.isDateInYesterday(since) { return "был(а) вчера в \(time)" }
            if calendar.isDate(since, equalTo: now, toGranularity: .year) {
                return "был(а) \(since.formatted(.dateTime.day().month(.wide).locale(russian))) в \(time)"
            }
            return "был(а) \(since.formatted(.dateTime.day().month(.wide).year().locale(russian)))"
        case .recently:
            return "был(а) недавно"
        case .lastWeek:
            return "был(а) на этой неделе"
        case .lastMonth:
            return "был(а) в этом месяце"
        case .longAgo:
            return "был(а) давно"
        }
    }

    /// What someone in a chat is doing, for one person and for several; nil ends the activity.
    static func activityVerb(_ action: TDNode?) -> (single: String, plural: String)? {
        switch action?.tdType {
        case "chatActionTyping": ("печатает", "печатают")
        case "chatActionRecordingVideo": ("записывает видео", "записывают видео")
        case "chatActionUploadingVideo": ("отправляет видео", "отправляют видео")
        case "chatActionRecordingVoiceNote": ("записывает голосовое", "записывают голосовые")
        case "chatActionUploadingVoiceNote": ("отправляет голосовое", "отправляют голосовые")
        case "chatActionUploadingPhoto": ("отправляет фото", "отправляют фото")
        case "chatActionUploadingDocument": ("отправляет файл", "отправляют файлы")
        case "chatActionChoosingSticker": ("выбирает стикер", "выбирают стикеры")
        case "chatActionChoosingLocation": ("выбирает место", "выбирают место")
        case "chatActionChoosingContact": ("выбирает контакт", "выбирают контакты")
        case "chatActionStartPlayingGame": ("играет", "играют")
        case "chatActionRecordingVideoNote": ("записывает видеосообщение", "записывают видеосообщения")
        case "chatActionUploadingVideoNote": ("отправляет видеосообщение", "отправляют видеосообщения")
        default: nil
        }
    }

    /// Russian plural form: 1 участник, 2 участника, 5 участников.
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = count % 100
        let units = count % 10
        if units == 1 && tens != 11 { return one }
        if (2...4).contains(units) && !(12...14).contains(tens) { return few }
        return many
    }

    static func count(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(count.formatted(.number.locale(russian))) \(plural(count, one, few, many))"
    }

    // MARK: - chat list

    static func isMainPosition(_ position: TDNode) -> Bool { listType(of: position) == "chatListMain" }
    static func isArchivePosition(_ position: TDNode) -> Bool { listType(of: position) == "chatListArchive" }

    private static func listType(of position: TDNode) -> String {
        position.tdNode("list")?.tdType ?? position.tdNode("chat_list")?.tdType ?? ""
    }

    /// `updateChatLastMessage`, `updateChatDraftMessage` and `chat.positions` carry the complete set of
    /// positions, so a chat without an entry for a list has left that list.
    static func applyPositions(_ positions: [TDNode], to chat: inout Chat) {
        // Folders are listed only where the chat is in them; one missing from the list has left that folder.
        var folders: [Int: Int64] = [:]
        var pinned: Set<Int> = []
        for position in positions where position.tdNode("list")?.tdType == "chatListFolder" {
            let folder = position.tdNode("list")?.tdInt("chat_folder_id") ?? 0
            let order = position.tdInt64("order")
            if order != 0 { folders[folder] = order }
            if position.tdBool("is_pinned") { pinned.insert(folder) }
        }
        chat.folderOrders = folders
        chat.pinnedInFolders = pinned
        let main = positions.first(where: isMainPosition)
        chat.order = main?.tdInt64("order") ?? 0
        chat.isPinned = main?.tdBool("is_pinned") ?? false
        let archive = positions.first(where: isArchivePosition)
        chat.archiveOrder = archive?.tdInt64("order") ?? 0
        chat.isPinnedInArchive = archive?.tdBool("is_pinned") ?? false
    }

    /// `updateChatPosition` describes one list; order 0 removes the chat from it.
    static func applyPosition(_ position: TDNode, to chat: inout Chat) {
        if isMainPosition(position) {
            chat.order = position.tdInt64("order")
            chat.isPinned = position.tdBool("is_pinned")
        } else if isArchivePosition(position) {
            chat.archiveOrder = position.tdInt64("order")
            chat.isPinnedInArchive = position.tdBool("is_pinned")
        } else if let list = position.tdNode("list"), list.tdType == "chatListFolder" {
            let folder = list.tdInt("chat_folder_id")
            let order = position.tdInt64("order")
            chat.folderOrders[folder] = order == 0 ? nil : order
            if position.tdBool("is_pinned"), order != 0 { chat.pinnedInFolders.insert(folder) } else { chat.pinnedInFolders.remove(folder) }
        }
    }

    /// Chats without their own notification settings follow the defaults of this scope.
    static func notificationScope(of kind: ChatKind) -> String {
        switch kind {
        case .personal, .secret: "notificationSettingsScopePrivateChats"
        case .channel: "notificationSettingsScopeChannelChats"
        case .group, .other: "notificationSettingsScopeGroupChats"
        }
    }

    /// TDLib: chats must be sorted by the pair (order, chat.id) in descending order.
    static func precedes(_ lhs: Chat, _ rhs: Chat) -> Bool {
        if lhs.order != rhs.order { return lhs.order > rhs.order }
        return lhs.id > rhs.id
    }

    private static func kind(of node: TDNode) -> ChatKind {
        switch node.tdNode("type")?.tdType {
        case "chatTypePrivate": .personal
        case "chatTypeSecret": .secret
        case "chatTypeBasicGroup": .group
        case "chatTypeSupergroup":
            node.tdNode("type")?.tdBool("is_channel") == true ? .channel : .group
        default: .other
        }
    }

    // MARK: - drafts

    static func draftText(of draft: TDNode?) -> String {
        guard let draft else { return "" }
        if let content = draft.tdNode("content") {
            return content.tdType == "draftMessageContentText" ? content.tdText("text") : ""
        }
        // TDLib before the draft content types kept the text in `input_message_text`.
        return draft.tdNode("input_message_text")?.tdText("text") ?? ""
    }

    /// `nil` clears the draft.
    static func draftMessage(_ text: String) -> TDNode? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return [
            "@type": "draftMessage",
            "date": Int(Date().timeIntervalSince1970),
            "content": ["@type": "draftMessageContentText", "text": formattedText(text)],
        ]
    }

    // MARK: - outgoing content

    static func formattedText(_ text: String) -> TDNode {
        ["@type": "formattedText", "text": text, "entities": [Any]()]
    }

    /// What was typed, with Telegram's own markup read out of it the way the official apps read it:
    /// **жирный**, __курсив__, `код`, ~~зачёркнутый~~, ||спойлер|| and [текст](ссылка). Anything that does
    /// not pair up stays as typed.
    /// `keeping` are entities the markup cannot spell (custom emoji), already placed in this text.
    static func markedUp(_ text: String, keeping entities: [TDNode] = []) -> TDNode {
        var plain = formattedText(text)
        if !entities.isEmpty { plain["entities"] = entities }
        // Most messages hold nothing that could be markup, and are not sent through the parser at all.
        guard text.utf8.contains(where: { [0x2A, 0x5F, 0x60, 0x7E, 0x7C, 0x5B].contains($0) }),
              var parsed = TDBridge.answer(["@type": "parseMarkdown", "text": plain]),
              parsed.tdType == "formattedText" else { return plain }
        parsed["@extra"] = nil
        return parsed
    }

    /// The reverse, for the composer: a message that is being edited shows its formatting as the markup that
    /// would produce it, so saving it puts the same formatting back.
    static func markdown(of formatted: TDNode) -> String? {
        markdownText(of: formatted)?.text
    }

    /// The same with what the markup could not spell: custom emoji come back as entities placed in the
    /// marked-up text, to be handed to `markedUp(_:keeping:)` when the edit is saved.
    static func markdownText(of formatted: TDNode) -> (text: String, kept: [TDNode])? {
        guard !formatted.tdNodes("entities").isEmpty,
              let result = TDBridge.answer(["@type": "getMarkdownText", "text": formatted]),
              !result.tdString("text").isEmpty else { return nil }
        let kept = result.tdNodes("entities").filter { $0.tdNode("type")?.tdType == "textEntityTypeCustomEmoji" }
        return (result.tdString("text"), kept)
    }

    /// Entities of `old` that still stand on the same characters in `new`. An edit changes one stretch of the
    /// text: what lies before it keeps its place, what lies after it moves by the difference in length, and
    /// anything the stretch touches is dropped. Offsets are UTF-16, as TDLib counts them.
    static func carry(_ entities: [TDNode], from old: String, to new: String) -> [TDNode] {
        guard !entities.isEmpty else { return [] }
        let before = Array(old.utf16), after = Array(new.utf16)
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let shift = after.count - before.count
        return entities.compactMap { entity in
            let offset = entity.tdInt("offset"), length = entity.tdInt("length")
            if offset + length <= prefix { return entity }
            guard offset >= before.count - suffix else { return nil }
            var moved = entity
            moved["offset"] = offset + shift
            return moved
        }
    }

    /// `markup` is for what a person typed; a keyboard label or a command goes out letter for letter.
    static func inputText(_ text: String, clearDraft: Bool, markup: Bool = false) -> TDNode {
        ["@type": "inputMessageText", "text": markup ? markedUp(text) : formattedText(text), "clear_draft": clearDraft]
    }

    static func replyTo(_ messageId: Int64) -> TDNode {
        ["@type": "inputMessageReplyToMessage", "message_id": messageId]
    }

    /// Pictures Telegram accepts as photos are sent compressed like the official clients do; everything
    /// else goes as a file.
    static func inputContent(forFile url: URL) -> TDNode {
        let file: TDNode = ["@type": "inputFileLocal", "path": url.path]
        if let size = photoSize(of: url) {
            return [
                "@type": "inputMessagePhoto",
                "photo": ["@type": "inputPhoto", "photo": file, "width": size.width, "height": size.height],
            ]
        }
        return ["@type": "inputMessageDocument", "document": ["@type": "inputDocument", "document": file]]
    }

    /// Photos compressed, videos playable in the chat, everything else as a file; or all as files, untouched.
    /// The caption goes on the first message.
    static func inputContents(for urls: [URL], asDocuments: Bool, caption: String) async -> [TDNode] {
        var contents: [TDNode] = []
        for (index, url) in urls.enumerated() {
            let file: TDNode = ["@type": "inputFileLocal", "path": url.path]
            var content: TDNode
            if asDocuments {
                content = ["@type": "inputMessageDocument", "document": ["@type": "inputDocument", "document": file]]
            } else if let video = await videoInfo(of: url) {
                content = [
                    "@type": "inputMessageVideo",
                    "video": ["@type": "inputVideo", "video": file, "duration": video.duration,
                              "width": video.width, "height": video.height, "supports_streaming": true] as TDNode,
                ]
            } else {
                content = inputContent(forFile: url)
            }
            if index == 0, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content["caption"] = markedUp(caption)
            }
            contents.append(content)
        }
        return contents
    }

    /// Size and length of an .mp4/.mov/.m4v the chat can play; nil for anything else.
    static func videoInfo(of url: URL) async -> (width: Int, height: Int, duration: Int)? {
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else { return nil }
        let size = natural.applying(transform)
        return (Int(abs(size.width)), Int(abs(size.height)), Int(duration.seconds.rounded()))
    }

    /// Telegram photo limits: JPEG, PNG or WebP up to 10 MB, width + height ≤ 10000, sides ratio ≤ 20.
    private static func photoSize(of url: URL) -> (width: Int, height: Int)? {
        guard ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased()),
              let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes <= 10 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width + height <= 10_000,
              max(width, height) <= 20 * min(width, height) else { return nil }
        return (width, height)
    }

    // MARK: - incoming content

    static func body(of content: TDNode) -> Message.Body {
        switch content.tdType {
        case "messageText":
            return .text(content.tdText("text"))
        case "messageAnimatedEmoji":
            return .text(content.tdString("emoji"))
        default:
            break
        }
        if let service = serviceName(of: content) {
            return .service(service)
        }
        if let attachment = attachmentName(of: content) {
            let caption = content.tdText("caption")
            return .attachment(caption.isEmpty ? attachment : "\(attachment) — \(caption)")
        }
        return .unsupported("Сообщение этого типа не поддерживается: \(content.tdType)")
    }

    static func entities(of content: TDNode) -> [TextEntity] {
        entities(content.tdNode("text") ?? content.tdNode("caption"))
    }

    static func entities(_ formatted: TDNode?) -> [TextEntity] {
        guard let formatted else { return [] }
        // The usual answer is "no entities", and bridging the whole text to NSString just to say that was the
        // cost: this runs for every message parsed, on every update.
        let list = formatted.tdNodes("entities")
        guard !list.isEmpty else { return [] }
        let text = formatted.tdString("text") as NSString
        return list.compactMap { entity in
            let offset = entity.tdInt("offset")
            let length = entity.tdInt("length")
            guard length > 0, offset >= 0, offset + length <= text.length else { return nil }
            let type = entity.tdNode("type") ?? [:]
            let fragment = text.substring(with: NSRange(location: offset, length: length))
            let style: TextEntity.Style
            switch type.tdType {
            case "textEntityTypeBold": style = .bold
            case "textEntityTypeItalic": style = .italic
            case "textEntityTypeUnderline": style = .underline
            case "textEntityTypeStrikethrough": style = .strikethrough
            case "textEntityTypeCode", "textEntityTypePre", "textEntityTypePreCode": style = .code
            case "textEntityTypeSpoiler": style = .spoiler
            case "textEntityTypeCustomEmoji":
                let id = type.tdInt64("custom_emoji_id")
                guard id != 0 else { return nil }
                style = .customEmoji(id)
            case "textEntityTypeTextUrl":
                guard let url = URL(string: type.tdString("url")) else { return nil }
                // The words over a hidden link are remembered when they are themselves an address: that is
                // the oldest trick in phishing, and by the time the link is clicked only the URL is left.
                SecurityTools.noteLabel(fragment, for: url)
                style = .link(url)
            case "textEntityTypeUrl":
                let address = fragment.contains("://") ? fragment : "https://" + fragment
                guard let url = URL(string: address) else { return nil }
                style = .link(url)
            case "textEntityTypeMention":
                guard let url = URL(string: "https://t.me/" + fragment.dropFirst()) else { return nil }
                style = .link(url)
            case "textEntityTypeEmailAddress":
                guard let url = URL(string: "mailto:" + fragment) else { return nil }
                style = .link(url)
            case "textEntityTypePhoneNumber":
                guard let url = URL(string: "tel:" + fragment.filter { $0.isNumber || $0 == "+" }) else { return nil }
                style = .link(url)
            default:
                return nil
            }
            return TextEntity(offset: offset, length: length, style: style)
        }
    }

    static func media(of content: TDNode) -> MediaInfo? {
        switch content.tdType {
        case "messagePhoto":
            guard var photo = picture(content.tdNode("photo")) else { return nil }
            photo.hasSpoiler = content.tdBool("has_spoiler")
            return photo
        case "messageVideo":
            return clip(content.tdNode("video"), file: "video", kind: .video, spoiler: content.tdBool("has_spoiler"))
        case "messageAnimation":
            return clip(content.tdNode("animation"), file: "animation", kind: .animation, spoiler: content.tdBool("has_spoiler"))
        case "messageVoiceNote":
            guard let voice = content.tdNode("voice_note"), let file = voice.tdNode("voice"), file.tdInt("id") != 0 else { return nil }
            return MediaInfo(
                kind: .voiceNote,
                fileId: file.tdInt("id"),
                fileSize: fileSize(file),
                thumbnailFileId: nil,
                minithumbnail: nil,
                width: 0,
                height: 0,
                duration: voice.tdInt("duration"),
                hasSpoiler: false,
                waveform: waveform(Data(base64Encoded: voice.tdString("waveform")) ?? Data())
            )
        case "messageVideoNote":
            guard var note = clip(content.tdNode("video_note"), file: "video", kind: .videoNote, spoiler: false) else { return nil }
            let side = content.tdNode("video_note")?.tdInt("length") ?? 0
            note.width = side
            note.height = side
            return note
        default:
            return nil
        }
    }

    /// A `photo` object as shown in a bubble: the size sharp at 300 points on a Retina screen (not the
    /// 2560-pixel original), plus a small size that loads first.
    static func picture(_ photo: TDNode?) -> MediaInfo? {
        guard let photo else { return nil }
        let sizes = photo.tdNodes("sizes").filter { $0.tdNode("photo") != nil }
            .sorted { $0.tdInt("width") * $0.tdInt("height") < $1.tdInt("width") * $1.tdInt("height") }
        guard let size = sizes.first(where: { max($0.tdInt("width"), $0.tdInt("height")) >= 640 }) ?? sizes.last,
              let file = size.tdNode("photo") else { return nil }
        let preview = sizes.last { max($0.tdInt("width"), $0.tdInt("height")) <= 320 }?.tdNode("photo")?.tdInt("id")
        return MediaInfo(
            kind: .photo,
            fileId: file.tdInt("id"),
            fileSize: fileSize(file),
            thumbnailFileId: nil,
            minithumbnail: minithumbnail(photo),
            width: size.tdInt("width"),
            height: size.tdInt("height"),
            duration: 0,
            hasSpoiler: false,
            previewFileId: preview == file.tdInt("id") ? nil : preview
        )
    }

    static func linkPreview(_ node: TDNode?) -> LinkPreview? {
        guard let node, let url = URL(string: node.tdString("url")) else { return nil }
        let type = node.tdNode("type") ?? [:]
        let title = node.tdString("title")
        let description = node.tdText("description")
        guard !title.isEmpty || !description.isEmpty || type["photo"] != nil else { return nil }
        let photo = picture(type.tdNode("photo") ?? type.tdNode("cover") ?? type.tdNode("thumbnail"))
        return LinkPreview(
            url: url,
            siteName: node.tdString("site_name").isEmpty ? (url.host() ?? "") : node.tdString("site_name"),
            title: title,
            description: description,
            photo: photo
        )
    }

    private static func clip(_ node: TDNode?, file key: String, kind: MediaInfo.Kind, spoiler: Bool) -> MediaInfo? {
        guard let node, let file = node.tdNode(key), file.tdInt("id") != 0 else { return nil }
        let thumbnail = node.tdNode("thumbnail")
        let isPicture = ["thumbnailFormatJpeg", "thumbnailFormatWebp", "thumbnailFormatPng"]
            .contains(thumbnail?.tdNode("format")?.tdType ?? "")
        return MediaInfo(
            kind: kind,
            fileId: file.tdInt("id"),
            fileSize: fileSize(file),
            thumbnailFileId: isPicture ? thumbnail?.tdNode("file")?.tdInt("id") : nil,
            minithumbnail: minithumbnail(node),
            width: node.tdInt("width"),
            height: node.tdInt("height"),
            duration: node.tdInt("duration"),
            hasSpoiler: spoiler
        )
    }

    /// Telegram packs the waveform as 5-bit values, least significant bits first.
    static func waveform(_ data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        let count = bytes.count * 8 / 5
        return (0..<count).map { index in
            let bit = index * 5
            let low = Int(bytes[bit / 8])
            let high = bit / 8 + 1 < bytes.count ? Int(bytes[bit / 8 + 1]) : 0
            return UInt8(((low | high << 8) >> (bit % 8)) & 31)
        }
    }

    private static func fileSize(_ file: TDNode) -> Int64 {
        max(file.tdInt64("size"), file.tdInt64("expected_size"))
    }

    private static func minithumbnail(_ node: TDNode) -> Data? {
        node.tdNode("minithumbnail").flatMap { Data(base64Encoded: $0.tdString("data")) }
    }

    static func sticker(of content: TDNode) -> Sticker? {
        switch content.tdType {
        case "messageSticker": sticker(content.tdNode("sticker"), isEmoji: false)
        // Emoji without an animation arrive with a null sticker and stay plain text.
        case "messageAnimatedEmoji": sticker(content.tdNode("animated_emoji")?.tdNode("sticker"), isEmoji: true)
        default: nil
        }
    }

    static func sticker(_ node: TDNode?, isEmoji: Bool) -> Sticker? {
        guard let node, let file = node.tdNode("sticker"), file.tdInt("id") != 0 else { return nil }
        let format: Sticker.Format
        switch node.tdNode("format")?.tdType {
        case "stickerFormatWebp": format = .webp
        case "stickerFormatTgs": format = .tgs
        case "stickerFormatWebm": format = .webm
        default: return nil
        }
        let thumbnail = node.tdNode("thumbnail")
        let isPicture = ["thumbnailFormatWebp", "thumbnailFormatJpeg", "thumbnailFormatPng"]
            .contains(thumbnail?.tdNode("format")?.tdType ?? "")
        return Sticker(
            fileId: file.tdInt("id"),
            format: format,
            width: node.tdInt("width"),
            height: node.tdInt("height"),
            emoji: node.tdString("emoji"),
            thumbnailFileId: isPicture ? thumbnail?.tdNode("file")?.tdInt("id") : nil,
            isEmoji: isEmoji
        )
    }

    static func attachment(of content: TDNode) -> Attachment? {
        let file: TDNode?
        var name: String
        switch content.tdType {
        case "messageDocument":
            file = content.tdNode("document")?.tdNode("document")
            name = content.tdNode("document")?.tdString("file_name") ?? ""
        case "messagePhoto":
            let sizes = content.tdNode("photo")?.tdNodes("sizes") ?? []
            file = sizes.max { $0.tdInt("width") * $0.tdInt("height") < $1.tdInt("width") * $1.tdInt("height") }?
                .tdNode("photo")
            name = ""
        case "messageVideo":
            file = content.tdNode("video")?.tdNode("video")
            name = content.tdNode("video")?.tdString("file_name") ?? ""
        case "messageAnimation":
            file = content.tdNode("animation")?.tdNode("animation")
            name = content.tdNode("animation")?.tdString("file_name") ?? ""
        case "messageAudio":
            file = content.tdNode("audio")?.tdNode("audio")
            name = content.tdNode("audio")?.tdString("file_name") ?? ""
        case "messageVoiceNote":
            file = content.tdNode("voice_note")?.tdNode("voice")
            name = ""
        case "messageVideoNote":
            file = content.tdNode("video_note")?.tdNode("video")
            name = ""
        default:
            return nil
        }
        guard let file, file.tdInt("id") != 0 else { return nil }
        let fileId = file.tdInt("id")
        if name.isEmpty { name = defaultFileName(for: content.tdType, fileId: fileId) }
        return Attachment(fileId: fileId, name: name)
    }

    private static func defaultFileName(for type: String, fileId: Int) -> String {
        switch type {
        case "messagePhoto": "photo-\(fileId).jpg"
        case "messageVideo": "video-\(fileId).mp4"
        case "messageAnimation": "animation-\(fileId).mp4"
        case "messageAudio": "audio-\(fileId).mp3"
        case "messageVoiceNote": "voice-\(fileId).ogg"
        case "messageVideoNote": "video-note-\(fileId).mp4"
        default: "file-\(fileId)"
        }
    }

    private static func attachmentName(of content: TDNode) -> String? {
        switch content.tdType {
        case "messagePhoto": return "Фото"
        case "messageVideo": return "Видео"
        case "messageAnimation": return "GIF"
        case "messageAudio":
            let audio = content.tdNode("audio") ?? [:]
            let title = [audio.tdString("performer"), audio.tdString("title")].filter { !$0.isEmpty }
            return title.isEmpty ? "Аудио" : "Аудио: " + title.joined(separator: " — ")
        case "messageDocument":
            let name = content.tdNode("document")?.tdString("file_name") ?? ""
            return name.isEmpty ? "Файл" : name
        case "messageVoiceNote": return "Голосовое сообщение" + duration(of: content.tdNode("voice_note"))
        case "messageVideoNote": return "Видеосообщение" + duration(of: content.tdNode("video_note"))
        case "messageSticker":
            let emoji = content.tdNode("sticker")?.tdString("emoji") ?? ""
            return emoji.isEmpty ? "Стикер" : "Стикер \(emoji)"
        case "messageLocation": return "Геолокация"
        case "messageLiveLocation": return "Трансляция геолокации"
        case "messageVenue":
            let title = content.tdNode("venue")?.tdString("title") ?? ""
            return title.isEmpty ? "Место" : "Место: \(title)"
        case "messageContact":
            let contact = content.tdNode("contact") ?? [:]
            let name = [contact.tdString("first_name"), contact.tdString("last_name")].filter { !$0.isEmpty }
            let details = [name.joined(separator: " "), contact.tdString("phone_number")].filter { !$0.isEmpty }
            return details.isEmpty ? "Контакт" : "Контакт: " + details.joined(separator: ", ")
        case "messagePoll": return "Опрос: \(content.tdNode("poll")?.tdText("question") ?? "")"
        case "messageChecklist": return "Список задач: \(content.tdNode("list")?.tdText("title") ?? "")"
        case "messageInvoice": return "Счёт"
        case "messageDice":
            let value = content.tdInt("value")
            return value > 0 ? "Кости: \(value)" : "Кости"
        case "messageGame": return "Игра: \(content.tdNode("game")?.tdString("title") ?? "")"
        case "messageStory": return "История"
        case "messagePaidMedia": return "Платный контент"
        default: return nil
        }
    }

    private static func duration(of media: TDNode?) -> String {
        let seconds = media?.tdInt("duration") ?? 0
        guard seconds > 0 else { return "" }
        return String(format: " (%d:%02d)", seconds / 60, seconds % 60)
    }

    private static func serviceName(of content: TDNode) -> String? {
        switch content.tdType {
        case "messageChatAddMembers": return "Добавил участников: \(content.tdInt64s("member_user_ids").count)"
        case "messageChatDeleteMember": return "Участник удалён"
        case "messageChatChangeTitle": return "Новое название: \(content.tdString("title"))"
        case "messageChatChangePhoto": return "Обновлено фото группы"
        case "messageChatDeletePhoto": return "Фото группы удалено"
        case "messageChatJoinByLink": return "вошёл по ссылке"
        case "messageChatJoinByRequest": return "вошёл по заявке"
        case "messageChatSetMessageAutoDeleteTime": return "Изменён срок хранения сообщений"
        case "messageBasicGroupChatCreate", "messageSupergroupChatCreate": return "Группа создана"
        case "messageChatUpgradeTo", "messageChatUpgradeFrom": return "Группа улучшена до супергруппы"
        case "messagePinMessage": return "Сообщение закреплено"
        case "messageScreenshotTaken": return "Сделан скриншот"
        case "messageCall": return callName(of: content)
        case "messageGroupCall": return "Групповой звонок"
        case "messageVideoChatScheduled": return "Видеочат запланирован"
        case "messageVideoChatStarted": return "Видеочат начат"
        case "messageVideoChatEnded": return "Видеочат завершён"
        case "messageInviteVideoChatParticipants": return "Приглашение в видеочат"
        case "messageChatSetTheme": return "Тема чата изменена"
        case "messageChatSetBackground": return "Фон чата изменён"
        case "messageChatBoost": return "Чат получил бусты"
        case "messageContactRegistered": return "Присоединился к Telegram"
        case "messageCustomServiceAction": return content.tdString("text")
        case "messageForumTopicCreated": return "Создана тема «\(content.tdString("name"))»"
        case "messageForumTopicEdited": return "Тема изменена"
        case "messageForumTopicIsClosedToggled": return content.tdBool("is_closed") ? "Тема закрыта" : "Тема открыта"
        case "messageExpiredPhoto": return "Фото с таймером истекло"
        case "messageExpiredVideo": return "Видео с таймером истекло"
        case "messageExpiredVideoNote": return "Видеосообщение истекло"
        case "messageExpiredVoiceNote": return "Голосовое сообщение истекло"
        case "messageGameScore": return "Новый рекорд в игре: \(content.tdInt("score"))"
        case "messagePaymentSuccessful", "messagePaymentSuccessfulBot": return "Платёж выполнен"
        case "messageGift", "messageUpgradedGift", "messageRefundedUpgradedGift", "messageGiftedPremium",
             "messagePremiumGiftCode", "messageGiftedStars", "messageGiftedGrams":
            return "Подарок"
        case "messageGiveaway", "messageGiveawayCreated", "messageGiveawayCompleted", "messageGiveawayWinners",
             "messageGiveawayPrizeStars":
            return "Розыгрыш"

        // Layer 229 additions; without a label each of these showed its raw TDLib type name.
        case "messageUnsupported": return "Сообщение этого типа пока не читается"
        case "messageChatOwnerChanged": return "Назначен новый владелец"
        case "messageChatOwnerLeft": return "Владелец вышел из чата"
        case "messageChatAddedToCommunity": return "Чат добавлен в сообщество"
        case "messageChatJoinFromCommunity": return "вошёл через сообщество"
        case "messageChatRemovedFromCommunity": return "Чат убран из сообщества"
        case "messageBotWriteAccessAllowed": return "Боту разрешено писать"
        case "messagePollOptionAdded": return "В опросе — новый вариант: \(content.tdText("text"))"
        case "messagePollOptionDeleted": return "Вариант убран из опроса: \(content.tdText("text"))"
        case "messageForumTopicIsHiddenToggled": return content.tdBool("is_hidden") ? "Тема скрыта" : "Тема снова видна"
        case "messageChatHasProtectedContentToggled":
            return content.tdBool("new_has_protected_content") ? "Копирование запрещено" : "Копирование разрешено"
        case "messageChatHasProtectedContentDisableRequested": return "Запрос на снятие запрета копирования"
        case "messageChatShared": return "Чат выбран для переписки"
        case "messageUsersShared": return "Профили переданы: \(content.tdNodes("users").count)"
        case "messageProximityAlertTriggered": return "Кто-то прошёл совсем рядом"
        case "messagePaymentRefunded": return "Платёж возвращён"
        case "messagePaidMessagesRefunded": return "Возврат за \(content.tdInt("message_count")) платных сообщений"
        case "messagePaidMessagePriceChanged": return "Цена платного сообщения изменена"
        case "messageDirectMessagePriceChanged":
            return content.tdBool("is_enabled") ? "Платные сообщения включены" : "Платные сообщения выключены"
        case "messageSuggestBirthdate": return "Предложен день рождения"
        case "messageSuggestProfilePhoto": return "Предложено фото профиля"
        case "messageChecklistTasksAdded": return "Пункты добавлены в список"
        case "messageChecklistTasksDone": return "Отметки в списке изменены"
        case "messageWebAppDataSent": return "Нажата кнопка: \(content.tdString("button_text"))"
        case "messageWebAppDataReceived": return "Ответ мини-приложения: \(content.tdString("button_text"))"
        case "messagePassportDataSent": return "Отправлены паспортные данные"
        case "messageRichMessage": return "Богатое сообщение"
        case "messageStakeDice": return "Ставка на кубик"
        case "messageManagedBotCreated": return "Создан управляемый бот"
        case "messageUpgradedGiftPurchaseOffer", "messageUpgradedGiftPurchaseOfferRejected": return "Предложение о покупке подарка"
        case "messageSuggestedPostApproved": return "Заказной пост одобрен"
        case "messageSuggestedPostApprovalFailed": return "Заказной пост не одобрен"
        case "messageSuggestedPostDeclined": return "Заказной пост отклонён"
        case "messageSuggestedPostPaid": return "Заказной пост оплачен"
        case "messageSuggestedPostRefunded": return "Оплата заказного поста возвращена"
        default: return nil
        }
    }

    private static func callName(of content: TDNode) -> String {
        if content.tdNode("discard_reason")?.tdType == "callDiscardReasonMissed" { return "Пропущенный звонок" }
        return content.tdBool("is_video") ? "Видеозвонок" : "Звонок"
    }
}
