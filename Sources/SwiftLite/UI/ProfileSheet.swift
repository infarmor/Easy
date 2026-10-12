import AppKit
import SwiftUI

/// A person, bot, group or channel: who it is, how to reach it, and the ids a power user looks for.
struct ProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Preferences.showMessageCode) private var showsCode = false
    @State private var copied: String?
    @State private var isBlocked = false
    /// nil for a chat this account does not have, which has no notifications to silence.
    @State private var isMuted: Bool?
    @State private var showsGifts = false
    @State private var showsStories = false
    /// The photo settles into place when the sheet comes up.
    @State private var hasAppeared = false
    let info: ProfileInfo

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if !info.about.isEmpty {
                        heading(info.userId != 0 ? (info.subtitle == L("бот") ? L("О боте") : L("О себе")) : L("Описание"))
                        card {
                            Text(Self.linked(info.about))
                                .font(.body)
                                .tint(Color.brandInk)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                    heading(L("Сведения"))
                    details
                    if !info.facts.isEmpty {
                        heading(L("Подробности"))
                        card {
                            ForEach(info.facts.indices, id: \.self) { index in
                                row(info.facts[index].0, info.facts[index].1)
                                if index < info.facts.count - 1 { Divider().padding(.leading, 12) }
                            }
                        }
                    }
                    SharedMedia(chatId: info.chatId)
                    if info.userId != 0, !info.isSelf {
                        // Last and alone, where Contacts and Messages keep the one thing you cannot take back
                        // by accident.
                        card {
                            Button {
                                let blocking = !isBlocked
                                if blocking, !Dialogs.confirm(L("Заблокировать \(info.title)?"), message: L("Он не сможет писать вам и звонить."), action: L("Заблокировать")) { return }
                                Task { if await model.setBlocked(blocking, userId: info.userId) { isBlocked = blocking } }
                            } label: {
                                Text(isBlocked ? L("Разблокировать") : L("Заблокировать"))
                                    .foregroundStyle(isBlocked ? Color.brandInk : Color.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressDimStyle())
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            Divider()
            HStack {
                if showsCode, let raw = info.raw {
                    Button(L("Код…")) {
                        let json = (try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        let code = InspectedCode(title: info.title, json: json, node: raw)
                        dismiss()
                        // A second sheet can only come up once this one has finished going away.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            model.inspectedCode = code
                        }
                    }
                }
                Spacer()
                Button(L("Готово")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brand)
            }
            .padding(12)
        }
        .frame(width: 440, height: 640)
        .onAppear {
            withAnimation(.spring(duration: 0.45, bounce: 0.3).delay(0.08)) { hasAppeared = true }
            isBlocked = info.isBlocked
            isMuted = model.isChatMuted(info.chatId)
        }
        .background(.regularMaterial)
        // A link in someone's bio is as much a stranger's link as one in a message: the same checks, and
        // t.me stays in the app.
        .environment(\.openURL, OpenURLAction { url in
            Task { await model.openMessageLink(url) }
            return .handled
        })
        .sheet(isPresented: $showsStories) {
            StoryViewer(chatId: info.chatId, name: info.title).environment(model)
        }
        .sheet(isPresented: $showsGifts) {
            GiftSheet(userId: info.userId, name: info.title).environment(model)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            // A band of the profile's own colour behind the photo, as a contact's poster stands behind theirs.
            Avatar(title: info.title, seed: info.seed, photo: info.photo, diameter: 104)
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 3))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .scaleEffect(hasAppeared ? 1 : 0.86)
                .opacity(hasAppeared ? 1 : 0)
                .padding(.top, 34)
                .frame(maxWidth: .infinity)
                .background(alignment: .top) { banner }
            HStack(spacing: 5) {
                Text(info.title.isEmpty ? L("Без имени") : info.title)
                    .font(.system(size: 21, weight: .bold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                NameBadgeView(key: info.userId != 0 ? "u\(info.userId)" : "c\(info.telegramId)", size: 20)
            }
            if !info.subtitle.isEmpty {
                Text(info.subtitle)
                    .font(.callout)
                    .foregroundStyle(info.subtitle == L("в сети") ? AnyShapeStyle(Color.brandInk) : AnyShapeStyle(.secondary))
            }
            if isBlocked {
                Label(L("Заблокирован"), systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
            }
            if !info.badges.isEmpty {
                HStack(spacing: 5) {
                    ForEach(info.badges, id: \.self) { badge in
                        let isWarning = badge.hasPrefix("⚠︎"), isPremium = badge == "Premium"
                        Text(badge)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(isWarning ? AnyShapeStyle(.white) : isPremium ? AnyShapeStyle(Color.brandInk) : AnyShapeStyle(.primary))
                            .background(isWarning ? AnyShapeStyle(Color.red.opacity(0.85))
                                            : isPremium ? AnyShapeStyle(Color.brand.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                        in: Capsule())
                    }
                }
            }
            actions
                .padding(.top, 8)
        }
    }

    /// Behind the photo: the photo again, enlarged and blurred into a wash of its own colours, as a contact's
    /// poster stands behind theirs. Without a photo, the colour of the monogram.
    private var banner: some View {
        Group {
            if info.photo != nil {
                Avatar(title: info.title, seed: info.seed, photo: info.photo, diameter: 520)
                    .blur(radius: 46)
                    .saturation(1.25)
            } else {
                Palette.gradient(for: info.seed)
            }
        }
        .frame(width: 440, height: 96)
        .clipped()
        .overlay(LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.3)], startPoint: .top, endPoint: .bottom))
        .padding(.horizontal, -20)
    }

    /// Addresses in a bio open in the browser, as they do in a message.
    private static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }

    /// The tiles under the name, as on a contact's card: write, search, silence.
    private var actions: some View {
        HStack(spacing: 8) {
            action(info.isSelf ? L("Избранное") : info.userId != 0 ? L("Написать") : L("Открыть"), "message.fill") {
                Task { await model.openChat(fromProfile: info.chatId) }
            }
            action(L("Поиск"), "magnifyingglass") {
                Task { await model.openChat(fromProfile: info.chatId, searching: true) }
            }
            if info.isSelf {
                // Name, bio and username are edited in the settings' account pane.
                action(L("Изменить"), "pencil") {
                    dismiss()
                    openSettings()
                }
            }
            if info.userId != 0, !info.isSelf, info.subtitle != L("бот") {
                action(L("Секретный"), "lock.fill") {
                    Task { await model.startSecretChat(with: info.userId) }
                }
            }
            if info.userId != 0, !info.isSelf, info.subtitle != L("бот") {
                action(L("Подарок"), "gift.fill") { showsGifts = true }
            }
            if !info.isSelf, info.subtitle != L("бот") {
                action(L("Истории"), "circle.dashed") { showsStories = true }
            }
            if !info.isSelf, let muted = isMuted {
                action(muted ? L("Со звуком") : L("Без звука"), muted ? "bell.fill" : "bell.slash.fill") {
                    isMuted = !muted
                    Task { await model.toggleMuted(chatId: info.chatId) }
                }
            }
        }
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.brandInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityLabel(title)
    }

    private var details: some View {
        card {
            copyRow(info.userId != 0 ? "Telegram ID" : L("ID чата"), String(info.telegramId))
            if info.innerId != 0 {
                Divider().padding(.leading, 12)
                copyRow(L("Внутренний ID"), String(info.innerId))
            }
            Divider().padding(.leading, 12)
            if let dc = info.dataCenter {
                copyRow(L("Дата-центр"), "DC\(dc) · \(TD.dataCenterLocation(dc))", copying: "DC\(dc)")
            } else {
                row(L("Дата-центр"), L("неизвестен — нет фото профиля"))
            }
            ForEach(info.usernames, id: \.self) { username in
                Divider().padding(.leading, 12)
                copyRow(L("Имя пользователя"), "@" + username)
            }
            if !info.phone.isEmpty {
                Divider().padding(.leading, 12)
                copyRow(L("Телефон"), info.phone)
            }
        }
    }

    /// The quiet caption over a card, as over a group of rows in System Settings.
    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.bottom, -10)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// A value with a copy button that confirms itself for a moment.
    private func copyRow(_ title: String, _ value: String, copying: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, design: title.contains("ID") ? .monospaced : .default))
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copying ?? value, forType: .string)
                copied = title
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    if copied == title { copied = nil }
                }
            } label: {
                Image(systemName: copied == title ? "checkmark" : "doc.on.doc")
                    .font(.subheadline)
                    .foregroundStyle(copied == title ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(L("Скопировать"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
