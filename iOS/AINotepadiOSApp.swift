import AINotepadCore
import AINotepadUI
import AppIntents
import Combine
import CoreSpotlight
import os
import SwiftUI
import UIKit
import UserNotifications

private let phoneAppLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "App")

/// iPhone uygulaması (Gistsmith): önce giriş (Apple ya da Google, Mac'teki Gistsmith'le aynı hesap), sonra bir kez yapay
/// zekâ işleme açıklaması, sonra tek ana ekran (bugün, geçmiş toplantılar, altta "Bir şey sor" ve kayıt düğmesi; görevler,
/// arama, ayarlar ve kitaplık bir dokunuş ötede). Mac'le aynı çekirdeği ve görünümü kullanır; toplantılar giriş yapan hesabın bu iPhone'daki klasöründe durur (iCloud eşitlemesi yok).
@main
struct AINotepadiOSApp: App {
    /// Abonelik hesabı (giriş, hak durumu, toplantı oturumu); Mac'teki Gistsmith'le ortak.
    private let account: HostedAccount
    /// Yüklü hesabın bellekteki verisi (toplantılar, kaydedici, Sor, çalar); hesap değişince yenisi kurulur.
    @State private var sessions: PhoneSessionHost
    @State private var router: PhoneRouter
    @State private var calendar: PhoneCalendar
    /// Çökme raporları (MetricKit; yalnız bu iPhone'da, Ayarlar'da gösterilir).
    @State private var crashReports: CrashReportCenter = CrashReportCenter()
    /// Paylaşım sayfasından gelen ses dosyaları (ör. iPhone'un arama kaydı): giriş ve açıklama bitince içe aktarılır.
    @State private var sharedFiles: PhoneSharedFileInbox = PhoneSharedFileInbox()

    init() {
        // Yarıda kalan işlemeyi sürdüren sistem görevi açılış bitmeden kaydedilmeli.
        ProcessingResumeScheduler.shared.register()
        registerPhoneDefaults()
        keepPhoneLegacyNoteLanguage(defaults: .standard)
        choosePhoneMeetingLanguageOnFirstRun(defaults: .standard)
        // Tema ilk kareden önce uygulanır.
        let theme: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: PhoneSettingsKey.theme) ?? "") ?? .system
        ThemeStore.shared.set(light: theme.colorSets.light, dark: theme.colorSets.dark)
        #if DEBUG
        // `--karsilama` (yalnız Debug, görsel kontrol): ilk açılış karşılaması yeniden gösterilir.
        if CommandLine.arguments.contains("--karsilama") {
            UserDefaults.standard.removeObject(forKey: PhoneSettingsKey.onboardingCompleted)
            // `--karsilama-adim <adım>` (welcome, calendar, permissions, sample, ready): karşılama o adımdan açılır.
            if let index = CommandLine.arguments.firstIndex(of: "--karsilama-adim"), CommandLine.arguments.indices.contains(index + 1) {
                UserDefaults.standard.set(CommandLine.arguments[index + 1], forKey: onboardingStepKey)
            } else {
                UserDefaults.standard.removeObject(forKey: onboardingStepKey)
            }
        }
        #endif
        #if DEBUG
        if isDemoMode {
            activatePhoneDemoAccount()
        }
        #endif
        // Hesap toplantılardan önce okunur: oturum varsa o hesabın verisi yüklenir (yoksa toplantı klasörü açılmaz).
        let account: HostedAccount = HostedAccount.shared
        #if DEBUG
        if isDemoMode {
            // `--abone`: sahte hesap App Store abonesi açılır (hesap ekranı, davet; görsel kontrol).
            if CommandLine.arguments.contains("--abone") {
                account.showAccountForDemo(entitlements: phoneDemoAppStoreEntitlements(now: Date()), referral: phoneDemoReferral(now: Date()))
            } else {
                account.showAccountForDemo(entitlements: phoneDemoEntitlements(now: Date()), referral: nil)
            }
            // `--ekran asistan`: yapay zekâ asistanı erişimi açık, iki bağlı asistan; `--reddedilen` ile yükleme bitmiş ve
            // sunucunun kabul etmediği toplantılar var (görsel kontrol; sunucuya gidilmez).
            if launchPath(arguments: CommandLine.arguments).last == .assistantAccess {
                if CommandLine.arguments.contains("--reddedilen") {
                    HostedAssistantCenter.shared.showRefusedForDemo(now: Date())
                } else {
                    HostedAssistantCenter.shared.showForDemo(now: Date())
                }
            }
            // `--aciklama`: yapay zekâ açıklaması yeniden gösterilir (görsel kontrol).
            UserDefaults.standard.set(!CommandLine.arguments.contains("--aciklama"), forKey: PhoneSettingsKey.aiDisclosureAccepted)
            // `--karsilama`: ilk açılış karşılaması gösterilir (görsel kontrol).
            UserDefaults.standard.set(!CommandLine.arguments.contains("--karsilama"), forKey: PhoneSettingsKey.onboardingCompleted)
        }
        #endif
        self.account = account
        // App Store aboneliği (RevenueCat): oturum varsa hesabın kimliğiyle; tanıtım modunda anonim (sahte hesabın kimliği
        // RevenueCat'e gönderilmez). Anahtar yoksa abonelik ekranı nedeni gösterir.
        do {
            #if DEBUG
            try AppStorePurchases.shared.configure(userID: isDemoMode ? nil : account.signedInUserIDCache)
            #else
            try AppStorePurchases.shared.configure(userID: account.signedInUserIDCache)
            #endif
        } catch {
            phoneAppLogger.error("RevenueCat yapılandırılamadı, hata: \(String(describing: error), privacy: .public)")
        }
        let calendar: PhoneCalendar = PhoneCalendar()
        let sessions: PhoneSessionHost = PhoneSessionHost(session: makePhoneAccountSession(calendar: calendar))
        let router: PhoneRouter = PhoneRouter(path: launchPath(arguments: CommandLine.arguments))
        router.isLibraryOpen = launchOpensLibrary(arguments: CommandLine.arguments)
        _sessions = State(initialValue: sessions)
        _router = State(initialValue: router)
        _calendar = State(initialValue: calendar)
        // Kısayollar, Denetim Merkezi ve canlı etkinlikteki niyetler yüklü hesabın kaydedicisine ve gezinmeye buradan
        // ulaşır (hesap değişince kaydedici değişir, kayıt yeri değişmez).
        AppDependencyManager.shared.add(dependency: sessions)
        AppDependencyManager.shared.add(dependency: router)
        // Toplantılara sor, açık görevler, toplantıyı aç ve Spotlight sonucu yüklü hesaba buradan ulaşır.
        MeetingIntentsHost.backend = PhoneMeetingIntentsBackend(sessions: sessions, router: router, account: account)
        // Toplantı hatırlatmasındaki taze "Kaydı başlat" kaydı başlatır (kısayoldaki gibi); bildirime dokunmak ya da
        // eski bildirim yalnız ana ekranı açar (bkz. `meetingNotificationTap`).
        PhoneNotificationDelegate.onMeetingNotification = { (isStartAction: Bool, deliveredAt: Date) -> Void in
            router.showHome()
            let recorder: PhoneRecorder = sessions.session.recorder
            guard meetingNotificationTap(isStartAction: isStartAction, deliveredAt: deliveredAt, now: Date(), isRecording: recorder.phase != .idle) == .startRecording else {
                return
            }
            Task { await recorder.start() }
        }
        // "Toplantı bitti mi?": "Kaydı bitir" uygulamayı açmadan bitirir, "Sürüyor" soruyu kapatır.
        PhoneNotificationDelegate.onMeetingOverResponse = { (finish: Bool) -> Void in
            let recorder: PhoneRecorder = sessions.session.recorder
            if finish {
                recorder.stop()
            } else {
                recorder.dismissMeetingOverPrompt()
            }
        }
        // Not hazır, görev günü, haftalık özet ve kayıtsız hafta bildirimleri: dokunma yerini açar, "Tamamlandı" görevi
        // uygulamayı öne getirmeden işaretler (arka planda açıldıysa önce hesabın adı ve toplantıları okunur).
        PhoneNotificationDelegate.onEngagementResponse = { (route: EngagementRoute) async -> Void in
            switch route {
            case .openMeeting(let meetingID):
                router.show(meetingID: meetingID)
            case .openTasks:
                router.showTasks()
            case .openRecording:
                router.showHome()
            case .completeTask(let meetingID, let taskKey):
                guard account.isAccountDataLoaded else {
                    phoneAppLogger.warning("Bildirimdeki görev işaretlenemedi: hesap verisi yüklü değil, toplantı: \(meetingID, privacy: .public)")
                    return
                }
                let store: PhoneStore = sessions.session.store
                if !store.isLoaded {
                    store.loadIdentity()
                    await store.reloadAndWait()
                }
                store.completeTaskFromNotification(meetingID: meetingID, taskKey: taskKey)
            }
        }
        UNUserNotificationCenter.current().delegate = PhoneNotificationDelegate.shared
        EngagementNotifier.shared.start { () -> EngagementDataState in
            phoneEngagementDataState(store: sessions.session.store, account: account)
        }
    }

    var body: some Scene {
        WindowGroup {
            PhoneAppRoot(account: account, sessions: sessions, router: router, calendar: calendar, crashReports: crashReports)
            .modifier(PhoneAppearanceModifier())
            // Paylaşım sayfasındaki "Gistsmith" (ses dosyası türleri project.yml'de): giriş kapısı açıkken gelen dosya da
            // kaybolmaz, ana ekran açılınca içe aktarılır (`PhoneImportHost`).
            .environment(sharedFiles)
            // `gistsmith://…` ve evrensel bağlantılar (`https://gistsmith.com/m/<kimlik>`) yerini açar; geri kalan adres
            // paylaşım sayfasından gelen dosyadır.
            .onOpenURL { (url: URL) in
                guard let route = appLinkRoute(url: url) else {
                    sharedFiles.receive(url: url)
                    return
                }
                let store: PhoneStore = sessions.session.store
                openPhoneAppLink(route: route, router: router, account: account, meetingIDs: store.meetings.map(\.id) + store.deletedMeetings.map(\.id))
            }
            // Spotlight'taki toplantı sonucu o toplantıyı açar (hesapta yoksa açılmaz).
            .onContinueUserActivity(CSSearchableItemActionType) { (activity: NSUserActivity) in
                guard let meetingID = spotlightMeetingID(activity: activity) else {
                    return
                }
                Task { await openSpotlightMeeting(meetingID: meetingID) }
            }
            .task {
                crashReports.start()
                HostedTelemetryCenter.shared.start()
                // Hesap ve hak durumu açılışta okunur (Mac'te `AINotepadApp`'teki gibi): oturum varken giriş kapısı
                // görünmez, okumayı başka hiçbir şey başlatmaz; yoksa Ayarlar'daki hesap satırı "okunuyor"da kalırdı.
                await account.readUnknownStatus()
            }
        }
    }
}

/// Kullanıcının görünüm ayarları (vurgu rengi, yazı tipi, yazı ölçeği, okuma metni boyutu, satır aralığı ve canlı metnin
/// alt boşluğu) tüm arayüze: ortam, yazı ve renk tonu; ayar değişince hemen uygulanır. Sistemin yazı boyutu (Dinamik Yazı)
/// ayarların üstüne çarpılır.
private struct PhoneAppearanceModifier: ViewModifier {
    @AppStorage(PhoneSettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(PhoneSettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontChoice.storageValue
    @AppStorage(PhoneSettingsKey.uiScale) private var uiScale: Double = PanelAppearance.standard.uiScale
    @AppStorage(PhoneSettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(PhoneSettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @AppStorage(PhoneSettingsKey.bottomSpacing) private var bottomSpacing: Double = PanelAppearance.standard.bottomSpacing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    func body(content: Content) -> some View {
        let standard: PanelAppearance = .standard
        let appearance: PanelAppearance = resolvedPanelAppearance(stored: StoredAppearance(
            fontDesign: fontDesign, uiScale: uiScale, textSize: textSize, lineSpacing: lineSpacing, bottomSpacing: bottomSpacing,
            accent: accent, surface: standard.surface.rawValue, surfaceOpacity: standard.surfaceOpacity
        ), isFontFamilyInstalled: { (family: String) -> Bool in !UIFont.fontNames(forFamilyName: family).isEmpty })
        .dynamicTypeScaled(factor: dynamicTypeFactor(size: dynamicTypeSize))
        content
            .environment(\.panelAppearance, appearance)
            .fontDesign(appearance.systemFontDesign)
            .font(appearance.font(size: 15, weight: .regular))
            .tint(appearance.accent.color)
            // Menü biçimli seçiciler ve sistem sayfaları rengi SwiftUI ortamından değil pencereden alır.
            .onChange(of: accent, initial: true) { (_: String, _: String) in
                applyWindowTint(color: UIColor(appearance.accent.color))
            }
            .onChange(of: fontDesign, initial: true) { (_: String, storage: String) in
                if case .installed(let family) = AppFontChoice.parse(storage: storage), UIFont.fontNames(forFamilyName: family).isEmpty {
                    phoneAppLogger.warning("Seçili yazı ailesi yüklü değil, varsayılan yazı kullanılıyor; aile: \(family, privacy: .public)")
                }
            }
    }
}

/// Dinamik Yazı boyutunun gövde metnine göre çarpanı (varsayılan boyutta 1). Erişilebilirlik boyutlarında düzen
/// bozulmasın diye en çok iki kat.
private func dynamicTypeFactor(size: DynamicTypeSize) -> Double {
    let traits: UITraitCollection = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
    let base: CGFloat = 17
    return min(Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traits) / base), 2)
}

/// Uygulamanın pencerelerinin vurgu rengi (UIKit denetimleri, menü biçimli seçiciler, paylaşım sayfası).
@MainActor
private func applyWindowTint(color: UIColor) {
    for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else {
            continue
        }
        for window in windowScene.windows {
            window.tintColor = color
        }
    }
}

/// Giriş kapısı, yapay zekâ açıklaması ya da sekmeler. Kayıt sürerken oturum kapanırsa (`hostedSessionEnded`) sekmeler
/// kalır ("Bitir" kaybolmasın), kapı kayıt bitip toplantı saklanınca açılır. Hesabın verisi yüklenince (açılışta, ilk
/// girişte ya da hesap değişince) toplantılar, Sor geçmişi ve yarım kalan işlemeler okunur; hesap bekleyen kayıtların işlenmesini
/// tetikleyince (ağ geldi, hak durumu okundu, uygulama öne geldi) kuyruk çalışır. Başka bir hesapla giriş yapılınca
/// (iPhone kendini yeniden başlatamaz) eski hesabın yazan işleri bitince hesap yerinde değişir (bkz.
/// `switchAccountIfIdle`).
private struct PhoneAppRoot: View {
    let account: HostedAccount
    let sessions: PhoneSessionHost
    let router: PhoneRouter
    let calendar: PhoneCalendar
    let crashReports: CrashReportCenter
    /// Yapay zekâ açıklaması bu oturumda onaylandı: onay hesabın ayar alanına yazılır (`recordPhoneAIConsent`), görünüm
    /// bununla yeniden okur.
    @State private var consentRevision: Int = 0
    /// Onay saklanamadıysa nedeni (açıklamanın altında).
    @State private var consentError: String?
    @AppStorage(PhoneSettingsKey.theme) private var theme: String = AppTheme.system.rawValue

