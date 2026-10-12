import AppKit
import Foundation

/// Files in and out: downloads, the pasteboard, storage, export, shared media and the security tools.
extension AppModel {
    // MARK: - files

    /// A file card appeared: its progress is followed from now on, starting from what TDLib already has.
    func follow(_ fileId: Int) async {
        guard !trackedFiles.contains(fileId) else { return }
        trackedFiles.insert(fileId)
        if let file = try? await request(["@type": "getFile", "file_id": fileId]) {
            let transfer = TD.transfer(file)
            if transfer.isDownloaded, !transfer.path.isEmpty { localPaths[fileId] = transfer.path }
            transfers[fileId] = transfer
        }
    }

    func download(_ fileId: Int) async {
        trackedFiles.insert(fileId)
        await perform(["@type": "downloadFile", "file_id": fileId, "priority": 24, "offset": 0, "limit": 0, "synchronous": false])
    }

    /// Stops a download, or an upload together with the message that was being sent.
    func cancelTransfer(of message: Message, fileId: Int) async {
        if message.isPending {
            await perform(["@type": "deleteMessages", "chat_id": message.chatId, "message_ids": [message.id], "revoke": true])
        } else {
            await perform(["@type": "cancelDownloadFile", "file_id": fileId, "only_if_pending": false])
        }
    }

    /// The local copy, downloading it first when needed.
    private func localURL(of fileId: Int) async -> URL? {
        guard let path = await localFile(id: fileId, priority: 32) else {
            fail("Не удалось скачать файл")
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    func open(_ document: DocumentInfo) async {
        guard let url = await localURL(of: document.fileId) else { return }
        if Preferences.isOn(Preferences.fileGuard),
           let warning = SecurityTools.fileWarning(for: document.name) ?? SecurityTools.contentWarning(at: url),
           !BotDialogs.ask("Открыть «\(document.name)»?", warning, action: "Открыть") {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ document: DocumentInfo) async {
        guard let url = await localURL(of: document.fileId) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Straight into Downloads under the file's own name ("name 2.pdf" when taken), then shown in Finder.
    func saveToDownloads(_ document: DocumentInfo) async {
        guard let source = await localURL(of: document.fileId),
              let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let name = document.name.replacingOccurrences(of: "/", with: "-")
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: target)
            showToast("Сохранено в «Загрузки»")
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            fail("Не удалось сохранить: \(error.localizedDescription)")
        }
    }

    func save(_ document: DocumentInfo, to destination: URL) async {
        guard let source = await localURL(of: document.fileId) else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            fail("Не удалось сохранить: \(error.localizedDescription)")
        }
    }

    // MARK: - shared media

    /// A page of a chat's photos, files or links, newest first. `from` is 0 for the first page and the
    /// `next` of the page before for the following ones; a `next` of 0 says there is nothing older.
    /// nil when the chat could not be asked at all — a person you have never talked to has no chat to search.
    func sharedMedia(_ kind: SharedMediaKind, in chatId: Int64, from messageId: Int64 = 0) async -> (messages: [Message], next: Int64)? {
        guard let found = try? await request([
            "@type": "searchChatMessages", "chat_id": chatId, "query": "", "from_message_id": messageId,
            "offset": 0, "limit": 60, "filter": ["@type": kind.filter],
        ]) else { return nil }
        return (found.tdNodes("messages").map { TD.message($0) }, found.tdInt64("next_from_message_id"))
    }

    /// Out of the profile and to the message in its chat.
    func showInChat(_ message: Message) {
        profile = nil
        open(message)
    }

    // MARK: - export

    struct ExportOptions {
        enum Chats: String, CaseIterable, Identifiable {
            case none = "Не выгружать"
            case personal = "Личные чаты"
            case personalAndGroups = "Личные и группы"
            case all = "Все, включая каналы"
            var id: String { rawValue }
        }

        var contacts = true
        var chats: Chats = .personal
        /// Newest messages per chat; 0 means the whole history.
        var messagesPerChat = 2000
    }

    /// A copy of the account's data in a folder you pick: profile, contacts, chats and their messages as JSON
    /// and HTML. Session keys and the TDLib database are never part of it.
    func exportAccount(to folder: URL, options: ExportOptions) {
        guard exportTask == nil, isReady else { return }
        exportTask = Task {
            await runExport(to: folder, options: options)
            exportTask = nil
            exportProgress = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func runExport(to folder: URL, options: ExportOptions) async {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " " +
            Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "ru_RU")))
                .replacingOccurrences(of: ":", with: "-")
        let root = folder.appendingPathComponent("Easy — экспорт \(stamp)", isDirectory: true)
        let files = FileManager.default
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)

