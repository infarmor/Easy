import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Chats in Spotlight: ⌘Space, a few letters of a chat's name, Return, and Easy opens it.
///
/// Only names, kinds and the tiny blurred preview of the photo go in, never message text: the index is the
/// system's, kept outside Easy's container and its passcode. Secret chats stay out, and so does everything
/// while a passcode is set; setting one takes out what was there.
@MainActor
enum Spotlight {
    /// What each account last handed over, so an unchanged list is not indexed again.
    private static var signatures: [String: Int] = [:]
    private static var pending: [String: Task<Void, Never>] = [:]
    /// Spotlight is for finding a chat, not an archive of every channel ever joined.
    private static let limit = 1000

    static var isEnabled: Bool { Preferences.isOn(Preferences.spotlight) && !AppLock.isEnabled }

    /// Indexes an account's chats a few seconds from now; calls in between make one pass. The list is read
    /// when the pass runs, not when it is asked for.
    static func schedule(account: String, chats: @escaping @MainActor () -> [Chat]) {
        guard pending[account] == nil else { return }
        pending[account] = Task {
            try? await Task.sleep(for: .seconds(5))
            pending[account] = nil
            index(account: account, chats: chats())
        }
    }

    private static func index(account: String, chats: [Chat]) {
        guard isEnabled else {
            if signatures[account] != nil { forget(account: account) }
            return
        }
        let shown = chats.filter { $0.kind != .secret && !$0.title.isEmpty }.prefix(limit)
        var hasher = Hasher()
        for chat in shown {
            hasher.combine(chat.id)
            hasher.combine(chat.title)
            hasher.combine(chat.photo?.minithumbnail)
        }
        let signature = hasher.finalize()
        guard signatures[account] != signature else { return }
        signatures[account] = signature
        let items = shown.map { chat in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = chat.title
            attributes.displayName = chat.title
            attributes.contentDescription = "Easy · " + chat.kind.label
            attributes.thumbnailData = chat.photo?.minithumbnail
            return CSSearchableItem(uniqueIdentifier: identifier(account: account, chatId: chat.id),
                                    domainIdentifier: domain(account), attributeSet: attributes)
        }
        // Replaced as a whole: chats that left the list leave Spotlight with it.
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain(account)]) { _ in
            index.indexSearchableItems(items)
        }
    }

    /// An account signed out, or its chats should no longer be found.
    static func forget(account: String) {
        signatures[account] = nil
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain(account)])
    }

    /// Spotlight turned off, or a passcode set.
    static func forgetAll() {
        signatures = [:]
        CSSearchableIndex.default().deleteAllSearchableItems()
    }

    /// The account and chat a picked result stands for.
    static func target(of activity: NSUserActivity) -> (account: String, chatId: Int64)? {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let colon = id.lastIndex(of: ":"), let chatId = Int64(id[id.index(after: colon)...]) else { return nil }
        return (String(id[..<colon]), chatId)
    }

    /// "account:chat". The first account's id is empty, so its chats start with the colon.
    private static func identifier(account: String, chatId: Int64) -> String { "\(account):\(chatId)" }

    private static func domain(_ account: String) -> String { "chats." + (account.isEmpty ? "main" : account) }
}
