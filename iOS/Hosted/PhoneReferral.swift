import AINotepadCore
import AINotepadUI
import SwiftUI
import UIKit

/// Hesap ekranındaki "Arkadaşını davet et" bölümü (Mac'teki davet satırının iPhone karşılığı): ne kazandırdığı, davet
/// kodu (dokununca kopyalanır), sayaçlar ve davet metnini iOS paylaşım sayfasıyla gönderen düğme. Yalnızca abonelik
/// erişimi olan ve kodu olan hesapta görünür (sunucu kodu ücretsiz davet ayındaki hesaba vermez). Bağlantı arkadaşa
/// gider; bu uygulamada App Store dışı bir satın alma yolu açılmaz (App Store 3.1.1).
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
                        // Ödül yazılmayan hesapta (ücretsiz erişim, App Store aboneliği) "bir ay al" denmez.
                        Text(referral.complimentary || referral.appStoreBilled == true ? "Arkadaşına ilk ayı hediye et" : "Bir ay ver, bir ay al")
                            .appFont(size: 17, weight: .semibold)
                            .foregroundStyle(Theme.ink)
                    }
                    Text(verbatim: hostedReferralRewardText(referral: referral))
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        UIPasteboard.general.string = code
                        withAnimation(.smooth(duration: 0.2)) { copied = true }
                    } label: {
                        HStack {
                            Text(verbatim: code)
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
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
                    ShareLink(item: hostedInviteText(inviteURL: inviteURL)) {
                        PhonePrimaryButtonLabel(title: "Davet bağlantısını paylaş")
                    }
                    .buttonStyle(.plain)
                    Text(verbatim: hostedReferralStatsText(referral: referral))
                        .appFont(size: 12, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Arkadaşını davet et")
            }
        }
    }
}
