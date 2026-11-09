import AINotepadCore
import Foundation
import Observation
import os

private let hostedAssistantLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedAssistant")

// Yapay zekâ asistanı erişiminin uygulama tarafı (Mac'teki Gistsmith ve iPhone ortak; tasarım
// docs/superpowers/specs/2026-11-05-remote-mcp.md). İsteğe bağlıdır (varsayılan kapalı) ve sunucunun `ASSISTANT_POLICY`
// anahtarının arkasındadır: sunucu özelliği kapalı bildirirse Ayarlar'daki bölüm hiç görünmez. Açılınca bu cihazın
// toplantılarının not kopyası (asla ses, metin dökümü, ekran görüntüsü ya da ses izi) sunucuya yüklenir ve bağlanan
// asistanlar mcp.gistsmith.com üzerinden okur. Ayar hesabındır: bir cihazda açılınca hesabın her cihazı kendi
// toplantılarını yükler, kopya hepsinin birleşimidir. Mantık çekirdekte (`AssistantUploader`, `assistantUploadPlan`);
// burası durum, zamanlama ve hesap bağıdır.

/// Hesabın ayar alanındaki asistan anahtarları.
private enum HostedAssistantDefaultsKey {
    /// Sunucunun son bildirdiği açık/kapalı (çevrimdışı açılışta da kuyruk çalışsın diye).
    static let enabled: String = "assistant.enabled"
    /// Bu cihazın yükleyen cihaz kimliği (sunucuda "bu cihazın toplantılarını kaldır" bununla seçilir).
    static let deviceID: String = "assistant.deviceID"
    /// Bilinen bağlantılar: listede olmayan yeni bağlantı bildirilir.
    static let knownGrantIDs: String = "assistant.knownGrantIDs"
    /// Kullanıcı bu cihazın toplantılarını kopyadan kaldırdı: yeniden ekleyene dek bu cihaz yüklemez.
    static let deviceExcluded: String = "assistant.deviceExcluded"
}

/// Ön planda kendiliğinden yenileme aralığı (yeni bağlantılar ve başka cihazdaki kapatma için).
private let hostedAssistantRefreshSeconds: Double = 300
/// Yerel değişiklikten sonra yüklemeden önce bekleme (art arda düzenlemeler tek yükleme olsun).
private let hostedAssistantDebounceSeconds: Double = 3

/// Sunucunun özelliği sunup sunmadığı (`ASSISTANT_POLICY`).
enum HostedAssistantAvailability: Equatable {
    /// Henüz sorulmadı ya da sorulamadı (çevrimdışı).
    case unknown
    case available
    /// Sunucu özelliği kapalı bildirdi: Ayarlar'daki bölüm görünmez.
    case unavailable
}

/// Bu cihazın yüklemelerinin durumu.
enum HostedAssistantUploadStatus: Equatable {
    case idle
    case uploading
    /// Son geçiş başarısız; `retryAt`'te kendiliğinden yeniden denenir.
    case failed(message: String, retryAt: Date?)
}

/// Uygulamanın asistan merkezine verdiği bağlantılar.
struct HostedAssistantHooks {
    /// Yeni bir asistan bağlandı (adı): uygulama kendi bildirimini gösterir.
    let announceConnection: @MainActor (String) -> Void
}

/// Yüklü hesabın asistan erişimi: hesabın ayarı, bu cihazın yükleme kuyruğu, bağlı asistanlar ve yeni bağlantı
/// bildirimi. Tek örnek; hesap değişince ya da çıkışta durur, yeni hesapla yeniden kurulur.
@MainActor
@Observable
final class HostedAssistantCenter {
    static let shared: HostedAssistantCenter = HostedAssistantCenter()

