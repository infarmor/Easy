import AppKit
import SwiftUI
import WebKit

/// The mini app window. It shows whatever `AppModel.webApp` holds and closes when that goes away.
struct WebAppWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session = model.webApp {
                WebAppScreen(session: session)
                    .id(session.id)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 520, idealHeight: 720)
        .onChange(of: model.webApp == nil) { _, isGone in
            if isGone { dismissWindow(id: WebAppWindow.id) }
        }
        // Opened from the Window menu with nothing to show: nothing to keep open.
        .onAppear { if model.webApp == nil { dismissWindow(id: WebAppWindow.id) } }
        // Closing the window ends the session in TDLib too.
        .onDisappear { model.closeWebApp() }
    }

    static let id = "webapp"
}

/// Owns the bridge. SwiftUI may build this view's value many times; the bridge (and its web view, which
/// starts loading the app) is created once, when the view first appears.
private struct WebAppScreen: View {
    @Environment(AppModel.self) private var model
    let session: WebAppSession
    @State private var bridge: WebAppBridge?

    var body: some View {
        Group {
            if let bridge {
                WebAppContent(bridge: bridge)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard bridge == nil else { return }
            let created = WebAppBridge(session: session)
            created.model = model
            created.start()
            bridge = created
        }
    }
}

private struct WebAppContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let bridge: WebAppBridge

