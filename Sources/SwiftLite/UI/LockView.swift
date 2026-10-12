import LocalAuthentication
import SwiftUI

/// The cover over a locked Easy: the app's icon, a field for the passcode, and Touch ID once the passcode
/// has been typed since launch.
struct LockView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var passcode = ""
    @State private var isWrong = false
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
            VStack(spacing: 4) {
                Text(L("Easy заблокирован"))
                    .font(.title3.weight(.semibold))
                Text(isWrong ? L("Неверный код-пароль") : L("Введите код-пароль"))
                    .font(.callout)
                    .foregroundStyle(isWrong ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            SecureField(L("Код-пароль"), text: $passcode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit { submit() }
                .disabled(isChecking)
            HStack(spacing: 10) {
                if model.canUnlockWithoutPasscode, Self.hasBiometrics {
                    Button {
                        authenticate()
                    } label: {
                        Label("Touch ID", systemImage: "touchid")
                    }
                }
                Button(L("Разблокировать")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passcode.isEmpty || isChecking)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque: the conversation underneath must not show through, blurred or not.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            focused = true
            if model.canUnlockWithoutPasscode, Self.hasBiometrics { authenticate() }
        }
    }

    private static var hasBiometrics: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private func submit() {
        guard !passcode.isEmpty, !isChecking else { return }
        let typed = passcode
        isChecking = true
        Task {
            let opened = await model.unlock(with: typed)
            isChecking = false
            passcode = ""
            isWrong = !opened
            if !opened { focused = true }
        }
    }

    private func authenticate() {
        let context = LAContext()
        context.localizedCancelTitle = L("Ввести код-пароль")
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: L("разблокировать Easy")) { success, _ in
            guard success else { return }
            Task { @MainActor in model.unlockAfterSystemAuthentication() }
        }
    }
}
