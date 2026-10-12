import AppKit
import AVFoundation
import SwiftUI

func json(_ text: String) -> TDNode { try! JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! TDNode }
func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
let position = #"{"@type":"chatPosition","list":{"@type":"chatListMain"},"order":"9221294784512000500","is_pinned":false,"source":null}"#
func pos(_ list: String, _ order: Int, pinned: Bool = false) -> String {
    #"{"@type":"chatPosition","list":\#(list),"order":"\#(9_221_294_784_512_000_000 + order)","is_pinned":\#(pinned),"source":null}"#
}
func folderList(_ id: Int) -> String { #"{"@type":"chatListFolder","chat_folder_id":\#(id)}"# }
func msg(_ id: Int, _ content: String, outgoing: Bool = false, extra: String = "") -> TDNode {
    json(#"{"@type":"updateNewMessage","message":{"@type":"message","id":\#(id),"chat_id":-1003,"sender_id":{"@type":"messageSenderUser","user_id":511},"is_outgoing":\#(outgoing),"date":\#(Int(Date().timeIntervalSince1970) - 60),"content":\#(content)\#(extra)}}"#)
}
let text = #"{"@type":"messageText","text":{"@type":"formattedText","text":"жирный текст и https://telegram.org @durov `код`","entities":[{"@type":"textEntity","offset":0,"length":6,"type":{"@type":"textEntityTypeBold"}},{"@type":"textEntity","offset":15,"length":20,"type":{"@type":"textEntityTypeUrl"}},{"@type":"textEntity","offset":36,"length":6,"type":{"@type":"textEntityTypeMention"}}]}}"#
let photo = #"{"@type":"messagePhoto","photo":{"@type":"photo","sizes":[{"@type":"photoSize","type":"x","photo":{"@type":"file","id":2,"size":6},"width":800,"height":600}]},"caption":{"@type":"formattedText","text":"подпись","entities":[]},"has_spoiler":false}"#
let video = #"{"@type":"messageVideo","video":{"@type":"video","duration":75,"width":1280,"height":720,"video":{"@type":"file","id":3,"size":9}},"caption":{"@type":"formattedText","text":"","entities":[]},"has_spoiler":false}"#
let gif = #"{"@type":"messageAnimation","animation":{"@type":"animation","duration":3,"width":320,"height":240,"animation":{"@type":"file","id":4,"size":999999999}},"caption":{"@type":"formattedText","text":"","entities":[]},"has_spoiler":false}"#
let note = #"{"@type":"messageVideoNote","video_note":{"@type":"videoNote","duration":9,"length":384,"video":{"@type":"file","id":5,"size":9}}}"#
let sticker = #"{"@type":"messageSticker","sticker":{"@type":"sticker","id":"1","width":512,"height":512,"emoji":"😀","format":{"@type":"stickerFormatWebp"},"sticker":{"@type":"file","id":6}}}"#

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    NSApp.appearance = NSAppearance(named: CommandLine.arguments.count > 2 ? .darkAqua : .aqua)
    let model = AppModel()
    model.apply(json(#"{"@type":"updateUser","user":{"@type":"user","id":511,"first_name":"Иван","last_name":"","type":{"@type":"userTypeRegular"},"status":{"@type":"userStatusRecently"}}}"#))
    model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":-1003,"type":{"@type":"chatTypeSupergroup","supergroup_id":3,"is_channel":false},"title":"Группа","positions":[\#(position)],"unread_count":3,"last_read_inbox_message_id":10,"draft_message":null}}"#))
    model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":511,"type":{"@type":"chatTypePrivate","user_id":511},"title":"Иван","positions":[\#(position.replacingOccurrences(of: "500", with: "400"))],"unread_count":0,"draft_message":{"@type":"draftMessage","date":1,"content":{"@type":"draftMessageContentText","text":{"@type":"formattedText","text":"черновик","entities":[]}}}}}"#))
    // The rail and the sections need folders and a handful of chats spread over them.
    @MainActor func addChat(_ id: Int64, _ title: String, _ type: String, _ positions: String, unread: Int = 0) {
        model.apply(json(#"{"@type":"updateNewChat","chat":{"@type":"chat","id":\#(id),"type":\#(type),"title":"\#(title)","positions":[\#(positions)],"unread_count":\#(unread),"last_read_inbox_message_id":0,"draft_message":null}}"#))
    }
    func folder(_ id: Int, _ name: String, _ icon: String, _ color: Int) -> String {
        #"{"@type":"chatFolderInfo","id":\#(id),"name":{"@type":"chatFolderName","text":{"@type":"formattedText","text":"\#(name)","entities":[]},"animate_custom_emoji":false},"icon":{"@type":"chatFolderIcon","name":"\#(icon)"},"color_id":\#(color),"is_shareable":false,"has_my_invite_links":false}"#
    }
    model.apply(json(#"{"@type":"updateChatFolders","chat_folders":[\#(folder(1, "Личные", "Private", 0)),\#(folder(2, "Каналы", "Channels", 3)),\#(folder(3, "Боты", "Bots", 5)),\#(folder(4, "Разное", "", -1))]}"#))
    model.apply(json(#"{"@type":"updateUser","user":{"@type":"user","id":702,"first_name":"Помощник","type":{"@type":"userTypeBot"},"status":{"@type":"userStatusOnline","was_online":0}}}"#))
    model.apply(json(#"{"@type":"updateUser","user":{"@type":"user","id":700,"first_name":"Мария","is_premium":true,"type":{"@type":"userTypeRegular"},"status":{"@type":"userStatusOnline","was_online":0}}}"#))
    let mainList = #"{"@type":"chatListMain"}"#
    addChat(700, "Мария", #"{"@type":"chatTypePrivate","user_id":700}"#,
            "\(pos(mainList, 30, pinned: true)),\(pos(folderList(1), 30))", unread: 2)
    addChat(701, "Вестник", #"{"@type":"chatTypeSupergroup","supergroup_id":701,"is_channel":true}"#,
            "\(pos(mainList, 29)),\(pos(folderList(2), 29))", unread: 128)
    addChat(702, "Помощник", #"{"@type":"chatTypePrivate","user_id":702}"#,
            "\(pos(mainList, 28)),\(pos(folderList(3), 28))", unread: 4)
    addChat(703, "Рабочая группа", #"{"@type":"chatTypeBasicGroup","basic_group_id":703}"#,
            "\(pos(mainList, 27)),\(pos(folderList(4), 27))", unread: 1)
    addChat(704, "Рассылка", #"{"@type":"chatTypeSupergroup","supergroup_id":704,"is_channel":true}"#,
            pos(#"{"@type":"chatListArchive"}"#, 26), unread: 9)
    model.phase = .working
    pump(0.1)
    print("rail fixture: folders \(model.chatFolders.count), chats \(model.chats.count), "
          + "badges all=\(model.mainUnread.count) archive=\(model.archiveUnread.count) "
          + "per folder=\(model.folderUnread.keys.sorted().map { "\($0):\(model.folderUnread[$0]?.count ?? 0)" }.joined(separator: ","))")
    print("folders parsed: " + model.chatFolders.map { "\($0.id) \($0.title) icon=\($0.icon) color=\($0.colorId)" }.joined(separator: " | "))
    pump(0.1)
    model.selection = -1003
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: RootView().environment(model))
    window.orderFrontRegardless()
    pump(1)
    for (index, content) in [text, photo, video, gif, note, sticker].enumerated() {
        model.apply(msg(20 + index, content, extra: index == 1 ? #","reply_to":{"@type":"messageReplyToMessage","chat_id":-1003,"message_id":20},"forward_info":{"@type":"messageForwardInfo","origin":{"@type":"messageOriginUser","sender_user_id":511},"date":1}"# : ""))
    }
    model.apply(msg(40, #"{"@type":"messageVoiceNote","voice_note":{"@type":"voiceNote","duration":14,"waveform":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+Pw==","voice":{"@type":"file","id":91,"size":20000}},"caption":{"@type":"formattedText","text":"","entities":[]}}"#))
    for id in [41, 42, 43] {
        model.apply(msg(id, #"{"@type":"messagePhoto","photo":{"@type":"photo","sizes":[{"@type":"photoSize","type":"x","photo":{"@type":"file","id":\#(id)},"width":800,"height":600}]},"caption":{"@type":"formattedText","text":"\#(id == 43 ? "альбом" : "")","entities":[]}}"#, extra: #","media_album_id":"555""#))
    }
    model.apply(msg(48, #"{"@type":"messagePhoto","photo":{"@type":"photo","sizes":[{"@type":"photoSize","type":"x","photo":{"@type":"file","id":48},"width":600,"height":800}]},"caption":{"@type":"formattedText","text":"💋 Создай свой поцелуй по 2 фото — длинная подпись, которая должна переноситься под фото","entities":[]}}"#))
    model.apply(msg(49, #"{"@type":"messagePoll","poll":{"@type":"poll","id":"5","question":{"@type":"formattedText","text":"Куда идём вечером?","entities":[]},"options":[{"@type":"pollOption","text":{"@type":"formattedText","text":"Кино","entities":[]},"voter_count":3,"vote_percentage":60,"is_chosen":true},{"@type":"pollOption","text":{"@type":"formattedText","text":"Парк","entities":[]},"voter_count":2,"vote_percentage":40,"is_chosen":false}],"total_voter_count":5,"is_anonymous":true,"type":{"@type":"pollTypeRegular"},"is_closed":false}}"#))
    model.apply(msg(50, #"{"@type":"messagePoll","poll":{"@type":"poll","id":"6","question":{"@type":"formattedText","text":"Новый опрос","entities":[]},"options":[{"@type":"pollOption","text":{"@type":"formattedText","text":"Да","entities":[]},"voter_count":0,"vote_percentage":0,"is_chosen":false},{"@type":"pollOption","text":{"@type":"formattedText","text":"Нет","entities":[]},"voter_count":0,"vote_percentage":0,"is_chosen":false}],"total_voter_count":0,"is_anonymous":false,"type":{"@type":"pollTypeRegular"},"is_closed":false}}"#))
    model.apply(msg(51, #"{"@type":"messageDocument","document":{"@type":"document","file_name":"Годовой отчёт 2026.pdf","mime_type":"application/pdf","document":{"@type":"file","id":851,"size":2500000,"expected_size":2500000}},"caption":{"@type":"formattedText","text":"смотри файл","entities":[]}}"#))
    model.apply(msg(44, #"{"@type":"messageText","text":{"@type":"formattedText","text":"с реакциями","entities":[]}}"#, extra: #","interaction_info":{"@type":"messageInteractionInfo","view_count":0,"reactions":{"@type":"messageReactions","reactions":[{"@type":"messageReaction","type":{"@type":"reactionTypeEmoji","emoji":"👍"},"total_count":3,"is_chosen":true},{"@type":"messageReaction","type":{"@type":"reactionTypeEmoji","emoji":"🔥"},"total_count":1,"is_chosen":false}]}}"#))
    model.pinnedMessage = TD.message(json(#"{"@type":"message","id":20,"chat_id":-1003,"date":1,"content":{"@type":"messageText","text":{"@type":"formattedText","text":"важное объявление","entities":[]}}}"#))
    model.translations["-1003:20"] = AppModel.Translation(
        text: "жирный перевод и https://telegram.org @durov `код`",
        entities: [TextEntity(offset: 0, length: 6, style: .bold),
                   TextEntity(offset: 15, length: 20, style: .link(URL(string: "https://telegram.org")!)),
                   TextEntity(offset: 36, length: 6, style: .link(URL(string: "https://t.me/durov")!))],
        languageCode: "de")
    model.translations["-1003:44"] = AppModel.Translation(text: "переведено, язык берётся из самого перевода", entities: [], languageCode: "ru")
    model.apply(msg(45, #"{"@type":"messageText","text":{"@type":"formattedText","text":"😂👍","entities":[]}}"#))
    model.apply(msg(46, #"{"@type":"messageText","text":{"@type":"formattedText","text":"смотри https://apple.com","entities":[{"@type":"textEntity","offset":7,"length":17,"type":{"@type":"textEntityTypeUrl"}}]},"link_preview":{"@type":"linkPreview","url":"https://apple.com","site_name":"Apple","title":"Apple","description":{"@type":"formattedText","text":"Discover the innovative world of Apple and shop everything iPhone, iPad, Mac.","entities":[]},"type":{"@type":"linkPreviewTypeArticle"}}}"#))
    model.apply(msg(47, #"{"@type":"messagePhoto","photo":{"@type":"photo","sizes":[{"@type":"photoSize","type":"x","photo":{"@type":"file","id":47},"width":800,"height":1000}]},"caption":{"@type":"formattedText","text":"","entities":[]},"has_spoiler":true}"#))
    model.apply(msg(30, #"{"@type":"messageText","text":{"@type":"formattedText","text":"моё","entities":[]}}"#, outgoing: true))
    model.apply(msg(31, #"{"@type":"messageText","text":{"@type":"formattedText","text":"моё второе, подлиннее, со ссылкой https://apple.com","entities":[{"@type":"textEntity","offset":34,"length":17,"type":{"@type":"textEntityTypeUrl"}}]}}"#, outgoing: true))
    model.apply(msg(33, #"{"@type":"messageText","text":{"@type":"formattedText","text":"Ура","entities":[]}}"#, extra: #","reply_to":{"@type":"messageReplyToMessage","chat_id":-1003,"message_id":31},"reply_markup":{"@type":"replyMarkupInlineKeyboard","rows":[[{"@type":"inlineKeyboardButton","text":"Профиль","type":{"@type":"inlineKeyboardButtonTypeCallback","data":"eA=="}},{"@type":"inlineKeyboardButton","text":"Сайт","type":{"@type":"inlineKeyboardButtonTypeUrl","url":"https://example.com"}}],[{"@type":"inlineKeyboardButton","text":"Открыть приложение","style":{"@type":"buttonStylePrimary"},"type":{"@type":"inlineKeyboardButtonTypeWebApp","url":"https://example.com"}}]]}"#))
    model.apply(msg(32, #"{"@type":"messageText","text":{"@type":"formattedText","text":"ответ собеседника","entities":[]}}"#, extra: #","reply_to":{"@type":"messageReplyToMessage","chat_id":-1003,"message_id":31}"#))
    model.apply(json(#"{"@type":"updateDeleteMessages","chat_id":-1003,"message_ids":[21],"is_permanent":true,"from_cache":false}"#))
    if CommandLine.arguments.contains("viewer") { model.viewerMessage = model.messages.first { $0.id == 47 } }
    // SELECT_MODE
    if CommandLine.arguments.contains("select") {
        model.beginSelection(with: model.messages.first { $0.id == 31 }!)
        model.toggleSelection(of: model.messages.first { $0.id == 44 }!)
    }
    model.apply(msg(60, #"{"@type":"messageText","text":{"@type":"formattedText","text":"моё сообщение с ответом","entities":[]}}"#, outgoing: true, extra: #","reply_to":{"@type":"messageReplyToMessage","chat_id":-1003,"message_id":44}"#))
    model.apply(msg(61, #"{"@type":"messageLocation","location":{"@type":"location","latitude":59.9386,"longitude":30.3141,"horizontal_accuracy":0}}"#))
    model.apply(msg(62, #"{"@type":"messageVenue","venue":{"@type":"venue","location":{"@type":"location","latitude":48.8584,"longitude":2.2945,"horizontal_accuracy":0},"title":"Эйфелева башня","address":"Champ de Mars, 5 Av. Anatole France, Paris","provider":"g","id":"1","type":"tower"},"caption":{"@type":"formattedText","text":"смотрели","entities":[]}}"#))
    model.apply(msg(63, #"{"@type":"messageContact","contact":{"@type":"contact","phone_number":"+79991234567","first_name":"Анна","last_name":"Смирнова","vcard":"","user_id":511}}"#))
    model.apply(msg(64, #"{"@type":"messageDice","initial_state":{"@type":"diceStickers","sticker":{"@type":"sticker","id":"1","width":1,"height":1,"emoji":"","format":{"@type":"stickerFormatWebp"},"sticker":{"@type":"file","id":1}}},"final_state":{"@type":"diceStickers","sticker":{"@type":"sticker","id":"2","width":1,"height":1,"emoji":"","format":{"@type":"stickerFormatWebp"},"sticker":{"@type":"file","id":2}}},"emoji":"🎲","value":5,"success_animation_frame_number":0}"#))
    // Your own bubbles are filled with the accent colour: everything a bubble can hold has to read on it.
    model.apply(msg(70, #"{"@type":"messageText","text":{"@type":"formattedText","text":"моё со ссылкой https://apple.com и жирным","entities":[{"@type":"textEntity","offset":15,"length":17,"type":{"@type":"textEntityTypeUrl"}},{"@type":"textEntity","offset":35,"length":6,"type":{"@type":"textEntityTypeBold"}}]},"link_preview":{"@type":"linkPreview","url":"https://apple.com","site_name":"Apple","title":"Apple","description":{"@type":"formattedText","text":"Discover the innovative world of Apple.","entities":[]},"type":{"@type":"linkPreviewTypeArticle"}}}"#, outgoing: true, extra: #","forward_info":{"@type":"messageForwardInfo","origin":{"@type":"messageOriginUser","sender_user_id":511},"date":1}"#))
    model.apply(msg(71, #"{"@type":"messageVoiceNote","voice_note":{"@type":"voiceNote","duration":14,"waveform":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+Pw==","voice":{"@type":"file","id":92,"size":20000}},"caption":{"@type":"formattedText","text":"","entities":[]}}"#, outgoing: true))
    model.apply(msg(72, #"{"@type":"messageDocument","document":{"@type":"document","file_name":"Мой файл.zip","mime_type":"application/zip","document":{"@type":"file","id":852,"size":1500000,"expected_size":1500000}},"caption":{"@type":"formattedText","text":"подпись к файлу","entities":[]}}"#, outgoing: true))
    model.apply(msg(73, #"{"@type":"messagePoll","poll":{"@type":"poll","id":"7","question":{"@type":"formattedText","text":"Мой опрос","entities":[]},"options":[{"@type":"pollOption","text":{"@type":"formattedText","text":"Да","entities":[]},"voter_count":3,"vote_percentage":75,"is_chosen":true},{"@type":"pollOption","text":{"@type":"formattedText","text":"Нет","entities":[]},"voter_count":1,"vote_percentage":25,"is_chosen":false}],"total_voter_count":4,"is_anonymous":true,"type":{"@type":"pollTypeRegular"},"is_closed":false}}"#, outgoing: true))
    model.apply(msg(74, #"{"@type":"messageLocation","location":{"@type":"location","latitude":55.7558,"longitude":37.6173,"horizontal_accuracy":0}}"#, outgoing: true))
    model.apply(msg(75, #"{"@type":"messageText","text":{"@type":"formattedText","text":"короткое","entities":[]}}"#))
    model.apply(msg(76, #"{"@type":"messageText","text":{"@type":"formattedText","text":"ответ на пост канала","entities":[]}}"#, extra: #","reply_to":{"@type":"messageReplyToMessage","chat_id":-100777,"message_id":9,"origin":{"@type":"messageOriginHiddenUser","sender_name":"Вестник"},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"Новый выпуск уже на сайте","entities":[]}}}"#))
    model.openChatIsForum = true
    model.topics = [
        Topic(id: 1, name: "Общее", unread: 3),
        Topic(id: 7, name: "Релизы", unread: 12),
        Topic(id: 8, name: "Оффтоп", isClosed: true),
    ]
    model.openTopicId = 7
    pump(2)
    print("conversation rendered: \(model.messages.count) messages")

    let player = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    player.contentView = NSHostingView(rootView: PlayerControlsView(player: AVPlayer()).frame(width: 320, height: 200))
    player.orderFrontRegardless()
    pump(0.5)
    print("video player rendered")

    let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    settings.contentView = NSHostingView(rootView: SettingsView().environment(model))
    settings.orderFrontRegardless()
    pump(1)
    print("settings rendered")

    settings.orderOut(nil)
    player.orderOut(nil)
    window.makeKeyAndOrderFront(nil)
    pump(1)
    if let view = window.contentView, let layer = view.layer {
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        layer.render(in: context)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("captured")
    }
    let node = json(#"{"@type":"message","id":1048576,"chat_id":-1003,"date":1790000000,"is_outgoing":false,"sender_id":{"@type":"messageSenderUser","user_id":511},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"привет","entities":[]}},"reply_to":null,"is_pinned":false}"#)
    let codeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
    codeWindow.contentView = NSHostingView(rootView: CodeSheet(code: InspectedCode(title: "Сообщение 1048576", json: "{}", node: node)))
    codeWindow.orderFrontRegardless()
    pump(0.5)
    if let view = codeWindow.contentView, let layer = view.layer {
        let size = view.bounds.size, scale = codeWindow.backingScaleFactor
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        layer.render(in: context)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + ".code.png"))
    }
    /// A window of the app's own views, rendered to a PNG. `configure` runs after the view has appeared,
    /// so a sheet that loads on appear can be given the state it would have fetched.
    func snapshot<V: View>(@ViewBuilder _ view: () -> V, size: CGSize, to path: String, then configure: () -> Void = {}) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view())
        window.orderFrontRegardless()
        pump(0.7)
        configure()
        pump(0.7)
        defer { window.orderOut(nil) }
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    @MainActor func fillManageSheet(canChangeInfo: Bool, members: [ChatMemberInfo]) {
        model.chatAccess = ChatAccess(
            isCreator: true, isAdmin: true, canChangeInfo: canChangeInfo, canInvite: true, canRestrict: true,
            canPromote: true, canDeleteMessages: true, canGetMembers: true, isChannel: true,
            about: "Общий чат команды. По делу и без флуда.",
            primaryLink: "https://t.me/joinchat/AAAAAE0", memberCount: 128
        )
        model.members = members
        model.membersTotal = 128
        model.statistics = ChannelStats(from: Date().addingTimeInterval(-7 * 86400), to: Date(),
                                                   members: 12840, membersGrowth: 2.4, meanViews: 8900,
                                                   meanShares: 14.5, meanReactions: 61)
        model.inviteLinks = [
            InviteLinkInfo(url: "https://t.me/joinchat/AAAAAF1", name: "Конференция в пятницу",
                           expirationDate: Date().addingTimeInterval(86400), memberLimit: 50, memberCount: 12),
        ]
    }

    let group = model.chat(withId: -1003)
    if let group {
        snapshot({ ChatManageSheet(chat: group).environment(model) },
                 size: CGSize(width: 540, height: 640),
                 to: CommandLine.arguments[1] + ".manage.png",
                 then: {
            fillManageSheet(canChangeInfo: true, members: [
                ChatMemberInfo(userId: 511, name: "Иван Петров", rank: .admin),
                ChatMemberInfo(userId: 512, name: "Мария Соколова", rank: .member),
                ChatMemberInfo(userId: 513, name: "Анна Смирнова", rank: .restricted,
                               untilDate: Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
                ChatMemberInfo(userId: 514, name: "Спам-бот", rank: .banned),
            ])
        })
        // The rights editor, which is a sheet of its own.
        let adminMember = ChatMemberInfo(userId: 511, name: "Иван Петров", rank: .admin, canBeEdited: true,
                                     rights: ["can_manage_chat": true, "can_delete_messages": true])
        snapshot({ RightsSheet(chat: group, member: adminMember, isAdmin: true).environment(model) },
                 size: CGSize(width: 430, height: 560), to: CommandLine.arguments[1] + ".rights.png")
        // A second take without the rename card: the links are below the fold in the first one.
        snapshot({ ChatManageSheet(chat: group).environment(model) },
                 size: CGSize(width: 540, height: 640),
                 to: CommandLine.arguments[1] + ".manage2.png",
                 then: {
            fillManageSheet(canChangeInfo: false, members: [
                ChatMemberInfo(userId: 512, name: "Мария Соколова", rank: .member),
            ])
        })
        // The members column, with the same roster the sheet was given.
        snapshot({ MembersPanel(chat: group).environment(model) }, size: CGSize(width: 300, height: 560),
                 to: CommandLine.arguments[1] + ".members.png",
                 then: {
            fillManageSheet(canChangeInfo: true, members: [
                ChatMemberInfo(userId: 501, name: "Ольга Ветрова", rank: .owner),
                ChatMemberInfo(userId: 511, name: "Иван Петров", rank: .admin, canBeEdited: true,
                               rights: ["can_manage_chat": true, "can_delete_messages": true]),
                ChatMemberInfo(userId: 512, name: "Мария Соколова", rank: .member),
                ChatMemberInfo(userId: 513, name: "Анна Смирнова", rank: .restricted,
                               untilDate: Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
                ChatMemberInfo(userId: 514, name: "Спам-бот", rank: .banned),
            ])
        })
        print("management sheet rendered")
    }
    // The sidebar snapshots share one model, and which place is open is model state, not view state: without
    // an explicit reset each later snapshot inherits the previous one's folder, archive and filters.
    @MainActor func atPlace(archive: Bool = false, folder: Int? = nil, members: Bool = false) {
        model.filter = ""
        model.showsArchive = archive
        model.selectedFolder = folder
        model.showsMembersPanel = members
    }
    // The whole window at ordinary proportions: the rail, the list with its sections, the conversation.
    // The first column of a split view is not part of the captured layer tree, so the rail is drawn alone too.
    snapshot({ WorkspaceView().environment(model) }, size: CGSize(width: 1180, height: 760),
             to: CommandLine.arguments[1] + ".rail.png", then: { atPlace() })
    // The profile of a person: the round actions under the name, the facts, what was shared, and blocking last.
    do {
        var person = ProfileInfo(title: "Мария", photo: nil, seed: 700, subtitle: "в сети", telegramId: 700, dataCenter: 2)
        person.userId = 700
        person.usernames = ["maria"]
        person.about = "Пишу редко, отвечаю быстро."
        snapshot({ ProfileSheet(info: person).environment(model) }, size: CGSize(width: 440, height: 640),
                 to: CommandLine.arguments[1] + ".profile.png")
    }
    snapshot({ ChatListView().environment(model).frame(width: 320, height: 700) },
             size: CGSize(width: 320, height: 700), to: CommandLine.arguments[1] + ".list.png",
             then: { atPlace() })
    // While searching the header must stop quoting the place's numbers: the rows are matches, not the folder.
    snapshot({ ChatListView().environment(model).frame(width: 320, height: 700) },
             size: CGSize(width: 320, height: 700), to: CommandLine.arguments[1] + ".search.png",
             then: { atPlace(); model.filter = "Вест" })
    snapshot({ WorkspaceView().environment(model) }, size: CGSize(width: 1180, height: 760),
             to: CommandLine.arguments[1] + ".folder.png", then: { atPlace(folder: 2) })
    snapshot({ WorkspaceView().environment(model) }, size: CGSize(width: 1180, height: 760),
             to: CommandLine.arguments[1] + ".archive.png", then: { atPlace(archive: true) })
    // The same window a third narrower with the members column open: does the transcript survive the squeeze?
    // The roster itself stays empty here — the column's own task re-reads it, and offline that fails; what is
    // being looked at is the width, not the names.
    // The same window at the width the layout now demands with the column open: nothing may be cut off.
    snapshot({ WorkspaceView().environment(model) }, size: CGSize(width: 1060, height: 700),
             to: CommandLine.arguments[1] + ".narrow.png", then: { atPlace(members: true) })
    // The same window without the column: tells a squeeze caused by the panel from one caused by the rail.
    snapshot({ WorkspaceView().environment(model) }, size: CGSize(width: 1000, height: 700),
             to: CommandLine.arguments[1] + ".narrow-nocolumn.png", then: { atPlace() })
    // The topic chips must not show a scroll bar, whatever the Mac's "show scroll bars" setting says.
    @MainActor func scrollers(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollers(in: $0) }
    }
    do {
        let chips = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        chips.contentView = NSHostingView(rootView: TopicBar(chat: model.chat(withId: -1003)!).environment(model).padding(10).frame(width: 330, height: 60))
        chips.orderFrontRegardless()
        pump(1)
        let found = chips.contentView.map { scrollers(in: $0) } ?? []
        let visible = found.filter { $0.hasHorizontalScroller || $0.hasVerticalScroller }
        print(found.isEmpty ? "FAIL chip row has no scroll view to check" : visible.isEmpty ? "chip row scroll bars: none" : "FAIL chip row still has \(visible.count) scroll bar(s)")
        chips.orderOut(nil)
    }
    // Albums follow their pictures' proportions: every row spans the album's width exactly.
    do {
        func shot(_ id: Int64, _ width: Int, _ height: Int) -> Message {
            var message = Message(id: id, chatId: 1, senderKey: "u1", isOutgoing: false, body: .attachment("Фото"),
                                  date: Date(), isPending: false, isFailed: false, isPinned: false)
            message.media = MediaInfo(kind: .photo, fileId: Int(id), fileSize: 1, thumbnailFileId: nil, minithumbnail: nil,
                                      width: width, height: height, duration: 0, hasSpoiler: false)
            return message
        }
        var problems: [String] = []
        for count in 1...10 {
            let items = (0..<count).map { shot(Int64(100 + $0), $0 % 3 == 0 ? 1600 : 900, $0 % 3 == 0 ? 900 : 1600) }
            let rows = AlbumView.layout(items)
            if rows.flatMap({ $0 }).count != count { problems.append("\(count): lost pictures") }
            for row in rows {
                let span = row.reduce(0) { $0 + $1.size.width } + AlbumView.gap * CGFloat(row.count - 1)
                if abs(span - AlbumView.width) > 0.5 || row.contains(where: { $0.size.width < 40 || $0.size.height < 60 }) {
                    problems.append("\(count): row spans \(span)")
                }
            }
        }
        let pair = AlbumView.layout([shot(1, 1600, 900), shot(2, 900, 1600)])[0]
        if pair[0].size.width <= pair[1].size.width { problems.append("a landscape shot is not wider than a portrait one") }
        print(problems.isEmpty ? "album rows: every size spans the width" : "FAIL album layout: \(problems.joined(separator: "; "))")
    }
    print("rail rendered")
    print("SMOKE PASSED")
}
exit(0)