    private(set) var availability: HostedAssistantAvailability = .unknown
    /// Hesapta açık (sunucunun son bildirdiği).
    private(set) var isOn: Bool = false
    /// Açma, kapatma ya da kaldırma sürüyor (düğmeler kilitlenir).
    private(set) var isChanging: Bool = false
    private(set) var uploadStatus: HostedAssistantUploadStatus = .idle
    /// Bu cihazdaki toplantılardan kaçının kopyası güncel; henüz hesaplanmadıysa nil.
    private(set) var progress: AssistantUploadProgress?
    /// Kopyadaki toplantılar (bütün cihazlardan) ve üst sınır; bilinmiyorsa nil.
    private(set) var copyMeetings: Int?
    private(set) var maxMeetings: Int?
    /// Bağlı asistanlar.
    private(set) var grants: [HostedAssistantGrant] = []
    /// Bu cihazın toplantıları kopyadan kaldırıldı (bu cihaz yüklemez).
    private(set) var isDeviceExcluded: Bool = false
    /// Açma, kapatma ya da bağlantı kesmenin hatası.
    private(set) var actionError: String?
    /// Kullanıcıya bir kez söylenen olay (yeni bağlantı, başka cihazda kapatıldı).
    private(set) var notice: String?

    @ObservationIgnored private var hooks: HostedAssistantHooks?
    @ObservationIgnored private var scope: (accountKey: String, userID: String)?
    @ObservationIgnored private var uploader: AssistantUploader?
    /// Son görülen toplantılar (bu cihazda kaydedilenler) ve kullanıcının adı.
    @ObservationIgnored private var meetings: [MeetingRecord]?
    @ObservationIgnored private var userName: String = ""
    /// Yükleme geçişlerinin durumu (`assistantPassStep`); görevler yan etkidir: zamanlayıcı (kısa bekleme ya da yeniden
    /// deneme beklemesi) ve süren geçiş.
    @ObservationIgnored private var passPhase: AssistantPassPhase = .idle
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var passTask: Task<Void, Never>?
    /// Dönemsel yenileme: hesap kurulduğundan ve özellik açık olduğundan durdurulana dek sürer (geçişlerin iptali onu
    /// durdurmaz).
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures: Int = 0
    @ObservationIgnored private var lastRefreshAt: Date?
    /// Her kurulumda ve geçişlerin her iptalinde artar: eski işin geç gelen sonucu yenisinin durumunu yazmaz.
    @ObservationIgnored private var generation: Int = 0
    /// Tanıtım modu: sunucuya hiç gidilmez.
    @ObservationIgnored private var isDemo: Bool = false

    private init() {}

    // MARK: Bağlantı

    func attach(hooks newHooks: HostedAssistantHooks) {
        hooks = newHooks
    }

    /// Hesap durumu değişti: hesap verisi yüklü ve aynı hesapla giriş yapılmışsa o hesabın asistan erişimi kurulur,
    /// değilse durur. Aynı hesap için tekrar çağrılırsa bir şey yapmaz.
    func update(scopeKey: HostedSyncScopeKey) async {
        guard !isDemo else {
            return
        }
        let next: (accountKey: String, userID: String)?
        if let loadedAccountKey = scopeKey.loadedAccountKey, let signedInUserID = scopeKey.signedInUserID, accountDataKey(userId: signedInUserID) == loadedAccountKey {
            next = (loadedAccountKey, signedInUserID)
        } else {
            next = nil
        }
        guard next?.accountKey != scope?.accountKey || next?.userID != scope?.userID else {
            return
        }
        stop()
        scope = next
        meetings = nil
        grants = []
        progress = nil
        copyMeetings = nil
        maxMeetings = nil
        actionError = nil
        notice = nil
        uploadStatus = .idle
        guard let next else {
            isOn = false
            isDeviceExcluded = false
            availability = .unknown
            return
        }
        do {
            let defaults: UserDefaults = try hostedAccountDefaults(accountKey: next.accountKey)
            isOn = defaults.bool(forKey: HostedAssistantDefaultsKey.enabled)
            isDeviceExcluded = defaults.bool(forKey: HostedAssistantDefaultsKey.deviceExcluded)
            uploader = AssistantUploader(
                client: try makeClient(), file: AssistantLedgerFile(url: AppPaths.accountAssistantLedger(dataRoot: try AppPaths.applicationSupport(), accountKey: next.accountKey)),
                deviceID: try deviceID(defaults: defaults)
            )
        } catch {
            hostedAssistantLogger.error("Asistan erişimi kurulamadı, hata: \(String(describing: error), privacy: .private)")
            uploadStatus = .failed(message: userFacingMessage(error: error), retryAt: nil)
            return
        }
        await refresh()
    }

