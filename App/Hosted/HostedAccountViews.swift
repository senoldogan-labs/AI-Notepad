import AINotepadCore
import AINotepadUI
import SwiftUI

/// "Apple ile devam et" (siyah hap, Apple logosu) ve "Google ile devam et" (beyaz hap, renkli "G"): seçilen sağlayıcı
/// uygulama içi giriş penceresinde doğrudan açılır. Pencere açıkken iki düğme de kapalıdır; açılan sağlayıcının
/// düğmesinde bekleme göstergesi döner. Giriş kapısında, kurulumda ve Ayarlar › Hesap'ta aynı.
struct HostedProviderButtons: View {
    let account: HostedAccount
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await account.signIn(provider: .apple) }
            } label: {
                label(provider: .apple, title: Text("Apple ile devam et")) {
                    Image(systemName: "apple.logo")
                        .appFont(size: 15, weight: .medium)
                }
            }
            .buttonStyle(.pillPrimary)
            Button {
                Task { await account.signIn(provider: .google) }
            } label: {
                label(provider: .google, title: Text("Google ile devam et")) {
                    Image("brand-google")
                        .resizable()
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.pill)
        }
        .controlSize(.large)
        .disabled(account.isWorking || account.pendingBrowserSignIn != nil)
    }

    /// Düğme içeriği: logo (pencere bu sağlayıcıyla açıksa bekleme göstergesi) ve yazı, ortalanmış.
    private func label(provider: HostedSignInProvider, title: Text, @ViewBuilder logo: () -> some View) -> some View {
        HStack(spacing: 10) {
            if account.pendingSignInProvider == provider {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                logo()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            title
        }
        .frame(width: width)
    }
}

/// Giriş: Apple ya da Google düğmesi giriş penceresini açar, pencere kapanınca giriş tamamlanır (Developer ID ile
/// dağıtılan uygulama Apple ile girişi kendisi yapamaz; giriş sitede). Kurulumda ve Ayarlar › Hesap'ta aynı.
struct HostedSignInPanel: View {
    let account: HostedAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3 toplantı ya da ilk toplantından itibaren 7 gün ücretsiz; anahtar gerekmez. Sonrası aylık ya da yıllık abonelikle.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HostedProviderButtons(account: account, width: 240)
            HostedSignInHint(account: account)
            HostedAccountError(account: account)
        }
    }
}

/// Düğmelerin altındaki kısa açıklama: pencere açılmadan önce ne olacağı, açıkken nasıl vazgeçileceği.
struct HostedSignInHint: View {
    let account: HostedAccount

