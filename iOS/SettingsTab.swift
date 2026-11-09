import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar (ana ekrandaki profil simgesinden; Mac'teki gruplarla aynı sırada): üstte plan kartı (plan durumu, denemede
/// "Abone ol") ve gizlenmediyse "Mac için Gistsmith" satırı (tanıtım sayfası bunun üstünde açılır), sonra Hesap (profil, plan ve faturalandırma, eşitleme), Özellikler (her biri kendi sayfasında: kayıt ve
/// diller, notlar, canlı çeviri ve Sor, takvim, bildirimler, bağlantılar, yapay zekâ asistanı, beceriler, telefon
/// görüşmesi), Görünüm, Destek, Veri ve paylaşım, çıkış ve en altta sürüm. Her satırda vurgu renkli simge kutusu ve
/// gerekirse tek cümlelik açıklama.
struct PhoneSettingsTab: View {
    let store: PhoneStore
    let account: HostedAccount
    let router: PhoneRouter
    /// Hesabın verisine yazan bir iş sürüyor (bkz. `phoneOpenWriters`): çıkış, hesap silme ve kurulum kapalı.
    let isMeetingInFlight: Bool
    let crashReports: CrashReportCenter
    @AppStorage(PhoneSettingsKey.audioRetentionDays) private var retentionDays: Int = 30
    /// Kısalan saklama süresi eski sesleri hemen siler: onay bekleyen seçim.
    @State private var pendingRetention: PendingAudioRetention?
    @AppStorage(PhoneSettingsKey.theme) private var theme: String = AppTheme.system.rawValue
    @AppStorage(shareUsageStatisticsDefaultsKey) private var shareUsageStatistics: Bool = true
    /// Toplantılar Spotlight'ta (ve Siri'de) görünsün mü.
    @AppStorage(spotlightMeetingsSettingKey) private var showsInSpotlight: Bool = true
    /// "Kurulumu yeniden aç" bunu kapatır: kök görünüm karşılamayı yeniden sunar.
    @AppStorage(PhoneSettingsKey.onboardingCompleted) private var onboardingCompleted: Bool = true
    @Environment(\.openURL) private var openURL: OpenURLAction
    /// "Telefon görüşmesi" rehberi kökteki içe aktarma sunumunda açılır.
    @Environment(PhoneImportState.self) private var imports: PhoneImportState

    /// Saklama süresi seçimi: süre kısalıp eski sesler hemen silinecekse önce sorulur (`pendingRetention`).
    private var retentionSelection: Binding<Int> {
        Binding<Int>(
            get: { retentionDays },
            set: { (days: Int) -> Void in
                let count: Int = audioDeletedByRetentionChange(records: store.meetings, now: Date(), setting: days).count
                if count > 0 {
                    pendingRetention = PendingAudioRetention(days: days, meetingCount: count)
                } else {
                    retentionDays = days
                }
            }
        )
    }

    /// Çıkış yapılabilecek bir oturum var (hak durumu okunamasa da).
    private var hasSession: Bool {
        switch account.state {
        case .signedIn, .signedInStatusUnknown: true
        case .loading, .signedOut, .unavailable: false
        }
    }

    var body: some View {
        List {
            CrashReportNotice(center: crashReports)
            Section {
                PhoneSettingsPlanBanner(account: account)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            PhoneMacAppBanner(router: router)
            accountSection
            PhoneSyncSection()
            featuresSection
            appearanceSection
            supportSection
            dataSection
            if hasSession {
                signOutSection
            }
            versionFooter
        }
        // Kayan satırlar durum çubuğunun ve başlığın arkasında yarı saydam görünmesin: üst kenar sert biter.
        .hardTopScrollEdge()
        .navigationTitle("Ayarlar")
        .sheet(isPresented: Binding<Bool>(get: { router.isMacAppIntroOpen }, set: { router.isMacAppIntroOpen = $0 })) {
            PhoneMacAppSheet()
        }
    }

    private var accountSection: some View {
        Section {
            // Profil (ad, unvan, şirket); altında giriş yapılan e-posta.
            NavigationLink(value: PhoneRoute.profile) {
                PhoneProfileRow(store: store, account: account)
            }
            // Plan, kullanım, aboneliği yönet, arkadaş daveti ve hesap silme; ana ekrandaki engel bildiriminin "Kullanımı
            // gör"ü de burayı açar (`PhoneRouter.openAccount`).
            NavigationLink(value: PhoneRoute.account) {
                PhoneSettingLabel(icon: "creditcard", title: Text("Plan ve faturalandırma"))
            }
        } header: {
            Text("Hesap")
        }
    }

    private var featuresSection: some View {
        Section {
            ForEach(PhoneSettingsPage.allCases, id: \.self) { (page: PhoneSettingsPage) in
                NavigationLink(value: PhoneRoute.settingsPage(page)) {
                    PhoneSettingLabel(icon: page.icon, title: Text(page.title)) {
                        Text(page.summary)
                    }
                }
            }
            PhoneConnectionsRow()
            // Sunucu sunmuyorsa görünmez (bkz. `PhoneAssistantRow`).
            PhoneAssistantRow()
            Button {
                imports.request = .phoneCall
            } label: {
                PhoneSettingLabel(icon: "phone", title: Text("Telefon görüşmesi")) {
                    Text("Görüşmenin notunu almanın yolları.")
                }
            }
            .tint(Theme.ink)
        } header: {
            Text("Özellikler")
        }
    }

    private var appearanceSection: some View {
        Section {
            NavigationLink {
                PhoneAppearanceScreen()
            } label: {
                PhoneAppearanceRow(theme: theme)
            }
            // Arayüz dili iOS'ta uygulama başına iPhone Ayarları'ndan seçilir (Mac'te uygulamanın içinden): satır
            // uygulamanın Ayarlar sayfasını açar, sağdaki simge uygulamadan çıkıldığını gösterir.
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Button {
                    openURL(settings)
                } label: {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(verbatim: interfaceLanguageName())
                            Image(systemName: "arrow.up.forward.app")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                        }
                    } label: {
                        PhoneSettingLabel(icon: "globe", title: Text("Arayüz dili"))
                    }
                }
                .tint(Theme.ink)
                .accessibilityHint(Text("iPhone Ayarları'nı açar"))
            }
        } header: {
            Text("Görünüm")
        } footer: {
            Text("Arayüz dili iPhone Ayarları › \(appName) › Dil'den değişir. Dil satırı yoksa önce iPhone Ayarları › Genel › Dil ve Bölge'ye ikinci bir dil ekle.")
        }
    }

    private var supportSection: some View {
        Section {
            NavigationLink {
                PhoneFeedbackForm(account: account, store: store)
            } label: {
                PhoneSettingLabel(icon: "bubble.left.and.text.bubble.right", title: Text("Geri bildirim gönder"))
            }
            if let contact = phoneLegalURL(path: "contact") {
                Link(destination: contact) {
                    PhoneSettingLabel(icon: "envelope", title: Text("Bize ulaş"))
                }
                .tint(Theme.ink)
            }
            if let review = URL(string: phoneAppStoreReviewLink) {
                Link(destination: review) {
                    PhoneSettingLabel(icon: "star", title: Text("App Store'da değerlendir"))
                }
                .tint(Theme.ink)
            }
            NavigationLink {
                PhoneDiagnosticsScreen(account: account, store: store)
            } label: {
                PhoneSettingLabel(icon: "stethoscope", title: Text("Tanılama"))
            }
            // Mac'teki "Kurulumu yeniden aç": karşılama (ad, ana toplantı dili) baştan gösterilir. Kayıt ya da işleme
            // sürerken kapalı (karşılama tam ekran açılır).
            Button {
                // Karşılama baştan açılır (kaldığı adım silinir).
                UserDefaults.standard.removeObject(forKey: onboardingStepKey)
                onboardingCompleted = false
            } label: {
                PhoneSettingLabel(icon: "arrow.counterclockwise", title: Text("Kurulumu yeniden aç"))
            }
            .tint(Theme.ink)
            .disabled(isMeetingInFlight)
        } header: {
            Text("Destek")
        }
    }

    private var dataSection: some View {
        Section {
            PhoneSettingMenuRow(icon: "waveform.badge.minus", title: "Sesleri sakla", selection: retentionSelection, options: audioRetentionChoices.map { (days: Int) -> MenuPickerOption<Int> in
                MenuPickerOption(value: days, label: days == audioRetentionNever ? Text("Hiç silme") : Text("\(days) gün"))
            })
            .onChange(of: retentionDays) { (_: Int, _: Int) in
                store.applyRetention(now: Date())
            }
            .alert(
                "Sesler silinsin mi?",
                isPresented: Binding<Bool>(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }),
                presenting: pendingRetention
            ) { (pending: PendingAudioRetention) in
                Button("Sesleri sil", role: .destructive) { retentionDays = pending.days }
                Button("Vazgeç", role: .cancel) {}
            } message: { (pending: PendingAudioRetention) in
                Text("\(pending.meetingCount) toplantının sesi şimdi silinecek; metin ve not kalır. Bu geri alınamaz.")
            }
            Toggle(isOn: $showsInSpotlight) {
                PhoneSettingLabel(icon: "magnifyingglass", title: Text("Toplantıları Spotlight'ta göster")) {
                    Text("Ad, tarih, kişiler, özet ve görevler bu iPhone'un aramasına girer; transkript ve ses girmez. Siri ve Kısayollar da toplantılarına buradan ulaşır.")
                }
            }
            .onChange(of: showsInSpotlight) { (_: Bool, _: Bool) in
                MeetingSpotlightIndex.shared.update(records: store.meetings, userName: store.userName, isAllowed: HostedAccount.shared.isAccountDataLoaded && !HostedAccount.shared.requiresSignIn)
            }
            Toggle(isOn: $shareUsageStatistics) {
                PhoneSettingLabel(icon: "chart.bar.xaxis", title: Text("Anonim kullanım istatistiklerini paylaş")) {
                    Text("Yalnızca kullanım sayıları paylaşılır; toplantı içeriği, ses ya da metin paylaşılmaz.")
                }
            }
            .onChange(of: shareUsageStatistics) { (_: Bool, enabled: Bool) in
                if !enabled {
                    HostedTelemetryCenter.shared.sharingDisabled()
                }
            }
            CrashReportsLink(center: crashReports)
            // Girişte onaylanan yapay zekâ açıklaması: neyin nereye gittiği sonradan da okunur.
            NavigationLink {
                PhoneAIDisclosureReview()
            } label: {
                PhoneSettingLabel(icon: "lock.shield", title: Text("Toplantıların nasıl işlenir"))
            }
            if let privacy = phoneLegalURL(path: "privacy") {
                Link(destination: privacy) {
                    PhoneSettingLabel(icon: "hand.raised.square", title: Text("Gizlilik politikası"))
                }
                .tint(Theme.ink)
            }
            // Hesap silme hesap sayfasının en altında, satır içinde onaylanır (hak durumu okunmuşken).
            if case .signedIn = account.state {
                NavigationLink(value: PhoneRoute.account) {
                    PhoneSettingLabel(icon: "trash", title: Text("Hesabı sil")) {
                        Text("Hesabın ve sunucudaki kayıtların silinir; bu iPhone'daki toplantılar kalır.")
                    }
                }
            }
        } header: {
            Text("Veri ve paylaşım")
        } footer: {
            Text("Süre dolunca ses dosyaları silinir; metin ve not kalır.")
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await account.signOut() }
            } label: {
                Text("Çıkış yap")
                    .frame(maxWidth: .infinity)
            }
            .disabled(account.isWorking || isMeetingInFlight)
        } footer: {
            if isMeetingInFlight {
                Text("Kayıt, içe aktarma ya da yapay zekâ işi sürüyor; bitince çıkış yapabilirsin.")
            } else {
                Text("Toplantıların ve notların bu iPhone'da kalır.")
            }
        }
    }

    /// En altta sürüm ve derleme (geri bildirimde ve TestFlight'ta hangi derleme olduğu görünsün) ve toplantı sayısı.
    private var versionFooter: some View {
        Section {
            VStack(spacing: 2) {
                Text(verbatim: "\(appName) \(currentReportDiagnostics(bundle: Bundle.main, platformName: "iOS").appVersion)")
                Text("\(store.meetings.count) toplantı")
            }
            .appFont(size: 13, weight: .regular)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
        }
    }
}

