import AppKit
import UserNotifications

/// macOS banners for incoming messages and the Dock badge. Clicking a banner hands its chat to `onOpen`; its
/// two buttons answer the message or mark the chat read without bringing the app forward.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// One for the app: the notification center has a single delegate, and several accounts post through it.
    static let shared = Notifier()

    private struct Handlers {
        var onOpen: (Int64) -> Void
        var onReply: (_ chatId: Int64, _ messageId: Int64, _ text: String) -> Void
        var onRead: (Int64) -> Void
    }

    /// What a banner's click and buttons do, by the account that posted it.
    private var handlers: [String: Handlers] = [:]
    private var badges: [String: Int] = [:]
    private var asked = false

    private nonisolated static let category = "message"
    private nonisolated static let replyAction = "reply"
    private nonisolated static let readAction = "read"
    /// True only while the notification center actually takes banners — Settings reads it as "уведомления включены".
    private(set) var isActive = false

    /// Asks for permission once per install. Only an .app bundle may use the notification center:
    /// it traps in a bare executable such as `swift run`.
    func activate(account: String,
                  onOpen: @escaping (Int64) -> Void,
                  onReply: @escaping (_ chatId: Int64, _ messageId: Int64, _ text: String) -> Void,
                  onRead: @escaping (Int64) -> Void) {
        handlers[account] = Handlers(onOpen: onOpen, onReply: onReply, onRead: onRead)
        guard !asked, Bundle.main.bundleURL.pathExtension == "app" else { return }
        asked = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Neither button brings the window forward: answering from the banner is the point of them.
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNTextInputNotificationAction(identifier: Self.replyAction, title: L("Ответить"), options: [],
                                              textInputButtonTitle: L("Отправить"), textInputPlaceholder: L("Сообщение")),
                UNNotificationAction(identifier: Self.readAction, title: L("Прочитано"), options: []),
            ],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.isActive = granted }
        }
    }

    func post(account: String, chatId: Int64, messageId: Int64, title: String, subtitle: String, body: String, playsSound: Bool) {
        guard isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Easy" : title
        content.subtitle = subtitle
        content.body = body
        content.sound = playsSound ? .default : nil
        content.threadIdentifier = account + "/" + String(chatId)
        content.categoryIdentifier = Self.category
        content.userInfo = ["chat_id": NSNumber(value: chatId), "message_id": NSNumber(value: messageId), "account": account]
        let request = UNNotificationRequest(identifier: Self.identifier(account, chatId, messageId), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Something about the account itself, not a message: no reply field, and a click only brings the app up.
    func postAlert(id: String, title: String, body: String) {
        guard isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Banners of messages read here or on another device are taken back.
    func withdraw(account: String, chatId: Int64, upTo messageId: Int64) {
        guard isActive else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let stale = delivered.map(\.request.identifier).filter { identifier in
                guard let (owner, chat, message) = Self.parse(identifier) else { return false }
                return owner == account && chat == chatId && message <= messageId
            }
            if !stale.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    /// The Dock shows what is unread in all accounts together.
    func setBadge(_ count: Int, account: String) {
        badges[account] = count
        let total = badges.values.reduce(0, +)
        NSApp?.dockTile.badgeLabel = total > 0 ? String(total) : nil
    }

    /// The account went away: nothing it showed should stay on screen.
    func reset(account: String) {
        setBadge(0, account: account)
        guard isActive else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let own = delivered.map(\.request.identifier).filter { Self.parse($0)?.0 == account }
            if !own.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: own) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Plain values first: the response itself does not cross to the main actor.
        let info = response.notification.request.content.userInfo
        let chatId = (info["chat_id"] as? NSNumber)?.int64Value
        let messageId = (info["message_id"] as? NSNumber)?.int64Value ?? 0
        let account = info["account"] as? String ?? ""
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        await MainActor.run {
            guard let chatId else {
                // An alert about the account: the app comes forward and shows what it has to ask.
                if action != UNNotificationDismissActionIdentifier { NSApp.activate() }
                return
            }
            let handlers = self.handlers[account]
            switch action {
            case Self.replyAction:
                handlers?.onReply(chatId, messageId, text)
            case Self.readAction:
                handlers?.onRead(chatId)
            case UNNotificationDismissActionIdentifier:
                break
            default:
                NSApp.activate()
                handlers?.onOpen(chatId)
            }
        }
    }

    private nonisolated static func identifier(_ account: String, _ chatId: Int64, _ messageId: Int64) -> String {
        "\(account):\(chatId):\(messageId)"
    }

    /// The account, the chat and the message of a banner. The first account's id is empty.
    private nonisolated static func parse(_ identifier: String) -> (String, Int64, Int64)? {
        let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let chat = Int64(parts[1]), let message = Int64(parts[2]) else { return nil }
        return (String(parts[0]), chat, message)
    }
}
