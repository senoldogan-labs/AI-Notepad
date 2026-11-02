import AINotepadCore
import AINotepadUI
import AppIntents
import os
import SwiftUI
import UIKit

private let phoneAppLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "App")

/// iPhone uygulaması (Gistsmith): önce giriş (Apple ya da Google, Mac'teki Gistsmith'le aynı hesap), sonra bir kez yapay
/// zekâ işleme açıklaması, sonra sekmeler (Kayıt, Toplantılar, Sor, Görevler, Ayarlar). Mac'le aynı çekirdeği ve
/// görünümü kullanır; toplantılar giriş yapan hesabın bu iPhone'daki klasöründe durur (iCloud eşitlemesi yok).
@main
struct AINotepadiOSApp: App {
    /// Abonelik hesabı (giriş, hak durumu, toplantı oturumu); Mac'teki Gistsmith'le ortak.
    private let account: HostedAccount
    @State private var store: PhoneStore
    @State private var recorder: PhoneRecorder
    @State private var ask: PhoneAsk
    @State private var router: PhoneRouter
    @State private var player: MeetingAudioPlayer = MeetingAudioPlayer()
    @State private var calendar: PhoneCalendar
    /// Çökme raporları (MetricKit; yalnız bu iPhone'da, Ayarlar'da gösterilir).
    @State private var crashReports: CrashReportCenter = CrashReportCenter()

    init() {
        registerPhoneDefaults()
        keepPhoneLegacyNoteLanguage(defaults: .standard)
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
        let store: PhoneStore = PhoneStore()
        let recorder: PhoneRecorder = PhoneRecorder(store: store)
        let calendar: PhoneCalendar = PhoneCalendar()
        // Kayıt başlarken takvimde süren toplantıya bağlanır (takvim açıksa).
        recorder.currentCalendarMeeting = { () -> CalendarMeeting? in calendar.meetingForRecording(now: Date()) }
        let router: PhoneRouter = PhoneRouter(
            tab: launchTab(arguments: CommandLine.arguments), meetingsPath: launchMeetingPath(arguments: CommandLine.arguments), askPath: []
        )
        _store = State(initialValue: store)
        _recorder = State(initialValue: recorder)
        _router = State(initialValue: router)
        _calendar = State(initialValue: calendar)
        _ask = State(initialValue: PhoneAsk(store: store))
        // Kısayollar, Denetim Merkezi ve canlı etkinlikteki niyetler kaydediciye ve gezinmeye buradan ulaşır.
        AppDependencyManager.shared.add(dependency: recorder)
        AppDependencyManager.shared.add(dependency: router)
    }

    var body: some Scene {
        WindowGroup {
            PhoneAppRoot(
                account: account, store: store, recorder: recorder, ask: ask, router: router, player: player, calendar: calendar,
                crashReports: crashReports
            )
            .modifier(PhoneAppearanceModifier())
            .task {
                crashReports.start()
                HostedTelemetryCenter.shared.start()
            }
        }
    }
}

