import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 40)
                    // The icon the Dock shows, as the sign-in windows of Apple's own apps greet with theirs.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                    VStack(spacing: 4) {
                        Text("Easy")
                            .font(.system(size: 26, weight: .bold))
                        Text(L("Нативный клиент Telegram для Mac"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    LoginStage(model: model)
                        .padding(18)
                        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
                    if model.canLeaveSignIn {
                        Button(L("Вернуться к своему аккаунту")) { model.leaveSignIn() }
                            .buttonStyle(.link)
                    }
                }
                .padding(28)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
            ErrorBanner()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct LoginStage: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.phase {
        case .credentials:
            Form {
                TextField("api_id", text: $model.apiIdField)
                    .textFieldStyle(.roundedBorder)
                SecureField("api_hash", text: $model.apiHashField)
                    .textFieldStyle(.roundedBorder)
                primaryButton(L("Подключиться")) { model.submitCredentials() }
                Text(L("Ключи выдаются на my.telegram.org для вашего аккаунта. Хранятся в ~/Library/Application Support/SwiftLite с правами 600."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .phone:
            Form {
                TextField(L("Номер телефона"), text: $model.phoneField)
                    .textFieldStyle(.roundedBorder)
                primaryButton(L("Отправить код")) { model.submitPhone() }
                Button(L("Войти по QR-коду с телефона")) { model.startQrLogin() }
                    .buttonStyle(.link)
                    .disabled(model.busy)
            }
        case .qr(let link):
            VStack(spacing: 14) {
                if let image = QRCode.image(for: link) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Text(L("Откройте Telegram на телефоне → Настройки → Устройства → «Подключить устройство» и наведите камеру на код."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Войти по номеру телефона")) { model.cancelQrLogin() }
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity)
        case .email:
            Form {
                Text(L("Telegram просит привязать почту: код для входа придёт на неё"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Email", text: $model.emailField)
                    .textFieldStyle(.roundedBorder)
                primaryButton(L("Отправить код")) { model.submitEmail() }
            }
        case .code(let destination):
            Form {
                Text(destination)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(L("Код подтверждения"), text: $model.codeField)
                    .textFieldStyle(.roundedBorder)
                primaryButton(L("Подтвердить")) { model.submitCode() }
                if model.canResendCode {
                    Button(L("Отправить другим способом")) { model.resendCode() }
                        .disabled(model.busy)
                }
            }
        case .password(let hint):
            Form {
                if !hint.isEmpty {
                    Text(L("Подсказка: \(hint)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                SecureField(L("Облачный пароль"), text: $model.passwordField)
                    .textFieldStyle(.roundedBorder)
                primaryButton(L("Войти")) { model.submitPassword() }
            }
        case .working, .failed:
            EmptyView()
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.busy)
    }
}

/// Login QR codes, drawn by Core Image.
enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
