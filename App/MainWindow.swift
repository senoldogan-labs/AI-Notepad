import AINotepadCore
import AINotepadUI
import AppKit
import os
import SwiftUI
import UserNotifications

private let appDelegateLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AppDelegate")

/// Ana pencerenin sahne kimliği.
let mainWindowID: String = "main"

extension Notification.Name {
    /// Ana pencereyi açma isteği (menü, Dock simgesi, kısayol). Menü çubuğu simgesi her zaman çizildiği için onu dinler
    /// ve SwiftUI'nin `openWindow` eylemiyle pencereyi açar.
    static let openMainWindow: Notification.Name = Notification.Name("com.senoldogan.AINotepad.openMainWindow")
}

/// Ana pencerenin bölümleri (kenar çubuğu).
enum MainSection: Hashable {
    case home
    case meetings
    case ask
    case people
    case tasks
    case insights
    case settings
    case setup
}

/// Ana pencerede açık bölüm ve seçili toplantı; menü ve Dock da buradan bölüm seçer.
@MainActor
@Observable
final class MainWindowRouter {
    var section: MainSection = .home
    var selectedMeetingID: String?
    /// Sor'da basılan kaynak: toplantı sayfası açılınca o anı gösterir ve sıfırlar (`MeetingDetailPage.openingSource`).
    var openingSource: ArchivePassage?
    /// Toplantılar listesini süzen arama (arama penceresinde ↩ ile uygulanır; üst çubukta görünür, × ile temizlenir).
    var searchQuery: String = ""
    /// Orta ekrandaki arama penceresi açık.
    var isSearchPresented: Bool = false
    /// Kayıt ekranı bu kayıt için kapatıldı ("Uygulamaya dön"); üst çubuktaki "Kayıtta" hapı yeniden açar. Her yeni
    /// kayıtta sıfırlanır.
    var isRecordingFocusDismissed: Bool = false
    /// Kayıt ya da işleme sürerken çıkış istendi: Ana sayfada satır içi soru gösterilir.
    var quitWarning: Bool = false
    /// Açılış ekranı bu açılışta gösterildi.
    var hasShownSplash: Bool = false
    /// Toplantılar listesini süzen klasör; nil hepsi.
    var folderFilter: String?
    /// Ayarlar açılınca Hesap sekmesi seçilsin (kenar çubuğundaki kullanım göstergesi ve kullanım bildirimi; abonelik
    /// sürümü). Ayarlar sekmeyi seçince sıfırlar.
    var opensAccountSettings: Bool = false
    /// Ayarlar açılınca Sesle yazma sekmesi seçilsin (sesle yazma hapındaki "izin ver"). Ayarlar sekmeyi seçince sıfırlar.
    var opensVoiceTypingSettings: Bool = false
    /// Ayarlar açılınca Takvim sekmesi seçilsin (satın almadan sonraki "Takvimini bağla"). Ayarlar sekmeyi seçince sıfırlar.
    var opensCalendarSettings: Bool = false
    /// Kişiler sayfasında seçili sekme (kişiler ya da şirketler).
    var peopleTab: PeopleTab = .people
    /// Oturum yokken bir bağlantı (`gistsmith://…`) geldi: giriş kapısı bağlantının girişten sonra açılacağını söyler.
    var isLinkWaitingForSignIn: Bool = false
    /// Kişiler tablosunda seçili kişinin adı: ⌘J Sor'u bu kişiyle açar.
    var selectedPersonName: String?
    /// ⌘J ile açılan Sor paneli (bulunulan yerin kapsamıyla; bkz. `askShortcutTarget`); nil kapalı.
    var askOverlay: AskScope?
    /// Arttıkça bulunulan sayfanın Sor alanı (Sor sayfası, toplantı sayfasının çubuğu, ⌘J paneli) odağı alır.
    var askFocusRequest: Int = 0
}

/// ⌘J'nin açacağı Sor: sayfanın kendi Sor alanı (Sor sayfası, toplantı sayfasının çubuğu) ya da pencere içindeki Sor
/// paneli, bulunulan yerin kapsamıyla.
enum AskShortcutTarget: Equatable {
    case askPage
    case meetingBar
    case overlay(AskScope)
}

/// ⌘J'nin hedefi: Sor sayfasında soru alanı; açık toplantı sayfasında onun çubuğu; klasörle süzülmüş toplantı
/// listesinde o klasör, Kişiler'de seçili kişi kapsamıyla panel; başka yerde tüm toplantılarla panel. Saf fonksiyondur.
func askShortcutTarget(section: MainSection, selectedMeetingID: String?, folderFilter: String?, selectedPersonName: String?) -> AskShortcutTarget {
    switch section {
    case .ask:
        return .askPage
    case .meetings where selectedMeetingID != nil:
        return .meetingBar
    case .meetings:
        return .overlay(folderFilter.map { AskScope.folder(name: $0) } ?? .allMeetings)
    case .people:
        return .overlay(selectedPersonName.map { AskScope.person(name: $0) } ?? .allMeetings)
    case .home, .tasks, .insights, .settings, .setup:
        return .overlay(.allMeetings)
    }
}

/// ⌘J: bulunulan yerin Sor'unu açar (bkz. `askShortcutTarget`); kurulumda bir şey yapmaz.
@MainActor
func openAskShortcut(router: MainWindowRouter) {
    guard router.section != .setup else {
        return
    }
    switch askShortcutTarget(
        section: router.section, selectedMeetingID: router.selectedMeetingID, folderFilter: router.folderFilter, selectedPersonName: router.selectedPersonName
    ) {
    case .askPage, .meetingBar:
        router.askOverlay = nil
    case .overlay(let scope):
        router.askOverlay = scope
    }
    router.askFocusRequest += 1
}

/// Ayarlar › Sesle yazma'yı açar.
@MainActor
func openVoiceTypingSettings(router: MainWindowRouter) {
    router.opensVoiceTypingSettings = true
    openMainWindow(router: router, section: .settings)
}

/// Ayarlar › Hesap'ı açar (abonelik sürümü: kullanım göstergesi ve bildirimleri).
@MainActor
func openAccountSettings(router: MainWindowRouter) {
    router.opensAccountSettings = true
    openMainWindow(router: router, section: .settings)
}

/// Çıkış koruması: kayıt ya da işleme sürerken uygulama hemen kapanmaz (toplantı "yarıda kaldı" olurdu); ana pencere
/// sorar. Uygulama açılışında bağlanır.
@MainActor
final class QuitGuard {
    static let shared: QuitGuard = QuitGuard()
    var isBusy: (@MainActor () -> Bool)?
    var onBlocked: (@MainActor () -> Void)?
    /// "Yine de çık" seçildi: bir sonraki çıkış sorulmaz.
    var allowQuit: Bool = false
}

/// `--bolum ana|toplantilar|gorevler|sor|kisiler|istatistikler|ayarlar|kurulum` başlatma argümanından ana pencere
/// bölümü (görsel kontrol ve geliştirme için); yoksa nil. Saf fonksiyondur.
func launchSection(arguments: [String]) -> MainSection? {
    guard let index = arguments.firstIndex(of: "--bolum"), arguments.indices.contains(index + 1) else {
        return nil
    }
    switch arguments[index + 1] {
    case "ana": return .home
    case "toplantilar": return .meetings
    case "gorevler": return .tasks
    case "sor": return .ask
    case "kisiler": return .people
    case "istatistikler": return .insights
    case "ayarlar": return .settings
    case "kurulum": return .setup
    default: return nil
    }
}

/// Ana pencereyi verilen bölümde açar ve uygulamayı öne getirir.
@MainActor
func openMainWindow(router: MainWindowRouter, section: MainSection) {
    router.section = section
    NotificationCenter.default.post(name: .openMainWindow, object: nil)
}

/// Dock simgesine tıklanınca ana pencere açılır: ada penceresi hep açık olduğu için sistem "görünür pencere var" sayıp
/// kendiliğinden açmazdı.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Toplantı bildirimine yanıt: "Kaydı başlat" eylemi mi ve bildirimin geldiği an (taze eylem kaydı başlatır,
    /// bildirime tıklama ya da eski bildirim Ana sayfayı açar; bkz. `meetingNotificationTap`). Açılışta bağlanır.
    @MainActor static var onMeetingNotification: (@MainActor (Bool, Date) -> Void)?
    /// "Kayıt başlatılamadı" bildirimine tıklama Ana sayfayı açar (neden başlat düğmesinin yanında); açılışta bağlanır.
    @MainActor static var onOpenHomeFromNotification: (@MainActor () -> Void)?
    /// "Görüşme bitti gibi" bildiriminin yanıtı (eylem kimliği: devam, bitir ya da bildirime tıklama) ve bildirimin bağlı
    /// olduğu kayıt (eski sürümün bildiriminde nil); açılışta bağlanır.
    @MainActor static var onCallEndedResponse: (@MainActor (String, RecordingID?) -> Void)?
    /// Not hazır, görev günü, haftalık özet ve kayıtsız hafta bildirimlerinin yanıtı (bkz. `engagementRoute`); açılışta
    /// bağlanır.
    @MainActor static var onEngagementResponse: (@MainActor (EngagementRoute) -> Void)?

    /// Spotlight'taki toplantı sonucuna tıklama o toplantıyı açar; açılışta bağlanır.
    @MainActor static var onOpenSpotlightMeeting: (@MainActor (String) -> Void)?

    /// `gistsmith://…` bağlantısı (yalnız Gistsmith adres şemasını kaydeder; bkz. `appLinkRoute`) yerini açar; açılışta
    /// bağlanır.
    @MainActor static var onAppLink: (@MainActor (AppLinkRoute) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let meetingID = spotlightMeetingID(activity: userActivity) else {
            return false
        }
        AppDelegate.onOpenSpotlightMeeting?(meetingID)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let route = appLinkRoute(url: url) else {
                appDelegateLogger.warning("Tanınmayan adres açıldı, yok sayıldı, şema: \(url.scheme ?? "-", privacy: .public)")
                continue
            }
            AppDelegate.onAppLink?(route)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            return
        }
        switch response.notification.request.content.categoryIdentifier {
        case MeetingNotificationID.category:
            let isStartAction: Bool = response.actionIdentifier == MeetingNotificationID.startAction
            let deliveredAt: Date = response.notification.date
            await MainActor.run { AppDelegate.onMeetingNotification?(isStartAction, deliveredAt) }
        case MeetingNotificationID.autoFailedCategory:
            await MainActor.run { AppDelegate.onOpenHomeFromNotification?() }
        case MeetingNotificationID.callEndedCategory:
            let action: String = response.actionIdentifier
            let recordingID: RecordingID? = notificationRecordingID(userInfo: response.notification.request.content.userInfo)
            await MainActor.run { AppDelegate.onCallEndedResponse?(action, recordingID) }
        default:
            guard let route = engagementRoute(response: response) else {
                return
            }
            await MainActor.run { AppDelegate.onEngagementResponse?(route) }
        }
    }

    // Uygulama öndeyken de toplantı bildirimi görünsün.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let quitGuard: QuitGuard = .shared
        guard !quitGuard.allowQuit, let isBusy = quitGuard.isBusy, isBusy() else {
            return .terminateNow
        }
        quitGuard.onBlocked?()
        return .terminateCancel
    }
}

