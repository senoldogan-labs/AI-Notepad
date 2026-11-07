import AINotepadCore
import AINotepadUI
import SwiftUI

/// Giriş kapısı: oturum yokken (ya da hesabın verisi açılmamışken) uygulama yalnızca bunu gösterir — ortada başlığı olan
/// simgeli pastel kart, ad ve tek cümlelik tanıtım, deneme satırı, "Apple ile devam et" ve "Google ile devam et" (sistemin
/// güvenli giriş sayfasında, sitedeki giriş akışıyla; bkz. `HostedAccount.signIn`) ve gizlilik/koşullar bağlantıları;
/// hepsi ortalı. İçerik en az ekran boyundadır: büyük iPhone'da düğmeler alta yaslanır, artan boy ad bloğunun iki
/// yanına bölünür; küçükte kaydırılır. Sekmeler, toplantılar ve kayıt yoktur. Satın alma yoktur (abonelik girişten
/// sonra, uygulama içi satın almayla).
struct PhoneSignInGate: View {
    let account: HostedAccount
    /// Başka bir hesapla giriş yapıldıysa hesap değişiminin beklediği, eski hesabın verisine yazan işler.
    let switchWaitsFor: [AccountDataWriter]
    /// Hesap hizmeti kullanılamıyorken "Yeniden dene"ye basıldı, okuma sürüyor.
    @State private var isRetrying: Bool = false

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ScrollView {
                VStack(spacing: 0) {
                    PhoneHeroCard(
                        seed: "gistsmith-giris", palette: .violet,
                        height: phoneHeroHeight(screenHeight: proxy.size.height, ratio: 0.38, minimum: 180, maximum: 340)
                    ) {
                        // Karşılamanın ilk sayfasıyla aynı simgeler: dinler, yazıya döker, görevleri çıkarır.
                        VStack(spacing: 22) {
                            OnboardingSymbolRow(symbols: ["mic.fill", "captions.bubble.fill", "checklist"])
                            Text("Toplantılarını dinler, notunu yazar")
                                .appFont(size: 28, weight: .regular)
                                .tracking(-0.5)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .foregroundStyle(Color.black.opacity(0.78))
                    }
                    // Artan boy kartın altı ile düğmelerin üstü arasında bölünür: ad ve tanıtım ortada kalır.
                    Spacer(minLength: 28)
                    VStack(spacing: 8) {
                        Text(verbatim: appName)
                            .appFont(size: 34, weight: .regular)
                            .tracking(-0.6)
                            .foregroundStyle(Theme.ink)
                        Text("Yüz yüze toplantılarını canlı yazıya döker; bitince notun hazır, görevlerin en üstte.")
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 32)
                    actions
                    VStack(spacing: 10) {
                        PhoneAccountErrorText(account: account)
                        PhoneDeletedSubscriptionNotice(account: account)
                        PhoneAccountDataNotice(account: account, switchWaitsFor: switchWaitsFor)
                    }
                    .padding(.top, 12)
                    // Denemenin sözü gizlilik ve koşulların hemen üstünde; zeminsiz, alttaki açıklamalarla aynı yazı.
                    PhoneTrialLine()
                        .padding(.top, 20)
                    PhoneLegalLinks()
                        .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await account.refresh() }
    }

    /// Giriş düğmeleri ve güvenli giriş açıklaması; hesap hizmeti kullanılamıyorsa yalnızca nedeni.
    @ViewBuilder
    private var actions: some View {
        switch account.state {
        case .unavailable(let message):
            // Okuma geçici olarak olmayabilir (ör. Anahtar Zinciri cihazın ilk kilit açılışından önce okunamaz): yeniden
            // denenir; uygulama öne gelince de kendiliğinden yeniden okunur (`HostedAccount.readUnknownStatus`).
            VStack(spacing: 12) {
                NoticeText(message as String, severity: .error)
                    .appFont(size: 14, weight: .regular)
                    .frame(maxWidth: .infinity)
                Button {
                    Task {
                        isRetrying = true
                        await account.refresh()
                        isRetrying = false
                    }
                } label: {
                    PhonePrimaryButtonLabel(title: "Yeniden dene")
                }
                .buttonStyle(.plain)
                .disabled(isRetrying)
            }
        case .loading, .signedOut, .signedIn, .signedInStatusUnknown:
            VStack(spacing: 16) {
                PhoneProviderButtons(account: account)
                Text(account.pendingBrowserSignIn == nil
                    ? "Güvenli bir giriş sayfası açılır; parolan Apple'da ya da Google'da kalır."
                    : "Giriş sayfasında devam et. Vazgeçersen sayfayı kapatman yeter.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "İlk 3 toplantı ya da 7 gün ücretsiz": zeminsiz, simgesiz soluk yazı (alttaki açıklamalarla aynı), ortalı; gizlilik
/// ve koşul bağlantılarının hemen üstünde durur.
private struct PhoneTrialLine: View {
    var body: some View {
        Text("İlk 3 toplantı ya da 7 gün ücretsiz")
            .appFont(size: 13, weight: .regular)
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
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
                    Image(systemName: "apple.logo").font(.system(.body, weight: .medium))
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
/// şey silinmedi) ya da başka bir hesabın verisi yüklü ve hesap, o hesabın süren işi bitince kendiliğinden değişecek.
private struct PhoneAccountDataNotice: View {
    let account: HostedAccount
    let switchWaitsFor: [AccountDataWriter]

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
            case .switchPending:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    NoticeText(phoneAccountSwitchNotice(waitingFor: switchWaitsFor) as String, severity: .info)
                        .appFont(size: 13, weight: .regular)
                }
            }
        }
    }
}

/// Başka bir hesapla giriş yapılınca hesap değişiminin metni: beklenen bir iş yoksa hesap açılıyor; varsa eski hesabın
/// hangi işi bittiğinde bu hesabın toplantılarının kendiliğinden açılacağı (kayıt önce, sonra işleme, içe aktarma, not,
/// Sor). Saf fonksiyondur.
func phoneAccountSwitchNotice(waitingFor writers: [AccountDataWriter]) -> String {
    if writers.contains(.recording) {
        return String(localized: "Önceki hesabın kaydı sürüyor. Kayıt bitip toplantı işlenince bu hesabın toplantıları kendiliğinden açılır.")
    }
    if writers.contains(.processing) || writers.contains(.offlineQueue) {
        return String(localized: "Önceki hesabın toplantısı işleniyor. Bitince bu hesabın toplantıları kendiliğinden açılır.")
    }
    if writers.contains(.importing) {
        return String(localized: "Önceki hesaba bir dosya içe aktarılıyor. Bitince bu hesabın toplantıları kendiliğinden açılır.")
    }
    if writers.contains(.noteEditing) {
        return String(localized: "Önceki hesabın bir notu yazılıyor. Bitince bu hesabın toplantıları kendiliğinden açılır.")
    }
    if writers.contains(.askAnswering) {
        return String(localized: "Önceki hesabın Sor cevabı yazılıyor. Bitince bu hesabın toplantıları kendiliğinden açılır.")
    }
    return String(localized: "Bu hesabın toplantıları açılıyor…")
}

/// Gizlilik ve koşullar (sitede): ortalı, araya ince nokta; zemini yoktur (listede de satır zemini kaldırılır).
struct PhoneLegalLinks: View {
    var body: some View {
        HStack(spacing: 10) {
            if let privacy = phoneLegalURL(path: "privacy") {
                Link("Gizlilik", destination: privacy)
            }
            Text(verbatim: "·")
                .accessibilityHidden(true)
            if let terms = phoneLegalURL(path: "terms") {
                Link("Koşullar", destination: terms)
            }
        }
        .appFont(size: 13, weight: .regular)
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// İlk yapay zekâ işleminden önce bir kez (girişten hemen sonra, kayıt ve Sor açılmadan): toplantı sesinin ve metninin
/// hizmetimize ve güvenilir üçüncü taraf yapay zekâ hizmetlerine (konuşma tanıma ve not yazma) gönderileceğini, neyin
/// neden gittiğini açıkça söyler; hizmetlerin adları uygulamada geçmez, gizlilik politikasında (sitede) listelenir.
/// "Devam et" ile açıkça kabul edilir (App Store 5.1.2(i)). Kabul etmeyen çıkış yapabilir; hiçbir şey gönderilmez.
struct PhoneAIDisclosure: View {
    let account: HostedAccount
    let onAccept: @MainActor () -> Void

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ScrollView {
                VStack(spacing: 0) {
                    PhoneHeroCard(
                        seed: "gistsmith-aciklama", palette: .violet,
                        height: phoneHeroHeight(screenHeight: proxy.size.height, ratio: 0.14, minimum: 96, maximum: 132)
                    ) {
                        Image(systemName: "lock.shield.fill")
                            .appFont(size: 28, weight: .regular)
                            .foregroundStyle(.tint)
                            .frame(width: 66, height: 66)
                            .background(Color.white.opacity(0.9), in: Circle())
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                            .accessibilityHidden(true)
                    }
                    VStack(spacing: 10) {
                        Text("Toplantıların nasıl işlenir")
                            .appFont(size: 28, weight: .regular)
                            .tracking(-0.5)
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text("Yazıya dökme ve not için toplantının sesi ve metni hizmetimize ve güvenilir üçüncü taraf yapay zekâ hizmetlerine gönderilir.")
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
                    VStack(alignment: .leading, spacing: 16) {
                        disclosureRow(
                            symbol: "waveform",
                            title: "Konuşma tanıma",
                            text: "Toplantının sesi canlı metin, konuşmacıları ayırma ve yazıya dökme için bir konuşma tanıma hizmetine gönderilir."
                        )
                        disclosureRow(
                            symbol: "sparkles",
                            title: "Not, çeviri ve Sor",
                            text: "Toplantının metni not, canlı çeviri ve Sor cevapları için sunucumuz üzerinden bir yapay zekâ dil modeline gönderilir."
                        )
                        disclosureRow(
                            symbol: "iphone",
                            title: "Toplantıların bu iPhone'da",
                            text: "Sunucumuz ses saklamaz, notlarını da yalnızca yapay zekâ asistanı erişimini açarsan saklar; kullanım sınırları için süre ve kullanım sayıları tutulur."
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 22)
                    Text("Kullanılan hizmetler gizlilik politikasında adlarıyla listelenir.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // Onay alta sabit: küçük iPhone'da maddeler kaysa da "Devam et" ve "Çıkış yap" hep görünür.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                consent
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    /// Açık onay: gizlilik politikası bağlantısı, ne olacağının tek cümlesi, "Devam et" ve "Çıkış yap".
    private var consent: some View {
        VStack(spacing: 10) {
            if let privacy = phoneLegalURL(path: "privacy") {
                Link(destination: privacy) {
                    Label("Gizlilik politikasını oku", systemImage: "arrow.up.right")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(.tint)
                }
            }
            Text("Devam edersen toplantıların bu şekilde işlenir. İstemezsen çıkış yap; hiçbir şey gönderilmez.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onAccept()
            } label: {
                PhonePrimaryButtonLabel(title: "Devam et")
            }
            .buttonStyle(PressableCardStyle())
            Button("Çıkış yap") { Task { await account.signOut() } }
                .appFont(size: 14, weight: .medium)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .disabled(account.isWorking)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(Theme.background)
        .overlay(alignment: .top) {
            // Kayan maddelerle onay alanını ayıran ince çizgi.
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    /// Bir madde: vurgu renginde simge (hafif vurgu zeminli kare), başlık ve kısa açıklama.
    private func disclosureRow(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .appFont(size: 16, weight: .semibold)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).appFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                Text(text).appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
