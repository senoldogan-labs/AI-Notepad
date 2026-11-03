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

/// Hesap ekranı: giriş yapan kimlik, plan ve kullanım kartı (deneme ya da abonelik; `PhoneUsageCard`), aboneliği yönetme,
/// arkadaş daveti (abonede), çıkış ve hesap silme. Ekran açılınca hak durumu ve davet bilgisi yeniden okunur; satın alma
/// ya da geri yüklemeden sonra ve uygulama öne gelince de hak durumu yenilenir (`HostedAccount`). Abonelik yalnızca uygulama içi satın almayla alınır (abonelik ekranı); App Store
/// aboneliği Apple'ın penceresinde yönetilir, web (Stripe) aboneliği için bağlantı verilmez (App Store 3.1.1). Hesap
/// silme uygulama içindedir (App Store 5.1.1(v)) ve satır içinde onaylanır.
struct PhoneAccountScreen: View {
    let account: HostedAccount
    /// Hesabın verisine yazan bir iş sürüyor (kayıt, işleme, içe aktarma, not ya da Sor; bkz. `phoneOpenWriters`): çıkış
    /// ve hesap silme kapalı (süren işin toplantısı ya da sunucu oturumu başka hesaba ya da silinmiş hesaba yazılmasın;
    /// bitince açılır).
    let isMeetingInFlight: Bool
    @State private var confirmingDelete: Bool = false
    /// Apple'ın abonelik penceresi açılamadıysa nedeni.
    @State private var manageError: String?

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
                Section {
                    PhoneUsageCard(account: account, entitlements: entitlements)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                // Denemede ve sona ermiş abonelikte kartın kendisi durumu ve "Abone ol"u gösterir.
                if phoneSubscriptionManagement(entitlements: entitlements) != .subscribe {
                    planSection(entitlements: entitlements)
                }
                switch hostedPlanStatus(entitlements: entitlements) {
                case .subscribed, .complimentary, .ending, .grace:
                    PhoneReferralSection(account: account)
                case .trial, .expired, .paymentOverdue:
                    EmptyView()
                }
                signOutSection
                deleteSection(entitlements: entitlements)
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
            // Bağlantılar listenin altında zeminsiz ve tam ortada durur (kart değil).
            Section {
                PhoneLegalLinks()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("Hesap")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await account.refresh()
            await account.loadReferral()
        }
    }

    /// Plan durumu ve aboneliğin yönetimi. Denemede ve sona ermiş abonelikte "Abone ol" kullanım kartındadır.
    @ViewBuilder
    private func planSection(entitlements: HostedEntitlements) -> some View {
        let status: HostedPlanStatus = hostedPlanStatus(entitlements: entitlements)
        Section {
            Text(verbatim: phonePlanStatusText(status: status))
            switch phoneSubscriptionManagement(entitlements: entitlements) {
            case .appStore:
                Button("Aboneliği yönet") { Task { await manageSubscription() } }
                    .disabled(account.isWorking)
            case .web:
                Text("Aboneliğin web'de (kartla) alındı; Mac uygulamasında Ayarlar › Hesap › Hesabı yönet'ten yönetebilirsin.")
                    .foregroundStyle(Theme.muted)
            case .subscribe, .nothing:
                EmptyView()
            }
            if let manageError {
                NoticeText(manageError as String, severity: .error)
            }
        } header: {
            Text("Plan")
        } footer: {
            if phoneSubscriptionManagement(entitlements: entitlements) == .appStore {
                Text("Planı değiştirmek ya da iptal etmek için \"Aboneliği yönet\"e dokun.")
            }
        }
    }

    /// Apple'ın abonelik penceresini açar; kapanınca hak durumu yenilenir (iptal ya da plan değişikliği görünsün).
    private func manageSubscription() async {
        manageError = nil
        do {
            try await showAppStoreManageSubscriptions()
        } catch let error as AppStorePurchaseError {
            manageError = appStorePurchaseMessage(error: error)
        } catch {
            manageError = String(localized: "Apple'ın abonelik penceresi açılamadı: \(userFacingMessage(error: error))")
        }
        await account.refresh()
    }

    private var signOutSection: some View {
        Section {
            Button("Çıkış yap") { Task { await account.signOut() } }
                .disabled(account.isWorking || isMeetingInFlight)
        } footer: {
            if isMeetingInFlight {
                Text("Kayıt, içe aktarma ya da yapay zekâ işi sürüyor; bitince çıkış yapabilirsin.")
            } else {
                Text("Toplantıların ve notların bu iPhone'da kalır.")
            }
        }
    }

    private func deleteSection(entitlements: HostedEntitlements) -> some View {
        let effect: HostedDeletionSubscriptionEffect = hostedDeletionSubscriptionEffect(entitlements: entitlements)
        return Section {
            if confirmingDelete {
                NoticeText("Emin misin? Hesabın ve sunucudaki tüm kayıtların kalıcı olarak silinir; bu işlem geri alınamaz.", severity: .error)
                if let note = phoneDeletionSubscriptionText(effect: effect) {
                    NoticeText(note as String, severity: phoneDeletionKeepsAppStoreRenewing(effect: effect) ? .attention : .info)
                }
                if phoneDeletionKeepsAppStoreRenewing(effect: effect) {
                    Button("Aboneliği yönet") { Task { await manageSubscription() } }
                }
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
                Text("Kayıt, içe aktarma ya da yapay zekâ işi sürüyor; bitince hesabı silebilirsin.")
            } else if !confirmingDelete {
                Text("Hesabın ve sunucudaki kayıtların silinir; bu iPhone'daki toplantılar kalır.")
            }
        }
    }
}

/// Silme onayında aboneliğe ne olacağı; süren abonelik yoksa nil. Saf fonksiyondur.
func phoneDeletionSubscriptionText(effect: HostedDeletionSubscriptionEffect) -> String? {
    switch effect {
    case .none:
        nil
    case .stripeCanceled:
        String(localized: "Web aboneliğin hemen iptal edilir.")
    case .appStoreKeepsRenewing:
        String(localized: "App Store aboneliğin hesabı silince iptal olmaz; Apple ücret almaya devam eder. Önce \"Aboneliği yönet\"ten iptal et.")
    case .appStoreEnding:
        String(localized: "App Store aboneliğin zaten yenilenmeyecek; yeniden ücret alınmaz.")
    case .stripeCanceledAppStoreKeepsRenewing:
        String(localized: "Web aboneliğin hemen iptal edilir. App Store aboneliğin ise iptal olmaz; Apple ücret almaya devam eder. Önce \"Aboneliği yönet\"ten iptal et.")
    }
}

/// Silmeden sonra Apple'ın ücret almaya devam edeceği App Store aboneliği var mı. Saf fonksiyondur.
func phoneDeletionKeepsAppStoreRenewing(effect: HostedDeletionSubscriptionEffect) -> Bool {
    switch effect {
    case .appStoreKeepsRenewing, .stripeCanceledAppStoreKeepsRenewing:
        true
    case .none, .stripeCanceled, .appStoreEnding:
        false
    }
}
