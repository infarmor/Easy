import AppKit
import SwiftUI

enum Palette {
    private static let tints: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .mint]

    static func tint(for seed: Int64) -> Color {
        let index = Int(abs(seed) % Int64(tints.count))
        return tints[index]
    }

    /// The same colour as a monogram's ground in Contacts and Messages: lit from above, deeper below.
    static func gradient(for seed: Int64) -> LinearGradient {
        let tint = tint(for: seed)
        return LinearGradient(colors: [tint.mix(with: .white, by: 0.32), tint.mix(with: .black, by: 0.06)],
                              startPoint: .top, endPoint: .bottom)
    }
}

func initials(of title: String) -> String {
    // Avatars redraw with the scroll, and the same handful of names comes back over and over.
    if let known = initialsCache.object(forKey: title as NSString) { return known as String }
    let letters = title.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init)
    let result = letters.isEmpty ? "?" : letters.joined()
    initialsCache.setObject(result as NSString, forKey: title as NSString)
    return result
}

private nonisolated(unsafe) let initialsCache: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>()
    cache.countLimit = 5_000
    return cache
}()

/// The interface is Russian, so dates are too, whatever region the Mac is set to.
private let russian = Locale(identifier: "ru_RU")

/// Chat list time labels by minute and day; NSCache is safe to reach from any thread.
private nonisolated(unsafe) let chatListStampCache: NSCache<NSNumber, NSString> = {
    let cache = NSCache<NSNumber, NSString>()
    cache.countLimit = 20_000
    return cache
}()

/// Keys here are plain minutes since the epoch, so the two caches never share a number.
private nonisolated(unsafe) let minuteStampCache: NSCache<NSNumber, NSString> = {
    let cache = NSCache<NSNumber, NSString>()
    cache.countLimit = 20_000
    return cache
}()

/// Which day it is, worked out once a day: asking the calendar for the start of today costs as much as
/// formatting a label.
private enum Today {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = 0
    nonisolated(unsafe) private static var endsAt = Date.distantPast

    static func ordinal() -> Int {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if now >= endsAt {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: now)
            current = Int(start.timeIntervalSince1970 / 86_400)
            endsAt = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(3600)
        }
        return current
    }
}

extension Date {
    /// "12 мар 2026". Where a ban or a link expires is a day, not a minute, so no cache is worth it.
    var shortDate: String {
        formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "ru_RU")))
    }

    /// "13:22". Rows ask for this on every redraw and the answer only changes once a minute, same trick as
    /// `chatListStamp` below.
    var timeStamp: String {
        let key = NSNumber(value: Int64(timeIntervalSince1970 / 60))
        if let known = minuteStampCache.object(forKey: key) { return known as String }
        let stamp = formatted(.dateTime.hour().minute().locale(russian))
        minuteStampCache.setObject(stamp as NSString, forKey: key)
        return stamp
    }

    /// The chat list asks for this on every redraw of every row. The answer depends only on the minute and on
    /// what day it is today, so it is kept: working it out takes several calendar calls.
    var chatListStamp: String {
        let key = NSNumber(value: Int64(timeIntervalSince1970 / 60) &* 100_000 &+ Int64(Today.ordinal()))
        if let known = chatListStampCache.object(forKey: key) { return known as String }
        let stamp = makeChatListStamp()
        chatListStampCache.setObject(stamp as NSString, forKey: key)
        return stamp
    }

    private func makeChatListStamp() -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(.dateTime.hour().minute().locale(russian)) }
        if calendar.isDateInYesterday(self) { return "вчера" }
        // Within the last week the weekday reads faster than a date: "пн", "ср".
        if let days = calendar.dateComponents([.day], from: self, to: Date()).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated).locale(russian))
        }
        if calendar.isDate(self, equalTo: Date(), toGranularity: .year) {
            return formatted(.dateTime.day().month(.abbreviated).locale(russian))
        }
        return formatted(.dateTime.day().month(.twoDigits).year(.twoDigits).locale(russian))
    }

    var daySeparator: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Сегодня" }
        if calendar.isDateInYesterday(self) { return "Вчера" }
        if calendar.isDate(self, equalTo: Date(), toGranularity: .year) {
            return formatted(.dateTime.day().month(.wide).locale(russian))
        }
        return formatted(.dateTime.day().month(.wide).year().locale(russian))
    }
}