    var body: some View {
        let session: PhoneAccountSession = sessions.session
        Group {
            if phoneShowsSignInGate(requiresSignIn: account.requiresSignIn, isRecording: session.recorder.phase != .idle) {
                PhoneSignInGate(account: account, switchWaitsFor: session.openWriters, isLinkWaiting: router.isLinkWaitingForSignIn)
            } else if !phoneAIConsentGiven(account: account), consentRevision >= 0 {
                // Onay hesap başına: başka hesapla girince açıklama o hesaba da gösterilir. Onay ayarda saklıdır (gözlenmez);
                // `consentRevision` okunur ki onaylayınca görünüm yeniden çizilsin.
                PhoneAIDisclosure(account: account, errorMessage: consentError) {
                    do {
                        try recordPhoneAIConsent(account: account)
                        consentError = nil
                        consentRevision += 1
                    } catch {
                        consentError = userFacingMessage(error: error)
                    }
                }
            } else {
                RootView(
                    store: session.store, recorder: session.recorder, ask: session.ask, router: router, player: session.player, calendar: calendar,
                    crashReports: crashReports, account: account
                )
                .environment(session.integrations)
                .modifier(PhoneIntegrationTriggers(integrations: session.integrations, isLoaded: account.isAccountDataLoaded))
                // Kayıt sürerken oturum kapandıysa giriş kapısı kayıt bitince açılır; o zamana dek nedeni üstte görünür.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if account.requiresSignIn {
                        NoticeText("Oturumun kapandı. Kaydı bitir; toplantı bu iPhone'da saklanır, sonra yeniden giriş yap.", severity: .attention)
                            .appFont(size: 13, weight: .regular)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.background)
                    }
                }
            }
        }
        // Koyu tema giriş kapısında ve yapay zekâ açıklamasında da koyu sistem denetimleriyle (renkler tüm uygulamada).
        .preferredColorScheme((AppTheme(rawValue: theme) ?? .system).isDark.map { $0 ? ColorScheme.dark : ColorScheme.light })
        // Hesap değişince görünümlerin durumu (açık sayfalar, seçimler, kaydırma) eski hesabınkiyle kalmasın.
        .id(sessions.generation)
        // Önceki sürümlerin cihaz başına onayı ilk giren hesaba taşınır.
        .task(id: account.signedInUserIDCache) { migrateLegacyPhoneAIConsent(account: account) }
        // Bağlantı toplantılar okunmadan (açılışta, girişten önce) geldiyse kimliği okununca cihazdakiyle eşleşir.
        .onChange(of: session.store.meetings.count + session.store.deletedMeetings.count, initial: true) { (_: Int, _: Int) in
            router.matchLinkedMeetings(meetingIDs: session.store.meetings.map(\.id) + session.store.deletedMeetings.map(\.id))
        }
        // Girişten sonra kapıdaki "bağlantı girişten sonra açılır" notu kalkar (bağlantının yeri yığında bekler).
        .onChange(of: account.requiresSignIn) { (_: Bool, requiresSignIn: Bool) in
            if !requiresSignIn {
                router.isLinkWaitingForSignIn = false
            }
        }
        .task(id: account.dataState) {
            guard account.isAccountDataLoaded else {
                return
            }
            let store: PhoneStore = sessions.session.store
            let recorder: PhoneRecorder = sessions.session.recorder
            let ask: PhoneAsk = sessions.session.ask
            // Sistemin sürdürme görevi yüklü hesabın toplantılarını işler.
            ProcessingResumeScheduler.shared.recorder = recorder
            // Ad listeden önce okunur: notlardaki "Sen" ve görevler ilk çizimde doğru kişiye ayrılsın.
            store.loadIdentity()
            // Saklama süresi ve yarım kalan kayıtlar listeye bakar: okuma bitince sürer. Okuma sürerken hesap değiştiyse
            // (görev iptal edildi) eski hesabın listesiyle hiçbir şey yazılmaz.
            await store.reloadAndWait()
            guard !Task.isCancelled else {
                return
            }
            store.loadPeople()
            store.voices.load()
            store.loadFolders()
            // Bu iPhone'da silinen hesaptan kalan toplantılar varsa taşıma önerilir (bkz. `HostedDeletedMeetings`).
            HostedDeletedMeetings.shared.refresh()
            ask.loadRecipes()
            ask.loadHistory()
            store.applyRetention(now: Date())
            // Bağlantılar okunur; kapalıyken kaçan kendiliğinden gönderimler yapılır (Mac'teki açılış gibi).
            let integrations: PhoneIntegrations = sessions.session.integrations
            Task {
                await integrations.load()
                await integrations.processPendingAutoSends()
            }
            // Son silinenlerde süresi dolan toplantılar kalıcı silinir (okuma sürerken hesap değiştiyse silinmez).
            await store.reloadDeletedAndWait()
            guard !Task.isCancelled else {
                return
            }
            store.purgeExpiredDeleted(now: Date())
            #if DEBUG
            // `--paywall`: abonelik ekranı doğrudan açılır (App Store abonelik inceleme görseli).
            if CommandLine.arguments.contains("--paywall") {
                account.showPlans()
            }
            // `--sohbet <kimlik>`: saklanan Sor sohbeti tam ekran açılır (ekran görüntüleri).
            if let conversationID = launchConversationID(arguments: CommandLine.arguments) {
                ask.open(conversationID: conversationID)
                router.path = [.ask, .askConversation]
            }
            // `--sablon-galerisi [<kimlik>]`: Ayarlar'da şablon galerisi (ve o şablonun önizlemesi) açılır.
            let templateGalleryPath: [PhoneRoute] = launchTemplateGalleryPath(arguments: CommandLine.arguments)
            if !templateGalleryPath.isEmpty {
                router.path = templateGalleryPath
            }
            if CommandLine.arguments.contains("--ornek-takvim") {
                calendar.showSampleMeetings(now: Date())
            }
            if CommandLine.arguments.contains("--ornek-kayit") {
                recorder.showSampleRecording()
                // `--ornek-duraklat`: örnek kayıt duraklatılmış, bir cümlenin çevirisi alınamamış.
                if CommandLine.arguments.contains("--ornek-duraklat") {
                    recorder.showSamplePaused()
                }
                // `--ornek-sinir`: örnek kayıt çevrimdışı ve aylık sınırla kısaltılmış (kalan dakika şeridi).
                if CommandLine.arguments.contains("--ornek-sinir") {
                    recorder.showSampleLimits()
                }
                // `--ornek-bitir`: örnek kayıt "Bitir"e basılmış gibi bitiriliyor (hazırlık katmanı, durmuş süre).
                if CommandLine.arguments.contains("--ornek-bitir") {
                    recorder.showSampleFinishing()
                }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--soru"), CommandLine.arguments.indices.contains(index + 1) {
                ask.ask(question: CommandLine.arguments[index + 1], meetingIDs: [], recipeTitle: nil)
                router.path = [.ask, .askConversation]
            }
            #endif
            await recorder.resumeUnfinished()
            #if DEBUG
            // `--hesap-degistir` (tanıtım, Simülatör'de denetim): 3 sn sonra ikinci sahte hesapla giriş yapılmış gibi hesap
            // yerinde değişir; ikinci hesapta yeniden tetiklenmez.
            if isDemoMode, CommandLine.arguments.contains("--hesap-degistir"), AppPaths.activeAccountKey() == accountDataKey(userId: "tanitim") {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                account.beginAccountSwitchForDemo(userId: "tanitim-2")
            }
            #endif
        }
        .onChange(of: account.dataState, initial: true) { (_: HostedDataState, _: HostedDataState) in
            switchAccountIfIdle()
            recordHostedSyncedSettingChanges()
        }
        // Hesapla eşitlenen ayarlar (not dili, dil modu, görünüm, şablon…): her ayar değişiminde bu iPhone'da yapılan
        // değişikliğin anı kaydedilir; başka cihazdan gelen dil modu kaydedicinin bellekteki kopyasına da yansır.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { (_: Notification) in
            recordHostedSyncedSettingChanges()
            sessions.session.recorder.refreshStoredSettings()
        }
        .onChange(of: session.openWriters) { (_: [AccountDataWriter], _: [AccountDataWriter]) in
            switchAccountIfIdle()
        }
        // Mac ↔ iPhone eşitlemesi (isteğe bağlı; bkz. `HostedSyncCenter`). Hesap değişirken önce durur (`.syncing`).
        .modifier(PhoneSyncBindings(account: account, session: session))
        // Yapay zekâ asistanı erişimi (isteğe bağlı; bkz. `HostedAssistantCenter`).
        .modifier(PhoneAssistantBindings(account: account, session: session))
        .onChange(of: account.signedInUserIDCache, initial: true) { (_: String?, userID: String?) in
            // RevenueCat kimliği hesapla eşlenir: giriş, çıkış, hesap değişimi ve silme (satın alma bu hesaba yazılsın).
            #if DEBUG
            if isDemoMode {
                return
            }
            #endif
            AppStorePurchases.shared.syncIdentity(userID: userID)
        }
        .onChange(of: account.state) { (_: HostedAccountState, _: HostedAccountState) in
            // Çıkış yapılınca bildirimler kalkar, girişte giriş yapan hesabınkiler kurulur (bkz. `phoneEngagementDataState`).
            EngagementNotifier.shared.scheduleRefresh()
        }
        .onChange(of: account.queueTrigger) { (_: Int, _: Int) in
            guard account.isAccountDataLoaded else {
                return
            }
            let recorder: PhoneRecorder = sessions.session.recorder
            Task {
                await recorder.runQueue()
                // Geçici nedenle başarısız biten işlemeler de (ağ geldi, uygulama öne geldi) yeniden denenir.
                await recorder.retryFailedProcessing()
            }
        }
    }

    /// Başka bir hesapla giriş yapıldıysa ve eski hesabın verisine yazan iş yoksa hesabı yerinde değiştirir: eski hesabın
    /// çaları durur, hesap değişir, yeni hesabın toplantıları, kaydedicisi, Sor'u ve çaları kurulur, gezinme başa döner.
    /// Yazan iş varsa beklenir (kapı nedenini söyler); iş bitince yeniden denenir.
    private func switchAccountIfIdle() {
        guard case .switchPending = account.dataState else {
            return
        }
        guard case .ready(let writers) = accountSwitchReadiness(openWriters: sessions.session.openWriters) else {
            return
        }
        sessions.session.close()
        do {
            try account.completeAccountSwitch(writers: writers)
        } catch {
            phoneAppLogger.error("Hesap değişimi tamamlanamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
        guard account.isAccountDataLoaded else {
            // Yeni hesabın verisi hazırlanamadı: eski hesap yüklü kalır, neden kapıda görünür.
            return
        }
        sessions.replace(session: makePhoneAccountSession(calendar: calendar))
        router.reset()
        // Eski hesabın bildirimleri (bekleyen ve gösterilmiş) kalkar; yeni hesabınkiler toplantıları okununca kurulur.
        Task { await EngagementNotifier.shared.removeAll() }
    }
}

/// Bir hesabın bellekteki verisi ve ona yazan işler: toplantı arşivi, kaydedici (kayıt, işleme, bekleyen kayıtlar,
/// canlı etkinlik), Sor (geçmiş, tarifler) ve çalar. Hesap değişince bütünüyle bırakılır, yenisi kurulur.
@MainActor
struct PhoneAccountSession {
    let store: PhoneStore
    let recorder: PhoneRecorder
    let ask: PhoneAsk
    let player: MeetingAudioPlayer
    /// Not hedefleri ve görev araçları (Ayarlar › Bağlantılar, toplantıdaki gönderim).
    let integrations: PhoneIntegrations

    /// Hesabın verisine yazan açık işler (bkz. `phoneOpenWriters`).
    var openWriters: [AccountDataWriter] {
        phoneOpenWriters(store: store, recorder: recorder, ask: ask, integrations: integrations)
    }

    /// Hesap değişmeden önce eski hesabın açık dosyalarını bırakır: çalan toplantı durur.
    func close() {
        player.stop()
    }
}

/// Bildirim planı için giriş yapan hesabın verisi: çıkış yapıldıysa `signedOut` (bildirimler kalkar); tanıtım modunda,
/// hesap verisi yüklenmeden ve toplantılar okunmadan `notReady`.
@MainActor
func phoneEngagementDataState(store: PhoneStore, account: HostedAccount) -> EngagementDataState {
    if phoneIsDemoLaunch() {
        return .notReady
    }
    if case .signedOut = account.state {
        return .signedOut
    }
    guard !account.requiresSignIn, store.isLoaded else {
        return .notReady
    }
    // Örnek toplantı (karşılamadaki deneme) bildirimlere girmez.
    return .ready(EngagementSnapshot(
        records: realMeetings(records: store.meetings), userName: store.userName, calendarEnabled: UserDefaults.standard.bool(forKey: PhoneSettingsKey.calendarEnabled)
    ))
}

/// Tanıtım modunda (`--tanitim`, yalnız Debug) mı açıldı.
func phoneIsDemoLaunch() -> Bool {
    #if DEBUG
    isDemoMode
    #else
    false
    #endif
}

/// Giriş kapısı gösterilsin mi: giriş gerekiyorsa, ama kayıt sürerken değil (oturum kayıt sırasında kapandıysa kayıt
/// ekranı ve "Bitir" kalır; kapı kayıt bitip toplantı saklanınca açılır). Saf fonksiyondur.
func phoneShowsSignInGate(requiresSignIn: Bool, isRecording: Bool) -> Bool {
    requiresSignIn && !isRecording
}

/// Hesabın verisine yazan açık işler (bkz. `accountSwitchReadiness`): kayıt, işleme, bekleyen kayıtların kuyruğu, dosya
/// içe aktarma, not yazma, Sor cevabı, notların kendiliğinden gönderimi ve eşitleme. Hesap değişimi bunları bekler
/// (eşitleme hesap değişirken kendiliğinden durur); çıkış ve hesap silme eşitleme dışındakiler sürerken kapalıdır
/// (içe aktarılan ya da yazılan toplantı başka hesabın klasörüne ya da oturumuna, not başka hesabın hedeflerine gitmesin;
/// eşitleme çıkışta durur).
@MainActor
func phoneOpenWriters(store: PhoneStore, recorder: PhoneRecorder, ask: PhoneAsk, integrations: PhoneIntegrations) -> [AccountDataWriter] {
    let open: [(AccountDataWriter, Bool)] = [
        (.recording, recorder.phase != .idle),
        (.processing, !recorder.processingSteps.isEmpty),
        (.offlineQueue, recorder.isRunningQueue),
        (.importing, recorder.importingCount > 0),
        (.noteEditing, !store.regeneratingIDs.isEmpty),
        (.askAnswering, ask.isAnswering),
        (.noteSending, integrations.isAutoSending),
        (.syncing, HostedSyncCenter.shared.isEngineRunning),
    ]
    return open.filter { $0.1 }.map { $0.0 }
}

/// Giriş yapan hesabın veri anahtarı (oturumdaki kullanıcıdan); oturum yoksa nil. Tanıtım modunda (yalnız Debug) oturum
/// yoktur: yüklü sahte hesap giriş yapmış sayılır.
@MainActor
func phoneSignedInAccountKey() -> String? {
    #if DEBUG
    if isDemoMode {
        return AppPaths.activeAccountKey()
    }
    #endif
    return HostedAccount.shared.signedInUserIDCache.map { (userID: String) -> String in accountDataKey(userId: userID) }
}

/// Yüklü hesabın bellekteki verisini kurar (boş; toplantılar hesap yüklenince okunur). Kayıt başlarken takvimde süren
/// toplantıya bağlanır (takvim açıksa).
@MainActor
func makePhoneAccountSession(calendar: PhoneCalendar) -> PhoneAccountSession {
    let store: PhoneStore = PhoneStore()
    let recorder: PhoneRecorder = PhoneRecorder(store: store)
    recorder.currentCalendarMeeting = { () -> CalendarMeeting? in calendar.meetingForRecording(now: Date()) }
    let integrations: PhoneIntegrations = PhoneIntegrations(store: store)
    // Toplantılar ya da görev işaretleri değişince görev ve özet bildirimleri yeniden kurulur.
    store.onNotificationInputsChanged = { () -> Void in
        EngagementNotifier.shared.scheduleRefresh()
    }
    // Not hazır olunca bağlı hedeflere kendiliğinden gönderilir (Mac'teki işleme sonu gibi); uygulama arkadaysa "Not
    // hazır" bildirimi gösterilir, öndeyse ilk toplantıdan sonra bildirim izni sorulur.
    recorder.onMeetingProcessed = { (record: MeetingRecord) -> Void in
        Task { await integrations.processPendingAutoSends() }
        let userName: String = store.userName
        let isActive: Bool = UIApplication.shared.applicationState == .active
        Task { await EngagementNotifier.shared.meetingProcessed(record: record, userName: userName, isAppActive: isActive) }
    }
    // Not hazır olunca ve değişince Markdown klasöründeki kopya yenilenir (Mac'teki gibi; kendiliğinden yazma açıksa).
    // Bağlantılar arşive bağlı: zayıf başvuru döngü kurmaz.
    store.onMeetingsChanged = { [weak integrations] (previous: [MeetingRecord], current: [MeetingRecord]) -> Void in
        integrations?.refreshMarkdownFolderCopies(previous: previous, current: current)
    }
    return PhoneAccountSession(store: store, recorder: recorder, ask: PhoneAsk(store: store), player: MeetingAudioPlayer(), integrations: integrations)
}

/// Yüklü hesabın bellekteki verisinin sahibi: görünümler ve niyetler (Kısayollar, canlı etkinlik) onu buradan okur.
/// Hesap değişince yenisiyle değiştirilir; `generation` görünümlerin kimliğidir.
@MainActor
@Observable
final class PhoneSessionHost {
    private(set) var session: PhoneAccountSession
    /// Her hesap değişiminde artar: görünümlerin durumu sıfırlanır.
    private(set) var generation: Int = 0

    init(session: PhoneAccountSession) {
        self.session = session
    }

    /// Eski hesabın verisini yenisiyle değiştirir (eskisi bırakılır).
    func replace(session: PhoneAccountSession) {
        self.session = session
        generation += 1
    }
}

/// Ana ekranın üstündeki tam ekran sunum: ilk açılış karşılaması ya da abonelik ekranı (açılma nedeniyle).
enum PhoneRootCover: Identifiable, Equatable {
    case onboarding
    case paywall(HostedUpsellMoment)

    var id: String {
        switch self {
        case .onboarding:
            "onboarding"
        case .paywall(let reason):
            "paywall.\(reason.rawValue)"
        }
    }
}

/// Gösterilecek tam ekran sunum: karşılama bitmediyse karşılama (abonelik isteği bekler), bittiyse istenen abonelik
/// ekranı, yoksa nil. Saf fonksiyondur.
func phoneRootCover(onboardingCompleted: Bool, upsell: HostedUpsellMoment?) -> PhoneRootCover? {
    guard onboardingCompleted else {
        return .onboarding
    }
    return upsell.map { PhoneRootCover.paywall($0) }
}

/// Ana ekrandan açılan sayfalar (tek gezinme yığını; sıra yığındaki sıradır).
enum PhoneRoute: Hashable {
    /// Toplantı sayfası (kimliği).
    case meeting(String)
    /// Görevlerim.
    case tasks
    /// Arama: toplantılarda başlık, not, görev ve kişi adıyla.
    case search
    /// Toplantı kitaplığı: süzgeçler, klasörler, seçme, toplu taşıma ve silme (açılan kapsamla).
    case library(MeetingListScope)
    /// Kişiler.
    case people
    /// İstatistikler: toplantılardan cihazda hesaplanan sayılar ve grafikler.
    case insights
    /// Son silinenler.
    case recentlyDeleted
    /// Sor: örnek sorular, son sohbetler ve soru alanı.
    case ask
    /// Açık Sor sohbeti.
    case askConversation
    /// Sor sohbet geçmişi.
    case askHistory
    /// Ayarlar.
    case settings
    /// Ayarlar › Hesap (kullanım, plan, aboneliği yönet).
    case account
    /// Profil: ad, unvan, şirket ve şirket açıklaması.
    case profile
    /// Ayarlar › Not şablonu galerisi.
    case templateGallery
    /// Galerideki bir şablonun önizlemesi (`GalleryTemplate.id`).
    case templatePreview(String)
    /// Ayarlar › Kendi şablonun (adı ve yönergesi).
    case customTemplate
    /// Ayarlar › Yapay zekâ asistanı erişimi.
    case assistantAccess
    /// Ayarlar › Bağlantılar (kanallar ve görev araçları).
    case connections
}

/// Gezinme durumu: ana ekranın üstündeki sayfa yığını ve kitaplık sayfası. Uygulama içindeki bağlantılar yığına ekler
/// (geri, gelinen sayfaya döner); bildirim, kısayol ve canlı etkinlik gibi dışarıdan gelen açılışlar yığını baştan kurar.
@MainActor
@Observable
final class PhoneRouter {
    var path: [PhoneRoute]
    /// Ana ekranın sol üstündeki kitaplık sayfası (tüm toplantılar, görevler, kişiler, klasörler, içe aktarma) açık.
    var isLibraryOpen: Bool = false
    /// Oturum yokken bir bağlantı (`gistsmith://…`) geldi: giriş kapısı bağlantının girişten sonra açılacağını söyler.
    var isLinkWaitingForSignIn: Bool = false

    init(path: [PhoneRoute]) {
        self.path = path
    }

    /// Ana ekran görünüyor (üstünde açık sayfa yok).
    var isOnHome: Bool {
        path.isEmpty
    }

    /// Sayfayı yığının üstüne açar (uygulama içi bağlantı).
    func push(route: PhoneRoute) {
        path.append(route)
    }

    /// Sor'da basılan kaynak: toplantı sayfası açılınca o anı gösterir ve sıfırlar (`MeetingReadView.openingSource`).
    var openingSource: ArchivePassage?

    /// Sor'daki kaynağın toplantısını yığının üstünde açar; sayfa kaynağın anını gösterir (transkript çekmecesi o
    /// paragrafta, not kaynağında özet).
    func open(source: ArchivePassage) {
        openingSource = source
        open(meetingID: source.meetingID)
    }

    /// Toplantıyı yığının üstünde açar (Sor'daki kaynak, görev, kişi); zaten üstteyse yeniden açılmaz.
    func open(meetingID: String) {
        guard path.last != .meeting(meetingID) else {
            return
        }
        path.append(.meeting(meetingID))
    }

    /// Toplantıyı ana ekranın üstünde tek sayfa olarak açar (bildirim, mini çalar, işleme bitişi, karşılama).
    func show(meetingID: String) {
        isLibraryOpen = false
        path = [.meeting(meetingID)]
    }

    /// Sayfayı ana ekranın üstünde tek sayfa olarak açar (dışarıdan gelen bağlantı: Sor, İstatistikler).
    func showAlone(route: PhoneRoute) {
        isLibraryOpen = false
        path = [route]
    }

    /// Yığındaki toplantı sayfalarının kimliğini cihazdaki toplantınınkiyle değiştirir (bağlantıdaki UUID'nin harf
    /// büyüklüğü farklı olabilir; bkz. `linkedMeetingID`): silme sayfayı kapatsın, karşılaştırmalar tutsun. Bağlantı
    /// açılınca ve toplantılar okunup değişince çağrılır; eşleşmeyen kimlik kalır ("Toplantı bulunamadı").
    func matchLinkedMeetings(meetingIDs: [String]) {
        let matched: [PhoneRoute] = path.map { (route: PhoneRoute) -> PhoneRoute in
            guard case .meeting(let id) = route, let found = linkedMeetingID(linkID: id, meetingIDs: meetingIDs) else {
                return route
            }
            return .meeting(found)
        }
        if matched != path {
            path = matched
        }
    }

    /// Görevlerim'i ana ekranın üstünde açar (görev bildirimi).
    func showTasks() {
        isLibraryOpen = false
        path = [.tasks]
    }

    /// Ayarlar › Hesap'ı açar (kullanım, plan, aboneliği yönet; Mac'teki `openAccountSettings`).
    func openAccount() {
        isLibraryOpen = false
        path = [.settings, .account]
    }

    /// Ana ekrana döner: açık sayfalar ve kitaplık kapanır (kayıt başlarken, "Kaydı başlat" bağlantıları).
    func showHome() {
        isLibraryOpen = false
        path = []
    }

    /// Hesap değişince gezinme başa döner: açık toplantı ve sohbet eski hesabındır.
    func reset() {
        showHome()
    }

    /// Sor sohbetini açar: yığında Sor varsa onun üstünde (geçmiş kapanır), yoksa açık sayfanın üstünde Sor ile birlikte
    /// (geri önce Sor'a, sonra gelinen sayfaya döner).
    func openAskConversation() {
        path = askBase(path: path) + [.askConversation]
    }

    /// Sor'un ilk sayfasına döner ("Yeni sohbet").
    func returnToAsk() {
        path = askBase(path: path)
    }

    /// Silinen toplantıların açık sayfaları kapanır.
    func closeMeetings(ids: Set<String>) {
        path.removeAll { (route: PhoneRoute) -> Bool in
            if case .meeting(let id) = route {
                return ids.contains(id)
            }
            return false
        }
    }
}

/// Yığının Sor'a kadar olan kısmı (Sor dahil); Sor yoksa yığın ve sonunda Sor. Saf fonksiyondur.
func askBase(path: [PhoneRoute]) -> [PhoneRoute] {
    guard let index = path.lastIndex(of: .ask) else {
        return path + [.ask]
    }
    return Array(path[...index])
}

/// Başlatma argümanlarından ilk sayfa yığını (görsel kontrol ve App Store görselleri için; yoksa ana ekran). Saf
/// fonksiyondur.
/// - `--sekme kayit|toplantilar|sor|gorevler|ayarlar`: eski sekmeler; kayıt ve toplantılar ana ekrandır.
/// - `--ekran kitaplik|arama|kisiler|istatistikler|profil|hesap|asistan`: kitaplık, arama, kişiler, istatistikler, profil, hesap
///   ya da yapay zekâ asistanı erişimi.
/// - `--toplanti <kimlik>`: toplantı bunların üstünde açılır.
func launchPath(arguments: [String]) -> [PhoneRoute] {
    let base: [PhoneRoute] = launchValue(arguments: arguments, flag: "--sekme").map(launchTabRoutes(tab:))
        ?? launchValue(arguments: arguments, flag: "--ekran").map(launchScreenRoutes(screen:))
        ?? []
    let meeting: [PhoneRoute] = launchValue(arguments: arguments, flag: "--toplanti").map { [PhoneRoute.meeting($0)] } ?? []
    return base + meeting
}

/// Bayraktan sonraki değer; bayrak ya da değer yoksa nil. Saf fonksiyondur.
private func launchValue(arguments: [String], flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

/// Eski `--sekme` değerinin yığını (bilinmeyen değer ana ekran). Saf fonksiyondur.
private func launchTabRoutes(tab: String) -> [PhoneRoute] {
    switch tab {
    case "sor": [.ask]
    case "gorevler": [.tasks]
    case "ayarlar": [.settings]
    default: []
    }
}

/// `--ekran` değerinin yığını (bilinmeyen değer ana ekran). Saf fonksiyondur.
private func launchScreenRoutes(screen: String) -> [PhoneRoute] {
    switch screen {
    case "kitaplik": [.library(.filter(.all))]
    case "arama": [.search]
    case "kisiler": [.people]
    case "istatistikler": [.insights]
    case "profil": [.settings, .profile]
    case "hesap": [.settings, .account]
    case "asistan": [.settings, .assistantAccess]
    case "baglantilar": [.settings, .connections]
    default: []
    }
}

/// `--sohbet <kimlik>` başlatma argümanı: saklanan Sor sohbetinin kimliği (görsel kontrol için); yoksa ya da UUID değilse
/// nil. Saf fonksiyondur.
func launchConversationID(arguments: [String]) -> UUID? {
    launchValue(arguments: arguments, flag: "--sohbet").flatMap { UUID(uuidString: $0) }
}

/// `--ayar <bölüm>` başlatma argümanı: Ayarlar açılınca o bölüme kaydırılır (görsel kontrol için; ör. `konusmacilar`);
/// yoksa nil. Saf fonksiyondur.
func launchSettingsSection(arguments: [String]) -> String? {
    launchValue(arguments: arguments, flag: "--ayar")
}

/// `--ekran klasorler`: kitaplık sayfası açık başlar (görsel kontrol için). Saf fonksiyondur.
func launchOpensLibrary(arguments: [String]) -> Bool {
    launchValue(arguments: arguments, flag: "--ekran") == "klasorler"
}

/// `--ekran telefon` ya da `--arama <adım>`: telefon görüşmesi rehberi açık başlar (görsel kontrol için); yoksa nil. Saf
/// fonksiyondur.
func launchImportRequest(arguments: [String]) -> PhoneImportSource? {
    launchValue(arguments: arguments, flag: "--ekran") == "telefon" || arguments.contains("--arama") ? .phoneCall : nil
}

/// Ana ekran ve üstündeki sayfalar; tam ekran karşılama ve abonelik ekranı, kayıt ve uygulama yaşam döngüsü.
struct RootView: View {
    let store: PhoneStore
    let recorder: PhoneRecorder
    let ask: PhoneAsk
    @Environment(PhoneIntegrations.self) private var integrations: PhoneIntegrations
    @Bindable var router: PhoneRouter
    let player: MeetingAudioPlayer
    let calendar: PhoneCalendar
    let crashReports: CrashReportCenter
    let account: HostedAccount
    /// İlk açılış karşılaması bitti (`--karsilama` ile Debug'da yeniden gösterilir).
    @AppStorage(PhoneSettingsKey.onboardingCompleted) private var onboardingCompleted: Bool = false
    @AppStorage(PhoneSettingsKey.theme) private var theme: String = AppTheme.system.rawValue
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    /// Uygulama arka plana geçti: öne dönünce yarım kalan işleme sürdürülür.
    @State private var wasInBackground: Bool = false
    /// İçe aktarma isteği, seçici hatası ve Fotoğraflar kopyası (ana ekran ve kitaplık gösterir).
    /// `--ekran telefon` ile telefon görüşmesi rehberi açık başlar (görsel kontrol).
    @State private var imports: PhoneImportState = PhoneImportState(request: launchImportRequest(arguments: CommandLine.arguments))
    #if PHONE_DIALER
    /// Uygulamadan arama (pilot; hesap başına: hesap değişince kök görünüm yeniden kurulur). `--arama <adım>` örnek veriyle.
    @State private var dialer: PhoneDialer = makePhoneDialer(arguments: CommandLine.arguments)
    #endif

    /// Toplantı öncesi brifing (Mac'teki "Brifing"): yeni bir Sor sohbeti açar; arşive aynı kişilerle ya da konuda önceki
    /// görüşmeler, kararlar ve açık görevler sorulur.
    private func startBriefing(meeting: CalendarMeeting) {
        // Hakkı yoksa Sor'a geçilmez (boş sohbet açılırdı); abonelik ekranı açılır.
        guard !account.requiresSubscription else {
            account.requestSubscription()
            return
        }
        // Brifing yeni bir konu: önceki sohbet bağlam olmasın (önceki sohbet geçmişte kalır).
        ask.clear()
        ask.ask(question: briefingQuestion(meeting: meeting), meetingIDs: [], recipeTitle: nil)
        router.openAskConversation()
    }

    /// Toplantıya tarif uygular (Mac'teki "Tarif"): yeni bir Sor sohbetinde yalnız o toplantıya sorulur.
    private func runRecipe(recipe: Recipe, meetingID: String) {
        guard !account.requiresSubscription else {
            account.requestSubscription()
            return
        }
        ask.clear()
        ask.ask(question: recipe.prompt, meetingIDs: [meetingID], recipeTitle: recipe.title)
        router.openAskConversation()
    }

    /// Deneme bitince (ya da abonelik sona erince) abonelik ekranı bir kez kendiliğinden açılır (bkz.
    /// `phoneAutoPaywallKey`); gösterildiği, ekran görününce işaretlenir. Çağıran kayıt ve karşılama durumunu denetler.
    private func showAutoPaywallIfDue() {
        guard let key = phoneAutoPaywallKey(state: account.state), !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        #if DEBUG
        if isDemoMode {
            return
        }
        #endif
        account.showPlans()
    }

    var body: some View {
        // Tek gezinme yığını: kökte ana ekran (kayıtta canlı kayıt), üstünde toplantı, görevler, arama, kitaplık, Sor ve
        // ayarlar sayfaları.
        NavigationStack(path: $router.path) {
            PhoneHomeRoot(recorder: recorder, store: store, router: router, calendar: calendar, player: player, account: account, onBriefing: startBriefing(meeting:))
                .navigationDestination(for: PhoneRoute.self) { (route: PhoneRoute) in
                    PhoneDestination(
                        route: route, store: store, recorder: recorder, ask: ask, router: router, player: player, calendar: calendar,
                        account: account, crashReports: crashReports,
                        isMeetingInFlight: !phoneOpenWriters(store: store, recorder: recorder, ask: ask, integrations: integrations).filter { $0 != .syncing }.isEmpty,
                        onRunRecipe: runRecipe(recipe:meetingID:)
                    )
                }
        }
        // Ses ya da video içe aktarma (kitaplık ve kayıt düğmesinin menüsü), telefon görüşmesi rehberi ve deneysel görüşme
        // kaydı. Ortam nesnelerinden ÖNCE gelmeli: sayfalar yalnızca sunuldukları görünüme verilen ortamı alır; rehber
        // `PhoneDialer` ve `PhoneRecorder` okur, sonra eklenirse açılışta çöker (`SourceLintTests.phoneImportHostIsInsideTheEnvironment`).
        .modifier(PhoneImportHost(recorder: recorder, state: imports))
        // Görev satırları Anımsatıcılar'a eklemek için arşive, toplantı sayfasındaki "Şimdi dene" kaydediciye buradan ulaşır.
        .environment(store)
        .environment(recorder)
        .environment(imports)
        #if PHONE_DIALER
        .environment(dialer)
        #endif
        // Tam ekran sunum tektir (iki ayrı `fullScreenCover` aynı anda sunulamaz): önce ilk açılış karşılaması, bitince
        // abonelik ekranı ("Abone ol" — Hesap, kayıt kartı —, deneme bitince bir kez ve sunucu aboneliği isteyince;
        // `HostedAccount.upsell`). Karşılama sürerken istenen abonelik ekranı karşılama bitince açılır.
        .fullScreenCover(item: Binding<PhoneRootCover?>(
            get: { phoneRootCover(onboardingCompleted: onboardingCompleted, upsell: account.upsell) },
            set: { (cover: PhoneRootCover?) -> Void in
                // Karşılama kendiliğinden kapanmaz (bitince `onboardingCompleted`); kapatılan sunum abonelik ekranıdır.
                if cover == nil, onboardingCompleted {
                    account.dismissUpsell()
                }
            }
        )) { (cover: PhoneRootCover) in
            switch cover {
            case .onboarding:
                PhoneOnboarding(store: store, calendar: calendar) { (sampleMeetingID: String?) -> Void in
                    // Abonelik ekranı karşılamanın yerine aynı güncellemede geçer (karşılama kapanırken yeni sunum
                    // başlatılmaz; sunum kimliği değişince SwiftUI birini kapatıp ötekini açar).
                    if recorder.phase == .idle {
                        showAutoPaywallIfDue()
                    }
                    UserDefaults.standard.removeObject(forKey: onboardingStepKey)
                    // Örnek toplantı denendiyse kullanıcı onun notuna iner.
                    if let sampleMeetingID {
                        router.show(meetingID: sampleMeetingID)
                    }
                    onboardingCompleted = true
                }
            case .paywall(let reason):
                PhonePaywall(account: account, reason: reason) { account.dismissUpsell() }
                    .onAppear {
                        // Kendiliğinden açılış ekran gerçekten görününce işaretlenir: sunulamadıysa bir sonraki fırsatta
                        // yeniden açılır. Kullanıcı kendisi açtıysa da aynı durum için bir daha kendiliğinden açılmaz.
                        if let key = phoneAutoPaywallKey(state: account.state) {
                            UserDefaults.standard.set(true, forKey: key)
                        }
                    }
            }
        }
        // Kayıt sürerken ve karşılama bitmeden anahtar nil: son deneme toplantısı başlarken deneme biterse ekran kayıt
        // bitince, ilk açılışta karşılama bitince açılır (anahtar arada değişip bir daha değişmediği için yoksa ancak bir
        // sonraki açılışta açılırdı).
        .onChange(of: recorder.phase == .idle && onboardingCompleted ? phoneAutoPaywallKey(state: account.state) : nil, initial: true) { (_: String?, key: String?) in
            guard key != nil else {
                return
            }
            showAutoPaywallIfDue()
        }
        .preferredColorScheme((AppTheme(rawValue: theme) ?? .system).isDark.map { $0 ? ColorScheme.dark : ColorScheme.light })
        .onChange(of: theme) { (_: String, value: String) in
            let selected: AppTheme = AppTheme(rawValue: value) ?? .system
            ThemeStore.shared.set(light: selected.colorSets.light, dark: selected.colorSets.dark)
        }
        .onChange(of: player.meetingID, initial: true) { (_: String?, id: String?) in
            store.playingMeetingID = id
        }
        .onChange(of: recorder.phase) { (_: RecorderPhase, phase: RecorderPhase) in
            // Kayıt başlarken çalma durur (mikrofon ve hoparlör aynı oturumu paylaşamaz); açık sayfalar kapanır, canlı kayıt
            // ana ekranın yerinde görünür (kısayol, bildirim ya da canlı etkinlikle başlatıldıysa da).
            if phase == .starting || phase == .recording {
                player.stop()
                router.showHome()
            }
        }
        .onChange(of: scenePhase, initial: true) { (_: ScenePhase, phase: ScenePhase) in
            // Takvim açılışta ve uygulama öne gelince yeniden okunur (izin bu arada geri alınmış olabilir).
            if phase == .active {
                calendar.start()
                // Bildirim izni iPhone Ayarları'nda değişmiş olabilir; notu yazılmış toplantı varsa ve izin hiç
                // sorulmadıysa şimdi sorulur (tanıtım modunda sorulmaz); bildirimler yenilenir.
                if !phoneIsDemoLaunch() {
                    let records: [MeetingRecord] = store.meetings
                    Task { await EngagementNotifier.shared.appBecameActive(records: records) }
                }
            }
            // Kayıt arka planda sürer; görünmeyen kayıt ekranının işi durur, öne dönünce uzaktayken gelen metin hemen
            // görünür (bkz. `PhoneRecorder.enterBackground`).
            if phase == .background {
                recorder.enterBackground()
            } else if phase == .active {
                recorder.enterForeground()
                // Kayıttan önce boş yer (Ayarlar'da yer açılmış ya da dolmuş olabilir).
                recorder.refreshRecordingDiskSpace()
            }
            // Arka planda süresi dolup iptal edilen işleme öne dönünce sürer (yoksa toplantı bir sonraki açılışa dek
            // "Hazırlanıyor"da kalırdı). Açılıştaki ilk çağrı `.task`'tadır; işlenmekte olanlar atlanır.
            if phase == .background {
                wasInBackground = true
            } else if phase == .active, wasInBackground {
                wasInBackground = false
                Task { await recorder.resumeUnfinished() }
            }
        }
    }
}

/// Toplantı arşivi: giriş yapan hesabın bu iPhone'daki `Sessions` klasörü. (iCloud eşitlemesi bu sürümde kapalı; Mac'le
/// isteğe bağlı eşitleme kendi sunucumuz üzerinden, bkz. `HostedSyncCenter`.)
@MainActor
@Observable
final class PhoneStore {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneStore")
    /// Hesabın toplantıları (en yeni önce); değişince bağlanan iş çalışır (bildirimler yeniden kurulur).
    private(set) var meetings: [MeetingRecord] = [] {
        didSet {
            onNotificationInputsChanged?()
            // Spotlight'taki kopya farkla güncellenir (yalnız oturum açık ve hesap yüklüyken; bkz. MeetingSpotlightIndex).
            MeetingSpotlightIndex.shared.update(
                records: meetings, userName: userName, isAllowed: HostedAccount.shared.isAccountDataLoaded && !HostedAccount.shared.requiresSignIn
            )
        }
    }
    /// Toplantılar en az bir kez diskten okundu: o zamana dek bildirim planına dokunulmaz (boş listeyle bekleyen görev
    /// bildirimleri silinmesin).
    @ObservationIgnored private(set) var isLoaded: Bool = false
    /// Toplantılar ya da ad değişti (uygulama bağlar: görev ve özet bildirimleri yeniden kurulur). Markdown kopyaları için
    /// olan `onMeetingsChanged`'den ayrı: ikisi de bağlanır, biri diğerinin yerine geçmez.
    @ObservationIgnored var onNotificationInputsChanged: (@MainActor () -> Void)?
    /// Okunamayan klasörler ya da klasöre erişim hatası (her okumada yenilenir).
    private(set) var loadProblems: [String] = []
    /// Toplantı işlemlerinin hataları (not yenileme, düzenleme, görev işareti…): okumayla silinmez; toplantı sayfasında
    /// ve Görevler'de de görünür, kullanıcı kapatır (`dismissActionProblems`).
    private(set) var actionProblems: [String] = []
    /// Kullanıcıya gösterilen tüm sorunlar (Toplantılar listesi).
    var problems: [String] { loadProblems + actionProblems }
    /// Çalan toplantı: sesi saklama süresiyle silinmez (dosyaları kullanımda).
    var playingMeetingID: String?
    /// Elle eklenen ve kaldırılan kişiler (`People.json`, Mac'tekiyle aynı biçim; bkz. `PhonePeopleList`).
    private(set) var peopleBook: PeopleBook = .empty
    /// Kişiler defteri okunamadı ya da yazılamadı.
    private(set) var peopleBookError: String?
    /// Defter okundu: okunamadıysa üzerine yazılmaz (boş defterle eski kişiler silinmesin).
    @ObservationIgnored private var peopleBookLoaded: Bool = false
    /// Sesinden tanıma: kayıtlı sesler ve ses izi modeli (bkz. `PhoneVoices`).
    let voices: PhoneVoices = PhoneVoices()
    @ObservationIgnored private var peopleCache: MemoCache<PeopleDirectoryInput, [PersonSummary]> = .empty
    @ObservationIgnored private var analyticsCache: MemoCache<AnalyticsInput, MeetingAnalytics> = .empty

    /// Kişiler dizini (`peopleDirectory`); toplantılar, sesler, defter ve ad değişmedikçe yeniden hesaplanmaz.
    func peopleDirectory() -> [PersonSummary] {
        let input: PeopleDirectoryInput = PeopleDirectoryInput(records: meetings, voices: voices.registered, book: peopleBook, userName: userName)
        let result: (output: [PersonSummary], cache: MemoCache<PeopleDirectoryInput, [PersonSummary]>) = memoized(input: input, cache: peopleCache) {
            AINotepadCore.peopleDirectory(records: $0.records, voices: $0.voices, book: $0.book, userName: $0.userName)
        }
        peopleCache = result.cache
        return result.output
    }

    /// İstatistikler (`meetingAnalytics`); toplantılar, dönem, ad ya da gün değişmedikçe yeniden hesaplanmaz.
    func analytics(period: AnalyticsPeriod) -> MeetingAnalytics {
        let now: Date = Date()
        let input: AnalyticsInput = AnalyticsInput(records: meetings, period: period, userName: userName, day: Calendar.current.startOfDay(for: now))
        let result: (output: MeetingAnalytics, cache: MemoCache<AnalyticsInput, MeetingAnalytics>) = memoized(input: input, cache: analyticsCache) {
            meetingAnalytics(records: $0.records, period: $0.period, userName: $0.userName, now: now, calendar: Calendar.current)
        }
        analyticsCache = result.cache
        return result.output
    }

    /// Listeyi arka planda okur; art arda gelen istekleri birleştirir.
    @ObservationIgnored private let reloader: MeetingReloader = MeetingReloader()
    /// Liste değişti (önceki ve yeni liste): not hazır olunca ya da değişince Markdown klasöründeki kopya yenilenir (bkz.
    /// `PhoneIntegrations.refreshMarkdownFolderCopies`; oturum kurulurken bağlanır).
    @ObservationIgnored var onMeetingsChanged: (@MainActor ([MeetingRecord], [MeetingRecord]) -> Void)?

    /// Toplantıları arka planda yeniden okur; beklemeden döner.
    func reload() {
        Task { await reloadAndWait() }
    }

    /// Listeyi değiştirir ve değişikliği bildirir.
    private func replaceMeetings(records: [MeetingRecord]) {
        let previous: [MeetingRecord] = meetings
        meetings = records
        onMeetingsChanged?(previous, records)
    }

    /// Toplantıları diskten yeniden okur (en yeni önce). Okuma ana iş parçacığının dışında yapılır; liste güncellenince
    /// döner.
    func reloadAndWait() async {
        await reloader.reload(load: { () async throws -> MeetingLoadResult in
            try await loadMeetingsInBackground(location: .local)
        }, apply: { (result: MeetingLoadResult) -> Void in
            self.isLoaded = true
            self.replaceMeetings(records: result.meetings)
            self.loadProblems = result.failures.map { (failure: MeetingLoadFailure) -> String in "\(failure.folder): \(failure.reason)" }
        }, fail: { (error: any Error) -> Void in
            self.loadProblems = [userFacingMessage(error: error)]
        })
    }

    /// Eşitlemenin söylediğini (ör. kendi notların iki cihazda düzenlendi) işlem sorunlarıyla gösterir; kullanıcı kapatır.
    func reportSyncNotice(message: String) {
        actionProblems = appendUnique(messages: actionProblems, message: message)
    }

    /// İşlem hatalarını kapatır.
    func dismissActionProblems() {
        actionProblems = []
    }

    /// Kişiler defterini okur (hesabın klasöründen; Mac'teki `loadPeople`).
    func loadPeople() {
        do {
            peopleBook = try loadPeopleBook(url: try peopleFileURL())
            peopleBookLoaded = true
            peopleBookError = nil
        } catch {
            Self.logger.error("Kişiler defteri okunamadı, hata: \(String(describing: error), privacy: .private)")
            peopleBookError = userFacingMessage(error: error)
        }
    }

    /// Kişi ekler ya da bilgilerini günceller (adı konuşma tanımaya da verilir).
    func savePerson(name: String, role: String, email: String) {
        storePeople(book: addingPerson(book: peopleBook, person: SavedPerson(name: name, role: role, email: email, addedAt: Date())))
    }

    /// Elle eklenen kişinin adını ve bilgilerini değiştirir; kayıtlı sesi yeni ada taşınır.
    func renamePerson(oldName: String, name: String, role: String, email: String) {
        storePeople(book: renamingPerson(book: peopleBook, oldName: oldName, person: SavedPerson(name: name, role: role, email: email, addedAt: Date())))
        if peopleBookError == nil {
            voices.personRenamed(oldName: oldName, newName: name)
        }
    }

    /// Kişiyi Kişiler'den kaldırır ve sesini unutur (toplantılardaki adı kalır).
    func removePerson(name: String) {
        storePeople(book: removingPerson(book: peopleBook, name: name, now: Date()))
        if peopleBookError == nil {
            voices.personRemoved(name: name)
        }
    }

    private func storePeople(book: PeopleBook) {
        guard peopleBookLoaded else {
            peopleBookError = String(localized: "Kişiler defteri okunamadığı için değişiklik kaydedilmedi; People.json dosyasını denetle ve uygulamayı yeniden aç.")
            return
        }
        do {
            try savePeopleBook(book: book, url: try peopleFileURL())
            peopleBook = book
            peopleBookError = nil
        } catch {
            Self.logger.error("Kişiler defteri yazılamadı, hata: \(String(describing: error), privacy: .private)")
            peopleBookError = userFacingMessage(error: error)
        }
    }

    /// Kaydedilen toplantıyı listeye yazar (her kayıtta klasör yeniden okunmaz).
    func upsert(record: MeetingRecord) {
        replaceMeetings(records: upsertMeeting(records: meetings, record: record))
        // Süren arka plan okuması bu yazmayı görmemiş olabilir: sonucu bu kaydı geri almasın.
        reloader.invalidate()
    }

    /// Karşılamadaki örnek toplantıyı saklar (eşitlenmez, işlenmez) ve kimliğini döndürür. Saklı bir örnek toplantı varsa
    /// yenisi yazılmaz: kullanıcının bu denemede yazdığı not ona yazılır.
    func addSampleMeeting(script: SampleMeetingScript, note: MeetingNote, myNotes: String, audio: URL) throws -> String {
        if let existingID = existingSampleMeetingID(records: meetings), let existing = meetings.first(where: { $0.id == existingID }) {
            let updated: MeetingRecord = existing.with(myNotes: myNotes)
            try saveMeeting(record: updated, directory: try sessionDirectory(id: existingID))
            upsert(record: updated)
            return existingID
        }
        let record: MeetingRecord = try writeSampleMeeting(
            script: script, note: note, speakerNames: sampleMeetingSpeakerNames, myNotes: myNotes, audio: audio, now: Date()
        )
        upsert(record: record)
        Self.logger.info("Örnek toplantı saklandı, toplantı: \(record.id, privacy: .public)")
        return record.id
    }

    /// Konuşmacılara ad verir ("Konuşmacı 2 = Aino"; boş ad etiketi geri getirir). Kayıttaki, işlenen ya da notu
    /// yazılan toplantıda yapılmaz (işleme bitince kayıt bütünüyle yazılır, ad kaybolurdu). Değişiklik diskteki en güncel
    /// kayda uygulanır (Mac'te iCloud'la gelmiş düzenlemeler bellekteki eski kopyayla ezilmesin).
    /// Yüz yüze toplantıda kullanıcının konuşmacısı seçildi ("Hangisi sendin?"): ad henüz yoksa saklanır, konuşmacıya
    /// kullanıcının adı verilir (görevleri Görevlerim'e düşer). Adlandırılamazsa neden sorunlarda görünür.
    func nameUserSpeaker(meetingID: String, person: Int, name: String) {
        if userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setUserName(name: name)
        }
        do {
            try renameSpeakers(meetingID: meetingID, names: [person: name])
        } catch {
            Self.logger.error("Kullanıcının konuşmacısı adlandırılamadı, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: error))
        }
    }

    func renameSpeakers(meetingID: String, names: [Int: String]) throws {
        guard let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording, record.status != .processing,
              !regeneratingIDs.contains(meetingID) else {
            throw StorageError.writeFailed(path: meetingID, reason: "kayıtta ya da işleniyor")
        }
        let directory: URL = try sessionDirectory(id: meetingID)
        let fresh: MeetingRecord = try loadMeeting(directory: directory)
        let updated: MeetingRecord = fresh.with(speakerNames: renamingSpeakers(names: fresh.speakerNames, edits: names))
        try saveMeeting(record: updated, directory: directory)
        upsert(record: updated)
        // Adı verilen kişinin sesi hatırlanır (sesinden tanıma açıksa); düzeltilen adın sesi eski addan geri alınır.
        voices.speakersRenamed(meetingID: meetingID, previousNames: fresh.speakerNames, edits: names, voiceprints: fresh.voiceprints)
    }

    /// Anımsatıcılar bağlantısı (görevi Anımsatıcılar'a ekleme; izin ilk eklemede sorulur).
    @ObservationIgnored private let eventKit: EventKitConnector = EventKitConnector()

    /// Görevi Apple Anımsatıcılar'a ekler ve toplantıda "eklendi" diye işaretler (Mac'teki "Anımsatıcılara ekle"). İzin
    /// yoksa ya da kaydedilemezse hata fırlar (`EventKitError`); eklendi ama işaret yazılamadıysa yazma hatası fırlar.
    func addToReminders(meetingID: String, task: NoteTask) async throws {
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note else {
            throw StorageError.writeFailed(path: meetingID, reason: "toplantı ya da not yok")
        }
        // Anımsatıcıdaki toplantı adı ve sahip konuşmacı adlarıyla (görev zaten adlandırılmış kopyadır).
        let shown: MeetingRecord = namedRecord(record: record, userName: userName)
        try await eventKit.addReminder(draft: reminderDraft(record: shown, task: task, language: note.writtenLanguage, calendar: Calendar.current))
        try updateMeeting(meetingID: meetingID) { (current: MeetingRecord) -> MeetingRecord in markingReminded(record: current, task: task) }
    }

    /// Toplantıya küçük bir düzenleme uygular (ad, klasör, işaretli anlar, kendi notların). Kayıttaki, işlenen ya da notu
    /// yazılan toplantıda yapılmaz (işleme bitince kayıt bütünüyle yazılır, düzenleme kaybolurdu). Değişiklik diskteki en
    /// güncel kayda uygulanır (Mac'te iCloud'la gelmiş düzenlemeler bellekteki eski kopyayla ezilmesin).
    func updateMeeting(meetingID: String, change: (MeetingRecord) -> MeetingRecord) throws {
        guard let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording, record.status != .processing,
              !regeneratingIDs.contains(meetingID) else {
            throw StorageError.writeFailed(path: meetingID, reason: "kayıtta ya da işleniyor")
        }
        let directory: URL = try sessionDirectory(id: meetingID)
        let updated: MeetingRecord = change(try loadMeeting(directory: directory))
        try saveMeeting(record: updated, directory: directory)
        upsert(record: updated)
    }

    /// Kendi notlarını saklar ve notu onlarla yeniden yazar (Mac'teki "Notlarım"). Notlar hemen saklanır; not yazılamazsa
    /// notlar kalır, neden sorunlarda görünür.
    func saveMyNotes(meetingID: String, text: String) async {
        do {
            try updateMeeting(meetingID: meetingID) { (record: MeetingRecord) -> MeetingRecord in record.with(myNotes: text) }
        } catch {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Notların kaydedilemedi: \(userFacingMessage(error: error))"))
            return
        }
        guard let record = rewritableRecord(meetingID: meetingID) else {
            return
        }
        // Geçmişteki ad Mac'teki gibi (⋯ › Geri al).
        await rewriteNote(record: record, reason: String(localized: "Kendi notlarınla yeniden yazıldı"))
    }

    /// Görevin tamamlandı işaretini değiştirir ve toplantıyı saklar. Değişiklik diskteki en güncel kayda uygulanır
    /// (Mac'te iCloud'la gelmiş düzenlemeler bellekteki eski kopyayla ezilmesin).
    func toggleTask(meetingID: String, task: NoteTask) {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            return
        }
        guard record.status != .recording, record.status != .processing else {
            // Dokunuş boşa gitmesin: işleme bitince not bütünüyle yazılır, işaret kaybolurdu.
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Toplantı işlenirken görev işaretlenemez; işleme bitince yeniden dene."))
            return
        }
        do {
            let directory: URL = try sessionDirectory(id: meetingID)
            let updated: MeetingRecord = togglingTask(record: try loadMeeting(directory: directory), task: task)
            try saveMeeting(record: updated, directory: directory)
            upsert(record: updated)
        } catch {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Görev bildirimindeki "Tamamlandı": görev tamamlandı diye işaretlenir (zaten tamamlandıysa değişmez); uygulama
    /// öne gelmeden de çalışır. Toplantı kayıtta ya da işlenirken veya not bu arada yeniden yazılıp görev artık yoksa
    /// işaretlenmez, neden loglanır ve Görevler'de görünür.
    func completeTaskFromNotification(meetingID: String, taskKey key: String) {
        guard let record = meetings.first(where: { $0.id == meetingID }), hasTask(record: record, key: key) else {
            Self.logger.warning("Bildirimdeki görev işaretlenemedi (toplantı ya da görev yok), toplantı: \(meetingID, privacy: .public)")
            return
        }
        do {
            try updateMeeting(meetingID: meetingID) { (current: MeetingRecord) -> MeetingRecord in markingTaskDone(record: current, key: key) }
        } catch {
            Self.logger.error("Bildirimdeki görev işaretlenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Kullanıcının elle yazdığı görevi toplantının notuna ekler (diskteki en güncel kayda); toplantı işlenirken, notsuzken
    /// ya da aynı iş varsa eklenmez, nedeni sorunlarda görünür.
    func addTask(meetingID: String, description: String, dueDay: Date?) {
        guard let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording, record.status != .processing else {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Toplantı işlenirken görev eklenemez; işleme bitince yeniden dene."))
            return
        }
        do {
            let name: String = userName
            var added: Bool = false
            try updateMeeting(meetingID: meetingID) { (current: MeetingRecord) -> MeetingRecord in
                guard let updated = addingTask(record: current, description: description, dueDay: dueDay, userName: name, calendar: Calendar.current) else {
                    return current
                }
                added = true
                return updated
            }
            if !added {
                actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Görev eklenemedi: bu toplantıda aynı görev zaten var."))
            }
        } catch {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Elle eklenmiş görevi siler (nottan gelen görev silinmez).
    func removeAddedTask(meetingID: String, task: NoteTask) {
        do {
            try updateMeeting(meetingID: meetingID) { (current: MeetingRecord) -> MeetingRecord in removingAddedTask(record: current, task: task) }
        } catch {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }

    // MARK: Ad ve tanıma sözlüğü

    /// `namedMeetings` için son adlandırılan notlar: görünüm her çizimde bütün notlarda etiket aramasın.
    @ObservationIgnored private var namedMeetingsCache: NamedRecordsCache = .empty
    /// Arama önbelleği (katlanmış metinler); arama ana iş parçacığının dışında çalışır.
    @ObservationIgnored let searchCache: MeetingSearchCache = MeetingSearchCache()

    /// Toplantılar konuşmacı adlarıyla (`namedRecords`), `meetings` ile aynı sırada; yalnız okumak için (saklı not genel
    /// etiketleri korur, değişiklikler kimlikle saklı kayda yapılır). Notu, adları ya da kullanıcı adı değişmeyen
    /// toplantılar önbellekten gelir; `meetings` ve `userName` okunduğu için görünümler değişince yenilenir. Adlandırma
    /// bu yoldan yapılır (`SourceLintTests`).
    func namedMeetings() -> [MeetingRecord] {
        let result: (records: [MeetingRecord], cache: NamedRecordsCache) = namedRecords(records: meetings, userName: userName, cache: namedMeetingsCache)
        namedMeetingsCache = result.cache
        return result.records
    }

    /// Kullanıcının adı (notta "Sen" ve sana düşen görevler, Sor, konuşmacılar, takip e-postası): hesabın ayar alanında
    /// (Mac'teki Gistsmith'le aynı anahtar); aynı iPhone'daki başka bir hesap bu adı görmez. Hesap verisi yüklenince
    /// okunur (bkz. `loadIdentity`).
    private(set) var userName: String = ""
    /// Tanıma sözlüğü (satır ya da virgülle; Mac'teki "Tanıma sözlüğü"); ad gibi saklanır.
    private(set) var vocabulary: String = ""
    /// Profilin unvanı, şirketi ve şirket açıklaması (Mac'teki Ayarlar > Profil); ad gibi saklanır, notlara bağlam
    /// olarak gider (bkz. `userProfilePromptBlock`).
    private(set) var jobTitle: String = ""
    private(set) var companyName: String = ""
    private(set) var companyDescription: String = ""

    /// Kullanıcının profili (not, düzenleme, Sor ve takip e-postası istemlerine).
    var userProfile: UserProfile {
        UserProfile(name: userName, jobTitle: jobTitle, companyName: companyName, companyDescription: companyDescription)
    }

    /// Adı ve tanıma sözlüğünü okur (hesap verisi yüklenince). Okunamazsa neden sorunlarda görünür.
    func loadIdentity() {
        do {
            let defaults: UserDefaults = try hostedActiveAccountDefaults()
            userName = defaults.string(forKey: PhoneSettingsKey.userName) ?? ""
            vocabulary = defaults.string(forKey: PhoneSettingsKey.customVocabulary) ?? ""
            jobTitle = defaults.string(forKey: PhoneSettingsKey.jobTitle) ?? ""
            companyName = defaults.string(forKey: PhoneSettingsKey.companyName) ?? ""
            companyDescription = defaults.string(forKey: PhoneSettingsKey.companyDescription) ?? ""
        } catch {
            Self.logger.error("Ad ve sözlük okunamadı, hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: error))
        }
    }

    /// Adı hesabın ayar alanına saklar; saklanamazsa neden sorunlarda görünür.
    func setUserName(name: String) {
        do {
            try hostedActiveAccountDefaults().set(name, forKey: PhoneSettingsKey.userName)
            userName = name
            // Kullanıcıya düşen görevler adla da belirlenir.
            onNotificationInputsChanged?()
        } catch {
            Self.logger.error("Ad saklanamadı, hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: error))
        }
    }

    /// Profil alanını (`key`) en fazla `limit` karakterle hesabın ayar alanına saklar; saklanan metni, saklanamazsa
    /// (neden sorunlarda görünür) nil döner.
    private func storeProfileText(text: String, limit: Int, key: String) -> String? {
        let capped: String = cappedProfileText(text: text, limit: limit)
        do {
            try hostedActiveAccountDefaults().set(capped, forKey: key)
            return capped
        } catch {
            Self.logger.error("Profil saklanamadı, anahtar: \(key, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: error))
            return nil
        }
    }

    /// Unvanı saklar.
    func setJobTitle(text: String) {
        jobTitle = storeProfileText(text: text, limit: profileFieldLimit, key: PhoneSettingsKey.jobTitle) ?? jobTitle
    }

    /// Şirket adını saklar.
    func setCompanyName(text: String) {
        companyName = storeProfileText(text: text, limit: profileFieldLimit, key: PhoneSettingsKey.companyName) ?? companyName
    }

    /// Şirket açıklamasını saklar.
    func setCompanyDescription(text: String) {
        companyDescription = storeProfileText(text: text, limit: profileDescriptionLimit, key: PhoneSettingsKey.companyDescription) ?? companyDescription
    }

    /// Tanıma sözlüğünü hesabın ayar alanına saklar; saklanamazsa neden sorunlarda görünür.
    func setVocabulary(text: String) {
        do {
            try hostedActiveAccountDefaults().set(text, forKey: PhoneSettingsKey.customVocabulary)
            vocabulary = text
        } catch {
            Self.logger.error("Tanıma sözlüğü saklanamadı, hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: error))
        }
    }

    // MARK: Silinen hesabın toplantıları

    /// Bu iPhone'da silinen hesabın toplantılarını giriş yapan hesaba (`userID`) taşır (kayıt ekranındaki kart ya da
    /// Ayarlar › Hesap; bkz. `HostedDeletedMeetings`) ve listeyi yeniden okur. Hiçbir toplantı silinmez; taşınamayanın
    /// nedeni kartta ve Ayarlar › Hesap'ta görünür. Oturum yoksa neden sorunlarda görünür.
    func moveDeletedAccountMeetings(userID: String?) {
        guard let userID else {
            actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: HostedClientError.notSignedIn))
            return
        }
        if HostedDeletedMeetings.shared.moveIntoActiveAccount(userID: userID) > 0 {
            reload()
        }
    }

    // MARK: Klasörler

    /// Oluşturulan klasörler (toplantısız olanlar dahil): hesabın ayar alanında (Mac'teki Gistsmith'le aynı anahtar),
    /// hesap verisi yüklenince okunur (bkz. `loadFolders`).
    private(set) var savedFolders: [String] = []

    /// Klasörler ve toplantı sayıları (boş klasörler dahil).
    var folders: [FolderSummary] {
        meetingFolders(records: meetings, saved: savedFolders)
    }

    /// Kayıtlı klasörleri okur (hesap verisi yüklenince). Okunamazsa neden sorunlarda görünür.
    func loadFolders() {
        do {
            savedFolders = try hostedActiveAccountDefaults().stringArray(forKey: savedFoldersKey) ?? []
        } catch {
            Self.logger.error("Klasörler okunamadı, hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: error))
        }
    }

    /// Boş klasör oluşturur (Mac'teki "+"); aynı ad varsa bir şey yapmaz.
    func createFolder(name: String) {
        guard let updated = addingFolder(saved: savedFolders, records: meetings, name: name) else {
            return
        }
        storeFolders(folders: updated)
    }

    /// Klasörü siler (Mac'teki "Klasörü sil"): toplantılar silinmez, klasörsüz kalır. İçinde üzerinde iş süren (`locked`)
    /// toplantı varsa silinmez (o toplantı klasörden çıkarılamaz, klasör yeniden belirirdi); arayüz bu durumda düğmeyi
    /// kapatır. Klasörden çıkarılamayan toplantının nedeni sorunlarda görünür.
    func deleteFolder(name: String, locked: Set<String>) {
        let inside: [MeetingRecord] = meetingsInFolder(records: meetings, folder: name)
        guard !inside.contains(where: { locked.contains($0.id) }) else {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "İçinde kayıttaki ya da işlenen toplantı olan klasör silinemez."))
            return
        }
        storeFolders(folders: removingFolder(saved: savedFolders, name: name))
        for error in moveMeetings(ids: Set(inside.map(\.id)), to: nil, locked: locked) {
            actionProblems = appendUnique(messages: actionProblems, message: error)
        }
    }

    /// Toplantıları klasöre taşır (nil: klasörden çıkarır; ad kırpılır, boş ad klasörden çıkarır); üzerinde iş süren
    /// (`locked`) toplantılar atlanır. Taşınamayanların hataları (tekilleştirilmiş) döner.
    func moveMeetings(ids: Set<String>, to folder: String?, locked: Set<String>) -> [String] {
        let trimmed: String? = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: String? = trimmed?.isEmpty == false ? trimmed : nil
        return ids.subtracting(locked).sorted().reduce(into: [String]()) { (errors: inout [String], id: String) -> Void in
            do {
                try updateMeeting(meetingID: id) { (current: MeetingRecord) -> MeetingRecord in current.with(folder: target) }
            } catch {
                errors = appendUnique(messages: errors, message: "\(String(localized: "Klasöre taşınamadı")): \(userFacingMessage(error: error))")
            }
        }
    }

    /// Klasör listesini hesabın ayar alanına saklar; saklanamazsa neden sorunlarda görünür.
    private func storeFolders(folders: [String]) {
        do {
            try hostedActiveAccountDefaults().set(folders, forKey: savedFoldersKey)
            savedFolders = folders
        } catch {
            Self.logger.error("Klasörler saklanamadı, hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: error))
        }
    }

    // MARK: Son silinenler

    /// Son silinenler (en son silinen önce): `recentlyDeletedRetentionDays` gün geri yüklenebilir, sonra kalıcı silinir.
    private(set) var deletedMeetings: [DeletedMeeting] = []
    /// Son silinenlerde okunamayan klasörler ya da klasöre erişim hatası (her okumada yenilenir).
    private(set) var deletedLoadProblems: [String] = []
    /// Her okumada ve her değişiklikte artar: süren okuma sonradan yapılan silmeyi ya da geri yüklemeyi geri almasın.
    @ObservationIgnored private var deletedGeneration: Int = 0

    /// Son silinenleri arka planda yeniden okur; liste güncellenince döner.
    func reloadDeletedAndWait() async {
        deletedGeneration += 1
        let generation: Int = deletedGeneration
        do {
            let result: DeletedMeetingsLoadResult = try await loadRecentlyDeletedInBackground()
            guard generation == deletedGeneration else {
                return
            }
            deletedMeetings = result.meetings
            deletedLoadProblems = result.failures.map { (failure: MeetingLoadFailure) -> String in "\(failure.folder): \(failure.reason)" }
        } catch {
            guard generation == deletedGeneration else {
                return
            }
            deletedLoadProblems = [userFacingMessage(error: error)]
        }
    }

    /// Toplantıları son silinenlere taşır (Mac'te Çöp Sepeti); `recentlyDeletedRetentionDays` gün geri yüklenebilir.
    /// Üzerinde iş süren (`locked`: kayıtta, işleniyor, notu yazılıyor, sunucu oturumu hazırlanıyor) toplantı
    /// silinmez. Silinemeyenlerin hataları (tekilleştirilmiş) döner; silinenler listeden, görevlerden, Sor'dan ve
    /// Kişiler'den çıkar.
    func trashMeetings(ids: Set<String>, locked: Set<String>, now: Date) -> [String] {
        ids.sorted().reduce(into: [String]()) { (errors: inout [String], id: String) -> Void in
            if let error = trashMeeting(id: id, locked: locked, now: now) {
                errors = appendUnique(messages: errors, message: error)
            }
        }
    }

    /// Tek toplantıyı son silinenlere taşır; olmazsa kullanıcıya gösterilecek neden döner.
    private func trashMeeting(id: String, locked: Set<String>, now: Date) -> String? {
        guard let record = meetings.first(where: { $0.id == id }), !locked.contains(id) else {
            return String(localized: "Kayıttaki ya da işlenen toplantı silinemez.")
        }
        do {
            try moveMeetingToRecentlyDeleted(meetingDirectory: try sessionDirectory(id: id), recentlyDeleted: try AppPaths.recentlyDeletedDirectory(), deletedAt: now)
        } catch {
            Self.logger.error("Toplantı silinemedi, toplantı: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return String(localized: "Toplantı silinemedi: \(userFacingMessage(error: error))")
        }
        closeSpeakerReview(meetingID: id)
        // Toplantının paylaşım bağlantıları da kaldırılır (silinen not bağlantıyla okunmaya devam etmesin).
        revokeNoteShareLinks(meetingIDs: [id])
        meetings.removeAll { $0.id == id }
        reloader.invalidate()
        // Bu toplantıdan öğrenilen ses izleri de geri alınır (Mac'te Çöp Sepeti'ne taşırken olduğu gibi).
        voices.meetingDeleted(meetingID: id)
        deletedGeneration += 1
        deletedMeetings = newestDeletedFirst(meetings: deletedMeetings.filter { $0.id != id } + [DeletedMeeting(record: record, deletedAt: now)])
        return nil
    }

    /// Silinen toplantıları geri yükler: listeye, görevlere, Sor'a ve Kişiler'e (klasörüyle) dönerler. Geri
    /// yüklenemeyenlerin hataları döner; bir hata olduysa iki liste diskten yeniden okunur (yarım kalan geri yükleme
    /// doğru listede görünsün). Geri yüklenen kayıtlar da döner (bekleyen kayıt kuyruğa döner, bkz. çağıran).
    func restoreDeleted(ids: Set<String>) -> (restored: [MeetingRecord], errors: [String]) {
        deletedGeneration += 1
        var restored: [MeetingRecord] = []
        var errors: [String] = []
        for id in ids.sorted() {
            do {
                let record: MeetingRecord = try restoreMeetingFromRecentlyDeleted(
                    id: id, recentlyDeleted: try AppPaths.recentlyDeletedDirectory(), sessions: try AppPaths.sessionsDirectory()
                )
                upsert(record: record)
                deletedMeetings.removeAll { $0.id == id }
                restored.append(record)
            } catch {
                Self.logger.error("Toplantı geri yüklenemedi, toplantı: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                errors = appendUnique(messages: errors, message: String(localized: "Toplantı geri yüklenemedi: \(userFacingMessage(error: error))"))
            }
        }
        if !errors.isEmpty {
            reload()
            Task { await reloadDeletedAndWait() }
        }
        return (restored: restored, errors: errors)
    }

    /// Silinen toplantıları kalıcı olarak siler (metin, not ve ses); silinemeyenlerin hataları döner.
    func purgeDeleted(ids: Set<String>) -> [String] {
        deletedGeneration += 1
        return ids.sorted().reduce(into: [String]()) { (errors: inout [String], id: String) -> Void in
            do {
                try deleteRecentlyDeletedMeeting(id: id, recentlyDeleted: try AppPaths.recentlyDeletedDirectory())
                deletedMeetings.removeAll { $0.id == id }
            } catch {
                Self.logger.error("Toplantı kalıcı silinemedi, toplantı: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                errors = appendUnique(messages: errors, message: String(localized: "Toplantı kalıcı olarak silinemedi: \(userFacingMessage(error: error))"))
            }
        }
    }

    /// Süresi dolan silinen toplantıları kalıcı siler (açılışta ve Son silinenler açılınca). Silinemeyenin nedeni
    /// sorunlarda görünür; bir sonraki denemede yeniden silinir.
    func purgeExpiredDeleted(now: Date) {
        let expired: [String] = deletedMeetingsToPurge(meetings: deletedMeetings, now: now, retentionDays: recentlyDeletedRetentionDays)
        for error in purgeDeleted(ids: Set(expired)) {
            actionProblems = appendUnique(messages: actionProblems, message: error)
        }
    }

    /// Saklama süresi (Ayarlar) dolan toplantıların sesini ve ses izlerini siler; metin ve not kalır. Silinemeyenin
    /// nedeni sorunlarda görünür, bir sonraki açılışta yeniden denenir.
    func applyRetention(now: Date) {
        // "Hiç silme": ne toplantıların ne de sahipsiz kayıtların sesi silinir.
        guard let days = effectiveAudioRetentionDays(setting: UserDefaults.standard.integer(forKey: PhoneSettingsKey.audioRetentionDays)) else {
            return
        }
        // Çalan toplantının sesi kalır.
        for id in audioToDelete(records: meetings.filter { $0.id != playingMeetingID }, now: now, retentionDays: days) {
            do {
                let directory: URL = try sessionDirectory(id: id)
                try deleteAudioFiles(directory: directory)
                // Diskteki en güncel kayda uygulanır: Mac'te yapılan düzenlemeler bellekteki eski kopyayla ezilmesin.
                let updated: MeetingRecord = try loadMeeting(directory: directory).withAudioDeleted().with(voiceprints: nil)
                try saveMeeting(record: updated, directory: directory)
                upsert(record: updated)
            } catch {
                actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: error))
            }
        }
        // Kayıt başlarken (toplantı kaydı yazılmadan) kapanan uygulamanın sahipsiz sesi de süre dolunca silinir.
        do {
            let deleted: [String] = try deleteOrphanedAudio(sessionsDirectory: try AppPaths.sessionsDirectory(), now: now, retentionDays: days)
            if !deleted.isEmpty {
                Self.logger.info("Toplantı kaydı olmayan ses silindi, klasör sayısı: \(deleted.count, privacy: .public)")
            }
        } catch {
            actionProblems = appendUnique(messages: actionProblems, message: userFacingMessage(error: error))
        }
    }

    /// Notu yeniden yazılan toplantılar (menüde "Not yazılıyor…").
    private(set) var regeneratingIDs: Set<String> = []

    /// Mac ile eşitlemeyle başka cihazdan gelen toplantılar (bkz. `HostedSyncCenter`): sesleri kaydedildiği cihazda
    /// kalır, burada oynatılmaz, silinmez ve yeniden işlenmez.
    var meetingsRecordedElsewhere: Set<String> = []

    /// Notu yeniden yazar (Mac'teki "Notu yenile"): başarısız ya da yarım kalan toplantı da iPhone'dan düzelir.
    func regenerateNote(meetingID: String) async {
        guard let record = rewritableRecord(meetingID: meetingID) else {
            return
        }
        await rewriteNote(record: record, reason: String(localized: "Not yenilendi"))
    }

    /// Notu başka bir şablonla yeniden yazar (Mac'teki "Şablonla yeniden yaz"); şablon toplantıda saklanır.
    func regenerateNote(meetingID: String, template: NoteTemplate) async {
        guard let record = rewritableRecord(meetingID: meetingID) else {
            return
        }
        await rewriteNote(record: record.with(template: template), reason: String(localized: "Şablonla yeniden yazıldı"))
    }

    /// Notu yeniden yazılabilecek toplantı: kayıtta, işlenen ya da notu zaten yazılan toplantı değil.
    private func rewritableRecord(meetingID: String) -> MeetingRecord? {
        meetings.first { $0.id == meetingID && $0.status != .recording && $0.status != .processing && !regeneratingIDs.contains(meetingID) }
    }

    /// Notu verilen kayıtla (şablon, adlar) yeniden yazar; eski not `reason` ile geçmişe girer. Yeni not diskteki güncel
    /// kayda uygulanır (Mac'te bu arada yapılan düzenlemeler korunur); olmazsa neden sorunlarda görünür.
    private func rewriteNote(record: MeetingRecord, reason: String) async {
        let meetingID: String = record.id
        regeneratingIDs.insert(meetingID)
        defer { regeneratingIDs.remove(meetingID) }
        // Kabul edilen konuşmacı önerileri artık notta; bekleyen öneri yoksa inceleme kartı kapanır.
        speakerReviews[meetingID] = speakerReviewAfterNoteRewrite(state: speakerReviews[meetingID])
        do {
            let llm: LLMProvider = try phoneRecordedMeetingLLMProvider(recordID: meetingID)
            let directory: URL = try sessionDirectory(id: meetingID)
            let noteStartedAt: ContinuousClock.Instant = .now
            let result: MeetingRecord = await AINotepadCore.regenerateNote(
                record: record, directory: directory, llm: llm, userName: userName, profile: userProfile, language: phoneNoteLanguage(), screens: phoneScreenNotesPlan()
            )
            recordNoteOutcome(result: result, writingStartedAt: noteStartedAt)
            // Not yazılırken Mac'te değişmiş olabilir: yeni not diskteki güncel kayda uygulanır, işaretler oradan taşınır.
            let fresh: MeetingRecord = try loadMeeting(directory: directory)
            let merged: MeetingRecord = applyingRegeneratedNote(result: result, original: record, fresh: fresh)
            // Seçilen şablon toplantıda kalır (bir sonraki "Notu yenile" de onu kullanır).
            let templated: MeetingRecord = record.template.map { merged.with(template: $0) } ?? merged
            // Eski not geçmişe girer (⋯ › Önceki sürümler).
            let versioned: MeetingRecord = withNoteVersion(updated: templated, previous: fresh, reason: reason, savedAt: Date())
            try saveMeeting(record: versioned, directory: directory)
            upsert(record: versioned)
        } catch {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Not yenilenemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Transkriptte "Çeviri alınamadı · Tekrar dene" (Mac'teki gibi): toplantı sonu çevirisi yapılamayan parçalar hesaptan
    /// yeniden çevrilir. Çeviri sürerken toplantı kilitlidir; sonuç diskteki güncel kayda uygulanır (bu arada transkript
    /// değiştiyse uygulanmaz). Yine çevrilemeyen parçalar "Tekrar dene"de kalır.
    func retryTranscriptTranslations(meetingID: String) async {
        guard let record = rewritableRecord(meetingID: meetingID), !(record.failedTranslationKeys ?? []).isEmpty else {
            return
        }
        regeneratingIDs.insert(meetingID)
        defer { regeneratingIDs.remove(meetingID) }
        do {
            let llm: LLMProvider = try phoneAccountLLMProvider()
            let directory: URL = try sessionDirectory(id: meetingID)
            let translated: MeetingRecord = await retryingFailedTranscriptTranslations(
                record: record, llm: llm, language: phoneNoteLanguage(), userName: userName
            )
            let updated: MeetingRecord = withTranscriptTranslations(from: translated, onto: try loadMeeting(directory: directory))
            try saveMeeting(record: updated, directory: directory)
            upsert(record: updated)
        } catch {
            Self.logger.error("Transkript çevirisi yenilenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Çeviri: \(userFacingMessage(error: error))"))
        }
    }

    /// Notu verilen dile çevirir ve toplantıda saklar (Mac'teki notun dil menüsü; sunucuda `shared_note_translation`).
    /// Tam bir çevirisi zaten saklıysa (`sharedNoteVersion`) bir şey yapmaz; not değişince saklı çeviriler silinir.
    /// Çeviri sürerken not yeniden yazıldıysa eski notun çevirisi saklanmaz (sayfa yeni not için yeniden ister).
    /// Çevrilemezse ya da saklanamazsa hata fırlar (sayfa nedeni ve "Yeniden dene"yi gösterir).
    func translateNote(meetingID: String, language: ShareLanguage) async throws {
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note else {
            throw StorageError.writeFailed(path: meetingID, reason: "toplantı ya da not yok")
        }
        if sharedNoteVersion(record: record, language: language) != nil {
            return
        }
        let provider: LLMProvider = try phoneAccountLLMProvider()
        let shared: MeetingNote = try await requestStructured(
            provider: provider, request: sharedNoteRequest(note: note, language: language, userName: userName)
        ) { (text: String) throws -> MeetingNote in
            try parseSharedNote(text: text, original: note).with(language: language)
        }
        guard let current = meetings.first(where: { $0.id == meetingID }), current.note == note else {
            Self.logger.info("Çeviri saklanmadı: not bu arada değişti, toplantı: \(meetingID, privacy: .public)")
            return
        }
        try updateMeeting(meetingID: meetingID) { (fresh: MeetingRecord) -> MeetingRecord in
            fresh.note == note ? fresh.with(sharedNotes: (fresh.sharedNotes ?? [:]).merging([language.rawValue: shared]) { $1 }) : fresh
        }
    }

    // MARK: Konuşmacı incelemesi

    /// Toplantı sayfasındaki "Gözden geçir" kartları (toplantı kimliğiyle; Mac'teki `speakerReviews`).
    private(set) var speakerReviews: [String: SpeakerReviewState] = [:]
    @ObservationIgnored private var speakerReviewTasks: [String: Task<Void, Never>] = [:]

    /// Akıllı model transkriptin tamamını okuyup ad, birleştirme ve şüpheli an önerir (sunucuda `speaker_review`);
    /// öneriler kartta tek tek kabul ya da reddedilir (yanlış bir öneri sessizce notu bozmasın diye otomatik uygulanmaz).
    /// Kayıttaki, işlenen ya da notu yazılan toplantıda ya da numaralı konuşmacı yoksa yapılmaz.
    func reviewSpeakers(meetingID: String) {
        guard let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording, record.status != .processing,
              !regeneratingIDs.contains(meetingID) else {
            return
        }
        let segments: [StoredSegment] = meetingSegments(record: record)
        guard let request = speakerReviewRequest(
            segments: segments, speakerNames: record.speakerNames, userName: userName, attendees: record.attendees ?? [], language: phoneNoteLanguage()
        ) else {
            return
        }
        let persons: Set<Int> = Set(segments.compactMap(\.person))
        let names: [Int: String] = record.speakerNames
        speakerReviewTasks[meetingID]?.cancel()
        speakerReviews[meetingID] = .loading
        speakerReviewTasks[meetingID] = Task { [weak self] in
            let state: SpeakerReviewState
            do {
                let provider: LLMProvider = try phoneAccountLLMProvider()
                let review: SpeakerReview = try await requestStructured(provider: provider, request: request) { (text: String) throws -> SpeakerReview in
                    try parseSpeakerReview(text: text, persons: persons, speakerNames: names)
                }
                state = .ready(review: review, applied: 0)
            } catch {
                // Hata gövdesi toplantı metni içerebilir: yalnızca özel (private) loglanır.
                Self.logger.error("Konuşmacı incelemesi başarısız, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                state = .failed(userFacingMessage(error: error))
            }
            // Kart kapatıldıysa ya da yeni inceleme başladıysa sonuç yazılmaz.
            guard let self, !Task.isCancelled else {
                return
            }
            self.speakerReviews[meetingID] = state
            self.speakerReviewTasks[meetingID] = nil
        }
    }

    /// Kartı kapatır ve süren incelemeyi iptal eder.
    func closeSpeakerReview(meetingID: String) {
        speakerReviewTasks[meetingID]?.cancel()
        speakerReviewTasks[meetingID] = nil
        speakerReviews[meetingID] = nil
    }

    /// Ad önerisini uygular (ad her yerde hemen görünür: transkript, not, görevler). Bu arada elle birleştirilen kişiye
    /// ad verilmez, öneri yalnızca düşer. Ad saklanamazsa öneri kartta kalır, neden sorunlarda görünür.
    func acceptNameSuggestion(meetingID: String, suggestion: SpeakerNameSuggestion) {
        guard case .ready(let review, let applied) = speakerReviews[meetingID] else {
            return
        }
        guard currentPersons(meetingID: meetingID).contains(suggestion.person) else {
            speakerReviews[meetingID] = .ready(review: review.removingName(person: suggestion.person), applied: applied)
            return
        }
        do {
            try renameSpeakers(meetingID: meetingID, names: [suggestion.person: suggestion.name])
            speakerReviews[meetingID] = .ready(review: review.removingName(person: suggestion.person), applied: applied + 1)
        } catch {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Ad kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }

    func dismissNameSuggestion(meetingID: String, suggestion: SpeakerNameSuggestion) {
        guard case .ready(let review, let applied) = speakerReviews[meetingID] else {
            return
        }
        speakerReviews[meetingID] = .ready(review: review.removingName(person: suggestion.person), applied: applied)
    }

    /// Birleştirme önerisini uygular; kalan öneriler yeni numaralara taşınır. Birleştirilemezse öneri kartta kalır, neden
    /// sorunlarda görünür.
    func acceptMergeSuggestion(meetingID: String, suggestion: SpeakerMergeSuggestion) {
        guard case .ready(let review, let applied) = speakerReviews[meetingID] else {
            return
        }
        guard currentPersons(meetingID: meetingID).isSuperset(of: [suggestion.from, suggestion.into]) else {
            speakerReviews[meetingID] = .ready(review: review.removingMerge(from: suggestion.from, into: suggestion.into), applied: applied)
            return
        }
        do {
            try mergeSpeakers(meetingID: meetingID, from: suggestion.from, into: suggestion.into)
            speakerReviews[meetingID] = .ready(review: review.afterMerge(from: suggestion.from, into: suggestion.into), applied: applied + 1)
        } catch {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Konuşmacılar birleştirilemedi: \(userFacingMessage(error: error))"))
        }
    }

    func dismissMergeSuggestion(meetingID: String, suggestion: SpeakerMergeSuggestion) {
        guard case .ready(let review, let applied) = speakerReviews[meetingID] else {
            return
        }
        speakerReviews[meetingID] = .ready(review: review.removingMerge(from: suggestion.from, into: suggestion.into), applied: applied)
    }

    /// Toplantının şu anki kişi numaraları (gösterilen bölümlerden).
    private func currentPersons(meetingID: String) -> Set<Int> {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            return []
        }
        return Set(meetingSegments(record: record).compactMap(\.person))
    }

    /// İki konuşmacıyı birleştirir (Mac'teki "… ile birleştir"; son geçiş aynı kişiyi ikiye böldüyse): `from`un tüm
    /// bölümleri `into`ya geçer.
    func mergeSpeakers(meetingID: String, from: Int, into: Int) throws {
        try updateMeeting(meetingID: meetingID) { (record: MeetingRecord) -> MeetingRecord in mergingPersons(record: record, from: from, into: into) }
    }

    /// Toplantının yalnız sesini (ve ses izlerini) siler; metin ve not kalır (Mac'teki "Sesi sil").
    func deleteAudio(meetingID: String) throws {
        guard meetingID != playingMeetingID, let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording,
              record.status != .processing, record.status != .queued, !regeneratingIDs.contains(meetingID) else {
            throw StorageError.deleteFailed(path: meetingID, reason: "çalıyor, kayıtta, işleniyor ya da işlenmeyi bekliyor")
        }
        let directory: URL = try sessionDirectory(id: meetingID)
        try deleteAudioFiles(directory: directory)
        let updated: MeetingRecord = try loadMeeting(directory: directory).withAudioDeleted().with(voiceprints: nil)
        try saveMeeting(record: updated, directory: directory)
        upsert(record: updated)
    }

    /// Notu kullanıcının isteğine göre düzenler (Mac'teki "Notu değiştir": "özeti kısalt", "görevlere tarih ekle").
    /// Düzenlenirken toplantı kilitlidir; eski not geçmişe girer (⋯ › Önceki sürümler ile geri alınır). Düzenlenen not
    /// diskteki güncel kayda uygulanır (Mac'te bu arada yapılan düzenlemeler korunur). Olmazsa not değişmez ve neden
    /// sorunlarda görünür.
    func editNote(meetingID: String, instruction: String) async {
        let trimmed: String = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let record = meetings.first(where: { $0.id == meetingID }), record.note != nil,
              record.status != .recording, record.status != .processing, !regeneratingIDs.contains(meetingID) else {
            return
        }
        regeneratingIDs.insert(meetingID)
        defer { regeneratingIDs.remove(meetingID) }
        do {
            let llm: LLMProvider = try phoneAccountLLMProvider()
            let directory: URL = try sessionDirectory(id: meetingID)
            let edited: MeetingRecord = try await editMeetingNote(record: record, instruction: trimmed, llm: llm, userName: userName, profile: userProfile)
            guard let note = edited.note else {
                throw LLMError.empty
            }
            // Not düzenlenirken Mac'te değişmiş olabilir (başlık, adlar, görev işaretleri): yeni not diskteki güncel kayda
            // uygulanır, işaretler oradan taşınır; diskteki not geçmişe girer.
            let fresh: MeetingRecord = try loadMeeting(directory: directory)
            let versioned: MeetingRecord = withNoteVersion(
                updated: withCarriedTaskMarks(old: fresh, new: fresh.with(note: note)), previous: fresh,
                reason: String(localized: "Düzenlendi: \(trimmed)"), savedAt: Date()
            )
            try saveMeeting(record: versioned, directory: directory)
            upsert(record: versioned)
        } catch {
            Self.logger.error("Not düzenlenemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Not düzenlenemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// Toplantının notundan `language` dilinde takip e-postası taslağı yazar (Mac'teki "Takip e-postası yaz"); toplantı
    /// değişmez, taslak saklanmaz. Çağrı not düzenleme gibi hesaptan gider (hakkı yoksa `phoneAccountLLMProvider` durur);
    /// not yoksa `LLMError.empty`.
    func draftFollowUpEmail(meetingID: String, language: ShareLanguage) async throws -> FollowUpEmailDraft {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            throw StorageError.writeFailed(path: meetingID, reason: "toplantı yok")
        }
        let llm: LLMProvider = try phoneAccountLLMProvider()
        return try await AINotepadCore.draftFollowUpEmail(record: record, userName: userName, profile: userProfile, language: language, timeZone: TimeZone.current, llm: llm)
    }

    /// Takip e-postasının alıcıları: toplantı bir takvim etkinliğine bağlıysa katılımcıların e-posta adresleri (takvim
    /// izni varsa), değilse boş.
    func followUpRecipients(meetingID: String) -> [String] {
        guard let eventID = meetings.first(where: { $0.id == meetingID })?.calendarEventID else {
            return []
        }
        return eventKit.attendeeEmails(calendarEventID: eventID)
    }

    /// Notun önceki sürümünü geri yükler (`index`: geçmişte yeniden eskiye sıra); şimdiki not geçmişe girer. Kayıttaki,
    /// işlenen ya da notu yazılan toplantıda yapılmaz. Seçilen sürüm diskteki güncel kayıtta aranır ve ona uygulanır
    /// (Mac'te iCloud'la gelmiş düzenlemeler ezilmesin); geçmiş bu arada değiştiyse sıra numarası değil sürümün kendisi
    /// geri yüklenir, artık yoksa `versionNotFound`.
    func restoreNoteVersion(meetingID: String, index: Int) throws {
        guard let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording, record.status != .processing,
              !regeneratingIDs.contains(meetingID) else {
            throw StorageError.writeFailed(path: meetingID, reason: "kayıtta ya da işleniyor")
        }
        let shown: [NoteVersion] = record.noteHistory ?? []
        guard shown.indices.contains(index) else {
            throw NoteHistoryError.versionNotFound(index: index, count: shown.count)
        }
        let directory: URL = try sessionDirectory(id: meetingID)
        let fresh: MeetingRecord = try loadMeeting(directory: directory)
        let freshHistory: [NoteVersion] = fresh.noteHistory ?? []
        guard let freshIndex = freshHistory.firstIndex(of: shown[index]) else {
            throw NoteHistoryError.versionNotFound(index: index, count: freshHistory.count)
        }
        let restored: MeetingRecord = try restoringNoteVersion(
            record: fresh, index: freshIndex, reason: String(localized: "Önceki sürüm geri yüklendi"), savedAt: Date()
        )
        try saveMeeting(record: restored, directory: directory)
        upsert(record: restored)
    }

    /// Toplantının klasörü (klasör adı toplantı kimliğidir).
    func sessionDirectory(id: String) throws -> URL {
        try AppPaths.meetingDirectory(id: id, location: .local)
    }

    /// Toplantının ses kayıtları ("Diğerleri" önce); ses silindiyse ya da hiç yoksa boş.
    func audioURLs(record: MeetingRecord) throws -> [URL] {
        guard !record.audioDeleted else {
            return []
        }
        let directory: URL = try sessionDirectory(id: record.id)
        return [Speaker.others, Speaker.me].compactMap { meetingAudioURL(directory: directory, speaker: $0) }
    }
}

/// Yeniden yazılan notu (`result`, bellekteki `original`'dan üretildi) diskteki güncel kayda (`fresh`) uygular: Mac'te bu
/// arada yapılan düzenlemeler (ad, başlık, görev işaretleri) korunur, işaretler yeni görevlere taşınır. Not bu yenilemede
/// değişmediyse (ör. LLM hatası) diskteki not olduğu gibi kalır, yalnızca durum ve hata yazılır. Saf fonksiyondur.
func applyingRegeneratedNote(result: MeetingRecord, original: MeetingRecord, fresh: MeetingRecord) -> MeetingRecord {
    let withStatus: MeetingRecord = fresh.with(status: result.status, failureMessage: result.failureMessage)
    guard let note = result.note, note != original.note else {
        return withStatus
    }
    return withCarriedTaskMarks(old: fresh, new: withStatus.with(note: note))
}
