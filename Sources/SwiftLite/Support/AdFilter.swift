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
        guard kind == .channel, Preferences.isOn(Preferences.hideAds), !isExempt(message.chatId) else { return nil }
        if looksLikeAd(text) { return .advertisement }
        // What the user pointed at as an ad before: the same shop's link or the same @name again.
        return learned.contains(where: { text.contains($0) }) ? .advertisement : nil
    }

    // MARK: - one channel at a time

    static func isExempt(_ chatId: Int64) -> Bool {
        exempt.contains(chatId)
    }

    static func setExempt(_ isExempt: Bool, chatId: Int64) {
        var chats = exempt
        if isExempt { chats.insert(chatId) } else { chats.remove(chatId) }
        UserDefaults.standard.set(chats.map(String.init).sorted().joined(separator: ","), forKey: Preferences.adExemptChats)
    }

    private static var exempt: Set<Int64> {
        Set((UserDefaults.standard.string(forKey: Preferences.adExemptChats) ?? "").split(separator: ",").compactMap { Int64($0) })
    }

    /// Posts of a channel shown again and again are a sign its "ads" are wanted. True on the third one of a
    /// channel in this session, once: the moment to say that the filter can be turned off for it.
    static func noteReveal(in chatId: Int64) -> Bool {
        reveals[chatId, default: 0] += 1
        return reveals[chatId] == 3
    }

    nonisolated(unsafe) private static var reveals: [Int64: Int] = [:]

    // MARK: - learning

    /// What marks this post as somebody's advertisement beyond the legal marks: where its links lead and
    /// whom it mentions. Telegram's own hosts say nothing by themselves, so for them the name after the
    /// slash is taken. Returns how many new marks were learned.
    @discardableResult
    static func learn(from message: Message) -> Int {
        var found: Set<String> = []
        var links: [URL] = []
        for entity in message.entities {
            if case .link(let url) = entity.style { links.append(url) }
        }
        if let preview = message.linkPreview { links.append(preview.url) }
        let text = searchable(message)
        for match in plainLink.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range, in: text), let url = URL(string: String(text[range])) { links.append(url) }
        }
        for url in links {
            guard let host = url.host?.lowercased() else { continue }
            if ["t.me", "telegram.me", "telegram.dog"].contains(host) {
                if let name = url.pathComponents.dropFirst().first, name.count >= 4, !name.hasPrefix("+") {
                    found.insert("t.me/" + name.lowercased())
                }
            } else {
                found.insert(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            }
        }
        for match in mention.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range, in: text) { found.insert(String(text[range])) }
        }
        let known = Set(learned)
        let fresh = found.subtracting(known)
        guard !fresh.isEmpty else { return 0 }
        // A few hundred marks at most: the oldest give way, so a long-used list does not slow every row.
        let all = Array((learned + fresh.sorted()).suffix(300))
        UserDefaults.standard.set(all.joined(separator: "\n"), forKey: Preferences.adLearned)
        return fresh.count
    }

    static func forgetLearned() {
        UserDefaults.standard.removeObject(forKey: Preferences.adLearned)
    }

    static var learnedCount: Int { learned.count }

    private static var learned: [String] {
        let raw = UserDefaults.standard.string(forKey: Preferences.adLearned) ?? ""
        if raw != cachedLearnedRaw {
            cachedLearnedRaw = raw
            cachedLearned = raw.split(separator: "\n").map(String.init).filter { $0.count >= 4 }
        }
        return cachedLearned
    }

    nonisolated(unsafe) private static var cachedLearnedRaw = ""
    nonisolated(unsafe) private static var cachedLearned: [String] = []
    private static let mention = try! NSRegularExpression(pattern: #"@[a-z0-9_]{5,32}"#)
    private static let plainLink = try! NSRegularExpression(pattern: #"https?://[^\s<>"']+"#)

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
