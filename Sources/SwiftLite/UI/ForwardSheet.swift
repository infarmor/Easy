import SwiftUI

/// Chat picker behind "Переслать…".
struct ForwardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    let messages: [Message]
    var endsSelection = false

    var body: some View {
        VStack(spacing: 0) {
            TextField(messages.count > 1 ? L("Кому переслать \(TD.count(messages.count, L("сообщение"), L("сообщения"), L("сообщений")))") : L("Кому переслать"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List(model.forwardTargets(matching: query)) { chat in
                Button {
                    dismiss()
                    Task { await model.forward(messages, to: chat, endsSelection: endsSelection) }
                } label: {
                    HStack(spacing: 10) {
                        Avatar(title: chat.title, seed: chat.id, photo: chat.photo, diameter: 28)
                        Text(chat.title.isEmpty ? L("Без названия") : chat.title)
                            .font(.body)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 380, height: 460)
    }
}
