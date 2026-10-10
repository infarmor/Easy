import AppKit
import WebKit
var failures = 0
var checks = 0
func check(_ c: Bool, _ l: String) { checks += 1; print(c ? "ok   \(l)" : "FAIL \(l)"); if !c { failures += 1 } }
func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
_ = NSApplication.shared
MainActor.assumeIsolated {
    let session = WebAppSession(launchId: 0, chatId: 1, botUserId: 2, botName: "Тест", url: URL(string: "http://127.0.0.1:8765/index.html")!, requiresSameOrigin: false, keyboardButtonText: nil)
    // SwiftUI may build a bridge it then throws away: until start() nothing is loaded.
    let idle = WebAppBridge(session: session)
    pump(0.5)
    check(idle.webView.url == nil && !idle.webView.isLoading, "a bridge does not load before start()")
    let bridge = WebAppBridge(session: session)
    bridge.start()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = bridge.webView
    let deadline = Date().addingTimeInterval(15)
    while bridge.isLoading, Date() < deadline { pump(0.1) }
    pump(0.5)
    check(!bridge.isLoading, "page loaded and reported ready")
    check(bridge.mainButton.isVisible && bridge.mainButton.text == "Купить" && bridge.mainButton.color != nil, "main button set up from the page")
    check(bridge.isBackButtonVisible, "back button shown")
    // The page answers asynchronously and a fixed pump is a coin toss on a busy machine, so wait for the
    // events to arrive instead of assuming how long they need. A stand that goes red for no reason is as
    // useless as one that cannot go red.
    func pageSawAll(_ needles: [String], timeout: Double = 8) -> String {
        var text = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            bridge.webView.evaluateJavaScript("JSON.stringify(window.received)") { value, _ in text = value as? String ?? "" }
            pump(0.2)
            if needles.allSatisfy({ text.contains($0) }) { return text }
        }
        return text
    }
    let theme = pageSawAll(["theme_changed", "background_color"])
    check(theme.contains("theme_changed") && theme.contains("background_color") && !theme.contains("bg_color"), "theme sent back")
    check(pageSawAll(["viewport_changed"]).contains("viewport_changed"), "viewport sent back")
    check(pageSawAll(["biometry_info_received"]).contains("biometry_info_received"), "unsupported features answered")
    bridge.send("main_button_pressed")
    check(pageSawAll(["main_button_pressed"]).contains("main_button_pressed"), "button press reaches the page")

    // --- DeviceStorage ------------------------------------------------------------------------------
    func answerFor(_ reqId: String, timeout: Double = 8) -> String {
        var text = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            bridge.webView.evaluateJavaScript(
                "JSON.stringify(window.received.filter(function (e) { return e[1] && e[1].req_id === '\(reqId)'; }))"
            ) { value, _ in text = value as? String ?? "" }
            pump(0.2)
            if !text.isEmpty, text != "[]" { return text }
        }
        return text
    }
    check(answerFor("s1").contains("device_storage_key_saved"), "a stored key is confirmed to the page")
    check(answerFor("s2").contains("device_storage_key_received") && answerFor("s2").contains("dark"),
          "and reads back what was stored (\(answerFor("s2")))")
    check(answerFor("s3").contains("null"), "a key that was never stored answers with null")
    check(answerFor("s4").contains("device_storage_key_saved") && WebAppStorage.values(for: session)["theme"] == nil,
          "a key sent back with a null value is removed")
    check(WebAppStorage.values(for: session)["kept"] == "значение", "the value is kept as the page wrote it")
    check(answerFor("s6").contains("device_storage_failed") && answerFor("s7").contains("device_storage_failed"),
          "an empty or missing key is refused, not stored")
    let otherBot = WebAppSession(launchId: 0, chatId: 1, botUserId: 3, botName: "Другой",
                                 url: session.url, requiresSameOrigin: false, keyboardButtonText: nil)
    check(WebAppStorage.values(for: otherBot).isEmpty, "another bot's app reads none of it")
    let sameHost = WebAppSession(launchId: 0, chatId: 1, botUserId: 2, botName: "Тест",
                                 url: URL(string: "http://127.0.0.1:8766/index.html")!,
                                 requiresSameOrigin: false, keyboardButtonText: nil)
    check(WebAppStorage.values(for: sameHost).isEmpty, "and the same bot on another port starts empty")
    WebAppStorage.clear(session)
    check(WebAppStorage.values(for: session).isEmpty, "clear empties the app's storage")
    // --- another origin in the same window ---------------------------------------------------------------
    // The same test site under another host name is, to a browser, another site. A mini app's window can end
    // up on one through any link or redirect; that page may keep its buttons and nothing that acts for the bot.
    bridge.webView.load(URLRequest(url: URL(string: "http://localhost:8765/index.html")!))
    pump(1.0)
    check(pageSawAll(["theme_changed"]).contains("theme_changed"), "a page of another origin still gets what only concerns the window")
    check(bridge.webView.url?.host == "localhost", "and it really is the other origin (\(bridge.webView.url?.host ?? "?"))")
    let foreign = answerFor("s2", timeout: 2.5)
    check(foreign.isEmpty || foreign == "[]", "but it cannot read what the bot's app stored: \(foreign)")

}
print(failures == 0 ? "ALL PASSED (\(checks) checks)" : "\(failures) FAILED of \(checks)")
exit(failures == 0 ? 0 : 1)
