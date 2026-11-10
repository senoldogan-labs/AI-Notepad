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
    /// Oturum yokken bir bağlantı (`gistsmith://…`) geldi: girişten sonra açılacağı söylenir.
    let isLinkWaiting: Bool
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
                        if isLinkWaiting {
                            NoticeText("Bağlantıyı açmak için giriş yap; giriş yapınca açılır.", severity: .info)
                                .appFont(size: 13, weight: .regular)
                                .frame(maxWidth: .infinity)
                        }
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
                    // Girişte takılan biri bize ulaşabilsin (sitenin iletişim sayfası).
                    if let contact = phoneLegalURL(path: "contact") {
                        Link("Giriş yapamıyor musun? Yardım al", destination: contact)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 6)
                    }
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
                    Image(systemName: "apple.logo").appFont(size: 17, weight: .medium)
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

/// The third-party AI disclosure (App Review 5.1.1(i) / 5.1.2(i)): before the first AI request (after sign-in, before
/// the app) and whenever an AI feature is used without consent (a sheet). It names each service, what is sent and why,
/// how it is protected, links the privacy policy and asks "Kabul ediyorum" / "Şimdi değil". Nothing is sent until the user
/// agrees (`HostedAIConsentCenter`); "Not now" opens the app with AI features off. Settings › Veri ve paylaşım shows it
/// again with the state and a withdraw button (`PhoneAIDisclosureReview`).
struct PhoneAIDisclosure: View {
    let consent: HostedAIConsentCenter
    @State private var isAgreeing: Bool = false

