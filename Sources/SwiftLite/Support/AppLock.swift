import CommonCrypto
import CryptoKit
import Foundation

/// The passcode that locks iGram and encrypts what it keeps on this Mac.
///
/// Nothing derived from the passcode is stored except a check value: the keys exist only in memory while the
/// app is unlocked, and are worked out again from what is typed at the next launch. That is why no keychain
/// is involved — and why a forgotten passcode cannot be recovered, only replaced by signing in again.
enum AppLock {
    /// What is on disk: enough to check a passcode and to know whether the database was re-keyed with it.
    struct Record: Codable, Equatable {
        var salt: Data
        /// A value only the right passcode reproduces; it says nothing about the keys themselves.
        var verifier: Data
        var rounds: Int
        /// TDLib's database is encrypted with this passcode's key. False between writing this record and the
        /// re-keying being confirmed, and again while the passcode is being removed.
        var encryptsDatabase: Bool
    }

    struct Keys {
        /// 32 bytes handed to TDLib as `database_encryption_key`.
        let database: Data
        /// For the archive of deleted messages and edit history.
        let archive: SymmetricKey
    }

    /// Slow on purpose: a stolen disk gives an attacker this file, and every guess has to pay for the rounds.
    static let rounds = 310_000
    static let minimumLength = 4

    static var isEnabled: Bool { load() != nil }

    static func load() -> Record? {
        guard let data = try? Data(contentsOf: ConfigStore.lockFile) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func save(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: ConfigStore.lockFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ConfigStore.lockFile.path)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: ConfigStore.lockFile)
    }

    /// A new record for this passcode, not yet saved, and its keys.
    static func make(passcode: String) -> (record: Record, keys: Keys)? {
        var salt = Data(count: 32)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess,
              let master = derive(passcode, salt: salt, rounds: rounds) else { return nil }
        let record = Record(salt: salt, verifier: tag(master, "verify"), rounds: rounds, encryptsDatabase: false)
        return (record, keys(from: master))
    }

    /// The keys, when the passcode is the one the record was made with.
    static func unlock(_ passcode: String, _ record: Record) -> Keys? {
        guard let master = derive(passcode, salt: record.salt, rounds: record.rounds) else { return nil }
        // Compared in constant time: how long a wrong guess takes must not say how close it was.
        let candidate = tag(master, "verify")
        guard candidate.count == record.verifier.count,
              zip(candidate, record.verifier).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        return keys(from: master)
    }

    private static func keys(from master: Data) -> Keys {
        Keys(database: tag(master, "tdlib"), archive: SymmetricKey(data: tag(master, "archive")))
    }

    /// One master secret, a separate key for each use: knowing one of them gives nothing about the others.
    private static func tag(_ master: Data, _ purpose: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(purpose.utf8), using: SymmetricKey(data: master)))
    }

    private static func derive(_ passcode: String, salt: Data, rounds: Int) -> Data? {
        let password = Array(passcode.utf8)
        guard !password.isEmpty, rounds > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(passwordBytes.baseAddress!).assumingMemoryBound(to: CChar.self), password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &output, output.count)
            }
        }
        return status == kCCSuccess ? Data(output) : nil
    }

    // MARK: - sealing files

    private static let magic = Data("IGA1".utf8)

    static func isSealed(_ data: Data) -> Bool { data.prefix(magic.count) == magic }

    static func seal(_ data: Data, with key: SymmetricKey) -> Data? {
        (try? AES.GCM.seal(data, using: key))?.combined.map { magic + $0 }
    }

    static func open(_ data: Data, with key: SymmetricKey) -> Data? {
        guard isSealed(data), let box = try? AES.GCM.SealedBox(combined: data.dropFirst(magic.count)) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
