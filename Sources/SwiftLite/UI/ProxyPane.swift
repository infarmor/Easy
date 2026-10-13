import SwiftUI

/// The proxy servers and which one every account connects through. In the settings, and on the sign-in
/// screen: where Telegram is blocked, signing in is the first thing that needs it.
struct ProxyPane: View {
    @Environment(AppModel.self) private var model
    @State private var store = ProxyStore.shared
    @State private var editing: ProxyServer?
    /// The last check of each server: a time in ms, "no answer", or "…" while it runs.
    @State private var pings: [UUID: String] = [:]

    var body: some View {
        Form {
            Section {
                Picker(L("Подключаться"), selection: Binding(get: { store.enabledId }, set: { store.enable($0) })) {
                    Text(L("Напрямую")).tag(UUID?.none)
                    ForEach(store.servers) { server in
                        Text("\(server.title) · \(server.kind.title)").tag(UUID?.some(server.id))
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text(L("Подключение"))
            } footer: {
                Text(L("Через выбранный прокси подключаются все аккаунты. Ссылки tg://proxy и t.me/socks, открытые в Easy, добавляют сервер сюда."))
            }
            Section {
                ForEach(store.servers) { server in
                    row(server)
                        .transition(.opacity)
                }
                Button(L("Добавить прокси…")) { editing = ProxyServer() }
            } header: {
                Text(L("Серверы"))
            }
        }
        .formStyle(.grouped)
        .motion(Motion.standard, value: store.servers)
        .motion(Motion.standard, value: store.enabledId)
        .sheet(item: $editing) { server in
            ProxyEditor(server: server, isNew: !store.servers.contains { $0.id == server.id }) { saved, isNew in
                if isNew {
                    // A server is added to be used: it goes on at once, as one opened from a link does.
                    store.enable(store.add(saved))
                } else {
                    store.update(saved)
                }
                pings[saved.id] = nil
            }
        }
    }

    private func row(_ server: ProxyServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.title)
                Text(server.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let ping = pings[server.id] {
                Text(ping)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
            Button(L("Проверить")) { check(server) }
                .disabled(pings[server.id] == "…")
            Button(L("Изменить")) { editing = server }
            Button(role: .destructive) {
                store.remove(server.id)
                pings[server.id] = nil
            } label: {
                Image(systemName: "trash")
            }
            .help(L("Удалить"))
        }
        // The answer of a check replaces its "…" in place, without a jump of the buttons beside it.
        .motion(Motion.standard, value: pings[server.id])
    }

    private func check(_ server: ProxyServer) {
        pings[server.id] = "…"
        Task {
            let seconds = await model.ping(server)
            pings[server.id] = seconds.map { L("\(Int(($0 * 1000).rounded())) мс") } ?? L("нет ответа")
        }
    }
}

private struct ProxyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProxyServer
    let isNew: Bool
    let onSave: (ProxyServer, Bool) -> Void

    init(server: ProxyServer, isNew: Bool, onSave: @escaping (ProxyServer, Bool) -> Void) {
        _draft = State(initialValue: server)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker(L("Тип"), selection: $draft.kind) {
                    ForEach(ProxyServer.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(L("Сервер"), text: $draft.server, prompt: Text("proxy.example.com"))
                TextField(L("Порт"), value: $draft.port, format: .number.grouping(.never))
                if draft.kind == .mtproto {
                    TextField(L("Секрет"), text: $draft.secret)
                        .font(.body.monospaced())
                } else {
                    TextField(L("Имя пользователя"), text: $draft.username, prompt: Text(L("необязательно")))
                    SecureField(L("Пароль"), text: $draft.password, prompt: Text(L("необязательно")))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? L("Добавить") : L("Сохранить")) {
                    onSave(draft, isNew)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isComplete)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
    }
}
