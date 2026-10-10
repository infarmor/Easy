import AppKit
import SwiftUI

/// The admin side of a group or a channel: its name and description, its members and their rights,
/// and the links people use to join. Opened from the chat's own menu; only what this account may
/// change is offered.
struct ChatManageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chat: Chat

    @State private var query = ""
    @State private var title = ""
    @State private var about = ""
    @State private var saved = false
    @State private var error: String?
    @State private var loadedQuery: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if model.chatAccess.canChangeInfo { infoCard }
                    membersCard
                    if model.chatAccess.isChannel, model.chatAccess.canManage { statisticsCard }
                    if model.chatAccess.canInvite { linksCard }
                }
                .padding(16)
            }
            Divider()
            HStack(spacing: 10) {
                if let error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 540, height: 640)
        .background(.regularMaterial)
        .task(id: chat.id) {
            title = chat.title
            await model.loadAccess(of: chat)
            about = model.chatAccess.about
            loadedQuery = query
            if model.chatAccess.canGetMembers { await model.loadMembers(of: chat) }
            if model.chatAccess.canInvite { await model.loadInviteLinks(of: chat) }
        }
        // The server searches the list; typing a name is not filtering what is already on screen. The first
        // load belongs to the task above, so this one waits for the text to actually change.
        .task(id: query) {
            guard model.chatAccess.canGetMembers, loadedQuery != query else { return }
            loadedQuery = query
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await model.loadMembers(of: chat, query: query)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Avatar(title: chat.title, seed: chat.id, photo: chat.photo, diameter: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        let access = model.chatAccess
        let who = access.isCreator ? "вы владелец" : access.isAdmin ? "вы администратор" : "вы участник"
        let count = access.memberCount != 0 ? access.memberCount : chat.memberCount
        let kind = access.isChannel ? "канал" : "группа"
        return count > 0 ? "\(kind) · \(count) участников · \(who)" : "\(kind) · \(who)"
    }

    // MARK: - the chat itself

    private var infoCard: some View {
        Section("О чате") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Название", text: $title)
                    .textFieldStyle(.roundedBorder)
                TextField("Описание", text: $about, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                HStack {
                    Button(saved ? "Сохранено" : "Сохранить") { save() }
                        .disabled(title.isEmpty || title == chat.title && about == model.chatAccess.about)
                    if saved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
        }
    }

    private func save() {
        error = nil
        Task {
            if let message = await model.setChatInfo(chat, title: title, description: about) {
                error = message
            } else {
                saved = true
                try? await Task.sleep(for: .seconds(1.5))
                saved = false
            }
        }
    }

    // MARK: - members

    private var membersCard: some View {
        Section {
            TextField("Поиск по имени", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            if model.isLoadingMembers {
                HStack { ProgressView().controlSize(.small); Text("Участники…") }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if model.members.isEmpty {
                Text(model.chatAccess.canGetMembers
                     ? "Список участников пуст или скрыт."
                     : "Список участников этому аккаунту не показан.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(model.members) { member in
                MemberRow(member: member, chat: chat) {
                    Task { await model.loadMembers(of: chat, query: query) }
                }
                Divider()
            }
            if model.membersTotal > model.members.count {
                Text("Показано \(model.members.count) из \(model.membersTotal)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Участники")
        }
    }

    // MARK: - invite links

    private var linksCard: some View {
        Section("Ссылки-приглашения") {
            if !model.chatAccess.primaryLink.isEmpty {
                LinkRow(title: "Основная ссылка", url: model.chatAccess.primaryLink)
                Button("Сменить и скопировать") {
                    Task { await model.replacePrimaryInviteLink(in: chat) }
                }
                .controlSize(.small)
            } else {
                Text("У чата пока нет публичной ссылки.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.inviteLinks) { link in
                LinkRow(title: link.name.isEmpty ? "Ссылка" : link.name, url: link.url,
                        note: "\(link.memberCount) зашли"
                            + (link.memberLimit > 0 ? " из \(link.memberLimit)" : "")
                            + (link.expirationDate.map { " · до \($0.shortDate)" } ?? ""))
                Button("Отозвать") {
                    Task { await model.revokeInviteLink(link, in: chat) }
                }
                .controlSize(.small)
            }
            NewLinkRow(chat: chat)
        }
    }

    // MARK: - statistics

    private var statisticsCard: some View {
        Section("Статистика канала") {
            if let stats = model.statistics {
                statRow("Период", "\(stats.from.shortDate) — \(stats.to.shortDate)")
                statRow("Подписчиков", count(stats.members) + (stats.membersGrowth == 0 ? "" : "  (\(percent(stats.membersGrowth)))"))
                statRow("Просмотров на пост", count(stats.meanViews))
                statRow("Пересылок на пост", one(stats.meanShares))
                statRow("Реакций на пост", one(stats.meanReactions))
            } else {
                Text("Telegram отдаёт статистику только владельцу и администраторам канала.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button(model.statistics == nil ? "Показать статистику" : "Обновить") {
                Task { await model.loadStatistics(of: chat) }
            }
            .controlSize(.small)
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.body.monospacedDigit())
        }
        .padding(.vertical, 3)
    }

    /// Graphs TDLib returns for the same numbers are a chart specification, not figures, so only the
    /// headline values are shown.
    private func count(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }

    /// Shares and reactions per post are averages; rounding them away hides the whole number.
    private func one(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
    private func percent(_ value: Double) -> String {
        value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + "%"
    }
}

/// One member: who they are, what they may do, and the menu that changes it. Also the row of the members
/// column, which is why it is not private to the sheet.
struct MemberRow: View {
    @Environment(AppModel.self) private var model
    let member: ChatMemberInfo
    let chat: Chat
    let changed: () -> Void

    @State private var showsAdminRights = false
    @State private var showsRestrictions = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(title: member.name, seed: member.userId, photo: member.photo, diameter: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name.isEmpty ? "Без имени" : member.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(rank)
                    .font(.subheadline)
                    .foregroundStyle(colour)
                    .lineLimit(1)
                    .help(rank)
            }
            Spacer(minLength: 8)
            if canAct {
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Что можно сделать с этим участником")
            }
        }
        .padding(.vertical, 5)
        .sheet(isPresented: $showsAdminRights) {
            RightsSheet(chat: chat, member: member, isAdmin: true).environment(model)
        }
        .sheet(isPresented: $showsRestrictions) {
            RightsSheet(chat: chat, member: member, isAdmin: false).environment(model)
        }
    }

    private var rank: String {
        var text = member.rank.label
        // The member list already carries the rights, so an administrator shows what they actually hold.
        if member.rank == .admin {
            let summary = Rights.summary(member.rights, Rights.admin)
            if !summary.isEmpty { text += " · " + summary }
        }
        if member.rank == .restricted {
            let allowed = Rights.summary(member.permissions, Rights.permissions)
            if !allowed.isEmpty { text += " · можно: " + allowed }
        }
        if member.untilDate > 0 {
            text += " до " + Date(timeIntervalSince1970: TimeInterval(member.untilDate)).shortDate
        } else if member.rank == .banned {
            text += " навсегда"
        }
        return text
    }

    private var colour: AnyShapeStyle {
        switch member.rank {
        case .owner: return AnyShapeStyle(Color.accentColor)
        case .admin: return AnyShapeStyle(Color.accentColor.opacity(0.8))
        case .restricted, .banned: return AnyShapeStyle(.red)
        default: return AnyShapeStyle(.secondary)
        }
    }

    private var access: ChatAccess { model.chatAccess }

    /// Changing someone's status and clearing their history are different rights: an admin you may not touch
    /// can still have their messages deleted, and hiding that would be a capability the account does have.
    private var canAct: Bool {
        // The owner and this account are not something the menu may touch, whatever rights are held.
        guard member.userId != 0, member.userId != model.myId, member.rank != .owner else { return false }
        return canChangeStatus || access.canDeleteMessages
    }

    private var canChangeStatus: Bool {
        guard member.userId != 0, member.userId != model.myId, member.rank != .owner else { return false }
        // TDLib itself says which administrators this account may touch; the other ranks follow plain rights.
        if member.rank == .admin { return member.canBeEdited && (access.canPromote || access.canRestrict) }
        return access.canRestrict || (access.canPromote && member.rank == .member)
    }

    @ViewBuilder
    private var actions: some View {
        if access.canPromote, member.rank == .admin || member.rank == .member {
            Button(member.rank == .admin ? "Права администратора…" : "Назначить администратором…") { showsAdminRights = true }
        }
        if access.canRestrict, member.rank != .banned, member.rank != .restricted {
            Button("Заглушить с выбором прав…") { showsRestrictions = true }
        }
        if member.rank == .admin, member.canBeEdited, access.canPromote {
            Button("Снять с администраторов") { perform { await model.setMember(member, in: chat, rights: nil) } }
        } else if member.rank == .member, access.canPromote {
            Button("Сделать администратором") {
                perform { await model.setMember(member, in: chat, rights: Rights.editorDefaults) }
            }
        }
        if access.canDeleteMessages {
            Divider()
            Button("Удалить все сообщения участника", role: .destructive) {
                perform { await model.deleteMessages(by: member, in: chat) }
            }
        }
        if access.canRestrict {
            Divider()
            if member.rank == .restricted {
                Button("Снять ограничения") { perform { await model.removeMember(member, in: chat) } }
            } else {
                Menu("Заглушить") {
                    ForEach(MemberPeriod.all) { period in
                        Button(period.label) { perform { await model.restrictMember(member, in: chat, minutes: period.minutes) } }
                    }
                }
            }
            Divider()
            if member.rank == .banned {
                Button("Разблокировать") { perform { await model.removeMember(member, in: chat) } }
            } else {
                Button("Удалить из чата", role: .destructive) { perform { await model.removeMember(member, in: chat) } }
            }
            Menu("Забанить") {
                ForEach(MemberPeriod.all) { period in
                    Button(period.label) { perform { await model.banMember(member, in: chat, minutes: period.minutes, revokeMessages: false) } }
                }
                Button("Навсегда, с его сообщениями", role: .destructive) {
                    perform { await model.banMember(member, in: chat, minutes: 0, revokeMessages: true) }
                }
            }
        }
    }

    /// The list is re-read both before and after: TDLib answers at its own pace, and a refused action must
    /// not leave the row showing a rank the server never accepted.
    private func perform(_ action: @escaping () async -> Bool) {
        Task {
            guard await action() else { return }
            model.showToast("Готово")
            changed()
        }
    }
}

/// A link with its address and a copy button.
private struct LinkRow: View {
    let title: String
    let url: String
    var note = ""
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(note.isEmpty ? url : note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(copied ? "Скопировано" : "Копировать") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

/// A link that expires or stops after a number of people, made here and now.
private struct NewLinkRow: View {
    @Environment(AppModel.self) private var model
    let chat: Chat

    @State private var name = ""
    @State private var limit = ""
    @State private var days = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Название", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
            TextField("Гостей", text: $limit)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .help("Сколько человек может зайти по ссылке; пусто — сколько угодно")
            TextField("Дней", text: $days)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .help("Через сколько дней ссылка перестанет работать; пусто — никогда")
            Button("Создать") { create() }
                .controlSize(.small)
        }
    }

    private func create() {
        let guests = Int(limit.trimmingCharacters(in: .whitespaces)) ?? 0
        let life = Int(days.trimmingCharacters(in: .whitespaces)) ?? 0
        Task {
            if await model.createInviteLink(in: chat, name: name, memberLimit: guests, days: life) {
                name = ""
                limit = ""
                days = ""
            }
        }
    }
}

/// Rights, one check box each, the way Telegram's own admin editor shows them. For an administrator this is
/// what they may do; for a muted member it is what the mute leaves them allowed.
struct RightsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chat: Chat
    let member: ChatMemberInfo
    /// true edits admin rights, false chooses what a restriction permits.
    let isAdmin: Bool

    @State private var values: [String: Bool] = [:]
    @State private var minutes = 0
    @State private var busy = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name.isEmpty ? "Без имени" : member.name)
                    .font(.title3.weight(.semibold))
                Text(isAdmin ? "Права администратора" : "Что разрешено, пока участник заглушен")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(flags) { flag in
                        HStack(spacing: 10) {
                            Text(flag.label)
                                .font(.body)
                            Spacer(minLength: 12)
                            // macOS puts a switch label to the right of the switch; here the name of the right
                            // is the label, so the switch itself goes unlabeled at the end of the row.
                            Toggle("", isOn: Binding(
                                get: { values[flag.key] == true },
                                set: { values[flag.key] = $0 }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
            if !isAdmin {
                Divider()
                durations
            }
            Divider()
            HStack {
                Button("Отмена") { dismiss() }
                Spacer()
                if isAdmin {
                    Button("Снять с администраторов", role: .destructive) { save(rights: nil) }
                        .disabled(member.rank != .admin || busy)
                }
                Button(isAdmin ? "Сохранить" : "Заглушить") { save(rights: values) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
            .padding(12)
        }
        .frame(width: 430, height: isAdmin ? 560 : 620)
        .background(.regularMaterial)
        // The row already carries what the list said; the answer for this one member wins when it arrives,
        // so the boxes are never blank while the request is on its way.
        .task {
            if isAdmin, member.rank != .admin {
                // A first promotion starts from the set Telegram offers, not from an empty one.
                values = Rights.editorDefaults
            } else {
                values = isAdmin ? member.rights : member.permissions
            }
            let fresh = await model.loadMember(member, in: chat)
            if let fresh {
                values = isAdmin ? fresh.rights : fresh.permissions
            }
            busy = false
        }
    }

    private var flags: [RightsFlag] { isAdmin ? Rights.admin : Rights.permissions }

    private var durations: some View {
        HStack(spacing: 8) {
            ForEach(MemberPeriod.all) { period in
                let chosen = minutes == period.minutes
                Button(period.label) { minutes = period.minutes }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(chosen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thinMaterial), in: Capsule())
                    .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// `rights` nil means the person goes back to being an ordinary member.
    private func save(rights: [String: Bool]?) {
        busy = true
        Task {
            let done = isAdmin
                ? await model.setMember(member, in: chat, rights: rights)
                : await model.restrictMember(member, in: chat, minutes: minutes, permissions: rights ?? [:])
            if done { model.showToast(isAdmin ? "Права обновлены" : "Участник заглушен") }
            await model.loadMembers(of: chat)
            busy = false
            dismiss()
        }
    }
}

/// The durations Telegram offers for a ban or a mute.
struct MemberPeriod: Identifiable {
    var label: String
    var minutes: Int
    var id: Int { minutes }

    static let all = [
        MemberPeriod(label: "На час", minutes: 60),
        MemberPeriod(label: "На день", minutes: 60 * 24),
        MemberPeriod(label: "На неделю", minutes: 60 * 24 * 7),
        MemberPeriod(label: "Навсегда", minutes: 0),
    ]
}
