import Foundation

/// DeviceStorage of the Mini Apps protocol: a key-value store the client keeps for one mini app.
///
/// The window runs on an ephemeral web data store on purpose, so a page's own `localStorage` dies with it.
/// This file is what survives, which is exactly what a page asks for when it calls `DeviceStorage.setItem`.
enum WebAppStorage {
    /// Our own ceilings, not Telegram's: the server's limits are not published to clients, so these only
    /// keep one app from filling the disk. Anything a page legitimately stores stays far below them.
    static let maxValueBytes = 64 * 1024
    static let maxKeys = 2048

    enum Failure: String, Error {
        case invalid = "DATA_INVALID"
        case tooManyKeys = "KEYS_LIMIT_EXCEEDED"
    }

    /// One file per app, named after the bot that owns it and the origin it is served from: two apps on one
    /// host belong to different bots and must not read each other's values. Characters that could turn into
    /// a path are replaced, so a URL can never point outside the storage folder.
    private static func file(for session: WebAppSession) -> URL {
        let host = session.url.host?.lowercased() ?? "unknown"
        let safe = host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? "\($0)" : "_" }.joined()
        let port = session.url.port.map { "-\($0)" } ?? ""
        return ConfigStore.webAppStorageDirectory.appendingPathComponent("bot\(session.botUserId)-\(safe)\(port).json")
    }

    static func values(for session: WebAppSession) -> [String: String] {
        guard let data = try? Data(contentsOf: file(for: session)),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return stored
    }

    /// A `nil` value removes the key, the way the page's `removeItem` is sent.
    static func set(_ value: String?, forKey key: String, for session: WebAppSession) -> Result<Void, Failure> {
        var stored = values(for: session)
        if let value {
            guard !key.isEmpty, key.utf8.count <= 128 else { return .failure(.invalid) }
            guard value.utf8.count <= maxValueBytes else { return .failure(.invalid) }
            guard stored[key] != nil || stored.count < maxKeys else { return .failure(.tooManyKeys) }
            stored[key] = value
        } else {
            stored[key] = nil
        }
        guard let data = try? JSONEncoder().encode(stored) else { return .failure(.invalid) }
        let url = file(for: session)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return .success(())
        } catch {
            return .failure(.invalid)
        }
    }

    static func clear(_ session: WebAppSession) {
        try? FileManager.default.removeItem(at: file(for: session))
    }
}
