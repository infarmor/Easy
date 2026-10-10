import SwiftUI

/// The people of a group in a column of their own, like the member list at the right of Discord: grouped by
/// rank, searched through TDLib's own filter rather than locally, and every card carries the same admin menu
/// the management sheet has. Only supergroups can list their members, so the toolbar offers it for those.
struct MembersPanel: View {
    @Environment(AppModel.self) private var model
    let chat: Chat

    @State private var query = ""
    @State private var loadedQuery: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.chatAccess.canGetMembers {
                search
            }
            List {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.members) { member in
                            MemberCard(member: member, chat: chat, changed: reload)
                        }
                    } header: {
                        SectionHeading(title: group.title)
                    }
                }
                if model.members.isEmpty {
                    placeholder
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        // A fixed 300 here pushed the whole window past its right edge on a narrow screen: the close button
        // was cut off and the chat list's avatars were sliced. The column yields to the transcript instead.
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 300)
        .layoutPriority(-1)
        .background(.bar)
        .task(id: chat.id) {
            query = ""
            loadedQuery = nil
            await load()
        }
        // The management sheet writes into the same two slots this column reads. When it closes, this chat's
        // own roster is re-read: otherwise a sheet opened for another group leaves its members on screen here.
        .onChange(of: model.managedChat?.id) { _, closed in
            guard closed == nil else { return }
            Task { await load() }
        }
        // The server searches the roster; typing is not filtering the page already on screen.
        .task(id: query) {
            guard model.chatAccess.canGetMembers, loadedQuery != query else { return }
            loadedQuery = query
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await model.loadMembers(of: chat, query: query)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Участники")
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button {
                model.showsMembersPanel = false
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Скрыть список участников")
            // No Esc here: the conversation owns that key, and a second cancel-action button in the same
            // window makes the shortcut ambiguous. `AppModel.escape` closes this column last instead.
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var subtitle: String {
        let total = max(model.membersTotal, model.members.count)
        if !model.chatAccess.canGetMembers { return "участники скрыты" }
        if total == 0 { return "загружается…" }
        let online = chat.onlineMemberCount
        return online > 0
            ? "\(TD.count(total, "участник", "участника", "участников")) · \(online) в сети"
            : TD.count(total, "участник", "участника", "участников")
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Имя участника", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// Ranked the way Telegram orders its own member list, with the empty groups left out. One pass: the
    /// column redraws while TDLib pages 200 members in.
    private var groups: [(title: String, members: [ChatMemberInfo])] {
        var owners: [ChatMemberInfo] = [], members: [ChatMemberInfo] = [], limited: [ChatMemberInfo] = [], banned: [ChatMemberInfo] = []
        for member in model.members {
            switch member.rank {
            case .owner, .admin: owners.append(member)
            case .member: members.append(member)
            case .restricted: limited.append(member)
            case .banned: banned.append(member)
            }
        }
        let ranked: [(String, [ChatMemberInfo])] = [
            ("Владелец и администраторы", owners), ("Участники", members),
            ("Ограниченные", limited), ("Заблокированы", banned),
        ]
        return ranked.filter { !$0.1.isEmpty }
    }

    @ViewBuilder private var placeholder: some View {
        Text(model.isLoadingMembers ? "Загружаем…" : "Никого не нашлось")
            .font(.callout)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    /// Rights and roster come together: the member request is only worth making when the first one says the
    /// list is visible.
    private func load() async {
        await model.loadAccess(of: chat)
        if model.chatAccess.canGetMembers { await model.loadMembers(of: chat) }
    }

    private var reload: () -> Void {
        { Task { await model.loadMembers(of: chat) } }
    }
}

/// The roster row inside its own card. The row is the management sheet's own, so the two can never disagree
/// about what may be done to a member; the card only answers to the pointer, because a column of these is
/// scanned rather than selected.
private struct MemberCard: View {
    let member: ChatMemberInfo
    let chat: Chat
    let changed: () -> Void

    @State private var isHovered = false

    var body: some View {
        MemberRow(member: member, chat: chat, changed: changed)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.075 : 0.045))
            )
            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            .listRowSeparator(.hidden)
            .onHover { isHovered = $0 }
    }
}
