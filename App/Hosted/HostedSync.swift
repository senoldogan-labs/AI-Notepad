import AINotepadCore
import Foundation
import Observation
import os

private let hostedSyncLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedSync")

// Mac ↔ iPhone eşitlemesinin uygulama tarafı (Mac'teki Gistsmith ve iPhone ortak; tasarım
// docs/superpowers/specs/2026-11-03-mac-iphone-sync-options.md §8, plan docs/superpowers/plans/2026-11-03-sync-phase1.md
// 1B). İsteğe bağlıdır (varsayılan kapalı) ve sunucunun `SYNC_POLICY` anahtarının arkasındadır: sunucu eşitlemeyi
// kapalı bildirirse Ayarlar'daki satır görünmez. Toplantı metni, not, görevler, kişiler, Sor sohbetleri, klasörler,
// tarifler ve hesapla gelen ayarlar uçtan uca şifreli eşitlenir; ses, ekran görüntüleri ve ses izleri kaydedildiği
// cihazda kalır.

/// Hesabın ayar alanındaki eşitleme anahtarları.
private enum HostedSyncDefaultsKey {
    /// Kullanıcı bu hesap için eşitlemeyi bu cihazda açtı.
    static let enabled: String = "sync.enabled"
    /// Bu cihazın rastgele eşitleme kimliği (sunucuda yükleyen cihaz olarak saklanır).
    static let deviceID: String = "sync.deviceID"
    /// Son başarılı eşitlemenin anı.
    static let lastSyncedAt: String = "sync.lastSyncedAt"
    /// Açma ya da kodla katılma henüz bitmedi: sunucu hesabın anahtarını onaylayana ve bu cihazdaki her şey kuyruğa
    /// girene dek motor çevrimdışı kurulmaz (yarıda kalan açma "başka cihazda kapatıldı" sanılmasın).
    static let setupPending: String = "sync.setupPending"
}

/// Ön planda kendiliğinden eşitleme aralığı (başka cihazdaki değişiklikler için; yerel değişiklik hemen gider).
private let hostedSyncPeriodSeconds: Double = 300

/// Uygulamanın eşitlemeye verdiği bağlantılar (hesap oturumu kurulunca bağlanır).
struct HostedSyncHooks {
    /// Uzun not işi (işleme, notu yeniden yazma, düzenleme) süren toplantılar: gelen değişiklikleri iş bitene dek bekler.
    let busyMeetingIDs: @MainActor () -> Set<String>
    /// Kayıt sürüyor: başka cihazdan gelen ayarlar kayıt bitene dek yazılmaz.
    let recordingInProgress: @MainActor () -> Bool
    /// Bir geçiş bu cihazda bir şey yazdı ya da sildi: uygulama değişenleri diskten yeniden okur.
    let applyReport: @MainActor (SyncPassReport) -> Void
}

/// Sunucunun eşitlemeyi sunup sunmadığı (`SYNC_POLICY`).
enum HostedSyncAvailability: Equatable {
    /// Henüz sorulmadı ya da sorulamadı (çevrimdışı).
    case unknown
    case available
    /// Sunucu eşitlemeyi kapalı bildirdi: Ayarlar'daki satır görünmez.
    case unavailable
}

/// Ayarlar'da gösterilen eşitleme durumu.
enum HostedSyncStatus: Equatable {
    /// Bu cihazda kapalı.
    case off
    /// Açılıyor ya da bir geçiş sürüyor.
    case working
    /// Başka bir cihaz eşitlemeyi açtı: o cihazdaki bağlantı kodu girilmeli.
    case needsLinkCode
    /// Son geçiş başarılı (an `lastSyncedAt`'te).
    case synced
    /// Son geçiş ya da adım başarısız; yeniden denenecek (`retryAt`) ya da kullanıcı yeniden dener.
    case failed(message: String, retryAt: Date?)
}

/// Eşitlemenin bağlanacağı hesap: yüklü hesabın veri anahtarı ve giriş yapan kullanıcı (değişince eşitleme yeniden
/// kurulur).
struct HostedSyncScopeKey: Equatable {
    let loadedAccountKey: String?
    let signedInUserID: String?
}

/// Hesabın şu anki eşitleme kapsamı.
@MainActor
func hostedSyncScopeKey(account: HostedAccount) -> HostedSyncScopeKey {
    guard case .loaded(let accountKey) = account.dataState else {
        return HostedSyncScopeKey(loadedAccountKey: nil, signedInUserID: account.signedInUserIDCache)
    }
    return HostedSyncScopeKey(loadedAccountKey: accountKey, signedInUserID: account.signedInUserIDCache)
}

