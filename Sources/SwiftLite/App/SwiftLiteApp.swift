import AppKit
import SwiftUI

@main
struct SwiftLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var hub = AccountHub()

    /// The account in the window: the menus and the other windows act on it.
    private var model: AppModel { hub.active }

    var body: some Scene {
        WindowGroup("Easy") {
            RootView()
                .environment(model)
                .environment(hub)
                .tint(Color.brandInk)
                // The colour follows the desktop picture; a new one means every view resolves its colours again.
                .id(Theme.shared.revision)
                .task {
                    delegate.hub = hub
                    hub.boot()
                    Updates.shared.check()
                }
        }
        .defaultSize(width: 1160, height: 740)
        .commands {
            // Only one main window: a second would share this AppModel, and both composers would write the
            // same draft while each view re-runs `select` on the chat the other is looking at.
            // "New" here is a new chat. Not a new window: a second one would share this AppModel, and both
            // composers would write the same draft while each view re-runs `select` on the other's chat.
            CommandGroup(replacing: .newItem) {
                Button(L("Новый чат…")) { model.showsNewChat = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.takesCommands)
                Button(L("Избранное")) { Task { await model.openSavedMessages() } }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!model.takesCommands)
            }
            CommandGroup(after: .newItem) {
                Button(L("Отметить прочитанным")) {
                    Task { await model.markSelectedRead() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.takesCommands)
            }
            CommandGroup(after: .pasteboard) {
                Button(L("Отправить из буфера обмена")) {
                    Task { await model.sendPasteboard() }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!model.takesCommands)
            }
            CommandGroup(after: .sidebar) {
                Group {
                Button(L("Синхронизировать чаты")) {
                    Task { await model.loadChats() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                // One key, two meanings, told apart the way Mail and Notes tell them: with words selected in
                // the composer ⌘K makes them a link.
                Button(model.composerHasSelection ? L("Ссылка на выделенное") : L("Найти чат")) { model.linkOrFindChat() }
                    .keyboardShortcut("k", modifiers: .command)
                Button(L("Предыдущий чат")) { model.selectAdjacentChat(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button(L("Следующий чат")) { model.selectAdjacentChat(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                // ⌘↓ is also "caret to the end of the text". A menu takes a key before the field sees it, so
                // while something is being written the key is left to the field.
                Button(L("К последним сообщениям")) { Task { await model.showLatest() } }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(model.hasDraftText)
                Button(L("Увеличить текст сообщений")) { Preferences.stepFontSize(1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button(L("Уменьшить текст сообщений")) { Preferences.stepFontSize(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                // Not ⌥⇧↑/↓, which they first were: in a text field those extend the selection by a paragraph,
                // and the menu was taking them away from the composer.
                Button(L("Предыдущий непрочитанный")) { model.selectUnreadChat(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .shift])
                Button(L("Следующий непрочитанный")) { model.selectUnreadChat(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .shift])
                ForEach(1...9, id: \.self) { number in
                    Button(L("Чат \(number)")) { model.selectChat(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
                }
                .disabled(!model.takesCommands)
                Button(L("Заблокировать Easy")) { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(!model.hasPasscode || model.isLocked)
                Button(L("Режим призрака")) {
                    UserDefaults.standard.set(!Preferences.isOn(Preferences.ghostMode), forKey: Preferences.ghostMode)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!model.takesCommands)
            }
        }

        .commands {
            CommandMenu(L("Аккаунты")) {
                ForEach(Array(hub.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                    Button(account.name.isEmpty ? L("Новый аккаунт") : account.name) { hub.activate(account.id) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
                        .disabled(account.id == hub.activeId)
                }
                Divider()
                Button(L("Добавить аккаунт…")) { hub.addAccount() }
                    .disabled(model.isLocked)
            }
            CommandMenu(L("Формат")) {
                Group {
                Button(L("Жирный")) { model.format(.bold) }
                    .keyboardShortcut("b", modifiers: .command)
                Button(model.composerHasSelection ? L("Курсив") : L("Профиль собеседника")) { model.italicOrProfile() }
                    .keyboardShortcut("i", modifiers: .command)
                Button(L("Зачёркнутый")) { model.format(.strikethrough) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button(L("Моноширинный")) { model.format(.code) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button(L("Спойлер")) { model.format(.spoiler) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                }
                .disabled(!model.takesCommands)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(hub)
                .tint(Color.brandInk)
                .id(hub.activeId)
        }

        Window(L("Мини-приложение"), id: WebAppWindow.id) {
            WebAppWindow()
                .environment(model)
                .environment(hub)
        }
        .defaultSize(width: 420, height: 720)
        .windowResizability(.contentMinSize)
    }
}

/// Holds the quit until the model has saved the draft, gone offline and closed TDLib.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var hub: AccountHub?
    private var answered = false
    @MainActor private var purge: DispatchWorkItem?

    /// After a stretch in the background the decoded pictures are let go: none of them is being scrolled
    /// to there, and what a visible window shows is held by its own views. Aggressive memory mode shortens
    /// the wait from five minutes to under a minute.
    @MainActor
    func applicationDidResignActive(_ notification: Notification) {
        purge?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { MediaCache.purge() } }
        purge = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MediaCache.backgroundPurgeDelay, execute: work)
    }

    @MainActor
    func applicationDidBecomeActive(_ notification: Notification) {
        purge?.cancel()
        purge = nil
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let hub else { return .terminateNow }
        // Every reply after the first would kill the process while TDLib is still closing its databases.
        guard !answered else { return .terminateLater }
        Task { @MainActor in
            await hub.prepareForQuit()
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
