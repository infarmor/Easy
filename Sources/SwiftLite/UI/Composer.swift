import AppKit
import SwiftUI

struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountHub.self) private var hub: AccountHub?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recorder = VoiceRecorder()
    @State private var showsStickers = false
    @State private var showsSchedule = false
    @State private var showsScheduled = false
    @State private var showsLocation = false
    /// The caret or the selected words of the field, which the formatting commands wrap.
    @State private var selection: TextSelection?
    @AppStorage(Preferences.sendWithCommandReturn) private var sendsWithCommandReturn = false

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            if let context = model.composerContext {
                ComposerContextBar(context: context)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    // Rises out of the field it belongs to.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !model.suggestions.isEmpty, !needsStart {
                SuggestionList(suggestions: model.suggestions)
            }
            if needsStart {
                Button {
                    Task { await model.startBot() }
                } label: {
                    Text(L("Запустить"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(.white)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            } else {
                inputRow
            }
            if let keyboard = model.replyKeyboard, model.isReplyKeyboardShown, !needsStart {
                ReplyKeyboardPanel(markup: keyboard)
            }
        }
        .animation(.smooth(duration: 0.18), value: model.isReplyKeyboardShown)
        .animation(.smooth(duration: 0.18), value: model.replyKeyboard)
        .animation(.smooth(duration: 0.15), value: model.suggestions)
        .animation(.smooth(duration: 0.2), value: model.composerContext)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .onChange(of: model.composerContext) { _, context in
            if context != nil { focused = true }
        }
        // A sent or cleared message leaves no text for the old selection to point into.
        .onChange(of: model.draft.isEmpty) { _, isEmpty in
            if isEmpty { selection = nil }
        }
        .onChange(of: selection) { _, _ in
            let has = selectedRange.map { !$0.isEmpty } ?? false
            if model.composerHasSelection != has { model.composerHasSelection = has }
        }
        .onChange(of: model.formatRequest) { _, request in
            guard let request else { return }
            model.formatRequest = nil
            apply(request.format)
        }
        // Asked for before this chat's composer existed, or while it was already on screen.
        .onAppear { takeFocusIfAsked() }
        .onChange(of: model.wantsComposerFocus) { _, _ in takeFocusIfAsked() }
        // Leaving the chat mid-recording drops the recording instead of leaving the microphone on.
        .onDisappear { if recorder.isRecording { recorder.cancel() } }
        // ⌘V with a picture or files copied opens the send sheet; text pastes into the field as usual.
        .background {
            PasteInterceptor(handle: {
                guard AppModel.pasteboardHoldsAttachment() else { return false }
                Task { await model.sendPasteboard() }
                return true
            }, type: { characters in
                // A letter typed while the keyboard is in the chat list or nowhere starts the message: the
                // field takes the letter and the keyboard, with the caret after it.
                guard !needsStart, !model.isSelectingMessages, !recorder.isRecording, model.viewerMessage == nil else { return false }
                model.draft += characters
                focused = true
                let end = TextSelection(insertionPoint: model.draft.endIndex)
                selection = end
                // Again once the field has the keyboard: taking it selects the whole text, and the next
                // letter would replace what was just typed.
                DispatchQueue.main.async { selection = TextSelection(insertionPoint: model.draft.endIndex) }
                return true
            })
        }
    }

    private var openChat: Chat? {
        model.selectedChat
    }

    /// The selected stretch of the draft; empty for a bare caret, nil when the field has never had the keyboard.
    private var selectedRange: Range<String.Index>? {
        guard case .selection(let range)? = selection?.indices,
              range.upperBound <= model.draft.endIndex else { return nil }
        return range
    }

    /// Wraps the selection in a format's marks; without a selection the marks go in at the caret, or at the
    /// end, with the caret left between them.
    private func apply(_ format: TextFormat) {
        let range = selectedRange ?? model.draft.endIndex..<model.draft.endIndex
        let wrapped = format.wrap(model.draft, range)
        model.draft = wrapped.text
        focused = true
        // After the text has reached the field: a selection set first is measured against the old text.
        // And only if it is still that text — positions in a string mean nothing in another one.
        DispatchQueue.main.async {
            if model.draft == wrapped.text { selection = TextSelection(range: wrapped.selection) }
        }
    }

    /// The system's own picker (⌃⌘Space), which types into whatever field has the keyboard.
    private func showEmojiPicker() {
        focused = true
        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
    }

    private func takeFocusIfAsked() {
        guard model.wantsComposerFocus else { return }
        model.wantsComposerFocus = false
        focused = true
    }

    /// A bot you have never written to, or one opened through a start link, waits for "Запустить".
    private var needsStart: Bool {
        guard let chat = openChat, chat.isBot else { return false }
        return model.pendingBotStart != nil || (model.messages.isEmpty && !model.loadingHistory && chat.lastMessageId == 0)
    }

    private var placeholder: String {
        switch openChat?.secretState {
        case .pending: return L("Отправится, когда собеседник появится в сети")
        case .closed: return L("Секретный чат закрыт")
        default: break
        }
        let hint = model.replyKeyboard?.placeholder ?? ""
        if !hint.isEmpty { return hint }
        // With several accounts the field says which of them the message goes from.
        if let hub, hub.accounts.count > 1, !model.accountName.isEmpty { return L("Сообщение от \(model.accountName)") }
        return L("Сообщение")
    }

    private var inputRow: some View {
        @Bindable var model = model
        return HStack(alignment: .bottom, spacing: 10) {
            if recorder.isRecording {
                recordingBar
            } else {
                if let menu = model.botMenu, !menu.appURL.isEmpty || !menu.commands.isEmpty {
                    BotMenuButton(menu: menu)
                }
                Menu {
                    Button(L("Фото и файлы…"), systemImage: "doc.on.doc") { attachFiles() }
                    Button(L("Вставить из буфера"), systemImage: "doc.on.clipboard") { Task { await model.sendPasteboard() } }
                    Divider()
                    Button(L("Стикеры"), systemImage: "face.smiling") { showsStickers = true }
                    Button(L("Эмодзи и символы"), systemImage: "character.cursor.ibeam") { showEmojiPicker() }
                    if model.composerContext?.kind != .edit {
                        Button(L("Голосовое сообщение"), systemImage: "mic") { startRecording() }
                        Divider()
                        Button(L("Кости"), systemImage: "die.face.5") { Task { await model.sendDice("🎲") } }
                        Button(L("Геолокация…"), systemImage: "mappin") { showsLocation = true }
                    }
                } label: {
                    GlassCircleLabel(diameter: 36) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .popover(isPresented: $showsLocation, arrowEdge: .top) {
                    LocationPanel { showsLocation = false }
                }
                .help(L("Файлы, фото, стикеры, голосовые, кости и геолокация. Файлы можно и просто перетащить в чат"))
                .accessibilityLabel(L("Прикрепить"))

                HStack(alignment: .bottom, spacing: 6) {
                    TextField(placeholder, text: $model.draft, selection: $selection, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...8)
                        .focused($focused)
                        .padding(.vertical, 6)
                        .onSubmit {
                            Task { await model.send() }
                        }
                        // The other way round for people who write at length: Return is a new line and
                        // ⌘Return sends. ⌘Return sends in either mode.
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.command) {
                                Task { await model.send() }
                                return .handled
                            }
                            guard sendsWithCommandReturn, press.modifiers.isDisjoint(with: [.option, .shift, .control]) else { return .ignored }
                            let at = selectedRange ?? model.draft.endIndex..<model.draft.endIndex
                            let caret = model.draft.distance(from: model.draft.startIndex, to: at.lowerBound) + 1
                            model.draft.replaceSubrange(at, with: "\n")
                            let written = model.draft
                            DispatchQueue.main.async {
                                guard model.draft == written else { return }
                                selection = TextSelection(insertionPoint: written.index(written.startIndex, offsetBy: caret))
                            }
                            return .handled
                        }
                        .onChange(of: model.draft) { _, _ in
                            model.noteTyping()
                        }
                        // Tab takes the first person or command offered above the field.
                        .onKeyPress(.tab) {
                            guard let first = model.suggestions.first else { return .ignored }
                            Task { await model.accept(first) }
                            return .handled
                        }
                        // ↑ in an empty field edits your last message.
                        .onKeyPress(.upArrow) {
                            guard model.draft.isEmpty, model.composerContext == nil else { return .ignored }
                            Task { await model.editLastMessage() }
                            return .handled
                        }
                        .help((sendsWithCommandReturn ? L("⌘Return — отправить, Return — новая строка") : L("Return — отправить, Option-Return — новая строка"))
                            + L(", ↑ — изменить последнее. ")
                            + L("Выделите слова и нажмите ⌘B, ⌘I или ⌘K, либо пишите разметкой: **жирный**, __курсив__, `код`"))

                    if !model.scheduledMessages.isEmpty {
                        fieldButton("clock", help: L("Отложенные сообщения: \(model.scheduledMessages.count)")) { showsScheduled = true }
                            .popover(isPresented: $showsScheduled, arrowEdge: .top) { ScheduledList() }
                    }
                    if model.replyKeyboard != nil, !canSend {
                        fieldButton(model.isReplyKeyboardShown ? "keyboard.chevron.compact.down" : "keyboard",
                                    help: model.isReplyKeyboardShown ? L("Скрыть клавиатуру бота") : L("Показать клавиатуру бота")) {
                            model.isReplyKeyboardShown.toggle()
                        }
                    }
                    fieldButton("face.smiling", help: L("Стикеры")) { showsStickers.toggle() }
                        .popover(isPresented: $showsStickers, arrowEdge: .top) {
                            StickerPanel { showsStickers = false }
                        }

                    if canSend {
                        Button {
                            Task { await model.send() }
                        } label: {
                            Image(systemName: model.composerContext?.kind == .edit ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 26))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.brand)
                        }
                        .buttonStyle(PressDimStyle())
                        .padding(.bottom, 2)
                        .transition(.scale.combined(with: .opacity))
                        .help(L("Отправить. Правый клик — без звука или по расписанию"))
                        .accessibilityLabel(model.composerContext?.kind == .edit ? L("Сохранить изменения") : L("Отправить"))
                        .contextMenu {
                            if model.composerContext?.kind != .edit {
                                Button(L("Отправить без звука")) { Task { await model.send(silently: true) } }
                                Button(L("Отправить позже…")) { showsSchedule = true }
                                if openChat?.kind == .personal, openChat?.isBot == false {
                                    Button(L("Отправить, когда будет в сети")) { Task { await model.send(whenOnline: true) } }
                                }
                            }
                        }
                        .popover(isPresented: $showsSchedule, arrowEdge: .top) {
                            ScheduleSendPicker { date in
                                showsSchedule = false
                                Task { await model.send(at: date) }
                            }
                        }
                    } else if model.composerContext?.kind != .edit {
                        Button {
                            startRecording()
                        } label: {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 28)
                        }
                        .buttonStyle(PressDimStyle())
                        .help(L("Записать голосовое сообщение"))
                        .accessibilityLabel(L("Записать голосовое сообщение"))
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, canSend ? 4 : 10)
                .padding(.vertical, 2)
                .frame(minHeight: 36)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .animation(.smooth(duration: 0.15), value: canSend)
            }
        }
    }

    /// While a voice message records: the time, a pulsing dot, cancel and send.
    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button {
                recorder.cancel()
            } label: {
                GlassCircleLabel(diameter: 36) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(L("Отменить запись"))
            .accessibilityLabel(L("Отменить запись"))
            HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(recorder.level) * 0.6)
                .animation(reduceMotion ? nil : .smooth(duration: 0.08), value: recorder.level)
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                .font(.body.weight(.medium).monospacedDigit())
            Text(L("Запись…"))
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task {
                    guard let recording = await recorder.finish() else {
                        model.showToast(L("Слишком короткое сообщение"))
                        return
                    }
                    await model.sendVoiceNote(at: recording.file, duration: recording.duration, waveform: recording.waveform)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.brand)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .help(L("Отправить голосовое (Return)"))
            .accessibilityLabel(L("Отправить голосовое сообщение"))
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(minHeight: 34)
            .glassSurface(in: Capsule())
        }
    }

    private func startRecording() {
        Task {
            if !(await recorder.start()) {
                model.report(L("Нет доступа к микрофону: разрешите его в Системных настройках → Конфиденциальность → Микрофон."))
            }
        }
    }

    private func fieldButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 28)
        }
        .buttonStyle(PressDimStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private var canSend: Bool {
        // Editing to an empty caption is a valid send, so the button stays up while a message is being edited.
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.composerContext?.kind == .edit
    }

    private func attachFiles() {
        let urls = Dialogs.chooseFiles()
        guard !urls.isEmpty else { return }
        model.offerFiles(urls)
    }
}

