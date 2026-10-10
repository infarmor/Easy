import AppKit
import UserNotifications

/// macOS banners for incoming messages and the Dock badge. Clicking a banner hands its chat to `onOpen`; its
/// two buttons answer the message or mark the chat read without bringing the app forward.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var onOpen: ((Int64) -> Void)?
    private var onReply: ((_ chatId: Int64, _ messageId: Int64, _ text: String) -> Void)?
    private var onRead: ((Int64) -> Void)?
    private var asked = false

    private nonisolated static let category = "message"
    private nonisolated static let replyAction = "reply"
    private nonisolated static let readAction = "read"
    /// True only while the notification center actually takes banners — Settings reads it as "уведомления включены".
    private(set) var isActive = false

    /// Asks for permission once per install. Only an .app bundle may use the notification center:
    /// it traps in a bare executable such as `swift run`.
    func activate(onOpen: @escaping (Int64) -> Void,
                  onReply: @escaping (_ chatId: Int64, _ messageId: Int64, _ text: String) -> Void,
                  onRead: @escaping (Int64) -> Void) {
        self.onOpen = onOpen
        self.onReply = onReply
        self.onRead = onRead
        guard !asked, Bundle.main.bundleURL.pathExtension == "app" else { return }
        asked = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Neither button brings the window forward: answering from the banner is the point of them.
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNTextInputNotificationAction(identifier: Self.replyAction, title: "Ответить", options: [],
                                              textInputButtonTitle: "Отправить", textInputPlaceholder: "Сообщение"),
                UNNotificationAction(identifier: Self.readAction, title: "Прочитано", options: []),
            ],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.isActive = granted }
        }
    }

    func post(chatId: Int64, messageId: Int64, title: String, subtitle: String, body: String, playsSound: Bool) {
        guard isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "iGram" : title
        content.subtitle = subtitle
        content.body = body
        content.sound = playsSound ? .default : nil
        content.threadIdentifier = String(chatId)
        content.categoryIdentifier = Self.category
        content.userInfo = ["chat_id": NSNumber(value: chatId), "message_id": NSNumber(value: messageId)]
        let request = UNNotificationRequest(identifier: Self.identifier(chatId, messageId), content: content, trigger: nil)
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
    func withdraw(chatId: Int64, upTo messageId: Int64) {
        guard isActive else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let stale = delivered.map(\.request.identifier).filter { identifier in
                guard let (chat, message) = Self.parse(identifier) else { return false }
                return chat == chatId && message <= messageId
            }
            if !stale.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    func setBadge(_ count: Int) {
        NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    /// The account went away: nothing it showed should stay on screen.
    func reset() {
        setBadge(0)
        guard isActive else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
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
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        await MainActor.run {
            guard let chatId else {
                // An alert about the account: the app comes forward and shows what it has to ask.
                if action != UNNotificationDismissActionIdentifier { NSApp.activate() }
                return
            }
            switch action {
            case Self.replyAction:
                onReply?(chatId, messageId, text)
            case Self.readAction:
                onRead?(chatId)
            case UNNotificationDismissActionIdentifier:
                break
            default:
                NSApp.activate()
                onOpen?(chatId)
            }
        }
    }

    private nonisolated static func identifier(_ chatId: Int64, _ messageId: Int64) -> String {
        "\(chatId):\(messageId)"
    }

    private nonisolated static func parse(_ identifier: String) -> (Int64, Int64)? {
        let parts = identifier.split(separator: ":")
        guard parts.count == 2, let chat = Int64(parts[0]), let message = Int64(parts[1]) else { return nil }
        return (chat, message)
    }
}
