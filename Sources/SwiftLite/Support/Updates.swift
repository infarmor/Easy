import Foundation

/// Asks GitHub once per launch whether a newer release of Easy is out. The only request the app makes
/// that does not go to Telegram, and it can be turned off in the settings.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    struct Release: Equatable {
        var version: String
        var page: URL
    }

    /// A release newer than the app that is running; nil when up to date, not asked yet, or dismissed.
    private(set) var available: Release?
    @ObservationIgnored private var asked = false

    private static let latest = URL(string: "https://api.github.com/repos/infarmor/Easy/releases/latest")!

    func check() {
        guard !asked, Preferences.isOn(Preferences.checkUpdates), Bundle.main.bundleURL.pathExtension == "app" else { return }
        asked = true
        Task {
            var request = URLRequest(url: Self.latest, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String,
                  let address = release["html_url"] as? String, let page = URL(string: address),
                  // Only a page of this repository is ever opened, whatever the answer says.
                  page.host == "github.com", page.path.hasPrefix("/infarmor/Easy/") else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard Self.isNewer(version, than: current),
                  UserDefaults.standard.string(forKey: Preferences.skippedUpdate) != version else { return }
            available = Release(version: version, page: page)
        }
    }

    /// "Not this one": the banner goes and does not come back for this version.
    func dismiss() {
        if let available { UserDefaults.standard.set(available.version, forKey: Preferences.skippedUpdate) }
        available = nil
    }

    /// 0.10.0 is newer than 0.9.3: compared number by number, not as text.
    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0, right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