/// Menü çubuğu simgesi; kayıt sürerken yanında süre ("23:19"; duraklatılınca simge değişir, süre gizlenir). Ana
/// pencereyi açma isteklerini dinler (simge uygulama boyunca çizili kalır).
///
/// Süre `TimelineView` ya da `Text(timerInterval:)` ile değil, saniyede bir uyanan bir görevle ilerler: macOS 26'da
/// `MenuBarExtra` etiketindeki her zaman çizelgesi (`.periodic`, `.everyMinute`, zamanlayıcı metni) güncellemeyi hemen
/// yeniden ister, ana iş parçacığı tek bir çalışma döngüsü geçişinde sonsuza dek etiketi çizer (%100 CPU, panel ve
/// pencereler donar).
struct MenuBarLabel: View {
    let symbol: String
    /// Süren (duraklatılmamış) kaydın başladığı an; değilse nil (yalnız simge).
    let recordingStartedAt: Date?
    @Environment(\.openWindow) private var openWindow: OpenWindowAction
    /// Etiketin gösterdiği an; kayıt sürerken saniyede bir ilerler.
    @State private var now: Date = Date()

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { (_: Notification) in
                openWindow(id: mainWindowID)
                NSApplication.shared.activate()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let recordingStartedAt {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                Text(verbatim: timestamp(seconds: max(0, now.timeIntervalSince(recordingStartedAt))))
                    .monospacedDigit()
            }
            // Başlangıç değişince (yeni kayıt, duraklatmadan dönüş) görev yeniden kurulur; etiket gizlenince iptal olur.
            .task(id: recordingStartedAt) {
                await tickEverySecond(startedAt: recordingStartedAt)
            }
        } else {
            Image(systemName: symbol)
        }
    }

    /// `now`'u kaydın tam saniyelerinde günceller; görev iptal edilince döner.
    private func tickEverySecond(startedAt: Date) async {
        while true {
            now = Date()
            do {
                try await Task.sleep(for: .seconds(secondsUntilNextWholeSecond(elapsed: now.timeIntervalSince(startedAt))))
            } catch {
                // `Task.sleep` yalnız iptalde fırlatır: etiket kayıt süresini artık göstermiyor.
                return
            }
        }
    }
}

/// Geçen süre bir sonraki tam saniyeye ulaşana kadar beklenecek süre (0'dan büyük, en çok 1 saniye).
private func secondsUntilNextWholeSecond(elapsed: TimeInterval) -> TimeInterval {
    1 - (elapsed - elapsed.rounded(.down))
}

