import Foundation

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if condition() { print("ok   \(label)") } else { failures += 1; print("FAIL \(label)") }
}

@MainActor func wait(_ label: String, timeout: Double = 30, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let done = condition()
    print("\(done ? "…" : "TIMEOUT") \(label)")
    return done
}

MainActor.assumeIsolated {
    let model = AppModel()
    let file = { (path: String) in FileManager.default.fileExists(atPath: path) }
    let credentials = "\(CommandLine.arguments[1])/root/credentials.json"

    model.apiIdField = "12345"
    model.apiHashField = "0123456789abcdef0123456789abcdef"
    model.submitCredentials()
    check(wait("first session reaches phone step") { model.phase == .phone && !model.busy }, "new client asks for the phone number")
    check(file(credentials), "keys saved")

    model.forgetCredentials()
    check(model.phase == .credentials && model.busy, "forget shows the key form while TDLib closes")
    check(wait("session closed after forget") { !model.busy }, "close completes")
    check(model.phase == .credentials && !file(credentials) && model.apiIdField.isEmpty, "keys forgotten, form is empty")

    model.apiIdField = "12345"
    model.apiHashField = "0123456789abcdef0123456789abcdef"
    model.submitCredentials()
    check(wait("second session reaches phone step") { model.phase == .phone && !model.busy }, "a fresh client opens the same database after close")

    let before = model.sessionsStarted
    model.restartSession()
    check(wait("restart") { model.sessionsStarted == before + 1 && model.phase == .phone && !model.busy }, "restart closes and reopens the session")
    check(model.errorText.isEmpty, "restart without errors: '\(model.errorText)'")

    model.phase = .working  // pretend we were signed in, log out must land on the phone step
    model.logOut()
    check(wait("log out") { model.sessionsStarted == before + 2 && model.phase == .phone && !model.busy }, "log out closes TDLib and starts a clean session")
    check(model.errorText.isEmpty, "log out without errors: '\(model.errorText)'")

    // The app died between writing the passcode's record and TDLib confirming the new key: the record says
    // "encrypted", the database on disk is not. The next launch has to get in anyway, and set the record right.
    if let made = AppLock.make(passcode: "correct horse") {
        var claimed = made.record
        claimed.encryptsDatabase = true
        try? AppLock.save(claimed)
        model.hasPasscode = true
        model.lockKeys = made.keys
        let again = model.sessionsStarted
        model.restartSession()
        check(wait("restart with a stale passcode record") { model.sessionsStarted == again + 1 && model.phase == .phone && !model.busy },
              "a database the record wrongly calls encrypted still opens")
        check(AppLock.load()?.encryptsDatabase == false && model.errorText.isEmpty,
              "and the record is corrected to what opened it: '\(model.errorText)'")
        AppLock.remove()
        model.hasPasscode = false
        model.lockKeys = nil
    } else {
        check(false, "a passcode record can be made")
    }

    var quitDone = false
    let quitStart = Date()
    Task { await model.prepareForQuit(); quitDone = true }
    check(wait("quit") { quitDone }, "quit waits for TDLib to close")
    check(!model.hasSession && Date().timeIntervalSince(quitStart) < 3 && model.phase == .phone, "TDLib closed within the time budget, screen left as it was (\(String(format: "%.2f", Date().timeIntervalSince(quitStart)))s)")

    model.phoneField = "+1"
    model.submitPhone()
    check(model.errorText.hasPrefix("Номер нужен"), "phone validation still local")
}

print(failures == 0 ? "ALL PASSED (\(checks) checks)" : "\(failures) FAILED of \(checks)")
exit(failures == 0 ? 0 : 1)
