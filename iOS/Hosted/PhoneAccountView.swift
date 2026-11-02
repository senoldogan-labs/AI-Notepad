import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar'ın en üstündeki hesap satırı: giriş yapan kimlik ve plan durumu; dokununca hesap ekranı açılır.
struct PhoneAccountRow: View {
    let account: HostedAccount

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .appFont(size: 34, weight: .regular)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: phoneIdentityTitle(identity: account.signedInIdentity))
                    .appFont(size: 16, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(verbatim: phoneAccountSummary(state: account.state))
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Kimliğin başlığı: e-posta; bilinmiyorsa giriş sağlayıcısı, o da bilinmiyorsa "Hesap". Saf fonksiyondur.
func phoneIdentityTitle(identity: HostedSignInIdentity?) -> String {
    if let email = identity?.email {
        return email
    }
    switch identity?.provider {
    case .apple: return String(localized: "Apple ile giriş yapıldı")
    case .google: return String(localized: "Google ile giriş yapıldı")
    case nil: return String(localized: "Hesap")
    }
}

/// Hesap satırının alt yazısı: plan durumu ya da hesabın okunamama nedeni. Saf fonksiyondur.
func phoneAccountSummary(state: HostedAccountState) -> String {
    switch state {
    case .loading:
        String(localized: "Hesap okunuyor…")
    case .signedOut:
        String(localized: "Giriş yapılmadı")
    case .signedIn(let entitlements):
        phonePlanStatusText(status: hostedPlanStatus(entitlements: entitlements))
    case .signedInStatusUnknown:
        String(localized: "Hesap durumu şu an okunamıyor.")
    case .unavailable(let message):
        message
    }
}

/// Hesap ekranı: giriş yapan kimlik, plan durumu (deneme, abonelik), bu ayki kullanım, çıkış ve hesap silme. Satın alma,
/// ödeme ya da müşteri portalı bağlantısı yoktur (App Store 3.1.1); hesap silme uygulama içindedir (App Store
/// 5.1.1(v)) ve satır içinde onaylanır.
struct PhoneAccountScreen: View {
    let account: HostedAccount
    /// Kayıt ya da işleme sürüyor: çıkış ve hesap silme kapalı (süren toplantının sunucu oturumu başka hesaba ya da
    /// silinmiş hesaba yazılmasın; bitince açılır).
    let isMeetingInFlight: Bool
    @State private var confirmingDelete: Bool = false

    var body: some View {
        List {
            Section {
                PhoneAccountRow(account: account)
            }
            switch account.state {
            case .loading:
                Section { ProgressView() }
            case .unavailable(let message):
                Section {
                    NoticeText(message as String, severity: .error)
                }
            case .signedOut:
                Section {
                    PhoneProviderButtons(account: account)
                        .listRowBackground(Color.clear)
                }
            case .signedIn(let entitlements):
                planSection(entitlements: entitlements)
                usageSection(entitlements: entitlements)
                signOutSection
                deleteSection
            case .signedInStatusUnknown(let message):
                Section {
                    Text("Giriş yapıldı; hesap durumu şu an okunamıyor. Bağlantı gelince kendiliğinden yenilenir.")
                    NoticeText(message as String, severity: .attention)
                    Button("Yeniden dene") { Task { await account.refresh() } }
                        .disabled(account.isWorking)
                } header: {
                    Text("Plan")
                }
                signOutSection
            }
            if account.errorMessage != nil {
                Section {
                    PhoneAccountErrorText(account: account)
                }
            }
            Section {
                PhoneLegalLinks()
            }
        }
        .navigationTitle("Hesap")
        .navigationBarTitleDisplayMode(.inline)
        .task { await account.refresh() }
    }

    @ViewBuilder
    private func planSection(entitlements: HostedEntitlements) -> some View {
        let status: HostedPlanStatus = hostedPlanStatus(entitlements: entitlements)
        Section {
            Text(verbatim: phonePlanStatusText(status: status))
            if case .trial(let left, let total) = status, left > 0 {
                LabeledContent("Kalan ücretsiz toplantı", value: "\(left) / \(total)")
                if let endsAt = entitlements.trialEndsAt {
                    LabeledContent("Deneme bitişi", value: hostedDayText(date: endsAt))
                } else if let days = entitlements.trialDays {
                    Text("Deneme ilk toplantınla başlar ve \(days) gün sürer.")
                        .foregroundStyle(Theme.muted)
                }
            }
        } header: {
            Text("Plan")
        }
    }

    @ViewBuilder
    private func usageSection(entitlements: HostedEntitlements) -> some View {
        let fraction: Double = hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: hostedMonthlyUsageText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap))
                    .monospacedDigit()
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(hostedUsageLevel(fraction: fraction) == .normal ? Color.accentColor : NoticeSeverity.attention.tint)
                    .accessibilityLabel(Text("Kullanım"))
            }
            .padding(.vertical, 4)
        } header: {
            Text("Bu ayki kullanım")
        } footer: {
            Text("Kayıt saatlerin \(hostedResetDayText(now: Date())) tarihinde sıfırlanır.")
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Çıkış yap") { Task { await account.signOut() } }
                .disabled(account.isWorking || isMeetingInFlight)
        } footer: {
            if isMeetingInFlight {
                Text("Kayıt ya da işleme sürüyor; bitince çıkış yapabilirsin.")
            } else {
                Text("Bu iPhone'daki oturumu kapatır; toplantıların ve notların bu iPhone'da kalır.")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            if confirmingDelete {
                NoticeText("Emin misin? Hesabın ve sunucudaki tüm kayıtların kalıcı olarak silinir; bu işlem geri alınamaz.", severity: .error)
                Button("Hesabı kalıcı olarak sil", role: .destructive) {
                    confirmingDelete = false
                    Task { await account.deleteAccount() }
                }
                .disabled(account.isWorking || isMeetingInFlight)
                Button("Vazgeç") { confirmingDelete = false }
            } else {
                Button("Hesabı sil…", role: .destructive) { confirmingDelete = true }
                    .disabled(account.isWorking || isMeetingInFlight)
            }
        } footer: {
            if isMeetingInFlight {
                Text("Kayıt ya da işleme sürüyor; bitince hesabı silebilirsin.")
            } else {
                Text("Hesabın ve sunucudaki tüm kayıtların silinir; etkin bir abonelik varsa hemen iptal edilir. Bu iPhone'daki toplantılar ve notlar silinmez.")
            }
        }
    }
}