/// Uygulamanın ana penceresi (ElevenLabs düzeni): solda kendi kenar çubuğu (Ana sayfa, Toplantılar, Görevlerim,
/// Ayarlar, son toplantılar, durum), üstte sayfa adı + arama + "Canlı panel", altında bölüm içeriği. Kurulum yalnızca
/// ilk açılışta tam pencere. Kayıt sırasındaki panel ve ada ayrıca çalışır; pencere kapatılınca uygulama menü
/// çubuğunda sürer.
struct MainWindowView: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController
    let player: MeetingAudioPlayer
    let updater: AppUpdater
    let crashReports: CrashReportCenter
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void

    var body: some View {
        let isRecordingFocusVisible: Bool = model.phase == .recording && !router.isRecordingFocusDismissed && router.section != .setup
        // Arama penceresi ya da kayıt ekranı açıkken içerik bulanıklaşır (koyu perde yok, açık buzlu cam; toplantı
        // hazırlanırken çıkan kart gibi) ve tıklamaları almaz.
        let isContentCovered: Bool = router.isSearchPresented || isRecordingFocusVisible
        ZStack {
            // İlk açılışta bir kez: tam pencere, kenar çubuğu yok, içerik ortada.
            if router.section == .setup {
                SetupScreen(model: model, router: router, shortcuts: shortcuts)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                HStack(spacing: 0) {
                    Sidebar(model: model, router: router)
                    VStack(spacing: 0) {
                        TopBar(model: model, router: router, onShowPanel: onShowPanel)
                        // Ana penceredeki eylemlerin hataları (not düzenleme, tarif, ses silme…) burada görünür; önceden
                        // yalnızca canlı panelde çıkıyordu.
                        // Aynı ekranda başka yerde görünen (başlat düğmesinin yanındaki neden, kurulum eksikleri) ya da
                        // çözülmüş (ör. giriş yapıldı) hatalar şeritte tekrarlanmaz.
                        let startBlock: StartBlockNotice? = startBlockNotice(model: model)
                        let visibleErrors: [String] = visibleErrorMessages(
                            errors: model.errorMessages,
                            shownElsewhere: model.setupProblems + [startBlock?.reason].compactMap { $0 } + errorsCoveredByStartBlock(notice: startBlock),
                            resolved: resolvedErrorMessages()
                        )
                        if !visibleErrors.isEmpty {
                            ErrorBanner(messages: visibleErrors) { model.dismissErrors() }
                        }
                        // Kaydın bilgi ve dikkat bildirimleri (uyku, süre sınırı, buluttan Mac'e geçiş): hata değil,
                        // kırmızı görünmez; kapatılabilir.
                        if let notice = model.recordingNotices.last {
                            NoticeBar(severity: notice.severity, title: Text(verbatim: notice.text), detail: nil) { model.dismissErrors() } actions: {}
                        }
                        // Görüşme bitti gibi: kayıt geri sayımla bitecek (kayıt ekranı kapatılmışken burada görünür).
                        if let deadline = model.callEndDeadline {
                            CallEndNotice(deadline: deadline) { model.keepRecordingAfterCallEnd() } onStop: { model.stopRecording() }
                        }
                        // Önceki açılışta çöktüyse bir kez sorulur (rapor yalnızca bu Mac'te; gönderen kullanıcı).
                        if let report = crashReports.reportToAnnounce {
                            CrashReportBanner(center: crashReports, report: report)
                        }
                        #if HOSTED_EDITION
                        // Kullanım bildirimi (%80, %100, son deneme toplantısı, deneme bitti); dönem başına bir kez.
                        // Deneme bitti şeridi alttaki teklif şeridiyle aynı şeyi söyler: ikisi birden görünmez.
                        if let notice = HostedAccount.shared.visibleNotice, !(notice == .trialEnded && HostedAccount.shared.upsell == .trialEnded) {
                            HostedUsageBanner(account: .shared, notice: notice) { openAccountSettings(router: router) }
                        }
                        // Bu Mac'te silinen hesaptan kalan toplantılar: bir kez önerilir ("Şimdi değil"den sonra Ayarlar › Hesap'ta).
                        if HostedDeletedMeetings.shared.isOfferVisible {
                            HostedDeletedMeetingsBanner(deleted: .shared) { model.moveDeletedAccountMeetings() }
                        }
                        // Notu yazılan üçüncü toplantıdan sonra bir kez: arkadaşına öner ya da geri bildirim yaz (Mac'te App
                        // Store değerlendirmesinin yerine; bkz. `HostedRecommendPrompt`). Kayıt sürerken görünmez.
                        if HostedRecommendPrompt.shared.isVisible, !model.isRecording {
                            HostedRecommendBanner(prompt: .shared, account: .shared) { await diagnosticsReportText(model: model, updater: updater) }
                        }
                        #endif
                        detail
                            .id(router.section)
                            .transition(.opacity)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // ⌘J: pencere içinde, sayfanın altında yüzen Sor paneli (ayrı pencere değil).
                            .overlay(alignment: .bottom) {
                                if let context = router.askOverlay {
                                    AskOverlay(model: model, router: router, context: context)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                            .animation(.smooth(duration: 0.25), value: router.askOverlay)
                            .onChange(of: router.section) { (_: MainSection, _: MainSection) -> Void in
                                router.askOverlay = nil
                            }
                    }
                    // Çalan toplantı her bölümde altta görünür; sayfa değişince ses durmaz.
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 0) {
                            #if HOSTED_EDITION
                            // Kendiliğinden gelen teklif (not hazır, deneme bitti) sayfayı kapatmaz: altta ince şerit,
                            // not ve arşiv okunur kalır. Kayıt ya da işleme sürerken ve kurulumda görünmez.
                            if let moment = HostedAccount.shared.upsell, !HostedAccount.shared.isUpsellSheetVisible, !model.isBusy, router.section != .setup {
                                HostedUpsellStrip(account: .shared, moment: moment)
                                    .frame(maxWidth: 720)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                            #endif
                            PlayerDock(model: model, player: player) { (id: String) -> Void in
                                router.selectedMeetingID = id
                                router.section = .meetings
                            }
                            .frame(maxWidth: 720)
                        }
                    }
                    .animation(.smooth(duration: 0.25), value: router.section)
                }
                // Sağ alt: kısa başarı bildirimleri (kaydedildi, kopyalandı) ve bulunan güncelleme kartı (zamanlanmış
                // denetimde Sparkle penceresi açılmaz).
                .overlay(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing, spacing: 12) {
                        if let toast = ToastCenter.shared.current {
                            ToastView(toast: toast, center: .shared)
                                .id(toast.id)
                        }
                        if updater.showsBanner, let update = updater.availableUpdate {
                            UpdateToast(updater: updater, update: update, isBusy: model.blocksUpdateRelaunch)
                        }
                    }
                    .padding(20)
                }
                .animation(.smooth(duration: 0.35), value: updater.showsBanner)
                .animation(.smooth(duration: 0.3), value: ToastCenter.shared.current?.id)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: router.section == .setup)
        .blur(radius: isContentCovered ? 10 : 0)
        .allowsHitTesting(!isContentCovered)
        .animation(.easeInOut(duration: 0.25), value: isContentCovered)
        // Açılış ekranı: uygulama her açıldığında bir kez (pencere kapatılıp açılınca tekrarlanmaz).
        .overlay {
            // Animasyonsuz kaldırılır: sönmeyi açılış ekranı kendisi yapar (bkz. `LaunchSplash.play`).
            if !router.hasShownSplash {
                LaunchSplash(appName: appName) {
                    var transaction: Transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { router.hasShownSplash = true }
                }
            }
        }
        .overlay {
            if isRecordingFocusVisible {
                RecordingFocus(model: model, router: router, onShowPanel: onShowPanel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isRecordingFocusVisible)
        .onChange(of: model.phase) { (old: RecordingPhase, new: RecordingPhase) -> Void in
            // Kayıt "başlatılıyor"dan geçer: ekran her yeni kayıtta yeniden açılır (önceki kayıtta ya da kayıt yokken bir
            // bağlantıyla kapatılmış olsa da).
            if old != .recording, new == .recording {
                // Pencerede bir form (sayfa) açıksa kayıt ekranı onun üstüne açılmaz: yazılan form kapanmasın; üst
                // çubuktaki "Kayıtta" hapı ekranı açar.
                router.isRecordingFocusDismissed = NSApp.windows.contains { $0.isVisible && $0.attachedSheet != nil }
            }
        }
        .overlay {
            if router.isSearchPresented {
                SearchComposer(model: model, router: router)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.isSearchPresented)
        .foregroundStyle(Theme.ink)
        // Toplantı hazırlanırken ana pencerede de aynı ilerleme kartı (panelle eş zamanlı).
        .modifier(ProcessingOverlayHost(model: model))
        #if HOSTED_EDITION
        // Planlar (tam teklif): kullanıcı istediğinde ya da abonelik gerektiren bir şeyi denediğinde hemen; kendiliğinden
        // gelen anlarda (not hazır, deneme bitti) alttaki şeritten açılınca. Kayıt ya da işleme sürerken ve kurulumda
        // açılmaz; o sırada istendiyse bitince açılır.
        .sheet(isPresented: Binding<Bool>(
            get: { HostedAccount.shared.isUpsellSheetVisible && !model.isBusy && router.section != .setup },
            set: { (shown: Bool) -> Void in
                if !shown {
                    HostedAccount.shared.dismissUpsell()
                }
            }
        )) {
            if let moment = HostedAccount.shared.upsell {
                HostedUpsellSheet(account: .shared, moment: moment, trialValue: hostedTrialValue(meetings: model.meetings))
            }
        }
        // Notu yazılan üçüncü toplantıdan sonra öneri şeridi (toplantı listesinden izlenir).
        .modifier(HostedRecommendPromptObserver(model: model))
        // Satın almadan sonraki onay (bir kez): abonelik göründü, tek sonraki adım takvimi bağlamak.
        .sheet(isPresented: Binding<Bool>(
            get: { HostedAccount.shared.purchaseConfirmation != nil && !HostedAccount.shared.isUpsellSheetVisible && !model.isBusy },
            set: { (shown: Bool) -> Void in
                if !shown {
                    HostedAccount.shared.dismissPurchaseConfirmation()
                }
            }
        )) {
            if let tier = HostedAccount.shared.purchaseConfirmation {
                HostedPurchaseConfirmationSheet(tier: tier) {
                    HostedAccount.shared.dismissPurchaseConfirmation()
                    router.opensCalendarSettings = true
                    openMainWindow(router: router, section: .settings)
                } onClose: {
                    HostedAccount.shared.dismissPurchaseConfirmation()
                }
            }
        }
        #endif
        .frame(minWidth: 860, minHeight: 580)
        // Cam tek katman: pencere zemini (ikinci bir arka plan opaklığı iki kat gösteriyordu).
        .containerBackground(for: .window) { WindowBackdrop() }
        // Başlık çubuğu gizli: içerik pencerenin tepesine kadar sürer (trafik ışıkları kenar çubuğunun üstünde).
        .ignoresSafeArea(.container, edges: .top)
        .modifier(AppearanceEnvironment())
    }

    @ViewBuilder
    private var detail: some View {
        switch router.section {
        case .home:
            HomePage(model: model, router: router, shortcuts: shortcuts, onStartRecording: onStartRecording, onShowPanel: onShowPanel)
        case .meetings:
            MeetingsSplit(model: model, router: router, player: player, shortcuts: shortcuts, onStartRecording: onStartRecording)
        case .ask:
            AskPage(model: model, router: router, onStartRecording: onStartRecording)
        case .people:
            PeoplePage(model: model, router: router)
        case .tasks:
            TasksPage(model: model, router: router)
        case .insights:
            InsightsPage(model: model)
        case .settings:
            // Geniş pencerede form satırları ekran boyu uzamasın.
            // Genişlik sınırı sayfanın içinde: kaydırma çubuğu pencerenin sağ kenarında kalır.
            SettingsPage(model: model, router: router, shortcuts: shortcuts, updater: updater, crashReports: crashReports) { router.section = .setup }
                .scrollContentBackground(.hidden)
        case .setup:
            // Kurulum kenar çubuğu olmadan gösterilir (bkz. `body`); buraya gelinmez.
            EmptyView()
        }
    }
}

/// Kenar çubuğu (ElevenLabs): sade simgeli satırlar, seçili satır gri hap, "Son toplantılar" grubu.
private struct Sidebar: View {
    let model: AppModel
    let router: MainWindowRouter
    /// Notlardaki konuşmacı etiketleri adlarla; adı kullanıcının adı olan konuşmacının görevleri onundur.
    private var userName: String { model.userName }

    var body: some View {
        // Yalnızca açık (tamamlanmamış) görevler sayılır.
        let myTaskCount: Int = myTasks(namedRecords: model.namedMeetings(userName: userName)).filter { !isTaskDone(record: $0.record, task: $0.task) }.count
        VStack(alignment: .leading, spacing: 2) {
            // Trafik ışıklarına yer.
            Color.clear.frame(height: 40)
            item(title: "Ana sayfa", symbol: "house", section: .home, badge: nil)
            item(title: "Toplantılar", symbol: "list.bullet.rectangle", section: .meetings, badge: nil)
            item(title: "Sor", symbol: "sparkle.magnifyingglass", section: .ask, badge: nil)
            item(title: "Görevlerim", symbol: "checkmark.circle", section: .tasks, badge: myTaskCount > 0 ? myTaskCount : nil)
            item(title: "Kişiler", symbol: "person.2", section: .people, badge: nil)
            item(title: "İstatistikler", symbol: "chart.bar.xaxis", section: .insights, badge: nil)
            // Klasörler ve son toplantılar kayar: alçak pencerede ya da büyük arayüz ölçeğinde Ayarlar alttan taşmasın.
            ScrollView {
            VStack(alignment: .leading, spacing: 2) {
            SidebarFolders(model: model, router: router)
            if !model.meetings.isEmpty {
                Text("Son toplantılar")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10)
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                ForEach(model.meetings.prefix(4)) { (record: MeetingRecord) in
                    Button {
                        router.selectedMeetingID = record.id
                        router.section = .meetings
                    } label: {
                        Text(record.note?.title ?? record.title)
                            .appFont(size: 13, weight: .regular)
                            .lineLimit(1)
                            .foregroundStyle(Theme.ink.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
            }
            }
            .scrollIndicators(.never)
            // Ayarlar en altta, sol köşede (uygulamaların alışılmış yeri).
            Spacer(minLength: 12)
            #if HOSTED_EDITION
            // Abonelikte bu ayın saatleri, denemede kalan toplantılar; tıklanınca Ayarlar › Hesap.
            HostedSidebarUsage(account: .shared) { openAccountSettings(router: router) }
                .padding(.bottom, 4)
            #endif
            // Ayarlar ve hesabın avatarı yan yana (avatar hesaba götürür).
            HStack(spacing: 6) {
                item(title: "Ayarlar", symbol: "gearshape", section: .settings, badge: nil)
                SidebarAvatar(model: model, router: router)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .pageBackground()
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func item(title: LocalizedStringKey, symbol: String, section: MainSection, badge: Int?) -> some View {
        // Klasör süzgeci açıkken "Toplantılar" değil klasör seçili görünür.
        let isSelected: Bool = router.section == section && !(section == .meetings && router.folderFilter != nil)
        return Button {
            if section == .meetings {
                router.folderFilter = nil
            }
            router.section = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .appFont(size: 14, weight: .regular)
                    .frame(width: 18)
                    .symbolEffect(.bounce, value: isSelected)
                Text(title).appFont(size: 14, weight: isSelected ? .medium : .regular)
                Spacer(minLength: 0)
                if let badge {
                    Text("\(badge)")
                        .appFont(size: 11, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.soft, in: Capsule())
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.hoverPlain)
    }
}

/// Kenar çubuğunun altındaki avatar: abonelikte oturumdaki hesabın Google resmi ya da baş harfi (ad, yoksa e-posta),
/// tıklanınca Ayarlar › Hesap; geliştirici sürümünde adın baş harfi, tıklanınca Ayarlar. iPhone'daki avatarla aynı.
private struct SidebarAvatar: View {
    let model: AppModel
    let router: MainWindowRouter
    private var userName: String { model.userName }

    var body: some View {
        Button {
            #if HOSTED_EDITION
            openAccountSettings(router: router)
            #else
            router.section = .settings
            #endif
        } label: {
            #if HOSTED_EDITION
            ProfileAvatar(
                imageURL: HostedAccount.shared.avatarURL,
                initial: accountAvatarInitial(userName: userName, email: HostedAccount.shared.signedInIdentity?.email),
                size: 28
            )
            #else
            InitialAvatar(initial: accountAvatarInitial(userName: userName, email: nil), size: 28)
            #endif
        }
        .buttonStyle(.hoverPlain)
        .hoverHint("Hesap", alignment: .trailing, edge: .top)
        .accessibilityLabel(Text("Hesap"))
    }
}

/// Ana penceredeki kenar çubuğunun genişliği.
private let sidebarWidth: CGFloat = 228

/// Üst çubuk: sayfa adı, arama hapı (tıklayınca ya da ⌘K / ⌘F ile orta ekranda arama penceresi açılır; yazı alanı
/// değildir, imleç yanıp sönmez), "Canlı panel". Listeye uygulanmış arama hapta görünür, × ile temizlenir.
private struct TopBar: View {
    let model: AppModel
    let router: MainWindowRouter
    let onShowPanel: @MainActor () -> Void

    @AppStorage(SettingsKey.meetingsListVisible) private var meetingsListVisible: Bool = true
    @AppStorage(SettingsKey.askHistoryVisible) private var askHistoryVisible: Bool = false
    /// Transkript sekmesi açık toplantı sayfası (⌘F orada transkriptte bulur).
    @FocusedValue(\.transcriptFind) private var transcriptFind: TranscriptFindAction?

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            // Sayfanın sol listesini gizle/göster: her bölümde aynı yerde, başlığın solunda.
            switch router.section {
            // Hiç toplantı yokken liste sütunu yoktur (ilk açılış sahnesi tüm alanı kaplar): düğme de gizlenir.
            case .meetings where !model.meetings.isEmpty:
                listToggle(isVisible: $meetingsListVisible, show: "Toplantı listesini göster", hide: "Toplantı listesini gizle")
            case .ask where !model.askConversations.isEmpty:
                listToggle(isVisible: $askHistoryVisible, show: "Sohbet geçmişini göster", hide: "Sohbet geçmişini gizle")
            default:
                EmptyView()
            }
            // En dar pencerede başlık tek satırda kalır, arama hapı daralır; çubuk taşmaz.
            Text(title)
                .appFont(size: 14, weight: .medium)
                .lineLimit(1)
                .layoutPriority(1)
            // Kayıt ekranı kapatıldıysa "Kayıtta" hapı onu yeniden açar.
            if model.phase == .recording, router.isRecordingFocusDismissed {
                Button {
                    router.isRecordingFocusDismissed = false
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text("Kayıtta").appFont(size: 12, weight: .medium)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.hoverCapsule)
                .hoverHint("Kayıt ekranını aç", alignment: .leading, edge: .bottom)
            }
            Spacer(minLength: DesignTokens.Spacing.m)
            HStack(spacing: 8) {
                Button {
                    router.isSearchPresented = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        if router.searchQuery.isEmpty {
                            Text("Toplantılarda ara…").foregroundStyle(Theme.muted)
                        } else {
                            Text(verbatim: router.searchQuery).foregroundStyle(Theme.ink).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if router.searchQuery.isEmpty {
                    Text("⌘K")
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 5)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                } else {
                    Button {
                        router.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Aramayı temizle")
                }
            }
            .appFont(size: 13, weight: .regular)
            .padding(.horizontal, 10)
            .frame(minWidth: 180, idealWidth: 320, maxWidth: 320)
            .frame(height: 32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            .linkPointer(isEnabled: true)
            .background {
                // ⌘K ve ⌘F arama penceresini açar.
                Button { router.isSearchPresented = true } label: { Text(verbatim: "") }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
                // ⌘J bulunulan yerin Sor'unu açar (bkz. `askShortcutTarget`).
                Button { openAskShortcut(router: router) } label: { Text(verbatim: "") }
                    .keyboardShortcut("j", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
                Button {
                    // Transkript sekmesi açıkken ⌘F transkriptte bulur.
                    if let transcriptFind {
                        transcriptFind.focus()
                    } else {
                        router.isSearchPresented = true
                    }
                } label: { Text(verbatim: "") }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: DesignTokens.Spacing.m)
            Button("Canlı panel", systemImage: "rectangle.on.rectangle") { onShowPanel() }
                .buttonStyle(.pill)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// Sol listeyi gizleyen/gösteren düğme (Toplantılar, Kişiler, Sor'da aynı).
    private func listToggle(isVisible: Binding<Bool>, show: LocalizedStringKey, hide: LocalizedStringKey) -> some View {
        Button {
            isVisible.wrappedValue.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .appFont(size: 14, weight: .medium)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.hoverPlain)
        .accessibilityLabel(isVisible.wrappedValue ? hide : show)
        .hoverHint(isVisible.wrappedValue ? hide : show, alignment: .leading, edge: .bottom)
    }

    private var title: LocalizedStringKey {
        switch router.section {
        case .home: "Ana sayfa"
        case .meetings: "Toplantılar"
        case .ask: "Sor"
        case .people: "Kişiler"
        case .tasks: "Görevlerim"
        case .insights: "İstatistikler"
        case .settings: "Ayarlar"
        case .setup: "Kurulum"
        }
    }
}

private struct SetupScreen: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController

    var body: some View {
        // Tüm pencere: üstte ilerleme, ortada adım, altta eylemler (bkz. `SetupPage`).
        SetupPage(model: model, shortcuts: shortcuts) { (sampleMeetingID: String?) -> Void in
            // Kurulum ancak bitince tamamlanmış sayılır: yarıda kapatılırsa bir sonraki açılışta kaldığı adımdan sürer.
            UserDefaults.standard.set(true, forKey: SettingsKey.onboardingCompleted)
            UserDefaults.standard.removeObject(forKey: onboardingStepKey)
            // Örnek toplantı denendiyse kullanıcı onun notuna iner; yoksa ana sayfaya.
            if let sampleMeetingID {
                router.selectedMeetingID = sampleMeetingID
                router.section = .meetings
            } else {
                router.section = .home
            }
        }
            .padding(.top, 28)
            .background { FlowingLines(seed: "kurulum", lineCount: 14, isAnimated: false).ignoresSafeArea() }
    }
}

private struct QuitWarning: View {
    let model: AppModel
    let router: MainWindowRouter

    var body: some View {
        let isBusy: Bool = model.isBusy
        NoticeCard(
            severity: .attention,
            // Kayıt başlarken de (ses yazılıyor) kayıt uyarısı görünür.
            title: Text(model.phase == .idle && !model.isStarting
                ? "Toplantı işleniyor. Şimdi çıkarsan not hazırlanmaz; açılınca \"Tekrar işle\" gerekir."
                : "Kayıt sürüyor. Şimdi çıkarsan toplantı yarıda kalır."),
            detail: nil,
            onDismiss: nil
        ) {
            HStack(spacing: DesignTokens.Spacing.s) {
                if model.phase == .recording {
                    Button("Kaydı bitir", systemImage: "stop.fill") {
                        model.stopRecording()
                        router.quitWarning = false
                    }
                    .buttonStyle(.pillPrimary)
                }
                Button("Yine de çık", role: .destructive) {
                    QuitGuard.shared.allowQuit = true
                    NSApplication.shared.terminate(nil)
                }
                Button("Vazgeç") { router.quitWarning = false }
            }
        }
        .onChange(of: isBusy) { (_: Bool, busy: Bool) in
            if !busy {
                router.quitWarning = false
            }
        }
    }
}


/// Ana sayfa, önem sırasıyla: selamlama ve tek satırlık kayıt çubuğu, yaklaşan toplantılar (Katıl, Dinle, Brifing),
/// sana düşen görevler, gradyan kapaklı son toplantılar; kısayollar en altta.
private struct HomePage: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void

    var body: some View {
        let startBlock: StartBlockNotice? = startBlockNotice(model: model)
        ScrollView {
            VStack(spacing: 28) {
                if router.quitWarning {
                    QuitWarning(model: model, router: router)
                }
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    RecordBar(model: model, startBlock: startBlock, onStartRecording: onStartRecording, onShowPanel: onShowPanel) { (action: StartBlockAction) -> Void in
                        resolveStartBlock(action: action, router: router)
                    }
                }
                .padding(.top, 24)
                UpcomingMeetings(model: model, startBlock: startBlock, onStartRecording: onStartRecording) { (meeting: CalendarMeeting) -> Void in
                    if model.startBriefing(meeting: meeting) {
                        router.section = .ask
                    }
                } onOpenMeeting: { (id: String) -> Void in
                    router.selectedMeetingID = id
                    router.section = .meetings
                }
                HomeTasks(model: model, router: router)
                RecentMeetingCards(model: model, router: router)
                // Kısayollar ikincil: kenar çubuğunda ve menülerde de var, sayfanın sonunda kalır.
                Shortcuts(model: model, router: router, shortcuts: shortcuts, onShowPanel: onShowPanel)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.3), value: router.quitWarning)
            .animation(.smooth(duration: 0.3), value: model.phase)
        }
    }

    @ViewBuilder
    private var heading: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 12) {
                // Durağan: kayıt boyunca süren nabız animasyonu her karede pencereyi yeniden çizdirip işlemciyi
                // yoruyordu (kayıt sırasında uygulama hafif kalmalı); duraklatılınca soluklaşır.
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red.opacity(model.isPaused ? 0.45 : 1))
                // Duraklatmada süre durur (duraklatılan süre sayılmaz): sayaç gizlenir, "duraklatıldı" yazar.
                if !model.isPaused, let startedAt = model.recordingTimerStart {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
                Text(model.isPaused ? "· duraklatıldı" : "· dinleniyor")
                    .foregroundStyle(Theme.muted)
            }
            .appFont(size: 34, weight: .regular)
            // Kayıt sürerken sayfanın odağı bu satır: ortada durur.
            .frame(maxWidth: .infinity, alignment: .center)
        case .starting:
            Text("Başlatılıyor…")
                .appFont(size: 34, weight: .regular)
        case .finishing:
            Text("Bitiriliyor…")
                .appFont(size: 34, weight: .regular)
        case .idle:
            VStack(alignment: .leading, spacing: 4) {
                Text(Date.now.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(interfaceLocale())))
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                Text(verbatim: homeGreeting(name: model.userName, hour: Calendar.current.component(.hour, from: .now)))
                    .appFont(size: 30, weight: .semibold)
                    .tracking(-0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

/// Koyu temada ana sayfadaki kayıt çubuğunun pastel zeminine eklenen karartma (kapakların genel kısmasının üstüne): parlak
/// gradyan koyu sayfada göze batmasın.
private let homeBarDarkDimming: Double = 0.3

/// Kayıt kartında konuşma modelinin durumu: indiriliyorsa ilerleme, hazırlanamadıysa neden ve "Yeniden dene".
/// Geliştirici sürümünde "Kaydı başlat" neden kapalı, abonelikte canlı metin neden gecikecek, kart söyler.
struct LocalModelNoticeView: View {
    let notice: LocalModelNotice
    let onRetry: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch notice {
            case .preparing(let progress):
                if let progress {
                    ProgressView(value: progress).frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: localModelNoticeText(progress: progress) + " " + preparingHint)
                    .foregroundStyle(Theme.muted)
            case .failed(let message):
                NoticeText(message, severity: .error)
                Button("Yeniden dene", action: onRetry)
                    .buttonStyle(.pill)
                    .controlSize(.small)
            }
        }
        .appFont(size: 12, weight: .regular)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Hazırlanırken ne olacağı: abonelikte kayıt beklemez, geliştirici sürümünde model hazır olunca başlar.
    private var preparingHint: String {
        #if HOSTED_EDITION
        String(localized: "Kayıt hemen başlayabilir; canlı metin model hazır olunca gelir.")
        #else
        String(localized: "Bitince kayıt başlatılabilir.")
        #endif
    }
}

/// Kayıt çubuğu: boşta tek satır gradyan çubuk (küre, "Kaydı başlat", seçenek çipleri); kayıtta ve bitirilirken çubuk
/// (ElevenLabs'in "oluştur" çubuğu gibi): küre, durum, "Paneli göster" ve "Bitir".
private struct RecordBar: View {
    @Bindable var model: AppModel
    /// Kayıt başlatılamıyorsa nedeni: düğme kapanır, neden ve çözüm düğmenin yanında tek satır.
    let startBlock: StartBlockNotice?
    let onStartRecording: @MainActor () -> Void
    let onShowPanel: @MainActor () -> Void
    let onResolve: @MainActor (StartBlockAction) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    /// Mikrofon seçimi (değişince çip adı tazelenir).
    @AppStorage(audioInputSettingKey) private var storedAudioInput: String = ""

    var body: some View {
        if model.phase == .idle {
            hero
        } else {
            bar.frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
    }

    /// Boşta: tek satırlık kayıt çubuğu (sayfanın üçte birini kaplayan büyük kart yerine): küre, "Kaydı başlat" ve
    /// seçenek çipleri; dar pencerede çipler alt satıra iner. Zemin durağan pastel gradyan, koyu temada belirgin
    /// kısılır; içerik her temada açık görünümle çizilir. Engel, model ve boş yer bildirimleri çubuğun altında,
    /// uygulamanın temasında.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    startControls
                    Spacer(minLength: 8)
                    options
                }
                VStack(alignment: .leading, spacing: 10) {
                    startControls
                    options
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // İçerik her temada açık görünümde; zemin sonra eklenir ki uygulamanın temasını görsün ve koyu temada kısılsın.
            .environment(\.colorScheme, .light)
            .background {
                FilmGradient(seed: "kayit-karti", palette: .sunset)
                    .dimmedInDarkTheme()
                    .overlay { Color.black.opacity(colorScheme == .dark ? homeBarDarkDimming : 0).allowsHitTesting(false) }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if let startBlock {
                StartBlockView(notice: startBlock, onResolve: onResolve)
            } else if let notice = model.localModelNotice {
                LocalModelNoticeView(notice: notice) { Task { await model.retryLocalModel() } }
            }
            DiskSpaceNotice(model: model)
        }
        // Çubuk her göründüğünde (açılış, kayıt bitince) boş yer yeniden okunur.
        .task { model.refreshRecordingDiskSpace() }
    }

    /// Küre ve "Kaydı başlat".
    private var startControls: some View {
        HStack(spacing: 10) {
            orb(size: 30)
                .padding(3)
                .background(Color.white.opacity(0.4), in: Circle())
            Button(action: onStartRecording) {
                Label("Kaydı başlat", systemImage: "record.circle")
            }
            .buttonStyle(.bannerPrimary)
            .disabled(!model.isReadyToRecord || model.isStarting || startBlock != nil)
        }
        .fixedSize()
    }

    private func orb(size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [appearance.accent.color.mix(with: .white, by: 0.45), appearance.accent.color, appearance.accent.color.mix(with: .black, by: 0.55)],
                center: UnitPoint(x: 0.35, y: 0.35), startRadius: 1, endRadius: size * 0.65
            ))
            .frame(width: size, height: size)
            .tilt3D(maxAngle: 8)
    }

    /// Seçenekler gerekirse alt satıra geçer: dar pencerede, İngilizcede ya da büyük arayüz boyutunda çubuğun dışına
    /// taşıp kesilmez.
    private var options: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            languageChip
            chip(title: "Yüz yüze", isOn: model.isInPerson) { model.toggleInPerson() }
                .hoverHint("Aynı odadaki toplantı: mikrofondaki herkes konuşmacılara ayrılır", alignment: .center, edge: .bottom)
            if !model.isInPerson {
                chip(title: model.isMicMuted ? "Yalnız karşı taraf" : "Benim sesim de", isOn: !model.isMicMuted) {
                    model.toggleMicrophone()
                }
            }
            if model.isInPerson || !model.isMicMuted {
                microphoneChip
            }
            chip(title: "Canlı çeviri", isOn: model.displayMode.needsLiveTranslation) {
                model.selectDisplayMode(mode: model.displayMode.needsLiveTranslation ? .originalOnly : .bilingual)
            }
        }
        .fixedSize()
    }

    /// Kayıtta ve bitirilirken gösterilen çubuk (boşta `hero` gösterilir).
    private var bar: some View {
        HStack(spacing: 10) {
            orb(size: 34)
            switch model.phase {
            case .idle:
                EmptyView()
            case .recording:
                Text(model.isPaused ? "Kayıt duraklatıldı" : "Kayıt sürüyor — konuşmalar canlı panelde")
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if model.viewState.isInPerson || !model.isMicMuted {
                    recordingMicrophoneMenu
                }
                Button("Paneli göster", systemImage: "rectangle.on.rectangle") { onShowPanel() }
                    .buttonStyle(.pill)
                    .fixedSize()
                Button("Bitir", systemImage: "stop.fill") { model.stopRecording() }
                    .buttonStyle(.pillPrimary)
                    .fixedSize()
            case .starting:
                Text("Başlatılıyor…")
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button("İptal") { model.cancelStart() }
                    .buttonStyle(.pill)
                    .fixedSize()
            case .finishing:
                Text("Kalan metin ve konuşmacılar tamamlanıyor.")
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                ProgressView().controlSize(.small)
            }
        }
        .appFont(size: 14, weight: .regular)
        .controlSize(.small)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
    }

    private var languageChip: some View {
        Menu {
            Button("Otomatik") { model.languageMode = .automatic }
            LanguageMenuItems { (language: MeetingLanguage) -> Void in model.languageMode = .fixed(language) }
        } label: {
            // Kart her temada açık pastel: yazı temanın mürekkebini değil siyahı alır (koyu temada beyaz kalıp kayboluyordu).
            languageTitle
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .menuStyle(.button)
        .buttonStyle(HeroChipButtonStyle(fillOpacity: 0.9))
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Mikrofon seçimi (Ayarlar › Kayıt ve diller'dekiyle aynı): kullanılacak girişin adı.
    private var microphoneChip: some View {
        Menu {
            AudioInputMenuItems(inputs: model.audioInputs)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "mic")
                    .appFont(size: 10, weight: .semibold)
                Text(verbatim: microphoneChipTitle)
                    .appFont(size: 12, weight: .medium)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .menuStyle(.button)
        .buttonStyle(HeroChipButtonStyle(fillOpacity: 0.9))
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHint("Kayıtta kullanılacak mikrofon", alignment: .center, edge: .bottom)
    }

    /// Kayıtta mikrofon seçimi: kayıt durmadan yeni girişe geçer; ipucu kullanılan girişi söyler.
    private var recordingMicrophoneMenu: some View {
        Menu {
            AudioInputMenuItems(inputs: model.audioInputs)
        } label: {
            // Seçilen giriş kullanılamıyorsa kayıt boyunca işaretli (panel de söyler).
            Image(systemName: model.audioInput?.unavailableChoice != nil ? "mic.badge.xmark" : model.audioInput.map { audioInputSymbol(kind: $0.device.kind) } ?? "mic")
                .foregroundStyle(model.audioInput?.unavailableChoice != nil ? NoticeSeverity.attention.tint : Theme.ink)
        }
        .menuStyle(.button)
        .buttonStyle(.pill)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Mikrofon"))
        .hoverHint(verbatim: recordingMicrophoneHint, alignment: .center, edge: .bottom)
    }

    /// Kayıt çubuğundaki mikrofon menüsünün ipucu: kullanılan giriş ya da seçilenin kullanılamadığı.
    private var recordingMicrophoneHint: String {
        if let notice = persistentAudioInputNotice(active: model.audioInput) {
            return audioInputNoticeText(notice: notice)
        }
        return model.audioInput.map { String(localized: "Mikrofon: \($0.device.name)") } ?? String(localized: "Mikrofon")
    }

    /// Kullanılacak girişin adı: seçilen cihaz ya da (Otomatik) sistemin girişi.
    private var microphoneChipTitle: String {
        let choice: AudioInputChoice = audioInputChoice(stored: storedAudioInput)
        if choice == .automatic, let systemDefault = model.audioInputs.systemDefault {
            return systemDefault.name
        }
        return audioInputChoiceTitle(choice: choice)
    }

    private var languageTitle: Text {
        switch model.languageMode {
        case .automatic: Text("Otomatik dil")
        case .fixed(let language): Text(verbatim: meetingLanguageName(language: language))
        }
    }

    private func chip(title: LocalizedStringKey, isOn: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : "minus")
                    .appFont(size: 10, weight: .semibold)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).appFont(size: 12, weight: .medium)
            }
            .foregroundStyle(isOn ? Color.black : Color.black.opacity(0.62))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(HeroChipButtonStyle(fillOpacity: isOn ? 0.9 : 0.45))
        .fixedSize()
    }
}

/// Kayıt kartındaki seçenek hapı: pastel zeminde beyaz kapsül. Fare üstündeyken beyaz dolgu parlar (temanın koyu
/// hover tonu pastel kartta kirli bir hale çiziyordu), basılınca hafifçe küçülür; el imleci gösterir.
private struct HeroChipButtonStyle: ButtonStyle {
    let fillOpacity: Double

    func makeBody(configuration: Configuration) -> some View {
        HeroChipBody(configuration: configuration, fillOpacity: fillOpacity)
    }
}

private struct HeroChipBody: View {
    let configuration: ButtonStyleConfiguration
    let fillOpacity: Double
    @Environment(\.isEnabled) private var isEnabled: Bool
    @State private var isHovering: Bool = false

    var body: some View {
        configuration.label
            .background(Color.white.opacity(isEnabled && isHovering ? min(fillOpacity + 0.25, 1) : fillOpacity), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .linkPointer(isEnabled: isEnabled)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Kısayollar: beş sade, yatay kart: solda küçük gradyan kutuda simge, yanında ad ve kısa bilgi. Kayıt büyük kartta,
/// Ayarlar kenar çubuğunda olduğu için burada yok.
private struct Shortcuts: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController
    let onShowPanel: @MainActor () -> Void
    @AppStorage(SettingsKey.voiceTypingEnabled) private var isVoiceTypingEnabled: Bool = true
    /// Notlardaki konuşmacı etiketleri adlarla; adı kullanıcının adı olan konuşmacının görevleri onundur.
    private var userName: String { model.userName }

    var body: some View {
        let openTasks: Int = myTasks(namedRecords: model.namedMeetings(userName: userName)).filter { !isTaskDone(record: $0.record, task: $0.task) }.count
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            Text("Hızlı eylemler").appFont(size: 15, weight: .medium)
            // Beş kart satırı doldurur; dar pencerede üçerli iki satıra iner.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { cards(openTasks: openTasks) }
                    .frame(minWidth: 840)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 12) {
                    cards(openTasks: openTasks)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cards(openTasks: Int) -> some View {
        Group {
            card(title: "Canlı panel", detail: String(localized: "Kayıt sırasında yazı"), symbol: "rectangle.on.rectangle", palette: .ocean) { onShowPanel() }
            card(title: "İçe aktar", detail: String(localized: "Ses ya da video"), symbol: "square.and.arrow.down", palette: .mint) {
                router.section = .meetings
                chooseMediaToImport(model: model)
            }
            card(title: "Toplantılarına sor", detail: String(localized: "\(model.meetings.count) toplantı"), symbol: "sparkle.magnifyingglass", palette: .violet) {
                router.section = .ask
            }
            card(title: "Görevlerim", detail: String(localized: "\(openTasks) açık"), symbol: "checkmark.circle", palette: .coral) {
                router.section = .tasks
            }
            // Sesle yazma her uygulamada çalışır; kart Ayarlar › Sesle yazma'yı (tanıtım ve "Dene") açar.
            card(title: "Sesle yazma", detail: voiceTypingDetail, symbol: "waveform.and.mic", palette: .rose) {
                openVoiceTypingSettings(router: router)
            }
        }
    }

    /// Sesle yazma kartının alt satırı: kısayol ve "her uygulamada"; kapalıysa ya da kısayol yoksa bunu söyler.
    private var voiceTypingDetail: String {
        guard isVoiceTypingEnabled else {
            return String(localized: "Kapalı · aç")
        }
        guard let binding = shortcuts.assignedBinding(action: .dictate) else {
            return String(localized: "Kısayol seç")
        }
        return String(localized: "\(keyBindingDisplay(binding: binding)) · her uygulamada")
    }

    private func card(title: LocalizedStringKey, detail: String, symbol: String, palette: FilmPalette, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Color.black.opacity(0.78))
                    .frame(width: 34, height: 34)
                    .background { FilmGradient(seed: "kisayol-\(symbol)", palette: palette) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    // Uzun dillerde (Fince, Almanca) açıklama iki satıra iner, ad sığmazsa biraz küçülür; "…" ile kesilmez.
                    Text(title)
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(verbatim: detail)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ShortcutCardBackground() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
    }
}

/// Son toplantılarda sana düşen görevler (en yeni toplantıdan başlayarak).
private struct HomeTasks: View {
    let model: AppModel
    let router: MainWindowRouter
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// Notlardaki konuşmacı etiketleri adlarla; adı kullanıcının adı olan konuşmacının görevleri onundur.
    private var userName: String { model.userName }

    var body: some View {
        // Aciliyet sırasıyla: önce gecikmiş ve bugünün görevleri, sonra yaklaşanlar.
        let items: [DatedTask] = openTasksByUrgency(items: myTasks(namedRecords: model.namedMeetings(userName: userName)), now: Date(), calendar: Calendar.current)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                HStack {
                    Text("Sana düşen görevler").appFont(size: 15, weight: .medium)
                    Spacer(minLength: 0)
                    Button("Tümü ›") { router.section = .tasks }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items.prefix(5), id: \.rowID) { (item: DatedTask) in
                        // Ana sayfada görevler toplantılarıyla karışık: tarihin yanında toplantının adı.
                        TaskLine(model: model, record: item.record, task: item.task, meetingTitle: item.record.note?.title ?? item.record.title) {
                            router.selectedMeetingID = item.record.id
                            router.section = .meetings
                        }
                    }
                }
                .padding(8)
                .cardSurface(cornerRadius: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Yaklaşan toplantılar (takvim açıksa, önümüzdeki 12 saat): saat, başlık, katılımcılar; bağlantısı varsa "Katıl",
/// başlamak üzereyse (10 dk) ya da sürüyorsa "Dinle".
private struct UpcomingMeetings: View {
    let model: AppModel
    /// Kayıt başlatılamıyorsa nedeni (kayıt kartında yazar): "Dinle" de kayıt kartındaki düğme gibi kapanır.
    let startBlock: StartBlockNotice?
    let onStartRecording: @MainActor () -> Void
    /// Toplantı öncesi brifing (arşive sorulur, Sor sayfasında açılır).
    let onBriefing: @MainActor (CalendarMeeting) -> Void
    /// Bugün biten etkinliğin kaydını açar.
    let onOpenMeeting: @MainActor (String) -> Void

    var body: some View {
        let now: Date = Date()
        let items: [CalendarMeeting] = model.upcomingMeetings.filter { $0.end > now && $0.start.timeIntervalSince(now) < 12 * 3600 }
        // Bugün biten etkinlikler: kaydı olanın notu takvimden açılır (en yeni önce).
        let earlier: [CalendarMeeting] = meetingsEndedToday(meetings: model.upcomingMeetings, now: now, calendar: Calendar.current)
        if let error = model.calendarError {
            EmptyStateCard(symbol: "calendar.badge.exclamationmark", title: "Takvim okunamadı", message: "\(error)")
        } else if !items.isEmpty || !earlier.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                if !items.isEmpty {
                    group(title: "Yaklaşan toplantılar", meetings: Array(items.prefix(4))) { (meeting: CalendarMeeting) in
                        row(meeting: meeting, now: now)
                    }
                }
                if !earlier.isEmpty {
                    group(title: "Bugün biten toplantılar", meetings: Array(earlier.prefix(4))) { (meeting: CalendarMeeting) in
                        pastRow(meeting: meeting)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func group(title: LocalizedStringKey, meetings: [CalendarMeeting], @ViewBuilder row: @escaping (CalendarMeeting) -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text(title).appFont(size: 15, weight: .medium)
            VStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { (item: (offset: Int, element: CalendarMeeting)) in
                    if item.offset > 0 {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    row(item.element)
                }
            }
            .padding(.horizontal, 14)
            .cardSurface(cornerRadius: 16)
        }
    }

    /// Biten etkinlik: kaydı varsa notun durumu ve "Notu aç", yoksa "Kaydedilmedi".
    private func pastRow(meeting: CalendarMeeting) -> some View {
        let time: String = meeting.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
            + "–" + meeting.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
        let record: MeetingRecord? = recordedMeeting(meeting: meeting, records: model.meetings)
            .map { namedRecord(record: $0, userName: model.userName) }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time).appFont(size: 12, weight: .medium).monospacedDigit().foregroundStyle(Theme.muted)
                Text(meeting.title).appFont(size: 14, weight: .medium).lineLimit(1)
                if let summary = record?.note?.summary {
                    Text(summary)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let record {
                Button(record.note == nil ? LocalizedStringKey("Kaydı aç") : LocalizedStringKey("Notu aç"), systemImage: "doc.text") { onOpenMeeting(record.id) }
                    .controlSize(.small)
            } else {
                Text("Kaydedilmedi").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 10)
    }

    private func row(meeting: CalendarMeeting, now: Date) -> some View {
        let isSoon: Bool = meeting.start.timeIntervalSince(now) <= 600
        let time: String = meeting.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
            + "–" + meeting.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time).appFont(size: 12, weight: .medium).monospacedDigit().foregroundStyle(isSoon ? NoticeSeverity.attention.tint : Theme.muted)
                Text(meeting.title).appFont(size: 14, weight: .medium).lineLimit(1)
                if !meeting.attendees.isEmpty {
                    Text(meeting.attendees.prefix(4).joined(separator: ", ") + (meeting.attendees.count > 4 ? " +\(meeting.attendees.count - 4)" : ""))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !model.meetings.isEmpty {
                Button("Brifing", systemImage: "text.magnifyingglass") { onBriefing(meeting) }
                    .controlSize(.small)
                    .hoverHint("Bu kişilerle ve konuda önceki toplantılar, kararlar, açık görevler", alignment: .trailing, edge: .bottom)
            }
            if let url = meeting.joinURL {
                Button("Katıl", systemImage: "video") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
                    .hoverHint("Görüşme bağlantısını aç: \(url.host() ?? "")", alignment: .trailing, edge: .bottom)
            }
            // Kayıt kartındaki "Kaydı başlat" ile aynı koşul: bitirilirken, devredilirken, başlarken ya da model hazır
            // değilken kapalı (yoksa boş panel açılırdı).
            if isSoon, model.phase == .idle {
                Button("Dinle", systemImage: "record.circle") { onStartRecording() }
                    .buttonStyle(.pillPrimary)
                    .controlSize(.small)
                    .disabled(!model.isReadyToRecord || model.isStarting || startBlock != nil)
            }
        }
        .padding(.vertical, 10)
    }
}

/// Görev satırı: tamamlandı kutusu, iş, tarih ve toplantı adı (tıklayınca toplantı açılır), Anımsatıcılar'a ekleme.
private struct TaskLine: View {
    let model: AppModel
    let record: MeetingRecord
    let task: NoteTask
    /// İşin altında son günün yanında gösterilen toplantı adı; toplantının kartındaysa nil.
    let meetingTitle: String?
    let onOpen: @MainActor () -> Void
    @State private var isHovering: Bool = false

    var body: some View {
        let isDone: Bool = isTaskDone(record: record, task: task)
        HStack(alignment: .center, spacing: 8) {
            TaskCheckbox(isDone: isDone) { model.toggleTask(meetingID: record.id, task: task) }
                .disabled(model.isLocked(meetingID: record.id))
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.description)
                            .appFont(size: 14, weight: .regular)
                            .strikethrough(isDone, color: Theme.muted)
                            .foregroundStyle(isDone ? Theme.muted : Theme.ink)
                        if task.dueDate != nil || meetingTitle != nil {
                            // Son gün toplantı gününe göre çözülür, arayüz dilinde göreli ("Yarın", "2 gün gecikti").
                            HStack(spacing: 5) {
                                TaskDueText(record: record, task: task, size: 12)
                                if task.dueDate != nil, meetingTitle != nil {
                                    Text(verbatim: "·").foregroundStyle(Theme.muted)
                                }
                                if let meetingTitle {
                                    Text(verbatim: meetingTitle)
                                        .foregroundStyle(Theme.muted)
                                        .lineLimit(1)
                                }
                            }
                            .appFont(size: 12, weight: .regular)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            // Zil yalnız anımsatıcı eklendiyse ya da fare satırdayken (her satırda sürekli durunca gürültüydü).
            ReminderButton(model: model, record: record, task: task)
                .opacity(isHovering || isTaskReminded(record: record, task: task) ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { (hovering: Bool) -> Void in isHovering = hovering }
        .animation(.smooth(duration: 0.2), value: isDone)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contextMenu {
            Button(isDone ? "Tamamlanmadı olarak işaretle" : "Tamamlandı olarak işaretle", systemImage: isDone ? "circle" : "checkmark.circle") {
                model.toggleTask(meetingID: record.id, task: task)
            }
            .disabled(model.isLocked(meetingID: record.id))
            // Yalnız elle eklenen görev silinir; nottan gelen görev notun parçasıdır.
            if task.isAdded == true {
                Button("Görevi sil", systemImage: "trash", role: .destructive) {
                    model.removeAddedTask(meetingID: record.id, task: task)
                }
                .disabled(model.isLocked(meetingID: record.id))
            }
        }
    }
}

/// Son toplantılar: gradyan kapaklı kartlar (renk toplantıya göre sabit), başlık ve bilgi kapağın üstünde.
private struct RecentMeetingCards: View {
    let model: AppModel
    let router: MainWindowRouter
    /// Notlardaki konuşmacı etiketleri adlarla; adı kullanıcının adı olan konuşmacının görevleri onundur.
    private var userName: String { model.userName }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack {
                Text("Son toplantılar").appFont(size: 15, weight: .medium)
                Spacer(minLength: 0)
                if !model.meetings.isEmpty {
                    Button("Tümünü gör ›") { router.section = .meetings }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                }
            }
            if model.meetings.isEmpty {
                QuietEmptyCard(symbol: "waveform", title: "Henüz toplantı yok", message: "Kaydı başlatınca toplantıların ve notların burada görünür.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(model.namedMeetings(userName: userName).prefix(6)) { (record: MeetingRecord) in
                        Button {
                            router.selectedMeetingID = record.id
                            router.section = .meetings
                        } label: {
                            MeetingCover(record: record, isProcessing: model.processingMeetingIDs.contains(record.id))
                        }
                        .buttonStyle(.hoverPlain)
                    }
                }
            }
        }
    }
}

/// Toplantı kartı: toplantıya göre sabit renkli gradyan kapak; başlık, tarih ve görev sayısı kapağın altında.
private struct MeetingCover: View {
    let record: MeetingRecord
    let isProcessing: Bool

    var body: some View {
        let mine: Int = record.note?.tasks.filter(\.isMine).count ?? 0
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(seed: record.id)
                // Ortada toplantıya özgü ses dalgası, kapağın kendi renginin koyu tonunda.
                .overlay { CoverWaveform(seed: record.id) }
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .tilt3D(maxAngle: 4)
            Text(record.note?.title ?? record.title)
                .appFont(size: 14, weight: .medium)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.top, 10)
            coverSubtitle(mine: mine)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "tarih · durum" ya da "tarih · görev sayısı"; hata durumunda yalnızca durum kısmı hata renginde.
    private func coverSubtitle(mine: Int) -> Text {
        let date: String = record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))
        if isProcessing || record.status == .processing {
            return Text(verbatim: date + " · " + String(localized: "İşleniyor"))
        }
        if record.status == .failed {
            var line: AttributedString = AttributedString(date + " · ")
            var status: AttributedString = AttributedString(String(localized: "Hata"))
            status.foregroundColor = NoticeSeverity.error.tint
            line += status
            return Text(line)
        }
        return Text(verbatim: mine > 0 ? date + " · " + String(localized: "\(mine) görev") : date)
    }
}

/// Görevlerim: tüm toplantılardan sana düşen işler. Açık görevler son günlerine göre gruplu (gecikmiş, bugün,
/// önümüzdeki 7 gün, daha sonra, tarihsiz; grup içinde yakın tarih önce), tamamlananlar toplantıya göre. "Görev ekle"
/// ile elle görev eklenir (bir toplantının notuna).
private struct TasksPage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var showsDone: Bool = false
    @State private var isAdding: Bool = false
    /// Notlardaki konuşmacı etiketleri adlarla; adı kullanıcının adı olan konuşmacının görevleri onundur.
    private var userName: String { model.userName }

    var body: some View {
        let named: [MeetingRecord] = model.namedMeetings(userName: userName)
        let all: [(record: MeetingRecord, task: NoteTask)] = myTasks(namedRecords: named)
        let doneCount: Int = all.filter { isTaskDone(record: $0.record, task: $0.task) }.count
        let open: [(record: MeetingRecord, task: NoteTask)] = all.filter { !isTaskDone(record: $0.record, task: $0.task) }
        let dueGroups: [TaskDueGroup] = groupedByDueDay(items: open, now: Date(), calendar: Calendar.current)
        let doneGroups: [(record: MeetingRecord, tasks: [NoteTask])] = named.compactMap { (record: MeetingRecord) -> (record: MeetingRecord, tasks: [NoteTask])? in
            let mine: [NoteTask] = (record.note?.tasks ?? []).filter { $0.isMine && isTaskDone(record: record, task: $0) }
            return mine.isEmpty ? nil : (record: record, tasks: mine)
        }
        let isEmpty: Bool = showsDone ? doneGroups.isEmpty : dueGroups.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sana düşen görevler")
                        .appFont(size: 28, weight: .regular)
                        .tracking(-0.4)
                    Spacer(minLength: 0)
                    Button("Görev ekle", systemImage: "plus") { isAdding = true }
                        .buttonStyle(.pill)
                        .disabled(addableMeetings(named: named).isEmpty)
                        .hoverHint("Bir toplantıya kendi görevini ekle", alignment: .center, edge: .bottom)
                        .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                            AddTaskForm(meetings: addableMeetings(named: named), fixedMeetingID: nil) { (meetingID: String, text: String, dueDay: Date?) -> Void in
                                model.addTask(meetingID: meetingID, description: text, dueDay: dueDay)
                                isAdding = false
                            } onCancel: {
                                isAdding = false
                            }
                        }
                    PillPicker(selection: $showsDone, options: [
                        (false, "Açık · \(all.count - doneCount)"), (true, "Tamamlanan · \(doneCount)"),
                    ])
                    .monospacedDigit()
                    .fixedSize()
                }
                // Yüz yüze toplantıda kullanıcı da "Konuşmacı N": hangisi olduğu seçilmeden görevleri buraya düşmez.
                if !showsDone {
                    PendingUserSpeakerMeetings(meetings: named, userName: userName) { (meetingID: String) -> Void in
                        router.selectedMeetingID = meetingID
                        router.section = .meetings
                    }
                }
                if isEmpty {
                    emptyState(doneCount: doneCount)
                }
                if showsDone {
                    ForEach(doneGroups, id: \.record.id) { (group: (record: MeetingRecord, tasks: [NoteTask])) in
                        meetingGroup(record: group.record, tasks: group.tasks)
                    }
                } else {
                    ForEach(dueGroups, id: \.bucket) { (group: TaskDueGroup) in
                        dueGroup(group: group)
                    }
                }
            }
            .animation(.smooth(duration: 0.25), value: showsDone)
            .animation(.smooth(duration: 0.25), value: doneCount)
            .padding(36)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Görev eklenebilecek toplantılar: notu olan, örnek olmayan, kayıtta ya da işlenmekte olmayan (en yeni önce).
    private func addableMeetings(named: [MeetingRecord]) -> [MeetingRecord] {
        named.filter { $0.note != nil && !$0.isSampleMeeting && !model.isLocked(meetingID: $0.id) }
    }

    /// Son güne göre bir grup: başlık (gecikmişte kırmızı) ve görevler; her satırda toplantının adı.
    private func dueGroup(group: TaskDueGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: taskDueBucketTitle(bucket: group.bucket))
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(group.bucket == .overdue ? NoticeSeverity.error.tint : Theme.ink)
                Text(verbatim: "\(group.tasks.count)")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(group.tasks, id: \.rowID) { (item: DatedTask) in
                    TaskLine(model: model, record: item.record, task: item.task, meetingTitle: item.record.note?.title ?? item.record.title) {
                        router.selectedMeetingID = item.record.id
                        router.section = .meetings
                    }
                }
            }
            .padding(8)
            .cardSurface(cornerRadius: 16)
        }
        .transition(.opacity)
    }

    /// Tamamlananlarda toplantıya göre grup: başlığa tıklayınca toplantı açılır.
    private func meetingGroup(record: MeetingRecord, tasks: [NoteTask]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                router.selectedMeetingID = record.id
                router.section = .meetings
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.note?.title ?? record.title).appFont(size: 15, weight: .medium)
                        Text(meetingMetaLine(record: record)).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            ForEach(tasks, id: \.trackingKey) { (task: NoteTask) in
                // Toplantının adı kartın başlığında: altta yalnız tarih.
                TaskLine(model: model, record: record, task: task, meetingTitle: nil) {
                    router.selectedMeetingID = record.id
                    router.section = .meetings
                }
            }
        }
        .padding(8)
        .cardSurface(cornerRadius: 16)
        .transition(.opacity)
    }

    @ViewBuilder
    private func emptyState(doneCount: Int) -> some View {
        if showsDone {
            QuietEmptyCard(symbol: "checkmark.circle", title: "Tamamlanan görev yok", message: "Bitirdiğin görevler burada birikir.")
        } else if doneCount > 0 {
            EmptyScene(symbol: "party.popper.fill", palette: .coral, title: "Açık görevin kalmadı", message: "Hepsi tamamlandı.") {
                EmptyView()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .overlay { ConfettiBurst(palette: .coral) }
        } else {
            EmptyScene(
                symbol: "checklist", palette: .coral, title: "Henüz sana düşen görev yok",
                message: "Toplantı notunda senin adına yazılan işler burada toplanır."
            ) {
                if model.userName.isEmpty {
                    Button("Adını yaz (görevlerin tanınsın)", systemImage: "person.text.rectangle") { router.section = .settings }
                        .buttonStyle(.accentPill)
                        .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }
}

/// Toplantılar bölümü: solda liste (üst çubuktaki aramayla süzülür), sağda seçili toplantının sayfası. Hiç toplantı
/// yokken liste sütunu gösterilmez; tüm alanı ilk açılış sahnesi kaplar (kayıt, içe aktarma, sıradaki toplantı).
private struct MeetingsSplit: View {
    let model: AppModel
    let router: MainWindowRouter
    let player: MeetingAudioPlayer
    let shortcuts: ShortcutController
    let onStartRecording: @MainActor () -> Void
    @AppStorage(SettingsKey.meetingsListVisible) private var listVisible: Bool = true
    /// Notlardaki konuşmacı etiketleri adlarla; adı kullanıcının adı olan konuşmacının görevleri onundur.
    private var userName: String { model.userName }

    var body: some View {
        if model.meetings.isEmpty {
            MeetingsFirstRun(
                model: model, router: router, recordShortcut: keyBindingDisplay(binding: shortcuts.currentBinding(action: .record)),
                onStartRecording: onStartRecording
            )
            .transition(.opacity)
        } else {
            split
        }
    }

    private var split: some View {
        HStack(spacing: 0) {
            // Liste üst çubuktaki düğmeyle gizlenir (düğme Toplantılar'da her zaman görünür).
            if listVisible {
                MeetingsListPage(
                    model: model, selectedID: router.selectedMeetingID, query: router.searchQuery, folder: router.folderFilter,
                    onClearFolder: { router.folderFilter = nil },
                    onOpen: { (id: String) -> Void in router.selectedMeetingID = id },
                    onDeleted: { (ids: Set<String>) -> Void in
                        if let open = router.selectedMeetingID, ids.contains(open) {
                            router.selectedMeetingID = nil
                        }
                    }
                )
                .frame(width: 300)
                // Ses/video dosyası listeye bırakılınca toplantı olarak içe aktarılır.
                .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
                    let media: [URL] = mediaFileURLs(urls: urls)
                    guard !media.isEmpty else {
                        return false
                    }
                    model.importMedia(urls: media)
                    return true
                }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                if let id = router.selectedMeetingID, let stored = model.meetings.first(where: { $0.id == id }) {
                    // Sayfa notu konuşmacı adlarıyla gösterir; değişiklikler kimlikle saklı kayda yapılır.
                    let record: MeetingRecord = namedRecord(record: stored, userName: userName)
                    MeetingDetailPage(
                        model: model, player: player, record: record, openingSource: router.openingSource, askFocusRequest: router.askFocusRequest
                    ) {
                        router.selectedMeetingID = nil
                    } onRunRecipe: { (recipe: Recipe) -> Void in
                        // Tarif Sor sayfasında yeni bir sohbette bu toplantıya sorulur (kapsam çipinden genişletilebilir).
                        model.askChats.clear(context: .allMeetings)
                        model.askChats.select(scope: .meeting(id: record.id), context: .allMeetings)
                        model.askQuestion(context: .allMeetings, question: recipe.prompt, scope: .meeting(id: record.id), mentionIDs: [], recipeTitle: recipe.title)
                        router.section = .ask
                    } onSourceShown: {
                        router.openingSource = nil
                    } onOpenOtherSource: { (passage: ArchivePassage) -> Void in
                        // Kapsam başka toplantıları da okuduysa kaynağın toplantısı o anında açılır.
                        router.openingSource = passage
                        router.selectedMeetingID = passage.meetingID
                        router.searchQuery = ""
                        router.folderFilter = nil
                    }
                        // Toplantı değişince ad alanları gibi durumlar sıfırlansın.
                        .id(record.id)
                        .transition(.opacity)
                } else if router.selectedMeetingID != nil {
                    // Seçilen toplantı bu hesapta yok (bağlantı başka hesabın ya da silinmiş toplantısını gösterdi).
                    QuietEmptyState(symbol: "doc.questionmark", title: "Toplantı bulunamadı", message: "Bu toplantı silinmiş ya da başka bir hesapta olabilir.") {
                        if let latest = model.meetings.first {
                            Button("Son toplantıyı aç") { router.selectedMeetingID = latest.id }
                                .buttonStyle(.pill)
                        }
                    }
                    .transition(.opacity)
                } else {
                    // Seçim yokken sakin yer tutucu: en son toplantı tek tıkla açılır. Kendiliğinden açılmaz: klasör
                    // seçince ve silince seçim bilerek boşalır, ağır toplantı sayfası (transkript, ses) istenmeden yüklenmez.
                    QuietEmptyState(symbol: "doc.text", title: "Bir toplantı aç", message: "Not, görevler ve transkript burada görünür.") {
                        HStack(spacing: 8) {
                            if let latest = model.meetings.first {
                                Button("Son toplantıyı aç") { router.selectedMeetingID = latest.id }
                                    .buttonStyle(.pill)
                                    .hoverHint(verbatim: latest.note?.title ?? latest.title, alignment: .center, edge: .bottom)
                            }
                            if !listVisible {
                                Button("Listeyi göster", systemImage: "sidebar.left") { listVisible = true }
                                    .buttonStyle(.pill)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.25), value: router.selectedMeetingID)
        }
        .animation(.smooth(duration: 0.25), value: listVisible)
    }
}

/// Kenar çubuğunda klasörler (Otter'daki kanallar gibi): proje, ekip ya da ders başına; tıklayınca Toplantılar o
/// klasörle süzülür. "+" ile satır içinde yeni klasör; sağ tıkla silinir (toplantılar silinmez).
private struct SidebarFolders: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var isAdding: Bool = false
    @State private var newName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Klasörler").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Button {
                    isAdding = true
                    isFocused = true
                } label: {
                    Image(systemName: "plus").appFont(size: 11, weight: .semibold).foregroundStyle(Theme.muted).frame(width: 20, height: 20)
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("Yeni klasör", alignment: .trailing, edge: .bottom)
            }
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 4)
            ForEach(model.folders) { (folder: FolderSummary) in
                let isSelected: Bool = router.section == .meetings && router.folderFilter?.caseInsensitiveCompare(folder.name) == .orderedSame
                Button {
                    router.folderFilter = folder.name
                    router.selectedMeetingID = nil
                    router.section = .meetings
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "folder.fill" : "folder").appFont(size: 13, weight: .regular).frame(width: 18)
                        Text(folder.name).appFont(size: 13, weight: isSelected ? .medium : .regular).lineLimit(1)
                        Spacer(minLength: 0)
                        if folder.count > 0 {
                            Text("\(folder.count)").appFont(size: 11, weight: .medium).monospacedDigit().foregroundStyle(Theme.muted)
                        }
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isSelected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.hoverPlain)
                .contextMenu {
                    Button("Klasörü sil", systemImage: "trash", role: .destructive) {
                        if router.folderFilter == folder.name {
                            router.folderFilter = nil
                        }
                        model.deleteFolder(name: folder.name)
                    }
                    // İşlenen toplantı klasörden çıkarılamaz; silinse klasör yeniden belirirdi.
                    .disabled(!model.canDeleteFolder(name: folder.name))
                }
            }
            if isAdding {
                TextField("Klasör adı", text: $newName)
                    .textFieldStyle(.plain)
                    .appFont(size: 13, weight: .regular)
                    .focused($isFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                    .onSubmit {
                        model.createFolder(name: newName)
                        newName = ""
                        isAdding = false
                    }
                    .onExitCommand {
                        newName = ""
                        isAdding = false
                    }
            }
        }
    }
}

/// Ana penceredeki hata şeridi (ortak uyarı şeridi): en yeni hata başlıkta, öncekiler (en çok iki) ikinci satırda;
/// kapatılabilir. Metin seçilebilir (destek için kopyalanabilsin).
private struct ErrorBanner: View {
    let messages: [String]
    let onDismiss: @MainActor () -> Void

    var body: some View {
        let earlier: [String] = Array(messages.dropLast())
        NoticeBar(
            severity: .error,
            title: Text(verbatim: messages.last ?? ""),
            detail: earlier.isEmpty ? nil : Text(verbatim: earlier.joined(separator: "\n")),
            onDismiss: onDismiss
        ) {
            EmptyView()
        }
        .textSelection(.enabled)
    }
}

/// Saate göre selam; ad varsa ilk adıyla. Saf fonksiyondur.
func homeGreeting(name: String, hour: Int) -> String {
    let base: String = switch hour {
    case 5..<12: String(localized: "Günaydın")
    case 12..<18: String(localized: "İyi günler")
    case 18..<23: String(localized: "İyi akşamlar")
    default: String(localized: "İyi geceler")
    }
    let first: String = name.split(separator: " ").first.map(String.init) ?? ""
    return first.isEmpty ? base : "\(base), \(first)"
}

/// Orta ekrandaki arama penceresi (Spotlight gibi): arka plan bulanıklaşır ve kararır; büyük arama alanı yazıldıkça
/// toplantıları süzer (başlık, not, görevler, adlar, transkript) ve her sonucun altında eşleşen cümleyi ve
/// transkriptteki anını gösterir; sonda soruyu Sor'da bütün toplantılara soran satır. Arama yazmayı `searchDebounce`
/// kadar bekler ve ana iş parçacığının dışında önbellekli çalışır (`AppModel.searchCache`). ↑↓ seçer, ↩ seçileni açar
/// (seçim yoksa aramayı Toplantılar listesine uygular), Esc ya da dışarı tıklama kapatır.
private struct SearchComposer: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var query: String = ""
    @State private var highlighted: Int = 0
    /// Son biten aramanın sorgusu ve sonuçları (yeni arama bitene dek eskisi görünür).
    @State private var searched: MacSearchResults = MacSearchResults(query: "", hits: [])
    @FocusState private var isFocused: Bool

    var body: some View {
        let trimmed: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetings: [MeetingRecord] = model.namedMeetings(userName: model.userName)
        let byID: [String: MeetingRecord] = Dictionary(meetings.map { ($0.id, $0) }) { (first: MeetingRecord, _: MeetingRecord) -> MeetingRecord in first }
        let hits: [MeetingSearchHit] = trimmed.isEmpty
            ? meetings.prefix(8).map { MeetingSearchHit(meetingID: $0.id, field: .title, snippet: nil, startSec: nil) }
            : Array(searched.hits.filter { byID[$0.meetingID] != nil }.prefix(8))
        let items: [SearchComposerItem] = hits.map { SearchComposerItem.meeting($0) } + (trimmed.isEmpty ? [] : [SearchComposerItem.ask(trimmed)])
        ZStack(alignment: .top) {
            // Arkadaki içerik pencerede bulanıklaşır; burada yalnızca dışarı tıklayınca kapatan saydam katman.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .appFont(size: 18, weight: .medium)
                        .foregroundStyle(Theme.muted)
                    TextField("Toplantılarda ara…", text: $query)
                        .textFieldStyle(.plain)
                        .appFont(size: 20, weight: .regular)
                        .focused($isFocused)
                        .onSubmit { open(items: items) }
                    Text("esc")
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                }
                .padding(.horizontal, 18)
                .frame(height: 60)
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    if hits.isEmpty, searched.query == trimmed {
                        Text("Eşleşen toplantı yok")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else if !hits.isEmpty {
                        Text(trimmed.isEmpty ? "Son toplantılar" : "Toplantılar")
                            .appFont(size: 11, weight: .semibold)
                            .tracking(DesignTokens.labelTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { (item: (offset: Int, element: SearchComposerItem)) in
                        let isHighlighted: Bool = item.offset == min(highlighted, items.count - 1)
                        Group {
                            switch item.element {
                            case .meeting(let hit):
                                if let record = byID[hit.meetingID] {
                                    row(record: record, hit: hit, isHighlighted: isHighlighted)
                                }
                            case .ask(let question):
                                askRow(question: question, isHighlighted: isHighlighted)
                            }
                        }
                        .onHover { (hovering: Bool) -> Void in
                            if hovering {
                                highlighted = item.offset
                            }
                        }
                    }
                }
                .padding(8)
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 14) {
                    Text("↑↓ seç")
                    Text("↩ aç")
                    Spacer(minLength: 0)
                    if !trimmed.isEmpty {
                        Button("Tüm sonuçları listede göster") { applyToList() }
                            .buttonStyle(.hoverPlain)
                    }
                }
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 16)
                .frame(height: 34)
            }
            .frame(width: 600)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 18)
            // Pencerenin tam ortasında (sağdan ve soldan eşit; büyük ekranda içerik alanına göre ortalanınca sağa kaymış
            // görünüyordu).
            .padding(.top, 96)
        }
        .onAppear {
            query = router.searchQuery
            isFocused = true
        }
        .onChange(of: query) { (_: String, _: String) -> Void in highlighted = 0 }
        .task(id: MacSearchRequest(query: trimmed, stamps: meetings.map(searchStamp(record:)))) {
            guard !trimmed.isEmpty else {
                searched = MacSearchResults(query: "", hits: [])
                return
            }
            // Yazarken her harfte aranmaz: yeni harf bu görevi iptal eder.
            do {
                try await Task.sleep(for: searchDebounce)
            } catch {
                return
            }
            let found: [MeetingSearchHit] = await model.searchCache.search(records: meetings, query: trimmed)
            guard !Task.isCancelled else {
                return
            }
            searched = MacSearchResults(query: trimmed, hits: found)
        }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(0, items.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onExitCommand { close() }
    }

    private func row(record: MeetingRecord, hit: MeetingSearchHit, isHighlighted: Bool) -> some View {
        Button {
            openMeeting(id: record.id)
        } label: {
            HStack(spacing: 12) {
                CoverImage(seed: record.id)
                    .frame(width: 40, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.note?.title ?? record.title)
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let snippet = hit.snippet {
                        Text(verbatim: snippet)
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.ink.opacity(0.8))
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let startSec = hit.startSec {
                            Text(verbatim: timestamp(seconds: startSec))
                                .monospacedDigit()
                                .accessibilityLabel(Text("Transkriptte \(timestamp(seconds: startSec))"))
                            Text(verbatim: "·").accessibilityHidden(true)
                        }
                        Text(record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                    }
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                if isHighlighted {
                    Image(systemName: "return")
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHighlighted ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Sonların altındaki satır: sorguyu Sor'da bütün toplantılara sorar.
    private func askRow(question: String, isHighlighted: Bool) -> some View {
        Button {
            askEverything(question: question)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 28)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                Text("Sor: \u{201C}\(question)\u{201D}")
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHighlighted ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Bütün toplantılarına sorar"))
    }

    /// ↩: vurgulanan satırı açar (toplantı ya da Sor); sonuç yoksa aramayı listeye uygular.
    private func open(items: [SearchComposerItem]) {
        guard !items.isEmpty else {
            applyToList()
            return
        }
        switch items[min(highlighted, items.count - 1)] {
        case .meeting(let hit): openMeeting(id: hit.meetingID)
        case .ask(let question): askEverything(question: question)
        }
    }

    private func askEverything(question: String) {
        if model.startAskingEverything(question: question) {
            router.section = .ask
        }
        close()
    }

    private func openMeeting(id: String) {
        router.searchQuery = ""
        router.folderFilter = nil
        router.selectedMeetingID = id
        router.section = .meetings
        close()
    }

    /// Aramayı Toplantılar listesine uygular (üst çubukta görünür, × ile temizlenir).
    private func applyToList() {
        router.searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        router.folderFilter = nil
        router.section = .meetings
        close()
    }

    private func close() {
        router.isSearchPresented = false
    }
}

/// Arama penceresinin satırı: eşleşen toplantı ya da soruyu Sor'a soran satır.
private enum SearchComposerItem: Identifiable {
    case meeting(MeetingSearchHit)
    case ask(String)

    var id: String {
        switch self {
        case .meeting(let hit): "meeting-\(hit.meetingID)"
        case .ask: "ask"
        }
    }
}

/// Aramanın son sonucu: hangi sorgunun sonucu olduğu ve eşleşen toplantılar.
private struct MacSearchResults: Equatable {
    let query: String
    let hits: [MeetingSearchHit]
}

/// Aramayı yeniden çalıştıran girdiler: sorgu ve toplantıların değişiklik izleri (`searchStamp`).
struct MacSearchRequest: Equatable {
    let query: String
    let stamps: [MeetingSearchStamp]
}

/// Kısayol kartının zemini: Sor'daki örnek kartlar gibi kart yüzeyi, sağa doğru beliren ince çapraz çizgiler ve çerçeve.
private struct ShortcutCardBackground: View {
    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            shape.fill(Theme.card)
            DiagonalLines(spacing: 9)
                .stroke(Theme.line, lineWidth: 1)
                .mask(LinearGradient(colors: [.clear, .clear, .black], startPoint: .leading, endPoint: .trailing))
                .clipShape(shape)
            shape.strokeBorder(Theme.line)
        }
    }
}

/// Kayıt ekranı: kayıt sürerken ana pencerenin arkası bulanıklaşır, ortada paneldeki ses ölçerin büyük eşi, süre ve
/// durum; altında duraklat/devam, paneli göster ve kırmızı "Bitir". "Uygulamaya dön" (ya da Esc) ekranı bu kayıt için
/// kapatır; üst çubuktaki "Kayıtta" hapı geri açar.
private struct RecordingFocus: View {
    let model: AppModel
    let router: MainWindowRouter
    let onShowPanel: @MainActor () -> Void
    // Ekran açılınca odak buraya alınır: tuşlar ve Return arkadaki gizli alanlara (ör. Sor kutusu) gitmesin.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Arkadaki içerik pencerede bulanıklaşır; koyu perde yok. Temanın zemin rengiyle hafif bir örtü yazıyı
            // açık ve koyu temada okunur tutar, tıklamaları da arkaya geçirmez.
            Theme.background
                .opacity(0.35)
                .contentShape(Rectangle())
                .ignoresSafeArea()
            VStack(spacing: 22) {
                if let deadline = model.callEndDeadline {
                    CallEndNotice(deadline: deadline) { model.keepRecordingAfterCallEnd() } onStop: { model.stopRecording() }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: 520)
                }
                LargeLevelMeter(levels: model.audioLevels)
                    .opacity(model.isPaused ? 0.35 : 1)
                VStack(spacing: 6) {
                    if let startedAt = model.recordingTimerStart {
                        TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                            // Duraklatmada süre duraklatma anında durur (duraklatılan süre sayılmaz).
                            Text(timestamp(seconds: model.pauseClock.pausedAt.map { $0.timeIntervalSince(startedAt) } ?? context.date.timeIntervalSince(startedAt)))
                                .appFont(size: 40, weight: .semibold)
                                .monospacedDigit()
                                .tracking(-1)
                        }
                    }
                    Text(model.isPaused ? "Duraklatıldı" : "Dinleniyor — konuşmalar canlı panelde yazıya dökülüyor")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 10) {
                    Button(model.isPaused ? "Devam ettir" : "Duraklat", systemImage: model.isPaused ? "play.fill" : "pause.fill") { model.togglePause() }
                        .buttonStyle(.pill)
                    Button("Paneli göster", systemImage: "rectangle.on.rectangle") { onShowPanel() }
                        .buttonStyle(.pill)
                    Button {
                        model.stopRecording()
                    } label: {
                        Label("Bitir", systemImage: "stop.fill")
                            .appFont(size: 13, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.red, in: Capsule())
                    }
                    .buttonStyle(.hoverCapsule)
                }
                // Bulanık zeminde soluk renk okunmuyordu: koyu yazı.
                Button("Uygulamaya dön") { router.isRecordingFocusDismissed = true }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .appFont(size: 12, weight: .medium)
                    .padding(.top, 4)
            }
            .padding(36)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onExitCommand { router.isRecordingFocusDismissed = true }
    }
}

