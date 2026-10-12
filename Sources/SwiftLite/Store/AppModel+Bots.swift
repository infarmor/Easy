import AppKit
import Foundation

/// Bots and everything they bring: keyboards, logins, t.me links and mini apps.
extension AppModel {
    // MARK: - bots

    private static func userId(ofSender key: String) -> Int64 {
        key.hasPrefix("u") ? Int64(key.dropFirst()) ?? 0 : 0
    }

    /// Buttons belong to the bot that sent the message, or to the one it was sent through.
    private func botUserId(of message: Message) -> Int64 {
        message.viaBotUserId != 0 ? message.viaBotUserId : Self.userId(ofSender: message.senderKey)
    }

    private func botName(_ userId: Int64) -> String {
        let name = senderNames["u\(userId)"] ?? ""
        return name.isEmpty ? "Бот" : name
    }

    /// Groups name the author of the last message in the list; private chats and channels need not.
    func snippetSender(of message: Message, in chat: Chat) -> String {
        guard chat.kind == .group, !message.isOutgoing, !message.isService,
              let name = senderNames[message.senderKey], !name.isEmpty else { return "" }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    /// A button under a bot's message.
    func press(_ button: BotButton, in message: Message) async {
        let bot = botUserId(of: message)
        switch button.action {
        case .callback(let data):
            let key = "\(message.id):\(button.id)"
            guard pendingButton != key else { return }
            pendingButton = key
            defer { if pendingButton == key { pendingButton = nil } }
            do {
                let answer = try await request([
                    "@type": "getCallbackQueryAnswer",
                    "chat_id": message.chatId,
                    "message_id": message.id,
                    "payload": ["@type": "callbackQueryPayloadData", "data": data],
                ])
                let text = answer.tdString("text")
                if !text.isEmpty {
                    if answer.tdBool("show_alert") { BotDialogs.notice(text, from: botName(bot)) } else { showToast(text) }
                }
                let url = answer.tdString("url")
                if !url.isEmpty { await openLink(url, confirming: true) }
            } catch let error as TDError where error.code == 502 || error.message.contains("TIMEOUT") {
                // The bot did not answer in time; the official apps stay silent as well.
            } catch {
                fail(error)
            }

        case .url(let url):
            await openLink(url, confirming: true)

        case .loginUrl(let url, let buttonId):
            await logIn(url: url, buttonId: buttonId, in: message)

        case .webApp(let url):
            await openWebApp(url: url, bot: bot, chatId: message.chatId)

        case .switchInline(let query, _):
            // The query goes into this chat's composer, where the bot's inline results take over.
            guard let username = await username(ofUser: bot) else { return }
            put("@\(username) \(query)", inComposerOf: message.chatId)

        case .user(let userId):
            await openPrivateChat(with: userId)

        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showToast("Скопировано")

        case .disabled:
            break

        case .text, .keyboardWebApp, .unsupported:
            showToast("Эта кнопка работает только в официальном приложении")
        }
    }

    /// A button of the keyboard in place of the composer.
    func press(keyboardButton button: BotButton) async {
        guard let chatId = openChatId else { return }
        switch button.action {
        case .text:
            if replyKeyboard?.isOneTime == true { isReplyKeyboardShown = false }
            await sendText(button.text, to: chatId)
        case .keyboardWebApp(let url):
            let bot = replyKeyboardBotId != 0 ? replyKeyboardBotId : (knownChats[chatId]?.userId ?? 0)
            guard bot != 0 else { return }
            do {
                let result = try await request([
                    "@type": "getWebAppUrl",
                    "bot_user_id": bot,
                    "url": url,
                    "parameters": webAppParameters(),
                ])
                show(result, launchId: 0, bot: bot, chatId: chatId, keyboardButtonText: button.text)
            } catch {
                fail(error)
            }
        default:
            showToast("Эта кнопка работает только в официальном приложении")
        }
    }

    /// Sends a keyboard label or a command as a plain message.
    func sendText(_ text: String, to chatId: Int64) async {
        if isViewingHistory { await showLatest() }
        do {
            _ = try await request([
                "@type": "sendMessage",
                "chat_id": chatId,
                "options": ["@type": "messageSendOptions", "disable_notification": false],
                "input_message_content": TD.inputText(text, clearDraft: false),
            ])
            await readAfterReplying(in: chatId)
        } catch {
            fail(error)
        }
    }

    /// "Запустить" in a bot chat that has no messages yet, or one opened through a start link.
    func startBot() async {
        guard let chatId = openChatId, let bot = knownChats[chatId]?.userId, bot != 0 else { return }
        let parameter = pendingBotStart ?? ""
        pendingBotStart = nil
        await perform(["@type": "sendBotStartMessage", "bot_user_id": bot, "chat_id": chatId, "parameter": parameter])
    }

    /// The menu button of a bot chat: its mini app.
    func openBotMenuApp() async {
        guard let menu = botMenu, !menu.appURL.isEmpty, let chatId = openChatId else { return }
        await openWebApp(url: menu.appURL, bot: menu.botUserId, chatId: chatId)
    }

    func loadBotControls(of chatId: Int64) async {
        guard let chat = knownChats[chatId] else { return }
        if chat.replyMarkupMessageId != 0,
           let node = try? await request(["@type": "getMessage", "chat_id": chatId, "message_id": chat.replyMarkupMessageId]),
           openChatId == chatId {
            adoptReplyKeyboard(TD.message(node))
        }
        guard chat.isBot, chat.userId != 0,
              let info = try? await request(["@type": "getUserFullInfo", "user_id": chat.userId]),
              openChatId == chatId, let bot = info.tdNode("bot_info") else { return }
        let button = bot.tdNode("menu_button")
        botMenu = BotMenu(
            botUserId: chat.userId,
            appTitle: button?.tdString("text") ?? "",
            appURL: button?.tdString("url") ?? "",
            commands: bot.tdNodes("commands").map {
                BotMenu.Command(command: $0.tdString("command"), description: $0.tdString("description"))
            }
        )
    }

    func adoptReplyKeyboard(_ message: Message?) {
        guard let message, let markup = message.markup, markup.kind == .keyboard, !markup.rows.isEmpty else {
            replyKeyboard = nil
            replyKeyboardBotId = 0
            return
        }
        if replyKeyboard != markup { isReplyKeyboardShown = true }
        replyKeyboard = markup
        replyKeyboardBotId = botUserId(of: message)
    }

    private func username(ofUser userId: Int64) async -> String? {
        guard let user = try? await request(["@type": "getUser", "user_id": userId]) else { return nil }
        let names = user.tdNode("usernames")?["active_usernames"] as? [String]
        return names?.first
    }

    func openPrivateChat(with userId: Int64) async {
        guard let chat = try? await request(["@type": "createPrivateChat", "user_id": userId, "force": false]) else { return }
        selection = chat.tdInt64("id")
    }

    // MARK: - log in with Telegram

    private func logIn(url: String, buttonId: Int64, in message: Message) async {
        do {
            let info = try await request([
                "@type": "getLoginUrlInfo", "chat_id": message.chatId, "message_id": message.id, "button_id": buttonId,
            ])
            switch info.tdType {
            case "loginUrlInfoOpen":
                await openLink(info.tdString("url"), confirming: !info.tdBool("skip_confirmation"))
            case "loginUrlInfoRequestConfirmation":
                let bot = info.tdInt64("bot_user_id")
                switch BotDialogs.confirmLogin(domain: info.tdString("domain"), bot: botName(bot),
                                               requestsWriting: info.tdBool("request_write_access")) {
                case .logIn(let allowWriting):
                    let result = try await request([
                        "@type": "getLoginUrl", "chat_id": message.chatId, "message_id": message.id,
                        "button_id": buttonId, "allow_write_access": allowWriting,
                    ])
                    await openLink(result.tdString("url"), confirming: false)
                case .openOnly:
                    await openLink(info.tdString("url"), confirming: false)
                case .cancel:
                    break
                }
            default:
                await openLink(url, confirming: true)
            }
        } catch {
            // No login info: the button still works as a plain link.
            await openLink(url, confirming: true)
        }
    }

    // MARK: - links

    static let telegramHosts: Set<String> = ["t.me", "telegram.me", "telegram.dog", "www.t.me"]

    /// Web links go to the browser; t.me and tg: links stay in the app when it can show them.
    func openLink(_ link: String, confirming: Bool) async {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return }
        let host = url.host?.lowercased() ?? ""
        if scheme == "tg" || Self.telegramHosts.contains(host) {
            if await openTelegramLink(link) { return }
        }
        guard ["http", "https", "mailto"].contains(scheme) else { return }
        if confirming, !BotDialogs.confirmOpening(link) { return }
        NSWorkspace.shared.open(url)
    }

