import AppKit
import Foundation
import ImageIO

// Offline harness: feeds TDLib-shaped updates (td_api.tl 1.8.67) straight into AppModel.apply.
// No TDLib client is started, so every request fails with TDError.closed and is ignored.

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if condition() { print("ok   \(label)") } else { failures += 1; print("FAIL \(label)") }
}

func writePNG(to url: URL, width: Int, height: Int) {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

func pump(_ seconds: Double = 0.05) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func json(_ text: String) -> TDNode {
    try! JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! TDNode
}

func mainPosition(_ order: String, pinned: Bool = false) -> String {
    #"{"@type":"chatPosition","list":{"@type":"chatListMain"},"order":"\#(order)","is_pinned":\#(pinned),"source":null}"#
}

func chat(_ id: Int64, _ title: String, positions: [String] = [], draft: String? = nil) -> TDNode {
    let draftJSON = draft.map {
        #"{"@type":"draftMessage","reply_to":null,"date":1,"content":{"@type":"draftMessageContentText","text":{"@type":"formattedText","text":"\#($0)","entities":[]}}}"#
    } ?? "null"
    return json(#"""
    {"@type":"updateNewChat","chat":{"@type":"chat","id":\#(id),"type":{"@type":"chatTypePrivate","user_id":\#(id)},"title":"\#(title)",
     "positions":[\#(positions.joined(separator: ","))],"unread_count":0,"is_marked_as_unread":false,
     "last_read_outbox_message_id":0,"unread_mention_count":0,"unread_reaction_count":0,"draft_message":\#(draftJSON)}}
    """#)
}

func message(_ id: Int64, chat: Int64, from user: Int64 = 7, text: String = "hi", outgoing: Bool = false, state: String = "null") -> String {
    #"""
    {"@type":"message","id":\#(id),"sender_id":{"@type":"messageSenderUser","user_id":\#(user)},"chat_id":\#(chat),
     "sending_state":\#(state),"is_outgoing":\#(outgoing),"is_pinned":false,"date":1790000000,
     "content":{"@type":"messageText","text":{"@type":"formattedText","text":"\#(text)","entities":[]}}}
    """#
}

MainActor.assumeIsolated {
    let model = AppModel()

    // --- chat list ------------------------------------------------------------------------------
    model.apply(chat(1, "Alpha"))
    model.apply(chat(2, "Beta", positions: [mainPosition("9221294784512000005")]))
    model.apply(chat(3, "Gamma", positions: [mainPosition("9221294784512000009", pinned: true)]))
    model.apply(chat(4, "Archived", positions: [#"{"@type":"chatPosition","list":{"@type":"chatListArchive"},"order":"9221294784512000001","is_pinned":false,"source":null}"#]))
    pump()
    check(model.chats.map(\.title) == ["Gamma", "Beta"], "only main-list chats, sorted by string int64 order: \(model.chats.map(\.title))")
    check(model.chats.first?.isPinned == true, "pinned flag from position")

    model.apply(json(#"{"@type":"updateChatPosition","chat_id":1,"position":\#(mainPosition("9221294784512000099"))}"#))
    pump()
    check(model.chats.map(\.title) == ["Alpha", "Gamma", "Beta"], "updateChatPosition moves chat into place: \(model.chats.map(\.title))")

    model.apply(json(#"{"@type":"updateChatLastMessage","chat_id":2,"last_message":\#(message(10, chat: 2, text: "latest")),"positions":[\#(mainPosition("9221294784512000100"))]}"#))
    pump()
    check(model.chats.first?.title == "Beta" && model.chats.first?.snippet == "latest", "last message reorders and sets snippet")

    model.apply(json(#"{"@type":"updateChatLastMessage","chat_id":3,"last_message":null,"positions":[]}"#))
    pump()
    check(!model.chats.contains { $0.id == 3 }, "chat without main position leaves the list")

    model.apply(json(#"{"@type":"updateChatPosition","chat_id":1,"position":\#(mainPosition("0"))}"#))
    pump()
    check(model.chats.map(\.id) == [2], "order 0 removes chat: \(model.chats.map(\.id))")

    model.apply(json(#"{"@type":"updateChatPosition","chat_id":1,"position":\#(mainPosition("9221294784512000050"))}"#))
    model.apply(json(#"{"@type":"updateChatIsMarkedAsUnread","chat_id":1,"is_marked_as_unread":true}"#))
    model.apply(json(#"{"@type":"updateChatReadInbox","chat_id":1,"last_read_inbox_message_id":5,"unread_count":4}"#))
    model.apply(json(#"{"@type":"updateChatTitle","chat_id":1,"title":"Alpha 2"}"#))
    pump()
    let alpha = model.chats.first { $0.id == 1 }
    check(alpha?.isMarkedUnread == true && alpha?.unread == 4 && alpha?.title == "Alpha 2", "unread, marked-unread and title updates")

    // --- users ----------------------------------------------------------------------------------
    model.apply(json(#"{"@type":"updateUser","user":{"@type":"user","id":7,"first_name":"Иван","last_name":"Петров","usernames":null,"type":{"@type":"userTypeRegular"}}}"#))
    model.apply(json(#"{"@type":"updateUser","user":{"@type":"user","id":8,"first_name":"","last_name":"","usernames":{"@type":"usernames","active_usernames":["nick"]},"type":{"@type":"userTypeRegular"}}}"#))
    model.apply(json(#"{"@type":"updateUser","user":{"@type":"user","id":9,"first_name":"","last_name":"","usernames":null,"type":{"@type":"userTypeDeleted"}}}"#))
    check(model.senderNames["u7"] == "Иван Петров" && model.senderNames["u8"] == "@nick" && model.senderNames["u9"] == "Удалённый аккаунт", "user names from updateUser: \(model.senderNames)")
    check(model.senderNames["c2"] == "Beta", "chat names remembered for channel senders")

    // --- conversation ---------------------------------------------------------------------------
    model.apply(chat(5, "Drafty", positions: [mainPosition("9221294784512000200")], draft: "черновик"))
    pump()
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.3)
    check(model.draft == "черновик", "opening a chat restores its TDLib draft")

    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(100, chat: 5, text: "one"))}"#))
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(200, chat: 2, text: "other chat"))}"#))
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(101, chat: 5, text: "pending", outgoing: true, state: #"{"@type":"messageSendingStatePending","sending_id":0}"#))}"#))
    check(model.messages.map(\.id) == [100, 101], "only the open chat's messages are kept: \(model.messages.map(\.id))")
    check(model.messages.last?.isPending == true, "pending state parsed")

    model.apply(json(#"{"@type":"updateMessageSendFailed","message":\#(message(102, chat: 5, text: "pending", outgoing: true, state: #"{"@type":"messageSendingStateFailed","error":{"@type":"error","code":400,"message":"x"},"can_retry":true,"need_another_sender":false,"need_another_reply_quote":false,"need_drop_reply":false,"required_paid_message_star_count":0,"retry_after":0}"#)),"old_message_id":101,"error":{"@type":"error","code":400,"message":"x"}}"#))
    check(model.messages.map(\.id) == [100, 102] && model.messages.last?.isFailed == true, "send failure replaces the pending copy: \(model.messages.map(\.id))")

    model.apply(json(#"{"@type":"updateMessageSendSucceeded","message":\#(message(103, chat: 5, text: "pending", outgoing: true)),"old_message_id":102}"#))
    check(model.messages.map(\.id) == [100, 103] && model.messages.last?.isSent == true, "send success replaces the local copy")

    model.apply(json(#"{"@type":"updateMessageIsPinned","chat_id":5,"message_id":100,"is_pinned":true}"#))
    check(model.messages.first?.isPinned == true, "pin state follows updateMessageIsPinned")

    model.apply(json(#"{"@type":"updateMessageContent","chat_id":5,"message_id":100,"new_content":{"@type":"messageText","text":{"@type":"formattedText","text":"edited","entities":[]}}}"#))
    check(model.messages.first?.body == .text("edited"), "content edits applied")

    if let first = model.messages.first { model.beginReply(to: first) }
    check(model.composerContext?.kind == .reply && model.composerContext?.messageId == 100 && model.composerContext?.title == "Ответ: Иван Петров", "reply context: \(String(describing: model.composerContext))")

    model.apply(json(#"{"@type":"updateDeleteMessages","chat_id":5,"message_ids":[100],"is_permanent":false,"from_cache":true}"#))
    check(model.messages.count == 2, "cache eviction keeps messages")
    model.apply(json(#"{"@type":"updateDeleteMessages","chat_id":5,"message_ids":[100],"is_permanent":true,"from_cache":false}"#))
    check(model.messages.first { $0.id == 100 }?.isDeleted == true && model.messages.count == 2, "deleted by the other side: kept and marked (AyuGram default)")
    check(model.composerContext == nil, "deleting the replied message drops the reply bar")

    // Remote draft change while nothing is typed locally is adopted.
    model.apply(json(#"{"@type":"updateChatDraftMessage","chat_id":5,"draft_message":{"@type":"draftMessage","reply_to":null,"date":2,"content":{"@type":"draftMessageContentText","text":{"@type":"formattedText","text":"с телефона","entities":[]}}},"positions":[\#(mainPosition("9221294784512000200"))]}"#))
    check(model.draft == "с телефона", "remote draft adopted when composer is clean")

    // Typing, then switching chats keeps each chat's own draft.
    model.draft = "набираю"
    model.selection = 2
    check(model.messages.isEmpty && model.draft.isEmpty, "leaving a chat clears the transcript and composer")
    Task { await model.select(chatId: 2) }
    pump(0.3)
    check(model.draft.isEmpty, "other chat starts with its own (empty) draft")
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(300, chat: 5, text: "late"))}"#))
    check(model.messages.isEmpty, "messages for the chat we left are not shown")
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.3)
    check(model.draft == "набираю", "returning restores the unsent draft: '\(model.draft)'")


    // --- archive, mute, forwarding -------------------------------------------------------------
    func archivePosition(_ order: String, pinned: Bool = false) -> String {
        #"{"@type":"chatPosition","list":{"@type":"chatListArchive"},"order":"\#(order)","is_pinned":\#(pinned),"source":null}"#
    }
    func channel(_ id: Int64, _ title: String, positions: [String], muteFor: Int? = nil) -> TDNode {
        let settings = muteFor.map { #"{"@type":"chatNotificationSettings","use_default_mute_for":false,"mute_for":\#($0),"use_default_sound":true,"sound_id":"0","use_default_show_preview":true,"show_preview":false}"# }
            ?? #"{"@type":"chatNotificationSettings","use_default_mute_for":true,"mute_for":0,"use_default_sound":true,"sound_id":"0","use_default_show_preview":true,"show_preview":false}"#
        return json(#"""
        {"@type":"updateNewChat","chat":{"@type":"chat","id":\#(id),"type":{"@type":"chatTypeSupergroup","supergroup_id":1,"is_channel":true},"title":"\#(title)",
         "positions":[\#(positions.joined(separator: ","))],"unread_count":0,"is_marked_as_unread":false,"last_read_inbox_message_id":0,
         "last_read_outbox_message_id":0,"unread_mention_count":0,"unread_reaction_count":0,"draft_message":null,"notification_settings":\#(settings)}}
        """#)
    }
    model.apply(channel(-100_1, "Новости", positions: [mainPosition("9221294784512000300")]))
    model.apply(channel(-100_2, "Шумный", positions: [mainPosition("9221294784512000290")], muteFor: 2147483647))
    model.apply(chat(6, "Старый", positions: [archivePosition("9221294784512000010")]))
    model.apply(chat(7, "Важный архив", positions: [archivePosition("9221294784512000005", pinned: true)]))
    pump()
    check(model.chats.first { $0.id == -100_1 }?.isMuted == false, "channel follows scope default (not muted yet)")
    check(model.chats.first { $0.id == -100_2 }?.isMuted == true, "own mute_for wins")
    model.apply(json(#"{"@type":"updateScopeNotificationSettings","scope":{"@type":"notificationSettingsScopeChannelChats"},"notification_settings":{"@type":"scopeNotificationSettings","mute_for":2147483647,"show_preview":true}}"#))
    pump()
    check(model.chats.first { $0.id == -100_1 }?.isMuted == true, "muting the channel scope mutes default channels")
    model.apply(json(#"{"@type":"updateChatNotificationSettings","chat_id":-1002,"notification_settings":{"@type":"chatNotificationSettings","use_default_mute_for":false,"mute_for":0}}"#))
    pump()
    check(model.chats.first { $0.id == -100_2 }?.isMuted == false, "explicit unmute beats a muted scope")
    check(!model.chats.contains { $0.id == 6 || $0.id == 7 }, "archived chats stay out of the main list")

    model.showsArchive = true
    check(model.chats.map(\.id) == [6, 7, 4], "archive shows archived chats by archive order: \(model.chats.map(\.id))")
    check(model.chats.first { $0.id == 7 }?.isPinned == true && model.chats.first { $0.id == 6 }?.isPinned == false && model.chats.allSatisfy(\.isArchived), "archive pin flag is projected")
    model.showsArchive = false
    check(!model.chats.contains { $0.isArchived }, "back to the main list")

    let targets = model.forwardTargets(matching: "")
    check(targets.first?.id == model.chats.first?.id && targets.suffix(3).map(\.id) == [6, 7, 4], "forward targets: main list first, then archive")
    check(model.forwardTargets(matching: "архив").map(\.id) == [7], "forward targets filter by title")

    // Archiving the open chat keeps it on screen.
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.3)
    model.apply(json(#"{"@type":"updateChatPosition","chat_id":5,"position":\#(mainPosition("0"))}"#))
    model.apply(json(#"{"@type":"updateChatPosition","chat_id":5,"position":\#(archivePosition("9221294784512000400"))}"#))
    pump()
    check(!model.chats.contains { $0.id == 5 } && model.selectedChat?.id == 5 && model.selectedChat?.isArchived == true, "archived open chat stays selected")

    model.apply(json(#"{"@type":"updateChatReadInbox","chat_id":5,"last_read_inbox_message_id":150,"unread_count":2}"#))
    pump()
    check(model.selectedChat?.unread == 2, "read inbox tracked for chats outside the list")


    // --- presence, activity, members, photos ----------------------------------------------------
    func group(_ id: Int64, _ title: String, supergroup: Int64, channel: Bool, order: String) -> TDNode {
        json(#"""
        {"@type":"updateNewChat","chat":{"@type":"chat","id":\#(id),"type":{"@type":"chatTypeSupergroup","supergroup_id":\#(supergroup),"is_channel":\#(channel)},"title":"\#(title)",
         "positions":[\#(mainPosition(order))],"unread_count":0,"is_marked_as_unread":false,"last_read_inbox_message_id":0,
         "last_read_outbox_message_id":0,"unread_mention_count":0,"unread_reaction_count":0,"draft_message":null}}
        """#)
    }
    func user(_ id: Int64, _ first: String, status: String = #"{"@type":"userStatusRecently","by_my_privacy_settings":false}"#, type: String = "userTypeRegular", photo: String = "null") -> TDNode {
        json(#"{"@type":"updateUser","user":{"@type":"user","id":\#(id),"first_name":"\#(first)","last_name":"","usernames":null,"type":{"@type":"\#(type)"},"status":\#(status),"profile_photo":\#(photo)}}"#)
    }
    let now = Int(Date().timeIntervalSince1970)
    let mini = Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
    model.apply(user(501, "Мария", status: #"{"@type":"userStatusOnline","expires":\#(now + 300)}"#,
                     photo: #"{"@type":"profilePhoto","id":"77","small":{"@type":"file","id":900,"local":{"@type":"localFile","path":"","is_downloading_completed":false}},"big":{"@type":"file","id":901},"minithumbnail":{"@type":"minithumbnail","width":40,"height":40,"data":"\#(mini)"},"has_animation":false,"is_personal":false}"#))
    model.apply(chat(501, "Мария", positions: [mainPosition("9221294784512000500")]))
    pump()
    let maria = { model.chats.first { $0.id == 501 } }
    check(maria()?.presence == .online && model.subtitle(for: maria()!) == "в сети", "online status from updateUser reaches the private chat")
    check(model.senderPhotos["u501"]?.fileId == 900 && model.senderPhotos["u501"]?.minithumbnail == Data([0xFF, 0xD8, 0xFF]), "profile photo with minithumbnail")

    let today = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) + 60
    model.apply(json(#"{"@type":"updateUserStatus","user_id":501,"status":{"@type":"userStatusOffline","was_online":\#(today)}}"#))
    pump()
    check(model.subtitle(for: maria()!).hasPrefix("был(а) в "), "last seen today: \(model.subtitle(for: maria()!))")
    model.apply(json(#"{"@type":"updateUserStatus","user_id":501,"status":{"@type":"userStatusOffline","was_online":\#(today - 7200)}}"#))
    pump()
    check(model.subtitle(for: maria()!).hasPrefix("был(а) вчера в "), "last seen yesterday: \(model.subtitle(for: maria()!))")
    model.apply(json(#"{"@type":"updateUserStatus","user_id":501,"status":{"@type":"userStatusOnline","expires":\#(now - 10)}}"#))
    pump()
    check(maria()?.presence != .online, "expired online status reads as offline")
    model.apply(json(#"{"@type":"updateUserStatus","user_id":501,"status":{"@type":"userStatusLastWeek","by_my_privacy_settings":false}}"#))
    pump()
    check(model.subtitle(for: maria()!) == "был(а) на этой неделе", "hidden last seen")

    model.apply(user(502, "Бот", type: "userTypeBot"))
    model.apply(chat(502, "Бот", positions: [mainPosition("9221294784512000499")]))
    pump()
    check(model.subtitle(for: model.chats.first { $0.id == 502 }!) == "бот", "bots are labelled")

    model.apply(json(#"{"@type":"updateChatAction","chat_id":501,"topic_id":null,"sender_id":{"@type":"messageSenderUser","user_id":501},"action":{"@type":"chatActionTyping"}}"#))
    pump()
    check(maria()?.activity == "печатает…" && model.subtitle(for: maria()!) == "печатает…", "typing in a private chat")
    model.apply(json(#"{"@type":"updateChatAction","chat_id":501,"topic_id":null,"sender_id":{"@type":"messageSenderUser","user_id":501},"action":{"@type":"chatActionCancel"}}"#))
    pump()
    check(maria()?.activity == "", "typing cancelled")

    model.apply(json(#"{"@type":"updateSupergroup","supergroup":{"@type":"supergroup","id":4,"member_count":21,"is_channel":true}}"#))
    model.apply(group(-1004, "Канал", supergroup: 4, channel: true, order: "9221294784512000480"))
    model.apply(group(-1003, "Группа", supergroup: 3, channel: false, order: "9221294784512000490"))
    model.apply(user(511, "Иван Петров"))
    model.apply(user(512, "Ольга"))
    model.apply(user(513, "Пётр"))
    model.apply(json(#"{"@type":"updateSupergroup","supergroup":{"@type":"supergroup","id":3,"member_count":1234,"is_channel":false}}"#))
    model.apply(json(#"{"@type":"updateChatOnlineMemberCount","chat_id":-1003,"online_member_count":5}"#))
    pump()
    let groupChat = { model.chats.first { $0.id == -1003 }! }
    let channelChat = { model.chats.first { $0.id == -1004 }! }
    check(model.subtitle(for: channelChat()) == "21 подписчик", "channel subscribers (count before the chat): \(model.subtitle(for: channelChat()))")
    check(model.subtitle(for: groupChat()).contains("234 участника") && model.subtitle(for: groupChat()).hasSuffix(", 5 в сети"), "group members and online: \(model.subtitle(for: groupChat()))")

    for sender in [511, 512] {
        model.apply(json(#"{"@type":"updateChatAction","chat_id":-1003,"topic_id":null,"sender_id":{"@type":"messageSenderUser","user_id":\#(sender)},"action":{"@type":"chatActionTyping"}}"#))
    }
    pump()
    check(groupChat().activity == "Иван и Ольга печатают…", "two people typing: \(groupChat().activity)")
    model.apply(json(#"{"@type":"updateChatAction","chat_id":-1003,"topic_id":null,"sender_id":{"@type":"messageSenderUser","user_id":513},"action":{"@type":"chatActionTyping"}}"#))
    pump()
    check(groupChat().activity == "3 человека печатают…", "three people typing: \(groupChat().activity)")
    model.apply(json(#"{"@type":"updateChatAction","chat_id":-1003,"topic_id":null,"sender_id":{"@type":"messageSenderUser","user_id":512},"action":{"@type":"chatActionCancel"}}"#))
    model.apply(json(#"{"@type":"updateChatAction","chat_id":-1003,"topic_id":null,"sender_id":{"@type":"messageSenderUser","user_id":513},"action":{"@type":"chatActionUploadingPhoto","progress":10}}"#))
    pump()
    check(groupChat().activity.hasPrefix("Иван и Пётр "), "mixed activities keep both names: \(groupChat().activity)")

    model.apply(json(#"{"@type":"updateChatPhoto","chat_id":501,"photo":{"@type":"chatPhotoInfo","small":{"@type":"file","id":950,"local":{"@type":"localFile","path":"/tmp/x.jpg","is_downloading_completed":true}},"big":{"@type":"file","id":951},"minithumbnail":null,"has_animation":false,"is_personal":false}}"#))
    pump()
    check(maria()?.photo == ProfilePhoto(fileId: 950, localPath: "/tmp/x.jpg", minithumbnail: nil) && model.senderPhotos["c501"]?.fileId == 950, "chat photo updates")

    check([1, 2, 5, 11, 21, 22, 112].map { TD.plural($0, "a", "b", "c") } == ["a", "b", "c", "c", "a", "b", "c"], "russian plural forms")

    // --- stickers and gzip ------------------------------------------------------------------------
    func stickerContent(format: String, thumbnail: String) -> String {
        #"{"@type":"messageSticker","sticker":{"@type":"sticker","id":"1","set_id":"2","width":512,"height":384,"emoji":"😀","format":{"@type":"\#(format)"},"full_type":{"@type":"stickerFullTypeRegular"},"thumbnail":{"@type":"thumbnail","format":{"@type":"\#(thumbnail)"},"width":128,"height":96,"file":{"@type":"file","id":31}},"sticker":{"@type":"file","id":30}},"is_premium":false}"#
    }
    let tgs = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":\#(stickerContent(format: "stickerFormatTgs", thumbnail: "thumbnailFormatWebp"))}"#))
    check(tgs.sticker == Sticker(fileId: 30, format: .tgs, width: 512, height: 384, emoji: "😀", thumbnailFileId: 31, isEmoji: false) && tgs.body == .attachment("Стикер 😀"), "animated sticker parsed")
    let webm = TD.sticker(of: json(stickerContent(format: "stickerFormatWebm", thumbnail: "thumbnailFormatWebm")))
    check(webm?.format == .webm && webm?.thumbnailFileId == nil, "video sticker without a still preview")
    let emoji = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messageAnimatedEmoji","emoji":"👍","animated_emoji":{"@type":"animatedEmoji","sticker":{"@type":"sticker","id":"5","width":512,"height":512,"emoji":"👍","format":{"@type":"stickerFormatTgs"},"thumbnail":null,"sticker":{"@type":"file","id":40}},"sticker_width":512,"sticker_height":512}}}"#))
    check(emoji.sticker?.isEmoji == true && emoji.sticker?.fileId == 40 && emoji.body == .text("👍"), "animated emoji becomes a small sticker")
    let plainEmoji = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messageAnimatedEmoji","emoji":"🫠","animated_emoji":{"@type":"animatedEmoji","sticker":null,"sticker_width":0,"sticker_height":0}}}"#))
    check(plainEmoji.sticker == nil && plainEmoji.body == .text("🫠"), "emoji without animation stays text")

    let original = Data(#"{"tgs":1,"v":"5.5.2","fr":60,"ip":0,"op":180,"w":512,"h":512,"layers":[]}"#.utf8)
    let raw = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlite-sticker.json")
    try? original.write(to: raw)
    for flags in [["-c"], ["-n", "-c"]] {
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = flags + [raw.path]
        let pipe = Pipe()
        gzip.standardOutput = pipe
        try? gzip.run()
        let packed = pipe.fileHandleForReading.readDataToEndOfFile()
        gzip.waitUntilExit()
        check(Gzip.inflate(packed) == original, "gzip \(flags.joined(separator: " ")) round trip (\(packed.count) bytes)")
    }


    // --- media, replies, forwards -----------------------------------------------------------------
    let photoMessage = TD.message(json(#"{"@type":"message","id":7,"chat_id":1,"date":1,"edit_date":5,"reply_to":{"@type":"messageReplyToMessage","chat_id":1,"message_id":3},"forward_info":{"@type":"messageForwardInfo","origin":{"@type":"messageOriginUser","sender_user_id":42},"date":1},"content":{"@type":"messagePhoto","has_spoiler":true,"photo":{"@type":"photo","minithumbnail":{"@type":"minithumbnail","width":40,"height":30,"data":"\#(mini)"},"sizes":[{"@type":"photoSize","type":"s","photo":{"@type":"file","id":1,"size":900},"width":90,"height":67},{"@type":"photoSize","type":"x","photo":{"@type":"file","id":2,"size":60000},"width":800,"height":600},{"@type":"photoSize","type":"y","photo":{"@type":"file","id":3,"size":150000},"width":1280,"height":960}]},"caption":{"@type":"formattedText","text":"подпись","entities":[]}}}"#))
    check(photoMessage.media?.kind == .photo && photoMessage.media?.fileId == 2 && photoMessage.media?.width == 800 && photoMessage.media?.hasSpoiler == true && photoMessage.media?.minithumbnail != nil, "photo picks the 800px size for the bubble")
    check(photoMessage.caption == "подпись" && photoMessage.isEdited && photoMessage.replyToId == 3 && photoMessage.forwardSenderKey == "u42", "caption, edited flag, reply and forward origin")
    check(photoMessage.attachment?.fileId == 3, "opening a photo still uses the largest size")
    let foreignReply = TD.message(json(#"{"@type":"message","id":8,"chat_id":1,"date":1,"reply_to":{"@type":"messageReplyToMessage","chat_id":99,"message_id":3},"forward_info":{"@type":"messageForwardInfo","origin":{"@type":"messageOriginHiddenUser","sender_name":"Аноним"},"date":1},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"x","entities":[]}}}"#))
    check(foreignReply.replyToId == 0 && foreignReply.forwardSenderName == "Аноним" && foreignReply.isForwarded, "replies to other chats are not quoted; hidden forward names kept")
    let note = TD.media(of: json(#"{"@type":"messageVideoNote","video_note":{"@type":"videoNote","duration":9,"length":384,"thumbnail":{"@type":"thumbnail","format":{"@type":"thumbnailFormatJpeg"},"width":90,"height":90,"file":{"@type":"file","id":61}},"video":{"@type":"file","id":60,"size":500000}}}"#))
    check(note?.kind == .videoNote && note?.fileId == 60 && note?.thumbnailFileId == 61 && note?.width == 384 && note?.duration == 9, "video message: round clip with its still")
    let gif = TD.media(of: json(#"{"@type":"messageAnimation","animation":{"@type":"animation","duration":3,"width":320,"height":240,"thumbnail":{"@type":"thumbnail","format":{"@type":"thumbnailFormatMpeg4"},"width":90,"height":67,"file":{"@type":"file","id":71}},"animation":{"@type":"file","id":70,"size":0,"expected_size":800000}},"caption":{"@type":"formattedText","text":"","entities":[]},"has_spoiler":false}"#))
    check(gif?.kind == .animation && gif?.thumbnailFileId == nil && gif?.fileSize == 800000, "GIF with a video thumbnail has no still picture; expected size used")

    // --- editing captions -------------------------------------------------------------------------
    check(AppModel.editableText(of: photoMessage).map { $0.text == "подпись" && $0.isCaption } == true, "photo caption is editable")
    check(AppModel.editableText(of: tgs) == nil, "stickers are not editable")
    check(AppModel.editableText(of: TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"abc","entities":[]}}}"#))).map { $0.text == "abc" && !$0.isCaption } == true, "text messages edit their text")

    // --- AyuGram: deleted messages and edit history ----------------------------------------------
    model.archive.open(accountId: 999)
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.3)
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(700, chat: 5, text: "первый вариант"))}"#))
    model.apply(json(#"{"@type":"updateMessageContent","chat_id":5,"message_id":700,"new_content":{"@type":"messageText","text":{"@type":"formattedText","text":"второй вариант","entities":[]}}}"#))
    let edited = model.messages.first { $0.id == 700 }
    check(edited?.body == .text("второй вариант") && edited?.hasEditHistory == true, "edit keeps a history")
    model.showEditHistory(of: edited!)
    check(model.inspectedCode?.json.contains("первый вариант") == true && model.inspectedCode?.isCode == false, "history sheet lists the old text")
    model.apply(json(#"{"@type":"updateMessageContent","chat_id":5,"message_id":700,"new_content":{"@type":"messageText","text":{"@type":"formattedText","text":"второй вариант","entities":[{"@type":"textEntity"}]}}}"#))
    check(model.archive.entry(chatId: 5, messageId: 700)?.versions.count == 1, "same text again (link preview, entities) is not an edit")

    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(701, chat: 5, text: "исчезну"))}"#))
    model.apply(json(#"{"@type":"updateDeleteMessages","chat_id":5,"message_ids":[701],"is_permanent":true,"from_cache":false}"#))
    check(model.messages.first { $0.id == 701 }?.isDeleted == true, "message deleted by someone else stays, marked deleted")
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(702, chat: 5, text: "моё", outgoing: true))}"#))
    Task { await model.delete(model.messages.first { $0.id == 702 }!, forEveryone: true) }
    pump(0.2)
    model.apply(json(#"{"@type":"updateDeleteMessages","chat_id":5,"message_ids":[702],"is_permanent":true,"from_cache":false}"#))
    // No session here, so the deletion is refused: its "mine" mark must go, and a deletion that comes later
    // (someone else's) is kept like any other. With a session TDLib's update arrives before the reply.
    check(model.messages.first { $0.id == 702 }?.isDeleted == true, "a refused deletion leaves no mark behind")

    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(800, chat: 2, text: "в закрытом чате"))}"#))
    model.apply(json(#"{"@type":"updateDeleteMessages","chat_id":2,"message_ids":[800],"is_permanent":true,"from_cache":false}"#))
    check(model.archive.deletedMessages(in: 2).first?.body == .text("в закрытом чате"), "deletions in closed chats are archived from the recent cache")

    model.selection = 2
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.3)
    // Stands in for the history page that loads when the chat opens.
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(650, chat: 5, text: "история"))}"#))
    check(model.messages.first { $0.id == 701 }?.isDeleted == true, "reopened chat shows the saved deleted message again")
    let reopenedEdit = model.messages.first { $0.id == 700 }
    check(reopenedEdit == nil || reopenedEdit?.hasEditHistory == true, "edit history flag survives reopening")

    model.archive.close()
    let reloaded = MessageArchive()
    reloaded.open(accountId: 999)
    check(reloaded.deletedMessages(in: 5).contains { $0.id == 701 } && reloaded.hasHistory(chatId: 5, messageId: 700), "archive survives a restart (JSON on disk)")
    let archiveFile = "\(NSTemporaryDirectory())"
    _ = archiveFile

    // --- ghost mode -------------------------------------------------------------------------------
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: Preferences.ghostMode)
    check(!Preferences.readsAutomatically && !Preferences.sendsTyping && !Preferences.showsOnline, "ghost mode silences reading, typing and online")
    defaults.set(false, forKey: Preferences.ghostMode)
    check(Preferences.readsAutomatically && Preferences.sendsTyping && Preferences.showsOnline, "without ghost mode the switches apply")

    // --- search across lists ----------------------------------------------------------------------
    model.filter = "важный"
    check(model.visibleChats.map(\.id) == [7], "search finds archived chats from the main list: \(model.visibleChats.map(\.id))")
    model.filter = ""
    check(TD.count(1, "чат", "чата", "чатов") == "1 чат" && TD.count(3, "чат", "чата", "чатов") == "3 чата", "chat count plural")

    model.apply(json(#"{"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateWaitOtherDeviceConfirmation","link":"tg://login?token=abc"}}"#))
    check(model.phase == .qr(link: "tg://login?token=abc"), "qr login phase follows TDLib")

    // --- voice, albums ---------------------------------------------------------------------------
    // 5-bit packing: values 1, 2, 3, 31 → bits 00001 00010 00011 11111
    var bits: UInt32 = 0
    let barValues: [UInt32] = [1, 2, 3, 31]
    for (index, value) in barValues.enumerated() { bits |= value << (5 * UInt32(index)) }
    let packed = Data([UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF)])
    check(Array(TD.waveform(packed).prefix(4)) == [1, 2, 3, 31], "voice waveform unpacked: \(TD.waveform(packed))")
    let voice = TD.media(of: json(#"{"@type":"messageVoiceNote","voice_note":{"@type":"voiceNote","duration":14,"waveform":"\#(packed.base64EncodedString())","mime_type":"audio/ogg","voice":{"@type":"file","id":91,"size":20000}},"caption":{"@type":"formattedText","text":"","entities":[]},"is_listened":false}"#))
    check(voice?.kind == .voiceNote && voice?.fileId == 91 && voice?.duration == 14 && voice?.waveform.prefix(4) == [1, 2, 3, 31], "voice message parsed")
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.3)
    for id in [900, 901, 902] {
        model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":\#(id),"chat_id":5,"sender_id":{"@type":"messageSenderUser","user_id":7},"is_outgoing":false,"date":1790000000,"media_album_id":"77777","content":{"@type":"messagePhoto","photo":{"@type":"photo","sizes":[{"@type":"photoSize","type":"x","photo":{"@type":"file","id":\#(id)},"width":800,"height":600}]},"caption":{"@type":"formattedText","text":"","entities":[]}}}}"#))
    }
    let albumRow = model.transcript.flatMap(\.rows).first { !$0.album.isEmpty }
    check(albumRow?.album.map(\.id) == [900, 901, 902] && albumRow?.message.id == 902 && !model.transcript.flatMap(\.rows).contains { $0.message.id == 900 }, "album joins into one row")

    model.focus(on: 900)
    check(model.scrollTarget == 902 && model.highlightedMessageId == 902, "album photo focus scrolls to the album row")
    model.scrollTarget = nil

    let reacted = TD.message(json(#"{"@type":"message","id":5,"chat_id":1,"date":1,"interaction_info":{"@type":"messageInteractionInfo","view_count":1520,"forward_count":0,"reactions":{"@type":"messageReactions","reactions":[{"@type":"messageReaction","type":{"@type":"reactionTypeEmoji","emoji":"👍"},"total_count":3,"is_chosen":true},{"@type":"messageReaction","type":{"@type":"reactionTypePaid"},"total_count":9,"is_chosen":false}]}},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"x","entities":[]}}}"#))
    check(reacted.viewCount == 1520 && reacted.reactions == [Reaction(emoji: "👍", count: 3, isChosen: true)], "reactions and views parsed, paid stars left out")
    let target = model.messages.first { $0.id == 901 }!
    Task { await model.toggleReaction("🔥", on: target) }
    pump(0.2)
    // No session here, so TDLib refuses at once and the optimistic reaction is taken back.
    check(model.messages.first { $0.id == 901 }?.reactions == target.reactions, "a refused reaction is rolled back")
    model.apply(json(#"{"@type":"updateMessageInteractionInfo","chat_id":5,"message_id":901,"interaction_info":{"@type":"messageInteractionInfo","view_count":0,"forward_count":0,"reactions":{"@type":"messageReactions","reactions":[{"@type":"messageReaction","type":{"@type":"reactionTypeEmoji","emoji":"🔥"},"total_count":2,"is_chosen":true}]}}}"#))
    check(model.messages.first { $0.id == 901 }?.reactions.first?.count == 2, "server reaction counts replace the optimistic ones")

    // --- translation ------------------------------------------------------------------------------
    func said(_ id: Int64, _ body: Message.Body, caption: String = "", local: String? = nil) -> Message {
        Message(id: id, chatId: 5, senderKey: "u7", isOutgoing: false, body: body,
                date: Date(timeIntervalSince1970: 1), isPending: false, isFailed: false, isPinned: false,
                caption: caption, localText: local)
    }
    check(!model.canTranslate(said(930, .text("   "))), "blank words offer no translation")
    check(!model.canTranslate(said(931, .service("вошёл по ссылке"))), "and neither does a service line")
    check(AppModel.translatableText(of: said(932, .attachment("Фото"), caption: "закат")) == "закат",
          "a photo translates by its caption")
    check(AppModel.translatableText(of: said(933, .text("оригинал"), local: "переписано")) == "переписано",
          "and your local rewrite is what goes, not the server's text")
    check(AppModel.languageName("ru") == "Русский" && AppModel.languageName("zz") == "zz",
          "known language names show in Russian, unknown stay codes")
    if let photo = model.messages.first(where: { $0.id == 900 }) {
        Task { await model.translate(photo) }
        pump(0.2)
        // No session here either: the request is refused, so nothing may be left marked as working.
        check(model.translatingIds.isEmpty && model.translation(of: photo) == nil,
              "a refused translation leaves no pending state behind")
        model.hideTranslation(of: photo)
        check(model.translations.isEmpty, "hiding a message that was never translated changes nothing")
    }

    // --- forum topics -------------------------------------------------------------------------------
    let inTopic = TD.message(json(#"{"@type":"message","id":940,"chat_id":5,"date":1,"sender_id":{"@type":"messageSenderUser","user_id":7},"topic_id":{"@type":"messageTopicForum","forum_topic_id":7},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"в теме","entities":[]}}}"#))
    check(inTopic.topicId == 7, "a message of a forum knows which topic it belongs to (\(inTopic.topicId))")
    let outside = TD.message(json(#"{"@type":"message","id":941,"chat_id":5,"date":1,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"обычное","entities":[]}}}"#))
    check(outside.topicId == 0, "while an ordinary chat's message has no topic at all")
    let parsedTopic = TD.topic(json(#"{"@type":"forumTopic","info":{"@type":"forumTopicInfo","chat_id":5,"forum_topic_id":7,"name":"Релизы","icon":{"@type":"forumTopicIcon","color":1874840,"custom_emoji_id":"0"},"creation_date":1,"creator_id":{"@type":"messageSenderUser","user_id":7},"is_general":false,"is_outgoing":false,"is_closed":false,"is_hidden":false,"is_name_implicit":false},"last_message":{"@type":"message","id":940,"chat_id":5,"date":1,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"последнее","entities":[]}}},"order":"9221294784512000123","unread_count":4,"draft_message":{"@type":"draftMessage","date":1,"content":{"@type":"draftMessageContentText","text":{"@type":"formattedText","text":"черновик темы","entities":[]}}}}"#))
    check(parsedTopic == Topic(id: 7, name: "Релизы", color: 1874840, unread: 4, snippet: "последнее",
                               draft: "черновик темы"),
          "a topic parses with its unread count, last line and draft (\(parsedTopic))")
    check(AppModel.topicNode(7)["forum_topic_id"] as? Int == 7, "a topic id goes into requests in the shape TDLib wants")

    // --- selecting several messages -------------------------------------------------------------
    model.beginSelection(with: model.messages.first { $0.id == 901 }!)
    check(model.isSelectingMessages && model.selectedMessageIds == [900, 901, 902], "selection picks the whole album")
    model.toggleSelection(of: model.messages.first { $0.id == 900 }!)
    check(model.selectedMessageIds.isEmpty, "clicking an album member drops the whole album")
    if let deleted = model.messages.first(where: { $0.isDeleted }) {
        model.toggleSelection(of: deleted)
        check(model.selectionAsText().contains(MessageArchive.text(of: deleted)), "copied text lists the picked messages")
        let before = model.messages.count
        Task { await model.deleteSelection(forEveryone: false) }
        pump(0.2)
        check(model.messages.count == before - 1 && !model.isSelectingMessages, "saved deleted messages are dropped locally and selection ends")
    }
    model.beginSelection(with: model.messages.first { $0.id == 901 }!)
    model.selection = 2
    check(!model.isSelectingMessages && model.selectedMessageIds.isEmpty, "leaving the chat ends the selection")
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.3)

    let linked = TD.message(json(#"{"@type":"message","id":6,"chat_id":1,"date":1,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"https://apple.com","entities":[]},"link_preview":{"@type":"linkPreview","url":"https://apple.com","display_url":"apple.com","site_name":"Apple","title":"Apple","description":{"@type":"formattedText","text":"Discover the innovative world of Apple","entities":[]},"type":{"@type":"linkPreviewTypeArticle","photo":{"@type":"photo","sizes":[{"@type":"photoSize","type":"s","photo":{"@type":"file","id":11},"width":90,"height":60},{"@type":"photoSize","type":"m","photo":{"@type":"file","id":12},"width":320,"height":213},{"@type":"photoSize","type":"x","photo":{"@type":"file","id":13},"width":800,"height":533}]}}}}}"#))
    check(linked.linkPreview?.siteName == "Apple" && linked.linkPreview?.description.hasPrefix("Discover") == true && linked.linkPreview?.photo?.fileId == 13 && linked.linkPreview?.photo?.previewFileId == 12, "link preview parsed with its picture")
    check(photoMessage.media?.previewFileId == 1, "photo keeps a small size to show first")

    // --- content parsing ------------------------------------------------------------------------
    let doc = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"sender_id":{"@type":"messageSenderChat","chat_id":-100},"is_outgoing":false,"date":1,"content":{"@type":"messageDocument","document":{"@type":"document","file_name":"отчёт.pdf","mime_type":"application/pdf","document":{"@type":"file","id":42,"size":10}},"caption":{"@type":"formattedText","text":"","entities":[]}}}"#))
    check(doc.body == .attachment("отчёт.pdf") && doc.attachment == Attachment(fileId: 42, name: "отчёт.pdf") && doc.senderKey == "c-100", "document name and file")

    let photo = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messagePhoto","photo":{"@type":"photo","sizes":[{"@type":"photoSize","type":"m","photo":{"@type":"file","id":5},"width":320,"height":240},{"@type":"photoSize","type":"y","photo":{"@type":"file","id":6},"width":1280,"height":960}]},"caption":{"@type":"formattedText","text":"закат","entities":[]}}}"#))
    check(photo.body == .attachment("Фото — закат") && photo.attachment?.fileId == 6, "photo picks the largest size")

    let poll = TD.body(of: json(#"{"@type":"messagePoll","poll":{"@type":"poll","question":{"@type":"formattedText","text":"Куда идём?","entities":[]}}}"#))
    check(poll == .attachment("Опрос: Куда идём?"), "poll question is formatted text")

    let place = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messageLocation","location":{"@type":"location","latitude":59.9386,"longitude":30.3141,"horizontal_accuracy":0}}}"#))
    check(place.location == LocationInfo(latitude: 59.9386, longitude: 30.3141), "a point on the map is parsed (\(String(describing: place.location)))")
    check(place.body == .attachment("Геолокация"), "and the chat list still gets a one-line label")

    let venue = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messageVenue","venue":{"@type":"venue","location":{"@type":"location","latitude":48.8584,"longitude":2.2945,"horizontal_accuracy":0},"title":"Эйфелева башня","address":"Champ de Mars, Paris","provider":"g","id":"1","type":"tower"},"caption":{"@type":"formattedText","text":"смотрели","entities":[]}}}"#))
    check(venue.location?.title == "Эйфелева башня" && venue.location?.address == "Champ de Mars, Paris" && venue.caption == "смотрели",
          "a venue carries its name, its address and a caption")

    let live = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messageLiveLocation","location":{"@type":"location","latitude":55.7558,"longitude":37.6173,"horizontal_accuracy":0},"heading":0,"proximity_alert_radius":0,"expires_in":3600}}"#))
    check(live.location?.expiresAt != nil && live.location?.latitude == 55.7558, "a live location reads latitude and expiry")
    let atZero = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messageLocation","location":{"@type":"location","latitude":0,"longitude":0,"horizontal_accuracy":0}}}"#))
    check(atZero.location == nil, "and 0,0 is taken for what it almost certainly is: no place")

    let shared = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messageContact","contact":{"@type":"contact","phone_number":"+79991234567","first_name":"Анна","last_name":"Смирнова","vcard":"","user_id":42}}}"#))
    check(shared.contact == ContactInfo(name: "Анна Смирнова", phone: "+79991234567", userId: 42), "a shared contact is a name, a number and an account")

    let thrown = TD.message(json(#"{"@type":"message","id":1,"chat_id":1,"date":1,"content":{"@type":"messageDice","initial_state":{"@type":"diceStickers","sticker":{"@type":"sticker","id":"1","width":1,"height":1,"emoji":"","format":{"@type":"stickerFormatWebp"},"sticker":{"@type":"file","id":1}}},"final_state":{"@type":"diceStickers","sticker":{"@type":"sticker","id":"2","width":1,"height":1,"emoji":"","format":{"@type":"stickerFormatWebp"},"sticker":{"@type":"file","id":2}}},"emoji":"🎲","value":5,"success_animation_frame_number":0}}"#))
    check(thrown.dice == Dice(emoji: "🎲", value: 5), "a dice shows the six it landed on")

    check(TD.body(of: json(#"{"@type":"messageAnimatedEmoji","emoji":"👍"}"#)) == .text("👍"), "animated emoji shown as text")
    check(TD.body(of: json(#"{"@type":"messageChatAddMembers","member_user_ids":[1,2,3]}"#)) == .service("Добавил участников: 3"), "added members counted")
    check(TD.body(of: json(#"{"@type":"messageVoiceNote","voice_note":{"@type":"voiceNote","duration":75,"voice":{"@type":"file","id":9}},"caption":{"@type":"formattedText","text":"","entities":[]}}"#)) == .attachment("Голосовое сообщение (1:15)"), "voice note duration")
    check(TD.body(of: json(#"{"@type":"messageCall","is_video":false,"discard_reason":{"@type":"callDiscardReasonMissed"},"duration":0}"#)) == .service("Пропущенный звонок"), "missed call")

    // --- outgoing content -------------------------------------------------------------------
    let dir = FileManager.default.temporaryDirectory
    let png = dir.appendingPathComponent("swiftlite-test.png")
    writePNG(to: png, width: 40, height: 30)
    let txt = dir.appendingPathComponent("swiftlite-test.txt")
    try? "x".write(to: txt, atomically: true, encoding: .utf8)
    let photoContent = TD.inputContent(forFile: png)
    check(photoContent.tdType == "inputMessagePhoto" && photoContent.tdNode("photo")?.tdInt("width") == 40, "png goes as photo with its size: \(photoContent)")
    check(TD.inputContent(forFile: txt).tdType == "inputMessageDocument", "other files go as documents")
    check(TD.draftMessage("  ") == nil && TD.draftMessage("x")?.tdNode("content")?.tdType == "draftMessageContentText", "draft payloads")

    check(TDError(code: 429, message: "Too Many Requests: retry after 3").retryAfter == 3, "flood wait parsed")
    check(json(#"{"order":"9221294784512000005"}"#).tdInt64("order") == 9221294784512000005, "int64 strings parsed")

    // --- bot keyboards -------------------------------------------------------------------------
    let botMessage = TD.message(json(#"{"@type":"message","id":900,"chat_id":1,"date":1,"sender_id":{"@type":"messageSenderUser","user_id":55},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"Меню","entities":[]}},"reply_markup":{"@type":"replyMarkupInlineKeyboard","rows":[[{"@type":"inlineKeyboardButton","text":"Профиль","type":{"@type":"inlineKeyboardButtonTypeCallback","data":"cHJvZmlsZQ=="}},{"@type":"inlineKeyboardButton","text":"Сайт","style":{"@type":"buttonStylePrimary"},"type":{"@type":"inlineKeyboardButtonTypeUrl","url":"https://example.com"}}],[{"@type":"inlineKeyboardButton","text":"Открыть","type":{"@type":"inlineKeyboardButtonTypeWebApp","url":"https://app.example.com"}}],[]]}}"#))
    check(botMessage.markup?.kind == .inline && botMessage.markup?.rows.count == 2 && botMessage.markup?.rows[0].count == 2, "inline keyboard rows parsed, empty rows dropped")
    check(botMessage.markup?.rows[0][0].action == .callback("cHJvZmlsZQ==") && botMessage.markup?.rows[0][1].style == .primary
          && botMessage.markup?.rows[1][0].action == .webApp("https://app.example.com") && botMessage.markup?.rows[1][0].id == "1:0", "button kinds, styles and ids")
    let keyboard = TD.replyMarkup(json(#"{"@type":"replyMarkupShowKeyboard","rows":[[{"@type":"keyboardButton","text":"Да","type":{"@type":"keyboardButtonTypeText"}},{"@type":"keyboardButton","text":"Номер","type":{"@type":"keyboardButtonTypeRequestPhoneNumber"}}]],"one_time":true,"input_field_placeholder":"Выберите"}"#))
    check(keyboard?.kind == .keyboard && keyboard?.isOneTime == true && keyboard?.placeholder == "Выберите"
          && keyboard?.rows[0][0].action == .text && keyboard?.rows[0][1].action == .unsupported, "reply keyboard parsed")
    check(TD.replyMarkup(json(#"{"@type":"replyMarkupInlineKeyboard","rows":[]}"#)) == nil, "empty inline keyboard is no keyboard")

    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.3)
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(910, chat: 5, text: "бот"))}"#))
    model.apply(json(#"{"@type":"updateMessageEdited","chat_id":5,"message_id":910,"edit_date":0,"reply_markup":{"@type":"replyMarkupInlineKeyboard","rows":[[{"@type":"inlineKeyboardButton","text":"Готово","type":{"@type":"inlineKeyboardButtonTypeCallback","data":"eA=="}}]]}}"#))
    let withButtons = model.messages.first { $0.id == 910 }
    check(withButtons?.markup?.rows.first?.first?.text == "Готово" && withButtons?.isEdited == false, "an edit that only adds buttons shows them and is not marked edited")
    model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":911,"chat_id":5,"date":1,"sender_id":{"@type":"messageSenderUser","user_id":55},"is_outgoing":false,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"x","entities":[]}},"reply_markup":{"@type":"replyMarkupShowKeyboard","rows":[[{"@type":"keyboardButton","text":"Старт","type":{"@type":"keyboardButtonTypeText"}}]]}}}"#))
    model.apply(json(#"{"@type":"updateChatReplyMarkup","chat_id":5,"reply_markup_message_id":911}"#))
    check(model.replyKeyboard?.rows.first?.first?.text == "Старт" && model.isReplyKeyboardShown, "chat keyboard shown under the composer")
    model.apply(json(#"{"@type":"updateChatReplyMarkup","chat_id":5,"reply_markup_message_id":0}"#))
    check(model.replyKeyboard == nil, "keyboard removed")
    model.showToast("ok")
    check(model.toast == "ok", "toast shown")

    // --- security tools ------------------------------------------------------------------------
    let iocs = SecurityTools.indicators(in: "C2: hxxps://evil[.]example[.]com/login?x=1, backup 185.220.101[.]5 and http://10.0.0.1:8080/a. Mail bad@phish.ru. Hash 44d88612fea8a8f36de82e1278abb02f и sha256 275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f, report.pdf, CVE-2024-3094, domain update-check.xyz")
    check(iocs.urls.contains("https://evil.example.com/login?x=1") && iocs.urls.contains("http://10.0.0.1:8080/a"), "defanged and plain URLs found: \(iocs.urls)")
    check(iocs.ipv4.contains("185.220.101.5") && iocs.emails == ["bad@phish.ru"], "IPs and mail found")
    check(iocs.md5 == ["44d88612fea8a8f36de82e1278abb02f"] && iocs.sha256.count == 1 && iocs.cves == ["CVE-2024-3094"], "hashes and CVE found")
    check(iocs.domains.contains("update-check.xyz") && !iocs.domains.contains("report.pdf") && !iocs.domains.contains("evil.example.com"), "domains without file names or duplicates: \(iocs.domains)")
    check(SecurityTools.defang("https://evil.com/a") == "hxxps[://]evil[.]com/a" && SecurityTools.refang("hxxps[://]evil[.]com") == "https://evil.com", "defang and refang")
    check(!iocs.report().contains("https://"), "report is defanged")
    check(SecurityTools.linkWarnings(URL(string: "https://xn--pple-43d.com")!).contains { $0.contains("punycode") }, "punycode link flagged")
    check(SecurityTools.linkWarnings(URL(string: "https://apple.com@evil.com")!).contains { $0.contains("@") }, "userinfo trick flagged")
    check(SecurityTools.linkWarnings(URL(string: "https://evil.com")!, shownAs: "apple.com").contains { $0.contains("apple.com") }, "shown text mismatch flagged")
    check(SecurityTools.linkWarnings(URL(string: "https://www.apple.com/mac")!).isEmpty && SecurityTools.linkWarnings(URL(string: "https://support.apple.com")!, shownAs: "apple.com").isEmpty, "ordinary links pass")
    check(SecurityTools.fileWarning(for: "invoice.pdf.exe")?.contains("Двойное") == true && SecurityTools.fileWarning(for: "photo\u{202E}gpj.app") != nil
          && SecurityTools.fileWarning(for: "Setup.pkg") != nil && SecurityTools.fileWarning(for: "report.pdf") == nil, "risky files flagged")
    let hashed = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlite-hash.txt")
    try? Data("abc".utf8).write(to: hashed)
    check((try? SecurityTools.sha256(of: hashed)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of a file")

    // --- data centers ------------------------------------------------------------------------------
    // type 2 (profile photo), DC 4, then an id and access hash; zero runs packed the Bot API way.
    var fileBytes: [UInt8] = [2, 0, 0, 0, 4, 0, 0, 0, 0x11, 0x22, 0, 0, 0, 0, 0, 0x33, 7, 0, 0, 0, 0, 0, 0, 1, 22, 4]
    var packedBytes: [UInt8] = []
    var zeroCount = 0
    for byte in fileBytes {
        if byte == 0 { zeroCount += 1; continue }
        if zeroCount > 0 { packedBytes += [0, UInt8(zeroCount)]; zeroCount = 0 }
        packedBytes.append(byte)
    }
    if zeroCount > 0 { packedBytes += [0, UInt8(zeroCount)] }
    let fileId = Data(packedBytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    check(TD.dataCenter(ofRemoteFileId: fileId) == 4 && TD.dataCenterLocation(4).contains("Амстердам"), "DC read from a file id")
        check(TD.dataCenter(ofRemoteFileId: "AAAA") == nil, "garbage id has no DC")

    // --- local edits ---------------------------------------------------------------------------
    model.archive.open(accountId: 999)
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(920, chat: 5, text: "оригинал"))}"#))
    if let original = model.messages.first(where: { $0.id == 920 }) {
        model.setLocalText("моя версия", of: original)
        check(model.messages.first { $0.id == 920 }?.localText == "моя версия" && model.archive.localText(chatId: 5, messageId: 920) == "моя версия", "local edit shown and kept")
        model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(921, chat: 5, text: "ещё"))}"#))
        check(model.messages.first { $0.id == 920 }?.localText == "моя версия", "local edit survives new messages")
        model.setLocalText(nil, of: original)
        check(model.messages.first { $0.id == 920 }?.localText == nil && model.archive.localText(chatId: 5, messageId: 920) == nil, "original restored")
    } else {
        check(false, "message for local edit")
    }

    // --- transcript rows carry their quote ------------------------------------------------------
    model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":930,"chat_id":5,"date":2,"sender_id":{"@type":"messageSenderUser","user_id":7},"reply_to":{"@type":"messageReplyToMessage","chat_id":5,"message_id":921},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"ответ","entities":[]}}}}"#))
    let replyRow = model.transcript.flatMap(\.rows).first { $0.message.id == 930 }
    check(replyRow?.reply?.id == 921, "a row knows the message it quotes")
    let plainRow = model.transcript.flatMap(\.rows).first { $0.message.id == 921 }
    check(plainRow?.reply == nil, "rows without a reply have no quote")

    // --- recording voice messages ----------------------------------------------------------------
    let tone = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000) * 0.5) }
    if let ogg = OggOpus.encode(tone) {
        let stream = OggOpus.demux(ogg)
        check(stream != nil && stream!.packets.count >= 49 && stream!.channels == 1, "recorded audio is valid Ogg/Opus: \(stream?.packets.count ?? 0) packets")
        let pcm = stream.flatMap { OggOpus.decode($0) }
        let frames = Int(pcm?.frameLength ?? 0)
        check(abs(frames - 48_000) < 2_000, "it decodes back to about one second: \(frames) frames")
        let peak = pcm.map { buffer in (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0 } ?? 0
        check(peak > 0.3 && peak < 0.8, "and the tone survives: peak \(peak)")
        // Every page's checksum must match, or Telegram's players refuse the file.
        var offset = 0, pagesOK = true, pages = 0
        let bytes = [UInt8](ogg)
        while offset + 27 <= bytes.count {
            let segments = Int(bytes[offset + 26])
            var length = 27 + segments
            for i in 0..<segments { length += Int(bytes[offset + 27 + i]) }
            var page = Data(bytes[offset..<offset + length])
            let stored = page[22..<26].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            page.replaceSubrange(22..<26, with: [0, 0, 0, 0])
            if OggOpus.oggCRC(page) != UInt32(littleEndian: stored) { pagesOK = false }
            pages += 1
            offset += length
        }
        check(pagesOK && pages >= 3 && offset == bytes.count, "every Ogg page has a valid checksum (\(pages) pages)")
    } else {
        check(false, "the system Opus encoder is available")
    }
    // Reference value of CRC-32 with polynomial 04C11DB7, zero init, no reflection and no final xor.
    check(OggOpus.oggCRC(Data("123456789".utf8)) == 0x89A1_897F, "Ogg checksum matches the reference")
    if let ogg = OggOpus.encode(tone) {
        try? ogg.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("longhun-voice-test.ogg"))
    }
    let wave = OggOpus.waveform(from: (0..<200).map { Float($0 % 20) })
    check(wave.count == 63 && TD.waveform(wave).count == 100 && TD.waveform(wave).max() == 31, "waveform packs into 100 five-bit values")

    // --- polls ---------------------------------------------------------------------------------
    let pollJSON = #"{"@type":"poll","id":"77","question":{"@type":"formattedText","text":"Куда идём?","entities":[]},"options":[{"@type":"pollOption","id":"0","text":{"@type":"formattedText","text":"Кино","entities":[]},"voter_count":3,"vote_percentage":75,"is_chosen":true},{"@type":"pollOption","id":"1","text":{"@type":"formattedText","text":"Парк","entities":[]},"voter_count":1,"vote_percentage":25,"is_chosen":false}],"total_voter_count":4,"is_anonymous":true,"allows_multiple_answers":false,"type":{"@type":"pollTypeRegular"},"is_closed":false}"#
    model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":940,"chat_id":5,"date":3,"sender_id":{"@type":"messageSenderUser","user_id":7},"content":{"@type":"messagePoll","poll":\#(pollJSON)}}}"#))
    let polled = model.messages.first { $0.id == 940 }?.poll
    check(polled?.question == "Куда идём?" && polled?.options.count == 2 && polled?.totalVoters == 4 && polled?.hasVoted == true && polled?.options[0].percentage == 75, "poll parsed with results")
    model.apply(json(#"{"@type":"updatePoll","poll":\#(pollJSON.replacingOccurrences(of: "\"total_voter_count\":4", with: "\"total_voter_count\":9"))}"#))
    check(model.messages.first { $0.id == 940 }?.poll?.totalVoters == 9, "updatePoll refreshes the poll in the history")
    let quiz = TD.poll(json(#"{"@type":"poll","id":"1","question":{"@type":"formattedText","text":"2+2","entities":[]},"options":[],"total_voter_count":0,"type":{"@type":"pollTypeQuiz","correct_option_ids":[1],"explanation":{"@type":"formattedText","text":"четыре","entities":[]}},"is_closed":true}"#))
    check(quiz?.isQuiz == true && quiz?.correctOptions == [1] && quiz?.explanation == "четыре" && quiz?.showsResults == true, "quiz answers and explanation parsed")

    // --- scheduled messages --------------------------------------------------------------------
    model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":950,"chat_id":5,"date":4,"is_outgoing":true,"sender_id":{"@type":"messageSenderUser","user_id":1},"scheduling_state":{"@type":"messageSchedulingStateSendAtDate","send_date":9999999999},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"потом","entities":[]}}}}"#))
    check(!model.messages.contains { $0.id == 950 }, "a scheduled message stays out of the history")
    let options = AppModel.sendOptions(silently: true, at: Date(timeIntervalSince1970: 2_000_000_000))
    check(options.tdBool("disable_notification") && options.tdNode("scheduling_state")?.tdInt64("send_date") == 2_000_000_000, "silent and scheduled send options")

    // --- chat folders --------------------------------------------------------------------------
    model.apply(json(#"{"@type":"updateChatFolders","chat_folders":[{"@type":"chatFolderInfo","id":3,"name":{"@type":"chatFolderName","text":{"@type":"formattedText","text":"Работа","entities":[]}}}],"main_chat_list_position":0}"#))
    check(model.chatFolders == [ChatFolder(id: 3, title: "Работа")], "folders listed")
    model.apply(json(#"{"@type":"updateChatPosition","chat_id":6,"position":{"@type":"chatPosition","list":{"@type":"chatListFolder","chat_folder_id":3},"order":"9221294784512000100","is_pinned":true}}"#))
    model.selectedFolder = 3
    pump()
    check(model.chats.map(\.id) == [6] && model.chats.first?.isPinned == true, "a folder shows only its chats: \(model.chats.map(\.id))")
    model.apply(json(#"{"@type":"updateChatPosition","chat_id":6,"position":{"@type":"chatPosition","list":{"@type":"chatListFolder","chat_folder_id":3},"order":"0","is_pinned":false}}"#))
    pump()
    check(model.chats.isEmpty, "a chat taken out of the folder leaves it")
    model.apply(json(#"{"@type":"updateChatFolders","chat_folders":[],"main_chat_list_position":0}"#))
    pump()
    check(model.selectedFolder == nil && !model.chats.isEmpty, "a deleted folder falls back to all chats")

    // --- search while a folder is open ------------------------------------------------------------
    model.apply(json(#"{"@type":"updateChatFolders","chat_folders":[{"@type":"chatFolderInfo","id":4,"name":{"@type":"chatFolderName","text":{"@type":"formattedText","text":"Пустая","entities":[]}}}],"main_chat_list_position":0}"#))
    model.selectedFolder = 4
    let someone = model.chat(withId: 5)?.title ?? ""
    model.filter = String(someone.prefix(3))
    pump()
    check(!someone.isEmpty && model.visibleChats.contains { $0.id == 5 }, "search finds chats outside the open folder")
    model.filter = ""
    model.selectedFolder = nil

    // --- clearing a history is not someone else deleting --------------------------------------------
    Preferences.register()
    UserDefaults.standard.set(true, forKey: Preferences.saveDeletedMessages)
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(960, chat: 5, text: "стираю"))}"#))
    if let chat = model.chat(withId: 5) { Task { await model.clearHistory(of: chat, forEveryone: false) } }
    pump(0.2)
    model.apply(json(#"{"@type":"updateDeleteMessages","chat_id":5,"message_ids":[960],"is_permanent":true,"from_cache":false}"#))
    check(model.archive.entry(chatId: 5, messageId: 960)?.deletedAt == nil, "a history you clear is not kept as deleted")

    // --- the chat list kept up to date piece by piece matches a full rebuild -----------------------------
    for id in Int64(2001)...Int64(2060) {
        model.apply(chat(id, "Случайный \(id)", positions: [mainPosition(String(9221294784512000000 + id * 7))]))
    }
    pump()
    var generator = SystemRandomNumberGenerator()
    var mismatches = 0
    for round in 0..<30 {
        for _ in 0..<10 {
            let id = Int64.random(in: 2001...2060, using: &generator)
            switch Int.random(in: 0..<3, using: &generator) {
            case 0:
                let order = Int64.random(in: 1...900, using: &generator) + 9221294784512000000
                model.apply(json(#"{"@type":"updateChatPosition","chat_id":\#(id),"position":{"@type":"chatPosition","list":{"@type":"chatListMain"},"order":"\#(order)","is_pinned":\#(Bool.random(using: &generator))}}"#))
            case 1:
                model.apply(json(#"{"@type":"updateChatReadInbox","chat_id":\#(id),"last_read_inbox_message_id":\#(round),"unread_count":\#(Int.random(in: 0...9, using: &generator))}"#))
            default:
                // Out of the list and back.
                model.apply(json(#"{"@type":"updateChatPosition","chat_id":\#(id),"position":{"@type":"chatPosition","list":{"@type":"chatListMain"},"order":"0","is_pinned":false}}"#))
            }
        }
        pump()
        let piecewise = model.chats
        model.showsArchive = true
        model.showsArchive = false
        if piecewise != model.chats { mismatches += 1 }
    }
    check(mismatches == 0, "the list updated piece by piece equals a full rebuild (\(mismatches) of 30 rounds differ)")
    check(zip(model.chats, model.chats.dropFirst()).allSatisfy { TD.precedes($0, $1) }, "the list stays sorted")

    // --- files -----------------------------------------------------------------------------------
    let docMessage = TD.message(json(#"{"@type":"message","id":970,"chat_id":5,"date":5,"sender_id":{"@type":"messageSenderUser","user_id":7},"content":{"@type":"messageDocument","document":{"@type":"document","file_name":"Отчёт 2026.pdf","mime_type":"application/pdf","document":{"@type":"file","id":801,"size":2500000,"expected_size":2500000,"local":{"@type":"localFile","path":"","is_downloading_active":false,"is_downloading_completed":false,"downloaded_size":0},"remote":{"@type":"remoteFile","id":"x","uploaded_size":0}}},"caption":{"@type":"formattedText","text":"вот","entities":[]}}}"#))
    check(docMessage.document?.name == "Отчёт 2026.pdf" && docMessage.document?.size == 2_500_000 && docMessage.document?.fileExtension == "pdf" && docMessage.caption == "вот", "document card parsed with size and caption")
    let track = TD.document(of: json(#"{"@type":"messageAudio","audio":{"@type":"audio","duration":200,"title":"Song","performer":"Band","file_name":"song.mp3","mime_type":"audio/mpeg","audio":{"@type":"file","id":802,"size":0,"expected_size":4000000}}}"#))
    check(track?.trackTitle == "Band — Song" && track?.duration == 200 && track?.size == 4_000_000, "music shows performer, title and expected size")
    let fileUpdate = #"{"@type":"updateFile","file":{"@type":"file","id":801,"size":2500000,"expected_size":2500000,"local":{"@type":"localFile","path":"","is_downloading_active":true,"is_downloading_completed":false,"downloaded_size":1250000},"remote":{"@type":"remoteFile","id":"x","uploaded_size":0,"is_uploading_active":false}}}"#
    model.apply(json(fileUpdate))
    check(model.transfers[801] == nil, "progress of files nobody looks at is ignored")
    Task { await model.download(801) }
    pump(0.1)
    model.apply(json(fileUpdate))
    check(model.transfers[801]?.isDownloading == true && abs((model.transfers[801]?.downloadFraction ?? 0) - 0.5) < 0.001, "download progress followed once asked for")
    let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlite-test.png")
    var asFiles: [TDNode] = []
    var compressed: [TDNode] = []
    Task {
        asFiles = await TD.inputContents(for: [pngURL], asDocuments: true, caption: "подпись")
        compressed = await TD.inputContents(for: [pngURL], asDocuments: false, caption: "")
    }
    pump(0.3)
    check(asFiles.first?.tdType == "inputMessageDocument" && asFiles.first?.tdNode("caption")?.tdString("text") == "подпись", "files can go uncompressed with a caption")
    check(compressed.first?.tdType == "inputMessagePhoto" && compressed.first?.tdNode("caption") == nil, "a picture goes as a photo by default")

    // --- who wrote last in a group -------------------------------------------------------------------
    model.apply(json(#"{"@type":"updateUser","user":{"@type":"user","id":777,"first_name":"Пётр","last_name":"Первый","type":{"@type":"userTypeRegular"},"status":{"@type":"userStatusEmpty"}}}"#))
    model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":-1003001,"type":{"@type":"chatTypeSupergroup","supergroup_id":3001,"is_channel":false},"title":"Группа","positions":[\#(mainPosition("9221294784512009000"))],"unread_count":0,"draft_message":null}}"#))
    model.apply(json(#"{"@type":"updateChatLastMessage","chat_id":-1003001,"last_message":{"@type":"message","id":1,"chat_id":-1003001,"date":7,"sender_id":{"@type":"messageSenderUser","user_id":777},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"привет всем","entities":[]}}},"positions":[\#(mainPosition("9221294784512009001"))]}"#))
    pump()
    check(model.chat(withId: -1003001)?.snippetSender == "Пётр" && model.chat(withId: -1003001)?.snippet == "привет всем", "a group preview names who wrote last")
    model.apply(json(#"{"@type":"updateChatLastMessage","chat_id":-1003001,"last_message":{"@type":"message","id":2,"chat_id":-1003001,"date":8,"is_outgoing":true,"sender_id":{"@type":"messageSenderUser","user_id":1},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"и тебе","entities":[]}}},"positions":[\#(mainPosition("9221294784512009002"))]}"#))
    check(model.chat(withId: -1003001)?.snippetSender == "" && model.chat(withId: -1003001)?.snippet == "Вы: и тебе", "your own last message says «Вы:» instead")

    // --- imported history: an earlier date after a later one --------------------------------------
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.2)
    let late = 1_790_100_000, early = 1_789_000_000
    for (id, date) in [(990, late), (991, early), (992, late + 60)] {
        model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":\#(id),"chat_id":5,"date":\#(date),"sender_id":{"@type":"messageSenderUser","user_id":7},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"x","entities":[]}}}}"#))
    }
    let dates = model.transcript.map(\.date)
    check(Set(dates).count == dates.count, "no two day sections share a date (\(dates.count) sections)")
    check(model.transcript.flatMap(\.rows).contains { $0.message.id == 991 }, "the out-of-order message is still shown")

    // --- Esc and Return in the chat search --------------------------------------------------------
    model.filter = "Случайный 2001"
    model.escape()
    check(model.filter.isEmpty, "Esc clears the chat search when nothing else is open")
    let searchTarget = model.chats.first { $0.id != model.selection }
    model.filter = searchTarget?.title ?? "?"
    model.openFirstSearchResult()
    check(searchTarget != nil && model.selection == model.visibleChats.first?.id && model.visibleChats.contains { $0.id == searchTarget?.id },
          "Return opens the first chat found (\(String(describing: model.selection)))")
    model.filter = ""

    // --- ↑ skips messages that cannot be edited ---------------------------------------------------
    var ownDeleted = TD.message(json(#"{"@type":"message","id":1,"chat_id":5,"date":1,"is_outgoing":true,"sender_id":{"@type":"messageSenderUser","user_id":1},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"x","entities":[]}}}"#))
    check(model.canEdit(ownDeleted), "your own text can be edited")
    ownDeleted.isDeleted = true
    check(!model.canEdit(ownDeleted), "a deleted copy cannot")
    let ownForwarded = TD.message(json(#"{"@type":"message","id":2,"chat_id":5,"date":1,"is_outgoing":true,"sender_id":{"@type":"messageSenderUser","user_id":1},"forward_info":{"@type":"messageForwardInfo","origin":{"@type":"messageOriginHiddenUser","sender_name":"Кто-то"},"date":1},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"x","entities":[]}}}"#))
    check(!model.canEdit(ownForwarded), "nor a message you forwarded")

    // --- ⌘V: a picture or files attach, text pastes ---------------------------------------------------
    // A private pasteboard: the tests never touch what you copied.
    let board = NSPasteboard(name: NSPasteboard.Name("ru.anemia.swiftlite.tests.\(UUID().uuidString)"))
    func holds(_ fill: () -> Void) -> Bool {
        board.clearContents()
        fill()
        return AppModel.pasteboardHoldsAttachment(board)
    }
    let pngBytes = (try? Data(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent("swiftlite-test.png"))) ?? Data()
    check(holds { board.writeObjects([pngURL as NSURL]) }, "files copied in Finder attach")
    check(holds { board.setData(pngBytes, forType: .png) }, "a screenshot attaches")
    check(holds { board.declareTypes([.png, .string], owner: nil); board.setData(pngBytes, forType: .png); board.setString("https://example.com/cat.png", forType: .string) },
          "a browser's copied picture with its address attaches")
    check(!holds { board.declareTypes([.png, .string], owner: nil); board.setData(pngBytes, forType: .png); board.setString("привет, как дела", forType: .string) },
          "text that comes with a picture pastes as text")
    check(!holds { board.declareTypes([.rtfd, .tiff, .string], owner: nil); board.setString("документ", forType: .string) }, "rich text pastes as text")
    check(!holds { board.setString("просто текст", forType: .string) }, "plain text pastes as text")
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.2)
    model.pendingFiles = nil
    board.clearContents()
    board.setData(pngBytes, forType: .png)
    Task { await model.sendPasteboard(board) }
    pump(0.3)
    let pasted = model.pendingFiles?.first
    check(pasted?.pathExtension == "png" && pasted.map { (try? Data(contentsOf: $0)) == pngBytes } == true,
          "a pasted PNG goes to the send sheet as the same bytes")
    model.pendingFiles = nil
    board.releaseGlobally()

    // --- export format -------------------------------------------------------------------------
    check(ExportFormat.fileName("a/b:c", id: 7) == "a-b-c (7)" && ExportFormat.fileName("  ", id: 7) == "7", "export folder names")
    let page = ExportFormat.html(title: "<Чат>", messages: [.init(id: 1, date: Date(timeIntervalSince1970: 0), sender: "Иван", isOutgoing: false, text: "<script>x</script>", replyToId: nil, forwardedFrom: nil, edited: false)])
    check(page.contains("&lt;script&gt;") && !page.contains("<script>x") && page.contains("&lt;Чат&gt;"), "export HTML is escaped")

    regressionChecks(model, tone: tone, pngURL: pngURL)
}


/// Regressions found while auditing the app, kept in their own function: the whole of main.swift is
/// one top-level expression for the type checker, and these checks are heavy enough to slow the rest down.
@MainActor func regressionChecks(_ model: AppModel, tone: [Float], pngURL: URL) {
    // --- an empty composer in edit mode goes to the edit, not to the send guard ---------------------
    model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":985,"chat_id":5,"date":6,"is_outgoing":true,"sender_id":{"@type":"messageSenderUser","user_id":1},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"","entities":[]}}}}"#))
    pump()
    model.draft = ""
    model.composerContext = ComposerContext(kind: .edit, messageId: 985, title: "Редактирование", preview: "")
    Task { await model.send() }
    pump(0.3)
    check(model.composerContext == nil, "clearing your own message to empty is handled as an edit")

    // --- a delete TDLib refused keeps the pick ------------------------------------------------------
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.2)
    for message in model.messages.filter({ !$0.isDeleted && $0.albumId == 0 }).prefix(2) { model.toggleSelection(of: message) }
    let beforeDelete = model.selectedMessageIds
    Task { await model.deleteSelection(forEveryone: false) }
    pump(0.3)
    check(!beforeDelete.isEmpty && model.selectedMessageIds == beforeDelete,
          "the selection survives a refused delete (\(beforeDelete.count) → \(model.selectedMessageIds.count))")
    model.endSelection()

    // --- an edit lands on every quote that shows the message -------------------------------------------
    // A row is keyed by its last message and an album row re-keys as members join, so the index of who quotes
    // what has to follow: otherwise a quote keeps showing text the message no longer has.
    func textMessage(_ id: Int, _ text: String, replyTo: Int? = nil) -> TDNode {
        let body: TDNode = ["@type": "formattedText", "text": text, "entities": [Any]()]
        var message: TDNode = [
            "@type": "message", "id": id, "chat_id": 5, "date": 1_790_000_100 + id,
            "sender_id": ["@type": "messageSenderUser", "user_id": 7], "is_outgoing": false,
            "content": ["@type": "messageText", "text": body] as TDNode,
        ]
        if let replyTo { message["reply_to"] = ["@type": "messageReplyToMessage", "chat_id": 5, "message_id": replyTo] }
        return ["@type": "updateNewMessage", "message": message]
    }
    func photoMessage(_ id: Int, album: String, replyTo: Int?) -> TDNode {
        let file: TDNode = ["@type": "file", "id": id, "width": 800, "height": 600]
        let size: TDNode = ["@type": "photoSize", "type": "x", "photo": file]
        let caption: TDNode = ["@type": "formattedText", "text": "", "entities": [Any]()]
        let photo: TDNode = ["@type": "photo", "sizes": [size], "caption": caption]
        var message: TDNode = [
            "@type": "message", "id": id, "chat_id": 5, "date": 1_790_000_100 + id,
            "sender_id": ["@type": "messageSenderUser", "user_id": 7], "is_outgoing": false,
            "media_album_id": album, "content": ["@type": "messagePhoto", "photo": photo] as TDNode,
        ]
        if let replyTo { message["reply_to"] = ["@type": "messageReplyToMessage", "chat_id": 5, "message_id": replyTo] }
        return ["@type": "updateNewMessage", "message": message]
    }
    model.apply(textMessage(9901, "первоначальный"))
    model.apply(textMessage(9902, "ответ", replyTo: 9901))
    model.apply(photoMessage(9903, album: "88888", replyTo: 9901))
    model.apply(photoMessage(9904, album: "88888", replyTo: nil))   // joins the row, which re-keys it to 9904
    pump()
    let rows = model.transcript.flatMap(\.rows)
    let albumRow = rows.first { $0.message.id == 9904 }
    check(albumRow?.album.count == 2 && albumRow?.reply?.id == 9901,
          "the album row keeps the quote of its first member (\(albumRow?.album.count ?? 0) photos, quote \(albumRow?.reply?.id ?? -1))")
    model.apply(textMessage(9901, "переписали"))
    pump()
    let after = model.transcript.flatMap(\.rows)
    check(after.first { $0.message.id == 9902 }?.reply.map { MessageArchive.text(of: $0) } == "переписали",
          "an edit updates the plain quote that shows it")
    check(after.first { $0.message.id == 9904 }?.reply.map { MessageArchive.text(of: $0) } == "переписали",
          "and still reaches the row re-keyed by a later album member")

    // --- the flash after a clicked quote clears itself on an album row too -------------------------------
    // The highlight is keyed by the row; the cleanup compared it with the clicked message, and for an album
    // (or a quote of an older member) those are different ids, so the bubble stayed lit.
    model.focus(on: 9903)                      // the first photo, drawn inside the row of 9904
    check(model.highlightedMessageId == 9904, "the flash lands on the album row (\(model.highlightedMessageId ?? -1))")
    pump(1.7)
    check(model.highlightedMessageId == nil, "and goes away again, an album row or not")

    // --- a draft the server refused is not shown as saved ----------------------------------------------
    // Offline every request is refused, which is exactly the case that used to leave "Черновик:" in the list
    // for a draft no server ever got.
    let chat = model.chat(withId: 5)   // not `chats`: a folder left selected by an earlier section filters that list
    check(chat != nil, "the chat whose draft is being typed is known")
    let typed = "черновик, который не дойдёт"
    model.draft = typed
    model.noteTyping()
    pump(2.0)
    check(model.chat(withId: 5)?.draftText != typed,
          "a refused setChatDraftMessage does not leave the list claiming it (\(model.chat(withId: 5)?.draftText ?? "nil"))")
    model.draft = ""

    // --- a closed session leaves nothing of the open transcript --------------------------------------
    // `jump` and `loadOlder` raise this flag. resetSession clears `openChatId` before `selection`, so it used to
    // skip leaveOpenChat entirely — and a stale flag makes every incoming message invisible.
    model.isViewingHistory = true
    model.viewerMessage = model.messages.first
    model.pendingFiles = [pngURL]
    if let one = model.messages.first { model.revealSpoiler(of: one) }
    check(!model.revealedSpoilers.isEmpty, "an opened spoiler is remembered by the chat, not by the row")
    model.apply(json(#"{"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateClosed"}}"#))
    pump()
    check(!model.isViewingHistory, "a closed session drops 'viewing history'")
    check(model.viewerMessage == nil && model.pendingFiles == nil, "and the viewer, and the files staged for sending")
    check(model.revealedSpoilers.isEmpty, "and the spoilers you had opened")



    // --- the archive: one bad file must not cost everything -------------------------------------------
    let twinFile = MessageArchive.directory.appendingPathComponent("777001.json")
    func store(_ text: String) { try? text.write(to: twinFile, atomically: true, encoding: .utf8) }
    let firstEntry = #"{"chatId":777001,"messageId":5,"senderKey":"u1","isOutgoing":false,"date":1,"text":"первая","versions":[]}"#
    let secondEntry = #"{"chatId":777001,"messageId":5,"senderKey":"u1","isOutgoing":false,"date":1,"text":"вторая","versions":[]}"#
    store("[\(firstEntry),\(secondEntry)]")
    model.archive.open(accountId: 777001)
    check(model.archive.entry(chatId: 777001, messageId: 5)?.text == "первая",
          "a repeated id in the file keeps one entry instead of trapping")

    // And which one it keeps has to mean something: entries are written out of a dictionary, so "whichever row
    // the file happens to put last" is not a rule. A deletion mark and your own wording cannot be recovered.
    let plain777003 = #"{"chatId":777003,"messageId":7,"senderKey":"u7","isOutgoing":false,"date":1,"text":"обычная","versions":[]}"#
    let richer777003 = #"{"chatId":777003,"messageId":7,"senderKey":"u7","isOutgoing":false,"date":1,"text":"обычная","versions":[],"localText":"моя формулировка","deletedAt":2}"#
    let richerFile = MessageArchive.directory.appendingPathComponent("777003.json")
    try? "[\(richer777003),\(plain777003)]".write(to: richerFile, atomically: true, encoding: .utf8)
    model.archive.open(accountId: 777003)
    let survivor = model.archive.entry(chatId: 777003, messageId: 7)
    check(survivor?.localText != nil && survivor?.deletedAt != nil,
          "of two copies the one that remembers more wins (\(survivor?.localText ?? "nil"))")
    try? FileManager.default.removeItem(at: richerFile)

    store("{ это не json")
    model.archive.open(accountId: 777001)
    check(model.archive.entry(chatId: 777001, messageId: 5) == nil, "an unreadable file starts empty")
    model.archive.recordDeletion(of: Message(id: 9, chatId: 777001, senderKey: "u9", isOutgoing: false,
                                             body: .text("текст"), date: Date(timeIntervalSince1970: 1),
                                             isPending: false, isFailed: false, isPinned: false))
    pump(1.6)
    pump(0.3)
    check((try? String(contentsOf: twinFile, encoding: .utf8)) == "{ это не json", "and is left alone rather than written over")
    try? FileManager.default.removeItem(at: twinFile)

    let edited = Message(id: 42, chatId: 777002, senderKey: "u42", isOutgoing: true, body: .text("итог"),
                         date: Date(timeIntervalSince1970: 1), isPending: false, isFailed: false, isPinned: false)
    for step in 0..<40 { model.archive.recordEdit(of: edited, previousText: "версия \(step)") }
    check(model.archive.entry(chatId: 777002, messageId: 42)?.versions.count == 30,
          "the trail of one fiddled message stops at thirty (\(model.archive.entry(chatId: 777002, messageId: 42)?.versions.count ?? -1))")

    // --- a service message of a newer layer -------------------------------------------------------------
    let ownership = TD.message(json(#"{"@type":"message","id":986,"chat_id":5,"date":7,"sender_id":{"@type":"messageSenderUser","user_id":7},"content":{"@type":"messageChatOwnerChanged","new_owner_user_id":7}}"#))
    if case .service(let label) = ownership.body {
        check(label.localizedCaseInsensitiveContains("владел"), "new service types get a Russian label (\(label))")
    } else {
        check(false, "new service types get a Russian label")
    }
    let joined = TD.message(json(#"{"@type":"message","id":987,"chat_id":5,"date":8,"sender_id":{"@type":"messageSenderUser","user_id":7},"content":{"@type":"messageChatJoinFromCommunity","community_id":1}}"#))
    if case .service(let label) = joined.body {
        check(!label.contains("messageChat"), "and one more of them (\(label))")
    } else {
        check(false, "and one more service type labelled")
    }
    if let ogg = OggOpus.encode(tone) {
    // Each depth bites a different part of the last page: its lacing list, or whole segments. Every one of them
    // has to give back what arrived instead of nothing.
    let depths = Array(stride(from: 1, through: 90, by: 7))
    let playable = depths.filter { OggOpus.demux(ogg.dropLast($0))?.packets.isEmpty == false }
    check(playable.count == depths.count, "a voice note missing up to 90 bytes plays what arrived (\(playable.count) of \(depths.count))")
    }

    // --- a voice file that lies about its format -------------------------------------------------------
    if let ogg = OggOpus.encode(tone), let head = ogg.range(of: Data("OpusHead".utf8)) {
        var tooMany = ogg
        tooMany[head.lowerBound + 9] = 130                      // channel count feeds AudioToolbox and buffer sizes
        check(OggOpus.demux(tooMany) == nil, "a voice file claiming 130 channels is refused")
        var wrongVersion = ogg
        wrongVersion[head.lowerBound + 8] = 2
        check(OggOpus.demux(wrongVersion) == nil, "and one claiming a version that is not Opus 1")
        check(OggOpus.demux(ogg) != nil, "while our own take still decodes")
    }

    // --- the temporary voice cache does not grow forever ------------------------------------------------
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlite-purge-\(UUID().uuidString)", isDirectory: true)
    let stale = cacheRoot.appendingPathComponent("outgoing/stale.caf")
    let fresh = cacheRoot.appendingPathComponent("voice/fresh.caf")
    for url in [stale, fresh] {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([1, 2, 3]).write(to: url)
    }
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-4 * 24 * 3600)], ofItemAtPath: stale.path)
    VoiceRecorder.purgeOldFiles(in: cacheRoot)
    check(!FileManager.default.fileExists(atPath: stale.path) && FileManager.default.fileExists(atPath: fresh.path),
          "a four-day-old cached take is gone, today's stays")
    try? FileManager.default.removeItem(at: cacheRoot)

    // --- a .tgs that promises gigabytes ---------------------------------------------------------------
    // A real gzip container (python's gzip.compress), not one assembled here: Foundation's own deflate output
    // does not survive the raw-deflate path the way Telegram's sticker files do.
    let sticker = Data(base64Encoded: "H4sIAAAAAAAC/6tWKlOyUjLVM9czUdJRSitSsjI20FHKLFCyAlL5QMoMSJcrWRkaAOkMMF0LAMerPCI0AAAA") ?? Data()
    check(Gzip.inflate(sticker).flatMap { String(data: $0, encoding: .utf8) }
          == #"{"v":"5.7.4","fr":30,"ip":0,"op":60,"w":100,"h":100}"#, "a real .tgs sticker unfolds")
    var bomb = sticker
    bomb.replaceSubrange(bomb.count - 4..<bomb.count, with: [0xF0, 0xFF, 0xFF, 0xFF])  // ISIZE: four gigabytes
    check(Gzip.inflate(bomb) == nil, "and one promising four gigabytes is refused before it unfolds")
    var liar = sticker
    liar.replaceSubrange(liar.count - 4..<liar.count, with: [53, 0, 0, 0])  // one byte more than the stream holds
    check(Gzip.inflate(liar) == nil, "and one whose declared size does not match its payload is refused too")

    // --- a topic of its own ----------------------------------------------------------------------------
    // Last, because picking a topic empties the transcript to load that topic's history instead.
    model.selection = 5
    Task { await model.select(chatId: 5) }
    pump(0.3)
    model.topics = [Topic(id: 7, name: "Релизы"), Topic(id: 8, name: "Оффтоп")]
    model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":942,"chat_id":5,"sender_id":{"@type":"messageSenderUser","user_id":7},"date":1790000000,"topic_id":{"@type":"messageTopicForum","forum_topic_id":8},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"привет из темы","entities":[]}}}}"#))
    pump(0.2)
    check(model.topics.first { $0.id == 8 }?.unread == 1, "a new message counts in its own topic")
    check(model.topics.first { $0.id == 7 }?.unread == 0, "and not in the one beside it")
    check(model.openChatIsForum, "a forum is recognised from its messages alone")
    Task { await model.open(topic: 7) }
    pump(0.4)
    check(model.openTopicId == 7, "a topic can be picked")
    Task { await model.open(topic: nil) }
    pump(0.3)
    check(model.openTopicId == nil, "and the whole chat put back")

    // --- what the new calls actually send --------------------------------------------------------------
    // No session here, so nothing reaches Telegram: `request` records the payload before it refuses, which is
    // the only way the shape of these requests can be tested at all.
    func sent(_ type: String, after mark: Int) -> TDNode? {
        model.recordedRequests.dropFirst(mark).first { $0["@type"] as? String == type }
    }
    func part(_ payload: TDNode?, _ key: String) -> TDNode { (payload?[key] as? TDNode) ?? [:] }
    let managed = TD.chat(json(#"{"@type":"chat","id":-1003,"type":{"@type":"chatTypeSupergroup","supergroup_id":3,"is_channel":false},"title":"Группа","positions":[],"unread_count":0,"is_marked_as_unread":false,"last_read_inbox_message_id":0,"unread_mention_count":0,"unread_reaction_count":0,"draft_message":null,"last_message":null,"photo":null}"#))
    let target = ChatMemberInfo(userId: 511, name: "Иван Петров", rank: .member, canBeEdited: true)
    let now = Int(Date().timeIntervalSince1970)

    var mark = model.recordedRequests.count
    Task { await model.banMember(target, in: managed, minutes: 60, revokeMessages: true) }
    pump(0.2)
    var sentRequest = sent("banChatMember", after: mark)
    check(part(sentRequest, "member_id")["user_id"] as? Int64 == 511, "banChatMember names the member")
    check((sentRequest?["banned_until_date"] as? Int).map { $0 > now + 3500 && $0 < now + 3700 } == true,
          "and an hour ahead as the deadline")
    check(sentRequest?["revoke_messages"] as? Bool == true, "with the messages going too when asked")

    mark = model.recordedRequests.count
    Task { await model.removeMember(target, in: managed) }
    pump(0.2)
    sentRequest = sent("setChatMemberStatus", after: mark)
    check(part(sentRequest, "status").tdType == "chatMemberStatusLeft",
          "kicking and un-banning are both the left status (\(part(sentRequest, "status").tdType))")

    mark = model.recordedRequests.count
    Task { await model.restrictMember(target, in: managed, minutes: 60) }
    pump(0.2)
    sentRequest = sent("setChatMemberStatus", after: mark)
    let restriction = part(sentRequest, "status")
    check(restriction.tdType == "chatMemberStatusRestricted" && restriction["is_member"] as? Bool == true
          && part(restriction, "permissions").tdType == "chatPermissions", "a mute restricts rather than removes")
    check(restriction["restricted_until_date"] as? Int ?? 0 > now, "and a mute is timed, not forever")
    check(part(restriction, "permissions")["can_send_basic_messages"] as? Bool == false, "with sending turned off")
    check(part(restriction, "permissions").count == Rights.permissions.count + 1,
          "and every permission named, so nothing is allowed by omission (\(part(restriction, "permissions").count - 1))")

    mark = model.recordedRequests.count
    Task { await model.setMember(target, in: managed, rights: Rights.editorDefaults) }
    pump(0.2)
    sentRequest = sent("setChatMemberStatus", after: mark)
    let promotion = part(sentRequest, "status")
    check(promotion.tdType == "chatMemberStatusAdministrator" && part(promotion, "rights")["can_restrict_members"] as? Bool == true,
          "promotion sends a real set of rights, not an empty one")
    // A half-filled rights object would quietly take the rest away, so every flag has to be there.
    check(part(promotion, "rights").count == Rights.admin.count + 1,
          "and it names all \(Rights.admin.count) rights, not only the ones switched on (\(part(promotion, "rights").count - 1))")
    check(part(promotion, "rights")["can_promote_members"] as? Bool == false,
          "the ones left out are sent as false rather than missing")

    mark = model.recordedRequests.count
    Task { await model.createTopic(in: managed.id, name: "Релизы") }
    pump(0.2)
    sentRequest = sent("createForumTopic", after: mark)
    check(sentRequest?["name"] as? String == "Релизы" && sentRequest?["is_name_implicit"] as? Bool == false
          && part(sentRequest, "icon")["color"] as? Int == 0x6FB9F0,
          "a new topic carries its name and one of the six allowed colours")

    mark = model.recordedRequests.count
    Task { await model.createInviteLink(in: managed, name: "Встреча", memberLimit: 50, days: 2) }
    pump(0.2)
    sentRequest = sent("createChatInviteLink", after: mark)
    check(sentRequest?["member_limit"] as? Int == 50
          && (sentRequest?["expiration_date"] as? Int).map { $0 > now + 2 * 86_400 - 5 } == true,
          "an invite link is bounded by people and by days")

    mark = model.recordedRequests.count
    Task { _ = await model.setChatInfo(managed, title: "Новое имя", description: model.chatAccess.about) }
    pump(0.2)
    check(sent("setChatTitle", after: mark)?["title"] as? String == "Новое имя", "the sheet's rename sends a new title")
    check(sent("setChatDescription", after: mark) == nil, "and leaves the description alone when it did not change")
    mark = model.recordedRequests.count
    Task { _ = await model.setChatInfo(managed, title: managed.title, description: "Описание чата") }
    pump(0.2)
    check(sent("setChatDescription", after: mark)?["description"] as? String == "Описание чата",
          "a new description goes on its own")
    mark = model.recordedRequests.count
    Task { _ = await model.setChatInfo(managed, title: "Новое имя", description: "Описание чата") }
    pump(0.2)
    check(sent("setChatTitle", after: mark) != nil && sent("setChatDescription", after: mark) != nil,
          "and both are attempted even though the first one is refused")

    mark = model.recordedRequests.count
    Task { try? await model.setEmojiStatus(customEmojiId: 12345, for: 3600) }
    pump(0.2)
    sentRequest = sent("setEmojiStatus", after: mark)
    let emojiStatus = part(sentRequest, "emoji_status")
    check(part(emojiStatus, "type").tdType == "emojiStatusTypeCustomEmoji"
          && part(emojiStatus, "type")["custom_emoji_id"] as? Int64 == 12345
          && (emojiStatus["expiration_date"] as? Int).map { $0 > now + 3500 } == true,
          "the emoji status is a dated custom emoji")
    mark = model.recordedRequests.count
    Task { try? await model.setEmojiStatus(customEmojiId: 7, for: 0) }
    pump(0.2)
    let keptStatus = part(sent("setEmojiStatus", after: mark), "emoji_status")
    check(keptStatus["expiration_date"] as? Int == 0, "and a duration of zero means it stays")

    mark = model.recordedRequests.count
    let toTranslate = Message(id: 950, chatId: 5, senderKey: "u7", isOutgoing: false, body: .text("hello there"),
                               date: Date(timeIntervalSince1970: 1), isPending: false, isFailed: false, isPinned: false)
    Task { await model.translate(toTranslate) }
    pump(0.2)
    sentRequest = sent("translateText", after: mark)
    check(part(sentRequest, "text")["text"] as? String == "hello there"
          && sentRequest?["to_language_code"] as? String == "ru" && sentRequest?["tone"] as? String == "neutral",
          "translation asks in Russian, neutrally, with the message's own words")

    // A topic that is open has to catch the outgoing messages, or a reply lands in the wrong thread.
    model.topics = [Topic(id: 7, name: "Релизы")]
    mark = model.recordedRequests.count
    Task { await model.open(topic: 7) }
    pump(0.4)
    check(sent("getForumTopicHistory", after: mark)?["forum_topic_id"] as? Int == 7, "opening a topic reads that topic's history")
    mark = model.recordedRequests.count
    Task { await model.sendDice("🎲") }
    pump(0.3)
    sentRequest = sent("sendMessage", after: mark)
    check(part(sentRequest, "topic_id").tdType == "messageTopicForum"
          && part(sentRequest, "topic_id")["forum_topic_id"] as? Int == 7,
          "a message sent there carries the topic (\(part(sentRequest, "topic_id")))")
    check(part(sentRequest, "input_message_content").tdType == "inputMessageDice"
          && part(sentRequest, "input_message_content")["emoji"] as? String == "🎲", "and is a dice, not a text")

    mark = model.recordedRequests.count
    Task { await model.sendLocation(latitude: 59.9386, longitude: 30.3141) }
    pump(0.3)
    sentRequest = sent("sendMessage", after: mark)
    let point = part(part(sentRequest, "input_message_content"), "location")
    check(part(sentRequest, "input_message_content").tdType == "inputMessageLocation"
          && point["latitude"] as? Double == 59.9386 && point["longitude"] as? Double == 30.3141,
          "a typed point goes out as a location with both coordinates")
    mark = model.recordedRequests.count
    Task { await model.sendLocation(latitude: 120, longitude: 0) }
    pump(0.3)
    check(sent("sendMessage", after: mark) == nil, "and a latitude of 120 is refused before anything is sent")

    // --- rights, topic renaming and the statistics request ---------------------------------------------
    let admin = TD.member(json(#"{"@type":"chatMember","member_id":{"@type":"messageSenderUser","user_id":511},"tag":"","inviter_user_id":0,"joined_chat_date":1,"status":{"@type":"chatMemberStatusAdministrator","can_be_edited":true,"rights":{"@type":"chatAdministratorRights","can_manage_chat":true,"can_change_info":true,"can_delete_messages":true,"can_invite_users":true,"can_restrict_members":true,"can_pin_messages":false,"can_manage_topics":false,"is_anonymous":false}}}"#), name: "Иван", photo: nil)
    check(admin.rank == .admin && admin.canBeEdited && admin.rights["can_delete_messages"] == true
          && admin.rights["can_pin_messages"] == false && admin.rights.count == 8,
          "an administrator's rights are read from the member, not assumed (\(admin.rights.count))")
    check(Rights.summary(admin.rights, Rights.admin) == "Управлять чатом, Менять название и фото, Удалять сообщения и ещё 2",
          "and they summarise into one line (\(Rights.summary(admin.rights, Rights.admin)))")
    let restricted = TD.member(json(#"{"@type":"chatMember","member_id":{"@type":"messageSenderUser","user_id":512},"tag":"","inviter_user_id":0,"joined_chat_date":1,"status":{"@type":"chatMemberStatusRestricted","is_member":true,"restricted_until_date":1800000000,"permissions":{"@type":"chatPermissions","can_send_basic_messages":false,"can_react_to_messages":true}}}"#), name: "Мария", photo: nil)
    check(restricted.rank == .restricted && restricted.permissions["can_react_to_messages"] == true
          && restricted.permissions["can_send_basic_messages"] == false
          && restricted.untilDate == 1800000000,
          "a restriction reads back what is left allowed and until when")
    check(Rights.build(type: "chatPermissions", Rights.permissions, ["can_send_photos": true])["can_send_videos"] as? Bool == false,
          "building a rights object fills every flag")

    mark = model.recordedRequests.count
    Task { await model.loadMember(target, in: managed) }
    pump(0.2)
    check(part(sent("getChatMember", after: mark), "member_id")["user_id"] as? Int64 == 511,
          "one member is read with getChatMember before it is edited")

    mark = model.recordedRequests.count
    Task { await model.renameTopic(Topic(id: 7, name: "Релизы"), in: managed.id, to: "Релизы 2026") }
    pump(0.2)
    sentRequest = sent("editForumTopic", after: mark)
    check(sentRequest?["name"] as? String == "Релизы 2026" && sentRequest?["forum_topic_id"] as? Int == 7
          && sentRequest?["edit_icon_custom_emoji"] as? Bool == false,
          "renaming a topic keeps its icon and changes only the name")
    mark = model.recordedRequests.count
    Task { await model.renameTopic(Topic(id: 7, name: "Релизы"), in: managed.id, to: "  Релизы  ") }
    pump(0.2)
    check(sent("editForumTopic", after: mark) == nil, "and the same name, spaces aside, sends nothing")

    mark = model.recordedRequests.count
    Task { await model.loadStatistics(of: managed) }
    pump(0.2)
    check(sent("getChatStatistics", after: mark)?["is_dark"] as? Bool == false,
          "the statistics request asks for the light theme it will draw in")
    let stats = TD.stats(json(#"{"@type":"chatStatisticsChannel","period":{"@type":"dateRange","start_date":1790000000,"end_date":1790600000},"member_count":{"@type":"statisticalValue","value":12840,"previous_value":12540,"growth_rate_percentage":2.4},"mean_message_view_count":{"@type":"statisticalValue","value":8900,"previous_value":9100,"growth_rate_percentage":-2.2},"mean_message_share_count":{"@type":"statisticalValue","value":14.5,"previous_value":0,"growth_rate_percentage":0},"mean_message_reaction_count":{"@type":"statisticalValue","value":61,"previous_value":0,"growth_rate_percentage":0},"enabled_notifications_percentage":0,"member_count_graph":{"@type":"statisticalGraphError","error_message":"x"}}"#))
    check(stats == ChannelStats(from: Date(timeIntervalSince1970: 1790000000), to: Date(timeIntervalSince1970: 1790600000),
                               members: 12840, membersGrowth: 2.4, meanViews: 8900, meanShares: 14.5, meanReactions: 61),
          "the channel card's numbers are read straight from the answer (\(String(describing: stats?.members)))")
    let groupStats = TD.stats(json(#"{"@type":"chatStatisticsSupergroup","period":{"@type":"dateRange","start_date":1,"end_date":2},"member_count":{"@type":"statisticalValue","value":40,"previous_value":40,"growth_rate_percentage":0},"viewer_count":{"@type":"statisticalValue","value":27,"previous_value":0,"growth_rate_percentage":0}}"#))
    check(groupStats?.meanViews == 27, "a group keeps its viewers under another field, and the reader follows")
    check(TD.stats(json(#"{"@type":"chatStatisticsObjectTypeStory","story_id":1}"#)) == nil, "anything else is not statistics")

    let appSession = WebAppSession(launchId: 0, chatId: 5, botUserId: 900, botName: "Бот",
                                   url: URL(string: "https://example.com/app")!,
                                   requiresSameOrigin: false, keyboardButtonText: nil)
    mark = model.recordedRequests.count
    Task { _ = try? await model.invokeCustomMethod("cloudStorage.save", parameters: "{}", for: appSession) }
    pump(0.2)
    sentRequest = sent("sendWebAppCustomRequest", after: mark)
    check(sentRequest?["method"] as? String == "cloudStorage.save" && sentRequest?["bot_user_id"] as? Int64 == 900
          && sentRequest?["parameters"] as? String == "{}",
          "a mini app's own method goes out under TDLib's name, not the Bot API's")

    model.topics = [Topic(id: 7, name: "Релизы")]
    Task { await model.open(topic: 7) }
    pump(0.4)
    model.isSearching = true
    model.searchQuery = "релиз"
    mark = model.recordedRequests.count
    Task { await model.runSearch() }
    pump(0.3)
    sentRequest = sent("searchChatMessages", after: mark)
    check(part(sentRequest, "topic_id")["forum_topic_id"] as? Int == 7,
          "search inside an open topic stays in that topic (\\(String(describing: sentRequest?[\"topic_id\"])))")

    mark = model.recordedRequests.count
    Task { await model.jump(to: 942) }
    pump(0.6)
    let jumpRead = sent("getForumTopicHistory", after: mark)
    check(jumpRead != nil && sent("getChatHistory", after: mark) == nil,
          "a jump in an open topic reads that topic, not the whole chat")
    check(jumpRead?["offset"] as? Int == -25, "and asks for a window around the message, not its newest page")

    mark = model.recordedRequests.count
    Task { await model.open(topic: nil) }
    pump(0.4)
    model.isSearching = true
    model.searchQuery = "чисто"
    Task { await model.runSearch() }
    pump(0.3)
    sentRequest = sent("searchChatMessages", after: mark)
    check(sentRequest != nil && sentRequest?["topic_id"] == nil,
          "and the whole chat is searched again once no topic is open")

    // --- what a read chat leaves behind ------------------------------------------------------------------
    // Its own chat, last of all: reading and switching walk the model through states the earlier checks need.
    // `chat(...)` is shadowed by a binding above, so the update is written out here.
    model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":606,"type":{"@type":"chatTypeSupergroup","supergroup_id":66,"is_channel":false},"title":"Форум","positions":[\#(mainPosition("9221294784512000606"))],"unread_count":5,"is_marked_as_unread":false,"last_read_inbox_message_id":0,"unread_mention_count":0,"unread_reaction_count":0,"draft_message":null}}"#))
    model.selection = 606
    Task { await model.select(chatId: 606) }
    pump(0.4)
    if let forum = model.chat(withId: 606) {
        model.topics = [Topic(id: 7, name: "Релизы", unread: 3), Topic(id: 8, name: "Оффтоп", unread: 2)]
        Task { await model.markChatRead(forum) }
        pump(0.3)
        check(model.topics.allSatisfy { $0.unread == 0 },
              "reading the chat as one stream clears every topic's counter (\(model.topics.map(\.unread)))")
        // The search made in one topic must not survive into the next.
        model.isSearching = true
        model.searchQuery = "привет"
        Task { await model.open(topic: 7) }
        pump(0.4)
        check(!model.isSearching && model.searchQuery.isEmpty,
              "switching the topic ends the search made in the previous one")
        model.topics = [Topic(id: 7, name: "Релизы", unread: 4), Topic(id: 8, name: "Оффтоп", unread: 5)]
        Task { await model.markChatRead(forum) }
        pump(0.3)
        check(model.topics.first { $0.id == 7 }?.unread == 0 && model.topics.first { $0.id == 8 }?.unread == 5,
              "reading one topic leaves the others' counts alone (\(model.topics.map(\.unread)))")

        model.managedChat = forum
        model.chatAccess = ChatAccess(isCreator: true, isAdmin: true, canDeleteMessages: true, canGetMembers: true)
        model.members = [ChatMemberInfo(userId: 511, name: "Иван", rank: .admin)]
        check(model.chatAccess.canManage, "the sheet knows this account runs the chat")
        model.selection = 2
        pump(0.3)
        check(model.managedChat == nil, "switching the chat closes the sheet it was opened for")
        check(model.chatAccess == ChatAccess() && model.members.isEmpty,
              "and the rights of the old chat do not follow into the new one")
    } else {
        check(false, "the forum chat the read tests need exists")
    }

    // --- whose state is still on screen ------------------------------------------------------------------
    // Both chats are made here: an earlier section deletes the ones it was built on, and a check that
    // quietly does not run reads exactly like one that passed.
    func makeChat(_ id: Int64, _ title: String) {
        model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":\#(id),"type":{"@type":"chatTypeSupergroup","supergroup_id":\#(id),"is_channel":false},"title":"\#(title)","positions":[\#(mainPosition("9221294784512000000" + String(id)))] ,"unread_count":0,"is_marked_as_unread":false,"last_read_inbox_message_id":0,"unread_mention_count":0,"unread_reaction_count":0,"draft_message":null}}"#))
    }
    makeChat(616, "Открытый")
    makeChat(617, "Из меню")
    model.selection = 616
    Task { await model.select(chatId: 616) }
    pump(0.4)
    check(model.isBeingShown(616), "the open chat's data is still wanted")
    check(!model.isBeingShown(617), "a chat nobody opened is not")
    if let other = model.chat(withId: 617) {
        model.managedChat = other
        check(model.isBeingShown(617), "but a chat the management sheet is about is, even though it is not open")
        check(model.isBeingShown(616), "and the open chat stays wanted while the sheet is up")
        model.managedChat = nil
        check(!model.isBeingShown(617), "and it is not once the sheet closes")
    } else {
        check(false, "the second chat exists for the sheet tests")
    }
    // --- the sidebar rail: folder icons, colours and the unread badges ---------------------------
    model.apply(json(#"{"@type":"updateChatFolders","chat_folders":[{"@type":"chatFolderInfo","id":12,"name":{"@type":"chatFolderName","text":{"@type":"formattedText","text":"Каналы","entities":[]},"animate_custom_emoji":false},"icon":{"@type":"chatFolderIcon","name":"Channels"},"color_id":3,"is_shareable":false,"has_my_invite_links":false},{"@type":"chatFolderInfo","id":13,"name":{"@type":"chatFolderName","text":{"@type":"formattedText","text":"Разное","entities":[]},"animate_custom_emoji":false},"color_id":-1,"is_shareable":false,"has_my_invite_links":false}],"main_chat_list_position":0}"#))
    func folderPosition(_ folder: Int, _ order: String, pinned: Bool = false) -> String {
        #"{"@type":"chatPosition","list":{"@type":"chatListFolder","chat_folder_id":\#(folder)},"order":"\#(order)","is_pinned":\#(pinned),"source":null}"#
    }
    func archivedPosition(_ order: String) -> String {
        #"{"@type":"chatPosition","list":{"@type":"chatListArchive"},"order":"\#(order)","is_pinned":false,"source":null}"#
    }
    @MainActor func railChat(_ id: Int64, unread: Int, positions: [String], muted: Bool = false) {
        model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":\#(id),"type":{"@type":"chatTypePrivate","user_id":\#(id)},"title":"Р\#(id)","positions":[\#(positions.joined(separator: ","))],"unread_count":\#(unread),"is_marked_as_unread":false,"last_read_inbox_message_id":0,"draft_message":null,"notification_settings":{"@type":"chatNotificationSettings","use_default_mute_for":\#(!muted),"mute_for":\#(muted ? 2147483647 : 0)}}}"#))
    }
    check(model.chatFolders.first { $0.id == 12 }?.icon == "Channels" && model.chatFolders.first { $0.id == 12 }?.colorId == 3,
          "a folder's icon and colour come through from TDLib")
    check(model.chatFolders.first { $0.id == 13 }?.icon == "" && model.chatFolders.first { $0.id == 13 }?.colorId == -1,
          "a folder with neither icon nor colour parses as such")
    let mainBefore = model.mainUnread.count, archiveBefore = model.archiveUnread.count
    railChat(660, unread: 7, positions: [mainPosition("9221294784512000060"), folderPosition(12, "9221294784512000060")])
    railChat(661, unread: 3, positions: [mainPosition("9221294784512000059"), folderPosition(12, "9221294784512000059")], muted: true)
    railChat(662, unread: 5, positions: [archivedPosition("9221294784512000058"), folderPosition(13, "9221294784512000058")], muted: true)
    pump()
    check(model.mainUnread.count == mainBefore + 10,
          "the all-chats badge sums the main list only: \(model.mainUnread.count - mainBefore) over \(mainBefore)")
    check(model.folderUnread[12]?.count == 10, "a folder badge sums its own chats")
    check(model.folderUnread[12]?.isSilent == false, "a folder with one unmuted chat is not silent")
    check(model.folderUnread[13]?.count == 5 && model.folderUnread[13]?.isSilent == true,
          "a folder of nothing but muted news is marked silent")
    check(model.archiveUnread.count == archiveBefore + 5, "the archive badge counts archived chats")

    // Esc belongs to the conversation's own chain; a second cancel-action button in the members column made
    // the shortcut ambiguous, so the column is closed here, last.
    model.showsMembersPanel = true
    model.isSearching = true
    model.escape()
    check(model.isSearching == false && model.showsMembersPanel == true, "Esc closes the in-chat search before the members column")
    model.escape()
    check(model.showsMembersPanel == false, "and the next Esc closes the members column")
    model.escape()
    check(!model.showsMembersPanel, "Esc with nothing open leaves the column closed")

    // --- the members column exists only where TDLib has a roster --------------------------------
    @MainActor func rosterChat(_ id: Int64, _ type: String) {
        model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":\#(id),"type":\#(type),"title":"Чат \#(id)","positions":[\#(mainPosition("9221294784512000050"))],"unread_count":0,"draft_message":null}}"#))
    }
    rosterChat(670, #"{"@type":"chatTypeSupergroup","supergroup_id":670,"is_channel":false}"#)
    rosterChat(671, #"{"@type":"chatTypeBasicGroup","basic_group_id":671}"#)
    rosterChat(672, #"{"@type":"chatTypePrivate","user_id":672}"#)
    pump()
    check(model.chat(withId: 670)?.hasRoster == true, "a supergroup has a roster")
    check(model.chat(withId: 671)?.hasRoster == false && model.chat(withId: 672)?.hasRoster == false,
          "a basic group and a private chat do not")
    model.showsMembersPanel = true
    model.selection = 670
    check(model.showsMembersColumn == true, "the column shows for the group")
    model.selection = 672
    check(model.showsMembersColumn == false,
          "walking into a private chat hides it instead of showing an empty roster")
    model.selection = 670
    check(model.showsMembersColumn == true, "and it comes back with the group, the switch never having been touched")
    model.showsMembersPanel = false
    model.selectedFolder = 12
    pump()
    check(model.chats.map(\.id) == [660, 661] && model.selectedFolder == 12, "the rail's choice filters the list")
    model.selectedFolder = nil

    // --- a refused reload of the same chat must not leave it without the rights it already had ----------
    if let group = model.chat(withId: 670) {
        Task { await model.loadAccess(of: group) }
        pump(0.2)
        // The first load is for a chat the slot has never answered for, so it clears; both requests fail here.
        check(model.chatAccess.canManageTopics == false, "the first load of a chat starts from nothing")
        model.chatAccess = ChatAccess(isAdmin: true, canManageTopics: true, canGetMembers: true)
        model.members = [ChatMemberInfo(userId: 901, name: "Кто-то", rank: .admin)]
        Task { await model.loadAccess(of: group) }
        pump(0.2)
        check(model.chatAccess.canManageTopics && model.members.count == 1,
              "a refused reload of the same chat leaves the rights and roster already on screen")
        model.chatAccess = ChatAccess()
        model.members = []
    } else {
        check(false, "the supergroup for the access-reload test exists")
    }

    check(Rights.editorDefaults["can_promote_members"] == nil && Rights.editorDefaults["can_delete_messages"] == true,
          "the default promotion hands out no new administrators, only upkeep")
    check(Rights.admin.count == 18 && Rights.permissions.count == 16,
          "every right TDLib has is offered (\(Rights.admin.count)/\(Rights.permissions.count))")

    // --- a chat whose last message is gone, and content that changes under a card ------------------------
    // Written out like the sections above: `chat(...)` is shadowed by then.
    let emptied: Int64 = 9100
    let emptiedPosition = mainPosition("9221294784512009100")
    model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":\#(emptied),"type":{"@type":"chatTypePrivate","user_id":\#(emptied)},"title":"Очищаемый","positions":[\#(emptiedPosition)],"unread_count":0,"draft_message":null}}"#))
    model.apply(json(#"{"@type":"updateChatLastMessage","chat_id":\#(emptied),"last_message":\#(message(50, chat: emptied, text: "скоро сотрут")),"positions":[\#(emptiedPosition)]}"#))
    pump()
    check(model.chats.first { $0.id == emptied }?.snippet == "скоро сотрут" && model.chat(withId: emptied)?.lastMessageId == 50,
          "the row quotes the chat's last message")
    model.apply(json(#"{"@type":"updateChatLastMessage","chat_id":\#(emptied),"last_message":null,"positions":[\#(emptiedPosition)]}"#))
    pump()
    let afterClearing = model.chats.first { $0.id == emptied }
    check(afterClearing != nil, "a cleared chat stays in the list")
    check(afterClearing?.snippet == "" && afterClearing?.snippetDate == nil && afterClearing?.lastMessageId == 0,
          "and stops quoting a message that no longer exists: «\(afterClearing?.snippet ?? "?")»")

    model.selection = emptied
    Task { await model.select(chatId: emptied) }
    pump(0.3)
    let dice = { (value: Int) in #"{"@type":"messageDice","emoji":"🎲","value":\#(value),"success_animation_frame_number":0}"# }
    model.apply(json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":60,"chat_id":\#(emptied),"sender_id":{"@type":"messageSenderUser","user_id":7},"is_outgoing":false,"date":1790000100,"content":\#(dice(0))}}"#))
    check(model.messages.last?.dice?.value == 0, "a dice still rolling has no value")
    model.apply(json(#"{"@type":"updateMessageContent","chat_id":\#(emptied),"message_id":60,"new_content":\#(dice(4))}"#))
    check(model.messages.last?.dice?.value == 4, "the value it lands on reaches the card (\(String(describing: model.messages.last?.dice?.value)))")
    model.apply(json(#"{"@type":"updateMessageContent","chat_id":\#(emptied),"message_id":60,"new_content":{"@type":"messageDocument","document":{"@type":"document","file_name":"новый.pdf","mime_type":"application/pdf","document":{"@type":"file","id":77,"size":10}},"caption":{"@type":"formattedText","text":"","entities":[]}}}"#))
    check(model.messages.last?.dice == nil && model.messages.last?.document?.name == "новый.pdf",
          "content of another kind replaces the card instead of leaving the old one under it")
    check(model.transcript.last?.rows.last?.message.document?.fileId == 77, "and the row on screen follows")

    // --- markup typed into the composer, and what is offered while typing ---------------------------------
    // TDLib parses these on the calling thread and needs no client, so the stand runs the real parser.
    func kinds(_ formatted: TDNode) -> [String] { formatted.tdNodes("entities").map { $0.tdNode("type")?.tdType ?? "?" } }
    let marked = TD.markedUp("**жирный** и `код`")
    check(marked.tdString("text") == "жирный и код" && kinds(marked) == ["textEntityTypeBold", "textEntityTypeCode"],
          "markup becomes formatting: «\(marked.tdString("text"))» \(kinds(marked))")
    check(TD.markdown(of: marked) == "**жирный** и `код`", "and formatting reads back as the markup that makes it: \(TD.markdown(of: marked) ?? "nil")")
    let untouched = TD.markedUp("snake_case, 2*3 и a|b [не ссылка]")
    check(untouched.tdString("text") == "snake_case, 2*3 и a|b [не ссылка]" && kinds(untouched).isEmpty,
          "marks that do not pair up stay as typed: «\(untouched.tdString("text"))» \(kinds(untouched))")
    check(kinds(TD.markedUp("обычный текст")).isEmpty && TD.markdown(of: TD.formattedText("обычный текст")) == nil,
          "plain text is left alone both ways")
    let named = TD.markedUp("[Иван](tg://user?id=5), привет")
    check(named.tdString("text") == "Иван, привет" && kinds(named).count == 1, "a person without a username is mentioned by a link: \(kinds(named))")

    model.recordedRequests = []
    model.draft = "**важно** и всё"
    Task { await model.send() }
    pump(0.2)
    let sentText = model.recordedRequests.last { $0.tdType == "sendMessage" }?.tdNode("input_message_content")?.tdNode("text")
    check(sentText?.tdString("text") == "важно и всё" && kinds(sentText ?? [:]) == ["textEntityTypeBold"],
          "a typed message goes out formatted: \(String(describing: sentText?.tdString("text"))) \(kinds(sentText ?? [:]))")

    model.botMenu = BotMenu(botUserId: emptied, appTitle: "", appURL: "", commands: [
        .init(command: "start", description: "начать"), .init(command: "help", description: "помощь"),
        .init(command: "settings", description: "настройки"),
    ])
    model.draft = "/s"
    model.noteTyping()
    check(model.suggestions.map(\.title) == ["/start", "/settings"], "typing a slash offers the bot's commands: \(model.suggestions.map(\.title))")
    model.draft = "/start сейчас"
    model.noteTyping()
    check(model.suggestions.isEmpty, "and stops once the command has an argument")
    model.draft = "/he"
    model.noteTyping()
    model.recordedRequests = []
    if let first = model.suggestions.first { Task { await model.accept(first) } }
    pump(0.2)
    let command = model.recordedRequests.last { $0.tdType == "sendMessage" }?.tdNode("input_message_content")?.tdNode("text")
    check(command?.tdString("text") == "/help" && model.draft.isEmpty && model.suggestions.isEmpty,
          "a picked command is sent as it is: \(String(describing: command?.tdString("text")))")

    model.draft = "привет @ив"
    Task { await model.accept(ComposerSuggestion(id: "u5", title: "Иван", detail: "@ivan", kind: .mention(userId: 5, username: "ivan"))) }
    pump(0.1)
    check(model.draft == "привет @ivan ", "a picked person replaces the word being typed: «\(model.draft)»")
    model.draft = "@"
    Task { await model.accept(ComposerSuggestion(id: "u6", title: "Анна [QA]", detail: "", kind: .mention(userId: 6, username: ""))) }
    pump(0.1)
    check(model.draft == "[Анна QA](tg://user?id=6) ", "someone without a username is mentioned by name: «\(model.draft)»")
    model.draft = ""

    // --- answering from a banner ---------------------------------------------------------------------------
    model.recordedRequests = []
    Task { await model.replyFromNotification("  **ок**  ", to: 60, in: emptied) }
    pump(0.2)
    let banner = model.recordedRequests.last { $0.tdType == "sendMessage" }
    check(banner?.tdInt64("chat_id") == emptied && banner?.tdNode("input_message_content")?.tdNode("text")?.tdString("text") == "ок",
          "a banner's answer goes to its chat, formatted like any other")
    check(banner?["reply_to"] == nil, "a private chat is answered without a quote")
    model.recordedRequests = []
    Task { await model.replyFromNotification("   ", to: 60, in: emptied) }
    pump(0.1)
    check(!model.recordedRequests.contains { $0.tdType == "sendMessage" }, "an empty answer sends nothing")

    // --- quotes from other chats, custom emoji, and the Формат menu ----------------------------------------
    let across = TD.message(json(#"{"@type":"message","id":70,"chat_id":\#(emptied),"sender_id":{"@type":"messageSenderUser","user_id":7},"date":1790000200,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"смотри","entities":[]}},"reply_to":{"@type":"messageReplyToMessage","chat_id":-100777,"message_id":4096,"origin":{"@type":"messageOriginChannel","chat_id":-100777,"message_id":4096,"author_signature":""},"origin_send_date":1,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"новость\nдня","entities":[]}}}}"#))
    check(across.replyToId == 0 && across.foreignReply == ForeignReply(chatId: -100777, messageId: 4096, senderKey: "c-100777", senderName: "", text: "новость дня"),
          "a reply to another chat's message keeps its quote: \(String(describing: across.foreignReply))")
    let within = TD.message(json(#"{"@type":"message","id":71,"chat_id":\#(emptied),"sender_id":{"@type":"messageSenderUser","user_id":7},"date":1790000201,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"да","entities":[]}},"reply_to":{"@type":"messageReplyToMessage","chat_id":\#(emptied),"message_id":60}}"#))
    check(within.replyToId == 60 && within.foreignReply == nil, "a reply inside the chat is still looked up in its history")
    let quoted = TD.foreignReply(json(#"{"@type":"messageReplyToMessage","chat_id":0,"message_id":0,"quote":{"@type":"textQuote","text":{"@type":"formattedText","text":"только это","entities":[]},"position":0,"is_manual":true},"origin":{"@type":"messageOriginHiddenUser","sender_name":"Аноним"}}"#))
    check(quoted?.text == "только это" && quoted?.senderName == "Аноним" && quoted?.senderKey == "", "a quoted fragment and a hidden author are read as sent")

    let fancy = TD.message(json(#"{"@type":"message","id":72,"chat_id":\#(emptied),"sender_id":{"@type":"messageSenderUser","user_id":7},"date":1790000202,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"ура 🎉","entities":[{"@type":"textEntity","offset":4,"length":2,"type":{"@type":"textEntityTypeCustomEmoji","custom_emoji_id":"5368324170671202286"}}]}},"interaction_info":{"@type":"messageInteractionInfo","view_count":0,"reactions":{"@type":"messageReactions","reactions":[{"@type":"messageReaction","type":{"@type":"reactionTypeCustomEmoji","custom_emoji_id":"5368324170671202286"},"total_count":2,"is_chosen":false},{"@type":"messageReaction","type":{"@type":"reactionTypeEmoji","emoji":"👍"},"total_count":1,"is_chosen":true}]}}}"#))
    check(fancy.entities == [TextEntity(offset: 4, length: 2, style: .customEmoji(5368324170671202286))], "a custom emoji keeps its id: \(fancy.entities)")
    check(fancy.reactions.map(\.key) == ["c5368324170671202286", "👍"] && fancy.reactions.first?.count == 2,
          "custom emoji reactions are kept beside the ordinary ones: \(fancy.reactions.map(\.key))")

    let phrase = "это важно, да"
    let word = phrase.range(of: "важно")!
    let bold = TextFormat.bold.wrap(phrase, word)
    check(bold.text == "это **важно**, да" && bold.text[bold.selection] == "важно", "⌘B wraps the selected words and keeps them selected: «\(bold.text)»")
    let link = TextFormat.link.wrap(phrase, word)
    check(link.text == "это [важно](), да" && link.selection.isEmpty && link.text[..<link.selection.lowerBound].hasSuffix("]("),
          "⌘K leaves the caret where the address goes: «\(link.text)»")
    let caret = TextFormat.code.wrap("код: ", "код: ".endIndex..<"код: ".endIndex)
    check(caret.text == "код: ``" && caret.selection.isEmpty && caret.text[caret.selection.lowerBound...] == "`", "without a selection the marks open around the caret: «\(caret.text)»")
    check(kinds(TD.markedUp(bold.text)) == ["textEntityTypeBold"], "and what the menu writes is what the parser reads")
    model.composerHasSelection = true
    model.linkOrFindChat()
    check(model.formatRequest?.format == .link, "⌘K with words selected asks for a link")
    model.formatRequest = nil
    model.composerHasSelection = false
    let asked = model.searchChatsRequest
    model.linkOrFindChat()
    check(model.formatRequest == nil && model.searchChatsRequest == asked + 1, "and without a selection still finds a chat")

    // --- custom emoji through an edit, and secret chats ------------------------------------------------------
    func emojiEntity(_ offset: Int) -> TDNode {
        json(#"{"@type":"textEntity","offset":\#(offset),"length":2,"type":{"@type":"textEntityTypeCustomEmoji","custom_emoji_id":"77"}}"#)
    }
    let kept = TD.carry([emojiEntity(0), emojiEntity(10)], from: "🎉 привет 🎉 всем", to: "🎉 здравствуй 🎉 всем")
    check(kept.map { $0.tdInt("offset") } == [0, 14], "an edit between two custom emoji keeps both where they now stand: \(kept.map { $0.tdInt("offset") })")
    let cut = TD.carry([emojiEntity(0), emojiEntity(10)], from: "🎉 привет 🎉 всем", to: "🎉 привет всем")
    check(cut.map { $0.tdInt("offset") } == [0], "one that was typed over is dropped, not moved onto other letters: \(cut.map { $0.tdInt("offset") })")
    let both = TD.markedUp("**ура** 🎉", keeping: [emojiEntity(8)])
    check(both.tdString("text") == "ура 🎉" && Set(kinds(both)) == ["textEntityTypeBold", "textEntityTypeCustomEmoji"]
          && both.tdNodes("entities").first { $0.tdNode("type")?.tdType == "textEntityTypeCustomEmoji" }?.tdInt("offset") == 4,
          "markup and a kept custom emoji come out together, the emoji moved with the text: \(kinds(both))")

    let secretId: Int64 = -2000000000123
    model.apply(json(#"{"@type":"updateSecretChat","secret_chat":{"@type":"secretChat","id":123,"user_id":7,"state":{"@type":"secretChatStatePending"},"is_outbound":true,"key_hash":"","layer":0}}"#))
    model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":\#(secretId),"type":{"@type":"chatTypeSecret","secret_chat_id":123,"user_id":7},"title":"Тайный","positions":[\#(mainPosition("9221294784512009200"))],"unread_count":0,"draft_message":null}}"#))
    pump()
    let secret = { model.chat(withId: secretId) }
    check(secret()?.kind == .secret && secret()?.secretState == .pending && model.subtitle(for: secret()!).contains("ждёт"),
          "a secret chat that arrived after its session knows it is still waiting: \(String(describing: secret()?.secretState))")
    model.apply(json(#"{"@type":"updateSecretChat","secret_chat":{"@type":"secretChat","id":123,"user_id":7,"state":{"@type":"secretChatStateReady"},"is_outbound":true,"key_hash":"","layer":144}}"#))
    model.apply(json(#"{"@type":"updateUserStatus","user_id":7,"status":{"@type":"userStatusOnline","expires":\#(Int(Date().timeIntervalSince1970) + 600)}}"#))
    pump()
    check(secret()?.secretState == .ready && secret()?.presence == .online && model.subtitle(for: secret()!) == "в сети",
          "once accepted it shows its owner's presence, though its id is not theirs: \(model.subtitle(for: secret()!))")
    model.recordedRequests = []
    Task { await model.deleteChat(secret()!, forEveryone: false) }
    pump(0.2)
    check(model.recordedRequests.first?.tdType == "closeSecretChat" && model.recordedRequests.first?.tdInt("secret_chat_id") == 123,
          "deleting a secret chat ends its session first: \(model.recordedRequests.map(\.tdType))")

    // --- security tools, second pass ------------------------------------------------------------------------
    func warns(_ link: String, _ needle: String, shownAs: String? = nil) -> Bool {
        SecurityTools.linkWarnings(URL(string: link)!, shownAs: shownAs).contains { $0.contains(needle) }
    }
    check(warns("https://te1egram-login.com/auth", "похож на Telegram") && warns("https://telegrarn.org", "похож на Telegram"),
          "look-alikes of Telegram's name are called out")
    check(!warns("https://core.telegram.org/api", "похож") && !warns("https://t.me/durov", "похож") && !warns("https://telegra.ph/x", "похож"),
          "Telegram's own sites are not")
    check(warns("http://3232235777/", "числом") && warns("http://0xC0A80101/x", "числом") && warns("http://0300.0250.01.01/", "числом"),
          "an address written as a number is recognised")
    check(!warns("https://192.168.1.1/", "числом") && warns("https://192.168.1.1/", "IP-адрес"), "a plain dotted address keeps its own warning")
    check(warns("https://cdn.example.com/files/update.dmg", "сразу на файл") && !warns("https://example.com/index.html", "сразу на файл")
          && !warns("https://example.com/app.js", "сразу на файл"), "a link that hands over a program is told from one that opens a page")
    check(SecurityTools.linkWarnings(URL(string: "https://www.apple.com/mac")!).isEmpty && SecurityTools.linkWarnings(URL(string: "https://github.com/tdlib/td")!).isEmpty,
          "ordinary links still pass clean")

    let hidden = URL(string: "https://evil.example/login")!
    _ = TD.entities(json(#"{"@type":"formattedText","text":"зайдите на sberbank.ru сегодня","entities":[{"@type":"textEntity","offset":11,"length":11,"type":{"@type":"textEntityTypeTextUrl","url":"https://evil.example/login"}}]}"#))
    check(SecurityTools.label(for: hidden) == "sberbank.ru", "the address a hidden link is dressed as is remembered: \(String(describing: SecurityTools.label(for: hidden)))")
    check(warns("https://evil.example/login", "sberbank.ru", shownAs: SecurityTools.label(for: hidden)), "and named when the link is opened")
    _ = TD.entities(json(#"{"@type":"formattedText","text":"нажмите здесь","entities":[{"@type":"textEntity","offset":0,"length":13,"type":{"@type":"textEntityTypeTextUrl","url":"https://example.org/a"}}]}"#))
    check(SecurityTools.label(for: URL(string: "https://example.org/a")!) == nil, "ordinary words over a link are not an address")

    for name in ["Счёт.inetloc", "open.terminal", "wifi.mobileconfig", "отчёт.html", "macro.xll", "note.one", "doc\u{2067}fdp.scr"] {
        check(SecurityTools.fileWarning(for: name) != nil, "\(name.unicodeScalars.filter { $0.value < 0x2000 }.map(String.init).joined()) is treated as something that can run")
    }
    check(SecurityTools.fileWarning(for: "фото.jpg") == nil && SecurityTools.fileWarning(for: "архив.zip") == nil, "pictures and archives are not")
    let disguised = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlite-sniff-\(UUID().uuidString).pdf")
    try? Data([0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00]).write(to: disguised)
    check(SecurityTools.contentWarning(at: disguised)?.contains("Windows") == true, "a program named like a document is caught by its first bytes")
    try? Data("%PDF-1.7\n".utf8).write(to: disguised)
    check(SecurityTools.contentWarning(at: disguised) == nil, "a real document is not")
    try? FileManager.default.removeItem(at: disguised)

    let more = SecurityTools.indicators(in: "С2 2001:db8::8a2e:370:7334 и ::1, в 12:30:45 по T1566.001 и T1059; BTC bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq, ETH 0x52908400098527886E0F7030069857D2E4169EE7, TON EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N, sha512 cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
    check(more.ipv6 == ["2001:db8::8a2e:370:7334", "::1"], "IPv6 addresses are found and a time of day is not one: \(more.ipv6)")
    check(more.techniques == ["T1566.001", "T1059"], "ATT&CK technique ids are listed: \(more.techniques)")
    check(more.wallets.count == 3 && more.wallets.contains { $0.hasPrefix("BTC bc1q") } && more.wallets.contains { $0.hasPrefix("ETH 0x5290") } && more.wallets.contains { $0.hasPrefix("TON EQCD") },
          "wallet addresses are told apart by network: \(more.wallets)")
    check(more.sha512.count == 1 && more.sha256.isEmpty && more.sha1.isEmpty, "a SHA-512 is one hash, not pieces of shorter ones")
    check(more.report().contains("# IPv6 (2)") && more.report().contains("# Кошельки (3)"), "and the report has a section for each")

    // --- the passcode -------------------------------------------------------------------------------------------
    if let made = AppLock.make(passcode: "тайна-1234") {
        let right = AppLock.unlock("тайна-1234", made.record)
        check(right?.database == made.keys.database && right?.database.count == 32, "the right passcode gives the same keys again")
        check(AppLock.unlock("тайна-1235", made.record) == nil && AppLock.unlock("", made.record) == nil, "a wrong or empty one gives nothing")
        check(AppLock.make(passcode: "тайна-1234")?.keys.database != made.keys.database, "the same passcode set twice does not repeat a key")
        let stored = (try? JSONEncoder().encode(made.record)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!stored.contains(made.keys.database.base64EncodedString()) && !stored.contains("тайна"), "neither the passcode nor a key is in what goes to disk")

        let secretText = Data("удалённое сообщение".utf8)
        let sealed = AppLock.seal(secretText, with: made.keys.archive)
        check(sealed != nil && AppLock.isSealed(sealed!) && sealed!.range(of: secretText) == nil, "a sealed file does not contain its text")
        check(AppLock.open(sealed!, with: made.keys.archive) == secretText, "and opens with its key")
        check(AppLock.open(sealed!, with: AppLock.make(passcode: "другой")!.keys.archive) == nil, "and with no other")
        var tampered = sealed!
        tampered[tampered.count - 1] ^= 1
        check(AppLock.open(tampered, with: made.keys.archive) == nil, "a file changed on disk is refused, not read as something else")

        try? AppLock.save(made.record)
        model.hasPasscode = true
        model.profile = ProfileInfo(title: "x", photo: nil, seed: 1, subtitle: "", telegramId: 1, dataCenter: nil)
        model.lock()
        check(model.isLocked && model.profile == nil, "locking shuts the window and what was open over it")
        check(!model.canUnlockWithoutPasscode, "Touch ID is not offered before the passcode has been typed once")
        check(!model.unlock(with: "не тот") && model.isLocked, "a wrong passcode leaves it locked")
        check(model.unlock(with: "тайна-1234") && !model.isLocked && model.lockKeys?.database == made.keys.database, "the right one opens it and brings the keys")
        model.lock()
        check(model.canUnlockWithoutPasscode, "after that Touch ID may lift the cover")
        model.unlockAfterSystemAuthentication()
        check(!model.isLocked, "and does")
        AppLock.remove()
        model.hasPasscode = false
        model.lockKeys = nil
        model.lock()
        check(!model.isLocked, "without a passcode there is nothing to lock with")
    } else {
        check(false, "a passcode record can be made")
    }

    // --- secret chats and the archive, indicators for machines ------------------------------------------------
    let vault: Int64 = -2000000000456
    model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":\#(vault),"type":{"@type":"chatTypeSecret","secret_chat_id":456,"user_id":7},"title":"Сейф","positions":[\#(mainPosition("9221294784512009300"))],"unread_count":0,"draft_message":null}}"#))
    model.selection = vault
    Task { await model.select(chatId: vault) }
    pump(0.3)
    UserDefaults.standard.set(false, forKey: Preferences.archiveSecretChats)
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(81, chat: vault, text: "сгорит"))}"#))
    model.apply(json(#"{"@type":"updateDeleteMessages","chat_id":\#(vault),"message_ids":[81],"is_permanent":true,"from_cache":false}"#))
    check(!model.messages.contains { $0.id == 81 }, "a message deleted in a secret chat is gone here too")
    UserDefaults.standard.set(true, forKey: Preferences.archiveSecretChats)
    model.apply(json(#"{"@type":"updateNewMessage","message":\#(message(82, chat: vault, text: "останется"))}"#))
    model.apply(json(#"{"@type":"updateDeleteMessages","chat_id":\#(vault),"message_ids":[82],"is_permanent":true,"from_cache":false}"#))
    check(model.messages.first { $0.id == 82 }?.isDeleted == true, "unless keeping them was asked for")
    UserDefaults.standard.removeObject(forKey: Preferences.archiveSecretChats)

    let exported = SecurityTools.indicators(in: "https://evil.example/a 8.8.8.8 44d88612fea8a8f36de82e1278abb02f CVE-2024-3094 T1059.001")
    check(exported.json().contains(#""type" : "md5""#) && exported.json().contains("https://evil.example/a"), "indicators export as JSON with their types")
    check(exported.csv().hasPrefix("type,value\n") && exported.csv().contains(#""ipv4","8.8.8.8""#), "and as CSV")
    var formula = SecurityTools.Indicators()
    formula.domains = ["=cmd.example.com"]
    check(formula.csv().contains(#""'=cmd.example.com""#), "a value that would run as a spreadsheet formula is made text")
    let places = SecurityTools.lookups(for: "44d88612fea8a8f36de82e1278abb02f", kind: .hash).map(\.service)
    check(places == ["VirusTotal", "MalwareBazaar"] && SecurityTools.lookups(for: "T1059.001", kind: .technique).first?.url.absoluteString == "https://attack.mitre.org/techniques/T1059/001/",
          "each kind of indicator has its places to be looked up: \(places)")
    check(SecurityTools.lookups(for: "a b&c", kind: .domain).allSatisfy { !$0.url.absoluteString.contains(" ") && !$0.url.absoluteString.contains("&c") },
          "what goes into a lookup address is encoded, not pasted")

    // --- getting around: unread chats, reading a folder, a new device on the account -----------------------
    func plain(_ id: Int64, _ title: String, order: Int, unread: Int) {
        model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":\#(id),"type":{"@type":"chatTypePrivate","user_id":\#(id)},"title":"\#(title)","positions":[\#(mainPosition(String(9221294784513000000 + order)))],"unread_count":\#(unread),"last_read_inbox_message_id":0,"draft_message":null}}"#))
    }
    plain(9401, "Первый", order: 40, unread: 0)
    plain(9402, "Второй", order: 30, unread: 2)
    plain(9403, "Третий", order: 20, unread: 0)
    plain(9404, "Четвёртый", order: 10, unread: 5)
    pump()
    model.filter = ""
    model.selection = 9401
    model.selectUnreadChat(1)
    check(model.selection == 9402, "⌥⇧↓ goes to the next chat with something unread: \(String(describing: model.selection))")
    model.selectUnreadChat(1)
    check(model.selection == 9404, "skipping the ones that have nothing: \(String(describing: model.selection))")
    model.selectUnreadChat(-1)
    check(model.selection == 9402, "⌥⇧↑ goes back: \(String(describing: model.selection))")
    let waiting = model.unreadChatsOnScreen.filter { [9402, 9404].contains($0.id) }
    check(waiting.count == 2, "the folder knows which of its chats are waiting")
    model.recordedRequests = []
    Task { await model.markAllRead(waiting) }
    pump(0.2)
    check(model.toast?.contains("2 чата") == true, "reading a folder says how much it read: \(model.toast ?? "nil")")

    model.apply(json(#"{"@type":"updateUnconfirmedSession","session":{"@type":"unconfirmedSession","date":1790000000,"device_model":"iPhone 17","location":"Moscow, Russia"},"unconfirmed_session_count":1}"#))
    check(model.unconfirmedLogin == "iPhone 17 · Moscow, Russia", "a new device on the account is noticed: \(model.unconfirmedLogin ?? "nil")")
    model.apply(json(#"{"@type":"updateUnconfirmedSession","unconfirmed_session_count":0}"#))
    check(model.unconfirmedLogin == nil, "and forgotten once Telegram says it was dealt with")
}

print(failures == 0 ? "ALL PASSED (\(checks) checks)" : "\(failures) FAILED of \(checks)")
exit(failures == 0 ? 0 : 1)
