import AppKit
import Foundation

/// Profile sheets of people and chats, and your own profile.
extension AppModel {
    // MARK: - own profile

    struct MyProfile: Equatable {
        var firstName = ""
        var lastName = ""
        var bio = ""
        var username = ""
    }

    func loadMyProfile() async -> MyProfile? {
        guard myUserId != 0, let me = try? await request(["@type": "getUser", "user_id": myUserId]) else { return nil }
        let full = try? await request(["@type": "getUserFullInfo", "user_id": myUserId])
        return MyProfile(
            firstName: me.tdString("first_name"),
            lastName: me.tdString("last_name"),
            bio: full?.tdNode("bio")?.tdString("text") ?? "",
            username: me.tdNode("usernames")?.tdString("editable_username") ?? ""
        )
    }

    /// A status emoji a mini app asks to show in your profile. Telegram allows this of a Premium account,
    /// so an ordinary one answers through `error`; the caller decides what the page is told.
    func setEmojiStatus(customEmojiId: Int64, for seconds: Int) async throws {
        _ = try await request([
            "@type": "setEmojiStatus",
            "emoji_status": [
                "@type": "emojiStatus",
                "type": ["@type": "emojiStatusTypeCustomEmoji", "custom_emoji_id": customEmojiId],
                "expiration_date": seconds > 0 ? Int(Date().timeIntervalSince1970) + seconds : 0,
            ],
        ])
    }

    /// Saves what changed; returns the error to show, or nil.
    func saveMyProfile(_ profile: MyProfile, was old: MyProfile) async -> String? {
        do {
            if profile.firstName != old.firstName || profile.lastName != old.lastName {
                _ = try await request(["@type": "setName", "first_name": profile.firstName, "last_name": profile.lastName])
            }
            if profile.bio != old.bio {
                _ = try await request(["@type": "setBio", "bio": profile.bio])
            }
            if profile.username != old.username {
                _ = try await request(["@type": "setUsername", "username": profile.username])
            }
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    // MARK: - profiles

    func showMyProfile() async {
        guard myUserId != 0 else { return }
        await showProfile(ofUser: myUserId)
    }

    /// The person behind a private chat, or the group or channel itself.
    /// Closes the race where a slow `getUser` lands after the user already opened another profile, or dismissed
    /// the sheet: only the newest request may write `profile`.
    private func beginProfileRequest() -> Int {
        profileGeneration += 1
        return profileGeneration
    }

    func showProfile(of chat: Chat) async {
        if chat.userId != 0 {
            await showProfile(ofUser: chat.userId)
        } else {
            await showChatProfile(chat.id)
        }
    }

    /// The author of a message: a person, or a channel posting as itself.
    func showProfile(ofSender message: Message) async {
        if let userId = Int64(message.senderKey.dropFirst()), message.senderKey.hasPrefix("u") {
            await showProfile(ofUser: userId)
        } else if let chatId = Int64(message.senderKey.dropFirst()), message.senderKey.hasPrefix("c") {
            await showChatProfile(chatId)
        }
    }

    func showProfile(ofUser userId: Int64) async {
        let generation = beginProfileRequest()
        do {
            let user = try await request(["@type": "getUser", "user_id": userId])
            let full = try? await request(["@type": "getUserFullInfo", "user_id": userId])
            let type = user.tdNode("type")?.tdType ?? ""
            let verification = user.tdNode("verification_status")
            var info = ProfileInfo(
                title: TD.displayName(ofUser: user),
                photo: TD.photo(user.tdNode("profile_photo")),
                seed: userId,
                subtitle: type == "userTypeBot" ? "бот" : TD.presence(user.tdNode("status")).map { TD.describe($0) } ?? "",
                telegramId: userId,
                dataCenter: dataCenter(ofPhoto: user.tdNode("profile_photo"))
            )
            info.userId = userId
            info.isSelf = userId == myUserId
            info.usernames = (user.tdNode("usernames")?["active_usernames"] as? [String]) ?? []
            let phone = user.tdString("phone_number")
            info.phone = phone.isEmpty ? "" : "+" + phone
            info.about = full?.tdNode("bio")?.tdString("text") ?? ""
            if let bot = full?.tdNode("bot_info") {
                let description = bot.tdString("description")
                info.about = description.isEmpty ? bot.tdString("short_description") : description
            }
            if verification?.tdBool("is_verified") == true { info.badges.append("Подтверждён") }
            if user.tdBool("is_premium") { info.badges.append("Premium") }
            if verification?.tdBool("is_scam") == true { info.badges.append("⚠︎ SCAM") }
            if verification?.tdBool("is_fake") == true { info.badges.append("⚠︎ FAKE") }
            if user.tdBool("is_support") { info.badges.append("Поддержка Telegram") }
            if type == "userTypeDeleted" { info.badges.append("Удалён") }
            if user.tdBool("is_mutual_contact") {
                info.badges.append("Взаимный контакт")
            } else if user.tdBool("is_contact") {
                info.badges.append("В контактах")
            }
            info.isBlocked = full?.tdNode("block_list") != nil
            if let full {
                let common = full.tdInt("group_in_common_count")
                if common > 0 { info.facts.append(("Общие группы", String(common))) }
                if let birthdate = full.tdNode("birthdate"), birthdate.tdInt("day") > 0 {
                    let year = birthdate.tdInt("year")
                    info.facts.append(("День рождения", String(format: "%02d.%02d", birthdate.tdInt("day"), birthdate.tdInt("month")) + (year > 0 ? ".\(year)" : "")))
                }
                if full.tdBool("has_private_forwards") { info.facts.append(("Пересылки", "скрывает профиль")) }
                if full.tdBool("uses_unofficial_app") { info.facts.append(("Клиент", "неофициальное приложение")) }
            }
            let language = user.tdString("language_code")
            if !language.isEmpty { info.facts.append(("Язык", language)) }
            info.raw = user
            guard generation == profileGeneration else { return }
            profile = info
        } catch {
            fail(error)
        }
    }

    private func showChatProfile(_ chatId: Int64) async {
        let generation = beginProfileRequest()
        do {
            let chat = try await request(["@type": "getChat", "chat_id": chatId])
            let type = chat.tdNode("type") ?? [:]
            var info = ProfileInfo(
                title: chat.tdString("title"),
                photo: TD.photo(chat.tdNode("photo")),
                seed: chatId,
                subtitle: "",
                telegramId: chatId,
                dataCenter: dataCenter(ofPhoto: chat.tdNode("photo"))
            )
            switch type.tdType {
            case "chatTypeSupergroup":
                let groupId = type.tdInt64("supergroup_id")
                info.innerId = groupId
                let group = try? await request(["@type": "getSupergroup", "supergroup_id": groupId])
                let full = try? await request(["@type": "getSupergroupFullInfo", "supergroup_id": groupId])
                let members = full?.tdInt("member_count") ?? group?.tdInt("member_count") ?? 0
                let isChannel = type.tdBool("is_channel")
                info.subtitle = (isChannel ? "канал" : "группа") + (members > 0 ? " · " + TD.count(members, "участник", "участника", "участников") : "")
                info.usernames = (group?.tdNode("usernames")?["active_usernames"] as? [String]) ?? []
                info.about = full?.tdString("description") ?? ""
                let verification = group?.tdNode("verification_status")
                if verification?.tdBool("is_verified") == true { info.badges.append("Подтверждён") }
                if verification?.tdBool("is_scam") == true { info.badges.append("⚠︎ SCAM") }
                if verification?.tdBool("is_fake") == true { info.badges.append("⚠︎ FAKE") }
                if group?.tdBool("is_forum") == true { info.badges.append("Форум") }
                if let date = group?.tdInt("date"), date > 0 {
                    info.facts.append(("Создан или вступили", Date(timeIntervalSince1970: TimeInterval(date)).formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))))
                }
                if let admins = full?.tdInt("administrator_count"), admins > 0 { info.facts.append(("Администраторы", String(admins))) }
                if let linked = full?.tdInt64("linked_chat_id"), linked != 0 { info.facts.append(("Связанный чат", String(linked))) }
            case "chatTypeBasicGroup":
                let groupId = type.tdInt64("basic_group_id")
                info.innerId = groupId
                let full = try? await request(["@type": "getBasicGroupFullInfo", "basic_group_id": groupId])
                let members = full?.tdNodes("members").count ?? 0
                info.subtitle = "группа" + (members > 0 ? " · " + TD.count(members, "участник", "участника", "участников") : "")
                info.about = full?.tdString("description") ?? ""
            default:
                info.subtitle = "чат"
            }
            info.raw = chat
            guard generation == profileGeneration else { return }
            profile = info
        } catch {
            fail(error)
        }
    }