    var body: some View {
        VStack(spacing: 0) {
            WebAppWebView(bridge: bridge)
                .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { _, size in
                    bridge.reportViewport(size)
                }
                .overlay {
                    if bridge.isLoading {
                        ProgressView().controlSize(.large)
                    }
                }
            if bridge.mainButton.isVisible || bridge.secondaryButton.isVisible {
                bottomBar
            }
        }
        .background(bridge.backgroundColor ?? Color(nsColor: .windowBackgroundColor))
        .navigationTitle(bridge.session.botName)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if bridge.isBackButtonVisible {
                    Button { bridge.send("back_button_pressed") } label: { Image(systemName: "chevron.left") }
                        .help("Назад")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Обновить") { bridge.reload() }
                    if bridge.isSettingsButtonVisible {
                        Button("Настройки") { bridge.send("settings_button_pressed") }
                    }
                    Divider()
                    Button("Закрыть") { model.closeWebApp() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Ещё")
            }
        }
        .onChange(of: colorScheme) { _, scheme in bridge.sendTheme(dark: scheme == .dark) }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if bridge.secondaryButton.isVisible {
                button(bridge.secondaryButton, event: "secondary_button_pressed")
            }
            if bridge.mainButton.isVisible {
                button(bridge.mainButton, event: "main_button_pressed")
            }
        }
        .padding(10)
        .background(bridge.bottomBarColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.thinMaterial))
    }

    private func button(_ state: WebAppBridge.BottomButton, event: String) -> some View {
        Button {
            bridge.send(event)
        } label: {
            ZStack {
                if state.isProgressVisible {
                    ProgressView().controlSize(.small).tint(state.textColor ?? .white)
                } else {
                    Text(state.text)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(state.textColor ?? .white)
            .background(state.color ?? .accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(state.isActive ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!state.isActive)
    }
}

private struct WebAppWebView: NSViewRepresentable {
    let bridge: WebAppBridge

    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Speaks the protocol of telegram-web-app.js: the page posts events through `TelegramWebviewProxy.postEvent`,
/// answers go back through `Telegram.WebView.receiveEvent`.
@MainActor
@Observable
final class WebAppBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    struct BottomButton {
        var isVisible = false
        var isActive = true
        var isProgressVisible = false
        var text = ""
        var color: Color?
        var textColor: Color?
    }

    let session: WebAppSession
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored let webView: WKWebView

    private(set) var isLoading = true
    private(set) var mainButton = BottomButton()
    private(set) var secondaryButton = BottomButton()
    private(set) var isBackButtonVisible = false
    private(set) var isSettingsButtonVisible = false
    private(set) var backgroundColor: Color?
    private(set) var bottomBarColor: Color?

    /// Origins ("https://host:443") whose pages may act for the bot: the address the app was opened at, and
    /// the page that address first lands on. A mini app can take its window anywhere — a link, a redirect, an
    /// ad — and whatever page ends up there finds the same `TelegramWebviewProxy`. Without this list that page
    /// could read the bot's stored values, call its methods and send it data as though it were the app.
    @ObservationIgnored private var trustedOrigins: Set<String> = []
    @ObservationIgnored private var hasCommittedFirstPage = false

    /// Events that touch the account, the bot's data or the disk. Buttons, colours and the viewport are left
    /// to any page: they change nothing outside the window.
    private static let privileged: Set<String> = [
        "web_app_data_send", "web_app_switch_inline_query", "web_app_invoke_custom_method",
        "web_app_request_write_access", "web_app_request_phone", "web_app_read_text_from_clipboard",
        "web_app_request_file_download", "web_app_request_emoji_status_access", "web_app_set_emoji_status",
        "web_app_open_tg_link", "web_app_open_invoice", "web_app_request_chat", "web_app_send_prepared_message",
    ]

    private static func isPrivileged(_ event: String) -> Bool {
        privileged.contains(event) || event.hasPrefix("web_app_device_storage_") || event.hasPrefix("web_app_secure_storage_")
    }

    private static func origin(scheme: String?, host: String?, port: Int?) -> String? {
        guard let scheme = scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = host?.lowercased(), !host.isEmpty else { return nil }
        let effective = (port ?? 0) > 0 ? port! : (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(effective)"
    }

    init(session: WebAppSession) {
        self.session = session
        let configuration = WKWebViewConfiguration()
        // Ephemeral: a bot's mini app must not leave cookies and localStorage in the container once its window
        // is closed — nothing here ever clears the shared store otherwise.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let script = """
        window.TelegramWebviewProxy = {
          postEvent: function (eventType, eventData) {
            window.webkit.messageHandlers.telegram.postMessage([String(eventType), eventData == null ? "" : String(eventData)]);
          }
        };
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = Preferences.isOn(Preferences.showMessageCode)
        webView.underPageBackgroundColor = .windowBackgroundColor
        super.init()
        if let origin = Self.origin(scheme: session.url.scheme, host: session.url.host, port: session.url.port) {
            trustedOrigins.insert(origin)
        }
        // The content controller keeps its handler alive; the weak box breaks the cycle with the bridge.
        configuration.userContentController.add(WeakScriptHandler(self), name: "telegram")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Loading starts only once the bridge is wired to the model, so no early event is lost.
    func start() {
        webView.load(URLRequest(url: session.url))
    }

    func reload() {
        isLoading = true
        webView.load(URLRequest(url: session.url))
    }

    // MARK: - to the page

    func send(_ event: String, _ data: [String: Any] = [:]) {
        guard let json = try? JSONSerialization.data(withJSONObject: data),
              let payload = String(data: json, encoding: .utf8),
              let name = try? JSONSerialization.data(withJSONObject: [event]),
              let quoted = String(data: name, encoding: .utf8)?.dropFirst().dropLast() else { return }
        let script = "window.Telegram && window.Telegram.WebView && window.Telegram.WebView.receiveEvent(\(quoted), \(payload));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func sendTheme(dark: Bool) {
        send("theme_changed", ["theme_params": WebAppTheme.css(dark: dark)])
    }

    private func sendViewport() {
        reportViewport(webView.bounds.size)
    }

    /// The size the page is actually drawn at. Without it a resized window keeps the viewport it was opened
    /// with, and the page leaves a blank strip where the extra height went.
    func reportViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        send("viewport_changed", ["height": size.height, "width": size.width,
                                  "is_expanded": true, "is_state_stable": true])
    }

    // MARK: - from the page

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit calls script handlers on the main thread.
        MainActor.assumeIsolated {
            guard let parts = message.body as? [String], parts.count == 2, fromBridgePage(message) else { return }
            // A page of another origin in the app's window keeps its buttons and nothing more.
            guard !Self.isPrivileged(parts[0]) || fromTrustedOrigin(message) else { return }
            handle(parts[0], parts[1])
        }
    }

    /// `window.webkit.messageHandlers` exists in every frame, so without this an iframe of another origin inside
    /// a mini app could hand data to the bot, invoke its custom method or ask for your phone number as though it
    /// were the app. The proxy script goes into the main frame only; the messages must come from there too.
    private func fromBridgePage(_ message: WKScriptMessage) -> Bool {
        guard message.frameInfo.isMainFrame else { return false }
        guard session.requiresSameOrigin, let host = session.url.host else { return true }
        let origin = message.frameInfo.securityOrigin
        // The host alone is not enough: the same name served over http, or on another port, is a page that
        // must not be able to hand data to the bot or ask for your phone number.
        let scheme = session.url.scheme?.lowercased() ?? "https"
        let port = session.url.port ?? (scheme == "https" ? 443 : 80)
        return origin.host.lowercased() == host.lowercased()
            && origin.protocol.lowercased() == scheme
            && origin.port == port
    }

    private func fromTrustedOrigin(_ message: WKScriptMessage) -> Bool {
        let origin = message.frameInfo.securityOrigin
        guard let key = Self.origin(scheme: origin.protocol, host: origin.host, port: origin.port) else { return false }
        return trustedOrigins.contains(key)
    }

    private func handle(_ event: String, _ raw: String) {
        let data = (raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        func string(_ key: String) -> String { data[key] as? String ?? "" }

        switch event {
        case "web_app_ready":
            isLoading = false
        case "web_app_close":
            model?.closeWebApp()
        case "web_app_expand", "iframe_ready", "iframe_will_reload":
            break
        case "web_app_request_viewport":
            sendViewport()
        case "web_app_request_theme":
            sendTheme(dark: WebAppTheme.isDark)
        case "web_app_request_safe_area":
            send("safe_area_changed", ["top": 0, "bottom": 0, "left": 0, "right": 0])
        case "web_app_request_content_safe_area":
            send("content_safe_area_changed", ["top": 0, "bottom": 0, "left": 0, "right": 0])

        case "web_app_setup_main_button":
            mainButton = bottomButton(from: data)
        case "web_app_setup_secondary_button":
            secondaryButton = bottomButton(from: data)
        case "web_app_setup_back_button":
            isBackButtonVisible = data["is_visible"] as? Bool ?? false
        case "web_app_setup_settings_button":
            isSettingsButtonVisible = data["is_visible"] as? Bool ?? false
        case "web_app_set_background_color":
            backgroundColor = Self.color(string("color"))
        case "web_app_set_bottom_bar_color":
            bottomBarColor = Self.color(string("color"))
        case "web_app_set_header_color", "web_app_setup_closing_behavior", "web_app_setup_swipe_behavior",
             "web_app_toggle_orientation_lock":
            break

        case "web_app_trigger_haptic_feedback":
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)

        case "web_app_open_link":
            guard let url = URL(string: string("url")), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            // A mini app is third-party content: it goes through the same confirmation the transcripts use.
            Task { await model?.openLink(url.absoluteString, confirming: true) }
        case "web_app_open_tg_link":
            let path = string("path_full")
            guard path.hasPrefix("/") else { return }
            Task { await model?.openLink("https://t.me" + path, confirming: false) }

        case "web_app_open_popup":
            let buttons = (data["buttons"] as? [[String: Any]]) ?? []
            let chosen = popup(title: string("title"), message: string("message"), buttons: buttons)
            send("popup_closed", chosen.map { ["button_id": $0] } ?? [:])
        case "web_app_open_scan_qr_popup":
            send("scan_qr_popup_closed")

        case "web_app_data_send":
            Task { await model?.sendWebAppData(string("data"), from: session) }
        case "web_app_switch_inline_query":
            Task { await model?.insertInlineQuery(string("query"), from: session) }
        case "web_app_invoke_custom_method":
            let requestId = string("req_id")
            let parameters = data["params"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            Task {
                guard let model else { return }
                do {
                    let result = try await model.invokeCustomMethod(string("method"), parameters: parameters, for: session)
                    let value = result.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
                    send("custom_method_invoked", ["req_id": requestId, "result": value ?? NSNull()])
                } catch {
                    send("custom_method_invoked", ["req_id": requestId, "error": (error as? TDError)?.message ?? "UNKNOWN_ERROR"])
                }
            }
        case "web_app_request_write_access":
            let allowed = BotDialogs.ask("Разрешить \(session.botName) писать вам?",
                                         "Бот сможет присылать вам сообщения.", action: "Разрешить")
            Task {
                let done = allowed ? await model?.allowMessages(from: session) ?? false : false
                send("write_access_requested", ["status": done ? "allowed" : "cancelled"])
            }
        case "web_app_request_phone":
            let allowed = BotDialogs.ask("Поделиться номером телефона?",
                                         "\(session.botName) получит ваш номер телефона.", action: "Поделиться")
            Task {
                let done = allowed ? await model?.sharePhoneNumber(with: session) ?? false : false
                send("phone_requested", ["status": done ? "sent" : "cancelled"])
            }
        case "web_app_read_text_from_clipboard":
            // The pasteboard is private; the official apps only give it to a few attachment-menu bots.
            send("clipboard_text_received", ["req_id": string("req_id")])
        case "web_app_request_file_download":
            download(string("url"), name: string("file_name"))

        // DeviceStorage: values the page wants to keep between launches. Its own storage is ephemeral here,
        // so this file is the only thing that survives the window.
        case "web_app_device_storage_get_key":
            let key = string("key")
            let value = key.isEmpty ? nil : WebAppStorage.values(for: session)[key]
            send("device_storage_key_received", ["req_id": string("req_id"), "value": value ?? NSNull()])
        case "web_app_device_storage_save_key":
            let requestId = string("req_id")
            // A key sent with a null value is how the page removes it.
            let value: String?
            switch data["value"] {
            case let text as String: value = text
            case is NSNull: value = nil
            default:
                send("device_storage_failed", ["req_id": requestId, "error": WebAppStorage.Failure.invalid.rawValue])
                return
            }
            switch WebAppStorage.set(value, forKey: string("key"), for: session) {
            case .success: send("device_storage_key_saved", ["req_id": requestId])
            case .failure(let failure): send("device_storage_failed", ["req_id": requestId, "error": failure.rawValue])
            }
        case "web_app_device_storage_clear":
            WebAppStorage.clear(session)
            send("device_storage_cleared", ["req_id": string("req_id")])

        // Fullscreen is the mini app's own window going fullscreen; the page learns the state that holds.
        case "web_app_request_fullscreen":
            Task { await setFullscreen(true) }
        case "web_app_exit_fullscreen":
            Task { await setFullscreen(false) }

        // A status emoji is public: it shows in your profile to everyone, so it is never set without asking.
        case "web_app_request_emoji_status_access":
            let allowed = BotDialogs.ask("Разрешить \(session.botName) менять статус-эмодзи?",
                                         "Его увидят все, кто откроет ваш профиль.", action: "Разрешить")
            send("emoji_status_access_requested", ["status": allowed ? "allowed" : "cancelled"])
        case "web_app_set_emoji_status":
            let customEmojiId = Int64(string("custom_emoji_id")) ?? 0
            let seconds = (data["duration"] as? NSNumber)?.intValue ?? 0
            guard customEmojiId != 0 else {
                send("emoji_status_failed", ["error": WebAppStorage.Failure.invalid.rawValue])
                return
            }
            guard BotDialogs.ask("Поставить статус-эмодзи?",
                                 "\(session.botName) предлагает показать этот эмодзи в вашем профиле.",
                                 action: "Поставить") else {
                send("emoji_status_failed", ["error": "CANCELLED"])
                return
            }
            Task {
                do {
                    try await model?.setEmojiStatus(customEmojiId: customEmojiId, for: seconds)
                    send("emoji_status_set")
                } catch {
                    send("emoji_status_failed", ["error": (error as? TDError)?.message ?? "UNKNOWN_ERROR"])
                }
            }

        // Things a desktop window cannot do: the page is told so instead of waiting forever.
        case "web_app_open_invoice":
            model?.showToast("Оплата доступна только в официальном приложении")
            send("invoice_closed", ["slug": string("slug"), "status": "failed"])
        case "web_app_biometry_get_info":
            send("biometry_info_received", ["available": false])
        case "web_app_check_location":
            send("location_checked", ["available": false])
        case "web_app_request_location":
            send("location_requested", ["available": false])
        case "web_app_check_home_screen":
            send("home_screen_checked", ["status": "unsupported"])
        case "web_app_add_to_home_screen":
            // There is no home screen on macOS to add a shortcut to.
            send("home_screen_checked", ["status": "unsupported"])
        case "web_app_request_chat":
            send("requested_chat_failed", ["req_id": string("req_id"), "error": "UNSUPPORTED"])
        case "web_app_send_prepared_message":
            // A prepared message is a bot's own message id; TDLib gives no way to look one up by it.
            send("prepared_message_failed", ["error": "UNSUPPORTED"])
        case "web_app_start_accelerometer":
            send("accelerometer_failed", ["error": "UNSUPPORTED"])
        case "web_app_start_gyroscope":
            send("gyroscope_failed", ["error": "UNSUPPORTED"])
        case "web_app_start_device_orientation":
            // A Mac has no motion sensors a window may read, so all three stay refused.
            send("device_orientation_failed", ["error": "UNSUPPORTED"])
        case let name where name.hasPrefix("web_app_device_storage_"):
            send("device_storage_failed", ["req_id": string("req_id"), "error": "UNSUPPORTED"])
        case let name where name.hasPrefix("web_app_secure_storage_"):
            // Needs the bot's storage secret, which TDLib does not hand to a client at all.
            send("secure_storage_failed", ["req_id": string("req_id"), "error": "UNSUPPORTED"])
        default:
            break
        }
    }

    /// Asks the window to enter or leave fullscreen and reports the state that actually holds. The style mask
    /// is only true once the transition finished, so the answer waits for the notification.
    private func setFullscreen(_ wantsFullscreen: Bool) async {
        // A window without a title bar cannot go fullscreen, and the transition would never report back.
        guard let window = webView.window, window.styleMask.contains(.titled) else {
            send("fullscreen_failed", ["error": "UNSUPPORTED"])
            return
        }
        let isFullscreen = window.styleMask.contains(.fullScreen)
        guard isFullscreen != wantsFullscreen else {
            send("fullscreen_failed", ["error": wantsFullscreen ? "ALREADY_FULLSCREEN" : "NOT_FULLSCREEN"])
            return
        }
        await window.transitionFullScreen()
        send("fullscreen_changed", ["is_fullscreen": window.styleMask.contains(.fullScreen)])
    }

    private func bottomButton(from data: [String: Any]) -> BottomButton {
        BottomButton(
            isVisible: (data["is_visible"] as? Bool ?? false) && !((data["text"] as? String ?? "").isEmpty),
            isActive: data["is_active"] as? Bool ?? true,
            isProgressVisible: data["is_progress_visible"] as? Bool ?? false,
            text: data["text"] as? String ?? "",
            color: Self.color(data["color"] as? String ?? ""),
            textColor: Self.color(data["text_color"] as? String ?? "")
        )
    }

    private func popup(title: String, message: String, buttons: [[String: Any]]) -> String? {
        let alert = NSAlert()
        alert.messageText = title.isEmpty ? session.botName : title
        alert.informativeText = message
        let shown = buttons.prefix(3)
        for button in shown {
            let text: String
            switch button["type"] as? String {
            case "ok": text = "OK"
            case "close": text = "Закрыть"
            case "cancel": text = "Отмена"
            default: text = button["text"] as? String ?? ""
            }
            let added = alert.addButton(withTitle: text.isEmpty ? "OK" : text)
            added.hasDestructiveAction = button["type"] as? String == "destructive"
        }
        if shown.isEmpty { alert.addButton(withTitle: "Закрыть") }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard shown.indices.contains(index) else { return nil }
        return shown[index]["id"] as? String
    }

    private func download(_ link: String, name: String) {
        guard let url = URL(string: link), url.scheme?.lowercased() == "https" else {
            send("file_download_requested", ["status": "cancelled"])
            return
        }
        let fileName = name.isEmpty ? url.lastPathComponent : name
        Task {
            // Telegram is asked first whether the bot really offers this file: a page could otherwise name any
            // address and any file name, with the bot's name on the save panel to vouch for it.
            guard let model, await model.webAppOffers(fileName, at: link, for: session) else {
                send("file_download_requested", ["status": "cancelled"])
                return
            }
            if Preferences.isOn(Preferences.fileGuard), let warning = SecurityTools.fileWarning(for: fileName),
               !BotDialogs.ask("Сохранить «\(fileName)»?", "\(warning)\n\nИсточник: \(url.host ?? link)", action: "Сохранить") {
                send("file_download_requested", ["status": "cancelled"])
                return
            }
            guard let target = BotDialogs.saveLocation(suggestedName: fileName) else {
                send("file_download_requested", ["status": "cancelled"])
                return
            }
            send("file_download_requested", ["status": "downloading"])
            Task.detached {
                guard let (temporary, _) = try? await URLSession.shared.download(from: url) else { return }
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.moveItem(at: temporary, to: target)
            }
        }
    }

    private static func color(_ hex: String) -> Color? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    // MARK: - navigation

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // Pages that never call ready() still get their spinner removed and learn their size.
            isLoading = false
            sendViewport()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // The address a mini app is opened at often answers with a redirect to where it really lives; that
            // first page is the app. Anything the window moves to afterwards is not.
            guard !hasCommittedFirstPage, let url = webView.url else { return }
            hasCommittedFirstPage = true
            if let origin = Self.origin(scheme: url.scheme, host: url.host, port: url.port) { trustedOrigins.insert(origin) }
        }
    }

    /// A page in a bot's window asking for the camera or the microphone is answered no. The app holds the
    /// microphone for voice messages, and without this WebKit would offer it to any page a mini app shows.
    nonisolated func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                             initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { isLoading = false }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            isLoading = false
            model?.report("Мини-приложение не открылось: \(error.localizedDescription)")
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            let scheme = url.scheme?.lowercased() ?? ""
            let isMainFrame = action.targetFrame?.isMainFrame ?? true
            // tg: and t.me links belong to the app; other origins, when the app is pinned to its own, to the browser.
            if scheme == "tg" || url.host?.lowercased() == "t.me" {
                // Only a click, or the window itself going there: a frame inside the page (an advert, a
                // widget) must not be able to open chats and join prompts in the app on its own.
                if isMainFrame || action.navigationType == .linkActivated {
                    Task { await model?.openLink(url.absoluteString, confirming: false) }
                }
                return decisionHandler(.cancel)
            }
            if isMainFrame, session.requiresSameOrigin, action.navigationType == .linkActivated,
               url.host != session.url.host {
                // To the browser, and only what a browser opens. Handed over as it came, a link could name
                // any scheme this Mac knows: smb: mounts a stranger's share, others start other apps.
                if ["http", "https"].contains(scheme) { NSWorkspace.shared.open(url) }
                return decisionHandler(.cancel)
            }
            guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }

    /// `window.open` and target="_blank" go to the browser.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = session.botName
            alert.informativeText = message
            alert.runModal()
        }
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await MainActor.run {
            BotDialogs.ask(session.botName, message, action: "OK")
        }
    }
}

extension NSWindow {
    /// `toggleFullScreen` returns while the transition is still running, and the style mask only tells the
    /// truth afterwards, so the answer to the page waits for the notification.
    func transitionFullScreen() async {
        let leaving = styleMask.contains(.fullScreen)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let token = FullscreenToken()
            token.value = NotificationCenter.default.addObserver(
                forName: leaving ? NSWindow.didExitFullScreenNotification : NSWindow.didEnterFullScreenNotification,
                object: self, queue: .main
            ) { _ in
                if let value = token.value { NotificationCenter.default.removeObserver(value) }
                continuation.resume()
            }
            toggleFullScreen(nil)
        }
    }
}

/// One observer registration that can unregister itself from inside its own block. The queue the notification
/// arrives on is the main one, the same that registered it, so the value never crosses threads.
private final class FullscreenToken: @unchecked Sendable {
    var value: NSObjectProtocol?
}

/// `WKUserContentController` holds its handlers strongly; this keeps the bridge out of that cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
