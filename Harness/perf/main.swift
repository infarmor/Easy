import Foundation

// Timings of the hot paths at the size of a busy account. Not pass/fail: numbers to compare before and after.
// Run-to-run spread on this machine is wider than a tens-of-microseconds change, so compare the paired
// variants in one session, or measure the operation itself: "one unread counter change" moves between
// 0.08 and 0.20 ms on its own, while "compare two 700-row chat lists" is steady at ~0.08 ms.
func json(_ text: String) -> TDNode { try! JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! TDNode }
func pump(_ seconds: Double = 0.01) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func measure(_ label: String, repeat count: Int = 1, _ body: () -> Void) {
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<count { body() }
    let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    print(String(format: "%-58@ %9.2f ms total, %8.3f ms each", label as NSString, total, total / Double(count)))
}
func position(_ order: Int) -> String {
    #"{"@type":"chatPosition","list":{"@type":"chatListMain"},"order":"\#(9221294784512000000 + order)","is_pinned":false,"source":null}"#
}
func messageNode(_ id: Int, chat: Int, text: String = "сообщение с текстом средней длины, как обычно в группе") -> String {
    #"{"@type":"message","id":\#(id),"chat_id":\#(chat),"date":\#(1_790_000_000 + id),"is_outgoing":false,"sender_id":{"@type":"messageSenderUser","user_id":\#(1000 + id % 40)},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"\#(text)","entities":[]}},"interaction_info":{"@type":"messageInteractionInfo","view_count":\#(id),"reactions":{"@type":"messageReactions","reactions":[]}}}"#
}

MainActor.assumeIsolated {
    let model = AppModel()
    model.phase = .working

    let chatNodes = (1...3000).map { index in
        json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":\#(index),"type":{"@type":"chatTypeSupergroup","supergroup_id":\#(index),"is_channel":false},"title":"Чат \#(index)","positions":[\#(index <= 700 ? position(index) : "")],"unread_count":\#(index % 7),"last_read_inbox_message_id":0,"draft_message":null}}"#)
    }
    measure("3000 chats arrive (startup)") {
        for node in chatNodes { model.apply(node) }
        pump()
    }
    print("   list:", model.chats.count, "chats")

    measure("empty run loop turn (baseline of the measurements below)", repeat: 200) { pump(0) }
    let lastMessages = (0..<2000).map { index in
        json(#"{"@type":"updateChatLastMessage","chat_id":\#(1 + index % 700),"last_message":\#(messageNode(10_000 + index, chat: 1 + index % 700)),"positions":[\#(position(800 + index))]}"#)
    }
    var cursor = 0
    measure("burst of 20 new last messages + list rebuild", repeat: 100) {
        for _ in 0..<20 { model.apply(lastMessages[cursor % lastMessages.count]); cursor += 1 }
        pump(0)
    }
    measure("one unread counter change + list rebuild", repeat: ProcessInfo.processInfo.environment["PERF_LONG"] == nil ? 200 : 4000) {
        model.apply(json(#"{"@type":"updateChatReadInbox","chat_id":5,"last_read_inbox_message_id":\#(cursor),"unread_count":\#(cursor % 9)}"#))
        cursor += 1
        pump(0)
    }

    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.2)
    let history = (1...(ProcessInfo.processInfo.environment["PERF_MESSAGES"].flatMap(Int.init) ?? 1000)).map { messageNode($0, chat: 5) }
    measure("1000 messages arrive in the open chat") {
        for node in history { model.apply(json(#"{"@type":"updateNewMessage","message":\#(node)}"#)) }
    }
    print("   transcript:", model.transcript.flatMap(\.rows).count, "rows")
    // The busy-group case: every new message patches its row, refreshes the header of the open chat and moves
    // that chat in the sidebar — with the whole account loaded behind it.
    var incoming = 0
    measure("one new message in the open chat (row + header + sidebar)", repeat: 200) {
        incoming += 1
        let id = 20_000 + incoming
        model.apply(json(#"{"@type":"updateChatLastMessage","chat_id":5,"last_message":\#(messageNode(id, chat: 5)),"positions":[\#(position(900 + incoming))]}"#))
        pump(0)
    }
    measure("view count change on one message (transcript rebuild)", repeat: 300) {
        model.apply(json(#"{"@type":"updateMessageInteractionInfo","chat_id":5,"message_id":\#(1 + cursor % 1000),"interaction_info":{"@type":"messageInteractionInfo","view_count":\#(cursor + 5000),"reactions":{"@type":"messageReactions","reactions":[]}}}"#))
        cursor += 1
    }
    let nodes = (0..<5000).map { json(messageNode($0, chat: 5)) }
    measure("parse 5000 TDLib messages") {
        for node in nodes { _ = TD.message(node) }
    }
    // The cost of the whole-list comparison the incremental update used to do: the last row differs, so the
    // comparison walks every row before it says "not equal".
    let rows = model.chats
    var otherRows = rows
    otherRows[rows.count - 1].unread += 1
    measure("compare two \(rows.count)-row chat lists", repeat: 500) { _ = otherRows == rows }
    measure("copy a \(rows.count)-row chat list", repeat: 500) { var copy = rows; copy[rows.count - 1].unread += 1 }

    // The first page of a chat is read again while TDLib preloads it; this is what dropping the repeated
    // rows costs, against the parse it replaces.
    let pageTexts = (1...1000).map { messageNode($0, chat: 5) }
    let page = pageTexts.map { json($0) }
    for text in pageTexts { model.apply(json(#"{"@type":"updateNewMessage","message":\#(text)}"#)) }
    measure("drop 1000 rows already on screen", repeat: 200) {
        _ = page.filter { model.messageIndex[$0.tdInt64("id")] == nil }
    }
    measure("parse those same 1000 rows", repeat: 200) { _ = page.map { TD.message($0) } }

    let dates = (0..<10_000).map { Date(timeIntervalSince1970: 1_790_000_000 + Double($0 * 37)) }
    measure("10000 message times (\"13:22\")") { for date in dates { _ = date.timeStamp } }
    measure("10000 chat list stamps, first time") { for date in dates { _ = date.chatListStamp } }
    measure("10000 chat list stamps, redrawn") { for date in dates { _ = date.chatListStamp } }
    let texts = (0..<10_000).map { index in index % 10 == 0 ? "👍" : String(repeating: "длинное сообщение ", count: 1 + index % 40) }
    measure("10000 big-emoji checks") { for text in texts { _ = text.isBigEmoji } }
    let raw = (0..<5000).map { messageNode($0, chat: 5) }
    measure("decode 5000 JSON updates (receive thread)") {
        for text in raw { _ = try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
    }
}
exit(0)