    /// Profile and chat photos are stored in the owner's data center.
    private func dataCenter(ofPhoto photo: TDNode?) -> Int? {
        for size in ["small", "big"] {
            if let id = photo?.tdNode(size)?.tdNode("remote")?.tdString("id"), !id.isEmpty,
               let dc = TD.dataCenter(ofRemoteFileId: id) {
                return dc
            }
        }
        return nil
    }

    /// The profile's "Открыть": out of the sheet and into the chat it describes.
    func openChat(fromProfile chatId: Int64, searching: Bool = false) async {
        profile = nil
        if knownChats[chatId] == nil {
            // Someone you have never written to has no chat yet; TDLib makes the empty one to open.
            guard chatId > 0, (try? await request(["@type": "createPrivateChat", "user_id": chatId, "force": false])) != nil else { return }
        }
        selection = chatId
        // After the selection: leaving the chat that was open closes its own search.
        if searching { isSearching = true }
    }

    /// Whether a chat's notifications are off, by its own setting or its kind's default; nil for a chat this
    /// account does not have.
    func isChatMuted(_ chatId: Int64) -> Bool? {
        knownChats[chatId].map { isMuted($0) }
    }

    func toggleMuted(chatId: Int64) async {
        guard var chat = knownChats[chatId] else { return }
        chat.isMuted = isMuted(chat)
        await toggleChatMuted(chat)
    }

    /// A new end-to-end encrypted chat with this person. It lives on this Mac only and opens at once; the
    /// first message goes when the other side has come online and accepted it.
    func startSecretChat(with userId: Int64) async {
        profile = nil
        do {
            let chat = try await request(["@type": "createNewSecretChat", "user_id": userId])
            if chat.tdInt64("id") != 0 { selection = chat.tdInt64("id") }
        } catch {
            fail(error)
        }
    }

    func openChat(withUser userId: Int64) async {
        profile = nil
        await openPrivateChat(with: userId)
    }
}