    /// Chats, bots, messages and mini apps from t.me links. False for kinds left to the browser.
    @discardableResult
    func openTelegramLink(_ link: String) async -> Bool {
        guard let type = try? await request(["@type": "getInternalLinkType", "link": link]) else { return false }
        switch type.tdType {
        case "internalLinkTypePublicChat":
            guard let chatId = await publicChatId(type.tdString("chat_username")) else { return false }
            if type.tdBool("open_profile"), let chat = knownChats[chatId] {
                await showProfile(of: chat)
                return true
            }
            let text = type.tdString("draft_text")
            if text.isEmpty { selection = chatId } else { put(text, inComposerOf: chatId) }
            return true

        case "internalLinkTypeChatInvite":
            return await join(inviteLink: type.tdString("invite_link"))

        case "internalLinkTypeBotStart":
            guard let chatId = await publicChatId(type.tdString("bot_username")) else { return false }
            selection = chatId
            // The official apps also wait for "Запустить": opening a link never talks to the bot by itself.
            if openChatId == chatId {
                pendingBotStart = type.tdString("start_parameter")
            } else {
                startParameters[chatId] = type.tdString("start_parameter")
            }
            return true

        case "internalLinkTypeMainWebApp":
            guard let chatId = await publicChatId(type.tdString("bot_username")),
                  let bot = knownChats[chatId]?.userId, bot != 0 else { return false }
            do {
                let app = try await request([
                    "@type": "getMainWebApp",
                    "chat_id": openChatId ?? chatId,
                    "bot_user_id": bot,
                    "start_parameter": type.tdString("start_parameter"),
                    "parameters": webAppParameters(),
                ])
                show(app, launchId: 0, bot: bot, chatId: openChatId ?? chatId)
            } catch {
                fail(error)
            }
            return true

        case "internalLinkTypeWebApp":
            guard let chatId = await publicChatId(type.tdString("bot_username")),
                  let bot = knownChats[chatId]?.userId, bot != 0 else { return false }
            do {
                let found = try await request([
                    "@type": "searchWebApp", "bot_user_id": bot, "web_app_short_name": type.tdString("web_app_short_name"),
                ])
                var allowWriting = false
                if found.tdBool("request_write_access") {
                    allowWriting = BotDialogs.ask("Разрешить \(botName(bot)) писать вам?",
                                                  "Приложение просит права присылать вам сообщения.", action: "Разрешить")
                }
                let url = try await request([
                    "@type": "getWebAppLinkUrl",
                    "chat_id": openChatId ?? chatId,
                    "bot_user_id": bot,
                    "web_app_short_name": type.tdString("web_app_short_name"),
                    "start_parameter": type.tdString("start_parameter"),
                    "allow_write_access": allowWriting,
                    "parameters": webAppParameters(),
                ])
                show(url, launchId: 0, bot: bot, chatId: openChatId ?? chatId)
            } catch {
                fail(error)
            }
            return true

        case "internalLinkTypeMessage":
            guard let info = try? await request(["@type": "getMessageLinkInfo", "url": link]),
                  let node = info.tdNode("message") else { return false }
            open(TD.message(node))
            return true

        default:
            return false
        }
    }

