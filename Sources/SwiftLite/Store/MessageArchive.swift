import CryptoKit
import Foundation

/// AyuGram-style memory that TDLib does not keep: messages other people deleted, earlier versions of
/// edited texts and your own local wording of messages. One JSON file per account in Application Support, readable only by the user.
@MainActor
final class MessageArchive {
    struct Version: Codable, Equatable {
        var text: String
        /// When this text was replaced by a newer one.
        var replacedAt: Date
    }

    struct Entry: Codable, Equatable {
        var chatId: Int64
        var messageId: Int64
        var senderKey: String
        var isOutgoing: Bool
        var date: Date
        var text: String
        var deletedAt: Date?
        var versions: [Version] = []
        /// Your own wording, shown only on this Mac in place of the real text.
        var localText: String?
    }

    /// Keeps a busy chat from growing the file without bound.
    private static let limitPerChat = 1000
    /// Edit history of one message: the trail is useful, the whole trail of a fiddled-with caption is not.
    private static let limitOfVersions = 30

    private var entries: [Int64: [Int64: Entry]] = [:]
    private var file: URL?
    /// False when the stored file could not be read: an empty archive must not be written over it.
    private var loaded = true
    private var saveTask: Task<Void, Never>?
    /// Set while a passcode protects the app: the file is then written sealed, and read back only with it.
    private var key: SymmetricKey?

    /// A passcode was set, changed or removed: what is in memory is written again the new way.
    func setKey(_ key: SymmetricKey?) {
        self.key = key
        saveNow()
    }