/// App Store'daki "Değerlendir" sayfası (Gistsmith'in App Store kimliği; site `web/src/config.ts` ile aynı).
private let phoneAppStoreReviewLink: String = "https://apps.apple.com/app/id6829577553?action=write-review"

/// Ayarlar'ın üstündeki plan kartı: durgun pastel gradyan üstünde planın adı ve tek cümlesi; dokununca Plan ve
/// faturalandırma açılır. Abonelik yokken (deneme, sona ermiş) "Abone ol" abonelik ekranını açar. Hesap okunamıyorsa ya
/// da yükleniyorsa hesabın durumu yazar.
struct PhoneSettingsPlanBanner: View {
    let account: HostedAccount

    var body: some View {
        let status: HostedPlanStatus? = hostedBannerPlanStatus(state: account.state)
        ZStack {
            // Satırın tamamı sayfayı açar; "Abone ol" kendi düğmesidir (gizli bağlantı satırın dokunuşunu taşır).
            NavigationLink(value: PhoneRoute.account) { EmptyView() }
                .opacity(0)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: status.map { hostedPlanHeadline(status: $0) } ?? String(localized: "Hesap"))
                            .appFont(size: 22, weight: .semibold)
                            .tracking(-0.4)
                        Text(verbatim: status.map { hostedPlanBannerDetail(status: $0) } ?? hostedAccountSummary(state: account.state))
                            .appFont(size: 14, weight: .regular)
                            .opacity(0.72)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .appFont(size: 14, weight: .semibold)
                        .opacity(0.4)
                        .accessibilityHidden(true)
                }
                if let status, hostedPlanOffersSubscription(status: status) {
                    Button("Abone ol") { account.showPlans() }
                        .buttonStyle(.bannerPrimary)
                        .disabled(account.isWorking)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(20)
        }
        .background { FilmGradient(seed: "ayarlar-plan", palette: status.map { hostedPlanBannerPalette(status: $0) } ?? .ocean) }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Pastel zemin her temada açık: yazı koyu kalır.
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
    }
}

