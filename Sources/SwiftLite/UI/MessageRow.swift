import AppKit
import SwiftUI

/// The little a message row needs from its chat. Typing, presence and unread counts change the chat
/// constantly; passing only these keeps every visible message from redrawing on each of those updates.
struct RowChat: Equatable {
    let id: Int64
    let kind: ChatKind
    let lastReadOutboxId: Int64

    init(_ chat: Chat) {
        id = chat.id
        kind = chat.kind
        lastReadOutboxId = chat.lastReadOutboxId
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Preferences.messageFontSize) private var messageFontSize = 14
    @AppStorage(Preferences.chatBackground) private var chatBackground = ChatBackground.glass.rawValue
    @AppStorage(Preferences.showMessageCode) private var showsCode = false
    @AppStorage(Preferences.showIdentifiers) private var showsIdentifiers = false
    @AppStorage(Preferences.securityTools) private var securityTools = true
    @AppStorage(Preferences.markLocalEdits) private var marksLocalEdits = false
    // Read so the row is drawn again when either setting changes; `AdFilter` reads the values itself.
    @AppStorage(Preferences.hideAds) private var hidesAds = true
    @AppStorage(Preferences.filterWords) private var filterWords = ""
    @AppStorage(Preferences.adLearned) private var learnedAds = ""
    @AppStorage(Preferences.adExemptChats) private var exemptChats = ""
    /// A message the filter folded away, shown after all because it was asked for.
    @State private var isRevealed = false

    let row: TranscriptRow
    let chat: RowChat
    /// Width of the bubble, which the keyboard under it follows.
    @State private var contentWidth: CGFloat = 0
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A message that has just arrived grows out of the corner its tail points to; this says it has done so.
    @State private var hasSettled = false
    /// Bumped when this row's custom emoji have been decoded, so the text and reactions are drawn again.
    @State private var emojiRound = 0

    private var message: Message { row.message }