    /// Sunucudan ayarı ve bağlantıları okur (Ayarlar açılınca, uygulama öne gelince, dönemsel); açıksa yükleme geçişi
    /// başlar. Sorulamazsa (çevrimdışı) bilinen durum kalır.
    func refresh() async {
        guard let scope, !isDemo else {
            return
        }
        let current: Int = generation
        lastRefreshAt = Date()
        do {
            let client: HostedAssistantClient = try makeClient()
            let settings: HostedAssistantSettings = try await client.settings()
            guard current == generation, self.scope?.accountKey == scope.accountKey else {
                return
            }
            availability = .available
            apply(settings: settings)
            if settings.enabled {
                try await refreshGrants(client: client, generation: current)
                schedulePass(delaySeconds: 0)
            }
        } catch HostedAssistantError.unavailable {
            guard current == generation else {
                return
            }
            availability = .unavailable
            stopPeriodic()
        } catch {
            hostedAssistantLogger.warning("Asistan erişiminin durumu sorulamadı, hata: \(String(describing: error), privacy: .private)")
            // Çevrimdışıyken bilinen açık durum kuyruğu bekletir; bağlantı gelince geçiş yeniden dener.
            if isOn, !isDeviceExcluded, meetings != nil {
                schedulePass(delaySeconds: 0)
            }
        }
    }

    /// Uygulama öne geldi: son yenilemeden bu yana en az bir dakika geçtiyse yenilenir (Mac'te pencereler arasında
    /// gidip gelmek her seferinde sunucuya gitmesin).
    func appBecameActive() {
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < 60 {
            return
        }
        Task { await refresh() }
    }

    // MARK: Kullanıcı eylemleri

    /// Ayarlar'daki anahtar açıldı: hesapta açılır; o anki bağlantılar taban olur, bu cihazın toplantıları en yeniden
    /// eskiye yüklenmeye başlar.
    func turnOn() async {
        guard scope != nil, !isChanging, !isDemo else {
            return
        }
        isChanging = true
        defer { isChanging = false }
        actionError = nil
        notice = nil
        do {
            let client: HostedAssistantClient = try makeClient()
            let settings: HostedAssistantSettings = try await client.setEnabled(enabled: true)
            availability = .available
            apply(settings: settings)
            try await refreshGrants(client: client, generation: generation)
        } catch {
            hostedAssistantLogger.error("Asistan erişimi açılamadı, hata: \(String(describing: error), privacy: .private)")
            actionError = hostedAssistantMessage(error: error)
            return
        }
        schedulePass(delaySeconds: 0)
    }