            exportProgress = "Профиль…"
            let me = try await exportRequest(["@type": "getMe"])
            try ExportFormat.json(exportedUser(me)).write(to: root.appendingPathComponent("profile.json"))

            if options.contacts {
                exportProgress = "Контакты…"
                let ids = try await exportRequest(["@type": "getContacts"]).tdInt64s("user_ids")
                var contacts: [[String: String]] = []
                for (index, id) in ids.enumerated() {
                    try Task.checkCancellation()
                    if index % 20 == 0 { exportProgress = "Контакты: \(index) из \(ids.count)" }
                    if let user = try? await exportRequest(["@type": "getUser", "user_id": id]) {
                        contacts.append(exportedUser(user))
                    }
                }
                try ExportFormat.json(contacts).write(to: root.appendingPathComponent("contacts.json"))
            }

            let everyChat = knownChats.values.sorted { ($0.order, $0.id) > ($1.order, $1.id) }
            try ExportFormat.json(everyChat.map { chat in
                ["id": String(chat.id), "title": chat.title, "type": chat.kind.label]
            }).write(to: root.appendingPathComponent("chats.json"))

            let chosen = everyChat.filter { chat in
                switch options.chats {
                case .none: false
                case .personal: chat.kind == .personal
                case .personalAndGroups: chat.kind == .personal || chat.kind == .group
                case .all: true
                }
            }
            var index = "<!doctype html><html lang=\"ru\"><head><meta charset=\"utf-8\"><title>Экспорт</title></head><body style=\"font: 14px -apple-system, sans-serif; padding: 24px\"><h1>\(ExportFormat.escape(TD.displayName(ofUser: me)))</h1><ul>"
            let chatsFolder = root.appendingPathComponent("chats", isDirectory: true)
            for (number, chat) in chosen.enumerated() {
                try Task.checkCancellation()
                let title = chat.title.isEmpty ? "Без названия" : chat.title
                exportProgress = "Чат \(number + 1) из \(chosen.count): \(title)"
                let messages = try await exportHistory(of: chat, limit: options.messagesPerChat) { count in
                    self.exportProgress = "Чат \(number + 1) из \(chosen.count): \(title) — \(count)"
                }
                guard !messages.isEmpty else { continue }
                let name = ExportFormat.fileName(title, id: chat.id)
                let folder = chatsFolder.appendingPathComponent(name, isDirectory: true)
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                try ExportFormat.json(messages).write(to: folder.appendingPathComponent("messages.json"))
                try Data(ExportFormat.html(title: title, messages: messages).utf8).write(to: folder.appendingPathComponent("messages.html"))
                let link = "chats/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name) + "/messages.html"
                index += "<li><a href=\"\(link)\">\(ExportFormat.escape(title))</a> — \(messages.count)</li>"
            }
            index += "</ul></body></html>"
            try Data(index.utf8).write(to: root.appendingPathComponent("index.html"))
            lastExport = root
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } catch is CancellationError {
            // What was written so far stays; it is a valid, shorter export.
            lastExport = root
        } catch {
            fail(error)
        }
    }

    /// Newest first from TDLib, returned oldest first. Pages continue from the oldest message seen.
    private func exportHistory(of chat: Chat, limit: Int, progress: (Int) -> Void) async throws -> [ExportFormat.ExportedMessage] {
        var collected: [TDNode] = []
        var from: Int64 = 0
        var emptyPages = 0
        while limit == 0 || collected.count < limit {
            try Task.checkCancellation()
            let page = try await exportRequest([
                "@type": "getChatHistory", "chat_id": chat.id, "from_message_id": from,
                "offset": 0, "limit": 100, "only_local": false,
            ]).tdNodes("messages")
            // TDLib may answer with a short or empty page while it fetches from the server.
            if page.isEmpty {
                emptyPages += 1
                if emptyPages >= 2 { break }
                try await Task.sleep(for: .milliseconds(300))
                continue
            }
            emptyPages = 0
            collected += page
            // A page without a usable id would send the cursor back to 0, i.e. to the newest messages, and the
            // loop would fetch the same page forever while `collected` grows.
            guard let last = page.last?.tdInt64("id"), last != 0 else { break }
            from = last
            progress(collected.count)
        }
        if limit > 0, collected.count > limit { collected = Array(collected.prefix(limit)) }

        var result: [ExportFormat.ExportedMessage] = []
        for node in collected.reversed() {
            let message = TD.message(node)
            var forwarded: String?
            if message.isForwarded {
                forwarded = message.forwardSenderKey.isEmpty ? message.forwardSenderName : await exportName(of: message.forwardSenderKey)
            }
            var text = MessageArchive.text(of: message)
            if !message.caption.isEmpty, message.media != nil, !text.contains(message.caption) { text += "\n" + message.caption }
            result.append(ExportFormat.ExportedMessage(
                id: message.id,
                date: message.date,
                sender: message.isOutgoing ? "Вы" : await exportName(of: message.senderKey),
                isOutgoing: message.isOutgoing,
                text: text,
                replyToId: message.replyToId == 0 ? nil : message.replyToId,
                forwardedFrom: forwarded,
                edited: message.isEdited
            ))
        }
        return result
    }

    private func exportName(of key: String) async -> String {
        if let name = senderNames[key], !name.isEmpty { return name }
        guard let id = Int64(key.dropFirst()) else { return "" }
        if key.hasPrefix("u"), let user = try? await exportRequest(["@type": "getUser", "user_id": id]) {
            let name = TD.displayName(ofUser: user)
            remember(name, for: key)
            return name
        }
        if key.hasPrefix("c"), let chat = try? await exportRequest(["@type": "getChat", "chat_id": id]) {
            let name = chat.tdString("title")
            remember(name, for: key)
            return name
        }
        return ""
    }

    private func exportedUser(_ user: TDNode) -> [String: String] {
        var fields = ["id": String(user.tdInt64("id")), "name": TD.displayName(ofUser: user)]
        let usernames = (user.tdNode("usernames")?["active_usernames"] as? [String]) ?? []
        if !usernames.isEmpty { fields["username"] = usernames.map { "@" + $0 }.joined(separator: ", ") }
        let phone = user.tdString("phone_number")
        if !phone.isEmpty { fields["phone"] = "+" + phone }
        return fields
    }

    /// Exports make many requests; a flood wait is sat out instead of failing the whole export.
    private func exportRequest(_ payload: TDNode) async throws -> TDNode {
        // Flood waits are normal during a big export and the progress line says so, but a loop that only ever
        // waits looks exactly like a hung export. Twenty of them is an hour of patience.
        var waits = 0
        while true {
            do {
                return try await request(payload)
            } catch let error as TDError where error.isRateLimited {
                guard waits < 20 else { throw TDError(code: 429, message: "Telegram не отпускает запросы — экспорт прерван") }
                waits += 1
                let delay = min(error.retryAfter ?? 5, 120)
                exportProgress = "Telegram просит подождать \(Int(delay)) с…"
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    // MARK: - security

    /// A link clicked in a message: t.me stays in the app, anything suspicious is explained before it opens.
    func openMessageLink(_ url: URL, shownAs text: String? = nil) async {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        if scheme == "tg" || Self.telegramHosts.contains(host) {
            if await openTelegramLink(url.absoluteString) { return }
        }
        if Preferences.isOn(Preferences.linkGuard), ["http", "https"].contains(scheme) {
            let warnings = SecurityTools.linkWarnings(url, shownAs: text ?? SecurityTools.label(for: url))
            if !warnings.isEmpty {
                let list = warnings.map { "• " + $0 }.joined(separator: "\n")
                guard BotDialogs.ask("Подозрительная ссылка", "\(url.absoluteString)\n\n\(list)", action: "Всё равно открыть") else { return }
            }
        } else if !["http", "https", "mailto", "tel"].contains(scheme) {
            // file:, x-apple-… and other apps' schemes can do more than show a page.
            guard BotDialogs.ask("Открыть «\(scheme):»-ссылку?",
                                 "\(url.absoluteString)\n\nСсылка передаётся другому приложению на этом Mac.", action: "Открыть") else { return }
        }
        NSWorkspace.shared.open(url)
    }

    /// Indicators from one message or a selection, shown as a defanged report.
    func showIndicators(in messages: [Message]) {
        var text = messages.map { message -> String in
            var parts = [MessageArchive.text(of: message)]
            // Hidden links ("нажмите здесь") count as well.
            parts += message.entities.compactMap { entity -> String? in
                if case .link(let url) = entity.style { return url.absoluteString }
                return nil
            }
            if let preview = message.linkPreview { parts.append(preview.url.absoluteString) }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n")
        text += "\n" + messages.compactMap { $0.markup }.flatMap { $0.rows.joined() }.compactMap { button -> String? in
            if case .url(let url) = button.action { return url }
            return nil
        }.joined(separator: "\n")
        let found = SecurityTools.indicators(in: text)
        inspectedCode = InspectedCode(
            title: "Индикаторы (\(found.count)) · обезврежены",
            json: found.report(),
            isCode: true,
            indicators: found.isEmpty ? nil : found
        )
    }

    /// SHA-256 of an attachment, to look up in threat intelligence services.
    func showHash(of message: Message) async {
        guard let file = await downloadedFile(of: message) else { return }
        let hash = await Task.detached(priority: .userInitiated) { try? SecurityTools.sha256(of: file) }.value
        guard let hash else { return fail("Не удалось прочитать файл") }
        var lines = ["Файл: \(file.lastPathComponent)", "SHA-256: \(hash)"]
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            lines.append("Размер: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size) байт)")
        }
        if let warning = SecurityTools.fileWarning(for: file.lastPathComponent) { lines.append("⚠︎ " + warning) }
        if let warning = SecurityTools.contentWarning(at: file) { lines.append("⚠︎ " + warning) }
        inspectedCode = InspectedCode(title: "Хеш файла", json: lines.joined(separator: "\n"), isCode: true)
    }

    struct ActiveSession: Identifiable, Equatable {
        var id: Int64
        var isCurrent: Bool
        var isUnconfirmed: Bool
        var application: String
        var isOfficial: Bool
        var device: String
        var system: String
        var ipAddress: String
        var location: String
        var lastActive: Date
        var loggedIn: Date
    }

    func activeSessions() async -> [ActiveSession] {
        guard let result = try? await request(["@type": "getActiveSessions"]) else { return [] }
        return result.tdNodes("sessions").map { node in
            ActiveSession(
                id: node.tdInt64("id"),
                isCurrent: node.tdBool("is_current"),
                isUnconfirmed: node.tdBool("is_unconfirmed") || node.tdBool("is_password_pending"),
                application: "\(node.tdString("application_name")) \(node.tdString("application_version"))",
                isOfficial: node.tdBool("is_official_application"),
                device: node.tdString("device_model"),
                system: [node.tdString("platform"), node.tdString("system_version")].filter { !$0.isEmpty }.joined(separator: " "),
                ipAddress: node.tdString("ip_address"),
                location: node.tdString("location"),
                lastActive: Date(timeIntervalSince1970: TimeInterval(node.tdInt("last_active_date"))),
                loggedIn: Date(timeIntervalSince1970: TimeInterval(node.tdInt("log_in_date")))
            )
        }
        .sorted { ($0.isCurrent ? 1 : 0, $0.lastActive) > ($1.isCurrent ? 1 : 0, $1.lastActive) }
    }

    func terminateSession(_ id: Int64) async -> Bool {
        (try? await request(["@type": "terminateSession", "session_id": id])) != nil
    }

    func terminateOtherSessions() async -> Bool {
        (try? await request(["@type": "terminateAllOtherSessions"])) != nil
    }

    struct SecurityFinding: Identifiable, Equatable {
        enum Level { case good, advice, risk }
        let id = UUID()
        var level: Level
        var title: String
        var detail: String
    }

    /// Two-step verification and the privacy settings that matter most, with what to change.
    func securityAudit() async -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        /// A refused request is not a clean bill of health: an empty list used to read as "everything strict".
        var incomplete = false
        if let password = try? await request(["@type": "getPasswordState"]) {
            if password.tdBool("has_password") {
                findings.append(.init(level: .good, title: "Двухэтапная проверка включена",
                                      detail: password.tdBool("has_recovery_email_address")
                                          ? "Почта для восстановления задана." : "Почта для восстановления не задана: без неё забытый пароль не вернуть."))
            } else {
                findings.append(.init(level: .risk, title: "Двухэтапная проверка выключена",
                                      detail: "Любой, кто получит код из SMS, войдёт в аккаунт. Включите облачный пароль в официальном приложении: Настройки → Конфиденциальность."))
            }
            // Asked for by whoever holds a code from SMS: in a week the password is gone unless it is cancelled.
            let reset = password.tdInt("pending_reset_date")
            if reset > 0 {
                let day = Date(timeIntervalSince1970: TimeInterval(reset)).formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU")))
                findings.append(.init(level: .risk, title: "Запрошен сброс облачного пароля",
                                      detail: "Пароль будет снят \(day). Если это не вы — отмените сброс в официальном приложении и завершите чужие сеансы."))
            }
            if password.tdString("login_email_address_pattern").isEmpty {
                findings.append(.init(level: .advice, title: "Почта для входа не задана",
                                      detail: "С ней коды входа приходят на почту, а не по SMS: перехват SMS и перевыпуск SIM перестают давать доступ."))
            }
        } else {
            incomplete = true
        }
        if !hasPasscode {
            findings.append(.init(level: .advice, title: "Easy открывается без код-пароля",
                                  detail: "Любой, кто сел за этот Mac, читает переписку. Код-пароль задаётся выше; он же шифрует базу на диске."))
        }
        // Sessions nobody has used for a month, and apps that are not Telegram's own, are where a stolen
        // session hides.
        let sessions = await activeSessions().filter { !$0.isCurrent }
        let stale = sessions.filter { Date().timeIntervalSince($0.lastActive) > 30 * 86_400 }
        if !stale.isEmpty {
            findings.append(.init(level: .advice, title: "Сеансы без активности больше месяца: \(stale.count)",
                                  detail: stale.prefix(3).map { [$0.application, $0.device].filter { !$0.isEmpty }.joined(separator: " · ") }.joined(separator: "; ")
                                      + ". Ненужные стоит завершить в списке ниже."))
        }
        let unofficial = sessions.filter { !$0.isOfficial }
        if !unofficial.isEmpty {
            findings.append(.init(level: .advice, title: "Сеансы в сторонних приложениях: \(unofficial.count)",
                                  detail: unofficial.prefix(3).map(\.application).joined(separator: "; ")
                                      + ". Стороннее приложение видит всю переписку; оставьте только те, что ставили сами."))
        }
        if let ttl = try? await request(["@type": "getAccountTtl"]), ttl.tdInt("days") > 0 {
            findings.append(.init(level: .good, title: "Аккаунт удалится после \(TD.count(ttl.tdInt("days"), "дня", "дней", "дней")) без входов",
                                  detail: "Так задано в настройках Telegram: заброшенный аккаунт не остаётся висеть с вашими данными."))
        }
        let checks: [(String, String, SecurityFinding.Level)] = [
            ("userPrivacySettingShowPhoneNumber", "Номер телефона виден всем", .risk),
            ("userPrivacySettingAllowFindingByPhoneNumber", "Вас можно найти по номеру телефона", .advice),
            ("userPrivacySettingAllowChatInvites", "Кто угодно может добавить вас в группу", .advice),
            ("userPrivacySettingAllowCalls", "Звонить может кто угодно", .advice),
            ("userPrivacySettingAllowPeerToPeerCalls", "Звонки идут напрямую: собеседник видит ваш IP-адрес", .advice),
            ("userPrivacySettingShowLinkInForwardedMessages", "Пересланные сообщения ведут на ваш профиль", .advice),
            ("userPrivacySettingShowStatus", "Время последнего входа видно всем", .advice),
        ]
        await withTaskGroup(of: (Int, Bool, Bool).self) { group in
            for (index, check) in checks.enumerated() {
                group.addTask { @MainActor in
                    let rules = try? await self.request(["@type": "getUserPrivacySettingRules", "setting": ["@type": check.0]])
                    let open = rules?.tdNodes("rules").contains { $0.tdType == "userPrivacySettingRuleAllowAll" } ?? false
                    return (index, open, rules == nil)
                }
            }
            var open: [Int] = []
            for await (index, isOpen, failed) in group {
                if failed { incomplete = true } else if isOpen { open.append(index) }
            }
            for index in open.sorted() {
                let check = checks[index]
                findings.append(.init(level: check.2, title: check.1, detail: "Сейчас: «Все». Можно сузить до «Мои контакты» в официальном приложении."))
            }
        }
        if incomplete {
            findings.append(.init(level: .advice, title: "Проверка не полная",
                                  detail: "TDLib не ответил на часть запросов: 2FA и отдельные настройки могли остаться непроверенными."))
        } else if findings.allSatisfy({ $0.level == .good }) {
            findings.append(.init(level: .good, title: "Приватность настроена строго", detail: "Ничего важного не открыто для всех."))
        }
        return findings
    }

    // MARK: - pasteboard

    /// ⌘⇧V: files copied in Finder, or a copied picture saved as PNG, go to the send sheet of the open chat.
    func sendPasteboard(_ board: NSPasteboard = .general) async {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            offerFiles(urls)
            return
        }
        // PNG and JPEG go as they are; anything else (TIFF from Preview, PDF) is converted to PNG.
        let data: Data
        let fileExtension: String
        if let png = board.data(forType: .png) {
            (data, fileExtension) = (png, "png")
        } else if let jpeg = board.data(forType: Self.jpegType) {
            (data, fileExtension) = (jpeg, "jpg")
        } else if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            (data, fileExtension) = (png, "png")
        } else {
            fail("В буфере нет картинки или файла")
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftLite/pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        let file = folder.appendingPathComponent("Вставка \(stamp).\(fileExtension)")
        do {
            try data.write(to: file)
            offerFiles([file])
        } catch {
            fail(error)
        }
    }

    private nonisolated static let jpegType = NSPasteboard.PasteboardType("public.jpeg")

    /// Whether ⌘V should attach instead of pasting text: files copied in Finder, or a picture (a screenshot,
    /// "Copy Image" in a browser or Preview). Rich text, even with pictures inside, is text; so is plain text,
    /// unless it is only the address a browser adds next to a copied picture.
    nonisolated static func pasteboardHoldsAttachment(_ board: NSPasteboard = .general) -> Bool {
        let types = Set(board.types ?? [])
        if types.contains(.fileURL) { return true }
        guard types.contains(.png) || types.contains(.tiff) || types.contains(jpegType) else { return false }
        if types.contains(.rtf) || types.contains(.rtfd) { return false }
        guard types.contains(.string) else { return true }
        let text = (board.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("http") && !text.contains(" ") && !text.contains("\n")
    }

    /// Clicking a quote jumps to the original when it is loaded and flashes it.
    func focus(on messageId: Int64) {
        guard let rowId = rowIdByMessage[messageId] else { return }
        scrollTarget = rowId
        highlightedMessageId = rowId
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            // The row is what got highlighted: for an album, or a quote of an older member, it is not the
            // clicked message's own id, and comparing against that left the flash on forever.
            if highlightedMessageId == rowId { highlightedMessageId = nil }
        }
    }

    /// Shows an error from a view (a file that would not play, for example).
    func report(_ problem: String) {
        fail(problem)
    }

    /// Playing a video or voice message tells the sender it was played, unless ghost mode hides that too.
    func noteVideoMessagePlayed(_ message: Message) {
        guard !Preferences.isOn(Preferences.ghostMode), message.isSent, !message.isDeleted else { return }
        Task { _ = try? await request(["@type": "openMessageContent", "chat_id": message.chatId, "message_id": message.id]) }
    }

    func openAttachment(of message: Message) async {
        guard let file = await downloadedFile(of: message) else { return }
        if Preferences.isOn(Preferences.fileGuard),
           let warning = SecurityTools.fileWarning(for: file.lastPathComponent) ?? SecurityTools.contentWarning(at: file),
           !BotDialogs.ask("Открыть «\(file.lastPathComponent)»?", warning, action: "Открыть") {
            return
        }
        NSWorkspace.shared.open(file)
    }

    func saveAttachment(of message: Message, to destination: URL) async {
        guard let file = await downloadedFile(of: message) else { return }
        // Staged beside its target first: clearing the old file before the copy proved to work destroyed it
        // whenever the copy failed (full disk, another app holding the folder).
        let staging = destination.appendingPathExtension("part")
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.copyItem(at: file, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            fail(error)
        }
    }

    func name(for message: Message) -> String {
        if message.isOutgoing { return accountName.isEmpty ? "Вы" : accountName }
        if let cached = senderNames[message.senderKey], !cached.isEmpty { return cached }
        // Not `selectedChat`: that reads every chat, and each row would redraw on any chat's update.
        if message.senderKey.hasPrefix("c") { return "Канал" }
        return message.senderKey.isEmpty ? "" : "Пользователь"
    }

    func photo(for message: Message) -> ProfilePhoto? {
        senderPhotos[message.senderKey]
    }

    /// The picture of a user the client has already seen, for a contact card that names one.
    func photo(ofUser userId: Int64) -> ProfilePhoto? {
        senderPhotos["u\(userId)"]
    }

    /// The line under a chat's title: what someone is doing right now, otherwise last seen or member counts.
    func subtitle(for chat: Chat) -> String {
        if !chat.activity.isEmpty { return chat.activity }
        switch chat.kind {
        case .personal, .secret:
            // What stops a secret chat from working comes before when its owner was last seen.
            if chat.secretState == .pending { return "секретный чат · ждёт собеседника" }
            if chat.secretState == .closed { return "секретный чат закрыт" }
            if chat.userId == myUserId { return "заметки для себя" }
            if chat.isBot { return "бот" }
            return chat.presence.map { TD.describe($0) } ?? chat.kind.label
        case .group:
            guard chat.memberCount > 0 else { return chat.kind.label }
            let members = TD.count(chat.memberCount, "участник", "участника", "участников")
            return chat.onlineMemberCount > 1 ? "\(members), \(chat.onlineMemberCount) в сети" : members
        case .channel:
            guard chat.memberCount > 0 else { return chat.kind.label }
            return TD.count(chat.memberCount, "подписчик", "подписчика", "подписчиков")
        case .other:
            return chat.kind.label
        }
    }

    // MARK: - files

    /// Path of a file this session already has on disk.
    func downloadedPath(of fileId: Int) -> String? {
        localPaths[fileId]
    }

    /// Downloads a file once, however many views ask for it, and returns its local path.
    /// `knownPath` is where TDLib said the file already is; it is trusted only while the file exists.
    func localFile(id fileId: Int, knownPath: String = "", priority: Int) async -> String? {
        // TDLib's own cleanup removes old files; a remembered path is trusted only while the file is there.
        if let path = localPaths[fileId] {
            if FileManager.default.fileExists(atPath: path) { return path }
            localPaths[fileId] = nil
        }
        if !knownPath.isEmpty, FileManager.default.fileExists(atPath: knownPath) {
            localPaths[fileId] = knownPath
            return knownPath
        }
        // A waiter only borrows the task: taking the entry away here would let a late return drop a newer
        // download of the same file and start a second one.
        if let download = downloads[fileId] { return await download.task.value }

        let download = Download(Task { () -> String? in
            guard let file = try? await request([
                "@type": "downloadFile",
                "file_id": fileId,
                "priority": priority,
                "offset": 0,
                "limit": 0,
                "synchronous": true,
            ]) else { return nil }
            let local = file.tdNode("local") ?? [:]
            return local.tdBool("is_downloading_completed") && !local.tdString("path").isEmpty ? local.tdString("path") : nil
        })
        downloads[fileId] = download
        let path = await download.task.value
        // Only the task that still owns the entry keeps the result. A session reset cancels and empties these,
        // and TDLib reuses file ids between sessions, so a late return of the old task would otherwise clear the
        // new download and remember a path belonging to another account's files.
        guard downloads[fileId] === download else { return nil }
        downloads[fileId] = nil
        if let path { localPaths[fileId] = path }
        return path
    }

    // MARK: - developer view

    func inspect(_ message: Message) async {
        do {
            let node = try await request(["@type": "getMessage", "chat_id": message.chatId, "message_id": message.id])
            inspectedCode = InspectedCode(title: "Сообщение \(message.id) в чате \(message.chatId)", json: Self.prettyJSON(node), node: Self.cleaned(node))
        } catch {
            fail(error)
        }
    }

    func inspect(_ chat: Chat) async {
        do {
            let node = try await request(["@type": "getChat", "chat_id": chat.id])
            inspectedCode = InspectedCode(title: "Чат \(chat.id)", json: Self.prettyJSON(node), node: Self.cleaned(node))
        } catch {
            fail(error)
        }
    }

    /// Without the bridge's bookkeeping fields.
    private static func cleaned(_ node: TDNode) -> TDNode {
        var object = node
        object["@extra"] = nil
        object["@client_id"] = nil
        return object
    }

    private static func prettyJSON(_ node: TDNode) -> String {
        let object = cleaned(node)
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - storage

    func storageUsage() async -> StorageUsage? {
        guard let stats = try? await request(["@type": "getStorageStatisticsFast"]) else { return nil }
        return StorageUsage(
            files: stats.tdInt64("files_size"),
            fileCount: stats.tdInt("file_count"),
            database: stats.tdInt64("database_size")
        )
    }

    /// Deletes downloaded media (photos, stickers, attachments); messages stay in the database
    /// and files download again when needed. Without explicit types TDLib would keep avatars and stickers.
    func clearCache() async {
        let types = [
            "fileTypeAnimation", "fileTypeAudio", "fileTypeDocument", "fileTypePhoto", "fileTypePhotoStory",
            "fileTypeProfilePhoto", "fileTypeSticker", "fileTypeThumbnail", "fileTypeUnknown", "fileTypeVideo",
            "fileTypeVideoNote", "fileTypeVideoStory", "fileTypeVoiceNote", "fileTypeWallpaper",
        ]
        await perform([
            "@type": "optimizeStorage",
            "size": 0,
            "ttl": 0,
            "count": 0,
            "immunity_delay": 0,
            "file_types": types.map { ["@type": $0] },
            "chat_ids": [Any](),
            "exclude_chat_ids": [Any](),
            "return_deleted_file_statistics": false,
            "chat_limit": 0,
        ])
        localPaths = [:]
    }
}