    var body: some View {
        Text(account.pendingBrowserSignIn == nil
            ? "Güvenli bir giriş penceresi açılır; parolan Apple'da ya da Google'da kalır."
            : "Giriş penceresinde devam et. Vazgeçersen pencereyi kapatman yeter.")
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Son hesap işleminin hatası.
struct HostedAccountError: View {
    let account: HostedAccount

    var body: some View {
        if let message = account.errorMessage {
            NoticeText(message as String, severity: .error)
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Ayarlar › Hesap: giriş, deneme sayacı ya da abonelik durumu, aylık kullanım, ödeme, çıkış ve hesap silme.
struct HostedAccountSettings: View {
    let account: HostedAccount
    /// Kayıt, işleme ya da içe aktarma sürüyor: çıkış ve hesap silme kapalıdır (süren toplantının sunucu oturumu ve
    /// faturası başka hesaba ya da silinmiş hesaba yazılmasın; bitince açılır).
    let isMeetingInFlight: Bool
    /// Bu Mac'te silinen hesabın toplantılarını giriş yapan hesaba taşır (bkz. `AppModel.moveDeletedAccountMeetings`).
    let onMoveDeletedMeetings: @MainActor () -> Void
    /// Hesap silme satır içinde onaylanır (açılır pencere yok).
    @State private var confirmingDelete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch account.state {
            case .loading:
                ProgressView().controlSize(.small).padding(.vertical, 16)
            case .unavailable(let message):
                SettingsCard {
                    SettingsRow(icon: "exclamationmark.triangle", title: Text("Hesap kullanılamıyor")) {
                        NoticeText(message as String, severity: .error)
                    } control: {
                        EmptyView()
                    }
                }
                .padding(.top, 26)
            case .signedOut:
                HostedSignInPanel(account: account)
                    .padding(.top, 26)
                    .padding(.bottom, 16)
            case .signedIn(let entitlements):
                signedIn(entitlements: entitlements)
            case .signedInStatusUnknown(let message):
                SettingsGroup(title: Text("Abonelik")) {
                    SettingsRow(icon: "creditcard", title: Text("Plan")) {
                        Text("Giriş yapıldı; hesap durumu şu an okunamıyor. Bağlantı gelince kendiliğinden yenilenir.")
                        NoticeText(message as String, severity: .attention)
                    } control: {
                        Button("Yeniden dene") { Task { await account.refresh() } }
                            .disabled(account.isWorking)
                    }
                } footer: {
                    // Çıkış Ayarlar'ın sol sütununun altında (`HostedSettingsSignOut`).
                    HostedAccountError(account: account)
                }
            }
        }
        .task {
            await account.refresh()
            await account.loadReferral()
        }
    }

    @ViewBuilder
    private func signedIn(entitlements: HostedEntitlements) -> some View {
        let status: HostedPlanStatus = hostedPlanStatus(entitlements: entitlements, now: Date())
        // iPhone'dan (App Store) alınan abonelik yalnızca Apple'da yönetilir: Stripe portalı ve kart güncelleme yok.
        let appStoreManaged: Bool = isHostedAppStoreManaged(entitlements: entitlements)
        // Stripe abonesinin geçebileceği katman (Pro sunulmuyorsa Kişisel abone için nil: görünüm bugünkü gibi).
        let tierSwitch: HostedTier? = hostedStripeTierSwitchTarget(entitlements: entitlements)
        SettingsGroup(title: Text("Abonelik")) {
            SettingsRow(icon: "creditcard", title: Text("Plan")) {
                // Erişimi olan aboneliğin planı (aylık ya da yıllık); bitmiş abonelikte ve ücretsiz erişimde gösterilmez.
                if let subscription = entitlements.subscription, subscription.access != .none, !subscription.complimentary, let plan = subscription.billingPlan,
                   let tier = subscription.subscriptionTier {
                    Text(verbatim: hostedPlanLineText(tier: tier, plan: plan))
                        .foregroundStyle(Theme.ink)
                }
                switch status {
                case .trial:
                    // Kalan toplantılar, bitiş ve "Abone ol" aşağıdaki kullanım kartında.
                    Text("Ücretsiz deneme")
                case .subscribed(let renewsAt):
                    Text("Abonelik etkin; dönem \(hostedDayText(date: renewsAt)) tarihinde yenilenir.")
                case .complimentary:
                    // Bitiş tarihli ücretsiz erişimde (sunucu bitişi `cancelAt`'e yazar) erişim o gün kendiliğinden biter: tarih
                    // önceden görünür.
                    if let until = entitlements.subscription?.cancelAt {
                        Text("Ücretsiz tam erişim: ödeme yok; \(hostedDayText(date: until)) tarihine kadar.")
                            .foregroundStyle(Theme.ink)
                    } else {
                        Text("Ücretsiz tam erişim: ödeme ve yenileme yok.")
                            .foregroundStyle(Theme.ink)
                    }
                case .ending(let endsAt):
                    Text("Abonelik iptal edildi; \(hostedDayText(date: endsAt)) tarihine kadar kullanabilirsin, yenilenmez.")
                case .grace(let endsAt):
                    if appStoreManaged {
                        NoticeText("Apple ödemeyi alamadı; erişimin \(hostedDayText(date: endsAt)) tarihine kadar sürer. iPhone'da Ayarlar › Apple Hesabı'ndan ödeme yöntemini güncelle.", severity: .attention)
                    } else {
                        NoticeText("Ödeme alınamadı; erişimin \(hostedDayText(date: endsAt)) tarihine kadar sürer. \"Hesabı yönet\"ten kartını güncelle.", severity: .attention)
                    }
                case .expired(let endedAt):
                    Text("Aboneliğin \(hostedDayText(date: endedAt)) tarihinde sona erdi; toplantıların ve notların bu Mac'te.")
                case .paymentOverdue:
                    NoticeText("Ödeme alınamadı; kartını güncelleyene dek yeni toplantı başlatılamaz. \"Hesabı yönet\"ten kartını güncelle.", severity: .attention)
                }
                if appStoreManaged {
                    Text("Aboneliğin iPhone'dan (App Store) alındı. iPhone'da Ayarlar › Apple Hesabı › Abonelikler'den yönetebilir ya da iptal edebilirsin.")
                        .foregroundStyle(Theme.muted)
                    // App Store aboneliğinin katmanı yalnızca iPhone'da (uygulama içi satın almayla) değişir; iPhone'daki
                    // "Planı değiştir" yalnızca Pro satıştayken görünür.
                    if hostedProOffer(entitlements: entitlements) != nil {
                        Text("Kişisel ve Pro arasında iPhone'daki \(appName) uygulamasından geçebilirsin: Hesap › Planı değiştir.")
                            .foregroundStyle(Theme.muted)
                    }
                }
                switch tierSwitch {
                case .pro:
                    if let pro = hostedProOffer(entitlements: entitlements) {
                        Text("Pro ile ayda \(hostedHoursNumberText(hours: pro.monthlyHours)) saat kayıt. Geçiş hemen olur: Stripe bu dönemin kalan farkını alır, tutarı onaylamadan önce görürsün.")
                            .foregroundStyle(Theme.muted)
                    }
                case .personal:
                    Text("Kişisel plana geçince aylık kayıt sınırın düşer; kullanılmayan Pro süresi sonraki faturalarından düşülür. Tutarı onaylamadan önce Stripe'ta görürsün.")
                        .foregroundStyle(Theme.muted)
                case nil:
                    EmptyView()
                }
            } control: {
                HStack(spacing: 8) {
                    if let target = tierSwitch, let plan = entitlements.subscription?.billingPlan {
                        Button(target == .pro ? LocalizedStringKey("Pro'ya geç") : LocalizedStringKey("Kişisel plana geç")) {
                            Task { await account.changePlan(tier: target, plan: plan) }
                        }
                        .disabled(account.isWorking)
                    }
                    // Ücretsiz erişimde ve App Store aboneliğinde Stripe'ta yönetilecek bir şey yoktur.
                    if let subscription = entitlements.subscription, !subscription.complimentary, !appStoreManaged {
                        Button("Hesabı yönet") { Task { await account.manageSubscription() } }
                            .disabled(account.isWorking)
                    }
                }
            }
            HostedUsageCard(account: account, entitlements: entitlements)
            switch status {
            case .subscribed, .complimentary, .ending, .grace:
                HostedReferralRow(account: account)
            case .trial, .expired, .paymentOverdue:
                EmptyView()
            }
        }
        // Eşitleme Veri ve gizlilik'te, çıkış Ayarlar'ın sol sütununun altında.
        SettingsGroup(title: Text("Hesap")) {
            HostedDeletedMeetingsRow(deleted: .shared, onMove: onMoveDeletedMeetings)
            SettingsRow(icon: "trash", title: Text("Hesabı sil")) {
                SettingsMoreText(
                    summary: Text("Hesabın, aboneliğin ve sunucudaki kayıtların silinir; bu Mac'teki notlar kalır."),
                    details: Text("Hesabın, aboneliğin (hemen iptal edilir) ve sunucudaki tüm kayıtların silinir. Bu Mac'teki toplantılar ve notlar silinmez; bu Mac'te yeniden hesap açarsan yeni hesabına taşıyabilirsin.")
                )
                // Apple aboneliği hesapla birlikte iptal edilemez; Apple iptal edilene dek ücret almaya devam eder.
                if entitlements.appStoreSubscription?.willRenew == true {
                    NoticeText("App Store aboneliğin hesabı silince iptal olmaz; Apple ücret almaya devam eder. Önce iPhone'da Ayarlar › Apple Hesabı › Abonelikler'den iptal et.", severity: .attention)
                }
                if isMeetingInFlight {
                    NoticeText("Kayıt ya da işleme sürüyor; bitince hesabı silebilirsin.", severity: .attention)
                } else if confirmingDelete {
                    NoticeText("Emin misin? Bu işlem geri alınamaz.", severity: .error)
                }
            } control: {
                HStack(spacing: 8) {
                    if confirmingDelete {
                        Button("Vazgeç") { confirmingDelete = false }
                        Button("Hesabı kalıcı olarak sil", role: .destructive) {
                            confirmingDelete = false
                            Task { await account.deleteAccount() }
                        }
                        .disabled(account.isWorking || isMeetingInFlight)
                    } else {
                        Button("Hesabı sil…", role: .destructive) { confirmingDelete = true }
                            .disabled(account.isWorking || isMeetingInFlight)
                    }
                }
            }
        } footer: {
            HostedAccountError(account: account)
        }
    }
}

/// Ayarlar'ın sol sütununun altındaki çıkış (oturum varken; hak durumu okunamasa da çıkış yapılabilir): düğme ve altında
/// ne olduğu ya da neden kapalı olduğu, satır içinde.
struct HostedSettingsSignOut: View {
    let account: HostedAccount
    let isMeetingInFlight: Bool

    var body: some View {
        switch account.state {
        case .signedIn, .signedInStatusUnknown:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    Task { await account.signOut() }
                } label: {
                    Label("Çıkış yap", systemImage: "rectangle.portrait.and.arrow.right")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .disabled(account.isWorking || isMeetingInFlight)
                Group {
                    if isMeetingInFlight {
                        Text("Kayıt ya da işleme sürüyor; bitince çıkış yapabilirsin.")
                    } else {
                        Text("Toplantıların ve notların bu Mac'te kalır.")
                    }
                }
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            }
        case .loading, .signedOut, .unavailable:
            EmptyView()
        }
    }
}

/// Ayarlar'ın sol sütunundaki plan kartı: durgun pastel gradyan üstünde planın adı ve tek cümlesi; tıklayınca Plan ve
/// faturalandırma açılır. Abonelik yokken (deneme, sona ermiş) "Abone ol" planları açar. Hesap okunamıyorsa ya da
/// yükleniyorsa hesabın durumu yazar.
struct HostedSettingsBanner: View {
    let account: HostedAccount
    let onOpenAccount: @MainActor () -> Void

    var body: some View {
        let status: HostedPlanStatus? = hostedBannerPlanStatus(state: account.state)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onOpenAccount()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: status.map { hostedPlanHeadline(status: $0, tier: hostedBannerTier(state: account.state)) } ?? String(localized: "Hesap"))
                        .appFont(size: 15, weight: .semibold)
                    Text(verbatim: status.map { hostedPlanBannerDetail(status: $0) } ?? hostedAccountSummary(state: account.state))
                        .appFont(size: 11, weight: .regular)
                        .opacity(0.72)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkPointer(isEnabled: true)
            if let status, hostedPlanOffersSubscription(status: status) {
                Button("Abone ol") { account.showPlans() }
                    .buttonStyle(.bannerPrimary)
                    .disabled(account.isWorking)
            }
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(14)
        .background { FilmGradient(seed: "ayarlar-plan", palette: status.map { hostedPlanBannerPalette(status: $0) } ?? .ocean) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Pastel zemin her temada açık: yazı koyu kalır.
        .environment(\.colorScheme, .light)
    }
}
