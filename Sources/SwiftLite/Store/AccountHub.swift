import Foundation

/// Every account signed in on this Mac, each with a session of its own that stays connected: messages and
/// banners arrive for all of them, and the window shows whichever one is picked.
@MainActor
@Observable
final class AccountHub {
    private(set) var accounts = ConfigStore.accounts
    private(set) var activeId = ConfigStore.currentAccount
    /// One list for the chats of every account, newest first; a click opens a chat in the account it belongs to.
    var showsAllAccounts = UserDefaults.standard.object(forKey: "allAccountsList") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsAllAccounts, forKey: "allAccountsList") }
    }
    @ObservationIgnored private var models: [String: AppModel] = [:]
    /// The chat each account had open when the window left it, to come back to.
    @ObservationIgnored private var openChats: [String: Int64] = [:]

    init() {
        for account in accounts { adopt(AppModel(slot: account.id)) }
        if models[activeId] == nil { adopt(AppModel(slot: activeId)) }
        // The proxy is the app's, not an account's: a change reaches every session at once.
        ProxyStore.shared.onChange = { [weak self] in
            guard let self else { return }
            for model in models.values { model.applyProxy() }
        }
    }

    /// The account in the window.
    var active: AppModel { models[activeId]! }

    func model(for account: String) -> AppModel? { models[account] }

    private func adopt(_ model: AppModel) {
        model.hub = self
        models[model.slot] = model
    }

    /// The one on screen first; the rest connect behind it.
    func boot() {
        active.boot()
        for model in models.values where model !== active { model.boot() }
    }

    func refresh() {
        accounts = ConfigStore.accounts
    }

    // MARK: - picking an account

    func activate(_ account: String) {
        guard account != activeId, let next = models[account] else { return }
        let previous = active
        // Its chat is closed, not left open behind the window: an open chat reads what arrives in it.
        openChats[activeId] = previous.selection
        previous.selection = nil
        activeId = account
        ConfigStore.setCurrentAccount(account)
        if let chat = openChats[account], next.phase == .working { next.selection = chat }
    }

    /// A chat of any account, from the list of all of them: its account comes into the window with it.
    func open(_ chatId: Int64, in account: String) {
        guard let model = models[account] else { return }
        // Not the chat that account had open last: this one.
        openChats[account] = chatId
        activate(account)
        model.selection = chatId
    }

    struct OwnedChat: Identifiable {
        let chat: Chat
        let owner: AppModel
        var id: String { owner.slot + ":" + String(chat.id) }
    }

    /// The main lists of all signed-in accounts as one, by the time of the last message. Capped: the rows
    /// are rebuilt whenever any account's list changes.
    var allChats: [OwnedChat] {
        let signedIn = accounts.compactMap { models[$0.id] }.filter { $0.phase == .working }
        let merged = signedIn.flatMap { owner in owner.chats.map { OwnedChat(chat: $0, owner: owner) } }
        // Pinned chats keep their place at the top, whichever account pinned them; then the newest first.
        return Array(merged.sorted { a, b in
            if a.chat.isPinned != b.chat.isPinned { return a.chat.isPinned }
            return (a.chat.snippetDate ?? .distantPast) > (b.chat.snippetDate ?? .distantPast)
        }.prefix(200))
    }

    /// Chats of the other accounts whose name has the words being searched for: the sidebar's search looks
    /// through the account in the window, and this is what it would otherwise miss.
    func matches(_ query: String, outside model: AppModel) -> [OwnedChat] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else { return [] }
        return accounts.compactMap { models[$0.id] }
            .filter { $0 !== model && $0.phase == .working }
            .flatMap { owner in
                owner.listableChats.filter { $0.title.lowercased().contains(needle) }.prefix(15).map { OwnedChat(chat: $0, owner: owner) }
            }
    }

    /// ⌃1…⌃9 and the account menu.
    func activate(number: Int) {
        guard accounts.indices.contains(number - 1) else { return }
        activate(accounts[number - 1].id)
    }

    /// A fresh database; TDLib asks it for a phone number, which is the sign-in screen.
    func addAccount() {
        let slot = ConfigStore.addAccount()
        let model = AppModel(slot: slot.id)
        adopt(model)
        refresh()
        model.adoptLock(from: active)
        activate(slot.id)
        model.boot()
    }

    /// The account has not signed in yet and there is another one to go back to.
    func canLeaveSignIn(_ model: AppModel) -> Bool {
        accounts.count > 1 && accounts.first { $0.id == model.slot }?.userId == 0
    }

    /// Back from the sign-in screen of an account that was never signed in to.
    func leaveSignIn(_ model: AppModel) {
        guard canLeaveSignIn(model), let other = accounts.first(where: { $0.id != model.slot }) else { return }
        activate(other.id)
        models[model.slot] = nil
        let slot = model.slot
        // Its folder goes only after TDLib has closed the database in it: TDLib still writes there while closing.
        Task {
            await model.prepareForQuit()
            ConfigStore.removeAccount(slot)
            self.refresh()
        }
    }

    /// An account signed out and its session has closed. With others left its slot goes and the window moves
    /// on; false when it was the only one, which then shows its own sign-in screen.
    func signedOut(_ model: AppModel) -> Bool {
        guard let other = accounts.first(where: { $0.id != model.slot }) else { return false }
        if model.slot == activeId { activate(other.id) }
        models[model.slot] = nil
        openChats[model.slot] = nil
        ConfigStore.removeAccount(model.slot)
        refresh()
        return true
    }

    // MARK: - everything at once

    /// The passcode covers the app, not one account: what one learns, all know.
    func shareLock(from source: AppModel, rekeying: Bool = false) {
        for model in models.values where model !== source { model.adoptLock(from: source, rekeying: rekeying) }
    }

    /// The Dock counts what is unread in every account.
    var unreadTotal: Int { models.values.reduce(0) { $0 + $1.unreadBadge } }

    func prepareForQuit() async {
        await withTaskGroup(of: Void.self) { group in
            for model in models.values {
                group.addTask { await model.prepareForQuit() }
            }
        }
    }
}
