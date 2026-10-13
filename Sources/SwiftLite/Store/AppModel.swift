import AppKit
import Foundation
import Observation

/// A reply or an edit the composer is working on.
struct ComposerContext: Equatable {
    enum Kind: Equatable {
        case reply, edit
    }

    let kind: Kind
    let messageId: Int64
    let title: String
    let preview: String
    /// Editing the caption of a photo, video or file rather than a text message.
    var editsCaption = false
}

/// A person to mention or a bot command to send, offered while the composer is being typed in.
struct ComposerSuggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        /// `username` is empty for people who have none; they are mentioned by name.
        case mention(userId: Int64, username: String)
        case command(String)
    }

    let id: String
    var title: String
    /// "@username" for a person, what the command does for a command.
    var detail: String
    var photo: ProfilePhoto?
    var seed: Int64 = 0
    var kind: Kind
}

/// What the profile sheet can list out of a chat's history.
enum SharedMediaKind: String, CaseIterable, Identifiable {
    case photos = "Фото"
    case files = "Файлы"
    case links = "Ссылки"

    var id: String { rawValue }

    var filter: String {
        switch self {
        case .photos: "searchMessagesFilterPhoto"
        case .files: "searchMessagesFilterDocument"
        case .links: "searchMessagesFilterUrl"
        }
    }
}

/// The markup the Формат menu wraps a selection in; the same marks `TD.markedUp` reads when the message goes.
enum TextFormat: CaseIterable {
    case bold, italic, strikethrough, code, spoiler, link

    var title: String {
        switch self {
        case .bold: L("Жирный")
        case .italic: L("Курсив")
        case .strikethrough: L("Зачёркнутый")
        case .code: L("Моноширинный")
        case .spoiler: L("Спойлер")
        case .link: L("Ссылка")
        }
    }

    /// What goes before and after the selected words.
    var marks: (open: String, close: String) {
        switch self {
        case .bold: ("**", "**")
        case .italic: ("__", "__")
        case .strikethrough: ("~~", "~~")
        case .code: ("`", "`")
        case .spoiler: ("||", "||")
        case .link: ("[", "]()")
        }
    }

    /// The text with `range` wrapped, and where the selection belongs afterwards: on the same words, so a
    /// second format can follow at once — or, for a link, inside the brackets waiting for its address.
    func wrap(_ text: String, _ range: Range<String.Index>) -> (text: String, selection: Range<String.Index>) {
        let (open, close) = marks
        let before = text[..<range.lowerBound], inner = text[range], after = text[range.upperBound...]
        let result = before + open + inner + close + after
        let start = result.index(result.startIndex, offsetBy: before.count + open.count)
        let end = result.index(start, offsetBy: inner.count)
        if self == .link {
            let address = result.index(end, offsetBy: 2)
            return (String(result), address..<address)
        }
        return (String(result), start..<end)
    }
}

/// One use of a formatting command; the id tells two presses of the same one apart.
struct FormatRequest: Equatable {
    let id = UUID()
    let format: TextFormat
}

/// How a message may be deleted, from `getMessageProperties`.
struct DeletionOptions {
    let forSelf: Bool
    let forEveryone: Bool
}

/// Messages on their way to the "Переслать…" picker.
struct ForwardBatch: Identifiable {
    let id = UUID()
    let messages: [Message]
    /// Sent from the selection bar: forwarding them ends picking.
    var endsSelection = false
}

/// Text shown in a sheet: a TDLib object as pretty-printed JSON, or a message's edit history.
struct InspectedCode: Identifiable {
    let id = UUID()
    let title: String
    let json: String
    var isCode = true
    /// The object itself, for the readable tree view.
    var node: TDNode?
    /// Set for an indicators report: the sheet then offers lookups and export for what was found.
    var indicators: SecurityTools.Indicators?
}

