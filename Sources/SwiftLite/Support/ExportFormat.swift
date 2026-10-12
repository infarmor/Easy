import Foundation

/// The files of an account export: JSON for tools, HTML for people. No session keys are ever written.
enum ExportFormat {
    struct ExportedMessage: Codable {
        var id: Int64
        var date: Date
        var sender: String
        var isOutgoing: Bool
        var text: String
        var replyToId: Int64?
        var forwardedFrom: String?
        var edited: Bool
    }

    static func json<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data("null".utf8)
    }

    /// "Иван Петров" → "Иван Петров", "a/b:c" → "a-b-c": safe as a folder name.
    static func fileName(_ title: String, id: Int64) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(60))
        return short.isEmpty ? String(id) : "\(short) (\(id))"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// One chat as a page that reads like the app: days, names, times, oldest first.
    static func html(title: String, messages: [ExportedMessage]) -> String {
        let day = DateFormatter()
        day.locale = Loc.locale
        day.dateFormat = "d MMMM yyyy"
        let time = DateFormatter()
        time.locale = Loc.locale
        time.dateFormat = "HH:mm"

        var body = ""
        var currentDay = ""
        for message in messages {
            let label = day.string(from: message.date)
            if label != currentDay {
                currentDay = label
                body += "<div class=\"day\">\(escape(label))</div>\n"
            }
            var meta = escape(message.sender) + " · " + time.string(from: message.date)
            if message.edited { meta += L(" · изменено") }
            var extra = ""
            if let from = message.forwardedFrom { extra += L("<div class=\"fwd\">Переслано от \(escape(from))</div>") }
            if let reply = message.replyToId { extra += L("<div class=\"reply\">В ответ на <a href=\"#m\(reply)\">сообщение</a></div>") }
            let text = escape(message.text).replacingOccurrences(of: "\n", with: "<br>")
            body += "<div class=\"msg\(message.isOutgoing ? " out" : "")\" id=\"m\(message.id)\"><div class=\"meta\">\(meta)</div>\(extra)<div class=\"text\">\(text)</div></div>\n"
        }
        return """
        <!doctype html>
        <html lang="ru"><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --bg: #f5f5f7; --in: #ffffff; --out: #dbe9ff; --muted: #6e6e73; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --in: #2c2c2e; --out: #1e3a5f; --muted: #98989d; } }
        body { margin: 0; padding: 24px 16px; background: var(--bg); font: 14px -apple-system, system-ui, sans-serif; }
        main { max-width: 720px; margin: 0 auto; }
        h1 { font-size: 20px; margin: 0 0 16px; }
        .day { text-align: center; color: var(--muted); font-size: 12px; margin: 18px 0 8px; }
        .msg { background: var(--in); border-radius: 14px; padding: 8px 12px; margin: 4px 0; max-width: 80%; width: fit-content; }
        .msg.out { background: var(--out); margin-left: auto; }
        .meta { color: var(--muted); font-size: 11px; margin-bottom: 2px; }
        .fwd, .reply { color: var(--muted); font-size: 12px; }
        .text { white-space: normal; overflow-wrap: anywhere; }
        </style></head>
        <body><main><h1>\(escape(title))</h1>
        \(body)</main></body></html>
        """
    }
}
