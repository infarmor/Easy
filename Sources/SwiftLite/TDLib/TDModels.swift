import AVFoundation
import Foundation
import ImageIO

enum ChatKind: Equatable {
    case personal, group, channel, secret, other

    var label: String {
        switch self {
        case .personal: L("личный чат")
        case .group: L("группа")
        case .channel: L("канал")
        case .secret: L("секретный чат")
        case .other: L("чат")
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
    /// Seconds after which new messages delete themselves (self-destruct in a secret chat); 0 for never.
    var autoDeleteTime = 0

    var isArchived: Bool { archiveOrder != 0 }
    /// Only a supergroup or a channel has a member list TDLib can page through; a basic group and a private
    /// chat do not, so nothing that offers "its people" should pretend otherwise.
    var hasRoster: Bool { groupKey.hasPrefix("s") }
    /// Whose badge follows this chat's name: the other person's in a private chat, the chat's own otherwise.
    var badgeKey: String { userId != 0 ? "u\(userId)" : "c\(id)" }
}

/// What Telegram draws after a name: the emoji status a Premium user chose, a collectible gift worn as one,
/// or the plain Premium star when they chose nothing.
struct NameBadge: Equatable {
    /// The custom emoji to draw; 0 for the plain star.
    var customEmojiId: Int64 = 0
    /// "Plush Pepe #1234" when the status is a collectible gift, empty otherwise.
    var giftTitle = ""

    var isGift: Bool { !giftTitle.isEmpty }
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
            case .owner: return L("владелец")
            case .admin: return L("администратор")
            case .member: return L("участник")
            case .restricted: return L("ограничен")
            case .banned: return L("забанен")
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
        .init(key: "can_manage_chat", label: L("Управлять чатом")),
        .init(key: "can_change_info", label: L("Менять название и фото")),
        .init(key: "can_post_messages", label: L("Публиковать в канале")),
        .init(key: "can_edit_messages", label: L("Редактировать чужие сообщения")),
        .init(key: "can_delete_messages", label: L("Удалять сообщения")),
        .init(key: "can_invite_users", label: L("Приглашать участников")),
        .init(key: "can_restrict_members", label: L("Ограничивать участников")),
        .init(key: "can_pin_messages", label: L("Закреплять сообщения")),
        .init(key: "can_manage_topics", label: L("Управлять темами")),
        .init(key: "can_promote_members", label: L("Назначать администраторов")),
        .init(key: "can_manage_video_chats", label: L("Управлять видеочатами")),
        .init(key: "can_post_stories", label: L("Публиковать истории")),
        .init(key: "can_edit_stories", label: L("Редактировать истории")),
        .init(key: "can_delete_stories", label: L("Удалять истории")),
        .init(key: "can_manage_direct_messages", label: L("Писать лично от имени чата")),
        .init(key: "can_manage_tags", label: L("Выдавать участникам метки")),
        .init(key: "can_send_welcome_messages", label: L("Приветственные сообщения")),
        .init(key: "is_anonymous", label: L("Действовать анонимно")),
    ]

    static let permissions: [RightsFlag] = [
        .init(key: "can_send_basic_messages", label: L("Писать сообщения")),
        .init(key: "can_send_audios", label: L("Аудио")),
        .init(key: "can_send_documents", label: L("Файлы")),
        .init(key: "can_send_photos", label: L("Фото")),
        .init(key: "can_send_videos", label: L("Видео")),
        .init(key: "can_send_video_notes", label: L("Видеосообщения")),
        .init(key: "can_send_voice_notes", label: L("Голосовые")),
        .init(key: "can_send_polls", label: L("Опросы")),
        .init(key: "can_send_other_messages", label: L("Стикер, GIF и прочее")),
        .init(key: "can_add_link_previews", label: L("Превью ссылок")),
        .init(key: "can_react_to_messages", label: L("Ставить реакции")),
        .init(key: "can_edit_tag", label: L("Менять свою метку")),
        .init(key: "can_change_info", label: L("Менять информацию чата")),
        .init(key: "can_invite_users", label: L("Приглашать участников")),
        .init(key: "can_pin_messages", label: L("Закреплять сообщения")),
        .init(key: "can_create_topics", label: L("Создавать темы")),
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
        if on.count > 3 { return L("\(on.prefix(3).joined(separator: ", ")) и ещё \(on.count - 3)") }
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
    /// A channel post whose channel has a discussion group: how many comments it has. nil where there is
    /// nowhere to comment.
    var commentCount: Int?
    /// A post of a channel, as opposed to a message in a group.
    var isChannelPost = false
    /// The comment thread a message of a discussion group belongs to; 0 outside one.
    var threadId: Int64 = 0

    /// The id this message was first shown under, when that was another one. A message being sent has a
    /// temporary id and gets its real one when the server takes it; to the eye it is the same bubble, so the
    /// view goes on knowing it by the first.
    var firstShownId: Int64 = 0
    /// What the transcript's views are told apart by. Not `id`: that changes once in a sent message's life,
    /// and a view whose identity changes is torn down and built again — the bubble blinked and the transcript
    /// scrolled a second time, as though another message had arrived.
    var viewId: Int64 { firstShownId != 0 ? firstShownId : id }

    var isForwarded: Bool { !forwardSenderKey.isEmpty || !forwardSenderName.isEmpty }

    /// Only messages that reached the server can be replied to, pinned or edited.
    var isSent: Bool { !isPending && !isFailed }
}
