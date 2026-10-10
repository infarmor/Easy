import AppKit

/// Questions a bot button or a mini app can raise. AppKit only, so the model can ask them itself.
@MainActor
enum BotDialogs {
    enum LoginChoice { case logIn(allowWriting: Bool), openOnly, cancel }

    /// Links on buttons do not show their address, so it is shown before the browser opens it.
    static func confirmOpening(_ url: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Открыть ссылку?"
        alert.informativeText = url
        // The same checks transcripts use: an address like https://bank.ru@evil.top reads as bank.ru.
        if let parsed = URL(string: url) {
            let warnings = SecurityTools.linkWarnings(parsed)
            if !warnings.isEmpty { alert.informativeText += "\n\n" + warnings.joined(separator: "\n") }
        }
        alert.addButton(withTitle: "Открыть")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// "Log in with Telegram" on a site: the bot gets your name and user name for that domain.
    static func confirmLogin(domain: String, bot: String, requestsWriting: Bool) -> LoginChoice {
        let alert = NSAlert()
        alert.messageText = "Войти на \(domain)?"
        alert.informativeText = "Сайт получит ваше имя и имя пользователя Telegram через бота \(bot)."
        if requestsWriting {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Разрешить \(bot) писать мне"
            // Left unticked: writing permission is given by a click, not by whoever opened the dialog.
        }
        alert.addButton(withTitle: "Войти")
        alert.addButton(withTitle: "Открыть без входа")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .logIn(allowWriting: alert.suppressionButton?.state == .on)
        case .alertSecondButtonReturn: return .openOnly
        default: return .cancel
        }
    }

    enum LoginVerdict { case mine, notMine, later }

    /// A device signed in to the account. Three answers on purpose: closing the box with Esc must neither
    /// vouch for a stranger's device nor throw out your own.
    static func judgeLogin(_ details: String) -> LoginVerdict {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "В аккаунт вошли с нового устройства"
        alert.informativeText = "\(details)\n\nЕсли это не вы, завершите сеанс: устройство потеряет доступ к аккаунту."
        alert.addButton(withTitle: "Это я")
        alert.addButton(withTitle: "Завершить сеанс").hasDestructiveAction = true
        alert.addButton(withTitle: "Позже")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .mine
        case .alertSecondButtonReturn: return .notMine
        default: return .later
        }
    }

    static func notice(_ text: String, from bot: String) {
        let alert = NSAlert()
        alert.messageText = bot
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func saveLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func ask(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Colors handed to mini apps, matched to the system look of the window.
@MainActor
enum WebAppTheme {
    private static let dark: [String: Int] = [
        "background_color": 0x1C1C1E, "secondary_background_color": 0x2C2C2E, "header_background_color": 0x1C1C1E,
        "bottom_bar_background_color": 0x1C1C1E, "section_background_color": 0x2C2C2E,
        "section_separator_color": 0x38383A, "text_color": 0xFFFFFF, "accent_text_color": 0x0A84FF,
        "section_header_text_color": 0x8E8E93, "subtitle_text_color": 0x8E8E93, "destructive_text_color": 0xFF453A,
        "hint_color": 0x8E8E93, "link_color": 0x0A84FF, "button_color": 0x0A84FF, "button_text_color": 0xFFFFFF,
    ]
    private static let light: [String: Int] = [
        "background_color": 0xFFFFFF, "secondary_background_color": 0xF2F2F7, "header_background_color": 0xF7F7F7,
        "bottom_bar_background_color": 0xF7F7F7, "section_background_color": 0xFFFFFF,
        "section_separator_color": 0xC6C6C8, "text_color": 0x000000, "accent_text_color": 0x007AFF,
        "section_header_text_color": 0x6D6D72, "subtitle_text_color": 0x8E8E93, "destructive_text_color": 0xFF3B30,
        "hint_color": 0x8E8E93, "link_color": 0x007AFF, "button_color": 0x007AFF, "button_text_color": 0xFFFFFF,
    ]

    static var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func colors(dark: Bool) -> [String: Int] { dark ? Self.dark : light }

    /// `themeParameters` for TDLib.
    static func parameters(dark: Bool) -> TDNode {
        var node: TDNode = ["@type": "themeParameters"]
        for (key, value) in colors(dark: dark) { node[key] = value }
        return node
    }

    /// The same colors as "#rrggbb" for the page's `theme_changed` event.
    static func css(dark: Bool) -> [String: String] {
        colors(dark: dark).mapValues { String(format: "#%06x", $0) }
    }
}
