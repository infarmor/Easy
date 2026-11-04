import Foundation

/// How much Easy keeps in memory and on disk, chosen in Settings → Storage. Stored in Preferences as 0, 1 or 2.
enum MemoryProfile: Int {
    case standard = 0
    case balanced = 1
    case economical = 2

    /// The profile in Preferences; an unknown stored value falls back to the default, Balanced.
    static var current: MemoryProfile {
        MemoryProfile(rawValue: UserDefaults.standard.integer(forKey: Preferences.memoryProfile)) ?? .balanced
    }

    /// Messages per chat kept in memory so a deleted one can still be restored.
    var recentMessagesLimit: Int {
        switch self {
        case .standard: return 60
        case .balanced: return 40
        case .economical: return 20
        }
    }

    /// Age in days after which TDLib's storage optimizer removes downloaded files. Standard leaves this to
    /// TDLib's own defaults and does not prune.
    var maxAgeDays: Int {
        switch self {
        case .standard: return 30
        case .balanced: return 7
        case .economical: return 1
        }
    }
}