/// ⌘J ile açılan Sor paneli: sayfanın altında yüzen Sor çubuğu ve sohbeti, bulunulan yerin kapsamıyla (klasör, kişi ya
/// da tüm toplantılar; kapsam çipinden değişir). Tüm toplantılar bağlamı Sor sayfasıyla aynı sohbettir. Esc, aşağı ok
/// ya da başka bölüme geçmek paneli kapatır; cevap sürer.
private struct AskOverlay: View {
    let model: AppModel
    let router: MainWindowRouter
    let context: AskScope
    @State private var focusRequest: Int = 0
    @State private var pageHeight: CGFloat = 0

    var body: some View {
        let scope: AskScope = model.askChats.scope(context: context)
        let isOpen: Binding<Bool> = Binding<Bool>(
            get: { true },
            set: { (open: Bool) -> Void in
                if !open {
                    router.askOverlay = nil
                }
            }
        )
        ObservationScope {
            AskBar(
                exchanges: model.askChats.exchanges(context: context), isAnswering: model.askChats.isAnswering(context: context),
                followUps: [], quickActions: [], recipes: model.recipes, isEditingNote: false,
                scopeMenu: askScopeMenu(context: context, selected: scope, records: model.meetings, folders: model.folders, userName: model.userName),
                firstName: askFirstName(userName: model.userName),
                suggestions: model.askChats.exchanges(context: context).isEmpty ? askSuggestions(scope: scope, records: model.meetings, userName: model.userName, now: Date(), calendar: Calendar.current, limit: 4).map { askSuggestionText(suggestion: $0) } : [],
                transcript: nil, isPanelOpen: isOpen, conversationMaxHeight: bottomPanelMaxHeight(pageHeight: pageHeight, cap: 420),
                enlargedConversationMaxHeight: enlargedConversationMaxHeight(pageHeight: pageHeight, chrome: 200), focusRequest: focusRequest,
                onSelectScope: { (selected: AskScope) -> Void in model.askChats.select(scope: selected, context: context) },
                onAsk: { (question: String, recipeTitle: String?) -> Void in
                    model.askQuestion(context: context, question: question, scope: scope, mentionIDs: [], recipeTitle: recipeTitle)
                },
                onQuickAction: { (_: MeetingQuickAction) -> Void in },
                onStop: { model.askChats.stop(context: context) },
                onClear: { model.askChats.clear(context: context) },
                onRegenerate: { model.regenerateAnswer(context: context) },
                onOpenSource: { (passage: ArchivePassage) -> Void in
                    // Kaynak toplantı o anında açılır; panel kapanır (sohbet saklı kalır, ⌘J geri getirir).
                    router.askOverlay = nil
                    router.openingSource = passage
                    router.selectedMeetingID = passage.meetingID
                    router.searchQuery = ""
                    router.folderFilter = nil
                    router.section = .meetings
                },
                onSaveRecipe: { (question: String) -> Void in model.saveRecipe(question: question) },
                onAskMeetings: { (meetingIDs: [String]) -> Void in
                    guard let last = model.askChats.exchanges(context: context).last else {
                        return
                    }
                    model.askQuestion(context: context, question: last.question, scope: scope, mentionIDs: meetingIDs, recipeTitle: last.recipeTitle)
                }
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            GeometryReader { (proxy: GeometryProxy) in
                Color.clear.onAppear { pageHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { (_: CGFloat, height: CGFloat) -> Void in pageHeight = height }
            }
        }
        .onAppear { focusRequest += 1 }
        .onChange(of: router.askFocusRequest) { (_: Int, _: Int) -> Void in focusRequest += 1 }
    }
}
