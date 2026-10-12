import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // In place of the interface, not over it: a cover would leave the chats under it reachable by
            // keyboard and readable by anything that walks the window's contents.
            if model.isLocked {
                LockView()
            } else {
                switch model.phase {
                case .working:
                    WorkspaceView()
                case .failed(let message):
                    ClosedSessionView(message: message)
                default:
                    LoginView()
                }
            }
        }
        // The sidebar takes 270 before a word of conversation is drawn; the members column adds another 220.
        // Below that the split view starts overlapping its own columns, so the window stops.
        .frame(minWidth: model.showsMembersColumn ? 1040 : 740, minHeight: 500)
        // A mini app opens in its own window, like in Telegram Desktop.
        .onChange(of: model.webApp?.id) { _, id in
            if id != nil { openWindow(id: WebAppWindow.id) }
        }
    }
}

private struct ClosedSessionView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Text(L("Сессия завершена"))
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("Перезапустить Easy")) { model.restartSession() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
