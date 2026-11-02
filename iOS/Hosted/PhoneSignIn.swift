import AINotepadCore
import AINotepadUI
import SwiftUI

/// Giriş kapısı: oturum yokken (ya da hesabın verisi açılmamışken) uygulama yalnızca bunu gösterir — film gradyanlı
/// kart, ad, tek cümlelik tanıtım, "Apple ile devam et" ve "Google ile devam et" (sistemin güvenli giriş sayfasında,
/// sitedeki giriş akışıyla; bkz. `HostedAccount.signIn`), deneme satırı ve gizlilik/koşullar bağlantıları. Sekmeler,
/// toplantılar ve kayıt yoktur. Satın alma yoktur (abonelik girişten sonra, uygulama içi satın almayla).
struct PhoneSignInGate: View {
    let account: HostedAccount

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FilmGradient(seed: "gistsmith-giris", palette: .violet)
                    .overlay(alignment: .bottomLeading) {
                        Text("Toplantılarını dinler, notunu yazar")
                            .appFont(size: 28, weight: .regular)
                            .tracking(-0.5)
                            .foregroundStyle(Color.black.opacity(0.78))
                            .padding(24)
                    }
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .environment(\.colorScheme, .light)
                    .accessibilityElement(children: .combine)
                Text(verbatim: appName)
                    .appFont(size: 34, weight: .regular)
                    .tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                Text("Yüz yüze toplantılarını canlı yazıya döker; bitince notun hazır, görevlerin en üstte.")
                    .appFont(size: 15, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                switch account.state {
                case .unavailable(let message):
                    NoticeText(message as String, severity: .error)
                        .appFont(size: 14, weight: .regular)
                case .loading, .signedOut, .signedIn, .signedInStatusUnknown:
                    VStack(alignment: .leading, spacing: 12) {
                        PhoneProviderButtons(account: account)
                        Text(account.pendingBrowserSignIn == nil
                            ? "Güvenli bir giriş sayfası açılır; parolan Apple'da ya da Google'da kalır."
                            : "Giriş sayfasında devam et. Vazgeçersen sayfayı kapatman yeter.")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Label("İlk 3 toplantı ya da 7 gün ücretsiz", systemImage: "sparkles")
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(Theme.ink)
                            .padding(.top, 2)
                    }
                    .padding(.top, 4)
                }
                PhoneAccountErrorText(account: account)
                PhoneDeletedSubscriptionNotice(account: account)
                PhoneAccountDataNotice(account: account)
                PhoneLegalLinks()
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .task { await account.refresh() }
    }
}

/// "Apple ile devam et" (siyah hap) ve "Google ile devam et" (açık hap, renkli "G"): seçilen sağlayıcı sistemin giriş
/// sayfasında doğrudan açılır. Sayfa açıkken iki düğme de kapalıdır; açılan sağlayıcının düğmesinde bekleme göstergesi
/// döner. Giriş kapısında ve Ayarlar › Hesap'ta aynı.
struct PhoneProviderButtons: View {
    let account: HostedAccount

    var body: some View {
        VStack(spacing: 10) {
            Button {
                Task { await account.signIn(provider: .apple) }
            } label: {
                label(provider: .apple, title: Text("Apple ile devam et")) {
                    Image(systemName: "apple.logo").font(.system(size: 17, weight: .medium))
                }
                .foregroundStyle(Color.white)
                .background(Color.black, in: Capsule())
            }
            Button {
                Task { await account.signIn(provider: .google) }
            } label: {
                label(provider: .google, title: Text("Google ile devam et")) {
                    Image("brand-google").resizable().frame(width: 18, height: 18)
                }
                .foregroundStyle(Theme.ink)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line))
            }
        }
        .buttonStyle(PressableCardStyle())
        .disabled(account.isWorking || account.pendingBrowserSignIn != nil)
    }

    /// Düğme içeriği: logo (sayfa bu sağlayıcıyla açıksa bekleme göstergesi) ve yazı, ortalanmış, tam genişlik.
    private func label(provider: HostedSignInProvider, title: Text, @ViewBuilder logo: () -> some View) -> some View {
        HStack(spacing: 10) {
            if account.pendingSignInProvider == provider {
                ProgressView().frame(width: 18, height: 18)
            } else {
                logo().frame(width: 18, height: 18).accessibilityHidden(true)
            }
            title.appFont(size: 16, weight: .semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
    }
}

/// Hesap silindi ama App Store aboneliği sürüyor (sunucunun silme yanıtı): Apple onu hesapla birlikte iptal etmez.
/// Yenilenecekse kullanıcıya iptal etmesi söylenir ve Apple'ın abonelik penceresi buradan açılır.
private struct PhoneDeletedSubscriptionNotice: View {
    let account: HostedAccount
    @State private var manageError: String?

    var body: some View {
        if let subscription = account.deletedAppStoreSubscription, subscription.willRenew {
            VStack(alignment: .leading, spacing: 8) {
                NoticeText(
                    String(localized: "Hesabın silindi, ama App Store aboneliğin iptal olmadı: Apple \(hostedDayText(date: subscription.expiresAt)) tarihinde yeniden ücret alır. Aboneliği şimdi iptal et.") as String,
                    severity: .attention
                )
                .appFont(size: 13, weight: .regular)
                Button("Aboneliği yönet") {
                    Task {
                        manageError = nil
                        do {
                            try await showAppStoreManageSubscriptions()
                        } catch let error as AppStorePurchaseError {
                            manageError = appStorePurchaseMessage(error: error)
                        } catch {
                            manageError = String(localized: "Apple'ın abonelik penceresi açılamadı: \(userFacingMessage(error: error))")
                        }
                    }
                }
                .appFont(size: 15, weight: .semibold)
                if let manageError {
                    NoticeText(manageError as String, severity: .error)
                        .appFont(size: 13, weight: .regular)
                }
            }
        }
    }
}

/// Son hesap işleminin hatası (giriş, çıkış, silme).
struct PhoneAccountErrorText: View {
    let account: HostedAccount

    var body: some View {
        if let message = account.errorMessage {
            NoticeText(message as String, severity: .error)
                .appFont(size: 13, weight: .regular)
        }
    }
}

/// Giriş yapılmış ama hesabın verisi açılmamışsa nedeni: önceki toplantılar hesaba taşınamadı ("Yeniden dene"; hiçbir
/// şey silinmedi) ya da bu açılışta başka bir hesabın verisi yüklü (iOS uygulaması kendini yeniden başlatamaz).
private struct PhoneAccountDataNotice: View {
    let account: HostedAccount

    var body: some View {
        if account.hasSession == true {
            switch account.dataState {
            case .notLoaded, .loaded:
                EmptyView()
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    NoticeText(message as String, severity: .error)
                        .appFont(size: 13, weight: .regular)
                    Button("Yeniden dene") { account.retryAccountData() }
                        .appFont(size: 14, weight: .medium)
                }
            case .relaunchRequired:
                NoticeText("Başka bir hesapla giriş yaptın. Bu hesabın toplantılarını açmak için Gistsmith'i uygulama değiştiriciden kapatıp yeniden aç.", severity: .info)
                    .appFont(size: 13, weight: .regular)
            }
        }
    }
}

