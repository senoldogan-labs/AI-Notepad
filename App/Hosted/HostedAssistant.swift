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
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// Geçiş sürerken yeni değişiklik geldi: geçiş bitince bir geçiş daha.
    @ObservationIgnored private var needsAnotherPass: Bool = false
    @ObservationIgnored private var consecutiveFailures: Int = 0
    @ObservationIgnored private var lastRefreshAt: Date?
    /// Her kurulum ve durdurmada artar: eski işin geç gelen sonucu yenisinin durumunu yazmaz.
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
        guard scope != nil, !isChanging, !isDemo else {
            return
        }
        isChanging = true
        defer { isChanging = false }
        actionError = nil
        cancelPasses()
        do {
            let settings: HostedAssistantSettings = try await makeClient().setEnabled(enabled: false)
            apply(settings: settings)
            try await uploader?.forgetUploads()
        } catch {
            hostedAssistantLogger.error("Asistan erişimi kapatılamadı, hata: \(String(describing: error), privacy: .private)")
            actionError = hostedAssistantMessage(error: error)
            if isOn {
                schedulePass(delaySeconds: 0)
            }
            return
        }
        hostedAssistantLogger.info("Asistan erişimi kapatıldı, kopya silindi")
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
        cancelPasses()
        do {
            let defaults: UserDefaults = try hostedAccountDefaults(accountKey: scope.accountKey)
            _ = try await makeClient().deleteDevice(deviceID: try deviceID(defaults: defaults))
            try await uploader?.forgetUploads()
            defaults.set(true, forKey: HostedAssistantDefaultsKey.deviceExcluded)
        } catch {
            hostedAssistantLogger.error("Bu cihazın toplantıları kopyadan kaldırılamadı, hata: \(String(describing: error), privacy: .private)")
            actionError = hostedAssistantMessage(error: error)
            schedulePass(delaySeconds: 0)
            return
        }
        isDeviceExcluded = true
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

    private func schedulePass(delaySeconds: Double) {
        guard isOn, !isDeviceExcluded, meetings != nil, !isDemo else {
            return
        }
        if passTask != nil {
            needsAnotherPass = true
            return
        }
        debounceTask?.cancel()
        let current: Int = generation
        debounceTask = Task {
            if delaySeconds > 0 {
                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    return
                }
            }
            guard current == self.generation else {
                return
            }
            self.debounceTask = nil
            self.runPass()
        }
    }

    private func runPass() {
        guard let uploader, let meetings, isOn, !isDeviceExcluded, passTask == nil else {
            return
        }
        let current: Int = generation
        let name: String = userName
        retryTask?.cancel()
        retryTask = nil
        needsAnotherPass = false
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
            apply(settings: report.settings)
            if report.rejected > 0 {
                hostedAssistantLogger.warning("Asistan kopyası bazı toplantıları kabul etmedi, sayı: \(report.rejected, privacy: .public)")
            }
            if needsAnotherPass {
                schedulePass(delaySeconds: 0)
            }
        case .failure(HostedAssistantError.unavailable):
            availability = .unavailable
            uploadStatus = .idle
            stopPeriodic()
        case .failure(let error) where error is CancellationError:
            uploadStatus = .idle
        case .failure(let error):
            hostedAssistantLogger.warning("Asistan kopyası yüklenemedi, yeniden denenecek, hata: \(String(describing: error), privacy: .private)")
            consecutiveFailures += 1
            let delay: Double = syncRetryDelaySeconds(failures: consecutiveFailures)
            uploadStatus = .failed(message: hostedAssistantMessage(error: error), retryAt: Date().addingTimeInterval(delay))
            let current: Int = generation
            retryTask = Task {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard current == self.generation else {
                    return
                }
                self.retryTask = nil
                self.schedulePass(delaySeconds: 0)
            }
        }
    }

    private func startPeriodic() {
        guard periodicTask == nil, !isDemo else {
            return
        }
        let current: Int = generation
        periodicTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(hostedAssistantRefreshSeconds))
                } catch {
                    return
                }
                guard current == self.generation else {
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
        debounceTask?.cancel()
        debounceTask = nil
        retryTask?.cancel()
        retryTask = nil
        passTask?.cancel()
        passTask = nil
        needsAnotherPass = false
        consecutiveFailures = 0
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