    /// Opens a chat with text in its composer, whether or not the chat is open already.
    private func put(_ text: String, inComposerOf chatId: Int64) {
        if openChatId == chatId {
            quietDraft = text
            draft = text
        } else {
            pendingDrafts[chatId] = text
            selection = chatId
        }
    }

    /// t.me/+… links: a chat you are in opens, otherwise its name and size are shown before joining.
    private func join(inviteLink link: String) async -> Bool {
        guard let info = try? await request(["@type": "checkChatInviteLink", "invite_link": link]) else { return false }
        // Already a member: the chat is in the list, so it just opens.
        let known = info.tdInt64("chat_id")
        if known != 0, let chat = knownChats[known], chat.order != 0 || chat.isArchived {
            selection = known
            return true
        }
        let members = info.tdInt("member_count")
        let kind = info.tdNode("type")?.tdType == "inviteLinkChatTypeChannel" ? "канал" : "группу"
        let details = [members > 0 ? TD.count(members, "участник", "участника", "участников") : "",
                       info.tdString("description")].filter { !$0.isEmpty }.joined(separator: "\n")
        guard BotDialogs.ask("Вступить в \(kind) «\(info.tdString("title"))»?", details,
                             action: info.tdBool("creates_join_request") ? "Подать заявку" : "Вступить") else { return true }
        do {
            let chat = try await request(["@type": "joinChatByInviteLink", "invite_link": link])
            if chat.tdInt64("id") != 0 { selection = chat.tdInt64("id") }
        } catch let error as TDError where error.message.contains("INVITE_REQUEST_SENT") {
            showToast("Заявка отправлена")
        } catch {
            fail(error)
        }
        return true
    }