/// People to mention or commands to send for the word being typed; a click or Tab takes one.
private struct SuggestionList: View {
    @Environment(AppModel.self) private var model
    let suggestions: [ComposerSuggestion]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    Task { await model.accept(suggestion) }
                } label: {
                    HStack(spacing: 9) {
                        if case .mention = suggestion.kind {
                            Avatar(title: suggestion.title, seed: suggestion.seed, photo: suggestion.photo, diameter: 24)
                        }
                        Text(suggestion.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(suggestion.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if suggestion.id == suggestions.first?.id {
                            Text("Tab")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressDimStyle())
            }
        }
        .padding(.vertical, 5)
        .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity)
    }
}

private struct ComposerContextBar: View {
    @Environment(AppModel.self) private var model
    let context: ComposerContext

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: context.kind == .edit ? "pencil" : "arrowshape.turn.up.left")
                .foregroundStyle(Color.brandInk)
            VStack(alignment: .leading, spacing: 1) {
                Text(context.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandInk)
                Text(context.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                model.cancelComposerContext()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Отменить (Esc)"))
        }
    }
}

/// Catches ⌘V in the conversation's window before the text field does. Only the main window: sheets (the
/// caption field of the send sheet) paste as usual. The key is matched by its position, so ⌘V works in the
/// Russian layout too, where the key reads «м».
private struct PasteInterceptor: NSViewRepresentable {
    let handle: () -> Bool
    /// Text typed while no field has the keyboard; true when the composer took it.
    let type: (String) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.type = type
        context.coordinator.install(on: view, handle: handle)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handle = handle
        context.coordinator.type = type
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var handle: () -> Bool = { false }
        var type: (String) -> Bool = { _ in false }
        private var monitor: Any?
        private weak var view: NSView?
        /// kVK_ANSI_V.
        private static let keyV: UInt16 = 9

        func install(on view: NSView, handle: @escaping () -> Bool) {
            self.view = view
            self.handle = handle
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Plain values out of the event first: the event itself is not passed into the main-actor code.
                let isCommandV = event.keyCode == Self.keyV
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                let windowNumber = event.windowNumber
                // Plain typing: no ⌘, ⌃ or ⌥, and something that prints — not an arrow, Tab, Return or Esc.
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let typed = event.characters ?? ""
                let prints = flags.isDisjoint(with: [.command, .control, .option, .function]) && !typed.isEmpty
                    && typed.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
                if prints {
                    let taken = MainActor.assumeIsolated { () -> Bool in
                        guard let self, let window = self.view?.window, window.windowNumber == windowNumber,
                              window.attachedSheet == nil, window.isKeyWindow,
                              // A field that already has the keyboard keeps it: the search, a selected text.
                              !(window.firstResponder is NSText) else { return false }
                        return self.type(typed)
                    }
                    return taken ? nil : event
                }
                guard isCommandV else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.view?.window, window.windowNumber == windowNumber,
                          window.attachedSheet == nil else { return false }
                    return self.handle()
                }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