/// Ayarlar › Özellikler'den açılan sayfalar (sıra Ayarlar'daki sıradır).
enum PhoneSettingsPage: Hashable, CaseIterable {
    /// Not ve ana toplantı dili, tanıma sözlüğü ve konuşmacılar, kayıt hatırlatması.
    case recording
    /// Not şablonu, galeri, ada göre şablon, notta fotoğraflar.
    case notes
    /// Kayıtta canlı çeviri, "Ne kaçırdım?" ve Sor'da web araması.
    case translation
    case calendar
    case notifications
    /// SKILL.md içe aktarma.
    case skills
    /// Gistsmith Klavye: kurulum, diller, sesle yazma, klavyede toplantı notları.
    case keyboard

    var title: LocalizedStringKey {
        switch self {
        case .recording: "Kayıt ve diller"
        case .notes: "Notlar ve şablonlar"
        case .translation: "Canlı çeviri ve Sor"
        case .calendar: "Takvim"
        case .notifications: "Bildirimler"
        case .skills: "Beceriler"
        case .keyboard: "Klavye"
        }
    }

    /// Ayarlar'daki satırın altındaki kısa açıklama.
    var summary: LocalizedStringKey {
        switch self {
        case .recording: "Diller, tanıma sözlüğü, konuşmacılar ve kayıt hatırlatması."
        case .notes: "Not şablonu, şablon galerisi ve notta fotoğraflar."
        case .translation: "Kayıtta çeviri, \"Ne kaçırdım?\" ve web araması."
        case .calendar: "Sıradaki toplantılar ve toplantı hatırlatması."
        case .notifications: "Not hazır, görev günü ve haftalık özet."
        case .skills: "SKILL.md becerilerini Sor'da tarif olarak kullan."
        case .keyboard: "Her uygulamada sesle yaz ve toplantı notlarını ekle."
        }
    }

