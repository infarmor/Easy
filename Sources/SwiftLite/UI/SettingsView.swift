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
            Tab(L("Основные"), systemImage: "gearshape") { GeneralSettings() }
            Tab(L("Уведомления"), systemImage: "bell.badge") { NotificationSettings() }
            Tab(L("Конфиденциальность"), systemImage: "hand.raised") { PrivacySettings() }
            Tab(L("Призрак"), systemImage: "eye.slash") { GhostSettings() }
            Tab(L("Безопасность"), systemImage: "lock.shield") { SecuritySettings() }
            Tab(L("Прокси"), systemImage: "network") { ProxyPane() }
            Tab(L("Хранилище"), systemImage: "internaldrive") { StorageSettings() }
            Tab(L("Аккаунт"), systemImage: "person.crop.circle") { AccountSettings() }
            Tab(L("Для разработчиков"), systemImage: "hammer") { DeveloperSettings() }
        }
        // Nine panes do not fit a toolbar of tabs: they went behind a "»". A sidebar holds them all, as in
        // System Settings.
        .tabViewStyle(.sidebarAdaptable)
        .frame(width: 800, height: 540)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.messageFontSize) private var messageFontSize = 14
    @AppStorage(Preferences.sendWithCommandReturn) private var sendsWithCommandReturn = false
    @AppStorage(Preferences.showAvatars) private var showsAvatars = true
    @AppStorage(Preferences.animateStickers) private var animatesStickers = true
    @AppStorage(Preferences.backgroundDim) private var backgroundDim = 0.26
    @AppStorage(Preferences.chatBackground) private var chatBackground = ChatBackground.glass.rawValue
    @AppStorage(Preferences.translateToLanguage) private var translateTo = "ru"
    @AppStorage(Preferences.wallpaperColors) private var followsWallpaper = true
    @AppStorage(Loc.preference) private var language = "system"
    @AppStorage(Preferences.hideAds) private var hidesAds = true
    @AppStorage(Preferences.filterWords) private var filterWords = ""
    @AppStorage(Preferences.adLearned) private var learnedAds = ""
    @AppStorage(Preferences.checkUpdates) private var checksUpdates = true

    var body: some View {
        Form {
            Section {
                Picker(L("Язык интерфейса"), selection: $language) {
                    Text(L("Как в системе")).tag("system")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
                Toggle(L("Проверять обновления при запуске"), isOn: $checksUpdates)
            } header: {
                Text(L("Приложение"))
            } footer: {
                Text(L("Язык меняется после перезапуска Easy. Проверка обновлений — один запрос к GitHub при запуске; больше ничего не передаётся."))
            }
            Section {
                Stepper(value: $messageFontSize, in: 11...20) {
                    LabeledContent(L("Размер текста сообщений"), value: "\(messageFontSize) pt")
                }
                .help(L("Также ⌘+ и ⌘− в окне переписки"))
                Picker(L("Отправка сообщения"), selection: $sendsWithCommandReturn) {
                    Text("Return").tag(false)
                    Text(L("⌘Return (Return — новая строка)")).tag(true)
                }
                Picker(L("Переводить в"), selection: $translateTo) {
                    ForEach(AppModel.translationLanguages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            } header: {
                Text(L("Сообщения"))
            } footer: {
                Text(L("Пункт «Перевести» в меню сообщения. Форматирование перевода Telegram сохраняет только с Premium."))
            }
            Section {
                Toggle(L("Цвета по обоям рабочего стола"), isOn: $followsWallpaper)
                    .onChange(of: followsWallpaper) { _, _ in Theme.shared.refresh() }
                    .help(L("Акцент и боковая панель берут основной цвет картинки рабочего стола; без неё — индиго"))
                Picker(L("Фон переписки"), selection: $chatBackground) {
                    ForEach(ChatBackground.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent(L("Затемнение фона")) {
                    HStack {
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                        Slider(value: $backgroundDim, in: 0...0.6)
                            .frame(width: 180)
                            .disabled(chatBackground != ChatBackground.glass.rawValue)
                        Image(systemName: "moon.fill").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("Оформление"))
            } footer: {
                Text(L("Фон переписки — стекло macOS: чем меньше затемнение, тем сильнее просвечивает то, что за окном."))
            }
            Section {
                Toggle(L("Скрывать рекламные посты в каналах"), isOn: $hidesAds)
                TextField(L("Скрывать сообщения со словами"), text: $filterWords, prompt: Text(L("казино, ставки, розыгрыш")))
                if !learnedAds.isEmpty {
                    LabeledContent(L("Выучено признаков рекламы: \(AdFilter.learnedCount)")) {
                        Button(L("Забыть")) { AdFilter.forgetLearned() }
                    }
                }
            } header: {
                Text(L("Фильтр"))
            } footer: {
                Text(L("Рекламой считается пост канала с пометкой: «erid», «Реклама» с ИНН рекламодателя, #реклама, #ad. Слова — через запятую; сообщение с любым из них сворачивается в любом чате. Скрытое можно показать одним нажатием, и уведомлений о нём нет. Спонсорские сообщения Telegram в Easy не показываются вовсе."))
            }
            Section {
                Toggle(L("Показывать фото профилей"), isOn: $showsAvatars)
                Toggle(L("Анимировать стикеры и GIF"), isOn: $animatesStickers)
            } header: {
                Text(L("Медиа"))
            } footer: {
                Text(L("Анимация останавливается, пока окно Easy не активно."))
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
                Toggle(L("Уведомлять о новых сообщениях"), isOn: $isEnabled)
                Toggle(L("Звук"), isOn: $playsSound)
                    .disabled(!isEnabled)
                Toggle(L("Показывать текст сообщения"), isOn: $showsText)
                    .disabled(!isEnabled)
            } footer: {
                Text(L("Чаты с выключенными уведомлениями молчат, кроме упоминаний вас."))
            }
            Section {
                Toggle(L("Число непрочитанных на иконке в Dock"), isOn: $showsBadge)
                Button(L("Системные настройки уведомлений…")) {
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
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.spotlight) private var usesSpotlight = true
    @AppStorage(Preferences.showOnline) private var showsOnline = true
    @AppStorage(Preferences.sendTyping) private var sendsTyping = true
    @AppStorage(Preferences.markReadOnOpen) private var marksRead = true

    var body: some View {
        Form {
            Section {
                Toggle(L("Показывать, что я в сети, пока окно Easy активно"), isOn: $showsOnline)
                Toggle(L("Отправлять «печатает…»"), isOn: $sendsTyping)
                Toggle(L("Отмечать сообщения прочитанными при открытии чата"), isOn: $marksRead)
            } footer: {
                Text(L("Без автоматической отметки сообщения читаются только кнопкой «Отметить прочитанным» (⌘⇧E). Кому видно время вашего последнего захода, решают настройки конфиденциальности Telegram."))
            }
            Section {
                Toggle(L("Находить чаты через Spotlight"), isOn: $usesSpotlight)
                    .disabled(model.hasPasscode)
                    .onChange(of: usesSpotlight) { _, isOn in
                        if isOn { model.scheduleSpotlight() } else { Spotlight.forgetAll() }
                    }
            } footer: {
                Text(model.hasPasscode
                     ? L("Пока задан код-пароль, чатов в Spotlight нет: их названия было бы видно на заблокированном Mac.")
                     : L("В Spotlight попадают только названия чатов, без сообщений и без секретных чатов."))
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
                Toggle(L("Режим призрака"), isOn: $isGhost)
                Toggle(L("Читать чат, когда отвечаю в нём"), isOn: $readsOnReply)
                    .disabled(!isGhost)
            } footer: {
                Text(L("Пока режим включён, вы не в сети, не видно «печатает…», сообщения и кружки остаются непрочитанными для собеседников. «Отметить прочитанным» по-прежнему работает. Переключается и кнопкой с глазом над списком чатов."))
            }
            Section {
                Toggle(L("Сохранять удалённые сообщения"), isOn: $keepsDeleted)
                Toggle(L("Сохранять историю изменений"), isOn: $keepsEdits)
                Toggle(L("Помечать сообщения, изменённые локально"), isOn: $marksLocalEdits)
                Toggle(L("Сохранять и из секретных чатов"), isOn: $keepsSecret)
                    .disabled(!keepsDeleted && !keepsEdits)
                    .help(L("Выключено: сообщение, удалённое в секретном чате, исчезает и здесь, как и задумано"))
                Button(L("Очистить сохранённое"), role: .destructive) {
                    if Dialogs.confirm(L("Очистить сохранённое?"), message: L("Сохранённые удалённые сообщения, история изменений и локальные правки пропадут с этого Mac."), action: L("Очистить")) {
                        model.clearArchive()
                    }
                }
            } footer: {
                Text(L("Сообщения, которые удалил собеседник, остаются в чате с пометкой «удалено»; у изменённых в меню есть «История изменений…». Всё хранится только на этом Mac."))
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
    @State private var websites: [AppModel.ConnectedWebsite]?
    /// TDLib did not answer about the sites: said so, rather than shown as an endless wait or as "none".
    @State private var websitesFailed = false
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
                Picker(L("Блокировать без действий"), selection: $autoLockMinutes) {
                    Text(L("через 1 минуту")).tag(1)
                    Text(L("через 5 минут")).tag(5)
                    Text(L("через 15 минут")).tag(15)
                    Text(L("через час")).tag(60)
                    Text(L("никогда")).tag(0)
                }
                Button(L("Заблокировать сейчас")) { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                SecureField(L("Код-пароль, чтобы отключить"), text: $passcode)
                Button(L("Отключить код-пароль"), role: .destructive) {
                    run { await model.removePasscode(passcode) }
                }
                .disabled(passcode.isEmpty || isWorking)
            } else {
                SecureField(L("Новый код-пароль"), text: $passcode)
                SecureField(L("Ещё раз"), text: $repeated)
                Button(isWorking ? L("Шифрование…") : L("Включить код-пароль")) {
                    guard passcode == repeated else {
                        passcodeError = L("Код-пароли не совпадают")
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
            Text(L("Код-пароль"))
        } footer: {
            Text(model.hasPasscode
                ? L("Easy спрашивает код-пароль при запуске, после сна экрана и по таймеру. База Telegram и архив удалённых сообщений на этом Mac зашифрованы ключом из него. Touch ID работает после первого ввода с момента запуска.")
                : L("Код-пароль закрывает Easy и шифрует базу Telegram и архив удалённых сообщений на этом Mac. Он нигде не хранится: забытый код-пароль восстановить нельзя — придётся войти в аккаунт заново, а секретные чаты на этом Mac пропадут."))
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
                Toggle(L("Проверять ссылки перед открытием"), isOn: $guardsLinks)
                Toggle(L("Предупреждать об исполняемых файлах"), isOn: $guardsFiles)
                Toggle(L("Меню «Безопасность» у сообщений"), isOn: $showsTools)
            } footer: {
                Text(L("Ссылки: punycode и смешанные алфавиты, IP вместо домена, сокращатели, «имя@» в адресе, http. Файлы: .app, .pkg, .command, .exe, двойные расширения и скрытые символы направления текста. В меню сообщения — индикаторы (IOC) с обезвреживанием и SHA-256 вложений."))
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
                Button(isChecking ? L("Проверка…") : (findings == nil ? L("Проверить аккаунт") : L("Проверить ещё раз"))) {
                    Task { await refresh() }
                }
                .disabled(isChecking)
            } header: {
                Text(L("Защита аккаунта"))
            }
            Section {
                if let sessions {
                    ForEach(sessions) { session in
                        HStack(alignment: .top) {
                            Image(systemName: session.isCurrent ? "laptopcomputer" : "desktopcomputer")
                                .foregroundStyle(session.isUnconfirmed ? .orange : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.application + (session.isOfficial ? "" : L(" · неофициальное")))
                                    .fontWeight(session.isCurrent ? .semibold : .regular)
                                Text([session.device, session.system].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text([session.ipAddress, session.location,
                                      session.isCurrent ? L("этот Mac") : L("активен ") + session.lastActive.formatted(.relative(presentation: .named).locale(Loc.locale))]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if !session.isCurrent {
                                Button(L("Завершить"), role: .destructive) {
                                    guard Dialogs.confirm(L("Завершить сеанс?"), message: L("\(session.application) на \(session.device) выйдет из аккаунта."), action: L("Завершить")) else { return }
                                    Task {
                                        if await model.terminateSession(session.id) { self.sessions = await model.activeSessions() }
                                    }
                                }
                            }
                        }
                    }
                    if sessions.count > 1 {
                        Button(L("Завершить все другие сеансы"), role: .destructive) {
                            guard Dialogs.confirm(L("Завершить все другие сеансы?"), message: L("Все устройства, кроме этого Mac, выйдут из аккаунта."), action: L("Завершить")) else { return }
                            Task {
                                if await model.terminateOtherSessions() { self.sessions = await model.activeSessions() }
                            }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text(L("Активные сеансы"))
            } footer: {
                Text(L("Незнакомое устройство, город или приложение — повод завершить сеанс и сменить облачный пароль. Оранжевым отмечены входы, которые ещё не подтверждены."))
            }
            websitesSection
        }
        .formStyle(.grouped)
        .task {
            async let list = model.activeSessions()
            async let sites = model.connectedWebsites()
            sessions = await list
            websites = await sites
            websitesFailed = websites == nil
        }
    }

    /// Sites entered with "Log in with Telegram": the other place, besides sessions, where access lingers.
    @ViewBuilder
    private var websitesSection: some View {
        Section {
            if let websites {
                if websites.isEmpty {
                    Text(L("Ни один сайт не подключён."))
                        .foregroundStyle(.secondary)
                }
                ForEach(websites) { site in
                    HStack(alignment: .top) {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.domain.isEmpty ? L("Сайт") : site.domain)
                            Text([site.browser, site.platform].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text([site.ipAddress, site.location,
                                  L("активен ") + site.lastActive.formatted(.relative(presentation: .named).locale(Loc.locale))]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button(L("Отключить"), role: .destructive) {
                            guard Dialogs.confirm(L("Отключить \(site.domain)?"), message: L("Сайт потеряет вход через ваш Telegram; войти туда можно будет заново."), action: L("Отключить")) else { return }
                            Task {
                                if await model.disconnectWebsite(site.id) { self.websites = await model.connectedWebsites() }
                            }
                        }
                    }
                }
                if websites.count > 1 {
                    Button(L("Отключить все сайты"), role: .destructive) {
                        guard Dialogs.confirm(L("Отключить все сайты?"), message: L("Все сайты потеряют вход через ваш Telegram."), action: L("Отключить")) else { return }
                        Task {
                            if await model.disconnectAllWebsites() { self.websites = await model.connectedWebsites() }
                        }
                    }
                }
            } else if websitesFailed {
                Text(L("Telegram не отдал список сайтов."))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        } header: {
            Text(L("Сайты со входом через Telegram"))
        } footer: {
            Text(L("Сайт, на который вы входили кнопкой «Войти через Telegram», видит ваше имя и фото и может писать вам через своего бота. Незнакомый домен — повод его отключить."))
        }
    }

    private func refresh() async {
        isChecking = true
        async let audit = model.securityAudit()
        async let list = model.activeSessions()
        async let sites = model.connectedWebsites()
        findings = await audit
        sessions = await list
        websites = await sites
        websitesFailed = websites == nil
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
            Section(L("Занято на диске")) {
                LabeledContent(L("Скачанные файлы"), value: usage.map {
                    "\(Self.bytes($0.files)), \(TD.count($0.fileCount, L("файл"), L("файла"), L("файлов")))"
                } ?? "—")
                LabeledContent(L("База сообщений"), value: usage.map { Self.bytes($0.database) } ?? "—")
            }
            Section {
                Button(isClearing ? L("Очистка…") : L("Очистить кэш")) {
                    isClearing = true
                    Task {
                        await model.clearCache()
                        usage = await model.storageUsage()
                        isClearing = false
                    }
                }
                .disabled(isClearing || usage == nil)
            } footer: {
                Text(L("Удаляются скачанные фото, стикеры и вложения. Переписка остаётся, файлы скачаются снова, когда понадобятся."))
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
                TextField(L("Имя"), text: $profile.firstName)
                TextField(L("Фамилия"), text: $profile.lastName)
                TextField(L("Имя пользователя"), text: $profile.username, prompt: Text(L("без @")))
                TextField(L("О себе"), text: $profile.bio, axis: .vertical)
                    .lineLimit(1...3)
                HStack {
                    Text(profileStatus)
                        .font(.caption)
                        .foregroundStyle(profileStatus.hasPrefix(L("Сохранено")) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    Spacer()
                    Button(isSaving ? L("Сохранение…") : L("Сохранить")) { save() }
                        .disabled(loaded == nil || loaded == profile || isSaving || profile.firstName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text(L("Мой профиль"))
            } footer: {
                Text(L("«О себе» — до 70 символов. Имя пользователя: латиница, цифры и _, от 5 символов; пустое — убрать."))
            }
            Section {
                Toggle(L("Контакты"), isOn: $options.contacts)
                Picker(L("Переписка"), selection: $options.chats) {
                    ForEach(AppModel.ExportOptions.Chats.allCases) { Text(Loc.translate($0.rawValue)).tag($0) }
                }
                Picker(L("Сообщений на чат"), selection: $options.messagesPerChat) {
                    Text(L("500 последних")).tag(500)
                    Text(L("2 000 последних")).tag(2000)
                    Text(L("10 000 последних")).tag(10000)
                    Text(L("Вся история")).tag(0)
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
                        Button(L("Остановить")) { model.cancelExport() }
                    } else {
                        Button(L("Экспортировать…")) { chooseFolder() }
                        Spacer()
                        if let last = model.lastExport {
                            Button(L("Показать последний")) { NSWorkspace.shared.activateFileViewerSelecting([last]) }
                        }
                    }
                }
            } header: {
                Text(L("Резервная копия данных"))
            } footer: {
                Text(L("Профиль, контакты, список чатов и сообщения — в JSON и в HTML, который открывается в браузере. Ключи сессии и база входа в копию не попадают: по ней нельзя войти в аккаунт, её безопасно хранить и переносить."))
            }
            Section(L("Аккаунт")) {
                LabeledContent(L("Имя"), value: model.accountName.isEmpty ? "—" : model.accountName)
                LabeledContent("api_id", value: model.apiIdField.isEmpty ? "—" : model.apiIdField)
                LabeledContent(L("База TDLib"), value: ConfigStore.databaseDirectory(for: model.slot).path)
                Button(L("Выйти из аккаунта")) {
                    if Dialogs.confirm(L("Выйти из аккаунта?"), message: L("Сессия на этом Mac завершится, локальная база TDLib будет удалена. Войти снова можно по номеру телефона."), action: L("Выйти")) {
                        model.logOut()
                    }
                }
                Button(L("Забыть ключи на этом Mac"), role: .destructive) {
                    if Dialogs.confirm(L("Забыть api_id и api_hash?"), message: L("Для подключения их придётся ввести заново. Вход в аккаунт сохранится."), action: L("Забыть")) {
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
                profileStatus = L("Сохранено")
            }
            isSaving = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L("Куда сохранить копию")
        panel.prompt = L("Сохранить сюда")
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
                Toggle(L("Показывать код сообщений и чатов (JSON TDLib)"), isOn: $showsCode)
                Toggle(L("Показывать ID сообщений и чатов"), isOn: $showsIdentifiers)
            } footer: {
                Text(L("«Код сообщения…», «Код чата…» и «Скопировать ID» появятся в контекстном меню, ID — под сообщениями."))
            }
            Section("TDLib") {
                LabeledContent(L("Версия"), value: model.tdlibVersion.isEmpty ? "—" : model.tdlibVersion)
                LabeledContent(L("Процессор"), value: Self.processor)
                Picker(L("Журнал"), selection: $logLevel) {
                    Text(L("Выключен")).tag(0)
                    Text(L("Только ошибки")).tag(1)
                    Text(L("Предупреждения")).tag(2)
                    Text(L("Информация")).tag(3)
                    Text(L("Отладка")).tag(4)
                    Text(L("Всё")).tag(5)
                }
                Button(L("Показать журнал в Finder")) {
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
