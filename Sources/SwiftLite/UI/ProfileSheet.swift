import AppKit
import SwiftUI

/// A person, bot, group or channel: who it is, how to reach it, and the ids a power user looks for.
struct ProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.showMessageCode) private var showsCode = false
    @State private var copied: String?
    @State private var isBlocked = false
    /// nil for a chat this account does not have, which has no notifications to silence.
    @State private var isMuted: Bool?
    let info: ProfileInfo

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    details
                    if !info.about.isEmpty {
                        card {
                            Text(info.about)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                    if !info.facts.isEmpty {
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
                                if blocking, !Dialogs.confirm("Заблокировать \(info.title)?", message: "Он не сможет писать вам и звонить.", action: "Заблокировать") { return }
                                Task { if await model.setBlocked(blocking, userId: info.userId) { isBlocked = blocking } }
                            } label: {
                                Text(isBlocked ? "Разблокировать" : "Заблокировать")
                                    .foregroundStyle(isBlocked ? Color.accentColor : Color.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressDimStyle())
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if showsCode, let raw = info.raw {
                    Button("Код…") {
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
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 560)
        .onAppear {
            isBlocked = info.isBlocked
            isMuted = model.isChatMuted(info.chatId)
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Avatar(title: info.title, seed: info.seed, photo: info.photo, diameter: 88)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            Text(info.title.isEmpty ? "Без имени" : info.title)
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if !info.subtitle.isEmpty {
                Text(info.subtitle)
                    .font(.callout)
                    .foregroundStyle(info.subtitle == "в сети" ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            if isBlocked {
                Label("Заблокирован", systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
            }
            actions
                .padding(.top, 6)
            if !info.badges.isEmpty {
                HStack(spacing: 5) {
                    ForEach(info.badges, id: \.self) { badge in
                        Text(badge)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(badge.hasPrefix("⚠︎") ? .white : .primary)
                            .background(badge.hasPrefix("⚠︎") ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                        in: Capsule())
                    }
                }
            }
        }
    }

    /// The round buttons under the name, as on a contact's card in Messages: write, search, silence.
    private var actions: some View {
        HStack(spacing: 14) {
            action(info.isSelf ? "Избранное" : info.userId != 0 ? "Написать" : "Открыть", "message.fill") {
                Task { await model.openChat(fromProfile: info.chatId) }
            }
            action("Поиск", "magnifyingglass") {
                Task { await model.openChat(fromProfile: info.chatId, searching: true) }
            }
            if info.userId != 0, !info.isSelf, info.subtitle != "бот" {
                action("Секретный", "lock.fill") {
                    Task { await model.startSecretChat(with: info.userId) }
                }
            }
            if !info.isSelf, let muted = isMuted {
                action(muted ? "Со звуком" : "Без звука", muted ? "bell.fill" : "bell.slash.fill") {
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityLabel(title)
    }

    private var details: some View {
        card {
            copyRow(info.userId != 0 ? "Telegram ID" : "ID чата", String(info.telegramId))
            if info.innerId != 0 {
                Divider().padding(.leading, 12)
                copyRow("Внутренний ID", String(info.innerId))
            }
            Divider().padding(.leading, 12)
            if let dc = info.dataCenter {
                copyRow("Дата-центр", "DC\(dc) · \(TD.dataCenterLocation(dc))", copying: "DC\(dc)")
            } else {
                row("Дата-центр", "неизвестен — нет фото профиля")
            }
            ForEach(info.usernames, id: \.self) { username in
                Divider().padding(.leading, 12)
                copyRow("Имя пользователя", "@" + username)
            }
            if !info.phone.isEmpty {
                Divider().padding(.leading, 12)
                copyRow("Телефон", info.phone)
            }
        }
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
            .help("Скопировать")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