/// Eşitlenen öğelerin son görülen hâli: değişen öğeler bunlarla karşılaştırılarak kuyruğa girer.
private struct HostedSyncSnapshots {
    var meetings: [String: MeetingRecord]?
    var chats: [UUID: AskConversation]?
    var people: PeopleBook?
    var prefs: SyncPrefs?

    static let empty: HostedSyncSnapshots = HostedSyncSnapshots(meetings: nil, chats: nil, people: nil, prefs: nil)
}

/// Yüklü hesabın eşitlemesi: hesabın ayarı, anahtar, motor, durum ve yeniden deneme. Tek örnek; hesap değişince ya da
/// çıkışta durur, yeni hesapla yeniden kurulur.
@MainActor
@Observable
final class HostedSyncCenter {
    static let shared: HostedSyncCenter = HostedSyncCenter()

    private(set) var availability: HostedSyncAvailability = .unknown
    private(set) var status: HostedSyncStatus = .off
    /// Kullanıcı bu hesap için eşitlemeyi bu cihazda açtı.
    private(set) var isOn: Bool = false
    /// Son başarılı eşitleme.
    private(set) var lastSyncedAt: Date?
    /// Bu cihazdaki bağlantı kodu (diğer cihaz bununla katılır); eşitleme kapalıyken nil.
    private(set) var linkCode: String?
    /// Açma, kapatma ya da kodla katılma sürüyor (düğmeler kilitlenir).
    private(set) var isChangingSetup: Bool = false
    /// Kod girişi ya da kapatmanın hatası (satırın altında gösterilir).
    private(set) var setupError: String?
    /// Kullanıcıya bir kez söylenen olay (ör. başka cihazda kapatıldı).
    private(set) var notice: String?
    /// Motor çalışıyor (hesap yerinde değişmeden önce durdurulur; bkz. `AccountDataWriter.syncing`).
    private(set) var isEngineRunning: Bool = false
    /// Başka bir cihazın kaydettiği, eşitlemeyle gelen toplantılar: sesleri ve ekran görüntüleri o cihazda kalır, bu
    /// cihazda oynatılmaz ve yeniden işlenmez.
    private(set) var meetingsRecordedElsewhere: Set<String> = []

    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var hooks: HostedSyncHooks?
    /// Eşitlemenin bağlı olduğu hesap: veri anahtarı ve kullanıcı.
    @ObservationIgnored private var scope: (accountKey: String, userID: String)?
    @ObservationIgnored private var snapshots: HostedSyncSnapshots = .empty
    /// Motor kurulmadan önce gelen yerel değişiklikler (kurulunca kuyruğa girer).
    @ObservationIgnored private var waitingItems: [SyncLocalItem] = []
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures: Int = 0
    /// Her kurulum ve durdurmada artar: eski motorun geç gelen sonucu yenisinin durumunu yazmaz.
    @ObservationIgnored private var generation: Int = 0

    private init() {}

    // MARK: Bağlantı

    /// Uygulamanın bağlantıları (hesap oturumu kurulunca; iPhone'da hesap değişince yenisiyle).
    func attach(hooks newHooks: HostedSyncHooks) {
        hooks = newHooks
    }

    /// Hesap durumu değişti: hesap verisi yüklü ve aynı hesapla giriş yapılmışsa o hesabın eşitlemesi kurulur (açıksa
    /// motor başlar), değilse durur. Aynı hesap için tekrar çağrılırsa bir şey yapmaz.
    func update(scopeKey: HostedSyncScopeKey) async {
        let next: (accountKey: String, userID: String)?
        if let loadedAccountKey = scopeKey.loadedAccountKey, let signedInUserID = scopeKey.signedInUserID, accountDataKey(userId: signedInUserID) == loadedAccountKey {
            next = (loadedAccountKey, signedInUserID)
        } else {
            next = nil
        }
        guard next?.accountKey != scope?.accountKey || next?.userID != scope?.userID else {
            return
        }
        await stopEngine()
        scope = next
        snapshots = .empty
        waitingItems = []
        setupError = nil
        notice = nil
        meetingsRecordedElsewhere = []
        guard let next else {
            isOn = false
            status = .off
            linkCode = nil
            lastSyncedAt = nil
            availability = .unknown
            return
        }
        do {
            let defaults: UserDefaults = try hostedAccountDefaults(accountKey: next.accountKey)
            isOn = defaults.bool(forKey: HostedSyncDefaultsKey.enabled)
            lastSyncedAt = defaults.object(forKey: HostedSyncDefaultsKey.lastSyncedAt) as? Date
        } catch {
            hostedSyncLogger.error("Eşitleme ayarı okunamadı, hata: \(String(describing: error), privacy: .private)")
            status = .failed(message: userFacingMessage(error: error), retryAt: nil)
            return
        }
        status = isOn ? .working : .off
        if isOn {
            await start()
        } else {
            await refreshAvailability()
        }
    }

