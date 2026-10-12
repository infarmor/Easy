import Foundation

struct Credentials: Codable, Equatable {
    var apiId: Int
    var apiHash: String
}

/// One Telegram account signed in on this Mac. Each has its own TDLib database and files; the first one keeps
/// the folders the app always used, so its id is empty and nothing has to be moved.
struct AccountSlot: Codable, Identifiable, Equatable {
    var id: String
    var name = ""
    var userId: Int64 = 0
}

enum ConfigStore {
    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftLite", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let file = root.appendingPathComponent("credentials.json")
    /// The passcode's check value and salt; see `AppLock`.
    static let lockFile = root.appendingPathComponent("lock.json")

    static func load() -> Credentials? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func forget() {
        try? FileManager.default.removeItem(at: file)
    }

    static func databaseDirectory(for account: String) -> URL { prepare(folder(of: account) + "tdlib/database") }
    static func filesDirectory(for account: String) -> URL { prepare(folder(of: account) + "tdlib/files") }
    static var webAppStorageDirectory: URL { prepare(folder(of: list.current) + "webapp/storage") }

    // MARK: - accounts

    private struct AccountList: Codable {
        var current = ""
        var slots = [AccountSlot(id: "")]
    }

    private static let accountsFile = root.appendingPathComponent("accounts.json")
    private static var list: AccountList = {
        guard let data = try? Data(contentsOf: accountsFile),
              var saved = try? JSONDecoder().decode(AccountList.self, from: data) else { return AccountList() }
        // A slot's id becomes a folder name, and that folder is deleted with the account. Only ids this app
        // makes are taken from the file: one edited to "../.." must not point the deletion somewhere else.
        saved.slots.removeAll { !isValid(slot: $0.id) }
        guard !saved.slots.isEmpty else { return AccountList() }
        if !saved.slots.contains(where: { $0.id == saved.current }) { saved.current = saved.slots[0].id }
        return saved
    }()

    /// Empty for the first account, otherwise the eight hex digits `addAccount` makes.
    private static func isValid(slot id: String) -> Bool {
        id.isEmpty || (id.count == 8 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    static var accounts: [AccountSlot] { list.slots }
    static var currentAccount: String { list.current }

    /// Where an account keeps its data, relative to the app's folder.
    private static func folder(of account: String) -> String { account.isEmpty ? "" : "accounts/\(account)/" }

    /// The account the window shows, and opens on at the next launch.
    static func setCurrentAccount(_ id: String) {
        guard list.slots.contains(where: { $0.id == id }) else { return }
        list.current = id
        saveAccounts()
    }

    /// A slot for an account that has not signed in yet.
    static func addAccount() -> AccountSlot {
        let slot = AccountSlot(id: String(UUID().uuidString.prefix(8)).lowercased())
        list.slots.append(slot)
        saveAccounts()
        return slot
    }

    /// Who signed in to an account: its name is what the account menu shows.
    static func describe(account: String, name: String, userId: Int64) {
        guard let index = list.slots.firstIndex(where: { $0.id == account }),
              list.slots[index].name != name || list.slots[index].userId != userId else { return }
        list.slots[index].name = name
        list.slots[index].userId = userId
        saveAccounts()
    }

    /// Takes an account off the list, with its folder. The first account's folders are the app's own and
    /// stay: TDLib has already emptied them on sign-out. Never the last slot, and never the one on screen.
    static func removeAccount(_ id: String) {
        guard list.slots.count > 1, id != list.current, isValid(slot: id), list.slots.contains(where: { $0.id == id }) else { return }
        list.slots.removeAll { $0.id == id }
        saveAccounts()
        if !id.isEmpty {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("accounts/\(id)", isDirectory: true))
        }
    }

    private static func saveAccounts() {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: accountsFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountsFile.path)
    }

    private static func prepare(_ path: String) -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