/// Gizlilik ve koşullar (sitede).
struct PhoneLegalLinks: View {
    var body: some View {
        HStack(spacing: 16) {
            if let privacy = phoneLegalURL(path: "privacy") {
                Link("Gizlilik", destination: privacy)
            }
            if let terms = phoneLegalURL(path: "terms") {
                Link("Koşullar", destination: terms)
            }
        }
        .appFont(size: 13, weight: .regular)
        .foregroundStyle(Theme.muted)
    }
}

/// İlk yapay zekâ işleminden önce bir kez (girişten hemen sonra, kayıt ve Sor açılmadan): toplantı sesinin ve metninin
/// hizmetimize ve üçüncü taraf yapay zekâ sağlayıcılarına (konuşma için Deepgram ve ElevenLabs, not için Anthropic
/// Claude) gönderileceğini açıkça söyler; "Devam et" ile kabul edilir (App Store 5.1.2(i)). Kabul etmeyen çıkış
/// yapabilir; hiçbir şey gönderilmez.
struct PhoneAIDisclosure: View {
    let account: HostedAccount
    let onAccept: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "lock.shield")
                    .appFont(size: 34, weight: .regular)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Toplantıların nasıl işlenir")
                    .appFont(size: 30, weight: .regular)
                    .tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Yazıya dökme ve not için toplantının sesi ve metni hizmetimize ve aşağıdaki yapay zekâ sağlayıcılarına gönderilir.")
                    .appFont(size: 15, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 14) {
                    disclosureRow(
                        symbol: "waveform",
                        title: "Konuşma: Deepgram ve ElevenLabs",
                        text: "Kayıt sırasında ses canlı metin için Deepgram'a gider. Kayıt bitince ses, konuşmacıları ayırmak ve metni tamamlamak için sunucumuz üzerinden ElevenLabs'e gönderilir."
                    )
                    disclosureRow(
                        symbol: "sparkles",
                        title: "Not, çeviri ve Sor: Anthropic Claude",
                        text: "Toplantı metni not, canlı çeviri ve Sor cevapları için sunucumuz üzerinden Anthropic'in Claude modeline gönderilir."
                    )
                    disclosureRow(
                        symbol: "iphone",
                        title: "Toplantıların bu iPhone'da",
                        text: "Sunucumuz ses ve not saklamaz; kullanım sınırları için yalnızca süre ve kullanım sayıları tutulur."
                    )
                }
                .padding(16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
                if let privacy = phoneLegalURL(path: "privacy") {
                    Link(destination: privacy) {
                        Label("Gizlilik politikasını oku", systemImage: "arrow.up.right.square")
                            .appFont(size: 14, weight: .medium)
                    }
                }
                Button {
                    onAccept()
                } label: {
                    Text("Devam et")
                        .appFont(size: 16, weight: .semibold)
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Theme.primary, in: Capsule())
                }
                .buttonStyle(PressableCardStyle())
                .padding(.top, 4)
                Button("Çıkış yap") { Task { await account.signOut() } }
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .disabled(account.isWorking)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
    }

    private func disclosureRow(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .appFont(size: 16, weight: .medium)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).appFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                Text(text).appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