/// Initials on a tinted circle, covered by the profile photo once it is available.
struct Avatar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @AppStorage(Preferences.showAvatars) private var showsPhotos = true

    let title: String
    let seed: Int64
    var photo: ProfilePhoto? = nil
    var diameter: CGFloat = 38

    @State private var loaded: NSImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.gradient(for: seed))
            Text(initials(of: title))
                .font(.system(size: diameter * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if showsPhotos, let picture = loaded ?? placeholder {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .accessibilityHidden(true)
        .task(id: showsPhotos ? photo?.fileId : nil) {
            loaded = nil
            guard showsPhotos, let photo else { return }
            // Already decoded: the placeholder shows it, so no lookup and no second redraw while scrolling.
            let known = photo.localPath.isEmpty ? model.downloadedPath(of: photo.fileId) : photo.localPath
            if let known, MediaCache.cachedImage(atPath: known, pixels: pixels) != nil { return }
            guard let path = await model.localFile(id: photo.fileId, knownPath: photo.localPath, priority: 4) else { return }
            loaded = await MediaCache.image(atPath: path, pixels: pixels)
        }
    }

    private var pixels: Int { Int((diameter * displayScale).rounded(.up)) }

    /// A photo decoded earlier shows at once; otherwise TDLib's blurred preview fills in while downloading.
    private var placeholder: NSImage? {
        guard let photo else { return nil }
        let path = photo.localPath.isEmpty ? model.downloadedPath(of: photo.fileId) : photo.localPath
        if let path, let decoded = MediaCache.cachedImage(atPath: path, pixels: pixels) { return decoded }
        return photo.minithumbnail.flatMap { MediaCache.minithumbnail($0, id: photo.fileId) }
    }
}

/// What follows a name: an emoji status, a collectible gift worn as one, or the Premium star. Nothing at all
/// for a name that has none, so it can sit after every name without a check at the call site.
struct NameBadgeView: View {
    @Environment(AppModel.self) private var model
    /// "u<id>" or "c<id>", as `AppModel.nameBadges` is keyed.
    let key: String
    var size: CGFloat = 15
    /// On the selected row of the sidebar the star is drawn in white, like the rest of that row.
    var isOnAccent = false

    @State private var round = 0

    var body: some View {
        if let badge = model.nameBadges[key] {
            Group {
                if badge.customEmojiId == 0 {
                    Image(systemName: "star.fill")
                        .font(.system(size: size * 0.72, weight: .semibold))
                        .foregroundStyle(isOnAccent ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                        .frame(width: size, height: size)
                } else if round >= 0, let picture = CustomEmoji.image(badge.customEmojiId, side: size) {
                    Image(nsImage: picture)
                        // A template emoji takes the accent colour, as the official clients tint it.
                        .foregroundStyle(isOnAccent ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                } else {
                    // Its place is kept while the picture loads, so the name does not jump when it arrives.
                    Color.clear.frame(width: size, height: size)
                }
            }
            .help(badge.isGift ? "Коллекционный подарок: \(badge.giftTitle)" : badge.customEmojiId == 0 ? "Telegram Premium" : "Эмодзи-статус")
            .accessibilityLabel(badge.isGift ? "коллекционный подарок" : "Premium")
            .task(id: badge.customEmojiId) {
                guard badge.customEmojiId != 0 else { return }
                if await CustomEmoji.load([badge.customEmojiId], with: model) { round += 1 }
            }
        }
    }
}

/// Green dot on the avatar of someone who is online right now.
struct OnlineDot: View {
    var diameter: CGFloat = 11

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            .accessibilityLabel("в сети")
    }
}

struct UnreadBadge: View {
    let count: Int
    /// Muted chats get a grey badge, so the blue ones stand out.
    var isMuted = false
    /// On the selected row the ground is the accent colour itself, and the badge turns inside out.
    var isOnAccent = false

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.subheadline.weight(.semibold))
            // The digits roll to the new count, as the badges of Mail and Messages do.
            .contentTransition(.numericText(value: Double(count)))
            .animation(.snappy(duration: 0.25), value: count)
            .foregroundStyle(isOnAccent ? Color.accentColor : Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(isOnAccent ? Color.white.opacity(isMuted ? 0.7 : 1) : isMuted ? Color.secondary : Color.accentColor,
                        in: Capsule())
    }
}

/// The small tracked caption above a group of rows. The chat list and the members column want the same voice,
/// and two copies of it would drift.
struct SectionHeading: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.top, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

struct ErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return IfNotEmpty(model.errorText) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(model.errorText)
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    model.errorText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}

private struct IfNotEmpty<Content: View>: View {
    let value: String
    let content: Content