    /// The next time the clock shows this hour: today if it is still ahead, otherwise tomorrow.
    private static func next(hour: Int) -> Date {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return today > Date() ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    private var hiddenReason: AdFilter.Reason? {
        guard hidesAds || !filterWords.isEmpty else { return nil }
        // Named so the row is drawn again when what was learned, or which channels are skipped, changes.
        _ = (learnedAds, exemptChats)
        return AdFilter.reason(for: message, in: chat.kind)
    }

    var body: some View {
        if case .service(let text) = message.body {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else if !isRevealed, !model.isSelectingMessages, let reason = hiddenReason {
            // Folded, not removed: the post is one click away, and the transcript keeps its place.
            Button {
                withAnimation(.smooth(duration: 0.2)) { isRevealed = true }
                // The third post shown in one channel: its ads seem to be wanted, and the filter can skip it.
                if reason == .advertisement, AdFilter.noteReveal(in: chat.id) {
                    model.showToast(L("Рекламу этого канала можно не скрывать: правый клик по каналу в списке"))
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                    Text(reason == .advertisement ? L("Реклама скрыта") : L("Скрыто фильтром"))
                    Text(L("Показать")).foregroundStyle(Color.brandInk)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .glassSurface(in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressDimStyle())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if model.isSelectingMessages {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.brandInk) : AnyShapeStyle(.tertiary))
                        .padding(.bottom, 4)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if message.isOutgoing {
                    Spacer(minLength: 60)
                } else if showsSenders {
                    senderSlot
                }
                bubble
                    // Beside the bubble, outside its frame: pinned to the bubble's edge and moved out by their own
                    // known width, so they never cover the bubble and never move the layout.
                    .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
                        if isHovered, showsHoverActions {
                            hoverActions
                                .frame(width: Self.hoverActionsWidth)
                                .offset(x: message.isOutgoing ? -(Self.hoverActionsWidth + 8) : Self.hoverActionsWidth + 8)
                                .transition(.opacity)
                        }
                    }
                if !message.isOutgoing {
                    Spacer(minLength: 60)
                }
            }
            .scaleEffect(arrives && !hasSettled ? 0.86 : 1, anchor: message.isOutgoing ? .bottomTrailing : .bottomLeading)
            .opacity(arrives && !hasSettled ? 0 : 1)
            .onAppear {
                guard !hasSettled else { return }
                if arrives {
                    withAnimation(.spring(duration: 0.34, bounce: 0.3)) { hasSettled = true }
                } else {
                    hasSettled = true
                }
            }
            // The whole width of the row counts, empty side included: on the way from the bubble to its
            // buttons the pointer crosses the gap between them, and without this the buttons faded first.
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(.smooth(duration: 0.12)) { isHovered = inside }
            }
            // While picking messages a click anywhere on the row picks it, instead of opening media or links.
            .overlay {
                if model.isSelectingMessages {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggleSelection(of: message) }
                }
            }
            .animation(.smooth(duration: 0.15), value: model.isSelectingMessages)
            // Messages of one run sit close together; runs are set apart.
            .padding(.top, row.showsSender ? 8 : 1.5)
            .padding(.bottom, row.endsGroup ? 6 : 1.5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.brand.opacity(0.1))
                        .padding(.horizontal, -8)
                } else if model.highlightedMessageId == message.id {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.brand.opacity(0.12))
                        .padding(.horizontal, -8)
                }
            }
            .animation(.smooth(duration: 0.3), value: model.highlightedMessageId == message.id)
        }
    }

    /// Whether this row is a message coming in right now, as opposed to history being laid out. Yours counts
    /// while it is being sent; the copy that replaces it once the server has it is the same message to the
    /// eye and must not jump a second time.
    private var arrives: Bool {
        guard !reduceMotion else { return false }
        return message.isPending || (!message.isOutgoing && abs(message.date.timeIntervalSinceNow) < 2)
    }

    /// Three 26-point buttons, 2 points apart, 3 points of padding on each side.
    private static let hoverActionsWidth: CGFloat = 3 * 26 + 2 * 2 + 2 * 3

    private var showsHoverActions: Bool {
        !model.isSelectingMessages && message.isSent && !message.isDeleted && !message.isService
    }

    /// Reply, a quick 👍 and forward, like the hover buttons of Telegram Desktop and Messages.
    private var hoverActions: some View {
        HStack(spacing: 2) {
            hoverButton("arrowshape.turn.up.left", help: L("Ответить")) { model.beginReply(to: message) }
            Button {
                Task { await model.toggleReaction(AppModel.quickReactions[0], on: message) }
            } label: {
                Text(AppModel.quickReactions[0]).font(.body).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(L("Поставить \(AppModel.quickReactions[0])"))
            .accessibilityLabel(L("Поставить реакцию"))
            hoverButton("arrowshape.turn.up.right", help: L("Переслать")) {
                model.prepareForwarding([message])
            }
        }
        .padding(.horizontal, 3)
        .glassSurface(in: Capsule(), interactive: true)
        .fixedSize()
    }

    private func hoverButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    /// Custom emoji of the text and of the reactions under it.
    private var customEmojiIds: [Int64] {
        CustomEmoji.ids(in: message.entities) + message.reactions.compactMap { $0.customEmojiId != 0 ? $0.customEmojiId : nil }
    }

    private func loadCustomEmoji() async {
        if await CustomEmoji.load(customEmojiIds, with: model) { emojiRound += 1 }
    }

    private var isSelected: Bool {
        model.isSelectingMessages && model.selectedMessageIds.contains(message.id)
    }

    /// Only groups have several authors; private chats and channels speak with one voice.
    private var showsSenders: Bool {
        chat.kind == .group || chat.kind == .other
    }

    /// The avatar stands next to the last message of a run, where the tail points.
    @ViewBuilder
    private var senderSlot: some View {
        if row.endsGroup {
            Avatar(title: senderName, seed: seed, photo: model.photo(for: message), diameter: 30)
                .onTapGesture { Task { await model.showProfile(ofSender: message) } }
                .help(L("Профиль"))
                .padding(.bottom, showsStatus ? 16 : 0)
        } else {
            Color.clear.frame(width: 30, height: 1)
        }
    }

    /// Buttons a bot attached under this message.
    private var inlineRows: [[BotButton]]? {
        guard let markup = message.markup, markup.kind == .inline, !markup.rows.isEmpty else { return nil }
        return markup.rows
    }

    /// Surfaces that draw themselves — a sticker, a round video note, an album grid, a bare photo, a message
    /// that is only emoji — have no bubble to hold the author and the time, so those stay outside them.
    /// Everything else carries them inside, the way Telegram does.
    private var carriesOwnSurface: Bool {
        message.sticker != nil || message.media?.kind == .videoNote || row.album.count > 1
            || bigEmoji != nil || (message.media != nil && isBareMedia)
    }

    @ViewBuilder
    private var mainContent: some View {
        if carriesOwnSurface {
            ownSurface
        } else {
            bubbleBody
        }
    }

    @ViewBuilder
    private var ownSurface: some View {
        if let sticker = message.sticker {
            StickerView(sticker: sticker)
        } else if let media = message.media, media.kind == .videoNote {
            MediaView(message: message, media: media)
        } else if row.album.count > 1 {
            albumBody
        } else if let emoji = bigEmoji {
            Text(emoji)
                .font(.system(size: 44))
                .textSelection(.enabled)
        } else if let media = message.media, isBareMedia {
            // A photo or video without words is shown on its own, like in Messages, with the time on it.
            MediaView(message: message, media: media)
                .overlay { failureOutline(radius: 16) }
                .overlay(alignment: .bottomTrailing) {
                    if timeOnMedia { mediaTimeBadge }
                }
        }
    }

    private var bubble: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
            // Above the bubble, as Messages names the author in a group.
            if row.showsSender, !message.isOutgoing, showsSenders {
                senderLine.padding(.leading, 12)
            }
            if let rows = inlineRows {
                mainContent
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                InlineKeyboard(message: message, rows: rows)
                    .frame(width: max(contentWidth, 240))
            } else {
                mainContent
            }
            if !message.reactions.isEmpty {
                reactionsRow
            }
            // Under the bubble rather than in it: "Доставлено 14:32" is about the bubble, not part of what
            // was said.
            if showsStatus {
                statusLine
                    .padding(.horizontal, 6)
            }
        }
        .opacity(message.isDeleted ? 0.7 : 1)
        .contextMenu { menu }
        .task(id: message.replyToId) { await model.loadRepliedMessage(for: message) }
        .task(id: customEmojiIds) { await loadCustomEmoji() }
    }

    /// An album: the grid, with the one caption the album has (Telegram puts it on one of the photos).
    private var albumBody: some View {
        let caption = row.album.first { !$0.caption.isEmpty }
        return BubbleStack(spacing: 6) {
            AlbumView(messages: row.album)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .layoutValue(key: BubblePartKey.self, value: .media)
            if let caption {
                Text(formattedText(caption.caption, caption.entities))
                    .font(.system(size: Double(messageFontSize)))
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
            }
        }
        .padding(caption == nil ? 0 : 4)
        .bubbleInk(isOutgoing: message.isOutgoing && caption != nil)
        .background(caption == nil ? AnyShapeStyle(Color.clear) : bubbleColor, in: BubbleShape(isOutgoing: message.isOutgoing, hasTail: row.endsGroup))
    }

    private var bigEmoji: String? {
        guard case .text(let text) = message.body, message.media == nil, message.sticker == nil, !message.isForwarded,
              message.replyToId == 0, message.foreignReply == nil, message.linkPreview == nil, message.entities.isEmpty,
              text.isBigEmoji else { return nil }
        return text
    }

    /// Photos, videos and GIFs without a caption carry their time in a plaque on the picture.
    private var timeOnMedia: Bool {
        guard let kind = message.media?.kind, isBareMedia else { return false }
        return kind == .photo || kind == .video || kind == .animation
    }

    private var mediaTimeBadge: some View {
        HStack(spacing: 3) {
            Text(message.date.timeStamp)
            if message.isOutgoing, message.isSent {
                Text(isRead ? "✓✓" : "✓")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(7)
        .allowsHitTesting(false)
    }

    private var isBareMedia: Bool {
        message.media?.kind != .voiceNote && message.caption.isEmpty && !message.isForwarded && message.replyToId == 0
            && message.foreignReply == nil
    }

    /// A bubble carries its own time, ticks and "edited" in its corner; what has no bubble (a sticker, an
    /// album, a bare picture) has them on the line under it, once per run.
    private var hasInlineMeta: Bool { !carriesOwnSurface }

    /// The line under a message: for a bubble only what is unusual about it, since its time is inside.
    private var showsStatus: Bool {
        let unusual = message.isPending || message.isFailed || message.isDeleted || message.isPinned
            || showsIdentifiers || (marksLocalEdits && message.localText != nil)
        if hasInlineMeta { return unusual }
        return unusual || (row.endsGroup && !timeOnMedia) || message.isEdited || message.hasEditHistory
    }

    /// "изм. 14:32 ✓✓" as plain text: its length is what the last line of the message leaves room for.
    private var metaText: String {
        var parts: [String] = []
        if message.viewCount > 0 { parts.append("◉ " + message.viewCount.formatted(.number.notation(.compactName).locale(Loc.locale))) }
        if message.isEdited || message.hasEditHistory { parts.append(L("изм.")) }
        parts.append(message.date.timeStamp)
        if message.isOutgoing, message.isSent { parts.append(isRead ? "✓✓" : "✓") }
        return parts.joined(separator: " ")
    }

    /// In the bubble's lower right corner, where every messenger keeps it.
    private var metaLabel: some View {
        Text(verbatim: metaText)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(message.isOutgoing ? AnyShapeStyle(.white.opacity(0.72)) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
            .help(message.isOutgoing ? (isRead ? L("Прочитано") : L("Доставлено")) : "")
    }

    /// The bubble ends in words, so the time shares their last line; otherwise it gets a strip of its own.
    private var endsWithText: Bool {
        if model.translation(of: message) != nil || model.isTranslating(message) || message.linkPreview != nil { return false }
        if message.poll != nil || message.contact != nil || message.dice != nil { return false }
        if message.location != nil || message.document != nil || message.media != nil { return !message.caption.isEmpty }
        if case .text = message.body { return true }
        return false
    }

    private var bubbleBody: some View {
        BubbleStack(spacing: 4) {
            if message.isForwarded {
                Label(forwardName.map { L("Переслано от \($0)") } ?? L("Переслано"), systemImage: "arrowshape.turn.up.right")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(message.isOutgoing ? Color.white : Color.brandInk)
            }
            if let replied = row.reply {
                ReplyQuote(
                    name: model.name(for: replied),
                    text: TD.preview(of: replied),
                    tint: message.isOutgoing ? .white : Palette.tint(for: Self.seed(of: replied, in: chat)),
                    textStyle: secondaryInk
                ) {
                    Task { await model.jump(to: replied.id) }
                }
                .layoutValue(key: BubblePartKey.self, value: .fill)
            } else if let foreign = message.foreignReply {
                // The quote of a message from another chat; a click goes there when the chat is in reach.
                ReplyQuote(
                    name: foreignName(foreign),
                    text: foreign.text,
                    tint: message.isOutgoing ? .white : Color.brandInk,
                    textStyle: secondaryInk
                ) {
                    model.open(foreign)
                }
                .layoutValue(key: BubblePartKey.self, value: .fill)
            }
            if let poll = message.poll {
                PollView(message: message, poll: poll)
            } else if let location = message.location {
                LocationCard(location: location)
                    .layoutValue(key: BubblePartKey.self, value: .fill)
                if !message.caption.isEmpty {
                    messageText(message.caption)
                }
            } else if let contact = message.contact {
                ContactCard(contact: contact)
                    .layoutValue(key: BubblePartKey.self, value: .fill)
            } else if let dice = message.dice {
                DiceView(dice: dice)
            } else if let document = message.document {
                DocumentView(message: message, document: document)
                if !message.caption.isEmpty {
                    messageText(message.caption)
                }
            } else if let media = message.media {
                MediaView(message: message, media: media)
                    .padding(.horizontal, -6)
                    .padding(.top, message.isForwarded || message.replyToId != 0 ? 0 : -4)
                    .layoutValue(key: BubblePartKey.self, value: .media)
                if !message.caption.isEmpty {
                    messageText(message.caption)
                }
            } else {
                content
            }
            if let translation = model.translation(of: message) {
                TranslationCard(translation: translation, fontSize: Double(messageFontSize)) {
                    model.hideTranslation(of: message)
                }
                .layoutValue(key: BubblePartKey.self, value: .fill)
            } else if model.isTranslating(message) {
                Label(L("Перевод…"), systemImage: "globe")
                    .font(.system(size: Double(messageFontSize - 1)))
                    .foregroundStyle(.secondary)
            }
            if let preview = message.linkPreview {
                LinkPreviewCard(preview: preview)
                    .layoutValue(key: BubblePartKey.self, value: .fill)
            }
            if !endsWithText {
                // Nothing to share a line with: a strip under the card or the file for the time to sit on,
                // as wide as the time so a narrow bubble grows to hold it.
                metaLabel.hidden()
                    .frame(height: 8)
                    .layoutValue(key: BubblePartKey.self, value: .fill)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .bubbleInk(isOutgoing: message.isOutgoing)
        .background(bubbleColor, in: BubbleShape(isOutgoing: message.isOutgoing, hasTail: row.endsGroup))
        .overlay(alignment: .bottomTrailing) {
            metaLabel
                .padding(.trailing, 11)
                .padding(.bottom, 6)
        }
        .overlay { failureOutline(radius: 18) }
    }

    @ViewBuilder
    private func failureOutline(radius: CGFloat) -> some View {
        if message.isFailed || message.isDeleted {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.red.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: message.isDeleted ? [4] : []))
        }
    }

    private var secondaryInk: AnyShapeStyle {
        AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch message.body {
        case .text(let text):
            messageText(text)
        case .attachment(let name):
            Label(name, systemImage: "doc.fill")
                .font(.system(size: Double(messageFontSize)))
        case .unsupported(let name):
            Label(name, systemImage: "questionmark.square.dashed")
                .font(.system(size: Double(messageFontSize - 1)))
                .foregroundStyle(secondaryInk)
        case .service(let text):
            Text(text)
                .font(.system(size: Double(messageFontSize)))
        }
    }

    /// A local edit replaces the words (its own, without the original formatting).
    private func messageText(_ text: String) -> some View {
        let shown = message.localText ?? text
        let entities = message.localText == nil ? message.entities : []
        // Plain text, most messages, is drawn as is: wrapping it in an AttributedString copied it on every redraw.
        // `emojiRound` is read so the text is drawn again once this row's custom emoji have been decoded.
        let pictured = emojiRound >= 0 && !customEmojiIds.isEmpty
            ? CustomEmoji.text(shown, entities, fontSize: Double(messageFontSize)) : nil
        var words: Text = pictured ?? (entities.isEmpty ? Text(verbatim: shown) : Text(formattedText(shown, entities)))
        if hasInlineMeta, endsWithText {
            // Unbreakable blanks as wide as the time: the last line keeps that much free for it, and when it
            // has no room they wrap, which makes a line for the time to sit on.
            let room = String(repeating: "\u{2007}", count: metaText.count + 2)
            words = words + Text(verbatim: " " + room).font(.system(size: 10, weight: .medium))
        }
        return words
            .font(.system(size: Double(messageFontSize)))
            .lineSpacing(1.5)
            .textSelection(.enabled)
    }

    /// Reactions as small capsules; yours are tinted, and a click adds or takes back your own.
    private var reactionsRow: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions, id: \.key) { reaction in
                Button {
                    Task { await model.toggleReaction(reaction.emoji, customEmojiId: reaction.customEmojiId, on: message) }
                } label: {
                    HStack(spacing: 3) {
                        if reaction.customEmojiId == 0 {
                            Text(reaction.emoji).font(.callout)
                        } else if emojiRound >= 0, let picture = CustomEmoji.image(reaction.customEmojiId, side: 16) {
                            Image(nsImage: picture)
                        } else {
                            // Until its picture arrives the capsule keeps its shape.
                            Color.clear.frame(width: 16, height: 16)
                        }
                        Text(reaction.count.formatted(.number.notation(.compactName)))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(reaction.count)))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        reaction.isChosen ? AnyShapeStyle(Color.brand.opacity(0.25)) : AnyShapeStyle(Color.primary.opacity(0.07)),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(reaction.isChosen ? Color.brand.opacity(0.6) : .clear))
                }
                .buttonStyle(.plain)
                .help(reaction.isChosen ? L("Убрать реакцию") : reaction.emoji.isEmpty ? L("Поставить такую же") : L("Поставить \(reaction.emoji)"))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        // A reaction lands with a little bounce, and the others make room for it.
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.38), value: message.reactions)
    }

    /// The author's name in their own colour: inside the bubble where there is one, above the surface where
    /// there is not.
    @ViewBuilder
    private var senderLine: some View {
        if !message.isOutgoing, showsSenders {
            HStack(spacing: 3) {
                Text(senderName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                NameBadgeView(key: message.senderKey, size: 13)
            }
            .onTapGesture { Task { await model.showProfile(ofSender: message) } }
        }
    }

    /// Under the last message of a run: "Прочитано 14:32" for your own, the time for others'.
    private var statusLine: some View {
        HStack(spacing: 4) {
            if message.isDeleted {
                Label(L("удалено"), systemImage: "trash")
                    .foregroundStyle(.red)
            } else if !hasInlineMeta, message.isEdited || message.hasEditHistory {
                Text(L("изменено"))
            }
            if marksLocalEdits, message.localText != nil {
                Label(L("изменено локально"), systemImage: "pencil.and.outline")
                    .foregroundStyle(.orange)
                    .help(L("Текст изменён только на этом Mac. На сервере и у собеседника он прежний."))
            }
            if message.isPinned {
                Image(systemName: "pin.fill")
            }
            if message.isOutgoing, !hasInlineMeta || message.isPending || message.isFailed {
                delivery
            }
            if !hasInlineMeta {
                if message.viewCount > 0 {
                    Label(message.viewCount.formatted(.number.notation(.compactName)), systemImage: "eye")
                        .help(L("Просмотры"))
                }
                Text(message.date.timeStamp)
            }
            if showsIdentifiers {
                Text("· id \(String(message.id))")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var delivery: some View {
        if message.isPending {
            Label(L("Отправка"), systemImage: "clock")
        } else if message.isFailed {
            Label(L("Не отправлено"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if !message.isDeleted {
            Text(isRead ? L("Прочитано") : L("Доставлено"))
        }
    }

    @ViewBuilder
    private var menu: some View {
        // Grouped like the system's menus: talk, the text itself, the file, the author, your own tools, delete.
        if message.isSent, !message.isDeleted {
            Button(L("Ответить"), systemImage: "arrowshape.turn.up.left") { model.beginReply(to: message) }
            Menu(L("Реакция"), systemImage: "face.smiling") {
                ForEach(AppModel.quickReactions, id: \.self) { emoji in
                    Button(emoji) { Task { await model.toggleReaction(emoji, on: message) } }
                }
            }
            Button(row.album.count > 1 ? L("Переслать альбом…") : L("Переслать…"), systemImage: "arrowshape.turn.up.right") {
                model.prepareForwarding([message])
            }
            Button(L("В Избранное"), systemImage: "bookmark") { Task { await model.saveToSavedMessages(message) } }
            Button(L("Выбрать"), systemImage: "checkmark.circle") { model.beginSelection(with: message) }
            Divider()
        }
        if model.canEdit(message) {
            Button(L("Изменить"), systemImage: "pencil") { Task { await model.beginEdit(message) } }
        }
        Button(L("Скопировать текст"), systemImage: "doc.on.doc") { copyText() }
        if !message.isDeleted, model.canTranslate(message) {
            if model.translation(of: message) != nil {
                Button(L("Скрыть перевод"), systemImage: "globe") { model.hideTranslation(of: message) }
            } else {
                Button(L("Перевести"), systemImage: "globe") { Task { await model.translate(message) } }
            }
        }
        if message.isSent, !message.isDeleted {
            Button(message.isPinned ? L("Открепить") : L("Закрепить"), systemImage: message.isPinned ? "pin.slash" : "pin") {
                Task { await model.togglePin(message) }
            }
        }
        if message.isFailed {
            Button(L("Отправить ещё раз"), systemImage: "arrow.clockwise") { Task { await model.resend(message) } }
        }
        if message.isSent, !message.isDeleted, chat.kind == .group || chat.kind == .channel {
            Button(L("Скопировать ссылку на сообщение"), systemImage: "link") { Task { await model.copyLink(to: message) } }
        }
        if message.attachment != nil, !message.isDeleted {
            Divider()
            if message.media?.kind == .photo {
                Button(L("Скопировать фото"), systemImage: "photo.on.rectangle") { Task { await model.copyPhoto(of: message) } }
            }
            Button(L("Открыть вложение"), systemImage: "arrow.up.forward.app") { Task { await model.openAttachment(of: message) } }
            Button(L("Сохранить вложение…"), systemImage: "square.and.arrow.down") { saveAttachment() }
        }
        Divider()
        if !message.senderKey.isEmpty {
            Button(message.isOutgoing ? L("Мой профиль") : L("Профиль отправителя"), systemImage: "person.crop.circle") {
                Task { await model.showProfile(ofSender: message) }
            }
        }
        if message.hasEditHistory {
            Button(L("История изменений…"), systemImage: "clock.arrow.circlepath") { model.showEditHistory(of: message) }
        }
        if !message.isService, message.sticker == nil {
            Button(L("Изменить локально…"), systemImage: "square.and.pencil") {
                if let text = Dialogs.editLocally(message.localText ?? MessageArchive.text(of: message)) {
                    model.setLocalText(text, of: message)
                }
            }
            if message.localText != nil {
                Button(L("Вернуть оригинал"), systemImage: "arrow.uturn.backward") { model.setLocalText(nil, of: message) }
            }
        }
        if securityTools {
            Menu(L("Безопасность"), systemImage: "lock.shield") {
                Button(L("Индикаторы (IOC)…"), systemImage: "list.bullet.rectangle") { model.showIndicators(in: [message]) }
                if message.attachment != nil || message.media != nil, !message.isDeleted {
                    Button(L("SHA-256 файла…"), systemImage: "number") { Task { await model.showHash(of: message) } }
                }
                Button(L("Скопировать обезвреженным"), systemImage: "link.badge.plus") {
                    copy(SecurityTools.defang(MessageArchive.text(of: message)))
                }
            }
        }
        if !message.isDeleted, message.isSent, !message.isScheduled {
            Menu(L("Напомнить"), systemImage: "bell") {
                Button(L("Через час")) { Task { await model.remind(about: message, at: Date().addingTimeInterval(3600)) } }
                Button(L("Сегодня в 20:00")) { Task { await model.remind(about: message, at: Self.next(hour: 20)) } }
                Button(L("Завтра в 9:00")) { Task { await model.remind(about: message, at: Self.next(hour: 9)) } }
            }
        }
        if chat.kind == .channel, !message.isOutgoing, hidesAds, !message.isDeleted {
            Button(L("Скрыть как рекламу"), systemImage: "eye.slash") {
                let learned = AdFilter.learn(from: message)
                isRevealed = false
                model.showToast(learned > 0 ? L("Запомнил: похожие посты будут скрыты") : L("В посте нет ссылок и упоминаний, по которым его можно узнать"))
            }
        }
        if showsCode, !message.isDeleted {
            Button(L("Код сообщения…"), systemImage: "curlybraces") { Task { await model.inspect(message) } }
        }
        if showsIdentifiers {
            Button(L("Скопировать ID сообщения"), systemImage: "number.square") { copy(String(message.id)) }
        }
        Divider()
        if message.isDeleted {
            Button(L("Убрать из сохранённых"), systemImage: "trash", role: .destructive) {
                Task { await model.delete(message, forEveryone: false) }
            }
        } else {
            Button(row.album.count > 1 ? L("Удалить альбом…") : L("Удалить…"), systemImage: "trash", role: .destructive) { deleteMessage() }
        }
    }

    private var isRead: Bool {
        chat.lastReadOutboxId > 0 && message.id <= chat.lastReadOutboxId
    }

    /// The two bubbles of Messages: the accent colour for yours, lit from above the way Messages lights its
    /// own; a quiet grey for theirs, or white where the ground is grey.
    private var bubbleColor: AnyShapeStyle {
        if message.isOutgoing {
            return AnyShapeStyle(LinearGradient(
                colors: [Color.brand.mix(with: .white, by: 0.16), Color.brand.mix(with: .black, by: 0.04)],
                startPoint: .top, endPoint: .bottom))
        }
        if colorScheme == .dark { return AnyShapeStyle(Color(white: 0.23)) }
        // The glass and the indigo wash are grounds with a tone of their own, and a grey bubble sinks into
        // them; there theirs are white. Only the flat white ground keeps the grey.
        return AnyShapeStyle(chatBackground == ChatBackground.plain.rawValue ? Color(white: 0.915) : Color.white)
    }

    private var senderName: String {
        model.name(for: message)
    }

    /// The author's name, the name a hidden author chose, or nil when the origin chat is out of reach.
    private var forwardName: String? {
        if let name = model.senderNames[message.forwardSenderKey], !name.isEmpty { return name }
        return message.forwardSenderName.isEmpty ? nil : message.forwardSenderName
    }

    private func foreignName(_ reply: ForeignReply) -> String {
        if let name = model.senderNames[reply.senderKey], !name.isEmpty { return name }
        return reply.senderName.isEmpty ? L("Из другого чата") : reply.senderName
    }

    private var seed: Int64 {
        Self.seed(of: message, in: chat)
    }

    static func seed(of message: Message, in chat: RowChat) -> Int64 {
        if message.isOutgoing { return chat.id }
        return Int64(message.senderKey.unicodeScalars.reduce(7) { $0 + Int($1.value) })
    }

    private func copyText() {
        copy(MessageArchive.text(of: message))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveAttachment() {
        guard let attachment = message.attachment,
              let destination = Dialogs.saveLocation(suggestedName: attachment.name) else { return }
        Task { await model.saveAttachment(of: message, to: destination) }
    }

    private func deleteMessage() {
        Task {
            guard let options = await model.deletionOptions(for: message),
                  let forEveryone = Dialogs.confirmDeletion(options) else { return }
            await model.delete(message, forEveryone: forEveryone)
        }
    }
}

/// What a part of a bubble does to its width.
private enum BubblePart {
    /// Text: as wide as it needs, wrapping at the column's width.
    case text
    /// The reply quote or a link card: stretches to the bubble's width but does not widen it (much).
    case fill
    /// A photo, video or album grid: the bubble is exactly as wide, and a caption wraps under it.
    case media
}

private struct BubblePartKey: LayoutValueKey {
    static let defaultValue = BubblePart.text
}

/// A bubble's column: text and media decide the width, up to a comfortable reading measure; quotes and
/// cards follow it. A plain VStack would let a quote with a spacer stretch the bubble across the window.
private struct BubbleStack: Layout {
    var spacing: CGFloat = 4
    /// Lines longer than this are hard to read; the official apps stop about here too.
    var maxWidth: CGFloat = 520
    /// How far a quote alone may widen a short message.
    var fillerWidth: CGFloat = 260

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = columnWidth(proposal, subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let width = subview[BubblePartKey.self] == .text ? min(size.width, bounds.width) : bounds.width
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: width, height: size.height))
            y += size.height + spacing
        }
    }

    private func columnWidth(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let limit = min(proposal.width ?? maxWidth, maxWidth)
        // A picture has its own size; words around it follow it instead of stretching the bubble past it.
        let media = subviews.filter { $0[BubblePartKey.self] == .media }.map { $0.sizeThatFits(.unspecified).width }
        if let widest = media.max(), widest > 0 { return min(widest, limit) }
        var width: CGFloat = 0
        for subview in subviews {
            if subview[BubblePartKey.self] == .fill {
                width = max(width, min(subview.sizeThatFits(.unspecified).width, fillerWidth, limit))
            } else {
                width = max(width, min(subview.sizeThatFits(ProposedViewSize(width: limit, height: nil)).width, limit))
            }
        }
        return width
    }
}

/// The quoted message at the top of a reply; a click scrolls to it.
private struct ReplyQuote: View {
    let name: String
    let text: String
    let tint: Color
    let textStyle: AnyShapeStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(textStyle)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.trailing, 8)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Перейти к сообщению"))
    }
}

/// The card under a message with a link, as in the official clients; a click opens the page.
private struct LinkPreviewCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.bubbleAccent) private var accent
    let preview: LinkPreview

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.siteName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                if !preview.title.isEmpty {
                    Text(preview.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                }
                if !preview.description.isEmpty {
                    Text(preview.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if let photo = preview.photo {
                Poster(media: photo, size: CGSize(width: 54, height: 54), fileId: photo.fileId, previewFileId: photo.previewFileId)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { openURL(preview.url) }
        .help(preview.url.absoluteString)
    }
}

/// The translation of a message, under its own text. Told apart from the original by the language line.
private struct TranslationCard: View {
    @Environment(\.bubbleAccent) private var accent
    let translation: AppModel.Translation
    let fontSize: Double
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.subheadline)
                Text(AppModel.languageName(translation.languageCode))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button(action: hide) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(L("Скрыть перевод"))
            }
            .foregroundStyle(accent)
            Text(formattedText(translation.text, translation.entities))
                .font(.system(size: fontSize))
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}
