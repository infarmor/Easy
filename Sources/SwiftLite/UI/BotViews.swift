import SwiftUI

/// Buttons under a bot's message, one row per line, sharing the width of the bubble.
struct InlineKeyboard: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let rows: [[BotButton]]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    ForEach(rows[index]) { button in
                        BotButtonView(button: button, isPending: model.pendingButton == "\(message.id):\(button.id)") {
                            Task { await model.press(button, in: message) }
                        }
                    }
                }
            }
        }
        .disabled(model.isSelectingMessages)
    }
}

/// One key: glass like the bubbles, with a small corner mark for links and apps.
struct BotButtonView: View {
    let button: BotButton
    var isPending = false
    var height: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isPending {
                    ProgressView().controlSize(.small)
                } else {
                    Text(button.text)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                }
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(foreground)
            .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: tint, interactive: true)
            .overlay(alignment: .topTrailing) {
                if let symbol = button.symbol, !isPending {
                    Image(systemName: symbol)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(button.action == .disabled)
        .help(help)
    }

    /// Colored buttons (Primary, Danger, Success) are tinted glass; ordinary ones clear glass.
    private var tint: Color? {
        switch button.style {
        case .primary: Color.brand
        case .danger: Color.red
        case .success: Color.green
        case .plain: nil
        }
    }

    private var foreground: AnyShapeStyle {
        button.style == .plain ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white)
    }

    private var help: String {
        switch button.action {
        case .url(let url), .loginUrl(let url, _): url
        case .webApp, .keyboardWebApp: "Открыть мини-приложение"
        case .copy: "Скопировать"
        case .unsupported: "Работает только в официальном приложении"
        default: ""
        }
    }
}

/// Dims a little while held, like the system buttons.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.smooth(duration: 0.1), value: configuration.isPressed)
    }
}

/// The keyboard a bot put in place of the composer.
struct ReplyKeyboardPanel: View {
    @Environment(AppModel.self) private var model
    let markup: ReplyMarkup

    var body: some View {
        ScrollView {
            VStack(spacing: 5) {
                ForEach(markup.rows.indices, id: \.self) { index in
                    HStack(spacing: 5) {
                        ForEach(markup.rows[index]) { button in
                            BotButtonView(button: button, height: 34) {
                                Task { await model.press(keyboardButton: button) }
                            }
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// "Меню" in a bot chat: its mini app, or the list of its commands.
struct BotMenuButton: View {
    @Environment(AppModel.self) private var model
    let menu: BotMenu
    @State private var showsCommands = false

    var body: some View {
        Button {
            if menu.appURL.isEmpty {
                showsCommands = true
            } else {
                Task { await model.openBotMenuApp() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: menu.appURL.isEmpty ? "line.3.horizontal" : "square.grid.2x2.fill")
                    .font(.subheadline.weight(.semibold))
                Text(menu.appURL.isEmpty ? "Меню" : (menu.appTitle.isEmpty ? "Открыть" : menu.appTitle))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.brand, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(menu.appURL.isEmpty ? "Команды бота" : "Открыть мини-приложение")
        .contextMenu {
            if !menu.commands.isEmpty, !menu.appURL.isEmpty {
                Button("Команды бота…") { showsCommands = true }
            }
        }
        .popover(isPresented: $showsCommands, arrowEdge: .top) {
            BotCommandList(commands: menu.commands) { command in
                showsCommands = false
                guard let chatId = model.selection else { return }
                Task { await model.sendText("/\(command.command)", to: chatId) }
            }
        }
    }
}

private struct BotCommandList: View {
    let commands: [BotMenu.Command]
    let pick: (BotMenu.Command) -> Void

    var body: some View {
        if commands.isEmpty {
            Text("У бота нет команд")
                .foregroundStyle(.secondary)
                .padding(20)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(commands) { command in
                        Button { pick(command) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("/" + command.command)
                                    .font(.body.weight(.semibold))
                                if !command.description.isEmpty {
                                    Text(command.description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .frame(width: 300)
            .frame(maxHeight: 360)
        }
    }
}

/// A short answer from a bot, floating over the conversation for a moment.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 420)
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
    }
}