    init(_ value: String, @ViewBuilder content: () -> Content) {
        self.value = value
        self.content = content()
    }

    var body: some View {
        if value.isEmpty { EmptyView() } else { content }
    }
}

private final class FormattedBox {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

/// Built attributed strings: a row that redraws (a reaction, a read receipt) reuses the formatting.
private nonisolated(unsafe) let formattedCache: NSCache<NSString, FormattedBox> = {
    let cache = NSCache<NSString, FormattedBox>()
    cache.countLimit = 3000
    return cache
}()

/// Message text with Telegram's formatting: bold, italic, code, spoilers and clickable links.
func formattedText(_ text: String, _ entities: [TextEntity]) -> AttributedString {
    // Most messages have no formatting at all and need no attributes.
    guard !entities.isEmpty else { return AttributedString(text) }
    var hasher = Hasher()
    hasher.combine(text)
    hasher.combine(entities)
    let key = String(hasher.finalize()) as NSString
    if let cached = formattedCache.object(forKey: key) { return cached.value }
    let result = buildFormattedText(text, entities)
    formattedCache.setObject(FormattedBox(result), forKey: key)
    return result
}

private func buildFormattedText(_ text: String, _ entities: [TextEntity]) -> AttributedString {
    var result = AttributedString(text)
    for entity in entities {
        // TDLib counts UTF-16 units, as NSString does.
        guard let range = Range(NSRange(location: entity.offset, length: entity.length), in: text),
              let lower = AttributedString.Index(range.lowerBound, within: result),
              let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
        let span = lower..<upper
        switch entity.style {
        case .bold:
            result[span].inlinePresentationIntent = (result[span].inlinePresentationIntent ?? []).union(.stronglyEmphasized)
        case .italic:
            result[span].inlinePresentationIntent = (result[span].inlinePresentationIntent ?? []).union(.emphasized)
        case .strikethrough:
            result[span].inlinePresentationIntent = (result[span].inlinePresentationIntent ?? []).union(.strikethrough)
        case .code:
            result[span].inlinePresentationIntent = (result[span].inlinePresentationIntent ?? []).union(.code)
        case .underline:
            result[span].underlineStyle = .single
        case .spoiler:
            result[span].backgroundColor = Color.secondary.opacity(0.35)
        case .link(let url):
            result[span].link = url
            result[span].underlineStyle = .single
        case .customEmoji:
            // Drawn by `CustomEmoji.text`, which replaces the stand-in character with the picture.
            break
        }
    }
    return result
}

/// Telegram's custom emoji, as pictures set into a line of text. They are decoded once and kept: the same
/// few come back in message after message.
@MainActor
enum CustomEmoji {
    private static let pictures = NSCache<NSNumber, NSImage>()
    /// The same pictures at the size of a font, which is how `Text` wants an inline image to arrive.
    private static let sized = NSCache<NSString, NSImage>()

    static func has(_ id: Int64) -> Bool { pictures.object(forKey: NSNumber(value: id)) != nil }

    static func store(_ image: NSImage, for id: Int64) { pictures.setObject(image, forKey: NSNumber(value: id)) }

    /// Emoji that are shapes to be coloured: drawn in the colour of the text around them.
    private static var templates: Set<Int64> = []

    /// Fetches and decodes the pictures that are not in hand yet. True when something new can now be drawn.
    static func load(_ ids: [Int64], with model: AppModel) async -> Bool {
        guard !ids.isEmpty else { return false }
        await model.loadCustomEmoji(ids)
        templates.formUnion(model.templateEmoji)
        var decoded = false
        for id in ids where !has(id) {
            guard let path = model.customEmoji[id], !path.isEmpty,
                  let image = await MediaCache.image(atPath: path, pixels: 64) else { continue }
            store(image, for: id)
            decoded = true
        }
        return decoded
    }

    static func ids(in entities: [TextEntity]) -> [Int64] {
        entities.compactMap { entity -> Int64? in
            if case .customEmoji(let id) = entity.style { return id }
            return nil
        }
    }

