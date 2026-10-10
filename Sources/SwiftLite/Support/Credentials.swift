import Foundation

struct Credentials: Codable, Equatable {
    var apiId: Int
    var apiHash: String
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

    static var databaseDirectory: URL { prepare("tdlib/database") }
    static var filesDirectory: URL { prepare("tdlib/files") }
    static var webAppStorageDirectory: URL { prepare("webapp/storage") }

    private static func prepare(_ path: String) -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