    var icon: String {
        switch self {
        case .recording: "waveform"
        case .notes: "doc.text"
        case .translation: "character.bubble"
        case .calendar: "calendar"
        case .notifications: "bell.badge"
        case .skills: "wand.and.stars"
        case .keyboard: "keyboard"
        }
    }
}

/// Ayarlar › Özellikler'deki sayfa: her biri kendi listesinde.
struct PhoneSettingsPageScreen: View {
    let page: PhoneSettingsPage
    let store: PhoneStore
    /// Sor: SKILL.md'den içe aktarılan beceriler onun tariflerine eklenir.
    let ask: PhoneAsk
    let calendar: PhoneCalendar

    var body: some View {
        Group {
            switch page {
            case .recording:
                PhoneRecordingSettingsList(store: store)
            case .notes:
                PhoneNoteSettingsList()
            case .translation:
                PhoneTranslationSettingsList()
            case .calendar:
                List { CalendarSettingsSection(calendar: calendar) }
            case .notifications:
                List { NotificationSettingsSection() }
            case .skills:
                List { PhoneSkillImportSection(ask: ask) }
            case .keyboard:
                PhoneKeyboardSettingsList(store: store)
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Kayıt ve diller: not ve çeviri dili, ana toplantı dili; tanıma sözlüğü ve konuşmacılar (`--ayar konusmacilar` buraya
/// kaydırır); kayıt başlarken haber verme hatırlatması.
private struct PhoneRecordingSettingsList: View {
    let store: PhoneStore
    @AppStorage(PhoneSettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(PhoneSettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue
    @AppStorage(PhoneSettingsKey.consentReminder) private var consentReminder: Bool = true

    var body: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            List {
                Section {
                    PhoneSettingMenuRow(icon: "text.bubble", title: "Not ve çeviri dili", selection: $noteLanguage, options: ShareLanguage.allCases.map { (language: ShareLanguage) -> MenuPickerOption<String> in
                        MenuPickerOption(value: language.rawValue, label: Text(verbatim: language.interfaceTitle))
                    })
                    PhoneSettingMenuRow(icon: "waveform", title: "Ana toplantı dili", selection: $primaryLanguage, options: MeetingLanguage.allCases.map { (language: MeetingLanguage) -> MenuPickerOption<String> in
                        MenuPickerOption(value: language.rawValue, label: Text(languageName(language: language)))
                    })
                } header: {
                    Text("Dil")
                } footer: {
                    Text("Notlar, canlı çeviri ve Sor cevapları not ve çeviri dilinde yazılır.")
                }
                PhoneVoiceSettingsSection(voices: store.voices) {
                    NavigationLink {
                        // Sözlük hesabındır (bkz. `PhoneStore.vocabulary`): aynı iPhone'daki başka hesap görmez.
                        PhoneTextSettingScreen(
                            title: "Tanıma sözlüğü",
                            help: "Doğru yazılması gereken adlar ve terimler; satır başına bir tane, en fazla 30.",
                            load: { () -> String in store.vocabulary },
                            save: { (value: String) -> Void in store.setVocabulary(text: value) }
                        )
                    } label: {
                        LabeledContent {
                            Text("\(customVocabulary(text: store.vocabulary).count) terim")
                        } label: {
                            PhoneSettingLabel(icon: "character.book.closed", title: Text("Tanıma sözlüğü"))
                        }
                    }
                }
                .id(PhoneSettingsSectionID.speakers)
                Section {
                    PhoneAudioInputRow()
                    Toggle(isOn: $consentReminder) {
                        PhoneSettingLabel(icon: "hand.raised", title: Text("Kayıt başlarken haber vermeyi hatırlat")) {
                            Text("Kayıttan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur.")
                        }
                    }
                } header: {
                    Text("Kayıt")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: automaticAudioInputHelp())
                        Text("Teams/Zoom görüşmeleri için Mac'i kullan.")
                    }
                }
            }
            .onAppear {
                // Görsel kontrol: `--ayar konusmacilar` ile açılınca o bölüme kaydırılır.
                if launchSettingsSection(arguments: CommandLine.arguments) == PhoneSettingsSectionID.speakers {
                    proxy.scrollTo(PhoneSettingsSectionID.speakers, anchor: .top)
                }
            }
        }
    }
}

/// Notlar ve şablonlar: yeni notların şablonu, kendi şablonun, şablon galerisi, ada göre şablon ve notta fotoğraflar.
private struct PhoneNoteSettingsList: View {
    @AppStorage(PhoneSettingsKey.noteTemplate) private var noteTemplate: String = NoteTemplateKind.general.rawValue
    @AppStorage(PhoneSettingsKey.customTemplate) private var customTemplate: String = ""
    @AppStorage(PhoneSettingsKey.customTemplateName) private var customTemplateName: String = ""
    @AppStorage(PhoneSettingsKey.templateFromTitle) private var templateFromTitle: Bool = true
    /// "Notta fotoğrafları kullan" (Mac'teki "Notlarda ekran görüntülerini kullan" ile aynı anahtar).
    @AppStorage(PhoneSettingsKey.screenNotes) private var usesPhotosInNotes: Bool = false

    var body: some View {
        List {
            Section {
                PhoneSettingMenuRow(icon: "doc.text", title: "Not şablonu", selection: $noteTemplate, options: NoteTemplateKind.allCases.map { (kind: NoteTemplateKind) -> MenuPickerOption<String> in
                    MenuPickerOption(value: kind.rawValue, label: Text(verbatim: kind == .custom ? customTemplateDisplayName(name: customTemplateName) : kind.displayName))
                })
                if noteTemplate == NoteTemplateKind.custom.rawValue {
                    NavigationLink(value: PhoneRoute.customTemplate) {
                        LabeledContent {
                            Text(customTemplate.isEmpty ? LocalizedStringKey("Boş") : LocalizedStringKey("Yazıldı"))
                        } label: {
                            PhoneSettingLabel(icon: "pencil.line", title: Text("Kendi şablonun"))
                        }
                    }
                }
                NavigationLink(value: PhoneRoute.templateGallery) {
                    PhoneSettingLabel(icon: "square.grid.2x2", title: Text("Şablon galerisi")) {
                        Text("Hazır şablonlara göz at, kullan ya da kopyasını düzenle.")
                    }
                }
                Toggle(isOn: $templateFromTitle) {
                    PhoneSettingLabel(icon: "wand.and.stars", title: Text("Şablonu toplantı adına göre seç")) {
                        Text("Ad türü gösteriyorsa (ör. \"1:1\", \"Daily\", \"Mülakat\") o şablon kullanılır; kendi şablonun hep geçerli.")
                    }
                }
                Toggle(isOn: $usesPhotosInNotes) {
                    PhoneSettingLabel(icon: "camera.viewfinder", title: Text("Notta fotoğrafları kullan")) {
                        Text("Notta en fazla 6, Sor'da en fazla 3 fotoğraf küçültülüp sunucumuz üzerinden Anthropic'e (Claude) gönderilir; sunucumuz saklamaz. Kapalıyken fotoğraflar bu iPhone'dan çıkmaz.")
                    }
                }
            } header: {
                Text("Not")
            } footer: {
                Text("Yeni notlar bu şablonla yazılır; eski bir notu ⋯ menüsünden yeniden yazabilirsin.")
            }
        }
    }
}

/// Canlı çeviri ve Sor: kayıt sırasında not diline çeviri ve gösterimi, "Ne kaçırdım?" süresi, Sor'da web araması.
private struct PhoneTranslationSettingsList: View {
    @AppStorage(PhoneSettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue
    @AppStorage(PhoneSettingsKey.displayMode) private var displayMode: String = DisplayMode.bilingual.rawValue
    @AppStorage(PhoneSettingsKey.missedWindowMinutes) private var missedMinutes: Int = 3
    /// Sor'da web araması (varsayılan açık; `askWebSearchAllowed` okur).
    @AppStorage(askWebSearchSettingKey) private var askWebSearch: Bool = true

    var body: some View {
        // Seçili not dilinin adı (arayüz dilinde): çeviri ayarlarında geçer.
        let noteLanguageName: String = phoneStoredNoteLanguage(value: noteLanguage).interfaceName
        let translates: Bool = (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation
        List {
            Section {
                Toggle(isOn: Binding<Bool>(
                    get: { translates },
                    set: { (enabled: Bool) -> Void in displayMode = (enabled ? DisplayMode.bilingual : .originalOnly).rawValue }
                )) {
                    PhoneSettingLabel(icon: "character.bubble", title: Text("Kayıt sırasında \(noteLanguageName) diline çevir"))
                }
                if translates {
                    PhoneSettingMenuRow(icon: "rectangle.split.2x1", title: "Gösterim", selection: $displayMode, options: [
                        MenuPickerOption(value: DisplayMode.bilingual.rawValue, label: Text("İki dil (orijinal + \(noteLanguageName))")),
                        MenuPickerOption(value: DisplayMode.turkishOnly.rawValue, label: Text("Sadece \(noteLanguageName)")),
                    ])
                }
                Stepper(value: $missedMinutes, in: missedWindowMinutesRange) {
                    PhoneSettingLabel(icon: "clock.arrow.circlepath", title: Text("\"Ne kaçırdım?\" son \(missedMinutes) dakikayı özetler"))
                }
                Toggle(isOn: $askWebSearch) {
                    PhoneSettingLabel(icon: "magnifyingglass", title: Text("Sor'da web aramasına izin ver")) {
                        Text("Toplantılarda olmayan bilgi için cevap başına en çok 3 arama; web arama hizmetine yalnızca kısa arama sorgusu gider.")
                    }
                }
            } header: {
                Text("Canlı çeviri ve Sor")
            } footer: {
                Text(translates
                    ? "Cümleler kayıt sırasında \(noteLanguageName) diline çevrilir; ✦ özetler ve soruları yanıtlar."
                    : "Kayıtta yalnız orijinal metin görünür; \(noteLanguageName) not yine yazılır.")
            }
        }
    }
}

/// Ayarlar'da `--ayar` ile kaydırılabilen bölümlerin kimlikleri.
private enum PhoneSettingsSectionID {
    static let speakers: String = "konusmacilar"
}

/// Takvim: varsayılan kapalı; açılınca iOS izni sorar. İzin yoksa nedeni ve iPhone Ayarları'na giden düğme görünür.
/// Takvim açıkken toplantıdan 1 dk önce hatırlatma açılabilir (bildirim izni o an sorulur).
private struct CalendarSettingsSection: View {
    let calendar: PhoneCalendar
    @AppStorage(PhoneSettingsKey.calendarEnabled) private var isEnabled: Bool = false
    @AppStorage(PhoneSettingsKey.meetingReminders) private var remindersEnabled: Bool = false
    /// İzin isteniyor (iOS sorusu açık).
    @State private var isRequesting: Bool = false
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        Section {
            Toggle(isOn: Binding<Bool>(
                get: { isEnabled },
                set: { (enabled: Bool) -> Void in
                    guard enabled else {
                        calendar.disable()
                        return
                    }
                    isRequesting = true
                    Task {
                        await calendar.enable()
                        isRequesting = false
                    }
                }
            )) {
                PhoneSettingLabel(icon: "calendar", title: Text("Takvimi kullan"))
            }
            .disabled(isRequesting)
            switch calendar.state {
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Takvime erişim izni yok. iPhone Ayarları › Gizlilik ve Güvenlik › Takvimler'den Gistsmith'e tam erişim ver.", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(NoticeSeverity.attention.tint)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("Ayarlar'ı aç") { openURL(url) }
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(NoticeSeverity.attention.tint)
            case .off:
                EmptyView()
            case .on:
                Toggle(isOn: Binding<Bool>(
                    get: { remindersEnabled },
                    set: { (enabled: Bool) -> Void in
                        if enabled {
                            Task { await calendar.enableReminders() }
                        } else {
                            calendar.disableReminders()
                        }
                    }
                )) {
                    PhoneSettingLabel(icon: "bell", title: Text("Toplantıdan 1 dk önce hatırlat"))
                }
                if let problem = calendar.reminderProblem {
                    Label(problem, systemImage: "bell.slash")
                        .foregroundStyle(NoticeSeverity.attention.tint)
                }
            }
        } header: {
            Text("Takvim")
        } footer: {
            Text("Sıradaki toplantılar ana ekranda görünür; kayıt toplantının adını ve kişilerini alır.")
        }
    }
}

/// Bildirimler: not hazır, görev günü, haftalık özet ve kayıtsız hafta (her biri varsayılan açık). Açılan anahtar
/// bildirim iznini (sorulmadıysa) sorar, kapanan anahtar o türün bekleyen bildirimlerini hemen kaldırır. İzin yoksa
/// nedeni ve iPhone Ayarları'ndaki bildirim sayfasını açan düğme görünür.
private struct NotificationSettingsSection: View {
    @AppStorage(PhoneSettingsKey.notifyNoteReady) private var noteReady: Bool = true
    @AppStorage(PhoneSettingsKey.notifyTaskDue) private var taskDue: Bool = true
    @AppStorage(PhoneSettingsKey.notifyWeeklySummary) private var weeklySummary: Bool = true
    @AppStorage(PhoneSettingsKey.notifyInactive) private var inactive: Bool = true
    @Environment(\.openURL) private var openURL: OpenURLAction
    private let notifier: EngagementNotifier = .shared

    var body: some View {
        Section {
            if notifier.authorization == .denied {
                VStack(alignment: .leading, spacing: 8) {
                    Label(notificationMessage(error: NotificationError.denied), systemImage: "bell.slash")
                        .foregroundStyle(NoticeSeverity.attention.tint)
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        Button("Ayarlar'ı aç") { openURL(url) }
                    }
                }
            }
            toggle(icon: "bell.badge", title: "Not hazır olunca bildir", help: "Uygulama kapalıyken not hazırlanınca; toplantıyı açar.", isOn: $noteReady, kind: .noteReady)
            toggle(icon: "checklist", title: "Görevin günü gelince hatırlat", help: "O gün 09:00'da; \"Tamamlandı\" ile işaretlenir.", isOn: $taskDue, kind: .taskDue)
            toggle(icon: "calendar.badge.clock", title: "Haftalık özet", help: "Pazartesi 09:00'da açık görevler ve toplantı sayısı.", isOn: $weeklySummary, kind: .weeklySummary)
            toggle(icon: "hourglass", title: "Bir hafta kayıt yoksa hatırlat", help: "Son kayıttan 7 gün sonra 10:00'da bir kez.", isOn: $inactive, kind: .inactive)
        } header: {
            Text("Bildirimler")
        } footer: {
            Text("Kilit ekranında görünebilir: yalnız toplantı adı, sayılar ve görev metni; konuşma metni yok.")
        }
        .task { await notifier.refreshAuthorization() }
    }

    private func toggle(icon: String, title: LocalizedStringKey, help: LocalizedStringKey, isOn: Binding<Bool>, kind: EngagementKind) -> some View {
        Toggle(isOn: isOn) {
            PhoneSettingLabel(icon: icon, title: Text(title)) {
                Text(help)
            }
        }
        .onChange(of: isOn.wrappedValue) { (_: Bool, enabled: Bool) in
            Task { await notifier.settingChanged(kind: kind, enabled: enabled) }
        }
    }
}

/// Çok satırlı metin ayarı (tanıma sözlüğü, kendi şablonun): üstte kısa açıklama, altında kart içinde düzenleyici; her
/// değişiklik hemen saklanır (`save`; açılınca `load` okunur).
private struct PhoneTextSettingScreen: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey
    let load: @MainActor () -> String
    let save: @MainActor (String) -> Void
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(help)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .appFont(size: 16, weight: .regular)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        }
        .padding(20)
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            text = load()
            isFocused = true
        }
        .onChange(of: text) { (_: String, value: String) in
            save(value)
        }
    }
}

