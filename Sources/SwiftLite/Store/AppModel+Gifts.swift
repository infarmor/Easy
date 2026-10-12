import Foundation

/// Telegram Stars and the gifts they buy; and the sites signed in to with Telegram.
extension AppModel {
    /// A gift Telegram offers for Stars right now.
    struct GiftOffer: Identifiable, Equatable {
        var id: Int64
        var sticker: Sticker?
        var stars: Int
        /// Limited gifts: how many are left of how many; nil for the ones that do not run out.
        var remaining: Int?
        var total: Int?
        var isForBirthday: Bool

        var isSoldOut: Bool { remaining == 0 }
    }

    func availableGifts() async -> [GiftOffer] {
        guard let result = try? await request(["@type": "getAvailableGifts"]) else { return [] }
        return result.tdNodes("gifts").compactMap { entry in
            guard let gift = entry.tdNode("gift"), gift.tdInt64("id") != 0 else { return nil }
            let limits = gift.tdNode("overall_limits")
            return GiftOffer(
                id: gift.tdInt64("id"),
                sticker: TD.sticker(gift.tdNode("sticker"), isEmoji: false),
                stars: gift.tdInt("star_count"),
                remaining: limits.map { $0.tdInt("remaining_count") },
                total: limits.map { $0.tdInt("total_count") },
                isForBirthday: gift.tdBool("is_for_birthday")
            )
        }
        .sorted { ($0.isSoldOut ? 1 : 0, $0.stars) < ($1.isSoldOut ? 1 : 0, $1.stars) }
    }

    /// How many Stars the account holds. TDLib also pushes the number as `updateOwnedStarCount`; asking makes
    /// sure a balance that has not changed since launch is known too.
    func starBalance() async -> Int? {
        guard myUserId != 0, let result = try? await request([
            "@type": "getStarTransactions",
            "owner_id": ["@type": "messageSenderUser", "user_id": myUserId],
            "subscription_id": "",
            "offset": "",
            "limit": 1,
        ]), let amount = result.tdNode("star_amount") else { return ownedStars }
        ownedStars = amount.tdInt("star_count")
        return ownedStars
    }

    /// Buys the gift for Stars and sends it. The error to show, or nil when it went.
    func sendGift(_ gift: GiftOffer, to userId: Int64, text: String, isPrivate: Bool) async -> String? {
        do {
            _ = try await request([
                "@type": "sendGift",
                // A 64-bit id travels as a string in TDLib's JSON.
                "gift_id": String(gift.id),
                "owner_id": ["@type": "messageSenderUser", "user_id": userId],
                "text": ["@type": "formattedText", "text": text.trimmingCharacters(in: .whitespacesAndNewlines), "entities": [Any]()],
                "is_private": isPrivate,
                "pay_for_upgrade": false,
            ])
            _ = await starBalance()
            return nil
        } catch {
            let message = Self.describe(error)
            if message.contains("BALANCE_TOO_LOW") { return L("Не хватает звёзд. Пополнить баланс можно в официальном приложении Telegram.") }
            if message.contains("STARGIFT_USAGE_LIMITED") { return L("Этот подарок закончился.") }
            return message
        }
    }

    // MARK: - sites signed in to with Telegram

    struct ConnectedWebsite: Identifiable, Equatable {
        var id: Int64
        var domain: String
        var browser: String
        var platform: String
        var ipAddress: String
        var location: String
        var lastActive: Date
    }

    /// Sites where "Log in with Telegram" was used: each can see the name and photo, and write through its
    /// bot. nil when TDLib did not answer, which is not the same as "none".
    func connectedWebsites() async -> [ConnectedWebsite]? {
        guard let result = try? await request(["@type": "getConnectedWebsites"]) else { return nil }
        return result.tdNodes("websites").map { node in
            ConnectedWebsite(
                id: node.tdInt64("id"),
                domain: node.tdString("domain_name"),
                browser: node.tdString("browser"),
                platform: node.tdString("platform"),
                ipAddress: node.tdString("ip_address"),
                location: node.tdString("location"),
                lastActive: Date(timeIntervalSince1970: TimeInterval(node.tdInt("last_active_date")))
            )
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    func disconnectWebsite(_ id: Int64) async -> Bool {
        (try? await request(["@type": "disconnectWebsite", "website_id": String(id)])) != nil
    }

    func disconnectAllWebsites() async -> Bool {
        (try? await request(["@type": "disconnectAllWebsites"])) != nil
    }
}
