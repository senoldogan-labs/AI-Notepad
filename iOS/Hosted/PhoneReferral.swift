import AINotepadCore
import AINotepadUI
import SwiftUI
import UIKit

/// Hesap ekranındaki "Arkadaşını davet et" bölümü (Mac'teki davet satırının iPhone karşılığı): davet kodu (dokununca
/// kopyalanır), katılan arkadaş sayısı ve davet metnini iOS paylaşım sayfasıyla gönderen düğme. Yalnızca abonelik
/// erişimi olan ve kodu olan hesapta görünür (sunucu kodu ücretsiz davet ayındaki hesaba vermez). Metinler (paylaşılan
/// davet dahil) web'den, fiyattan, indirimden ya da ödülden söz etmez: iPhone'da App Store dışı bir satın almaya
/// yönlendirilmez (App Store 3.1.1, 3.1.3). Ödül ve indirim Mac'te anlatılır.
struct PhoneReferralSection: View {
    let account: HostedAccount
    @State private var copied: Bool = false

    var body: some View {
        if let referral = account.referral, referral.enabled, let code = referral.code, let inviteURL = referral.inviteUrl {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "gift.fill")
                            .appFont(size: 18, weight: .semibold)
                            .foregroundStyle(.tint)
                            .frame(width: 40, height: 40)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityHidden(true)
                        Text("Gistsmith'i arkadaşlarınla paylaş")
                            .appFont(size: 17, weight: .semibold)
                            .foregroundStyle(Theme.ink)
                    }
                    Text("Davet bağlantını ya da kodunu arkadaşına gönder; katılanlar burada sayılır.")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        UIPasteboard.general.string = code
                        withAnimation(.smooth(duration: 0.2)) { copied = true }
                    } label: {
                        HStack {
                            Text(verbatim: code)
                                .appMonoFont(size: 20, weight: .semibold)
                                .tracking(3)
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .appFont(size: 13, weight: .medium)
                                .foregroundStyle(.tint)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Davet kodunu kopyala"))
                    .sensoryFeedback(.success, trigger: copied) { (_: Bool, new: Bool) -> Bool in new }
                    // "Kopyalandı" kısa süre sonra "Kopyala"ya döner (yoksa ekranda hep kopyalanmış kalıyordu).
                    .task(id: copied) {
                        guard copied else {
                            return
                        }
                        do {
                            try await Task.sleep(for: .seconds(2))
                        } catch {
                            return
                        }
                        withAnimation(.smooth(duration: 0.2)) { copied = false }
                    }
                    ShareLink(item: phoneInviteText(inviteURL: inviteURL)) {
                        PhonePrimaryButtonLabel(title: "Davet bağlantısını paylaş")
                    }
                    .buttonStyle(.plain)
                    Text("Katılan arkadaş: \(referral.joined)")
                        .appFont(size: 12, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 6)
                // The same invite link as a QR code, for a friend standing next to you (`PhoneShareAppScreen`).
                NavigationLink(value: PhoneRoute.shareApp) {
                    PhoneSettingLabel(icon: "qrcode", title: Text("QR kodunu göster"))
                }
            } header: {
                PhoneSecondaryText {
                    Text("Arkadaşını davet et")
                }
            }
        }
    }
}

/// iPhone'dan paylaşılan davet metni (bağlantı dahil): yalnızca uygulamanın ne yaptığı; web'den, fiyattan ya da
/// indirimden söz etmez (App Store 3.1.1, 3.1.3; Mac'teki metin `hostedInviteText`). Saf fonksiyondur.
func phoneInviteText(inviteURL: URL) -> String {
    String(localized: "Toplantılarım için Gistsmith kullanıyorum: konuşulanı canlı yazıya döküyor, toplantı bitince notu ve görevleri hazırlıyor. Sen de bak: \(inviteURL.absoluteString)")
}