    /// Ayarlar'daki anahtar kapatıldı (satır içinde onaylandıktan sonra): kopya sunucuda hemen silinir, bütün
    /// asistanların bağlantısı kesilir, hesabın her cihazında durur. Sunucuya ulaşılamazsa hiçbir şey değişmez.
    func turnOff() async {
        guard let scope, !isChanging, !isDemo else {
            return
        }
        isChanging = true
        defer { isChanging = false }
        actionError = nil
        // Bu hesabın yükleyicisi: beklerken hesap değişirse yenisininki silinmesin.
        let accountUploader: AssistantUploader? = uploader
        let stamp: HostedScopeStamp = HostedScopeStamp(generation: await holdPasses(), accountKey: scope.accountKey, userID: scope.userID)
        // İstek oturumdaki hesapla gider: beklerken hesap değiştiyse ya da oturum bittiyse başka hesabın erişimi kapanırdı.
        guard isActionCurrent(stamp: stamp) else {
            hostedAssistantLogger.info("Asistan erişimini kapatırken hesap değişti; istek gönderilmedi")
            releaseIfStillHeld(stamp: stamp)
            return
        }
        let settings: HostedAssistantSettings
        do {
            settings = try await makeClient().setEnabled(enabled: false)
        } catch {
            hostedAssistantLogger.error("Asistan erişimi kapatılamadı, hata: \(String(describing: error), privacy: .private)")
            guard isActionCurrent(stamp: stamp) else {
                releaseIfStillHeld(stamp: stamp)
                return
            }
            actionError = hostedAssistantMessage(error: error)
            send(event: .release)
            if isOn {
                schedulePass(delaySeconds: 0)
            }
            return
        }
        guard isActionCurrent(stamp: stamp) else {
            // Sunucuda kapandı ama hesap bu arada değişti: yalnızca o hesabın kaydı ve defteri güncellenir.
            await forgetAfterTurnOff(accountKey: stamp.accountKey, uploader: accountUploader)
            releaseIfStillHeld(stamp: stamp)
            return
        }
        apply(settings: settings)
        do {
            try await accountUploader?.forgetUploads()
        } catch {
            hostedAssistantLogger.error("Asistan defteri silinemedi, hata: \(String(describing: error), privacy: .private)")
            actionError = hostedAssistantMessage(error: error)
        }
        send(event: .release)
        hostedAssistantLogger.info("Asistan erişimi kapatıldı, kopya silindi")
    }

