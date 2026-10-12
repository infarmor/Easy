import Foundation

/// Hides advertising posts in channels, and messages with words the user never wants to see. Nothing is
/// removed: a hidden message is one click from being shown, and it is still counted and still in the history.
enum AdFilter {
    /// Why a message is hidden; nil when it is shown as usual.
    enum Reason: Equatable {
        case advertisement
        case word(String)
    }

    static func reason(for message: Message, in kind: ChatKind) -> Reason? {
        guard !message.isOutgoing, !message.isDeleted else { return nil }
        if case .service = message.body { return nil }
        let text = searchable(message)
        guard !text.isEmpty else { return nil }
        if let word = userWords.first(where: { text.contains($0) }) { return .word(word) }
        guard kind == .channel, Preferences.isOn(Preferences.hideAds) else { return nil }
        return looksLikeAd(text) ? .advertisement : nil
    }

    /// Everything a marker can hide in: the text or caption, the addresses behind links, the link preview.
    private static func searchable(_ message: Message) -> String {
        var parts = [message.caption]
        switch message.body {
        case .text(let value): parts.append(value)
        case .attachment(let label), .service(let label), .unsupported(let label): parts.append(label)
        }
        for entity in message.entities {
            if case .link(let url) = entity.style { parts.append(url.absoluteString) }
        }
        if let preview = message.linkPreview { parts.append(preview.url.absoluteString) }
        return parts.joined(separator: "\n").lowercased()
    }

    /// The marks an advertising post carries. Russian law makes a paid post say so: the word "Реклама" with the
    /// advertiser's name or tax number, and an "erid" token in the text or in its links; elsewhere the habit is
    /// a hashtag. A channel's own mention of the word "реклама" is not enough to hide it.
    static func looksLikeAd(_ text: String) -> Bool {
        // The cheap test first: this runs for every channel post that is drawn.
        guard text.contains("erid") || text.contains("реклам") || text.contains("#ad") || text.contains("#promo")
                || text.contains("sponsor") || text.contains("#партн") else { return false }
        if erid.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
        if hashtags.contains(where: { text.contains($0) }) { return true }
        if text.contains("о рекламодателе") || text.contains("рекламодатель:") { return true }
        if text.contains("реклама."), text.contains("инн") || text.contains("ооо") || text.contains("ип ") { return true }
        return false
    }

    private static let erid = try! NSRegularExpression(pattern: #"(\berid\s*[:=]\s*[a-z0-9]{6,})|([?&]erid=)"#)
    private static let hashtags = ["#реклама", "#ad ", "#ad\n", "#ads", "#promo", "#sponsored", "#партнерский", "#партнёрский"]

    /// The user's own list from the settings, lowercased; read again only when the setting changes.
    private static var userWords: [String] {
        let raw = UserDefaults.standard.string(forKey: Preferences.filterWords) ?? ""
        if raw != cachedRaw {
            cachedRaw = raw
            cachedWords = raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { $0.count >= 2 }
        }
        return cachedWords
    }

    nonisolated(unsafe) private static var cachedRaw = ""
    nonisolated(unsafe) private static var cachedWords: [String] = []
}
