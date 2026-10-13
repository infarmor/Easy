import AppKit
import Foundation

/// The passcode: locking the window, and the keys it gives for what Easy keeps on disk.
extension AppModel {
    // MARK: - unlocking

    /// The passcode typed on the lock screen. At launch this is what lets the session start; later it only
    /// lifts the cover.
    func unlock(with passcode: String) async -> Bool {
        guard let record = AppLock.load() else {
            // The record is gone (removed by hand): there is nothing left to check against.
            hasPasscode = false
            isLocked = false
            boot()
            return true
        }
        // A third of a million rounds by design; on the main thread that was a visible stall on every unlock.
        let keys = await Task.detached(priority: .userInitiated) { AppLock.unlock(passcode, record) }.value
        guard let keys else { return false }
        lockKeys = keys
        isLocked = false
        startAutoLock()
        presentLoginAlert()
        // Does nothing once a session exists.
        boot()
        hub?.shareLock(from: self)
        return true
    }

    /// Touch ID or the Mac's password confirmed who is at the keyboard. Only good once the passcode has been
    /// typed since launch: the keys come from the passcode, and a fingerprint cannot produce them.
    var canUnlockWithoutPasscode: Bool { isLocked && lockKeys != nil }

    func unlockAfterSystemAuthentication() {
        guard canUnlockWithoutPasscode else { return }
        isLocked = false
        hub?.shareLock(from: self)
    }

    /// Whether the menus may act on the account: signed in, and not behind the passcode. A locked window with
    /// live shortcuts would still open chats (and mark them read), paste files into one, or change its drafts.
    var takesCommands: Bool { phase == .working && !isLocked }

    /// Covers the window until the passcode is typed again. The session keeps running underneath: messages
    /// still arrive, their banners just stop quoting them.
    func lock() {
        guard hasPasscode, !isLocked else { return }
        // Anything in front of the main window would stay readable above the cover.
        profile = nil
        inspectedCode = nil
        forwardingBatch = nil
        managedChat = nil
        pendingFiles = nil
        viewerMessage = nil
        closeWebApp()
        isLocked = true
        // Another account one click away would be a way round the cover.
        hub?.shareLock(from: self)
    }

    /// The passcode's state as another account of this Mac has it. Does not call back into the hub.
    /// `rekeying`: the passcode was just set or removed, so this account's database and archive follow.
    func adoptLock(from source: AppModel, rekeying: Bool = false) {
        hasPasscode = source.hasPasscode
        lockKeys = source.lockKeys
        if source.isLocked, !isLocked {
            profile = nil
            inspectedCode = nil
            forwardingBatch = nil
            managedChat = nil
            pendingFiles = nil
            viewerMessage = nil
        }
        isLocked = source.isLocked
        if rekeying {
            archive.setKey(lockKeys?.archive)
            if isReady {
                let key = lockKeys?.database.base64EncodedString() ?? ""
                Task { _ = try? await request(["@type": "setDatabaseEncryptionKey", "new_encryption_key": key]) }
            }
        }
        // Does nothing once a session exists; at launch this is what lets a locked account start.
        if !isLocked { boot() }
    }

    // MARK: - a new device on the account

    /// Asks about a login that has not been confirmed: yours, or to be thrown out. Only in front of someone
    /// who can answer — the app active and unlocked — and one question at a time.
    func presentLoginAlert() {
        guard let summary = unconfirmedLogin, !isLocked, !isAskingAboutLogin, NSApp?.isActive == true else { return }
        isAskingAboutLogin = true
        Task {
            defer { isAskingAboutLogin = false }
            // The update names the device; the sessions list has the ids the answer needs.
            let pending = await activeSessions().filter { $0.isUnconfirmed && !$0.isCurrent }
            guard !pending.isEmpty, unconfirmedLogin == summary else {
                unconfirmedLogin = nil
                return
            }
            let details = pending.map { session in
                [session.device, session.application, session.location, session.ipAddress].filter { !$0.isEmpty }.joined(separator: " · ")
            }.joined(separator: "\n")
            let verdict = BotDialogs.judgeLogin(details)
            // Whatever the answer, this login has been shown; "later" leaves the session in the settings list.
            unconfirmedLogin = nil
            for session in pending {
                switch verdict {
                case .mine:
                    _ = try? await request(["@type": "confirmSession", "session_id": session.id])
                case .notMine:
                    if await terminateSession(session.id) { showToast(L("Сеанс завершён")) }
                case .later:
                    break
                }
            }
        }
    }

    // MARK: - setting and removing

    /// Sets a passcode and re-keys the database and the archive with it. The error to show, or nil.
    func setPasscode(_ passcode: String) async -> String? {
        guard passcode.count >= AppLock.minimumLength else { return L("Код-пароль — не меньше \(AppLock.minimumLength) символов") }
        guard isReady else { return L("Сначала войдите в аккаунт") }
        guard !hasPasscode else { return L("Код-пароль уже задан") }
        let made = await Task.detached(priority: .userInitiated) { AppLock.make(passcode: passcode) }.value
        guard let made else { return L("Не удалось создать ключ") }
        do {
            // The record goes to disk first, marked as not yet encrypting: if the app dies in the middle, the
            // next launch has the salt to rebuild the key and tries the database both ways.
            try AppLock.save(made.record)
            _ = try await request(["@type": "setDatabaseEncryptionKey",
                                   "new_encryption_key": made.keys.database.base64EncodedString()])
            var record = made.record
            record.encryptsDatabase = true
            try AppLock.save(record)
        } catch {
            AppLock.remove()
            return L("База не зашифрована: \((error as? TDError)?.message ?? error.localizedDescription)")
        }
        lockKeys = made.keys
        archive.setKey(made.keys.archive)
        hasPasscode = true
        // Chat names in Spotlight would be readable on a locked Mac; with a passcode they go.
        Spotlight.forgetAll()
        startAutoLock()
        hub?.shareLock(from: self, rekeying: true)
        return nil
    }

    /// Removes the passcode after checking it, and puts the database and the archive back in the clear.
    func removePasscode(_ passcode: String) async -> String? {
        guard let record = AppLock.load() else {
            hasPasscode = false
            return nil
        }
        let matches = await Task.detached(priority: .userInitiated) { AppLock.unlock(passcode, record) != nil }.value
        guard matches else { return L("Неверный код-пароль") }
        guard isReady else { return L("Сначала войдите в аккаунт") }
        do {
            if record.encryptsDatabase {
                var leaving = record
                leaving.encryptsDatabase = false
                // Marked before the change for the same reason as above; the launch after a crash tries both.
                try AppLock.save(leaving)
                _ = try await request(["@type": "setDatabaseEncryptionKey", "new_encryption_key": ""])
            }
        } catch {
            try? AppLock.save(record)
            return L("Не удалось снять шифрование: \((error as? TDError)?.message ?? error.localizedDescription)")
        }
        AppLock.remove()
        lockKeys = nil
        archive.setKey(nil)
        hasPasscode = false
        scheduleSpotlight()
        lockTimer?.invalidate()
        lockTimer = nil
        hub?.shareLock(from: self, rekeying: true)
        return nil
    }

    // MARK: - locking by itself

    /// Checks twice a minute how long the Mac has gone without a key or a click.
    func startAutoLock() {
        guard lockTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockIfIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockTimer = timer
    }

    private func lockIfIdle() {
        let minutes = UserDefaults.standard.integer(forKey: Preferences.autoLockMinutes)
        guard hasPasscode, !isLocked, minutes > 0 else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= Double(minutes * 60) { lock() }
    }
}