    var body: some View {
        PhoneAIDisclosureContent()
            // The choice stays pinned at the bottom: on a small iPhone the list scrolls, the buttons stay visible.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                choice
            }
            .background(Theme.background.ignoresSafeArea())
            .interactiveDismissDisabled()
    }

    /// Privacy policy link, what "Not now" means, "Kabul ediyorum" and "Şimdi değil".
    private var choice: some View {
        VStack(spacing: 10) {
            PhoneAIPrivacyPolicyLink()
            if let message = consent.errorMessage {
                NoticeText(message, severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                isAgreeing = true
                Task {
                    await consent.grant()
                    isAgreeing = false
                }
            } label: {
                PhonePrimaryButtonLabel(title: "Kabul ediyorum")
            }
            .buttonStyle(PressableCardStyle())
            .disabled(isAgreeing)
            Button("Şimdi değil") { consent.decline() }
                .appFont(size: 15, weight: .medium)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(isAgreeing)
            Text("Onay vermezsen hiçbir şey gönderilmez: kayıt, Sor ve notlar kapalı kalır, toplantılarını yine açabilirsin.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(Theme.background)
        .overlay(alignment: .top) {
            // Thin line between the scrolling list and the pinned choice.
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }
}

/// Settings › Veri ve paylaşım › "Yapay zekâ hizmetleri": the same disclosure with the current state and the way to
/// change it (agree, or withdraw after a confirmation). Withdrawing waits while a recording, import or AI job runs: a
/// live transcript stream already open would otherwise keep sending audio until the meeting ends.
struct PhoneAIDisclosureReview: View {
    let consent: HostedAIConsentCenter
    let isMeetingInFlight: Bool
    @State private var isWorking: Bool = false
    @State private var isConfirmingWithdrawal: Bool = false

    var body: some View {
        PhoneAIDisclosureContent()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    Label(consent.isGranted ? "Açık: toplantıların bu hizmetlerle işlenir." : "Kapalı: hiçbir şey gönderilmez.",
                          systemImage: consent.isGranted ? "checkmark.circle.fill" : "pause.circle")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(consent.isGranted ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
                    PhoneAIPrivacyPolicyLink()
                    if let message = consent.errorMessage {
                        NoticeText(message, severity: .error)
                            .appFont(size: 12, weight: .regular)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if consent.isGranted {
                        Button("Onayı geri çek", role: .destructive) { isConfirmingWithdrawal = true }
                            .appFont(size: 15, weight: .medium)
                            .foregroundStyle(NoticeSeverity.error.tint)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(isWorking || isMeetingInFlight)
                        if isMeetingInFlight {
                            Text("Kayıt ya da yapay zekâ işi sürerken onay geri çekilemez; bitince geri çekebilirsin.")
                                .appFont(size: 12, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Button {
                            isWorking = true
                            Task {
                                await consent.grant()
                                isWorking = false
                            }
                        } label: {
                            PhonePrimaryButtonLabel(title: "Kabul ediyorum")
                        }
                        .buttonStyle(PressableCardStyle())
                        .disabled(isWorking)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Theme.background)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Onay geri çekilsin mi?", isPresented: $isConfirmingWithdrawal, titleVisibility: .visible) {
                Button("Onayı geri çek", role: .destructive) {
                    isWorking = true
                    Task {
                        await consent.withdraw()
                        isWorking = false
                    }
                }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Kayıt, Sor ve notlar hemen durur; bekleyen kayıtlar bu iPhone'da kalır ve yeniden onay verince işlenir.")
            }
    }
}

/// "Gizlilik politikasını oku" (on the site).
private struct PhoneAIPrivacyPolicyLink: View {
    var body: some View {
        if let privacy = phoneLegalURL(path: "privacy") {
            Link(destination: privacy) {
                Label("Gizlilik politikasını oku", systemImage: "arrow.up.right")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// The disclosure's content: cover, title, what goes to which service and why, and how it is protected. The services'
/// names are not translated (same text as the privacy policy, section 3 "Third-party AI services and your permission").
private struct PhoneAIDisclosureContent: View {
    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ScrollView {
                VStack(spacing: 0) {
                    PhoneHeroCard(
                        seed: "gistsmith-aciklama", palette: .violet,
                        height: phoneHeroHeight(screenHeight: proxy.size.height, ratio: 0.12, minimum: 84, maximum: 116)
                    ) {
                        Image(systemName: "lock.shield.fill")
                            .appFont(size: 26, weight: .regular)
                            .foregroundStyle(.tint)
                            .frame(width: 60, height: 60)
                            .background(Color.white.opacity(0.9), in: Circle())
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Yapay zekâ hizmetleri ve verin")
                            .appFont(size: 28, weight: .regular)
                            .tracking(-0.5)
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text("Gistsmith toplantılarını yazıya dökmek, not yazmak ve sorularını cevaplamak için aşağıdaki üçüncü taraf yapay zekâ hizmetlerine veri gönderir. Onay vermeden hiçbir şey gönderilmez.")
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
                    VStack(alignment: .leading, spacing: 18) {
                        serviceRow(
                            symbol: "waveform", name: "Deepgram", purpose: "Canlı metin",
                            text: "Kayıt sırasında toplantının sesi, canlı metin için doğrudan bu iPhone'dan gönderilir."
                        )
                        serviceRow(
                            symbol: "person.2.wave.2", name: "ElevenLabs", purpose: "Transkript ve konuşmacılar",
                            text: "Toplantı bitince kaydın sesi ve içe aktardığın ses ya da video dosyaları, konuşmacılara ayrılmış transkript için sunucumuz üzerinden gönderilir."
                        )
                        serviceRow(
                            symbol: "sparkles", name: "Anthropic (Claude)", purpose: "Not, çeviri ve cevaplar",
                            text: "Transkript, notlar ve kendi notların; Sor'a, Gistsmith Klavye'ye ya da Siri'ye yazdığın veya söylediğin sorular; eklediğin kişi adları ve terimler; ayarı açarsan nota eklediğin fotoğraflar sunucumuz üzerinden gönderilir. Sor'da web araması açıksa aramayı da Anthropic yapar."
                        )
                        protectionRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// One service: accent symbol, its name (never translated) with what it does, and what is sent.
    private func serviceRow(symbol: String, name: String, purpose: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .appFont(size: 16, weight: .semibold)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name).appFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                Text(purpose).appFont(size: 12, weight: .semibold).foregroundStyle(.tint)
                Text(text).appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// How the data is protected and how to withdraw.
    private var protectionRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .appFont(size: 16, weight: .semibold)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Korunması").appFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                Text("Sunucumuz ses saklamaz. Bu hizmetler verini yalnızca bizim için işler, modellerini eğitmekte kullanmaz ve sınırlı bir süre sonra siler; gizlilik politikamızdakiyle aynı ya da eşdeğer koruma sağlar. Onayını istediğin zaman Ayarlar › Veri ve paylaşım'dan geri çekebilirsin.")
                    .appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