    static func image(_ id: Int64, side: CGFloat) -> NSImage? {
        let key = "\(id):\(Int(side))" as NSString
        if let known = sized.object(forKey: key) { return known }
        guard let picture = pictures.object(forKey: NSNumber(value: id)),
              let bitmap = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: side, height: side))
        image.isTemplate = templates.contains(id)
        sized.setObject(image, forKey: key)
        return image
    }

    /// The text with every custom emoji that is already decoded drawn in place of its stand-in; nil when
    /// none is, and the plain text will do.
    static func text(_ text: String, _ entities: [TextEntity], fontSize: Double) -> Text? {
        let side = (fontSize * 1.3).rounded()
        let whole = formattedText(text, entities)
        var pieces: [Text] = []
        var cursor = text.startIndex
        var drew = false
        let emoji = entities.filter { if case .customEmoji = $0.style { return true } else { return false } }
            .sorted { $0.offset < $1.offset }
        func plain(_ range: Range<String.Index>) {
            guard !range.isEmpty, let lower = AttributedString.Index(range.lowerBound, within: whole),
                  let upper = AttributedString.Index(range.upperBound, within: whole) else { return }
            pieces.append(Text(AttributedString(whole[lower..<upper])))
        }
        for entity in emoji {
            guard case .customEmoji(let id) = entity.style,
                  let range = Range(NSRange(location: entity.offset, length: entity.length), in: text),
                  range.lowerBound >= cursor, let picture = image(id, side: side) else { continue }
            plain(cursor..<range.lowerBound)
            pieces.append(Text(Image(nsImage: picture)).baselineOffset(-side * 0.18))
            cursor = range.upperBound
            drew = true
        }
        guard drew else { return nil }
        plain(cursor..<text.endIndex)
        return pieces.dropFirst().reduce(pieces[0]) { $0 + $1 }
    }
}

extension String {
    /// One to three emoji and nothing else: shown large and without a bubble, as the official clients do.
    var isBigEmoji: Bool {
        // Asked on every redraw of a text message. Three emoji, even family sequences, stay under 100 bytes;
        // the byte count is instant, while trimming and counting characters walk the whole text.
        guard utf8.count <= 100 else { return false }
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3, !trimmed.contains(" ") else { return false }
        return trimmed.allSatisfy { character in
            let scalars = character.unicodeScalars
            return scalars.contains { $0.properties.isEmojiPresentation }
                || (scalars.count > 1 && scalars.first?.properties.isEmoji == true)
        }
    }
}

/// The colour of accents inside a bubble. Your own bubbles are filled with the accent colour, as in Messages,
/// so a link bar, a play button or a poll's progress drawn in that same colour would vanish into them: there
/// they turn white.
private struct BubbleAccentKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    var bubbleAccent: Color {
        get { self[BubbleAccentKey.self] }
        set { self[BubbleAccentKey.self] = newValue }
    }
}

extension View {
    /// What sits in a bubble of yours reads in white on the accent colour: text, secondary text, links and
    /// the accents of cards. Other people's bubbles keep the window's own ink.
    @ViewBuilder
    func bubbleInk(isOutgoing: Bool) -> some View {
        if isOutgoing {
            // The system's secondary grey sinks into a saturated fill, so the second level is spelled out.
            foregroundStyle(.white, .white.opacity(0.78))
                .environment(\.colorScheme, .dark)
                .environment(\.bubbleAccent, .white)
                .tint(.white)
        } else {
            self
        }
    }
}

/// What lies behind the bubbles; chosen in the settings.
enum ChatBackground: String, CaseIterable, Identifiable {
    /// The window's glass: the desktop shows through, dimmed by the slider beside it.
    case glass
    /// The window's own flat background, as in Messages.
    case plain
    /// A wash of the accent colour over that background.
    case tint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: "Стекло"
        case .plain: "Ровный"
        case .tint: "Оттенок акцента"
        }
    }
}

/// The transcript's ground.
struct ChatWallpaper: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Preferences.chatBackground) private var choice = ChatBackground.glass.rawValue

    var body: some View {
        switch ChatBackground(rawValue: choice) ?? .glass {
        case .glass:
            WindowGlass()
        case .plain:
            Color(nsColor: .textBackgroundColor)
        case .tint:
            // Faint on purpose: two solid bubble colours sit on it, and a saturated ground would fight both.
            Color(nsColor: .textBackgroundColor)
                .overlay(Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08))
        }
    }
}

/// The macOS glass behind the conversation: the desktop shows through, blurred, as in the sidebar, with a dark
/// tint on top so the grey reads deeper than the flat window background.
struct WindowGlass: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Preferences.backgroundDim) private var dim = 0.26

    var body: some View {
        ZStack {
            BehindWindowBlur()
            // Light mode needs far less darkening to read as the same depth.
            Color.black.opacity(colorScheme == .dark ? dim : dim * 0.15)
        }
        .ignoresSafeArea()
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