/// Görünüm satırı: öteki ayar satırlarıyla aynı simge kutusu, altında tema adı ve yazı tipi; dokununca Görünüm ayarları
/// açılır.
private struct PhoneAppearanceRow: View {
    let theme: String
    @AppStorage(PhoneSettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontChoice.storageValue

    var body: some View {
        PhoneSettingLabel(icon: "paintpalette", title: Text("Tema, renk ve yazı")) {
            Text(verbatim: [
                (AppTheme(rawValue: theme) ?? .system).displayName,
                fontChoiceName(choice: AppFontChoice.parse(storage: fontDesign) ?? PanelAppearance.standard.fontChoice),
            ].joined(separator: " · "))
        }
    }
}

/// Uygulamanın şu anki arayüz dilinin kendi dilindeki adı ("Türkçe", "English"). Saf değildir: paketin dil seçimini okur.
private func interfaceLanguageName() -> String {
    let code: String = Bundle.main.preferredLocalizations.first ?? "en"
    let locale: Locale = Locale(identifier: code)
    return locale.localizedString(forLanguageCode: code).map { $0.capitalized(with: locale) } ?? code
}

/// Onay bekleyen ses saklama seçimi: yeni süre ve sesi hemen silinecek toplantı sayısı.
struct PendingAudioRetention: Equatable {
    let days: Int
    let meetingCount: Int
}