    private func publicChatId(_ username: String) async -> Int64? {
        guard !username.isEmpty,
              let chat = try? await request(["@type": "searchPublicChat", "username": username]) else { return nil }
        return chat.tdInt64("id")
    }

    // MARK: - mini apps

    private func webAppParameters() -> TDNode {
        [
            "@type": "webAppOpenParameters",
            "theme": WebAppTheme.parameters(dark: WebAppTheme.isDark),
            "application_name": "Easy",
            "mode": ["@type": "webAppOpenModeFullSize"],
        ]
    }

    func openWebApp(url: String, bot: Int64, chatId: Int64) async {
        guard bot != 0 else { return }
        do {
            let info = try await request([
                "@type": "openWebApp",
                "chat_id": chatId,
                "bot_user_id": bot,
                "url": url,
                "parameters": webAppParameters(),
            ])
            show(info, launchId: info.tdInt64("launch_id"), bot: bot, chatId: chatId)
        } catch {
            fail(error)
        }
    }

    /// `webAppInfo`, `mainWebApp` and `webAppUrl` all carry a `webAppUrl`, directly or under `url`.
    private func show(_ node: TDNode, launchId: Int64, bot: Int64, chatId: Int64, keyboardButtonText: String? = nil) {
        let link = node.tdType == "webAppUrl" ? node : (node.tdNode("url") ?? [:])
        guard let url = URL(string: link.tdString("url")) else { return }
        closeWebApp()
        webApp = WebAppSession(
            launchId: launchId,
            chatId: chatId,
            botUserId: bot,
            botName: botName(bot),
            url: url,
            requiresSameOrigin: link.tdBool("require_same_origin"),
            keyboardButtonText: keyboardButtonText
        )
    }

    /// The window was closed, or the app asked to close.
    func closeWebApp() {
        guard let session = webApp else { return }
        webApp = nil
        if session.launchId != 0 {
            Task { _ = try? await request(["@type": "closeWebApp", "web_app_launch_id": session.launchId]) }
        }
    }

    /// `Telegram.WebApp.sendData` from an app opened by a keyboard button; the app closes after it.
    func sendWebAppData(_ data: String, from session: WebAppSession) async {
        guard let label = session.keyboardButtonText else { return }
        await perform(["@type": "sendWebAppData", "bot_user_id": session.botUserId, "button_text": label, "data": data])
        closeWebApp()
    }

    /// CloudStorage and the bot's own methods. TDLib calls this `sendWebAppCustomRequest`; the name the Bot
    /// API uses is not a TDLib request, and the answer is a JSON string in `result`.
    func invokeCustomMethod(_ method: String, parameters: String, for session: WebAppSession) async throws -> String {
        let result = try await request([
            "@type": "sendWebAppCustomRequest",
            "bot_user_id": session.botUserId,
            "method": method,
            "parameters": parameters,
        ])
        return result.tdString("result")
    }

    /// Whether the bot really offers this file at this address; Telegram's servers know, the page only claims.
    func webAppOffers(_ fileName: String, at url: String, for session: WebAppSession) async -> Bool {
        (try? await request(["@type": "checkWebAppFileDownload", "bot_user_id": session.botUserId,
                             "file_name": fileName, "url": url])) != nil
    }

    func allowMessages(from session: WebAppSession) async -> Bool {
        (try? await request(["@type": "allowBotToSendMessages", "bot_user_id": session.botUserId])) != nil
    }

    func sharePhoneNumber(with session: WebAppSession) async -> Bool {
        (try? await request(["@type": "sharePhoneNumber", "user_id": session.botUserId])) != nil
    }

    /// `switchInlineQuery` from a mini app: "@bot query" in the composer of the chat it was opened from.
    func insertInlineQuery(_ query: String, from session: WebAppSession) async {
        guard let username = await username(ofUser: session.botUserId) else { return }
        put("@\(username) \(query)", inComposerOf: session.chatId)
        closeWebApp()
    }
}
