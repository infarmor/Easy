import Foundation

/// Settings keys shared by the settings window (`@AppStorage`) and the model.
enum Preferences {
    static let messageFontSize = "messageFontSize"
    static let showAvatars = "showAvatars"
    static let animateStickers = "animateStickers"
    /// How much the glass behind the conversation is darkened, 0 (clear) ... 0.6.
    static let backgroundDim = "backgroundDim"
    /// A `ChatBackground` by its raw value.
    static let chatBackground = "chatBackground"

    static let notificationsEnabled = "notificationsEnabled"
    static let notificationSound = "notificationSound"
    static let notificationPreview = "notificationPreview"
    static let dockBadge = "dockBadge"

    static let showOnline = "showOnline"
    static let sendTyping = "sendTyping"
    static let markReadOnOpen = "markReadOnOpen"

    /// Target language of the "Перевести" menu entry.
    static let translateToLanguage = "translateToLanguage"

    /// AyuGram features.
    static let ghostMode = "ghostMode"
    static let ghostReadOnReply = "ghostReadOnReply"
    static let saveDeletedMessages = "saveDeletedMessages"
    static let saveEditHistory = "saveEditHistory"
    /// Show "изменено локально" under messages you changed on this Mac.
    static let markLocalEdits = "markLocalEdits"

    /// Security tools: checks before opening links and files, the "Безопасность" menu on messages.
    static let linkGuard = "linkGuard"
    static let fileGuard = "fileGuard"
    static let securityTools = "securityTools"

    /// Minutes without a key or a click before the passcode is asked for again; 0 never locks by itself.
    static let autoLockMinutes = "autoLockMinutes"
    /// Keep deleted messages and edit history of secret chats too. Off: what is meant to vanish, vanishes.
    static let archiveSecretChats = "archiveSecretChats"

    static let showMessageCode = "showMessageCode"
    static let showIdentifiers = "showIdentifiers"
    static let tdlibLogLevel = "tdlibLogLevel"

    static func register() {
        UserDefaults.standard.register(defaults: [
            messageFontSize: 14,
            chatBackground: "glass",
            showAvatars: true,
            animateStickers: true,
            backgroundDim: 0.26,
            notificationsEnabled: true,
            notificationSound: true,
            notificationPreview: true,
            dockBadge: true,
            showOnline: true,
            sendTyping: true,
            markReadOnOpen: true,
            translateToLanguage: "ru",
            ghostMode: false,
            ghostReadOnReply: true,
            saveDeletedMessages: true,
            saveEditHistory: true,
            markLocalEdits: false,
            linkGuard: true,
            fileGuard: true,
            securityTools: true,
            autoLockMinutes: 15,
            archiveSecretChats: false,
            showMessageCode: false,
            showIdentifiers: false,
            tdlibLogLevel: 1,
        ])
    }

    static func isOn(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    /// Ghost mode overrides the individual privacy switches: nothing tells others you are here.
    static var readsAutomatically: Bool { isOn(markReadOnOpen) && !isOn(ghostMode) }
    static var sendsTyping: Bool { isOn(sendTyping) && !isOn(ghostMode) }
    static var showsOnline: Bool { isOn(showOnline) && !isOn(ghostMode) }

    static var logLevel: Int { UserDefaults.standard.integer(forKey: tdlibLogLevel) }

    /// Language messages are translated to. The client's own interface is Russian, so that is the default.
    static var translationLanguage: String {
        UserDefaults.standard.string(forKey: translateToLanguage) ?? "ru"
    }

    /// TDLib's own log; a GUI app's stderr goes nowhere, so it is written here instead.
    static let logFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/SwiftLite/tdlib.log")
}