    /// Erişim sunucuda kapandı ama hesap istek sürerken değişti: o hesabın ayarı kapalı yazılır ve yükleme defteri
    /// silinir (ekrandaki yeni hesabın durumuna dokunulmaz).
    private func forgetAfterTurnOff(accountKey: String, uploader accountUploader: AssistantUploader?) async {
        hostedAssistantLogger.info("Asistan erişimi kapatıldı; hesap bu arada değiştiği için ekran güncellenmedi")
        do {
            try hostedAccountDefaults(accountKey: accountKey).set(false, forKey: HostedAssistantDefaultsKey.enabled)
            try await accountUploader?.forgetUploads()
        } catch {
            hostedAssistantLogger.error("Kapatılan asistan erişiminin yerel kaydı silinemedi, hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Bırakılan eylemin tuttuğu geçişleri serbest bırakır: kuşak değiştiyse (hesap değişti, geçişler zaten sıfırlandı)
    /// bir şey yapmaz; yalnızca oturum değiştiyse geçişler tutulu kalmasın.
    private func releaseIfStillHeld(stamp: HostedScopeStamp) {
        if stamp.generation == generation {
            send(event: .release)
        }
    }

    /// Bekleyen bir hesap eylemi (`stamp`) hâlâ bu hesabın bu çalışmasına mı ait ve oturum hâlâ o hesapta mı (bkz.
    /// `hostedAccountActionIsCurrent`).
    private func isActionCurrent(stamp: HostedScopeStamp) -> Bool {
        hostedAccountActionIsCurrent(
            stamp: stamp, generation: generation, accountKey: scope?.accountKey, userID: scope?.userID, sessionUserID: HostedAccount.shared.signedInUserIDCache
        )
    }

    /// Bir asistanın bağlantısını keser (anında; yeniden bağlanmak için asistanda yeniden bağlanılır).
    func disconnect(grant: HostedAssistantGrant) async {
        if isDemo {
            grants.removeAll { $0.grantId == grant.grantId }
            return
        }
        guard scope != nil else {
            return
        }
        actionError = nil
        do {
            let client: HostedAssistantClient = try makeClient()
            try await client.deleteGrant(grantID: grant.grantId)
            try await refreshGrants(client: client, generation: generation)
        } catch {
            hostedAssistantLogger.error("Asistanın bağlantısı kesilemedi, hata: \(String(describing: error), privacy: .private)")
            actionError = hostedAssistantMessage(error: error)
        }
    }

    /// Bu cihazın toplantılarını kopyadan kaldırır ve bu cihazın yüklemesini durdurur (diğer cihazlarınki kalır).
    func removeThisDevice() async {
        guard let scope, !isChanging, !isDemo else {
            return
        }
        isChanging = true
        defer { isChanging = false }
        actionError = nil
        let accountUploader: AssistantUploader? = uploader
        // Yükleme sunucuda silmeden sonra bitmesin (kaldırılan toplantı geri yüklenirdi).
        let stamp: HostedScopeStamp = HostedScopeStamp(generation: await holdPasses(), accountKey: scope.accountKey, userID: scope.userID)
        // İstek oturumdaki hesapla gider: beklerken hesap değiştiyse ya da oturum bittiyse başka hesabın cihazı kaldırılırdı.
        guard isActionCurrent(stamp: stamp) else {
            hostedAssistantLogger.info("Bu cihazı kopyadan kaldırırken hesap değişti; istek gönderilmedi")
            releaseIfStillHeld(stamp: stamp)
            return
        }
        do {
            let defaults: UserDefaults = try hostedAccountDefaults(accountKey: scope.accountKey)
            _ = try await makeClient().deleteDevice(deviceID: try deviceID(defaults: defaults))
            // Sunucuda kaldırıldı: hesap bu arada değişse de o hesabın defteri ve kaydı güncellenir.
            try await accountUploader?.forgetUploads()
            defaults.set(true, forKey: HostedAssistantDefaultsKey.deviceExcluded)
        } catch {
            hostedAssistantLogger.error("Bu cihazın toplantıları kopyadan kaldırılamadı, hata: \(String(describing: error), privacy: .private)")
            guard isActionCurrent(stamp: stamp) else {
                releaseIfStillHeld(stamp: stamp)
                return
            }
            actionError = hostedAssistantMessage(error: error)
            send(event: .release)
            schedulePass(delaySeconds: 0)
            return
        }
        guard isActionCurrent(stamp: stamp) else {
            hostedAssistantLogger.info("Bu cihaz kopyadan kaldırıldı; hesap bu arada değiştiği için ekran güncellenmedi")
            releaseIfStillHeld(stamp: stamp)
            return
        }
        isDeviceExcluded = true
        send(event: .release)
        progress = nil
        uploadStatus = .idle
        await refresh()
    }

    /// Bu cihazın toplantılarını yeniden kopyaya ekler.
    func includeThisDevice() {
        guard let scope, !isDemo else {
            return
        }
        do {
            try hostedAccountDefaults(accountKey: scope.accountKey).set(false, forKey: HostedAssistantDefaultsKey.deviceExcluded)
        } catch {
            actionError = userFacingMessage(error: error)
            return
        }
        isDeviceExcluded = false
        schedulePass(delaySeconds: 0)
    }

    /// Şimdi yeniden dener (Ayarlar'daki "Yeniden dene").
    func retryNow() {
        consecutiveFailures = 0
        schedulePass(delaySeconds: 0)
    }

    /// Sunucunun kabul etmediği toplantıları şimdi yeniden dener (Ayarlar'daki "Yeniden dene"; toplantı değişince
    /// zaten kendiliğinden denenir).
    func retryRejected() async {
        if isDemo {
            if let progress {
                self.progress = AssistantUploadProgress(uploaded: progress.uploaded + progress.rejected, rejected: 0, rejectionReason: nil, total: progress.total)
            }
            return
        }
        guard let uploader, scope != nil else {
            return
        }
        actionError = nil
        do {
            try await uploader.retryRejected()
        } catch {
            hostedAssistantLogger.error("Kabul edilmeyen toplantılar yeniden denenemedi, hata: \(String(describing: error), privacy: .private)")
            actionError = userFacingMessage(error: error)
            return
        }
        consecutiveFailures = 0
        schedulePass(delaySeconds: 0)
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: Yerel değişiklikler

    /// Toplantı listesi değişti (işleme bitti, düzenleme, silme): kısa bir beklemeden sonra kopya eşlenir. Liste
    /// diskten okunmadan çağrılmamalı (boş liste her şeyi silerdi). Başka cihazda kaydedilip eşitlemeyle gelen
    /// toplantıları o cihaz yükler (`recordedElsewhere`).
    func observe(meetings newMeetings: [MeetingRecord], recordedElsewhere: Set<String>, userName newUserName: String) {
        guard scope != nil else {
            return
        }
        let own: [MeetingRecord] = newMeetings.filter { !recordedElsewhere.contains($0.id) }
        let changed: Bool = meetings != own || userName != newUserName
        meetings = own
        userName = newUserName
        if changed {
            schedulePass(delaySeconds: hostedAssistantDebounceSeconds)
        }
    }

    // MARK: Geçiş

    private func apply(settings: HostedAssistantSettings) {
        let wasOn: Bool = isOn
        isOn = settings.enabled
        copyMeetings = settings.meetings
        maxMeetings = settings.maxMeetings
        if let scope {
            do {
                try hostedAccountDefaults(accountKey: scope.accountKey).set(settings.enabled, forKey: HostedAssistantDefaultsKey.enabled)
            } catch {
                hostedAssistantLogger.error("Asistan ayarı yazılamadı, hata: \(String(describing: error), privacy: .private)")
            }
        }
        if settings.enabled {
            startPeriodic()
        } else {
            stopPeriodic()
            cancelPasses()
            grants = []
            progress = nil
            uploadStatus = .idle
            if wasOn, !isChanging {
                notice = String(localized: "Yapay zekâ asistanı erişimi başka bir cihazda kapatıldı; kopya silindi.")
            }
        }
    }

    /// Bağlantıları okur; bilinenlerde olmayan her yeni bağlantı bir kez bildirilir.
    private func refreshGrants(client: HostedAssistantClient, generation current: Int) async throws {
        guard let scope else {
            return
        }
        let listed: [HostedAssistantGrant] = try await client.grants()
        guard current == generation else {
            return
        }
        grants = listed
        let defaults: UserDefaults = try hostedAccountDefaults(accountKey: scope.accountKey)
        let known: Set<String>? = defaults.stringArray(forKey: HostedAssistantDefaultsKey.knownGrantIDs).map(Set.init)
        for grant in newAssistantGrants(known: known, current: listed) {
            let name: String = assistantGrantDisplayName(grant: grant)
            notice = String(localized: "\(name) artık toplantılarını okuyabilir.")
            hooks?.announceConnection(name)
        }
        defaults.set(listed.map(\.grantId), forKey: HostedAssistantDefaultsKey.knownGrantIDs)
    }

    /// Bir geçiş ister (0 saniye: hemen); özellik kapalıysa, bu cihaz kaldırıldıysa ya da toplantılar okunmadıysa bir şey
    /// yapmaz.
    private func schedulePass(delaySeconds: Double) {
        guard isOn, !isDeviceExcluded, meetings != nil, !isDemo else {
            return
        }
        send(event: .requested(delaySeconds: delaySeconds))
    }

    /// Zamanlamaya bir olay verir ve geçiş fonksiyonunun istediği yan etkiyi yapar.
    private func send(event: AssistantPassEvent) {
        let step: AssistantPassStep = assistantPassStep(phase: passPhase, event: event)
        passPhase = step.phase
        switch step.effect {
        case .none:
            break
        case .startTimer(let seconds):
            startTimer(seconds: seconds)
        case .startPass:
            timerTask?.cancel()
            timerTask = nil
            startPass()
        case .cancelWork:
            timerTask?.cancel()
            timerTask = nil
            passTask?.cancel()
            passTask = nil
        }
    }

    private func startTimer(seconds: Double) {
        timerTask?.cancel()
        let current: Int = generation
        timerTask = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard current == self.generation else {
                return
            }
            self.timerTask = nil
            self.send(event: .timerFired)
        }
    }

    private func startPass() {
        guard let uploader, let meetings, isOn, !isDeviceExcluded else {
            send(event: .passStopped)
            return
        }
        let current: Int = generation
        let name: String = userName
        uploadStatus = .uploading
        passTask = Task {
            let result: Result<AssistantPassReport, any Error>
            do {
                result = .success(try await uploader.pass(records: meetings, userName: name) { (progress: AssistantUploadProgress) -> Void in
                    Task { @MainActor in
                        if current == HostedAssistantCenter.shared.generation {
                            HostedAssistantCenter.shared.progress = progress
                        }
                    }
                })
            } catch {
                result = .failure(error)
            }
            guard current == self.generation else {
                return
            }
            self.passTask = nil
            self.handle(result: result)
        }
    }

    private func handle(result: Result<AssistantPassReport, any Error>) {
        switch result {
        case .success(let report):
            consecutiveFailures = 0
            uploadStatus = .idle
            progress = report.progress
            // Kapalı bildirildiyse `apply` işi sıfırlar; o zaman aşağıdaki olay geç gelmiş sayılır.
            apply(settings: report.settings)
            if report.rejected > 0 {
                hostedAssistantLogger.warning("Asistan kopyası bazı toplantıları kabul etmedi, sayı: \(report.rejected, privacy: .public)")
            }
            send(event: .passSucceeded)
        case .failure(HostedAssistantError.unavailable):
            availability = .unavailable
            uploadStatus = .idle
            stopPeriodic()
            send(event: .passStopped)
        case .failure(let error) where error is CancellationError || error as? AssistantUploaderError == .ledgerForgotten:
            uploadStatus = .idle
            send(event: .passStopped)
        case .failure(let error):
            hostedAssistantLogger.warning("Asistan kopyası yüklenemedi, yeniden denenecek, hata: \(String(describing: error), privacy: .private)")
            consecutiveFailures += 1
            let delay: Double = syncRetryDelaySeconds(failures: consecutiveFailures)
            uploadStatus = .failed(message: hostedAssistantMessage(error: error), retryAt: Date().addingTimeInterval(delay))
            send(event: .passFailed(retryDelaySeconds: delay))
        }
    }

    /// Dönemsel yenilemeyi başlatır (sürüyorsa bir şey yapmaz). Döngü yalnızca `stopPeriodic` ile biter: geçişlerin
    /// iptali (kapatma denemesi, "bu cihazı kaldır") onu öldürmez.
    private func startPeriodic() {
        guard periodicTask == nil, !isDemo else {
            return
        }
        periodicTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(hostedAssistantRefreshSeconds))
                } catch {
                    return
                }
                await self.refresh()
            }
        }
    }

    private func stopPeriodic() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    /// Süren ve bekleyen geçişleri durdurur (defter diskte kalır).
    private func cancelPasses() {
        generation += 1
        send(event: .reset)
        consecutiveFailures = 0
    }

    /// Kopyayı değiştiren eylemden önce: süren ve bekleyen geçişler durur, süren geçişin bitmesi beklenir ve eylem
    /// `send(event: .release)` diyene dek yeni geçiş başlamaz. Böylece eylemin sunucu isteği (kapatma, cihazı kaldırma)
    /// hiçbir yüklemeyle iç içe geçmez ve geçiş defteri geri yazamaz (`AssistantUploaderError.ledgerForgotten`).
    /// Beklemeden önce verdiği kuşağı döndürür: eylem beklemeden sonra onunla hesabın değişmediğini denetler.
    private func holdPasses() async -> Int {
        let running: Task<Void, Never>? = passTask
        generation += 1
        let held: Int = generation
        send(event: .hold)
        consecutiveFailures = 0
        await running?.value
        return held
    }

    private func stop() {
        cancelPasses()
        stopPeriodic()
        uploader = nil
    }

    /// Hesap silindi: sunucudaki kopya hesapla birlikte silindi; bu cihazdaki defter de gider.
    func forgetAfterAccountDeletion(userID: String) {
        let accountKey: String = accountDataKey(userId: userID)
        if scope?.accountKey == accountKey {
            stop()
            isOn = false
        }
        do {
            let ledger: URL = AppPaths.accountAssistantLedger(dataRoot: try AppPaths.applicationSupport(), accountKey: accountKey)
            if FileManager.default.fileExists(atPath: ledger.path) {
                try FileManager.default.removeItem(at: ledger)
            }
        } catch {
            hostedAssistantLogger.error("Silinen hesabın asistan defteri silinemedi, hata: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: Tanıtım

    /// Tanıtım modu (ekran görüntüleri): özellik açık, iki bağlı asistan, yükleme sürüyor; sunucuya gidilmez.
    func showForDemo(now: Date) {
        isDemo = true
        availability = .available
        isOn = true
        copyMeetings = 128
        maxMeetings = 5000
        progress = AssistantUploadProgress(uploaded: 96, rejected: 0, rejectionReason: nil, total: 128)
        uploadStatus = .uploading
        grants = [
            HostedAssistantGrant(
                grantId: "demo-claude", clientName: "Claude", redirectHost: "claude.ai", verified: true, createdAt: now.addingTimeInterval(-9 * 86_400),
                lastUsedAt: now.addingTimeInterval(-3_600), heavyReadAt: nil
            ),
            HostedAssistantGrant(
                grantId: "demo-chatgpt", clientName: "ChatGPT", redirectHost: "chatgpt.com", verified: true, createdAt: now.addingTimeInterval(-2 * 86_400),
                lastUsedAt: nil, heavyReadAt: nil
            ),
        ]
        notice = String(localized: "\("ChatGPT") artık toplantılarını okuyabilir.")
    }

    /// Tanıtım modu, yükleme bitmiş ve sunucunun kabul etmediği toplantılarla (görsel kontrol: `--reddedilen`).
    func showRefusedForDemo(now: Date) {
        showForDemo(now: now)
        notice = nil
        progress = AssistantUploadProgress(uploaded: 125, rejected: 3, rejectionReason: .tooLarge, total: 128)
        uploadStatus = .idle
    }

    // MARK: Yardımcılar

    private func makeClient() throws -> HostedAssistantClient {
        HostedAssistantClient(baseURL: try HostedServices.requireClient().baseURL, credentials: try HostedServices.requireClient())
    }

    /// Bu cihazın bu hesaptaki yükleyen kimliği (UUID); ilk kullanımda üretilir.
    private func deviceID(defaults: UserDefaults) throws -> String {
        if let existing = defaults.string(forKey: HostedAssistantDefaultsKey.deviceID) {
            return existing
        }
        let created: String = UUID().uuidString.lowercased()
        defaults.set(created, forKey: HostedAssistantDefaultsKey.deviceID)
        return created
    }
}

/// Asistan erişimi hatasının kullanıcı metni.
func hostedAssistantMessage(error: any Error) -> String {
    switch error {
    case HostedAssistantError.unavailable:
        return String(localized: "Yapay zekâ asistanı erişimi şu an kullanılamıyor; biraz sonra yeniden dene.")
    case HostedAssistantError.notEnabled, HostedAssistantError.epochMismatch:
        return String(localized: "Yapay zekâ asistanı erişimi başka bir cihazda değişti; yeniden denenecek.")
    case HostedAssistantError.quotaExceeded:
        return String(localized: "Asistan kopyasının yeri doldu; eski toplantıları silerek yer açabilirsin.")
    case HostedAssistantError.copyTooLarge:
        return String(localized: "Bir toplantının notu asistan kopyası için çok büyük; o toplantı atlandı.")
    case let apiError as HostedAPIError where apiError.code == .subscriptionRequired:
        return String(localized: "Yapay zekâ asistanı erişimi için etkin abonelik ya da deneme gerekir.")
    default:
        return userFacingMessage(error: error)
    }
}
