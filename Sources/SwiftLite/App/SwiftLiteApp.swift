import AppKit
import SwiftUI

@main
struct SwiftLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("iGram") {
            RootView()
                .environment(model)
                .task {
                    delegate.model = model
                    model.boot()
                }
        }
        .defaultSize(width: 1160, height: 740)
        .commands {
            // Only one main window: a second would share this AppModel, and both composers would write the
            // same draft while each view re-runs `select` on the chat the other is looking at.
            // "New" here is a new chat. Not a new window: a second one would share this AppModel, and both
            // composers would write the same draft while each view re-runs `select` on the other's chat.
            CommandGroup(replacing: .newItem) {
                Button("Новый чат…") { model.showsNewChat = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.takesCommands)
                Button("Избранное") { Task { await model.openSavedMessages() } }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!model.takesCommands)
            }
            CommandGroup(after: .newItem) {
                Button("Отметить прочитанным") {
                    Task { await model.markSelectedRead() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.takesCommands)
            }
            CommandGroup(after: .pasteboard) {
                Button("Отправить из буфера обмена") {
                    Task { await model.sendPasteboard() }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!model.takesCommands)
            }
            CommandGroup(after: .sidebar) {
                Group {
                Button("Синхронизировать чаты") {
                    Task { await model.loadChats() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                // One key, two meanings, told apart the way Mail and Notes tell them: with words selected in
                // the composer ⌘K makes them a link.
                Button(model.composerHasSelection ? "Ссылка на выделенное" : "Найти чат") { model.linkOrFindChat() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Предыдущий чат") { model.selectAdjacentChat(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Следующий чат") { model.selectAdjacentChat(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("К последним сообщениям") { Task { await model.showLatest() } }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Увеличить текст сообщений") { Preferences.stepFontSize(1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Уменьшить текст сообщений") { Preferences.stepFontSize(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("Предыдущий непрочитанный") { model.selectUnreadChat(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                Button("Следующий непрочитанный") { model.selectUnreadChat(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
                ForEach(1...9, id: \.self) { number in
                    Button("Чат \(number)") { model.selectChat(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
                }
                .disabled(!model.takesCommands)
                Button("Заблокировать iGram") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(!model.hasPasscode || model.isLocked)
                Button("Режим призрака") {
                    UserDefaults.standard.set(!Preferences.isOn(Preferences.ghostMode), forKey: Preferences.ghostMode)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!model.takesCommands)
            }
        }

        .commands {
            CommandMenu("Формат") {
                Group {
                Button("Жирный") { model.format(.bold) }
                    .keyboardShortcut("b", modifiers: .command)
                Button(model.composerHasSelection ? "Курсив" : "Профиль собеседника") { model.italicOrProfile() }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Зачёркнутый") { model.format(.strikethrough) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Моноширинный") { model.format(.code) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Спойлер") { model.format(.spoiler) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                }
                .disabled(!model.takesCommands)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Мини-приложение", id: WebAppWindow.id) {
            WebAppWindow()
                .environment(model)
        }
        .defaultSize(width: 420, height: 720)
        .windowResizability(.contentMinSize)
    }
}

/// Holds the quit until the model has saved the draft, gone offline and closed TDLib.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?
    private var answered = false

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // Every reply after the first would kill the process while TDLib is still closing its databases.
        guard !answered else { return .terminateLater }
        Task { @MainActor in
            await model.prepareForQuit()
            answer(sender)
        }
        // A TDLib request that never comes back has no timeout, so the quit needs one of its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { self?.answer(sender) }
        }
        return .terminateLater
    }

    @MainActor
    private func answer(_ sender: NSApplication) {
        guard !answered else { return }
        answered = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
