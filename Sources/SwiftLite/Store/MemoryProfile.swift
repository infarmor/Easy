import Foundation

/// How much the app holds in memory and keeps on disk: Settings → Storage → Профиль памяти. Stored by its raw
/// value under `Preferences.memoryProfile`; Balanced is the default.
enum MemoryProfile: Int {
    case standard = 0
    case balanced = 1
    case economical = 2

    /// Messages per chat kept in RAM, so a message deleted a few minutes after it came can still be shown.
    var recentMessagesLimit: Int {
        switch self {
        case .standard: return 60
        case .balanced: return 40
        case .economical: return 20
        }
    }

    /// Downloaded files older than this are pruned when the profile is applied. Standard leaves the files to
    /// TDLib's own storage optimizer.
    var maxAgeDays: Int {
        switch self {
        case .standard: return 0
        case .balanced: return 7
        case .economical: return 1
        }
    }
}

extension AppModel {
    /// The profile as set now. Read each time rather than kept, so a change in the settings applies at once.
    nonisolated static var memoryProfile: MemoryProfile {
        (UserDefaults.standard.object(forKey: Preferences.memoryProfile) as? Int).flatMap(MemoryProfile.init(rawValue:)) ?? .balanced
    }

    var memoryProfile: MemoryProfile { Self.memoryProfile }
}
