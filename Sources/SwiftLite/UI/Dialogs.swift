import AppKit

/// Standard macOS panels behind the conversation actions. `@MainActor` because a panel running off the main
/// thread is undefined behaviour: the annotation is what keeps the call sites honest.
@MainActor
enum Dialogs {
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = L("Отправить файлы")
        panel.prompt = L("Отправить")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// "Изменить локально…": the text in an editable box; nil when cancelled.
    static func editLocally(_ text: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L("Изменить локально")
        alert.informativeText = L("Новый текст увидите только вы на этом Mac. Сообщение на сервере не меняется; оригинал можно вернуть в меню сообщения.")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
        scroll.borderType = .bezelBorder
        let editor = scroll.documentView as! NSTextView
        editor.string = text
        editor.font = .systemFont(ofSize: 13)
        editor.isRichText = false
        editor.allowsUndo = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: L("Сохранить"))
        alert.addButton(withTitle: L("Отмена"))
        alert.window.initialFirstResponder = editor
        return alert.runModal() == .alertFirstButtonReturn ? editor.string : nil
    }

    /// A short text asked for in an alert: nil when cancelled, the trimmed answer otherwise.
    static func prompt(_ title: String, hint: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = hint
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("ОК"))
        alert.addButton(withTitle: L("Отмена"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same question with a checkbox (like "Также у собеседника"): nil when cancelled, otherwise the checkbox.
    static func confirm(_ title: String, message: String, action: String, option: String?) -> Bool? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("Отмена"))
        alert.buttons.first?.hasDestructiveAction = true
        if let option {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = option
            alert.suppressionButton?.state = .off
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return alert.suppressionButton?.state == .on && option != nil
    }

    /// A yes/no question before something hard to undo.
    static func confirm(_ title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("Отмена"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `nil` when cancelled, otherwise whether the message goes for everyone.
    static func confirmDeletion(_ options: DeletionOptions) -> Bool? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Удалить сообщение?")
        switch (options.forEveryone, options.forSelf) {
        case (true, true): alert.informativeText = L("Его можно удалить у всех участников чата или только у себя.")
        case (true, false): alert.informativeText = L("Сообщение пропадёт у всех участников чата.")
        default: alert.informativeText = L("Сообщение пропадёт только у вас.")
        }

        var choices: [Bool] = []
        if options.forEveryone {
            alert.addButton(withTitle: options.forSelf ? L("Удалить у всех") : L("Удалить"))
            choices.append(true)
        }
        if options.forSelf {
            alert.addButton(withTitle: options.forEveryone ? L("Удалить только у меня") : L("Удалить"))
            choices.append(false)
        }
        alert.addButton(withTitle: L("Отмена"))
        alert.buttons.first?.hasDestructiveAction = true

        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : nil
    }
}
