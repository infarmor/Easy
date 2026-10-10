import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isLocked {
            // Sessions, the account and the export live here; none of it is for whoever found the Mac open.
            LockView().frame(width: 420, height: 360)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Основные", systemImage: "gearshape") { GeneralSettings() }
            Tab("Уведомления", systemImage: "bell.badge") { NotificationSettings() }
            Tab("Конфиденциальность", systemImage: "hand.raised") { PrivacySettings() }
            Tab("Призрак", systemImage: "eye.slash") { GhostSettings() }
            Tab("Безопасность", systemImage: "lock.shield") { SecuritySettings() }
            Tab("Хранилище", systemImage: "internaldrive") { StorageSettings() }
            Tab("Аккаунт", systemImage: "person.crop.circle") { AccountSettings() }
            Tab("Для разработчиков", systemImage: "hammer") { DeveloperSettings() }
        }
        .frame(width: 640, height: 460)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.messageFontSize) private var messageFontSize = 14
    @AppStorage(Preferences.showAvatars) private var showsAvatars = true
    @AppStorage(Preferences.animateStickers) private var animatesStickers = true
    @AppStorage(Preferences.backgroundDim) private var backgroundDim = 0.26
    @AppStorage(Preferences.chatBackground) private var chatBackground = ChatBackground.glass.rawValue
    @AppStorage(Preferences.translateToLanguage) private var translateTo = "ru"

    var body: some View {
        Form {
            Section {
                Stepper(value: $messageFontSize, in: 11...20) {
                    LabeledContent("Размер текста сообщений", value: "\(messageFontSize) pt")
                }
                Picker("Переводить в", selection: $translateTo) {
                    ForEach(AppModel.translationLanguages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
            } header: {
                Text("Сообщения")
            } footer: {
                Text("Пункт «Перевести» в меню сообщения. Форматирование перевода Telegram сохраняет только с Premium.")
            }
            Section {
                Picker("Фон переписки", selection: $chatBackground) {
                    ForEach(ChatBackground.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Затемнение фона") {
                    HStack {
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                        Slider(value: $backgroundDim, in: 0...0.6)
                            .frame(width: 180)
                            .disabled(chatBackground != ChatBackground.glass.rawValue)
                        Image(systemName: "moon.fill").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Оформление")
            } footer: {
                Text("Фон переписки — стекло macOS: чем меньше затемнение, тем сильнее просвечивает то, что за окном.")
            }
            Section {
                Toggle("Показывать фото профилей", isOn: $showsAvatars)
                Toggle("Анимировать стикеры и GIF", isOn: $animatesStickers)
            } header: {
                Text("Медиа")
            } footer: {
                Text("Анимация останавливается, пока окно iGram не активно.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @AppStorage(Preferences.notificationsEnabled) private var isEnabled = true
    @AppStorage(Preferences.notificationSound) private var playsSound = true
    @AppStorage(Preferences.notificationPreview) private var showsText = true
    @AppStorage(Preferences.dockBadge) private var showsBadge = true

    var body: some View {
        Form {
            Section {
                Toggle("Уведомлять о новых сообщениях", isOn: $isEnabled)
                Toggle("Звук", isOn: $playsSound)
                    .disabled(!isEnabled)
                Toggle("Показывать текст сообщения", isOn: $showsText)
                    .disabled(!isEnabled)
            } footer: {
                Text("Чаты с выключенными уведомлениями молчат, кроме упоминаний вас.")
            }
            Section {
                Toggle("Число непрочитанных на иконке в Dock", isOn: $showsBadge)
                Button("Системные настройки уведомлений…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @AppStorage(Preferences.showOnline) private var showsOnline = true
    @AppStorage(Preferences.sendTyping) private var sendsTyping = true
    @AppStorage(Preferences.markReadOnOpen) private var marksRead = true

    var body: some View {
        Form {
            Section {
                Toggle("Показывать, что я в сети, пока окно iGram активно", isOn: $showsOnline)
                Toggle("Отправлять «печатает…»", isOn: $sendsTyping)
                Toggle("Отмечать сообщения прочитанными при открытии чата", isOn: $marksRead)
            } footer: {
                Text("Без автоматической отметки сообщения читаются только кнопкой «Отметить прочитанным» (⌘⇧E). Кому видно время вашего последнего захода, решают настройки конфиденциальности Telegram.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Features borrowed from AyuGram.
private struct GhostSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.ghostMode) private var isGhost = false
    @AppStorage(Preferences.ghostReadOnReply) private var readsOnReply = true
    @AppStorage(Preferences.saveDeletedMessages) private var keepsDeleted = true
    @AppStorage(Preferences.saveEditHistory) private var keepsEdits = true
    @AppStorage(Preferences.markLocalEdits) private var marksLocalEdits = false
    @AppStorage(Preferences.archiveSecretChats) private var keepsSecret = false

    var body: some View {
        Form {
            Section {
                Toggle("Режим призрака", isOn: $isGhost)
                Toggle("Читать чат, когда отвечаю в нём", isOn: $readsOnReply)
                    .disabled(!isGhost)
            } footer: {
                Text("Пока режим включён, вы не в сети, не видно «печатает…», сообщения и кружки остаются непрочитанными для собеседников. «Отметить прочитанным» по-прежнему работает. Переключается и кнопкой с глазом над списком чатов.")
            }
            Section {
                Toggle("Сохранять удалённые сообщения", isOn: $keepsDeleted)
                Toggle("Сохранять историю изменений", isOn: $keepsEdits)
                Toggle("Помечать сообщения, изменённые локально", isOn: $marksLocalEdits)
                Toggle("Сохранять и из секретных чатов", isOn: $keepsSecret)
                    .disabled(!keepsDeleted && !keepsEdits)
                    .help("Выключено: сообщение, удалённое в секретном чате, исчезает и здесь, как и задумано")
                Button("Очистить сохранённое", role: .destructive) {
                    if Dialogs.confirm("Очистить сохранённое?", message: "Сохранённые удалённые сообщения, история изменений и локальные правки пропадут с этого Mac.", action: "Очистить") {
                        model.clearArchive()
                    }
                }
            } footer: {
                Text("Сообщения, которые удалил собеседник, остаются в чате с пометкой «удалено»; у изменённых в меню есть «История изменений…». Всё хранится только на этом Mac.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Checks for links and files, the state of the account's protection, and the devices signed in to it.
private struct SecuritySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.linkGuard) private var guardsLinks = true
    @AppStorage(Preferences.fileGuard) private var guardsFiles = true
    @AppStorage(Preferences.securityTools) private var showsTools = true
    @State private var findings: [AppModel.SecurityFinding]?
    @State private var sessions: [AppModel.ActiveSession]?
    @State private var isChecking = false
    @AppStorage(Preferences.autoLockMinutes) private var autoLockMinutes = 15
    @State private var passcode = ""
    @State private var repeated = ""
    @State private var passcodeError = ""
    @State private var isWorking = false

    /// The passcode: what it protects, and the one thing it costs.
    @ViewBuilder
    private var passcodeSection: some View {
        Section {
            if model.hasPasscode {
                Picker("Блокировать без действий", selection: $autoLockMinutes) {
                    Text("через 1 минуту").tag(1)
                    Text("через 5 минут").tag(5)
                    Text("через 15 минут").tag(15)
                    Text("через час").tag(60)
                    Text("никогда").tag(0)
                }
                Button("Заблокировать сейчас") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                SecureField("Код-пароль, чтобы отключить", text: $passcode)
                Button("Отключить код-пароль", role: .destructive) {
                    run { await model.removePasscode(passcode) }
                }
                .disabled(passcode.isEmpty || isWorking)
            } else {
                SecureField("Новый код-пароль", text: $passcode)
                SecureField("Ещё раз", text: $repeated)
                Button(isWorking ? "Шифрование…" : "Включить код-пароль") {
                    guard passcode == repeated else {
                        passcodeError = "Код-пароли не совпадают"
                        return
                    }
                    run { await model.setPasscode(passcode) }
                }
                .disabled(passcode.count < AppLock.minimumLength || repeated.isEmpty || isWorking)
            }
            if !passcodeError.isEmpty {
                Text(passcodeError).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Код-пароль")
        } footer: {
            Text(model.hasPasscode
                ? "iGram спрашивает код-пароль при запуске, после сна экрана и по таймеру. База Telegram и архив удалённых сообщений на этом Mac зашифрованы ключом из него. Touch ID работает после первого ввода с момента запуска."
                : "Код-пароль закрывает iGram и шифрует базу Telegram и архив удалённых сообщений на этом Mac. Он нигде не хранится: забытый код-пароль восстановить нельзя — придётся войти в аккаунт заново, а секретные чаты на этом Mac пропадут.")
        }
    }

    private func run(_ work: @escaping () async -> String?) {
        isWorking = true
        passcodeError = ""
        Task {
            passcodeError = await work() ?? ""
            isWorking = false
            if passcodeError.isEmpty {
                passcode = ""
                repeated = ""
            }
        }
    }

    var body: some View {
        Form {
            passcodeSection
            Section {
                Toggle("Проверять ссылки перед открытием", isOn: $guardsLinks)
                Toggle("Предупреждать об исполняемых файлах", isOn: $guardsFiles)
                Toggle("Меню «Безопасность» у сообщений", isOn: $showsTools)
            } footer: {
                Text("Ссылки: punycode и смешанные алфавиты, IP вместо домена, сокращатели, «имя@» в адресе, http. Файлы: .app, .pkg, .command, .exe, двойные расширения и скрытые символы направления текста. В меню сообщения — индикаторы (IOC) с обезвреживанием и SHA-256 вложений.")
            }
            Section {
                if let findings {
                    ForEach(findings) { finding in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.title)
                                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: icon(finding.level)).foregroundStyle(color(finding.level))
                        }
                    }
                }
                Button(isChecking ? "Проверка…" : (findings == nil ? "Проверить аккаунт" : "Проверить ещё раз")) {
                    Task { await refresh() }
                }
                .disabled(isChecking)
            } header: {
                Text("Защита аккаунта")
            }
            Section {
                if let sessions {
                    ForEach(sessions) { session in
                        HStack(alignment: .top) {
                            Image(systemName: session.isCurrent ? "laptopcomputer" : "desktopcomputer")
                                .foregroundStyle(session.isUnconfirmed ? .orange : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.application + (session.isOfficial ? "" : " · неофициальное"))
                                    .fontWeight(session.isCurrent ? .semibold : .regular)
                                Text([session.device, session.system].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text([session.ipAddress, session.location,
                                      session.isCurrent ? "этот Mac" : "активен " + session.lastActive.formatted(.relative(presentation: .named).locale(Locale(identifier: "ru_RU")))]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if !session.isCurrent {
                                Button("Завершить", role: .destructive) {
                                    guard Dialogs.confirm("Завершить сеанс?", message: "\(session.application) на \(session.device) выйдет из аккаунта.", action: "Завершить") else { return }
                                    Task {
                                        if await model.terminateSession(session.id) { self.sessions = await model.activeSessions() }
                                    }
                                }
                            }
                        }
                    }
                    if sessions.count > 1 {
                        Button("Завершить все другие сеансы", role: .destructive) {
                            guard Dialogs.confirm("Завершить все другие сеансы?", message: "Все устройства, кроме этого Mac, выйдут из аккаунта.", action: "Завершить") else { return }
                            Task {
                                if await model.terminateOtherSessions() { self.sessions = await model.activeSessions() }
                            }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text("Активные сеансы")
            } footer: {
                Text("Незнакомое устройство, город или приложение — повод завершить сеанс и сменить облачный пароль. Оранжевым отмечены входы, которые ещё не подтверждены.")
            }
        }
        .formStyle(.grouped)
        .task { sessions = await model.activeSessions() }
    }

    private func refresh() async {
        isChecking = true
        async let audit = model.securityAudit()
        async let list = model.activeSessions()
        findings = await audit
        sessions = await list
        isChecking = false
    }

    private func icon(_ level: AppModel.SecurityFinding.Level) -> String {
        switch level {
        case .good: "checkmark.shield.fill"
        case .advice: "exclamationmark.circle.fill"
        case .risk: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ level: AppModel.SecurityFinding.Level) -> Color {
        switch level {
        case .good: .green
        case .advice: .orange
        case .risk: .red
        }
    }
}

private struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var usage: StorageUsage?
    @State private var isClearing = false

    var body: some View {
        Form {
            Section("Занято на диске") {
                LabeledContent("Скачанные файлы", value: usage.map {
                    "\(Self.bytes($0.files)), \(TD.count($0.fileCount, "файл", "файла", "файлов"))"
                } ?? "—")
                LabeledContent("База сообщений", value: usage.map { Self.bytes($0.database) } ?? "—")
            }
            Section {
                Button(isClearing ? "Очистка…" : "Очистить кэш") {
                    isClearing = true
                    Task {
                        await model.clearCache()
                        usage = await model.storageUsage()
                        isClearing = false
                    }
                }
                .disabled(isClearing || usage == nil)
            } footer: {
                Text("Удаляются скачанные фото, стикеры и вложения. Переписка остаётся, файлы скачаются снова, когда понадобятся.")
            }
        }
        .formStyle(.grouped)
        .task { usage = await model.storageUsage() }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var options = AppModel.ExportOptions()
    @State private var profile = AppModel.MyProfile()
    @State private var loaded: AppModel.MyProfile?
    @State private var profileStatus = ""
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                TextField("Имя", text: $profile.firstName)
                TextField("Фамилия", text: $profile.lastName)
                TextField("Имя пользователя", text: $profile.username, prompt: Text("без @"))
                TextField("О себе", text: $profile.bio, axis: .vertical)
                    .lineLimit(1...3)
                HStack {
                    Text(profileStatus)
                        .font(.caption)
                        .foregroundStyle(profileStatus.hasPrefix("Сохранено") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    Spacer()
                    Button(isSaving ? "Сохранение…" : "Сохранить") { save() }
                        .disabled(loaded == nil || loaded == profile || isSaving || profile.firstName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Мой профиль")
            } footer: {
                Text("«О себе» — до 70 символов. Имя пользователя: латиница, цифры и _, от 5 символов; пустое — убрать.")
            }
            Section {
                Toggle("Контакты", isOn: $options.contacts)
                Picker("Переписка", selection: $options.chats) {
                    ForEach(AppModel.ExportOptions.Chats.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Сообщений на чат", selection: $options.messagesPerChat) {
                    Text("500 последних").tag(500)
                    Text("2 000 последних").tag(2000)
                    Text("10 000 последних").tag(10000)
                    Text("Вся история").tag(0)
                }
                .disabled(options.chats == .none)
                HStack {
                    if let progress = model.exportProgress {
                        ProgressView().controlSize(.small)
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Остановить") { model.cancelExport() }
                    } else {
                        Button("Экспортировать…") { chooseFolder() }
                        Spacer()
                        if let last = model.lastExport {
                            Button("Показать последний") { NSWorkspace.shared.activateFileViewerSelecting([last]) }
                        }
                    }
                }
            } header: {
                Text("Резервная копия данных")
            } footer: {
                Text("Профиль, контакты, список чатов и сообщения — в JSON и в HTML, который открывается в браузере. Ключи сессии и база входа в копию не попадают: по ней нельзя войти в аккаунт, её безопасно хранить и переносить.")
            }
            Section("Аккаунт") {
                LabeledContent("Имя", value: model.accountName.isEmpty ? "—" : model.accountName)
                LabeledContent("api_id", value: model.apiIdField.isEmpty ? "—" : model.apiIdField)
                LabeledContent("База TDLib", value: ConfigStore.databaseDirectory.path)
                Button("Выйти из аккаунта") {
                    if Dialogs.confirm("Выйти из аккаунта?", message: "Сессия на этом Mac завершится, локальная база TDLib будет удалена. Войти снова можно по номеру телефона.", action: "Выйти") {
                        model.logOut()
                    }
                }
                Button("Забыть ключи на этом Mac", role: .destructive) {
                    if Dialogs.confirm("Забыть api_id и api_hash?", message: "Для подключения их придётся ввести заново. Вход в аккаунт сохранится.", action: "Забыть") {
                        model.forgetCredentials()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            guard loaded == nil, let mine = await model.loadMyProfile() else { return }
            loaded = mine
            profile = mine
        }
    }

    private func save() {
        guard let old = loaded else { return }
        isSaving = true
        let edited = profile
        Task {
            if let problem = await model.saveMyProfile(edited, was: old) {
                profileStatus = problem
            } else {
                loaded = edited
                profileStatus = "Сохранено"
            }
            isSaving = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Куда сохранить копию"
        panel.prompt = "Сохранить сюда"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.exportAccount(to: folder, options: options)
    }
}

private struct DeveloperSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.showMessageCode) private var showsCode = false
    @AppStorage(Preferences.showIdentifiers) private var showsIdentifiers = false
    @AppStorage(Preferences.tdlibLogLevel) private var logLevel = 1

    var body: some View {
        Form {
            Section {
                Toggle("Показывать код сообщений и чатов (JSON TDLib)", isOn: $showsCode)
                Toggle("Показывать ID сообщений и чатов", isOn: $showsIdentifiers)
            } footer: {
                Text("«Код сообщения…», «Код чата…» и «Скопировать ID» появятся в контекстном меню, ID — под сообщениями.")
            }
            Section("TDLib") {
                LabeledContent("Версия", value: model.tdlibVersion.isEmpty ? "—" : model.tdlibVersion)
                LabeledContent("Процессор", value: Self.processor)
                Picker("Журнал", selection: $logLevel) {
                    Text("Выключен").tag(0)
                    Text("Только ошибки").tag(1)
                    Text("Предупреждения").tag(2)
                    Text("Информация").tag(3)
                    Text("Отладка").tag(4)
                    Text("Всё").tag(5)
                }
                Button("Показать журнал в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Preferences.logFile])
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "Apple M4, arm64": the app and TDLib are built for Apple Silicon only.
    private static let processor: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return "\(String(cString: name)), \(architecture)"
    }()
}
