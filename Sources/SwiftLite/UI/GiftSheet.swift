import SwiftUI

/// Picks a gift for someone and pays for it with Stars. Nothing is spent until the confirmation is answered.
struct GiftSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let userId: Int64
    let name: String

    @State private var gifts: [AppModel.GiftOffer]?
    @State private var balance: Int?
    @State private var chosen: AppModel.GiftOffer?
    @State private var text = ""
    @State private var isPrivate = false
    @State private var isSending = false
    @State private var error = ""

    private static let textLimit = 255

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Подарок для \(name.isEmpty ? L("собеседника") : name)"))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(L("Оплачивается звёздами Telegram"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(balance.map { Self.stars($0) } ?? "…", systemImage: "star.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.brandInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.brand.opacity(0.14), in: Capsule())
                    .help(L("Ваш баланс звёзд"))
            }
            .padding(16)
            Divider()
            ScrollView {
                if let gifts {
                    if gifts.isEmpty {
                        Text(L("Telegram сейчас не предлагает подарков этому аккаунту."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                            ForEach(gifts) { gift in cell(gift) }
                        }
                        .padding(16)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                TextField(L("Подпись к подарку"), text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onChange(of: text) { _, new in
                        if new.count > Self.textLimit { text = String(new.prefix(Self.textLimit)) }
                    }
                Toggle(L("Скрыть моё имя от посетителей его профиля"), isOn: $isPrivate)
                if !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L("Отмена")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(chosen.map { L("Подарить за \(Self.stars($0.stars))") } ?? L("Выберите подарок")) { send() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brand)
                        .disabled(chosen == nil || isSending || !canAfford)
                }
                if let chosen, !canAfford, let balance {
                    Text(L("Нужно \(Self.stars(chosen.stars)), на балансе \(Self.stars(balance)). Пополнить можно в официальном приложении Telegram."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .frame(width: 480, height: 600)
        .background(.regularMaterial)
        .task {
            async let offers = model.availableGifts()
            async let stars = model.starBalance()
            gifts = await offers
            balance = await stars
        }
    }

    private var canAfford: Bool {
        guard let chosen else { return false }
        // An unknown balance does not block the button: Telegram itself refuses a purchase it cannot cover.
        return balance.map { $0 >= chosen.stars } ?? true
    }

    private func cell(_ gift: AppModel.GiftOffer) -> some View {
        let isChosen = chosen?.id == gift.id
        return Button {
            if !gift.isSoldOut { chosen = gift }
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let sticker = gift.sticker {
                        StickerThumb(sticker: sticker, side: 64)
                    } else {
                        Image(systemName: "gift.fill").font(.system(size: 34)).foregroundStyle(Color.brandInk)
                    }
                }
                .frame(width: 64, height: 64)
                Label(Self.stars(gift.stars), systemImage: "star.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isChosen ? Color.white : Color.brandInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(isChosen ? Color.brand : Color.brand.opacity(0.14), in: Capsule())
                if let remaining = gift.remaining {
                    Text(gift.isSoldOut ? L("закончился") : L("осталось \(remaining.formatted(.number.locale(Loc.locale)))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(isChosen ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isChosen ? Color.brand : .clear, lineWidth: 2))
            .opacity(gift.isSoldOut ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityLabel(L("Подарок за \(Self.stars(gift.stars))"))
    }

    private func send() {
        guard let chosen else { return }
        guard Dialogs.confirm(L("Подарить за \(Self.stars(chosen.stars))?"),
                              message: L("Звёзды спишутся с баланса сразу. Подарок получит \(name.isEmpty ? L("собеседник") : name); вернуть его нельзя."),
                              action: L("Подарить")) else { return }
        isSending = true
        error = ""
        Task {
            let problem = await model.sendGift(chosen, to: userId, text: text, isPrivate: isPrivate)
            isSending = false
            if let problem {
                error = problem
            } else {
                model.showToast(L("Подарок отправлен"))
                dismiss()
            }
        }
    }

    static func stars(_ count: Int) -> String {
        TD.count(count, L("звезда"), L("звезды"), L("звёзд"))
    }
}
