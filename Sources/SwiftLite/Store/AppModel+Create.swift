import AppKit
import Foundation

/// New groups, channels and contacts; the files TDLib has downloaded; and stories.
extension AppModel {
    // MARK: - creating

    /// A group with the chosen people. The error to show, or nil when the group exists and is open.
    func createGroup(title: String, members: [Int64]) async -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return L("Нужно название") }
        do {
            let created = try await request([
                "@type": "createNewBasicGroupChat",
                "user_ids": members,
                "title": title,
                "message_auto_delete_time": 0,
            ])
            let chatId = created.tdInt64("chat_id")
            if chatId != 0 { selection = chatId }
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func createChannel(title: String, about: String) async -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return L("Нужно название") }
        do {
            let chat = try await request([
                "@type": "createNewSupergroupChat",
                "title": title,
                "is_forum": false,
                "is_channel": true,
                "description": about.trimmingCharacters(in: .whitespacesAndNewlines),
                "message_auto_delete_time": 0,
                "for_import": false,
            ])
            let chatId = chat.tdInt64("id")
            if chatId != 0 { selection = chatId }
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// Adds someone by phone number and opens the chat with them. Telegram only says whether the number has
    /// an account; a number without one is not kept.
    func addContact(phone: String, firstName: String, lastName: String) async -> String? {
        let number = phone.filter { $0.isNumber || $0 == "+" }
        guard number.count >= 8 else { return L("Номер нужен в международном формате, например +79991234567") }
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { return L("Нужно имя") }
        do {
            let imported = try await request([
                "@type": "importContacts",
                "contacts": [[
                    "@type": "importedContact",
                    "phone_number": number,
                    "first_name": first,
                    "last_name": lastName.trimmingCharacters(in: .whitespacesAndNewlines),
                ]],
            ])
            guard let userId = imported.tdInt64s("user_ids").first, userId != 0 else { return L("У этого номера нет аккаунта Telegram") }
            await openPrivateChat(with: userId)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    // MARK: - downloads

    struct DownloadedFile: Identifiable, Equatable {
        enum Kind: String, CaseIterable, Identifiable {
            case documents, photos, videos, music, voice
            var id: String { rawValue }
        }

        var url: URL
        var size: Int
        var date: Date
        var kind: Kind
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    /// What this account has downloaded and still keeps, newest first. Thumbnails, stickers, profile photos
    /// and files still arriving are TDLib's own business and are left out.
    func downloadedFiles() async -> [DownloadedFile] {
        let root = ConfigStore.filesDirectory(for: slot)
        return await Task.detached(priority: .utility) {
            let folders: [(String, DownloadedFile.Kind)] = [
                ("documents", .documents), ("photos", .photos), ("videos", .videos), ("animations", .videos),
                ("video_notes", .videos), ("music", .music), ("voice", .voice),
            ]
            var files: [DownloadedFile] = []
            for (folder, kind) in folders {
                let directory = root.appendingPathComponent(folder, isDirectory: true)
                let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
                guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles]) else { continue }
                while let url = walker.nextObject() as? URL {
                    guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                    files.append(DownloadedFile(url: url, size: values.fileSize ?? 0,
                                                date: values.contentModificationDate ?? .distantPast, kind: kind))
                }
            }
            return files.sorted { $0.date > $1.date }
        }.value
    }

    /// Opens a downloaded file after the same checks an attachment in a chat gets.
    func openDownloaded(_ file: DownloadedFile) {
        if Preferences.isOn(Preferences.fileGuard),
           let warning = SecurityTools.fileWarning(for: file.name) ?? SecurityTools.contentWarning(at: file.url),
           !BotDialogs.ask(L("Открыть «\(file.name)»?"), warning, action: L("Открыть")) {
            return
        }
        NSWorkspace.shared.open(file.url)
    }

    // MARK: - stories

    struct StoryItem: Identifiable, Equatable {
        var id: Int
        var posterChatId: Int64
        var date: Date
        var caption: String
        var photoFileId: Int?
        var videoFileId: Int?
        var canBeReplied: Bool
    }

    /// The stories a person or a channel has up right now, oldest first, as they are watched.
    func activeStories(of chatId: Int64) async -> [StoryItem] {
        guard let active = try? await request(["@type": "getChatActiveStories", "chat_id": chatId]) else { return [] }
        var stories: [StoryItem] = []
        for info in active.tdNodes("stories") {
            let storyId = info.tdInt("story_id")
            guard storyId != 0, let story = try? await request([
                "@type": "getStory", "story_poster_chat_id": chatId, "story_id": storyId, "only_local": false,
            ]) else { continue }
            let content = story.tdNode("content")
            var item = StoryItem(id: storyId, posterChatId: chatId,
                                 date: Date(timeIntervalSince1970: TimeInterval(story.tdInt("date"))),
                                 caption: story.tdText("caption"), canBeReplied: story.tdBool("can_be_replied"))
            switch content?.tdType {
            case "storyContentPhoto":
                // The largest size is the last one.
                item.photoFileId = content?.tdNode("photo")?.tdNodes("sizes").last?.tdNode("photo")?.tdInt("id")
            case "storyContentVideo":
                item.videoFileId = content?.tdNode("video")?.tdNode("video")?.tdInt("id")
            default:
                break
            }
            stories.append(item)
        }
        return stories.sorted { $0.date < $1.date }
    }

    /// Watching a story tells its author; ghost mode keeps that to itself.
    func noteStoryOpened(_ story: StoryItem) {
        guard !Preferences.isOn(Preferences.ghostMode) else { return }
        Task {
            _ = try? await request(["@type": "openStory", "story_poster_chat_id": story.posterChatId, "story_id": story.id])
            _ = try? await request(["@type": "closeStory", "story_poster_chat_id": story.posterChatId, "story_id": story.id])
        }
    }

    /// An answer to a story is a message in the private chat with its author, quoting the story.
    func reply(to story: StoryItem, text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return await perform([
            "@type": "sendMessage",
            "chat_id": story.posterChatId,
            "reply_to": ["@type": "inputMessageReplyToStory", "story_poster_chat_id": story.posterChatId, "story_id": story.id],
            "options": Self.sendOptions(),
            "input_message_content": TD.inputText(text, clearDraft: false, markup: true),
        ])
    }
}
