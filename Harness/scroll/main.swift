import AppKit
import SwiftUI

// The transcript in a real window: reaching the top of what is loaded asks for the page before it — once per
// arrival, and never just because a chat was opened. No TDLib client is started, so the request itself fails
// with TDError.closed; what is checked is that it was made, through `recordedRequests`.
// The same window also checks what Return in the sidebar search hands to the composer.

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if condition() { print("ok   \(label)") } else { failures += 1; print("FAIL \(label)") }
}
func json(_ text: String) -> TDNode { try! JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! TDNode }
func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
let position = #"{"@type":"chatPosition","list":{"@type":"chatListMain"},"order":"9221294784512000500","is_pinned":false,"source":null}"#
func msg(_ id: Int, chat: Int = -1003) -> TDNode {
    json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":\#(id),"chat_id":\#(chat),"sender_id":{"@type":"messageSenderUser","user_id":511},"is_outgoing":\#(id % 5 == 0),"date":\#(Int(Date().timeIntervalSince1970) - 4000 + id),"content":{"@type":"messageText","text":{"@type":"formattedText","text":"сообщение номер \#(id), обычной длины","entities":[]}}}}"#)
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let model = AppModel()
    model.apply(json(#"{"@type":"updateUser","user":{"@type":"user","id":511,"first_name":"Иван","last_name":"","type":{"@type":"userTypeRegular"},"status":{"@type":"userStatusRecently"}}}"#))
    model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":-1003,"type":{"@type":"chatTypeSupergroup","supergroup_id":3,"is_channel":false},"title":"Группа","positions":[\#(position)],"unread_count":0,"last_read_inbox_message_id":0,"draft_message":null}}"#))
    model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":-1004,"type":{"@type":"chatTypeSupergroup","supergroup_id":4,"is_channel":false},"title":"Короткая","positions":[\#(position.replacingOccurrences(of: "500", with: "400"))],"unread_count":0,"last_read_inbox_message_id":0,"draft_message":null}}"#))
    model.phase = .working
    pump(0.1)

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: RootView().environment(model))
    window.orderFrontRegardless()

    @MainActor func scrollers(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollers(in: $0) }
    }
    /// The transcript is the tallest scrolling thing in the window; the sidebar holds two rows.
    @MainActor func transcript() -> NSScrollView? {
        scrollers(in: window.contentView!).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
    @MainActor func olderRequests() -> [Int64] {
        model.recordedRequests.filter { $0.tdType == "getChatHistory" && $0.tdInt64("from_message_id") != 0 }
            .map { $0.tdInt64("from_message_id") }
    }
    @MainActor func scroll(_ scroll: NSScrollView, toTop: Bool) {
        guard let document = scroll.documentView else { return }
        let top = document.isFlipped ? 0 : document.frame.height - scroll.contentView.bounds.height
        let bottom = document.isFlipped ? document.frame.height - scroll.contentView.bounds.height : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: toTop ? top : bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // A long chat.
    model.selection = -1003
    pump(0.5)
    for id in 100..<260 { model.apply(msg(id)) }
    model.canLoadOlder = true
    pump(1.5)
    check(model.messages.count == 160, "the history is on screen (\(model.messages.count))")
    check(olderRequests().isEmpty, "opening a long chat asks for no older page \(olderRequests())")
    if let view = transcript(), let document = view.documentView {
        check(document.frame.height > view.contentView.bounds.height * 2, "the transcript is taller than the window (\(Int(document.frame.height)))")
        let visible = view.contentView.documentVisibleRect
        let atEnd = document.isFlipped ? visible.maxY >= document.frame.height - 140 : visible.minY <= 140
        check(atEnd, "a chat opens at its newest message (\(Int(visible.minY))…\(Int(visible.maxY)) of \(Int(document.frame.height)))")

        // A message arriving while the end is on screen must end up fully above the composer, not under it.
        // At the true bottom the visible rect reaches past the document by the composer's height; that
        // overhang is measured as the chat opens and has to be the same after each new message.
        func overhang() -> CGFloat { view.contentView.documentVisibleRect.maxY - (view.documentView?.frame.height ?? 0) }
        let resting = overhang()
        check(resting > 20, "at rest the transcript ends above the composer (overhang \(Int(resting)))")
        model.apply(msg(300))
        pump(1.0)
        check(abs(overhang() - resting) < 6, "someone's new message is brought fully into view (overhang \(Int(overhang())) of \(Int(resting)))")
        model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":9000001,"chat_id":-1003,"sender_id":{"@type":"messageSenderUser","user_id":1},"is_outgoing":true,"sending_state":{"@type":"messageSendingStatePending","sending_id":0},"date":\#(Int(Date().timeIntervalSince1970)),"content":{"@type":"messageText","text":{"@type":"formattedText","text":"моё сообщение","entities":[]}}}}"#))
        pump(1.0)
        check(abs(overhang() - resting) < 6, "your own message is brought fully into view (overhang \(Int(overhang())) of \(Int(resting)))")
        model.apply(json(#"{"@type":"updateMessageSendSucceeded","message":{"@type":"message","id":301,"chat_id":-1003,"sender_id":{"@type":"messageSenderUser","user_id":1},"is_outgoing":true,"date":\#(Int(Date().timeIntervalSince1970)),"content":{"@type":"messageText","text":{"@type":"formattedText","text":"моё сообщение","entities":[]}}},"old_message_id":9000001}"#))
        pump(1.0)
        check(abs(overhang() - resting) < 6, "and stays there when the server confirms it (overhang \(Int(overhang())) of \(Int(resting)))")
        // Three in a row, as in a quick exchange.
        for id in 302...304 { model.apply(msg(id)); pump(0.15) }
        pump(1.0)
        check(abs(overhang() - resting) < 6, "a quick run of messages ends at the last of them (overhang \(Int(overhang())) of \(Int(resting)))")

        scroll(view, toTop: true)
        pump(0.6)
        check(olderRequests() == [100], "reaching the top asks for the page before the oldest message \(olderRequests())")
        pump(0.8)
        check(olderRequests().count == 1, "a page that failed is not asked for again while the view rests at the top (\(olderRequests().count))")

        scroll(view, toTop: false)
        pump(0.5)
        check(olderRequests().count == 1, "scrolling back down asks for nothing (\(olderRequests().count))")
        scroll(view, toTop: true)
        pump(0.6)
        check(olderRequests().count == 2, "coming back to the top asks again (\(olderRequests().count))")

        // Nothing older exists: the top is just the top.
        model.canLoadOlder = false
        scroll(view, toTop: false)
        pump(0.4)
        scroll(view, toTop: true)
        pump(0.6)
        check(olderRequests().count == 2, "the start of the chat asks for nothing (\(olderRequests().count))")
    } else {
        check(false, "the transcript's scroll view was found")
    }

    // A chat shorter than the window rests at its top without having been scrolled there.
    let before = olderRequests().count
    model.selection = -1004
    pump(0.5)
    for id in 500..<504 { model.apply(msg(id, chat: -1004)) }
    model.canLoadOlder = true
    pump(1.2)
    check(model.messages.count == 4, "the short chat is on screen (\(model.messages.count))")
    check(olderRequests().count == before, "a short chat asks for no older page by itself (\(olderRequests().count - before))")

    // Return in the sidebar search opens the first match and asks its composer to take the keyboard. The
    // stand's window is never key, so the focus itself cannot be read here; what can is that the composer
    // of the chat that opened picked the request up.
    model.filter = "Групп"
    pump(0.3)
    model.openFirstSearchResult()
    check(model.wantsComposerFocus, "Return in the search asks for the composer")
    pump(1.0)
    check(model.selection == -1003, "and opens the first match (\(String(describing: model.selection)))")
    check(!model.wantsComposerFocus, "whose composer takes the request")
}

print(failures == 0 ? "ALL PASSED (\(checks) checks)" : "\(failures) FAILED of \(checks)")
exit(failures == 0 ? 0 : 1)