    /// Sunucunun eşitlemeyi sunup sunmadığını sorar (Ayarlar açılınca da); sorulamazsa durum bilinmiyor kalır.
    func refreshAvailability() async {
        guard scope != nil else {
            return
        }
        do {
            _ = try await makeClient().account()
            availability = .available
        } catch HostedSyncError.unavailable {
            availability = .unavailable
        } catch {
            hostedSyncLogger.warning("Eşitlemenin durumu sorulamadı, hata: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: Kullanıcı eylemleri

    /// Ayarlar'daki anahtar açıldı: hesap için eşitleme açılır (ilk cihazsa yeni anahtar ve bağlantı kodu üretilir) ya da
    /// başka cihaz açtıysa onun kodu istenir. Bu cihazdaki her şey kuyruğa girer.
    func turnOn() async {
        guard let scope, !isChangingSetup else {
            return
        }
        isChangingSetup = true
        defer { isChangingSetup = false }
        setupError = nil
        notice = nil
        do {
            let defaults: UserDefaults = try hostedAccountDefaults(accountKey: scope.accountKey)
            defaults.set(true, forKey: HostedSyncDefaultsKey.enabled)
            defaults.set(true, forKey: HostedSyncDefaultsKey.setupPending)
        } catch {
            setupError = userFacingMessage(error: error)
            return
        }
        isOn = true
        status = .working
        await start()
    }

    /// Başka cihazda gösterilen bağlantı koduyla katılır; kod doğruysa eşitleme başlar ve true döner.
    func join(codeText: String) async -> Bool {
        guard let scope, !isChangingSetup else {
            return false
        }
        isChangingSetup = true
        defer { isChangingSetup = false }
        setupError = nil
        do {
            let client: HostedSyncClient = try makeClient()
            _ = try await joinSync(client: client, keyStore: try keyStore(accountKey: scope.accountKey), userID: scope.userID, codeText: codeText)
            try hostedAccountDefaults(accountKey: scope.accountKey).set(true, forKey: HostedSyncDefaultsKey.setupPending)
        } catch {
            hostedSyncLogger.warning("Bağlantı koduyla katılınamadı, hata: \(String(describing: error), privacy: .private)")
            setupError = hostedSyncMessage(error: error)
            return false
        }
        status = .working
        await start()
        return true
    }

    /// Ayarlar'daki anahtar kapatıldı: sunucudaki şifreli kopya silinir, hesabın bütün cihazlarında eşitleme durur;
    /// cihazlardaki toplantılar yerinde kalır. Sunucuya ulaşılamazsa hiçbir şey değişmez ve neden gösterilir.
    func turnOff() async {
        guard let scope, !isChangingSetup else {
            return
        }
        isChangingSetup = true
        defer { isChangingSetup = false }
        setupError = nil
        await stopEngine()
        do {
            try await stopSync(client: try makeClient(), keyStore: try keyStore(accountKey: scope.accountKey), metadataDirectory: try metadataDirectory(accountKey: scope.accountKey))
        } catch {
            hostedSyncLogger.error("Eşitleme kapatılamadı, hata: \(String(describing: error), privacy: .private)")
            setupError = hostedSyncMessage(error: error)
            // Kapatılamadı: eşitleme açık kalır ve sürer.
            if isOn {
                await start()
            }
            return
        }
        markOff(accountKey: scope.accountKey)
        hostedSyncLogger.info("Eşitleme kapatıldı, sunucudaki kopya silindi")
    }

    /// Bağlantı kodu girilmesi beklenirken eşitlemeyi bu cihazda vazgeçerek kapatır (sunucuya dokunulmaz).
    func cancelJoin() {
        guard let scope, status == .needsLinkCode else {
            return
        }
        markOff(accountKey: scope.accountKey)
    }

    /// Şimdi eşitler (Ayarlar'daki "Şimdi eşitle", uygulama öne gelince, dönemsel); açık değilse bir şey yapmaz.
    func syncNow() {
        guard let engine, isOn else {
            return
        }
        let current: Int = generation
        retryTask?.cancel()
        retryTask = nil
        status = .working
        Task {
            do {
                _ = try await engine.syncNow()
            } catch {
                // Geçişin sonucu motorun gözlemcisine gider (`handle(result:)`): durum ve yeniden deneme orada.
                hostedSyncLogger.debug("Eşitleme geçişi başarısız, nesil: \(current, privacy: .public)")
            }
        }
    }

    /// Uygulama öne geldi: son eşitlemeden bu yana en az bir dakika geçtiyse eşitler (Mac'te pencereler arasında gidip
    /// gelmek her seferinde sunucuya gitmesin).
    func appBecameActive() {
        if let lastSyncedAt, Date().timeIntervalSince(lastSyncedAt) < 60 {
            return
        }
        syncNow()
    }

    /// Bir kez gösterilen bildirimi kapatır.
    func dismissNotice() {
        notice = nil
    }

    // MARK: Yerel değişiklikler

    /// Toplantı listesi değişti (okuma, kayıt, düzenleme, silme): önceki hâline göre değişen toplantılar kuyruğa girer.
    /// İlk liste yalnız taban olur (açılışta her toplantı yeniden denetlenmesin).
    func observe(meetings: [MeetingRecord]) {
        guard scope != nil else {
            return
        }
        let current: [String: MeetingRecord] = Dictionary(meetings.map { ($0.id, $0) }) { (first: MeetingRecord, _: MeetingRecord) -> MeetingRecord in first }
        defer { snapshots.meetings = current }
        guard let previous = snapshots.meetings else {
            return
        }
        note(items: changedSyncIDs(old: previous, new: current).sorted().map { SyncLocalItem.meeting(id: $0) })
    }

    /// Sor sohbetleri değişti.
    func observe(chats: [AskConversation]) {
        guard scope != nil else {
            return
        }
        let current: [UUID: AskConversation] = Dictionary(chats.map { ($0.id, $0) }) { (first: AskConversation, _: AskConversation) -> AskConversation in first }
        defer { snapshots.chats = current }
        guard let previous = snapshots.chats else {
            return
        }
        note(items: changedSyncIDs(old: previous, new: current).sorted { $0.uuidString < $1.uuidString }.map { SyncLocalItem.askChat(id: $0) })
    }

    /// Kişiler defteri değişti.
    func observe(people: PeopleBook) {
        guard scope != nil else {
            return
        }
        defer { snapshots.people = people }
        guard let previous = snapshots.people, previous != people else {
            return
        }
        note(items: [.people])
    }

    /// Klasörler, Sor tarifleri ya da hesapla gelen ayarlar değişmiş olabilir (ayar değişince, tarif kaydedilince):
    /// diskteki hâli öncekinden farklıysa kuyruğa girer.
    func observePrefs() {
        guard let scope else {
            return
        }
        let prefs: SyncPrefs
        do {
            prefs = try currentSyncPrefs(accountKey: scope.accountKey)
        } catch {
            hostedSyncLogger.error("Eşitlenen tercihler okunamadı, hata: \(String(describing: error), privacy: .private)")
            return
        }
        defer { snapshots.prefs = prefs }
        guard let previous = snapshots.prefs, previous != prefs else {
            return
        }
        note(items: [.prefs])
    }

    private func note(items: [SyncLocalItem]) {
        guard isOn, !items.isEmpty else {
            return
        }
        guard let engine else {
            waitingItems.append(contentsOf: items)
            return
        }
        let current: Int = generation
        let accountKey: String? = scope?.accountKey
        Task {
            for (index, item) in items.enumerated() {
                do {
                    try await engine.noteLocalChange(item: item)
                } catch SyncEngineError.stopped {
                    self.renote(items: Array(items[index...]), accountKey: accountKey)
                    return
                } catch {
                    // Kuyruk diske yazılamadı: değişiklik kaybolmasın diye sonraki geçişte her şey denetlenir.
                    hostedSyncLogger.error("Eşitleme kuyruğu yazılamadı, hata: \(String(describing: error), privacy: .private)")
                    if current == self.generation {
                        self.fail(error: error)
                    }
                    return
                }
            }
        }
    }

    /// Durdurulan bir motorun almadığı değişiklikler: aynı hesabın eşitlemesi sürüyorsa yeni motora (kurulana dek
    /// bekleyenlere) gider; durdurulan motor kuyruğa yazmaz, yoksa yeni motorun kuyruk dosyasını eski hâliyle ezerdi.
    private func renote(items: [SyncLocalItem], accountKey: String?) {
        guard accountKey != nil, scope?.accountKey == accountKey else {
            hostedSyncLogger.warning("Eşitleme hesabı değişti, önceki hesabın değişiklikleri kuyruğa girmedi, sayı: \(items.count, privacy: .public)")
            return
        }
        note(items: items)
    }

    // MARK: Motor

    /// Anahtarı hazırlar ve motoru kurar, ardından ilk geçiş ve dönemsel eşitleme başlar. Kurulum bitmişse ve anahtar bu
    /// cihazda kayıtlıysa motor ağ beklemeden kurulur: çevrimdışıyken yapılan değişiklikler de diskteki kuyruğa yazılır;
    /// anahtarın hâlâ hesabın anahtarı olduğunu ilk geçiş denetler (`needsLinkCode`, `turnedOffElsewhere`). Açma ya da
    /// kodla katılma bitmediyse (`setupPending`) önce sunucuya sorulur (çevrimdışıysa artan beklemeyle yeniden denenir),
    /// sonra bu cihazdaki her şey kuyruğa girer.
    private func start() async {
        guard let scope else {
            return
        }
        generation += 1
        let current: Int = generation
        status = .working
        let setupPending: Bool
        let stored: SyncDeviceKey?
        do {
            setupPending = try hostedAccountDefaults(accountKey: scope.accountKey).bool(forKey: HostedSyncDefaultsKey.setupPending)
            stored = try keyStore(accountKey: scope.accountKey).load()
        } catch {
            hostedSyncLogger.error("Eşitleme anahtarı okunamadı, hata: \(String(describing: error), privacy: .private)")
            fail(error: error)
            return
        }
        if !setupPending, let stored {
            do {
                try run(client: try makeClient(), key: stored, scope: scope, queueEverything: false, generation: current)
            } catch {
                hostedSyncLogger.error("Eşitleme motoru kurulamadı, hata: \(String(describing: error), privacy: .private)")
                fail(error: error)
            }
            return
        }
        let outcome: SyncStartOutcome
        let client: HostedSyncClient
        do {
            client = try makeClient()
            outcome = try await startSync(client: client, keyStore: try keyStore(accountKey: scope.accountKey), userID: scope.userID)
        } catch {
            guard current == generation else {
                return
            }
            hostedSyncLogger.warning("Eşitleme başlatılamadı, hata: \(String(describing: error), privacy: .private)")
            // Kurulum yarıda: hesabın durumu sunucudan öğrenilene dek "başka cihazda kapatıldı" ya da "kod gerekli"
            // sayılmaz, artan beklemeyle yeniden denenir.
            scheduleRetry(message: hostedSyncMessage(error: error))
            return
        }
        guard current == generation, self.scope?.accountKey == scope.accountKey else {
            return
        }
        availability = .available
        switch outcome {
        case .needsLinkCode:
            status = .needsLinkCode
            linkCode = nil
        case .ready(let key, _):
            do {
                // Kurulum bu geçişte biter: bu cihazdaki her şey kuyruğa girer (sunucudakilerle karşılaştırılır).
                try run(client: client, key: key, scope: scope, queueEverything: true, generation: current)
            } catch {
                hostedSyncLogger.error("Eşitleme motoru kurulamadı, hata: \(String(describing: error), privacy: .private)")
                fail(error: error)
            }
        }
    }

    /// Motoru kurar, bekleyen değişiklikleri (ve `queueEverything` ise bu cihazdaki her şeyi) kuyruğa yazar, ilk geçişi
    /// ve dönemsel eşitlemeyi başlatır. Kuyruğa yazma motorun kendi sırasında, geçişten önce yapılır.
    private func run(client: HostedSyncClient, key: SyncDeviceKey, scope: (accountKey: String, userID: String), queueEverything: Bool, generation current: Int) throws {
        let engine: SyncEngine = try makeEngine(client: client, key: key, scope: scope, generation: current)
        self.engine = engine
        isEngineRunning = true
        linkCode = key.code
        let waiting: [SyncLocalItem] = waitingItems
        waitingItems = []
        status = .working
        refreshMeetingsRecordedElsewhere(generation: current)
        Task {
            do {
                if queueEverything {
                    try await engine.queueEverything()
                    try hostedAccountDefaults(accountKey: scope.accountKey).set(false, forKey: HostedSyncDefaultsKey.setupPending)
                }
                for item in waiting {
                    try await engine.noteLocalChange(item: item)
                }
            } catch SyncEngineError.stopped {
                // Motor kurulur kurulmaz durduruldu: bekleyenler süren motora gider; tam denetim (`setupPending`) bir
                // sonraki kurulumda yeniden yapılır.
                self.renote(items: waiting, accountKey: scope.accountKey)
                return
            } catch {
                hostedSyncLogger.error("Eşitleme kuyruğu yazılamadı, hata: \(String(describing: error), privacy: .private)")
                if current == self.generation {
                    self.fail(error: error)
                }
                return
            }
            do {
                _ = try await engine.syncNow()
            } catch {
                // Geçişin sonucu motorun gözlemcisine gider (`handle(result:)`): durum ve yeniden deneme orada.
            }
        }
        startPeriodic()
    }

    private func makeEngine(client: HostedSyncClient, key: SyncDeviceKey, scope: (accountKey: String, userID: String), generation current: Int) throws -> SyncEngine {
        let dataRoot: URL = try AppPaths.applicationSupport()
        let domains: SyncedSettingsDomains = try hostedSyncedSettingsDomains(accountKey: scope.accountKey)
        let store: SyncAccountFolderStore = SyncAccountFolderStore(
            accountDirectory: AppPaths.accountDataDirectory(dataRoot: dataRoot, accountKey: scope.accountKey), defaultsSuite: domains.accountSuite,
            valuesDomain: domains.valuesDomain,
            busy: { () async -> Set<String> in await MainActor.run { HostedSyncCenter.shared.busyMeetingIDs() } },
            recordingInProgress: { () -> Bool in HostedSyncCenter.shared.recordingInProgress() },
            now: { () -> Date in Date() }
        )
        let settings: SyncEngineSettings = SyncEngineSettings(
            debounceSeconds: 2, maxConflictRounds: 5, pageSize: 500, conflictReason: String(localized: "Başka bir cihazda değiştirildi"),
            myNotesSeparator: String(localized: "— Diğer cihazdaki sürüm —")
        )
        return try SyncEngine(
            client: client, store: store, accountKey: key.accountKey, userID: scope.userID,
            files: SyncMetadataFiles(directory: AppPaths.accountSyncDirectory(dataRoot: dataRoot, accountKey: scope.accountKey)), clock: SystemSyncClock(),
            settings: settings
        ) { (result: Result<SyncPassReport, any Error>) -> Void in
            Task { @MainActor in
                HostedSyncCenter.shared.handle(result: result, generation: current)
            }
        }
    }

    private func busyMeetingIDs() -> Set<String> {
        hooks?.busyMeetingIDs() ?? []
    }

    private func recordingInProgress() -> Bool {
        hooks?.recordingInProgress() ?? false
    }

    /// Bir geçişin sonucu (motorun gözlemcisi): durum, yeniden deneme ve uygulamanın yeniden okuması.
    private func handle(result: Result<SyncPassReport, any Error>, generation current: Int) {
        guard current == generation, isOn else {
            return
        }
        switch result {
        case .success(let report):
            hooks?.applyReport(report)
            refreshMeetingsRecordedElsewhere(generation: current)
            if report.failures.isEmpty {
                consecutiveFailures = 0
                retryTask?.cancel()
                retryTask = nil
                let now: Date = Date()
                lastSyncedAt = now
                if let scope {
                    do {
                        try hostedAccountDefaults(accountKey: scope.accountKey).set(now, forKey: HostedSyncDefaultsKey.lastSyncedAt)
                    } catch {
                        hostedSyncLogger.error("Son eşitleme anı kaydedilemedi, hata: \(String(describing: error), privacy: .private)")
                    }
                }
                status = .synced
                recordFeatureUsage(feature: .sync)
            } else {
                // Öğeler sonraki geçişte yeniden denenir; hiçbiri atılmaz.
                hostedSyncLogger.warning("Eşitlemede bazı öğeler yeniden denenecek, sayı: \(report.failures.count, privacy: .public)")
                scheduleRetry(message: String(localized: "\(report.failures.count) öğe eşitlenemedi; yeniden denenecek."))
            }
        case .failure(let error):
            fail(error: error)
        }
    }

    /// Hatanın türüne göre: yeniden deneme (artan beklemeyle), kod isteme ya da başka cihazda kapatılınca bu cihazda
    /// bırakma. Hiçbir yerel veri silinmez. Motor durdurulurken hesap değişirse (ya da eşitleme yeniden kurulursa) eski
    /// hesabın sonucu yalnızca o hesabın kayıtlarına yazılır; görünen durum yenisinindir.
    private func fail(error: any Error) {
        guard let scope else {
            return
        }
        let current: Int = generation
        switch syncFailureKind(error: error) {
        case .turnedOffElsewhere:
            Task {
                guard let stopped = await stopEngineForFailure(scope: scope, generation: current) else {
                    return
                }
                persistOff(accountKey: scope.accountKey)
                guard hostedStampIsCurrent(stamp: stopped, generation: generation, accountKey: self.scope?.accountKey, userID: self.scope?.userID) else {
                    return
                }
                showOff()
                notice = String(localized: "Eşitleme başka bir cihazda kapatıldı. Bu cihazdaki toplantılar yerinde kalır.")
            }
        case .needsLinkCode:
            Task {
                guard let stopped = await stopEngineForFailure(scope: scope, generation: current),
                    hostedStampIsCurrent(stamp: stopped, generation: generation, accountKey: self.scope?.accountKey, userID: self.scope?.userID)
                else {
                    return
                }
                linkCode = nil
                status = .needsLinkCode
            }
        case .transient, .unavailable, .quotaExceeded, .subscriptionRequired, .other:
            scheduleRetry(message: hostedSyncMessage(error: error))
        }
    }

    /// Kalıcı bir hatadan sonra motoru durdurur ve bu hesabın anahtarını ile eşitleme kayıtlarını bu cihazdan siler.
    /// Hata geldikten sonra eşitleme yeniden kurulduysa, durdurulduysa ya da hesap değiştiyse bir şey yapmaz ve nil
    /// döner; yoksa durdurmanın damgasını döndürür (çağıran, beklerken bir şey değişmediyse durumu yazar).
    private func stopEngineForFailure(scope failed: (accountKey: String, userID: String), generation failedGeneration: Int) async -> HostedScopeStamp? {
        guard failedGeneration == generation, let scope, scope == failed else {
            return nil
        }
        await stopEngine()
        let stamp: HostedScopeStamp = HostedScopeStamp(generation: generation, accountKey: failed.accountKey, userID: failed.userID)
        do {
            try forgetSyncOnDevice(keyStore: try keyStore(accountKey: failed.accountKey), metadataDirectory: try metadataDirectory(accountKey: failed.accountKey))
        } catch {
            hostedSyncLogger.error("Eşitleme bu cihazda bırakılamadı, hata: \(String(describing: error), privacy: .private)")
        }
        return stamp
    }

    private func scheduleRetry(message: String) {
        consecutiveFailures += 1
        let delay: Double = syncRetryDelaySeconds(failures: consecutiveFailures)
        status = .failed(message: message, retryAt: Date().addingTimeInterval(delay))
        retryTask?.cancel()
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
            if self.engine == nil {
                await self.start()
            } else {
                self.syncNow()
            }
        }
    }

    private func startPeriodic() {
        periodicTask?.cancel()
        let current: Int = generation
        periodicTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(hostedSyncPeriodSeconds))
                } catch {
                    return
                }
                guard current == self.generation else {
                    return
                }
                if self.retryTask == nil {
                    self.syncNow()
                }
            }
        }
    }

    /// Motoru durdurur (süren geçiş biter); bekleyen iş diskte kalır, sonraki açılışta sürer.
    private func stopEngine() async {
        generation += 1
        periodicTask?.cancel()
        periodicTask = nil
        retryTask?.cancel()
        retryTask = nil
        consecutiveFailures = 0
        if let engine {
            self.engine = nil
            await engine.stop()
        }
        isEngineRunning = false
    }

    /// Eşitlemeyi bu hesapta bu cihaz için kapalı yazar ve kapalı gösterir.
    private func markOff(accountKey: String) {
        persistOff(accountKey: accountKey)
        showOff()
    }

    /// Eşitlemeyi bu hesabın kayıtlarında bu cihaz için kapalı yazar (görünen duruma dokunmaz).
    private func persistOff(accountKey: String) {
        do {
            let defaults: UserDefaults = try hostedAccountDefaults(accountKey: accountKey)
            defaults.set(false, forKey: HostedSyncDefaultsKey.enabled)
            defaults.removeObject(forKey: HostedSyncDefaultsKey.setupPending)
            defaults.removeObject(forKey: HostedSyncDefaultsKey.lastSyncedAt)
        } catch {
            hostedSyncLogger.error("Eşitleme ayarı yazılamadı, hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Eşitlemeyi kapalı gösterir.
    private func showOff() {
        isOn = false
        status = .off
        linkCode = nil
        lastSyncedAt = nil
        meetingsRecordedElsewhere = []
    }

    /// Başka cihazın kaydettiği toplantıları motorun defterinden yeniden okur (geçişten ve motor kurulunca).
    private func refreshMeetingsRecordedElsewhere(generation current: Int) {
        guard let engine else {
            return
        }
        Task {
            do {
                let ids: Set<String> = try await engine.meetingsRecordedElsewhere()
                guard current == self.generation else {
                    return
                }
                self.meetingsRecordedElsewhere = ids
            } catch {
                hostedSyncLogger.error("Başka cihazda kaydedilen toplantılar okunamadı, hata: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Hesap silindi: sunucudaki kopya hesapla birlikte silindi; bu cihazdaki anahtar ve kayıtlar da gider.
    func forgetAfterAccountDeletion(userID: String) async {
        let accountKey: String = accountDataKey(userId: userID)
        if scope?.accountKey == accountKey {
            await stopEngine()
        }
        do {
            try forgetSyncOnDevice(keyStore: try keyStore(accountKey: accountKey), metadataDirectory: try metadataDirectory(accountKey: accountKey))
        } catch {
            hostedSyncLogger.error("Silinen hesabın eşitleme anahtarı temizlenemedi, hata: \(String(describing: error), privacy: .private)")
        }
        markOff(accountKey: accountKey)
    }

    // MARK: Yardımcılar

    private func makeClient() throws -> HostedSyncClient {
        guard let scope else {
            throw HostedClientError.notSignedIn
        }
        return HostedSyncClient(baseURL: try HostedServices.requireClient().baseURL, credentials: try HostedServices.requireClient(), deviceID: try deviceID(accountKey: scope.accountKey))
    }

    /// Bu cihazın bu hesaptaki eşitleme kimliği; ilk kullanımda üretilir.
    private func deviceID(accountKey: String) throws -> String {
        let defaults: UserDefaults = try hostedAccountDefaults(accountKey: accountKey)
        if let existing = defaults.string(forKey: HostedSyncDefaultsKey.deviceID) {
            return existing
        }
        let created: String = UUID().uuidString.lowercased()
        defaults.set(created, forKey: HostedSyncDefaultsKey.deviceID)
        return created
    }

    /// Anahtar, hesabın kendi Anahtar Zinciri servisinde (not hedefleriyle aynı servis; Mac'te tanıtım modu sahibin
    /// öğelerine dokunmaz, bkz. `appKeychainService`).
    private func keyStore(accountKey: String) throws -> SyncKeychainStore {
        #if os(macOS)
        SyncKeychainStore(service: try hostedAccountKeychainService(accountKey: accountKey))
        #else
        SyncKeychainStore(service: try accountKeychainService(appService: try hostedKeychainService(bundle: .main), accountKey: accountKey))
        #endif
    }

    private func metadataDirectory(accountKey: String) throws -> URL {
        AppPaths.accountSyncDirectory(dataRoot: try AppPaths.applicationSupport(), accountKey: accountKey)
    }

    /// Eşitlenen tercihlerin diskteki hâli (motorun yükleyeceği değerlerle aynı kaynaktan).
    private func currentSyncPrefs(accountKey: String) throws -> SyncPrefs {
        let domains: SyncedSettingsDomains = try hostedSyncedSettingsDomains(accountKey: accountKey)
        let defaults: UserDefaults = try hostedAccountDefaults(accountKey: accountKey)
        return SyncPrefs(
            schema: syncPayloadSchema, folders: defaults.stringArray(forKey: savedFoldersKey) ?? [],
            recipes: try loadUserRecipes(defaults: defaults).filter { !$0.isBuiltIn }, settings: try currentSyncedSettings(domains: domains)
        )
    }
}

/// Eşitleme hatasının kullanıcı metni.
func hostedSyncMessage(error: any Error) -> String {
    switch error {
    case SyncCryptoError.invalidRecoveryCode:
        return String(localized: "Kod 32 karakter olmalı; diğer cihazda gösterildiği gibi yaz.")
    case SyncCryptoError.authenticationFailed:
        return String(localized: "Kod bu hesabın kodu değil. Diğer cihazda Ayarlar'daki kodu yeniden kontrol et.")
    case SyncSetupError.staleLinkCode:
        return String(localized: "Bu kod eski: eşitleme o günden beri yeniden açılmış. Diğer cihazdaki güncel kodu yaz.")
    case SyncSetupError.noLinkCode:
        return String(localized: "Diğer cihaz eşitlemeyi açmayı bitirmedi. O cihazda uygulamayı açıp yeniden dene.")
    case HostedSyncError.notEnabled:
        return String(localized: "Eşitleme bu hesapta kapalı. Bu cihazda açarak başlatabilirsin.")
    case HostedSyncError.unavailable:
        return String(localized: "Eşitleme şu an kullanılamıyor; yeniden açılınca kaldığı yerden sürer.")
    case HostedSyncError.quotaExceeded:
        return String(localized: "Eşitleme alanı doldu; yeni değişiklikler yüklenemiyor. Eski toplantıları silerek yer açabilirsin.")
    case let apiError as HostedAPIError where apiError.code == .subscriptionRequired:
        return String(localized: "Yeni değişiklikleri eşitlemek için etkin abonelik gerekir. Toplantıların bu cihazda kalır.")
    default:
        return userFacingMessage(error: error)
    }
}