    /// One file per account, in Application Support.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftLite/archive", isDirectory: true)
    }

    func open(accountId: Int64, key: SymmetricKey? = nil) {
        self.key = key
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(accountId).json")
        self.file = file
        entries = [:]
        loaded = false
        guard FileManager.default.fileExists(atPath: file.path) else {
            loaded = true
            return
        }
        guard var data = try? Data(contentsOf: file) else { return }
        if AppLock.isSealed(data) {
            // Sealed with a passcode this session does not have: left as it is, never written over.
            guard let key, let opened = AppLock.open(data, with: key) else { return }
            data = opened
        }
        guard let stored = try? JSONDecoder().decode([Entry].self, from: data) else {
            // Usually a field this build does not know. Leave the file alone; the next version can still read it.
            return
        }
        entries = Dictionary(grouping: stored, by: \.chatId).mapValues { rows in
            // The same message can be listed twice — a hand-merged or half-written file. Whichever row a
            // dictionary happens to lay out last is not a rule worth trusting, so keep the one that remembers
            // more: a deletion mark and your own wording cannot be recovered, an edit trail mostly can.
            var byId: [Int64: Entry] = [:]
            for row in rows {
                guard let kept = byId[row.messageId] else { byId[row.messageId] = row; continue }
                if Self.value(of: row) > Self.value(of: kept) { byId[row.messageId] = row }
            }
            return byId
        }
        loaded = true
    }

    private static func value(of entry: Entry) -> Int {
        (entry.deletedAt != nil ? 4 : 0) + (entry.localText != nil ? 4 : 0) + min(entry.versions.count, 3)
    }

    func close() {
        saveNow()
        // The app may be quitting: what was queued is on disk before the archive lets go.
        Self.io.sync {}
        entries = [:]
        file = nil
    }

    func clear() {
        entries = [:]
        scheduleSave()
    }

    func forget(chatId: Int64, messageId: Int64) {
        entries[chatId]?[messageId] = nil
        scheduleSave()
    }

    // MARK: - recording

    func recordDeletion(of message: Message) {
        var entry = entries[message.chatId]?[message.id] ?? Self.entry(for: message)
        entry.deletedAt = Date()
        store(entry)
    }

    func recordEdit(of message: Message, previousText: String) {
        var entry = entries[message.chatId]?[message.id] ?? Self.entry(for: message)
        entry.versions.append(Version(text: previousText, replacedAt: Date()))
        // A message edited over and over should not outweigh the rest of the chat's history.
        if entry.versions.count > Self.limitOfVersions {
            entry.versions.removeFirst(entry.versions.count - Self.limitOfVersions)
        }
        entry.text = Self.text(of: message)
        store(entry)
    }

    // MARK: - reading

    func deletedMessages(in chatId: Int64) -> [Message] {
        (entries[chatId] ?? [:]).values.filter { $0.deletedAt != nil }.map { entry in
            var message = Message(
                id: entry.messageId,
                chatId: entry.chatId,
                senderKey: entry.senderKey,
                isOutgoing: entry.isOutgoing,
                body: .text(entry.text),
                date: entry.date,
                isPending: false,
                isFailed: false,
                isPinned: false
            )
            message.isDeleted = true
            message.hasEditHistory = !entry.versions.isEmpty
            message.localText = entry.localText
            return message
        }
    }

    /// Everything kept whose text, or an earlier version of it, has the words: newest first. Looks through
    /// what is in memory, which is all of it.
    func search(_ query: String, limit: Int = 40) -> [Message] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 2 else { return [] }
        var found: [Entry] = []
        for chat in entries.values {
            for entry in chat.values where entry.deletedAt != nil || !entry.versions.isEmpty {
                if entry.text.lowercased().contains(needle) || entry.versions.contains(where: { $0.text.lowercased().contains(needle) }) {
                    found.append(entry)
                }
            }
        }
        return found.sorted { $0.date > $1.date }.prefix(limit).map { entry in
            var message = Message(id: entry.messageId, chatId: entry.chatId, senderKey: entry.senderKey, isOutgoing: entry.isOutgoing,
                                  body: .text(entry.text), date: entry.date, isPending: false, isFailed: false, isPinned: false)
            message.isDeleted = entry.deletedAt != nil
            message.hasEditHistory = !entry.versions.isEmpty
            message.localText = entry.localText
            return message
        }
    }

    func localText(chatId: Int64, messageId: Int64) -> String? {
        entries[chatId]?[messageId]?.localText
    }

    /// nil puts the real text back.
    func setLocalText(_ text: String?, for message: Message) {
        var entry = entries[message.chatId]?[message.id] ?? Self.entry(for: message)
        entry.localText = text
        if text == nil, entry.deletedAt == nil, entry.versions.isEmpty {
            forget(chatId: message.chatId, messageId: message.id)
        } else {
            store(entry)
        }
    }

    func hasHistory(chatId: Int64, messageId: Int64) -> Bool {
        !(entries[chatId]?[messageId]?.versions.isEmpty ?? true)
    }

    func entry(chatId: Int64, messageId: Int64) -> Entry? {
        entries[chatId]?[messageId]
    }

    /// Text as shown in the transcript: the message itself, or the attachment label with its caption.
    static func text(of message: Message) -> String {
        switch message.body {
        case .text(let value): value
        case .attachment(let label), .service(let label), .unsupported(let label): label
        }
    }

    // MARK: - storage

    private static func entry(for message: Message) -> Entry {
        Entry(
            chatId: message.chatId,
            messageId: message.id,
            senderKey: message.senderKey,
            isOutgoing: message.isOutgoing,
            date: message.date,
            text: text(of: message)
        )
    }

    private func store(_ entry: Entry) {
        guard file != nil else { return }
        var chat = entries[entry.chatId] ?? [:]
        chat[entry.messageId] = entry
        // The oldest entry makes room. Your own wording goes last — nothing else remembers it — but a chat made
        // of nothing but local edits still has to stop growing.
        if chat.count > Self.limitPerChat {
            let evictable = chat.values.filter { $0.localText == nil }.map(\.messageId)
            if let oldest = evictable.min() ?? chat.values.map(\.messageId).min() { chat[oldest] = nil }
        }
        entries[entry.chatId] = chat
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Encoding thousands of entries is kept off the main thread; one serial queue keeps the writes in order.
    private static let io = DispatchQueue(label: "ru.anemia.swiftlite.archive", qos: .utility)

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let file, loaded else { return }
        // Taking the dictionary is a reference bump; walking it into a flat array was 0.35 ms of the main
        // thread at ten thousand entries, and the encoder is already off the main thread.
        let snapshot = entries
        let key = key
        Self.io.async {
            let all = snapshot.values.flatMap(\.values)
            guard var data = try? JSONEncoder().encode(all) else { return }
            if let key {
                // A file that cannot be sealed is not written in the clear instead.
                guard let sealed = AppLock.seal(data, with: key) else { return }
                data = sealed
            }
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