/// Space TDLib uses on disk, from `getStorageStatisticsFast`.
struct StorageUsage {
    let files: Int64
    let fileCount: Int
    let database: Int64
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case credentials
        case phone
        case email
        case code(destination: String)
        /// Waiting for Telegram on a phone to scan the login QR code.
        case qr(link: String)
        case password(hint: String)
        case working
        case failed(String)
    }

    private enum CloseIntent {
        case logOut, forgetCredentials, restart, quit
    }

    private enum CodeTarget {
        case phone, email
    }

    var phase: Phase = .credentials
    var accountName = ""
    /// Which of the accounts on this Mac this session belongs to; empty for the first one.
    @ObservationIgnored let slot: String
    /// The accounts together; nil for a model made on its own, as the test stands make it.
    @ObservationIgnored weak var hub: AccountHub?
    /// What the Dock would show for this account alone: the sidebar marks the other accounts with it.
    private(set) var unreadBadge = 0
    /// Telegram Stars on the account; nil until TDLib has said.
    var ownedStars: Int?
    /// Your own id and photo, for the account card at the bottom of the sidebar.
    var myId: Int64 { myUserId }
    var myPhoto: ProfilePhoto? { senderPhotos["u\(myUserId)"] }
    var errorText = ""
    var busy = false

    var apiIdField = ""
    var apiHashField = ""
    var phoneField = ""
    var emailField = ""
    var codeField = ""
    var passwordField = ""
    private(set) var canResendCode = false

    var chats: [Chat] = []
    /// The sidebar shows the archive instead of the main list.
    var showsArchive = false {
        didSet {
            guard showsArchive != oldValue else { return }
            rebuildChatList()
            if showsArchive { Task { await loadChats() } }
        }
    }
    var filter = "" {
        didSet { if filter != oldValue { scheduleMessageSearch() } }
    }
    /// Bumped by ⌘K: the sidebar's search field takes the focus.
    var searchChatsRequest = 0
    /// Text is selected in the composer, so ⌘I and ⌘K mean italic and link there rather than the profile and
    /// the chat search.
    var composerHasSelection = false
    /// A formatting command from the menu or its shortcut; the composer, which knows the selection, applies it.
    var formatRequest: FormatRequest?
    /// The badge drawn after each name that has one, keyed like `senderNames`: "u<id>" for people, "c<id>"
    /// for chats.
    var nameBadges: [String: NameBadge] = [:]
    /// Custom emoji that are a shape to be coloured by whoever draws them, not a picture with colours of its own.
    var templateEmoji: Set<Int64> = []
    /// Where the picture of each custom emoji seen so far lies on disk, by its id.
    var customEmoji: [Int64: String] = [:]
    @ObservationIgnored var loadingCustomEmoji: Set<Int64> = []
    /// The window is covered by the passcode screen. At launch nothing has been started yet; later the session
    /// keeps running underneath and only the interface is shut.
    var isLocked = false
    /// A passcode is set; the settings read this to offer the right half of their controls.
    var hasPasscode = AppLock.isEnabled
    /// Keys of the passcode, in memory only while the app has been unlocked with it since launch.
    @ObservationIgnored var lockKeys: AppLock.Keys?
    @ObservationIgnored var lockTimer: Timer?
    /// A device that signed in to the account and has not been confirmed as yours: "iPhone 17 · Moscow, Russia".
    /// Kept until it is answered, so a login noticed while the app was locked or in the background is asked
    /// about when you are back.
    @ObservationIgnored var unconfirmedLogin: String?
    @ObservationIgnored var isAskingAboutLogin = false
    /// The chat list has settled after launch, so a row changing place from now on is news worth animating.
    var animatesChatList = false
    /// Something is written in the composer. Kept apart from `draft` for the menus: read there, `draft` itself
    /// would have every menu rebuilt on each key typed, while this changes only at the first and last letter.
    var hasDraftText = false
    /// The "Новый чат" sheet is on screen.
    var showsNewChat = false
    /// The sheets for a new group, channel or contact, and for the files this account has downloaded.
    var showsCreateChat = false
    var showsDownloads = false
    /// The gallery of photos and videos: of one chat, or of all of them.
    var mediaGallery: MediaScope?
    /// Whose stories the viewer is showing.
    var storyViewer: StoryTarget?
    /// The picture or video picked for a story of your own, waiting for its caption.
    var storyDraft: URL?
    /// People and channels with stories up right now, in Telegram's order.
    var storyChats: [StoryChat] = []
    /// A chat was opened from the keyboard (Return in the sidebar search): its composer takes the focus, so
    /// the next thing typed is the message rather than more of the search.
    var wantsComposerFocus = false
    /// Messages from all chats matching the sidebar search.
    var foundMessages: [Message] = []
    /// The chat list writes this directly; moving away from the open chat saves its draft and closes it in TDLib.
    var selection: Int64? {
        didSet {
            if selection != openChatId { leaveOpenChat() }
            refreshSelectedChat()
            if let selection, selection != oldValue, myUserId != 0 {
                UserDefaults.standard.set("\(myUserId):\(selection)", forKey: Preferences.lastChat)
            }
        }
    }
    var messages: [Message] = [] {
        didSet { applyTranscriptChange() }
    }
    /// The transcript shows an older stretch of history (after a jump), not the latest messages.
    var isViewingHistory = false
    /// Search inside the open chat: matching message ids, newest first, and the one on screen.
    var isSearching = false
    var searchQuery = ""
    var searchResults: [Int64] = []
    var searchPosition = 0
    /// How many matches the chat holds in all, which is more than `searchResults` until every page is read.
    var searchTotal = 0
    /// Where the next page of matches starts; 0 when there is none.
    @ObservationIgnored var searchNextFrom: Int64 = 0
    /// The words the matches in hand were found by: the field may have been typed in since.
    @ObservationIgnored var searchedQuery = ""
    var isSearchRunning = false
    var draft = ""
    /// The column of a group's people, opened from the chat's toolbar.
    var showsMembersPanel = false
    /// Whether that column is actually on screen: only supergroups have a roster to show, so the switch stays
    /// armed across a private chat without drawing an empty column for it.
    var showsMembersColumn: Bool {
        showsMembersPanel && selectedChat?.hasRoster == true
    }
    var composerContext: ComposerContext?
    /// The message whose "Переслать…" picker is open.
    var forwardingBatch: ForwardBatch?
    /// Several messages picked for forwarding, copying or deleting at once.
    var isSelectingMessages = false
    var selectedMessageIds: Set<Int64> = []
    var loadingHistory = false
    var canLoadOlder = false
    var senderNames: [String: String] = [:]
    /// Profile photos of message senders, keyed like `senderNames`.
    var senderPhotos: [String: ProfilePhoto] = [:]
    /// "Чат 3 из 40: Иван" while an export runs; nil otherwise.
    var exportProgress: String?
    /// The folder of the last finished export.
    var lastExport: URL?
    @ObservationIgnored var exportTask: Task<Void, Never>?
    /// Folders of the chat list; the chosen one filters the sidebar (nil: all chats).
    private(set) var chatFolders: [ChatFolder] = []
    var selectedFolder: Int? {
        didSet {
            guard selectedFolder != oldValue else { return }
            rebuildChatList()
            Task { await loadChats() }
        }
    }
    /// Unread messages of each place the sidebar rail can open, so its badges need no request: `folderUnread`
    /// is keyed by folder id, and the other two cover "all chats" and the archive.
    private(set) var folderUnread: [Int: UnreadTally] = [:]
    private(set) var mainUnread = UnreadTally()
    private(set) var archiveUnread = UnreadTally()
    /// Public chats and people found by the sidebar search that are not in your list yet.
    var foundPublicChats: [Int64] = []
    /// Messages of the open chat waiting to be sent at a set time.
    var scheduledMessages: [Message] = []
    /// Downloads and uploads of the files on screen, by file id.
    var transfers: [Int: FileTransfer] = [:]
    /// Files chosen, dropped or pasted, waiting in the send sheet.
    var pendingFiles: [URL]?
    /// The profile sheet on screen.
    var profile: ProfileInfo? {
        didSet { if profile == nil { profileGeneration += 1 } }
    }
    @ObservationIgnored var profileGeneration = 0
    /// A short answer from a bot button, shown over the conversation for a moment.
    var toast: String?
    /// "<message id>:<button id>" of a callback button waiting for the bot's answer.
    var pendingButton: String?
    /// The keyboard a bot put in place of the composer, and whether it is unfolded.
    var replyKeyboard: ReplyMarkup?
    var isReplyKeyboardShown = true
    @ObservationIgnored var replyKeyboardBotId: Int64 = 0
    /// Menu button and commands of the open bot chat.
    var botMenu: BotMenu?
    /// A bot chat opened through a start link waits for "Запустить" with this parameter.
    var pendingBotStart: String?
    /// The mini app on screen; the window follows this value.
    var webApp: WebAppSession?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    @ObservationIgnored var prefetchedChats: Set<Int64> = []
    @ObservationIgnored var prefetchesRunning = 0
    /// Text to put in the composer of a chat that is still opening (a t.me link with ?text=, an inline query).
    @ObservationIgnored var pendingDrafts: [Int64: String] = [:]
    /// Composer text the app put there itself: saved as a draft, but it does not make you "печатает…".
    @ObservationIgnored var quietDraft: String?
    /// Chats whose history you are clearing or deleting: those deletions are yours, not someone else's.
    @ObservationIgnored var clearingChats: [Int64: Int] = [:]
    /// Secret chats arrive as two things, the chat and its session, in either order: the session's state by
    /// its id, and which chat each session belongs to.
    @ObservationIgnored var secretStates: [Int: SecretChatState] = [:]
    @ObservationIgnored var chatIdBySecretId: [Int: Int64] = [:]
    /// A person's secret chats: they have ids of their own, so presence cannot find them by the user's id.
    @ObservationIgnored var secretChatsOfUser: [Int64: Set<Int64>] = [:]
    /// Files whose progress the interface shows; `updateFile` for everything else (avatars, stickers) is ignored.
    @ObservationIgnored var trackedFiles: Set<Int> = []
    /// Start parameters of links whose bot chat is still opening.
    @ObservationIgnored var startParameters: [Int64: String] = [:]
    /// The latest hand-over of the proxy settings to TDLib; each one waits for the one before. See `applyProxy`.
    @ObservationIgnored var proxySync: Task<Void, Never>?
    /// Raw TDLib object shown by "Код сообщения…" / "Код чата…".
    var inspectedCode: InspectedCode?
    /// The group or channel whose "Управление чатом…" sheet is open.
    var managedChat: Chat?
    /// "1.8.67 (42e6a52)" for the settings window.
    private(set) var tdlibVersion = ""
    /// Replied-to messages that are not in the loaded history, fetched for the quote in the bubble.
    var replyPreviews: [Int64: Message] = [:] {
        didSet { scheduleTranscriptRebuild() }
    }
    /// A message the transcript should scroll to (a clicked reply quote), and briefly highlight.
    var scrollTarget: Int64?
    /// The next `scrollTarget` is where a chat opens, not a trip across it: the view is put there at once.
    @ObservationIgnored var scrollsWithoutAnimation = false
    /// Set while a chat with unread messages opens: what had been read before, until the divider is placed.
    @ObservationIgnored var unreadOpenFrom: Int64?
    var highlightedMessageId: Int64?
    /// The first message that was unread when the chat opened: "Новые сообщения" goes above it.
    var unreadMarkerId: Int64?

    @ObservationIgnored var bridge: TDBridge?
    @ObservationIgnored private var closeIntent: CloseIntent?
    @ObservationIgnored private var authState = ""
    @ObservationIgnored private var codeTarget = CodeTarget.phone
    @ObservationIgnored var isReady = false
    @ObservationIgnored var myUserId: Int64 = 0

    /// Every chat TDLib told us about; `chats` is the main list (or the archive) cut from it.
    @ObservationIgnored var knownChats: [Int64: Chat] = [:]
    /// Chats that are in some list (main, archive or a folder). Most known chats are not; the list is rebuilt
    /// from these only, since copying thousands of chats per rebuild was most of its cost.
    @ObservationIgnored var listedChatIds: Set<Int64> = []
    /// Chats changed since the list was last brought up to date, and whether something changed for all of them.
    @ObservationIgnored private var changedChatIds: Set<Int64> = []
    @ObservationIgnored private var chatListNeedsFullRebuild = false
    @ObservationIgnored private var chatListRebuildPending = false
    @ObservationIgnored private var transcriptRebuildPending = false
    @ObservationIgnored var loadingChatLists: Set<String> = []

    @ObservationIgnored private let notifier = Notifier.shared
    /// Raw `chatNotificationSettings` per chat: changing one field means sending the whole object back.
    @ObservationIgnored var chatNotificationSettings: [Int64: TDNode] = [:] {
        didSet { mutedCache = [:] }
    }
    @ObservationIgnored private var mutedCache: [Int64: Bool] = [:]
    /// `scopeNotificationSettings` keyed by the scope type.
    @ObservationIgnored private var scopeNotificationSettings: [String: TDNode] = [:] {
        didSet { mutedCache = [:] }
    }

    /// The chat whose history is in `messages` and which is opened in TDLib.
    @ObservationIgnored var openChatId: Int64?
    @ObservationIgnored var historyGeneration = 0
    @ObservationIgnored var readPending = false
    @ObservationIgnored private var resolvingSenders: Set<String> = []

    /// Draft text TDLib has for the open chat; the composer differing from it means unsaved typing.
    @ObservationIgnored var draftBaseline = ""
    /// Identifies the newest draft save, so a late refusal cannot undo a draft typed after it.
    @ObservationIgnored var draftSaveRound = 0
    /// The chat draft set aside while the composer edits a message.
    @ObservationIgnored var stashedDraft = ""
    /// What the composer was given to edit, markup included: saving exactly that changes nothing.
    @ObservationIgnored var editBaseline: String?
    /// Custom emoji of the message being edited, placed in `editText`: markup cannot spell them, so they are
    /// carried over to the saved text by position.
    @ObservationIgnored var editText = ""
    @ObservationIgnored var editEntities: [TDNode] = []
    @ObservationIgnored var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored var lastTypingAt: Date?

    /// Users' last seen and bot flags arrive with the users, before or after their private chats.
    @ObservationIgnored private var userPresence: [Int64: UserPresence] = [:]
    @ObservationIgnored private var bots: Set<Int64> = []
    /// Member counts come with supergroup and basic group objects, keyed like `Chat.groupKey`.
    @ObservationIgnored var groupMemberCounts: [String: Int] = [:]
    @ObservationIgnored var chatIdByGroupKey: [String: Int64] = [:]
    /// Who is doing what in each chat: chat id → sender key → verb.
    @ObservationIgnored private var activities: [Int64: [String: (single: String, plural: String)]] = [:]

    /// Files downloaded in this session and downloads in flight, so many views asking share one request.
    @ObservationIgnored var localPaths: [Int: String] = [:]
    /// Boxed so the task that started a download can recognise its own entry again afterwards.
    final class Download {
        let task: Task<String?, Never>
        init(_ task: Task<String?, Never>) { self.task = task }
    }
    @ObservationIgnored var downloads: [Int: Download] = [:]

    /// Deleted messages and edit history kept locally (AyuGram features).
    @ObservationIgnored let archive = MessageArchive()
    /// Recent messages of every chat, so a deletion or edit in a chat that is not open still has the old text.
    @ObservationIgnored private var recentMessages: [Int64: [Int64: Message]] = [:]
    /// "chat:message" deleted from this app: those are not kept as "deleted by someone else".
    @ObservationIgnored var ownDeletions: Set<String> = []
    @ObservationIgnored var loadingReplies: Set<Int64> = []
    @ObservationIgnored var messageSearchTask: Task<Void, Never>?
    /// A search result to show once its chat has opened. The chat travels with the message, or switching chats
    /// in between would make the new chat jump to an id that is not its own.
    @ObservationIgnored var pendingJump: (chatId: Int64, messageId: Int64)?
    /// Position of each loaded message in `messages`.
    var messageIndex: [Int64: Int] { transcriptBuilder.index }
    /// The row that shows each message: an album's photos all live in the row of its last one.
    var rowIdByMessage: [Int64: Int64] { transcriptBuilder.rowIds }

    @ObservationIgnored private var unreadUnmutedCount = 0
    @ObservationIgnored private var reportedOnline: Bool?
    @ObservationIgnored private var appliedLogLevel: Int?

    init(slot: String = ConfigStore.currentAccount) {
        self.slot = slot
        Preferences.register()
        applyLogSettings()
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationBecameActive() }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOnlineStatus() }
        }
        // A display that went to sleep is a desk that was walked away from.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
    }

    /// Falls back to chats outside the shown list, so archiving the open chat or opening one from a
    /// notification keeps the conversation on screen.
    /// Kept as its own observed value: `knownChats` is not observed, so a chat outside the shown list
    /// (archived, found by search, not in the open folder) would otherwise never refresh its header.
    private(set) var selectedChat: Chat?

    private func refreshSelectedChat() {
        let current: Chat?
        if let selection, var shown = knownChats[selection] {
            // Fresh fields from the source; only the place in the shown list comes from the list. The scan goes
            // by index on purpose: a closure over the elements would copy every 328-byte chat it passes over,
            // and this runs for each update of the open chat.
            if let place = chats.indices.first(where: { chats[$0].id == selection }) {
                shown.order = chats[place].order
                shown.isPinned = chats[place].isPinned
            }
            shown.isMuted = isMuted(shown)
            current = shown
        } else {
            current = nil
        }
        if current != selectedChat { selectedChat = current }
    }

    /// Searching looks through the main list and the archive at once.
    var visibleChats: [Chat] {
        guard !filter.isEmpty else { return chats }
        let needle = filter.lowercased()
        // Search covers every chat you have, whatever folder or list is on screen: that list first.
        // The needle goes first: this runs on every keystroke, and sorting 700 chats to throw most of them
        // away cost about 2 ms of the main thread.
        let matched = listableChats.filter {
            $0.title.lowercased().contains(needle) || $0.snippet.lowercased().contains(needle)
        }
        let main = matched.compactMap { listed($0, inArchive: false) }.sorted(by: TD.precedes)
        let archived = matched.filter(\.isArchived).compactMap { listed($0, inArchive: true) }.sorted(by: TD.precedes)
        let everything: [Chat]
        if showsArchive {
            let inArchive = Set(archived.map(\.id))
            everything = archived + main.filter { !inArchive.contains($0.id) }
        } else {
            let inMain = Set(main.map(\.id))
            everything = main + archived.filter { !inMain.contains($0.id) }
        }
        return everything
    }

    /// Day sections of `messages`, kept up to date piece by piece rather than rebuilt on every redraw.
    var transcript: [TranscriptDay] { transcriptBuilder.days }

    /// Kept between changes of `messages`, see `TranscriptBuilder`. Observed: the transcript views read is
    /// its `days`, changed in place.
    private var transcriptBuilder = TranscriptBuilder()
    /// Set right before a change of `messages` that the builder can apply without starting over.
    @ObservationIgnored private var nextTranscriptChange: TranscriptChange = .rebuild

    private enum TranscriptChange {
        case rebuild
        /// Messages were added after this position, which is where the history ended before they came.
        case appended(from: Int)
        /// The message at this position was replaced; the copy that was there goes with the hint.
        case replaced(Int, Message)
    }

    /// The observer of `messages` deliberately takes no `oldValue`: asking for it copies the whole history on
    /// every single change — 0.2 ms per view count in a 4000-message chat, and half a second over a start-up
    /// load. Each mutation states what it did instead, and anything it cannot state takes the rebuild path.
    private func applyTranscriptChange() {
        let change = nextTranscriptChange
        nextTranscriptChange = .rebuild
        switch change {
        case .appended(let start) where start <= messages.count:
            transcriptBuilder.append(messages, from: start, replyPreviews: replyPreviews)
        case .replaced(let position, let old) where messages.indices.contains(position) && messages[position].id == old.id:
            if !transcriptBuilder.replace(old, with: messages[position]) {
                rebuildTranscript()
            }
        default:
            rebuildTranscript()
        }
    }

    private func rebuildTranscript() {
        transcriptBuilder = TranscriptBuilder(messages, replyPreviews: replyPreviews)
    }

    /// Fetched quotes land one at a time, and each one used to rebuild the whole history: in a chat where many
    /// messages answer something, the same work ran once per quote. Like the chat list, the transcript waits
    /// for the end of the burst; a change of `messages` still rebuilds at once where it needs the rows right away.
    private func scheduleTranscriptRebuild() {
        guard !transcriptRebuildPending else { return }
        transcriptRebuildPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.transcriptRebuildPending = false
                self.rebuildTranscript()
            }
        }
    }

    /// One message changed (views, reactions, an edit, a pin): its row is patched instead of the whole history.
    func replaceMessage(at position: Int, with message: Message) {
        guard messages.indices.contains(position), messages[position] != message else { return }
        nextTranscriptChange = .replaced(position, messages[position])
        messages[position] = message
    }

    // State of the features that live in the AppModel+… files. Stored properties cannot sit in an
    // extension, so each is declared here and explained by the code that uses it.

    /// The people or commands offered above the composer for the word being typed.
    var suggestions: [ComposerSuggestion] = []
    @ObservationIgnored var suggestionTask: Task<Void, Never>?

    /// The photo open in the viewer over the conversation.
    var viewerMessage: Message?

    /// Spoilers you have already opened. The row is recycled as soon as it scrolls out of sight, and `@State`
    /// goes with it, so what stays revealed has to live here — cleared together with the chat itself.
    var revealedSpoilers: Set<Int64> = []

    /// The newest pinned message of the open chat, for the bar above the transcript.
    var pinnedMessage: Message?

    /// Translations by "chat:message" — message ids repeat across chats, so an id alone is not a key.
    var translations: [String: Translation] = [:]
    /// Messages whose translation the server has not answered yet; a second tap adds no request.
    var translatingIds: Set<String> = []

    /// What this account may do in the open chat; nothing until it has been read.
    var chatAccess = ChatAccess()
    /// Which chat `chatAccess` and the two lists beside it answer for.
    @ObservationIgnored var accessChatId: Int64 = 0
    var members: [ChatMemberInfo] = []
    /// What the server says the chat holds, which is more than one page of `members` when the list is long.
    var membersTotal = 0
    var isLoadingMembers = false
    var inviteLinks: [InviteLinkInfo] = []

    var statistics: ChannelStats?

    /// Topics of the open chat, once they have been read.
    var topics: [Topic] = []
    /// The open chat is a forum. TDLib does not say so in the chat object, so this is learned from its
    /// messages: only a forum's messages carry a topic id.
    var openChatIsForum = false
    /// nil shows the whole chat, which is how a forum reads until a topic is picked. Only `open(topic:)`
    /// changes it: a bare assignment would leave the transcript of the previous topic on screen.
    var openTopicId: Int32?
    /// The comments of a channel post, shown in its discussion group instead of the group's whole history.
    /// Only `openComments` and `closeComments` (through a chat switch) change it.
    var commentThread: CommentThread?
    /// A thread whose group is still opening: the chat switch clears what was open, so it waits here.
    @ObservationIgnored var pendingThread: CommentThread?

    // MARK: - sign-in

    func boot() {
        guard bridge == nil else { return }
        // With a passcode set nothing starts until it is typed: the database cannot be opened without the
        // key that comes out of it.
        if hasPasscode, lockKeys == nil {
            isLocked = true
            return
        }
        // Nothing else ever clears these; the walk is a few hundred stats, kept off the first draw.
        Task.detached(priority: .utility) { VoiceRecorder.purgeOldFiles() }
        guard let saved = ConfigStore.load(), saved.apiId > 0, !saved.apiHash.isEmpty else {
            phase = .credentials
            return
        }
        apiIdField = String(saved.apiId)
        apiHashField = saved.apiHash
        start(with: saved)
    }

    func submitCredentials() {
        guard let apiId = Int(apiIdField.filter(\.isNumber)), apiId > 0 else {
            fail(L("api_id — число, которое видно на my.telegram.org"))
            return
        }
        let apiHash = apiHashField.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard apiHash.count == 32, apiHash.allSatisfy(\.isHexDigit) else {
            fail(L("api_hash состоит из 32 hex-символов"))
            return
        }

        let credentials = Credentials(apiId: apiId, apiHash: apiHash)
        do {
            try ConfigStore.save(credentials)
        } catch {
            fail(error)
            return
        }
        errorText = ""
        if bridge == nil {
            start(with: credentials)
        } else if authState == "authorizationStateWaitTdlibParameters" {
            // TDLib rejected the previous parameters (e.g. another copy holds the database); try again.
            Task { await configure(credentials) }
        } else if phase == .credentials {
            // The keys were asked for again in the middle of a sign-in: the session starts over with the new ones.
            restartSession()
        }
    }

    func submitPhone() {
        let number = phoneField.filter { $0.isNumber || $0 == "+" }
        guard number.count >= 8 else {
            fail(L("Номер нужен в международном формате, например +79991234567"))
            return
        }
        authenticate([
            "@type": "setAuthenticationPhoneNumber",
            "phone_number": number,
            "settings": [
                "@type": "phoneNumberAuthenticationSettings",
                "allow_flash_call": false,
                "allow_missed_call": false,
                "is_current_phone_number": false,
                "allow_sms_retriever_api": false,
                "authentication_tokens": [Any](),
            ],
        ])
    }

    func submitEmail() {
        let address = emailField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), address.contains(".") else {
            fail(L("Нужен адрес почты, например name@example.com"))
            return
        }
        authenticate(["@type": "setAuthenticationEmailAddress", "email_address": address])
    }

    func submitCode() {
        let code = codeField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        switch codeTarget {
        case .phone:
            authenticate(["@type": "checkAuthenticationCode", "code": code])
        case .email:
            authenticate([
                "@type": "checkAuthenticationEmailCode",
                "code": ["@type": "emailAddressAuthenticationCode", "code": code],
            ])
        }
    }

    func resendCode() {
        guard canResendCode else { return }
        authenticate([
            "@type": "resendAuthenticationCode",
            "reason": ["@type": "resendCodeReasonUserRequest"],
        ])
    }

    /// Login without a code: Telegram on a phone scans the QR code (Settings → Devices → Link Desktop Device).
    func startQrLogin() {
        authenticate(["@type": "requestQrCodeAuthentication", "other_user_ids": [Any]()])
    }

    /// TDLib cannot leave the QR step on its own, so a fresh session goes back to the phone number.
    func cancelQrLogin() {
        restartSession()
    }

    func submitPassword() {
        authenticate(["@type": "checkAuthenticationPassword", "password": passwordField])
    }

    private func authenticate(_ payload: TDNode) {
        busy = true
        Task {
            do {
                _ = try await request(payload)
            } catch let error as TDError where error.message.contains("API_ID_INVALID") {
                // Telegram checks the keys only when a code is asked for, so an account already signed in
                // keeps working on keys that a new sign-in is refused with. The form comes back for them.
                apiIdField = ""
                apiHashField = ""
                phase = .credentials
                fail(L("Telegram не принял сохранённые api_id и api_hash. Введите ключи своего приложения с my.telegram.org — уже подключённые аккаунты останутся в сети."))
            } catch {
                fail(error)
            }
            busy = false
        }
    }

    // MARK: - session

    func logOut() {
        guard bridge != nil, closeIntent == nil else { return }
        closeIntent = .logOut
        Task {
            do {
                _ = try await request(["@type": "logOut"])
            } catch let error as TDError where error.isSessionClosed {
                // The session finished closing before the reply arrived.
            } catch {
                closeIntent = nil
                fail(error)
            }
        }
    }

    func forgetCredentials() {
        ConfigStore.forget()
        apiIdField = ""
        apiHashField = ""
        errorText = ""
        phase = .credentials
        guard bridge != nil else { return }
        // Keys are part of the running session, so it is closed; the account stays signed in on disk.
        closeIntent = .forgetCredentials
        busy = true
        Task { _ = try? await request(["@type": "close"]) }
    }

    /// Replaces the TDLib session with a fresh one without quitting the app.
    func restartSession() {
        errorText = ""
        if bridge != nil {
            guard closeIntent == nil else { return }
            closeIntent = .restart
            Task { _ = try? await request(["@type": "close"]) }
            return
        }
        guard let saved = ConfigStore.load() else {
            phase = .credentials
            return
        }
        start(with: saved)
    }

    // MARK: - accounts

    /// This account has not signed in yet and there is another one to go back to.
    var canLeaveSignIn: Bool { hub?.canLeaveSignIn(self) ?? false }

    func leaveSignIn() { hub?.leaveSignIn(self) }

    private func start(with credentials: Credentials) {
        guard bridge == nil else { return }
        let bridge = TDBridge()
        self.bridge = bridge
        bridge.start { [weak self, weak bridge] update in
            guard let self, let bridge, self.bridge === bridge else { return }
            self.apply(update)
        }
        Task { await configure(credentials) }
    }

    private func configure(_ credentials: Credentials) async {
        busy = true
        defer { busy = false }

        do {
            // The key the record says the database has, then the other one. They differ only if the app died
            // between writing the record and TDLib confirming the new key, in either direction; trying both
            // is what keeps that moment from locking the account out of its own database.
            let record = AppLock.load()
            let passcodeKey = lockKeys?.database.base64EncodedString()
            var candidates = record?.encryptsDatabase == true ? [passcodeKey, ""] : ["", passcodeKey]
            if record == nil { candidates = [""] }
            let keys = candidates.compactMap { $0 }
            for (index, key) in keys.enumerated() {
                do {
                    _ = try await request([
                        "@type": "setTdlibParameters",
                        "use_test_dc": false,
                        "database_directory": ConfigStore.databaseDirectory(for: slot).path,
                        "files_directory": ConfigStore.filesDirectory(for: slot).path,
                        "database_encryption_key": key,
                        "use_file_database": true,
                        "use_chat_info_database": true,
                        "use_message_database": true,
                        "use_secret_chats": true,
                        "api_id": credentials.apiId,
                        "api_hash": credentials.apiHash,
                        "system_language_code": Loc.isEnglish ? "en" : "ru",
                        "device_model": "MacBook Pro (Apple M4)",
                        "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
                        "application_version": "11.0.0",
                    ])
                    // The record follows what actually opened the database.
                    if var record, record.encryptsDatabase != !key.isEmpty {
                        record.encryptsDatabase = !key.isEmpty
                        try? AppLock.save(record)
                    }
                    break
                } catch let error as TDError where error.message.contains("Wrong database encryption key") && index + 1 < keys.count {
                    continue
                }
            }
            // Before the sign-in screens: where Telegram is blocked, they cannot reach it without the proxy.
            applyProxy()
            applyAuthorization(try await request(["@type": "getAuthorizationState"]))
        } catch let error as TDError where error.isSessionClosed {
            // Closed while starting; `sessionClosed` has already decided what comes next.
        } catch {
            if case .failed = phase {
                phase = .failed(Self.describe(error))
            } else {
                fail(error)
            }
        }
    }

    private func onReady() async {
        notifier.activate(
            account: slot,
            onOpen: { [weak self] chatId in self?.openFromNotification(chatId) },
            onReply: { [weak self] chatId, messageId, text in
                Task { await self?.replyFromNotification(text, to: messageId, in: chatId) }
            },
            onRead: { [weak self] chatId in Task { await self?.markRead(chatId) } })
        // The chat list is what the window waits for: it starts first, the rest runs alongside it.
        Task { await loadChats() }
        Task { await loadStories() }
        async let meRequest = request(["@type": "getMe"])
        // Scope defaults decide which chats are muted; TDLib also pushes them as updates later.
        let scopes = [ChatKind.personal, .group, .channel].map { TD.notificationScope(of: $0) }
        async let first = try? request(["@type": "getScopeNotificationSettings", "scope": ["@type": scopes[0]]])
        async let second = try? request(["@type": "getScopeNotificationSettings", "scope": ["@type": scopes[1]]])
        async let third = try? request(["@type": "getScopeNotificationSettings", "scope": ["@type": scopes[2]]])
        do {
            let me = try await meRequest
            myUserId = me.tdInt64("id")
            accountName = TD.displayName(ofUser: me)
            ConfigStore.describe(account: slot, name: accountName, userId: myUserId)
            hub?.refresh()
            archive.open(accountId: myUserId, key: lockKeys?.archive)
        } catch {
            fail(error)
        }
        for (scope, settings) in zip(scopes, await [first, second, third]) {
            if let settings { scopeNotificationSettings[scope] = settings }
        }
        chatsChanged()
        updateOnlineStatus()
        reopenLastChat()
        Task {
            try? await Task.sleep(for: .seconds(6))
            animatesChatList = isReady
        }
        await applyEngineOptions()
        await loadTDLibVersion()
    }

    /// Less background work for TDLib: its own cache cleanup keeps downloaded files bounded, and statistics
    /// nobody here reads are not written to disk.
    private func applyEngineOptions() async {
        for name in ["use_storage_optimizer", "disable_top_chats", "disable_persistent_network_statistics"] {
            _ = try? await request(["@type": "setOption", "name": name, "value": ["@type": "optionValueBoolean", "value": true]])
        }
    }

    private func loadTDLibVersion() async {
        let version = (try? await request(["@type": "getOption", "name": "version"]))?.tdString("value") ?? ""
        let commit = (try? await request(["@type": "getOption", "name": "commit_hash"]))?.tdString("value") ?? ""
        tdlibVersion = commit.isEmpty ? version : "\(version) (\(commit.prefix(7)))"
    }

    private func openFromNotification(_ chatId: Int64) {
        guard knownChats[chatId] != nil else { return }
        // A banner of an account that is not in the window brings that account forward first.
        hub?.activate(slot)
        selection = chatId
    }

    /// The banner's "Ответить": the text goes to that chat whichever one is on screen. In a group it answers
    /// the message the banner showed, since by now others have written under it; a private chat needs no quote.
    func replyFromNotification(_ text: String, to messageId: Int64, in chatId: Int64) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let chat = knownChats[chatId] else { return }
        var payload: TDNode = [
            "@type": "sendMessage",
            "chat_id": chatId,
            "options": Self.sendOptions(),
            "input_message_content": TD.inputText(text, clearDraft: false, markup: true),
        ]
        if chat.kind == .group, messageId != 0 { payload["reply_to"] = TD.replyTo(messageId) }
        guard await perform(payload) else { return }
        // Answering says you have seen it; ghost mode keeps its own rule about that.
        if Preferences.isOn(Preferences.ghostMode) {
            await readAfterReplying(in: chatId)
        } else {
            await markRead(chatId)
        }
    }

    /// Quitting: the draft being typed is saved, the account goes offline right away instead of after the
    /// server's timeout, and TDLib gets up to two seconds to close its databases cleanly.
    func prepareForQuit() async {
        guard bridge != nil, closeIntent == nil else { return }
        if let chatId = openChatId, chatDraftText != draftBaseline {
            _ = try? await request(draftRequest(for: chatId, text: chatDraftText))
        }
        archive.close()
        if reportedOnline == true {
            _ = try? await request(["@type": "setOption", "name": "online", "value": ["@type": "optionValueBoolean", "value": false]])
        }
        closeIntent = .quit
        _ = try? await request(["@type": "close"])
        var waited = 0
        while bridge != nil, waited < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    /// `authorizationStateClosed`: the bridge is finished, whatever asked for the close decides what follows.
    private func sessionClosed() {
        let intent = closeIntent
        closeIntent = nil
        bridge = nil
        // The app is quitting: delivered notifications and the rest of the state may stay as they are.
        if intent == .quit { return }
        resetSession()
        busy = false

        switch intent {
        case .forgetCredentials:
            phase = .credentials
            // New keys may have been entered while the old session was still closing.
            if let saved = ConfigStore.load() { start(with: saved) }
        case .quit:
            break
        case .logOut, .restart:
            guard let saved = ConfigStore.load() else {
                phase = .credentials
                return
            }
            // Signed out of one account of several: its slot goes, and the window moves to one that remains.
            if intent == .logOut, hub?.signedOut(self) == true { return }
            if intent == .logOut { phase = .phone }
            start(with: saved)
        case nil:
            phase = .failed(L("TDLib закрыл сессию. Перезапустите Easy."))
        }
    }

    private func resetSession() {
        // Cleared first so that resetting `selection` does not try to save a draft into the dead session.
        openChatId = nil
        selection = nil
        clearConversation()
        knownChats = [:]
        listedChatIds = []
        chats = []
        showsArchive = false
        chatNotificationSettings = [:]
        scopeNotificationSettings = [:]
        notifier.reset(account: slot)
        senderNames = [:]
        senderPhotos = [:]
        nameBadges = [:]
        templateEmoji = []
        resolvingSenders = []
        userPresence = [:]
        bots = []
        groupMemberCounts = [:]
        chatIdByGroupKey = [:]
        animatesChatList = false
        secretStates = [:]
        chatIdBySecretId = [:]
        secretChatsOfUser = [:]
        activities = [:]
        downloads.values.forEach { $0.task.cancel() }
        downloads = [:]
        localPaths = [:]
        customEmoji = [:]
        // Kept per file id or per chat: any of them carries the old account's data into the new session.
        trackedFiles = []
        transfers = [:]
        pendingDrafts = [:]
        startParameters = [:]
        // An export running across a restart would keep paging chats of the new session into the old folder.
        exportTask?.cancel()
        exportTask = nil
        // Folder ids belong to an account; the sidebar filters by them until `updateChatFolders` corrects it.
        chatFolders = []
        selectedFolder = nil
        inspectedCode = nil
        archive.close()
        recentMessages = [:]
        prefetchedChats = []
        ownDeletions = []
        loadingReplies = []
        messageSearchTask?.cancel()
        foundMessages = []
        pendingJump = nil
        VoicePlayer.shared.stop()
        unreadUnmutedCount = 0
        reportedOnline = nil
        tdlibVersion = ""
        accountName = ""
        ownedStars = nil
        storyChats = []
        storyViewer = nil
        storyDraft = nil
        mediaGallery = nil
        myUserId = 0
        forwardingBatch = nil
        loadingChatLists = []
        readPending = false
        codeField = ""
        passwordField = ""
        canResendCode = false
        authState = ""
        isReady = false
    }

    // MARK: - requests

    /// Fire-and-report: the result arrives through updates, only a failure is shown.
    @discardableResult
    func perform(_ payload: TDNode) async -> Bool {
        do {
            _ = try await request(payload)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func request(_ payload: TDNode) async throws -> TDNode {
        guard let bridge else { throw TDError.closed }
        var attempts = 0
        while true {
            do {
                return try await bridge.request(payload)
            } catch let error as TDError {
                guard error.isRateLimited, attempts < 2, let delay = error.retryAfter, delay <= 5 else { throw error }
                attempts += 1
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    // MARK: - updates

    private func apply(_ update: TDNode) {
        switch update.tdType {
        case "updateAuthorizationState":
            applyAuthorization(update.tdNode("authorization_state") ?? [:])

        case "updateUser":
            guard let user = update.tdNode("user") else { return }
            let userId = user.tdInt64("id")
            let name = TD.displayName(ofUser: user)
            remember(name, for: "u\(userId)")
            remember(TD.photo(user.tdNode("profile_photo")), for: "u\(userId)")
            if userId == myUserId, !name.isEmpty, accountName != name { accountName = name }
            remember(TD.nameBadge(status: user.tdNode("emoji_status"), isPremium: user.tdBool("is_premium")), for: "u\(userId)")
            let presence = TD.presence(user.tdNode("status"))
            let isBot = user.tdNode("type")?.tdType == "userTypeBot"
            userPresence[userId] = presence
            if isBot { bots.insert(userId) } else { bots.remove(userId) }
            // A private chat has the same id as its user; their secret chats do not.
            for chatId in [userId] + Array(secretChatsOfUser[userId] ?? []) {
                updateChat(chatId) {
                    $0.presence = presence
                    $0.isBot = isBot
                }
            }

        case "updateUserStatus":
            let userId = update.tdInt64("user_id")
            let presence = TD.presence(update.tdNode("status"))
            userPresence[userId] = presence
            for chatId in [userId] + Array(secretChatsOfUser[userId] ?? []) {
                updateChat(chatId) { $0.presence = presence }
            }

        case "updateUnconfirmedSession":
            // Telegram's own "someone just signed in to your account". Nothing in the app showed it: the
            // session sat in the settings list, marked orange, until someone went looking.
            guard let session = update.tdNode("session") else {
                unconfirmedLogin = nil
                return
            }
            let device = session.tdString("device_model")
            let place = session.tdString("location")
            let summary = [device, place].filter { !$0.isEmpty }.joined(separator: " · ")
            let isNew = unconfirmedLogin != summary
            unconfirmedLogin = summary
            if isNew {
                notifier.postAlert(id: "login:\(session.tdInt("date"))", title: L("Новый вход в аккаунт"),
                                   body: summary.isEmpty ? L("Откройте Easy, чтобы проверить") : summary)
            }
            presentLoginAlert()

        case "updateChatEmojiStatus":
            remember(TD.nameBadge(status: update.tdNode("emoji_status"), isPremium: false), for: "c\(update.tdInt64("chat_id"))")

        case "updateSecretChat":
            guard let secret = update.tdNode("secret_chat"), let state = SecretChatState(secret.tdNode("state")) else { return }
            let id = secret.tdInt("id")
            secretStates[id] = state
            if let chatId = chatIdBySecretId[id] { updateChat(chatId) { $0.secretState = state } }

        case "updateNewChat":
            guard let node = update.tdNode("chat") else { return }
            var chat = TD.chat(node)
            if let last = node.tdNode("last_message").map(TD.message) {
                chat.snippetSender = snippetSender(of: last, in: chat)
            }
            if chat.userId != 0 {
                chat.presence = userPresence[chat.userId]
                chat.isBot = bots.contains(chat.userId)
            }
            if chat.secretChatId != 0 {
                chatIdBySecretId[chat.secretChatId] = chat.id
                chat.secretState = secretStates[chat.secretChatId]
                secretChatsOfUser[chat.userId, default: []].insert(chat.id)
            }
            if !chat.groupKey.isEmpty {
                chatIdByGroupKey[chat.groupKey] = chat.id
                chat.memberCount = groupMemberCounts[chat.groupKey] ?? 0
            }
            knownChats[chat.id] = chat
            noteListMembership(of: chat)
            chatNotificationSettings[chat.id] = node.tdNode("notification_settings")
            remember(chat.title, for: "c\(chat.id)")
            remember(chat.photo, for: "c\(chat.id)")
            if chat.userId == 0 {
                remember(TD.nameBadge(status: node.tdNode("emoji_status"), isPremium: false), for: "c\(chat.id)")
            }
            chatsChanged(chat.id)

        case "updateChatPhoto":
            let chatId = update.tdInt64("chat_id")
            let photo = TD.photo(update.tdNode("photo"))
            updateChat(chatId) { $0.photo = photo }
            remember(photo, for: "c\(chatId)")

        case "updateChatAction":
            // Topics are not shown separately, so every topic counts for the whole chat.
            let chatId = update.tdInt64("chat_id")
            let sender = TD.senderKey(update.tdNode("sender_id"))
            if let verb = TD.activityVerb(update.tdNode("action")) {
                activities[chatId, default: [:]][sender] = verb
            } else {
                activities[chatId]?[sender] = nil
            }
            let text = activityText(in: chatId)
            updateChat(chatId) { $0.activity = text }

        case "updateSupergroup":
            guard let group = update.tdNode("supergroup") else { return }
            noteMemberCount(group.tdInt("member_count"), for: "s\(group.tdInt64("id"))")

        case "updateBasicGroup":
            guard let group = update.tdNode("basic_group") else { return }
            noteMemberCount(group.tdInt("member_count"), for: "b\(group.tdInt64("id"))")

        case "updateChatOnlineMemberCount":
            let count = update.tdInt("online_member_count")
            updateChat(update.tdInt64("chat_id")) { $0.onlineMemberCount = count }

        case "updateChatNotificationSettings":
            chatNotificationSettings[update.tdInt64("chat_id")] = update.tdNode("notification_settings")
            chatsChanged(update.tdInt64("chat_id"))

        case "updateScopeNotificationSettings":
            guard let scope = update.tdNode("scope")?.tdType else { return }
            scopeNotificationSettings[scope] = update.tdNode("notification_settings")
            chatsChanged()

        case "updateUnreadMessageCount":
            // Like the official clients, the Dock counts unread messages of unmuted chats in the main list.
            guard update.tdNode("chat_list")?.tdType == "chatListMain" else { return }
            unreadUnmutedCount = update.tdInt("unread_unmuted_count")
            applyBadge()

        case "updateChatTitle":
            let chatId = update.tdInt64("chat_id")
            let title = update.tdString("title")
            updateChat(chatId) { $0.title = title }
            remember(title, for: "c\(chatId)")

        case "updateChatPosition":
            guard let position = update.tdNode("position") else { return }
            updateChat(update.tdInt64("chat_id")) { TD.applyPosition(position, to: &$0) }

        case "updateChatLastMessage":
            let last = update.tdNode("last_message").map(TD.message)
            let positions = update.tdNodes("positions")
            updateChat(update.tdInt64("chat_id")) { chat in
                if let last {
                    chat.snippet = TD.snippet(of: last)
                    chat.snippetSender = snippetSender(of: last, in: chat)
                    chat.snippetDate = last.date
                    if last.isSent { chat.lastMessageId = last.id }
                } else {
                    // No last message: the history was cleared, or its only message deleted. The row used to
                    // keep quoting a message that no longer exists, and the chat kept an id to "read".
                    chat.snippet = ""
                    chat.snippetSender = ""
                    chat.snippetDate = nil
                    chat.lastMessageId = 0
                }
                TD.applyPositions(positions, to: &chat)
            }

        case "updateChatDraftMessage":
            let chatId = update.tdInt64("chat_id")
            let text = TD.draftText(of: update.tdNode("draft_message"))
            let positions = update.tdNodes("positions")
            updateChat(chatId) { chat in
                chat.draftText = text
                TD.applyPositions(positions, to: &chat)
            }
            // The chat's own draft; a topic or a comment thread on screen has a draft of its own.
            if chatId == openChatId, openTopic == nil { adoptRemoteDraft(text) }

        case "updateChatReadInbox":
            let chatId = update.tdInt64("chat_id")
            let unread = update.tdInt("unread_count")
            let lastRead = update.tdInt64("last_read_inbox_message_id")
            updateChat(chatId) {
                $0.unread = unread
                $0.lastReadInboxId = lastRead
            }
            notifier.withdraw(account: slot, chatId: chatId, upTo: lastRead)

        case "updateChatActiveStories":
            noteActiveStories(update.tdNode("active_stories") ?? [:])

        case "updateOwnedStarCount":
            ownedStars = update.tdNode("star_amount")?.tdInt("star_count")

        case "updateChatReadOutbox":
            let marker = update.tdInt64("last_read_outbox_message_id")
            updateChat(update.tdInt64("chat_id")) { $0.lastReadOutboxId = marker }

        case "updateChatIsMarkedAsUnread":
            let marked = update.tdBool("is_marked_as_unread")
            updateChat(update.tdInt64("chat_id")) { $0.isMarkedUnread = marked }

        case "updateChatUnreadMentionCount":
            let count = update.tdInt("unread_mention_count")
            updateChat(update.tdInt64("chat_id")) { $0.unreadMentions = count }

        case "updateChatUnreadReactionCount":
            let count = update.tdInt("unread_reaction_count")
            updateChat(update.tdInt64("chat_id")) { $0.unreadReactions = count }

        case "updateNewMessage":
            guard let node = update.tdNode("message") else { return }
            let message = TD.message(node)
            // A scheduled message is not in the history yet and must not ring.
            if message.isScheduled {
                if message.chatId == openChatId, let chatId = openChatId { Task { await loadScheduledMessages(of: chatId) } }
                return
            }
            cache(message)
            notifyIfNeeded(message, mentionsMe: node.tdBool("contains_unread_mention"))
            // A forum is only ever seen through its messages: TDLib does not say it in the chat object.
            if message.topicId != 0, message.chatId == openChatId {
                openChatIsForum = true
                noteTopic(of: message)
            }
            // An older stretch of history on screen would get a gap; the message shows with the latest ones.
            guard belongsOnScreen(message), !isViewingHistory else { return }
            merge([message])
            if !message.isOutgoing { scheduleMarkRead() }

        case "updateMessageSendSucceeded", "updateMessageSendFailed":
            // The local copy is replaced by the server one (or a failed one) under a new id.
            guard let node = update.tdNode("message") else { return }
            var message = TD.message(node)
            cache(message)
            guard belongsOnScreen(message), !isViewingHistory else { return }
            let oldId = update.tdInt64("old_message_id")
            // The bubble on screen stays the bubble it was: see `Message.viewId`.
            if let index = messageIndex[oldId] { message.firstShownId = messages[index].viewId }
            merge([message], removing: [oldId])

        case "updateMessageContent":
            let chatId = update.tdInt64("chat_id")
            let messageId = update.tdInt64("message_id")
            let index = chatId == openChatId ? messageIndex[messageId] : nil
            guard var message = index.map({ messages[$0] }) ?? recentMessages[chatId]?[messageId] else { return }
            let previousText = MessageArchive.text(of: message)
            let content = update.tdNode("new_content") ?? [:]
            message.body = TD.body(of: content)
            message.attachment = TD.attachment(of: content)
            message.sticker = TD.sticker(of: content)
            message.media = TD.media(of: content)
            message.caption = content.tdText("caption")
            message.entities = TD.entities(of: content)
            message.linkPreview = TD.linkPreview(content.tdNode("link_preview"))
            // The cards are content too: a replaced file, a live location that moved, a dice that landed.
            // Left as they were, the bubble kept drawing the old card under the new text.
            message.document = TD.document(of: content)
            message.location = TD.location(of: content)
            message.contact = TD.contact(of: content)
            message.dice = TD.dice(of: content)
            message.poll = TD.poll(content.tdNode("poll"))
            // Polls, link previews and finished uploads change content too; only a new text is an edit.
            if Preferences.isOn(Preferences.saveEditHistory), archives(chatId), message.isSent, !message.isDeleted,
               MessageArchive.text(of: message) != previousText {
                archive.recordEdit(of: message, previousText: previousText)
                message.hasEditHistory = true
            }
            cache(message)
            if let index { replaceMessage(at: index, with: message) }

        case "updateMessageEdited":
            // Bots edit their buttons this way too ("Загрузка…" → "Готово").
            let messageId = update.tdInt64("message_id")
            guard update.tdInt64("chat_id") == openChatId, let index = messageIndex[messageId] else { return }
            var message = messages[index]
            message.isEdited = message.isEdited || update.tdInt("edit_date") > 0
            message.markup = TD.replyMarkup(update.tdNode("reply_markup"))
            replaceMessage(at: index, with: message)

        case "updateChatReplyMarkup":
            let chatId = update.tdInt64("chat_id")
            let messageId = update.tdInt64("reply_markup_message_id")
            updateChat(chatId) { $0.replyMarkupMessageId = messageId }
            guard chatId == openChatId else { return }
            if messageId != 0 {
                if let index = messageIndex[messageId] {
                    adoptReplyKeyboard(messages[index])
                } else {
                    Task {
                        guard let node = try? await request(["@type": "getMessage", "chat_id": chatId, "message_id": messageId]),
                              openChatId == chatId else { return }
                        adoptReplyKeyboard(TD.message(node))
                    }
                }
            } else {
                adoptReplyKeyboard(nil)
            }

        case "updateFile":
            guard let file = update.tdNode("file") else { return }
            let fileId = file.tdInt("id")
            guard trackedFiles.contains(fileId) else { return }
            let transfer = TD.transfer(file)
            if transfer.isDownloaded, !transfer.path.isEmpty { localPaths[fileId] = transfer.path }
            if transfers[fileId] != transfer { transfers[fileId] = transfer }

        case "updatePoll":
            guard let poll = TD.poll(update.tdNode("poll")) else { return }
            // Row by row: a vote in a busy poll arrives every second, and copying the whole history to compare
            // it with itself rebuilt the transcript each time.
            for index in messages.indices where messages[index].poll?.id == poll.id {
                var voted = messages[index]
                voted.poll = poll
                replaceMessage(at: index, with: voted)
            }

        case "updateChatFolders":
            chatFolders = update.tdNodes("chat_folders").map {
                ChatFolder(id: $0.tdInt("id"), title: $0.tdNode("name")?.tdText("text") ?? "",
                           icon: $0.tdNode("icon")?.tdString("name") ?? "",
                           // TDLib always sends the colour; a payload without it means "no colour", not blue.
                           colorId: $0["color_id"] == nil ? -1 : $0.tdInt("color_id"))
            }
            if let folder = selectedFolder, !chatFolders.contains(where: { $0.id == folder }) { selectedFolder = nil }

        case "updateMessageIsPinned":
            let messageId = update.tdInt64("message_id")
            if update.tdInt64("chat_id") == openChatId, let chatId = openChatId {
                Task { await loadPinnedMessage(of: chatId) }
            }
            guard update.tdInt64("chat_id") == openChatId,
                  let index = messageIndex[messageId],
                  messages[index].isPinned != update.tdBool("is_pinned") else { return }
            var pinned = messages[index]
            pinned.isPinned = update.tdBool("is_pinned")
            replaceMessage(at: index, with: pinned)

        case "updateMessageInteractionInfo":
            let messageId = update.tdInt64("message_id")
            guard update.tdInt64("chat_id") == openChatId, let index = messageIndex[messageId] else { return }
            var message = messages[index]
            TD.applyInteraction(update.tdNode("interaction_info"), to: &message)
            replaceMessage(at: index, with: message)

        case "updateDeleteMessages":
            // `from_cache` only means TDLib dropped them from memory; they still exist.
            guard !update.tdBool("from_cache") else { return }
            let chatId = update.tdInt64("chat_id")
            let removed = Set(update.tdInt64s("message_ids"))
            var kept: Set<Int64> = []
            for messageId in removed {
                let isOwn = ownDeletions.remove("\(chatId):\(messageId)") != nil || clearingChats[chatId] != nil
                // Someone else deleted it for good: the archive keeps it, marked as deleted.
                guard !isOwn, update.tdBool("is_permanent"), Preferences.isOn(Preferences.saveDeletedMessages),
                      archives(chatId),
                      let message = (chatId == openChatId ? messageIndex[messageId].map { messages[$0] } : nil)
                        ?? recentMessages[chatId]?[messageId],
                      message.isSent, !message.isDeleted else { continue }
                if case .service = message.body { continue }
                archive.recordDeletion(of: message)
                kept.insert(messageId)
            }
            for messageId in removed { recentMessages[chatId]?[messageId] = nil }
            guard chatId == openChatId else { return }
            // One assignment, so the transcript is rebuilt once for the whole batch.
            let gone = removed.subtracting(kept)
            var updated = messages
            for index in updated.indices where kept.contains(updated[index].id) {
                updated[index].isDeleted = true
            }
            updated.removeAll { gone.contains($0.id) }
            if updated != messages { messages = updated }
            scheduledMessages.removeAll { removed.contains($0.id) }
            selectedMessageIds.subtract(gone)
            if let context = composerContext, removed.contains(context.messageId) { cancelComposerContext() }

        default:
            break
        }
    }

    private func applyAuthorization(_ state: TDNode) {
        authState = state.tdType
        switch state.tdType {
        case "authorizationStateWaitPhoneNumber":
            phase = .phone
        case "authorizationStateWaitEmailAddress":
            phase = .email
        case "authorizationStateWaitEmailCode":
            codeTarget = .email
            canResendCode = true
            let pattern = state.tdNode("code_info")?.tdString("email_address_pattern") ?? ""
            phase = .code(destination: L("Код отправлен на почту") + (pattern.isEmpty ? "" : " " + pattern))
        case "authorizationStateWaitCode":
            let info = state.tdNode("code_info") ?? [:]
            codeTarget = .phone
            canResendCode = info.tdNode("next_type") != nil
            phase = .code(destination: Self.describeCodeDelivery(info))
        case "authorizationStateWaitOtherDeviceConfirmation":
            phase = .qr(link: state.tdString("link"))
        case "authorizationStateWaitPassword":
            phase = .password(hint: state.tdString("password_hint"))
        case "authorizationStateWaitRegistration":
            fail(L("Аккаунт ещё не зарегистрирован. Создайте его в официальном клиенте Telegram."))
        case "authorizationStateWaitPremiumPurchase":
            fail(L("Для входа в этот аккаунт Telegram требует Premium. Войдите через официальный клиент."))
        case "authorizationStateReady":
            // Reported both by the update and by `getAuthorizationState`; start the session once.
            guard !isReady else { return }
            isReady = true
            phase = .working
            Task { await onReady() }
        case "authorizationStateClosed":
            sessionClosed()
        default:
            break
        }
    }

    // MARK: - local state

    func merge(_ incoming: [Message], removing removed: Set<Int64> = []) {
        // New messages after the last one (the usual case while chatting) are appended, not merged and re-sorted.
        if removed.isEmpty, let last = messages.last, !incoming.isEmpty,
           incoming.allSatisfy({ $0.id > last.id && !$0.isScheduled }) {
            var seen = Set<Int64>()
            let fresh = incoming.sorted { $0.id < $1.id }.filter { seen.insert($0.id).inserted }.map { message -> Message in
                cache(message)
                var decorated = message
                decorated.hasEditHistory = archive.hasHistory(chatId: message.chatId, messageId: message.id)
                decorated.localText = archive.localText(chatId: message.chatId, messageId: message.id)
                return decorated
            }
            nextTranscriptChange = .appended(from: messages.count)
            messages.append(contentsOf: fresh)
            resolveSenders(of: fresh)
            return
        }
        var byId: [Int64: Message] = [:]
        for message in messages where !removed.contains(message.id) { byId[message.id] = message }
        for var message in incoming where !message.isScheduled {
            cache(message)
            message.hasEditHistory = archive.hasHistory(chatId: message.chatId, messageId: message.id)
            message.localText = archive.localText(chatId: message.chatId, messageId: message.id)
            // A fresh copy from TDLib never replaces what the archive already marked as deleted.
            if byId[message.id]?.isDeleted == true { continue }
            // Nor does it make the view forget which bubble this is.
            if message.firstShownId == 0, let shown = byId[message.id]?.firstShownId { message.firstShownId = shown }
            byId[message.id] = message
        }
        // Messages someone deleted stay where they were, within the part of the history on screen.
        if let chatId = openChatId, Preferences.isOn(Preferences.saveDeletedMessages), let oldest = byId.keys.min() {
            let newest = isViewingHistory ? (byId.keys.max() ?? oldest) : .max
            for deleted in archive.deletedMessages(in: chatId)
            where deleted.id >= oldest && deleted.id <= newest && byId[deleted.id] == nil {
                byId[deleted.id] = deleted
            }
        }
        // TDLib message ids grow with time, so chronological display is ids ascending.
        // Pages that bring nothing new (the retries of the first load) do not rebuild the transcript.
        let merged = byId.values.sorted { $0.id < $1.id }
        guard merged != messages else { return }
        messages = merged
        resolveSenders(of: messages)
    }

    /// Remembers the latest messages of every chat, so the archive can keep the text of a message that is
    /// deleted or edited while its chat is closed.
    private func cache(_ message: Message) {
        guard message.isSent, !message.isDeleted else { return }
        // Changed where it lies: taking the chat's dictionary out and putting it back made a second owner of
        // it, so every message cached copied all 150 of its neighbours first.
        recentMessages[message.chatId, default: [:]][message.id] = message
        // Sixty per chat: enough to still have the text of a message deleted minutes after it came, without
        // hundreds of busy channels each holding a hundred and fifty for the whole session.
        if let count = recentMessages[message.chatId]?.count, count > 60,
           let oldest = recentMessages[message.chatId]?.keys.min() {
            recentMessages[message.chatId]?[oldest] = nil
        }
    }

    /// `updateUser` and `updateNewChat` name almost every sender before its messages arrive;
    /// this only covers the rest.
    func resolveSenders(of messages: [Message]) {
        // Looked up one by one: subtracting all known names built a set of every name on each new message.
        var unknown = Set<String>()
        for message in messages {
            for key in [message.senderKey, message.forwardSenderKey, message.foreignReply?.senderKey ?? ""]
            where !key.isEmpty && senderNames[key] == nil && !resolvingSenders.contains(key) {
                unknown.insert(key)
            }
        }
        for key in unknown {
            guard let id = Int64(key.dropFirst()) else { continue }
            resolvingSenders.insert(key)
            Task {
                defer { resolvingSenders.remove(key) }
                if key.hasPrefix("u"), let user = try? await request(["@type": "getUser", "user_id": id]) {
                    remember(TD.displayName(ofUser: user), for: key)
                } else if key.hasPrefix("c"), let chat = try? await request(["@type": "getChat", "chat_id": id]) {
                    remember(chat.tdString("title"), for: key)
                }
            }
        }
    }

    func remember(_ name: String, for key: String) {
        if senderNames[key] != name { senderNames[key] = name }
    }

    /// The view identity of the row that shows a message, for scrolling to it.
    func viewId(ofMessage id: Int64) -> Int64 {
        let row = transcriptBuilder.rowIds[id] ?? id
        return transcriptBuilder.index[row].map { messages[$0].viewId } ?? row
    }

    func remember(_ badge: NameBadge?, for key: String) {
        if nameBadges[key] != badge { nameBadges[key] = badge }
    }

    func remember(_ photo: ProfilePhoto?, for key: String) {
        if senderPhotos[key] != photo { senderPhotos[key] = photo }
    }

    /// "печатает…" in a private chat; with names in groups, as the official clients show it.
    private func activityText(in chatId: Int64) -> String {
        guard let current = activities[chatId], let first = current.first?.value, let chat = knownChats[chatId] else { return "" }
        if chat.kind == .personal || chat.kind == .secret { return first.single + "…" }
        let names = current.keys.sorted().map { key in
            // First names keep the line short: "Иван и Мария печатают…".
            (senderNames[key] ?? "").split(separator: " ").first.map(String.init) ?? L("Кто-то")
        }
        switch names.count {
        case 1: return "\(names[0]) \(first.single)…"
        case 2: return L("\(names[0]) и \(names[1]) \(first.plural)…")
        default: return "\(TD.count(names.count, L("человек"), L("человека"), L("человек"))) \(first.plural)…"
        }
    }

    // MARK: - settings

    /// TDLib shows the account as online only while the "online" option is set; like the official
    /// clients it follows the app being in front, unless the user hides it in the settings.
    func updateOnlineStatus() {
        guard isReady else { return }
        let online = NSApp?.isActive == true && Preferences.showsOnline
        guard online != reportedOnline else { return }
        reportedOnline = online
        Task {
            _ = try? await request([
                "@type": "setOption",
                "name": "online",
                "value": ["@type": "optionValueBoolean", "value": online],
            ])
        }
    }

    private func applyBadge() {
        if unreadBadge != unreadUnmutedCount { unreadBadge = unreadUnmutedCount }
        notifier.setBadge(Preferences.isOn(Preferences.dockBadge) ? unreadUnmutedCount : 0, account: slot)
    }

    /// `UserDefaults.didChangeNotification` also fires for unrelated writes, so TDLib is only told about
    /// a level that actually changed.
    private func applyLogSettings() {
        let level = Preferences.logLevel
        guard level != appliedLogLevel else { return }
        if appliedLogLevel == nil {
            try? FileManager.default.createDirectory(
                at: Preferences.logFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            TDBridge.execute([
                "@type": "setLogStream",
                "log_stream": [
                    "@type": "logStreamFile",
                    "path": Preferences.logFile.path,
                    "max_file_size": 20 * 1024 * 1024,
                    "redirect_stderr": false,
                ],
            ])
        }
        appliedLogLevel = level
        TDBridge.execute(["@type": "setLogVerbosityLevel", "new_verbosity_level": level])
    }

    /// Whether the archive may keep what is deleted or edited in this chat. A secret chat's promise is that a
    /// deleted message is gone from both sides, so its messages are kept only when that was asked for.
    func archives(_ chatId: Int64) -> Bool {
        knownChats[chatId]?.kind != .secret || Preferences.isOn(Preferences.archiveSecretChats)
    }

    private func preferencesChanged() {
        updateOnlineStatus()
        applyBadge()
        applyLogSettings()
    }

    /// TDLib sends `updateNewChat` before any other update about a chat, so unknown ids are ignored.
    func updateChat(_ chatId: Int64, _ change: (inout Chat) -> Void) {
        guard var chat = knownChats[chatId] else { return }
        change(&chat)
        guard chat != knownChats[chatId] else { return }
        knownChats[chatId] = chat
        noteListMembership(of: chat)
        // The open chat's header follows at once; the list waits for the end of the burst.
        if chatId == selection { refreshSelectedChat() }
        chatsChanged(chatId)
    }

    /// Updates come in bursts (hundreds while the list loads), so the visible list is rebuilt once per burst.
    /// With a chat id only that chat moved or changed; without one, anything may have.
    private func chatsChanged(_ chatId: Int64? = nil) {
        if let chatId { changedChatIds.insert(chatId) } else { chatListNeedsFullRebuild = true }
        guard !chatListRebuildPending else { return }
        chatListRebuildPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyChatListChanges() }
        }
    }

    /// A few changed chats are taken out and put back in place; a big burst or a change of settings rebuilds.
    private func applyChatListChanges() {
        let changed = changedChatIds
        changedChatIds = []
        if chatListNeedsFullRebuild || changed.count > 40 {
            rebuildChatList()
            return
        }
        chatListRebuildPending = false
        let folder = showsArchive ? nil : selectedFolder
        var list = chats
        // Where each changed chat sat and what its row said then; the pair is what decides whether the list
        // changed at all, so the array of hundreds does not have to be compared row by row.
        var before: [Int64: (index: Int, row: Chat)] = [:]
        for chatId in changed {
            guard let at = list.firstIndex(where: { $0.id == chatId }) else { continue }
            before[chatId] = (at, list[at])
            list.remove(at: at)
        }
        var differs = false
        for chatId in changed {
            guard let chat = knownChats[chatId], let shown = listed(chat, inArchive: showsArchive, folder: folder) else {
                // Out of the list: a change only if it was in it a moment ago.
                differs = differs || before[chatId] != nil
                continue
            }
            // The list is sorted by TD.precedes; binary search finds the place.
            var low = 0, high = list.count
            while low < high {
                let middle = (low + high) / 2
                if TD.precedes(list[middle], shown) { low = middle + 1 } else { high = middle }
            }
            list.insert(shown, at: low)
            guard let was = before[chatId] else { differs = true; continue }   // just appeared in this list
            if was.index != low || was.row != shown { differs = true }
        }
        // One changed chat: its own row and place say whether anything moved, which saves comparing
        // hundreds of rows. A burst is rebuilt by insertion order, so it is published as a whole — a
        // redundant change costs a redraw, a wrong "nothing changed" would leave the list out of order.
        if changed.count != 1 || differs { chats = list }
        refreshUnreadBadges()
        refreshSelectedChat()
    }

    private func rebuildChatList() {
        chatListRebuildPending = false
        chatListNeedsFullRebuild = false
        changedChatIds = []
        let folder = showsArchive ? nil : selectedFolder
        let list = listableChats.compactMap { listed($0, inArchive: showsArchive, folder: folder) }.sorted(by: TD.precedes)
        if list != chats { chats = list }
        refreshUnreadBadges()
        refreshSelectedChat()
    }

    /// The badges of the sidebar rail: unread of every place a tap can open. Walked by id like the list,
    /// because building an array of hundreds of chats to read one number out of each is the expensive half,
    /// and chats without news are skipped before their mute state is looked up at all.
    private func refreshUnreadBadges() {
        var main = UnreadTally(), archive = UnreadTally(), folders: [Int: UnreadTally] = [:]
        for id in listedChatIds {
            guard let chat = knownChats[id], chat.unread > 0 else { continue }
            let (unread, muted) = (chat.unread, isMuted(chat))
            if chat.order != 0 { main.add(unread, isMuted: muted) }
            if chat.isArchived { archive.add(unread, isMuted: muted) }
            for folder in chat.folderOrders.keys {
                var tally = folders[folder] ?? UnreadTally()
                tally.add(unread, isMuted: muted)
                folders[folder] = tally
            }
        }
        if folders != folderUnread { folderUnread = folders }
        if main != mainUnread { mainUnread = main }
        if archive != archiveUnread { archiveUnread = archive }
    }

    /// A chat as a row of the main list or the archive: that list's position, and the effective mute.
    private func listed(_ chat: Chat, inArchive: Bool, folder: Int? = nil) -> Chat? {
        // Most known chats are in no list at all; they are ruled out before anything is copied or computed.
        let order: Int64
        let isPinned: Bool
        if let folder {
            guard let folderOrder = chat.folderOrders[folder] else { return nil }
            order = folderOrder
            isPinned = chat.pinnedInFolders.contains(folder)
        } else if inArchive {
            guard chat.isArchived else { return nil }
            order = chat.archiveOrder
            isPinned = chat.isPinnedInArchive
        } else {
            guard chat.order != 0 else { return nil }
            order = chat.order
            isPinned = chat.isPinned
        }
        var shown = chat
        shown.order = order
        shown.isPinned = isPinned
        shown.isMuted = isMuted(chat)
        return shown
    }

    /// Whether a chat is muted, remembered until notification settings change: working it out reads
    /// TDLib's settings objects, and the list asks for every chat on each rebuild.
    private func noteListMembership(of chat: Chat) {
        if chat.order != 0 || chat.archiveOrder != 0 || !chat.folderOrders.isEmpty {
            listedChatIds.insert(chat.id)
        } else {
            listedChatIds.remove(chat.id)
        }
    }

    /// The chats that can appear in any list, without copying the rest.
    var listableChats: [Chat] {
        listedChatIds.compactMap { knownChats[$0] }
    }

    func isMuted(_ chat: Chat) -> Bool {
        if let known = mutedCache[chat.id] { return known }
        let muted = notificationPolicy(for: chat).isMuted
        mutedCache[chat.id] = muted
        return muted
    }

    // MARK: - notifications

    private struct NotificationPolicy {
        var isMuted: Bool
        var showsPreview: Bool
        var notifiesMentions: Bool
    }

    /// Each field of the chat's settings either is its own or defers to the scope default.
    private func notificationPolicy(for chat: Chat) -> NotificationPolicy {
        let own = chatNotificationSettings[chat.id] ?? [:]
        let scope = scopeNotificationSettings[TD.notificationScope(of: chat.kind)] ?? [:]
        func source(_ useDefaultKey: String) -> TDNode {
            own.isEmpty || own.tdBool(useDefaultKey) ? scope : own
        }
        let preview = source("use_default_show_preview")
        return NotificationPolicy(
            isMuted: source("use_default_mute_for").tdInt("mute_for") > 0,
            showsPreview: preview["show_preview"] == nil || preview.tdBool("show_preview"),
            notifiesMentions: !source("use_default_disable_mention_notifications").tdBool("disable_mention_notifications")
        )
    }

    private func notifyIfNeeded(_ message: Message, mentionsMe: Bool) {
        guard notifier.isActive, Preferences.isOn(Preferences.notificationsEnabled), !message.isOutgoing,
              let chat = knownChats[message.chatId] else { return }
        if case .service = message.body { return }
        // What the filter folds away in the chat does not get a banner either.
        if AdFilter.reason(for: message, in: chat.kind) != nil { return }
        // Already on screen.
        if message.chatId == openChatId, NSApp?.isActive == true, hub.map({ $0.active === self }) ?? true { return }
        // Catching up after being offline replays older messages as new ones; skip what is read or stale.
        guard message.id > chat.lastReadInboxId, Date().timeIntervalSince(message.date) < 5 * 60 else { return }
        let policy = notificationPolicy(for: chat)
        guard !policy.isMuted || (mentionsMe && policy.notifiesMentions) else { return }

        // A locked app does not read its messages out on a banner.
        let showsText = policy.showsPreview && Preferences.isOn(Preferences.notificationPreview) && !isLocked
        // With several accounts the banner says which of them the message came to.
        let recipient = (hub?.accounts.count ?? 1) > 1 && !accountName.isEmpty ? accountName : ""
        notifier.post(
            account: slot,
            chatId: chat.id,
            messageId: message.id,
            title: chat.title,
            subtitle: [chat.kind == .group ? name(for: message) : "", recipient].filter { !$0.isEmpty }.joined(separator: " → "),
            body: showsText ? TD.preview(of: message) : L("Новое сообщение"),
            playsSound: Preferences.isOn(Preferences.notificationSound)
        )
    }

    func fail(_ error: Error) {
        // A request whose view went away is not something to report.
        if error is CancellationError { return }
        if let error = error as? TDError, error.isSessionClosed { return }
        fail(Self.describe(error))
    }

    func fail(_ message: String) {
        errorText = message
        // While chatting an error is news for a moment; on the sign-in screens it stays until fixed.
        guard phase == .working else { return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            if errorText == message { errorText = "" }
        }
    }

    /// Where Telegram says it sent the sign-in code. For an account that is signed in elsewhere it is usually
    /// not the phone at all but a message in Telegram itself, and "sent to +7…" sends people waiting for an SMS.
    static func describeCodeDelivery(_ info: TDNode) -> String {
        let phone = info.tdString("phone_number")
        let number = phone.isEmpty ? L("ваш номер") : (phone.hasPrefix("+") ? phone : "+" + phone)
        switch info.tdNode("type")?.tdType ?? "" {
        case "authenticationCodeTypeTelegramMessage":
            return L("Код пришёл сообщением в Telegram на другом вашем устройстве — в чате «Telegram». SMS не будет.")
        case "authenticationCodeTypeSms", "authenticationCodeTypeSmsWord", "authenticationCodeTypeSmsPhrase":
            return L("Код отправлен по SMS на \(number)")
        case "authenticationCodeTypeCall":
            return L("На \(number) позвонят и продиктуют код")
        case "authenticationCodeTypeFlashCall", "authenticationCodeTypeMissedCall":
            return L("На \(number) поступит звонок: код — последние цифры номера, с которого звонят")
        case "authenticationCodeTypeFragment":
            return L("Код ждёт на fragment.com, в аккаунте этого номера")
        case "authenticationCodeTypeFirebaseAndroid", "authenticationCodeTypeFirebaseIos":
            return L("Telegram отправляет код на \(number) способом, доступным только официальным приложениям. Нажмите «Отправить другим способом» или войдите по QR-коду.")
        default:
            return L("Код отправлен на \(number)")
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? TDError)?.message ?? error.localizedDescription
    }
}