/// Kullanıcının görünüm ayarı (vurgu rengi) tüm arayüze: ortam, yazı ve renk tonu; ayar değişince hemen uygulanır.
private struct PhoneAppearanceModifier: ViewModifier {
    @AppStorage(PhoneSettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue

    func body(content: Content) -> some View {
        let appearance: PanelAppearance = phoneAppearance(accentRawValue: accent)
        content
            .environment(\.panelAppearance, appearance)
            .font(appearance.font(size: 15, weight: .regular))
            .tint(appearance.accent.color)
            // Menü biçimli seçiciler ve sistem sayfaları rengi SwiftUI ortamından değil pencereden alır.
            .onChange(of: accent, initial: true) { (_: String, _: String) in
                applyWindowTint(color: UIColor(appearance.accent.color))
            }
    }
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

/// Giriş kapısı, yapay zekâ açıklaması ya da sekmeler. Hesabın verisi yüklenince (açılışta ya da ilk girişte)
/// toplantılar, Sor geçmişi ve yarım kalan işlemeler okunur; hesap bekleyen kayıtların işlenmesini tetikleyince (ağ
/// geldi, hak durumu okundu, uygulama öne geldi) kuyruk çalışır.
private struct PhoneAppRoot: View {
    let account: HostedAccount
    let store: PhoneStore
    let recorder: PhoneRecorder
    let ask: PhoneAsk
    let router: PhoneRouter
    let player: MeetingAudioPlayer
    let calendar: PhoneCalendar
    let crashReports: CrashReportCenter
    @AppStorage(PhoneSettingsKey.aiDisclosureAccepted) private var disclosureAccepted: Bool = false

    var body: some View {
        Group {
            if account.requiresSignIn {
                PhoneSignInGate(account: account)
            } else if !disclosureAccepted {
                PhoneAIDisclosure(account: account) { disclosureAccepted = true }
            } else {
                RootView(store: store, recorder: recorder, ask: ask, router: router, player: player, calendar: calendar, crashReports: crashReports, account: account)
            }
        }
        .task(id: account.isAccountDataLoaded) {
            guard account.isAccountDataLoaded else {
                return
            }
            // Saklama süresi ve yarım kalan kayıtlar listeye bakar: okuma bitince sürer.
            await store.reloadAndWait()
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
            Task { await recorder.runQueue() }
        }
    }
}

/// Abonelik ekranının açılma isteği (tam ekran sunum için kimlikli).
struct PaywallRequest: Identifiable {
    let reason: HostedUpsellMoment
    var id: String { reason.rawValue }
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

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Kayıt", systemImage: "record.circle", value: PhoneTab.record) {
                RecordTab(recorder: recorder, store: store, router: router, calendar: calendar)
            }
            Tab("Toplantılar", systemImage: "list.bullet.rectangle", value: PhoneTab.meetings) {
                MeetingsTab(store: store, router: router, player: player, isRecording: recorder.phase != .idle)
            }
            Tab("Sor", systemImage: "sparkle.magnifyingglass", value: PhoneTab.ask) {
                AskTab(ask: ask, store: store, router: router)
            }
            Tab("Görevler", systemImage: "checkmark.circle", value: PhoneTab.tasks) {
                TasksTab(store: store, router: router)
            }
            Tab("Ayarlar", systemImage: "gearshape", value: PhoneTab.settings) {
                PhoneSettingsTab(
                    store: store, calendar: calendar, account: account, isMeetingInFlight: recorder.phase != .idle || !recorder.busyMeetingIDs.isEmpty,
                    crashReports: crashReports
                )
            }
        }
        // Görev satırları (Kayıt, Toplantılar, Görevler) Anımsatıcılar'a eklemek için arşive buradan ulaşır.
        .environment(store)
        .tabViewBottomAccessory(isEnabled: player.meetingID != nil) {
            MiniPlayer(player: player, store: store, router: router)
        }
        // Abonelik ekranı: "Abone ol" (Hesap, kayıt kartı), deneme bitince bir kez ve sunucu aboneliği isteyince
        // (`HostedAccount.upsell`).
        .fullScreenCover(item: Binding<PaywallRequest?>(
            get: { account.upsell.map { PaywallRequest(reason: $0) } },
            set: { (request: PaywallRequest?) -> Void in
                if request == nil {
                    account.dismissUpsell()
                }
            }
        )) { (request: PaywallRequest) in
            PhonePaywall(account: account, reason: request.reason) { account.dismissUpsell() }
        }
        .onChange(of: phoneAutoPaywallKey(state: account.state), initial: true) { (_: String?, key: String?) in
            // Deneme bitince (ya da abonelik sona erince) abonelik ekranı bir kez kendiliğinden açılır; kayıt sürerken açılmaz.
            guard let key, recorder.phase == .idle, !UserDefaults.standard.bool(forKey: key) else {
                return
            }
            #if DEBUG
            if isDemoMode {
                return
            }
            #endif
            UserDefaults.standard.set(true, forKey: key)
            account.showPlans()
        }
        .fullScreenCover(isPresented: Binding<Bool>(get: { !onboardingCompleted }, set: { (_: Bool) -> Void in })) {
            PhoneOnboarding {
                onboardingCompleted = true
            }
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
    /// Okunamayan klasörler ya da klasöre erişim hatası (kullanıcıya gösterilir).
    private(set) var problems: [String] = []
    /// Çalan toplantı: sesi saklama süresiyle silinmez (dosyaları kullanımda).
    var playingMeetingID: String?

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
            self.problems = result.failures.map { (failure: MeetingLoadFailure) -> String in "\(failure.folder): \(failure.reason)" }
        }, fail: { (error: any Error) -> Void in
            self.problems = [userFacingMessage(error: error)]
        })
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
        try await eventKit.addReminder(draft: reminderDraft(record: record, task: task, language: note.writtenLanguage, calendar: Calendar.current))
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
            problems = appendUnique(messages: problems, message: String(localized: "Notların kaydedilemedi: \(userFacingMessage(error: error))"))
            return
        }
        await regenerateNote(meetingID: meetingID)
    }

    /// Görevin tamamlandı işaretini değiştirir ve toplantıyı saklar. Değişiklik diskteki en güncel kayda uygulanır
    /// (Mac'te iCloud'la gelmiş düzenlemeler bellekteki eski kopyayla ezilmesin).
    func toggleTask(meetingID: String, task: NoteTask) {
        guard let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording, record.status != .processing else {
            return
        }
        do {
            let directory: URL = try sessionDirectory(id: meetingID)
            let updated: MeetingRecord = togglingTask(record: try loadMeeting(directory: directory), task: task)
            try saveMeeting(record: updated, directory: directory)
            upsert(record: updated)
        } catch {
            problems = appendUnique(messages: problems, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
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
                problems = appendUnique(messages: problems, message: userFacingMessage(error: error))
            }
        }
    }

    /// Notu yeniden yazılan toplantılar (menüde "Not yazılıyor…").
    private(set) var regeneratingIDs: Set<String> = []

    /// Notu yeniden yazar (Mac'teki "Notu yenile"): başarısız ya da yarım kalan toplantı da iPhone'dan düzelir.
    func regenerateNote(meetingID: String) async {
        guard let record = meetings.first(where: { $0.id == meetingID }), record.status != .recording, record.status != .processing,
              !regeneratingIDs.contains(meetingID) else {
            return
        }
        regeneratingIDs.insert(meetingID)
        defer { regeneratingIDs.remove(meetingID) }
        do {
            let llm: LLMProvider = try phoneRecordedMeetingLLMProvider(recordID: meetingID)
            let directory: URL = try sessionDirectory(id: meetingID)
            let userName: String = UserDefaults.standard.string(forKey: PhoneSettingsKey.userName) ?? ""
            let result: MeetingRecord = await AINotepadCore.regenerateNote(record: record, directory: directory, llm: llm, userName: userName, language: phoneNoteLanguage())
            // Not yazılırken Mac'te değişmiş olabilir: yeni not diskteki güncel kayda uygulanır, işaretler oradan taşınır.
            let fresh: MeetingRecord = try loadMeeting(directory: directory)
            let merged: MeetingRecord = applyingRegeneratedNote(result: result, original: record, fresh: fresh)
            // Eski not geçmişe girer (⋯ › Önceki sürümler).
            let versioned: MeetingRecord = withNoteVersion(updated: merged, previous: fresh, reason: String(localized: "Not yenilendi"), savedAt: Date())
            try saveMeeting(record: versioned, directory: directory)
            upsert(record: versioned)
        } catch {
            problems = appendUnique(messages: problems, message: String(localized: "Not yenilenemedi: \(userFacingMessage(error: error))"))
        }
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
            problems = appendUnique(messages: problems, message: String(localized: "Not düzenlenemedi: \(userFacingMessage(error: error))"))
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
