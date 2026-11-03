import AINotepadCore
import AINotepadUI
import AppIntents
import os
import SwiftUI
import UIKit
import UserNotifications

private let phoneAppLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "App")

/// iPhone uygulaması (Gistsmith): önce giriş (Apple ya da Google, Mac'teki Gistsmith'le aynı hesap), sonra bir kez yapay
/// zekâ işleme açıklaması, sonra sekmeler (Kayıt, Toplantılar, Sor, Görevler, Ayarlar). Mac'le aynı çekirdeği ve
/// görünümü kullanır; toplantılar giriş yapan hesabın bu iPhone'daki klasöründe durur (iCloud eşitlemesi yok).
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

    init() {
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
            // `--aciklama`: yapay zekâ açıklaması yeniden gösterilir (görsel kontrol).
            UserDefaults.standard.set(!CommandLine.arguments.contains("--aciklama"), forKey: PhoneSettingsKey.aiDisclosureAccepted)
            UserDefaults.standard.set(true, forKey: PhoneSettingsKey.onboardingCompleted)
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
        let router: PhoneRouter = PhoneRouter(
            tab: launchTab(arguments: CommandLine.arguments), meetingsPath: launchMeetingPath(arguments: CommandLine.arguments), askPath: []
        )
        _sessions = State(initialValue: sessions)
        _router = State(initialValue: router)
        _calendar = State(initialValue: calendar)
        // Kısayollar, Denetim Merkezi ve canlı etkinlikteki niyetler yüklü hesabın kaydedicisine ve gezinmeye buradan
        // ulaşır (hesap değişince kaydedici değişir, kayıt yeri değişmez).
        AppDependencyManager.shared.add(dependency: sessions)
        AppDependencyManager.shared.add(dependency: router)
        // Toplantı hatırlatmasındaki "Dinlemeye başla" kaydı başlatır (kısayoldaki gibi).
        PhoneNotificationDelegate.onStartRecording = { () -> Void in
            router.tab = .record
            Task { await sessions.session.recorder.start() }
        }
        UNUserNotificationCenter.current().delegate = PhoneNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            PhoneAppRoot(account: account, sessions: sessions, router: router, calendar: calendar, crashReports: crashReports)
            .modifier(PhoneAppearanceModifier())
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

/// Kullanıcının görünüm ayarları (vurgu rengi, yazı tipi, yazı ölçeği, okuma metni boyutu ve satır aralığı) tüm arayüze:
/// ortam, yazı ve renk tonu; ayar değişince hemen uygulanır. Sistemin yazı boyutu (Dinamik Yazı) ayarların üstüne çarpılır.
private struct PhoneAppearanceModifier: ViewModifier {
    @AppStorage(PhoneSettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(PhoneSettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontChoice.storageValue
    @AppStorage(PhoneSettingsKey.uiScale) private var uiScale: Double = PanelAppearance.standard.uiScale
    @AppStorage(PhoneSettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(PhoneSettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    func body(content: Content) -> some View {
        let standard: PanelAppearance = .standard
        let appearance: PanelAppearance = resolvedPanelAppearance(stored: StoredAppearance(
            fontDesign: fontDesign, uiScale: uiScale, textSize: textSize, lineSpacing: lineSpacing, bottomSpacing: standard.bottomSpacing,
            accent: accent, surface: standard.surface.rawValue, surfaceOpacity: standard.surfaceOpacity
        ))
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
    @AppStorage(PhoneSettingsKey.aiDisclosureAccepted) private var disclosureAccepted: Bool = false
    @AppStorage(PhoneSettingsKey.theme) private var theme: String = AppTheme.system.rawValue

    var body: some View {
        let session: PhoneAccountSession = sessions.session
        Group {
            if phoneShowsSignInGate(requiresSignIn: account.requiresSignIn, isRecording: session.recorder.phase != .idle) {
                PhoneSignInGate(account: account, switchWaitsFor: session.openWriters)
            } else if !disclosureAccepted {
                PhoneAIDisclosure(account: account) { disclosureAccepted = true }
            } else {
                RootView(
                    store: session.store, recorder: session.recorder, ask: session.ask, router: router, player: session.player, calendar: calendar,
                    crashReports: crashReports, account: account
                )
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
        .task(id: account.dataState) {
            guard account.isAccountDataLoaded else {
                return
            }
            let store: PhoneStore = sessions.session.store
            let recorder: PhoneRecorder = sessions.session.recorder
            let ask: PhoneAsk = sessions.session.ask
            // Saklama süresi ve yarım kalan kayıtlar listeye bakar: okuma bitince sürer. Okuma sürerken hesap değiştiyse
            // (görev iptal edildi) eski hesabın listesiyle hiçbir şey yazılmaz.
            await store.reloadAndWait()
            guard !Task.isCancelled else {
                return
            }
            store.loadPeople()
            ask.loadRecipes()
            ask.loadHistory()
            store.applyRetention(now: Date())
            #if DEBUG
            // `--paywall`: abonelik ekranı doğrudan açılır (App Store abonelik inceleme görseli).
            if CommandLine.arguments.contains("--paywall") {
                account.showPlans()
            }
            // `--sohbet <kimlik>`: saklanan Sor sohbeti tam ekran açılır (ekran görüntüleri).
            if let conversationID = launchConversationID(arguments: CommandLine.arguments) {
                ask.open(conversationID: conversationID)
                router.tab = .ask
                router.askPath = [.conversation]
            }
            if CommandLine.arguments.contains("--ornek-takvim") {
                calendar.showSampleMeetings(now: Date())
            }
            if CommandLine.arguments.contains("--ornek-kayit") {
                recorder.showSampleRecording()
                // `--ornek-bitir`: örnek kayıt "Bitir"e basılmış gibi bitiriliyor (hazırlık katmanı, durmuş süre).
                if CommandLine.arguments.contains("--ornek-bitir") {
                    recorder.showSampleFinishing()
                }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--soru"), CommandLine.arguments.indices.contains(index + 1) {
                ask.ask(question: CommandLine.arguments[index + 1], meetingIDs: [], recipeTitle: nil)
                router.askPath = [.conversation]
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
        }
        .onChange(of: session.openWriters) { (_: [AccountDataWriter], _: [AccountDataWriter]) in
            switchAccountIfIdle()
        }
        .onChange(of: account.signedInUserIDCache, initial: true) { (_: String?, userID: String?) in
            // RevenueCat kimliği hesapla eşlenir: giriş, çıkış, hesap değişimi ve silme (satın alma bu hesaba yazılsın).
            #if DEBUG
            if isDemoMode {
                return
            }
            #endif
            AppStorePurchases.shared.syncIdentity(userID: userID)
        }
        .onChange(of: account.queueTrigger) { (_: Int, _: Int) in
            guard account.isAccountDataLoaded else {
                return
            }
            let recorder: PhoneRecorder = sessions.session.recorder
            Task { await recorder.runQueue() }
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

    /// Hesabın verisine yazan açık işler (bkz. `phoneOpenWriters`).
    var openWriters: [AccountDataWriter] {
        phoneOpenWriters(store: store, recorder: recorder, ask: ask)
    }

    /// Hesap değişmeden önce eski hesabın açık dosyalarını bırakır: çalan toplantı durur.
    func close() {
        player.stop()
    }
}

/// Giriş kapısı gösterilsin mi: giriş gerekiyorsa, ama kayıt sürerken değil (oturum kayıt sırasında kapandıysa kayıt
/// ekranı ve "Bitir" kalır; kapı kayıt bitip toplantı saklanınca açılır). Saf fonksiyondur.
func phoneShowsSignInGate(requiresSignIn: Bool, isRecording: Bool) -> Bool {
    requiresSignIn && !isRecording
}

/// Hesabın verisine yazan açık işler (bkz. `accountSwitchReadiness`): kayıt, işleme, bekleyen kayıtların kuyruğu, dosya
/// içe aktarma, not yazma ve Sor cevabı. Hesap değişimi bunları bekler; çıkış ve hesap silme bunlar sürerken kapalıdır
/// (içe aktarılan ya da yazılan toplantı başka hesabın klasörüne ya da oturumuna gitmesin).
@MainActor
func phoneOpenWriters(store: PhoneStore, recorder: PhoneRecorder, ask: PhoneAsk) -> [AccountDataWriter] {
    let open: [(AccountDataWriter, Bool)] = [
        (.recording, recorder.phase != .idle),
        (.processing, !recorder.processingSteps.isEmpty),
        (.offlineQueue, recorder.isRunningQueue),
        (.importing, recorder.importingCount > 0),
        (.noteEditing, !store.regeneratingIDs.isEmpty),
        (.askAnswering, ask.isAnswering),
    ]
    return open.filter { $0.1 }.map { $0.0 }
}

/// Yüklü hesabın bellekteki verisini kurar (boş; toplantılar hesap yüklenince okunur). Kayıt başlarken takvimde süren
/// toplantıya bağlanır (takvim açıksa).
@MainActor
func makePhoneAccountSession(calendar: PhoneCalendar) -> PhoneAccountSession {
    let store: PhoneStore = PhoneStore()
    let recorder: PhoneRecorder = PhoneRecorder(store: store)
    recorder.currentCalendarMeeting = { () -> CalendarMeeting? in calendar.meetingForRecording(now: Date()) }
    return PhoneAccountSession(store: store, recorder: recorder, ask: PhoneAsk(store: store), player: MeetingAudioPlayer())
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

/// Sekmelerin üstündeki tam ekran sunum: ilk açılış karşılaması ya da abonelik ekranı (açılma nedeniyle).
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

/// Sekmeler.
enum PhoneTab: String, Hashable {
    case record = "kayit"
    case meetings = "toplantilar"
    case ask = "sor"
    case tasks = "gorevler"
    case settings = "ayarlar"
}

/// Gezinme durumu: seçili sekme, Toplantılar'da açık toplantı (Sor'daki kaynak, görev ya da mini çalar oraya götürür),
/// Sor'da açık sohbet ya da geçmiş ve Sor'un sol üstteki geri okunun döneceği sekme.
@MainActor
@Observable
final class PhoneRouter {
    var tab: PhoneTab {
        didSet {
            if let returnTab = askReturnTarget(previous: oldValue, current: tab) {
                askReturnTab = returnTab
            }
        }
    }
    var meetingsPath: [String]
    var askPath: [AskRoute]
    /// Sor tam ekrandır (sekme çubuğu gizli): sol üstteki geri Sor'a gelinen sekmeye döner.
    private(set) var askReturnTab: PhoneTab = .record

    init(tab: PhoneTab, meetingsPath: [String], askPath: [AskRoute]) {
        self.tab = tab
        self.meetingsPath = meetingsPath
        self.askPath = askPath
    }

    /// Sor'dan çıkar: Sor'a gelinen sekmeye döner.
    func leaveAsk() {
        tab = askReturnTab
    }

    /// Hesap değişince gezinme başa döner: açık toplantı ve sohbet eski hesabındır.
    func reset() {
        tab = .record
        meetingsPath = []
        askPath = []
        askReturnTab = .record
    }

    /// Toplantıyı Toplantılar sekmesinde açar.
    func open(meetingID: String) {
        tab = .meetings
        meetingsPath = [meetingID]
    }
}

/// Sekme değişiminde Sor'un geri okunun döneceği sekme: başka bir sekmeden Sor'a geçildiyse o sekme, yoksa nil (değişmez).
/// Saf fonksiyondur.
func askReturnTarget(previous: PhoneTab, current: PhoneTab) -> PhoneTab? {
    current == .ask && previous != .ask ? previous : nil
}

/// `--sekme kayit|toplantilar|sor|gorevler|ayarlar` başlatma argümanı (görsel kontrol için); yoksa Kayıt. Saf fonksiyondur.
func launchTab(arguments: [String]) -> PhoneTab {
    guard let index = arguments.firstIndex(of: "--sekme"), arguments.indices.contains(index + 1),
          let tab = PhoneTab(rawValue: arguments[index + 1]) else {
        return .record
    }
    return tab
}

/// `--sohbet <kimlik>` başlatma argümanı: saklanan Sor sohbetinin kimliği (görsel kontrol için); yoksa ya da UUID değilse
/// nil. Saf fonksiyondur.
func launchConversationID(arguments: [String]) -> UUID? {
    guard let index = arguments.firstIndex(of: "--sohbet"), arguments.indices.contains(index + 1) else {
        return nil
    }
    return UUID(uuidString: arguments[index + 1])
}

/// `--toplanti <kimlik>` başlatma argümanı toplantıyı doğrudan açar (görsel kontrol için). Saf fonksiyondur.
func launchMeetingPath(arguments: [String]) -> [String] {
    guard let index = arguments.firstIndex(of: "--toplanti"), arguments.indices.contains(index + 1) else {
        return []
    }
    return [arguments[index + 1]]
}

/// Sekme çubuğu; bir toplantı çalarken sekme çubuğunun üstünde mini çalar.
struct RootView: View {
    let store: PhoneStore
    let recorder: PhoneRecorder
    let ask: PhoneAsk
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
        router.askPath = [.conversation]
        router.tab = .ask
    }

    /// Toplantıya tarif uygular (Mac'teki "Tarif"): yeni bir Sor sohbetinde yalnız o toplantıya sorulur.
    private func runRecipe(recipe: Recipe, meetingID: String) {
        guard !account.requiresSubscription else {
            account.requestSubscription()
            return
        }
        ask.clear()
        ask.ask(question: recipe.prompt, meetingIDs: [meetingID], recipeTitle: recipe.title)
        router.askPath = [.conversation]
        router.tab = .ask
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
        TabView(selection: $router.tab) {
            Tab("Kayıt", systemImage: "record.circle", value: PhoneTab.record) {
                RecordTab(recorder: recorder, store: store, router: router, calendar: calendar, onBriefing: startBriefing(meeting:))
            }
            Tab("Toplantılar", systemImage: "list.bullet.rectangle", value: PhoneTab.meetings) {
                MeetingsTab(
                    store: store, recorder: recorder, router: router, player: player, isRecording: recorder.phase != .idle, recipes: ask.recipes,
                    onRunRecipe: runRecipe(recipe:meetingID:)
                )
            }
            Tab("Sor", systemImage: "sparkle.magnifyingglass", value: PhoneTab.ask) {
                AskTab(ask: ask, store: store, router: router)
            }
            Tab("Görevler", systemImage: "checkmark.circle", value: PhoneTab.tasks) {
                TasksTab(store: store, router: router)
            }
            Tab("Ayarlar", systemImage: "gearshape", value: PhoneTab.settings) {
                PhoneSettingsTab(
                    store: store, calendar: calendar, account: account,
                    isMeetingInFlight: !phoneOpenWriters(store: store, recorder: recorder, ask: ask).isEmpty, crashReports: crashReports
                )
            }
        }
        // Görev satırları (Kayıt, Toplantılar, Görevler) Anımsatıcılar'a eklemek için arşive buradan ulaşır.
        .environment(store)
        .tabViewBottomAccessory(isEnabled: player.meetingID != nil) {
            MiniPlayer(player: player, store: store, router: router)
        }
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
                PhoneOnboarding {
                    // Abonelik ekranı karşılamanın yerine aynı güncellemede geçer (karşılama kapanırken yeni sunum
                    // başlatılmaz; sunum kimliği değişince SwiftUI birini kapatıp ötekini açar).
                    if recorder.phase == .idle {
                        showAutoPaywallIfDue()
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
            // Kayıt başlarken çalma durur (mikrofon ve hoparlör aynı oturumu paylaşamaz).
            if phase == .starting {
                player.stop()
            }
        }
        .onChange(of: scenePhase, initial: true) { (_: ScenePhase, phase: ScenePhase) in
            // Takvim açılışta ve uygulama öne gelince yeniden okunur (izin bu arada geri alınmış olabilir).
            if phase == .active {
                calendar.start()
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
/// eşitleme ayrı bir Gistsmith kapsayıcısıyla gelecek, `CloudSyncController` çekirdekte duruyor.)
@MainActor
@Observable
final class PhoneStore {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneStore")
    private(set) var meetings: [MeetingRecord] = []
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

    /// Listeyi arka planda okur; art arda gelen istekleri birleştirir.
    @ObservationIgnored private let reloader: MeetingReloader = MeetingReloader()

    /// Toplantıları arka planda yeniden okur; beklemeden döner.
    func reload() {
        Task { await reloadAndWait() }
    }

    /// Toplantıları diskten yeniden okur (en yeni önce). Okuma ana iş parçacığının dışında yapılır; liste güncellenince
    /// döner.
    func reloadAndWait() async {
        await reloader.reload(load: { () async throws -> MeetingLoadResult in
            try await loadMeetingsInBackground(location: .local)
        }, apply: { (result: MeetingLoadResult) -> Void in
            self.meetings = result.meetings
            self.loadProblems = result.failures.map { (failure: MeetingLoadFailure) -> String in "\(failure.folder): \(failure.reason)" }
        }, fail: { (error: any Error) -> Void in
            self.loadProblems = [userFacingMessage(error: error)]
        })
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

    /// Elle eklenen kişinin adını ve bilgilerini değiştirir.
    func renamePerson(oldName: String, name: String, role: String, email: String) {
        storePeople(book: renamingPerson(book: peopleBook, oldName: oldName, person: SavedPerson(name: name, role: role, email: email, addedAt: Date())))
    }

    /// Kişiyi Kişiler'den kaldırır (toplantılardaki adı kalır).
    func removePerson(name: String) {
        storePeople(book: removingPerson(book: peopleBook, name: name, now: Date()))
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
        meetings = upsertMeeting(records: meetings, record: record)
        // Süren arka plan okuması bu yazmayı görmemiş olabilir: sonucu bu kaydı geri almasın.
        reloader.invalidate()
    }

    /// Konuşmacılara ad verir ("Konuşmacı 2 = Aino"; boş ad etiketi geri getirir). Kayıttaki, işlenen ya da notu
    /// yazılan toplantıda yapılmaz (işleme bitince kayıt bütünüyle yazılır, ad kaybolurdu). Değişiklik diskteki en güncel
    /// kayda uygulanır (Mac'te iCloud'la gelmiş düzenlemeler bellekteki eski kopyayla ezilmesin).
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
        let shown: MeetingRecord = namedRecord(record: record, userName: phoneUserName())
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

    /// Toplantıyı kalıcı olarak siler (onay arayüzde sorulur). Kayıttaki, işlenen ya da notu yazılan toplantı silinmez
    /// (not isteği boşa harcanır, silinmiş toplantı için hata görünürdü).
    func deleteMeeting(id: String) throws {
        guard let record = meetings.first(where: { $0.id == id }), record.status != .recording, record.status != .processing,
              !regeneratingIDs.contains(id) else {
            throw StorageError.deleteFailed(path: id, reason: "kayıtta, işleniyor ya da notu yazılıyor")
        }
        try deleteMeetingDirectory(directory: try sessionDirectory(id: id))
        meetings.removeAll { $0.id == id }
        reloader.invalidate()
    }

    /// Saklama süresi (Ayarlar) dolan toplantıların sesini ve ses izlerini siler; metin ve not kalır. Silinemeyenin
    /// nedeni sorunlarda görünür, bir sonraki açılışta yeniden denenir.
    func applyRetention(now: Date) {
        let days: Int = min(365, max(7, UserDefaults.standard.integer(forKey: PhoneSettingsKey.audioRetentionDays)))
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
    }

    /// Notu yeniden yazılan toplantılar (menüde "Not yazılıyor…").
    private(set) var regeneratingIDs: Set<String> = []

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
        do {
            let llm: LLMProvider = try phoneRecordedMeetingLLMProvider(recordID: meetingID)
            let directory: URL = try sessionDirectory(id: meetingID)
            let noteStartedAt: ContinuousClock.Instant = .now
            let result: MeetingRecord = await AINotepadCore.regenerateNote(
                record: record, directory: directory, llm: llm, userName: phoneUserName(), language: phoneNoteLanguage(), screens: .off
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

    /// Notun verilen dildeki paylaşım kopyası (Mac'teki "Başka dilde paylaş"): daha önce çevrildiyse saklanan kopya, yoksa
    /// not o dile çevrilir ve toplantıda saklanır (not değişince kopyalar silinir). Çevrilemezse hata fırlar; çeviri
    /// saklanamazsa kopya yine döner, neden sorunlarda görünür.
    func sharedNote(meetingID: String, language: ShareLanguage) async throws -> MeetingNote {
        guard let record = meetings.first(where: { $0.id == meetingID }), let note = record.note else {
            throw StorageError.writeFailed(path: meetingID, reason: "toplantı ya da not yok")
        }
        if let cached = record.sharedNotes?[language.rawValue] {
            return cached
        }
        let provider: LLMProvider = try phoneAccountLLMProvider()
        let shared: MeetingNote = try await requestStructured(
            provider: provider, request: sharedNoteRequest(note: note, language: language, userName: phoneUserName())
        ) { (text: String) throws -> MeetingNote in
            try parseSharedNote(text: text, original: note).with(language: language)
        }
        // Çeviri sürerken not yeniden yazıldıysa eski notun çevirisi saklanmaz (yine de paylaşılır).
        guard let current = meetings.first(where: { $0.id == meetingID }), current.note == note else {
            return shared
        }
        do {
            try updateMeeting(meetingID: meetingID) { (fresh: MeetingRecord) -> MeetingRecord in
                fresh.note == note ? fresh.with(sharedNotes: (fresh.sharedNotes ?? [:]).merging([language.rawValue: shared]) { $1 }) : fresh
            }
        } catch {
            actionProblems = appendUnique(messages: actionProblems, message: String(localized: "Çeviri saklanamadı: \(userFacingMessage(error: error))"))
        }
        return shared
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
            let edited: MeetingRecord = try await editMeetingNote(record: record, instruction: trimmed, llm: llm, userName: phoneUserName())
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
