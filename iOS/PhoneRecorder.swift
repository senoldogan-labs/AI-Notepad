import ActivityKit
import AINotepadCore
import AINotepadUI
import BackgroundTasks
import Foundation
import os
import UIKit

/// Kaydın durumu.
enum RecorderPhase: Equatable {
    case idle
    case starting
    case recording
    /// Mikrofon kapandı; Deepgram ve konuşmacı ayırma son bölümleri bitiriyor.
    case finishing
}

/// Süren kayıt.
private struct ActiveRecording {
    let directory: URL
    let startedAt: Date
    let handle: LiveSessionHandle
    /// Canlı çeviri: kaydın sunucu oturumunun bütçesinden (`hostedMeetingLLMProvider`); çevrimdışı kayıtta ya da
    /// kullanılamıyorsa nil (neden kayıt ekranında görünür).
    let liveLLM: LLMProvider?
    /// Canlı metnin başladığı motor: bulut (Deepgram) ya da bu iPhone (Apple konuşma tanıma). Son geçiş her durumda
    /// sunucudadır.
    let engine: RecordingEngine
    /// Sunucuya ulaşılamadan başladı: toplantı bağlantı gelince işlenir (bkz. `runQueue`).
    let offline: Bool
    /// Kaydın bağlandığı takvim etkinliği (başlık ve katılımcılar kayda geçer); yoksa nil.
    let linkedMeeting: CalendarMeeting?
    /// Notun şablonu: kayıt başlarken Ayarlar'daki varsayılan ya da takvim etkinliğinin adına göre seçilen (kayıt
    /// sırasında değişmez).
    let template: NoteTemplate
    /// Duraklatma: duraklatılan ses akıştan atılır (dosyaya yazılmaz, yazıya dökülmez); mikrofon açık kalır.
    let pauseGate: RecordingPauseGate
}

/// iPhone kaydı: yüz yüze toplantı (odadaki herkes telefon mikrofonundan gelir ve konuşmacılara ayrılır). Mac'teki
/// Gistsmith'le aynı abonelik akışı: ses hemen diske yazılır, kaydın sunucu oturumu açılır (deneme ve aylık sınır
/// sunucuda), canlı metin sunucu izin verirse Deepgram'la (kısa ömürlü jetonla), vermezse ya da akış durursa bu
/// iPhone'da (Apple konuşma tanıma); bitince oturum kapanır, konuşmacılar ve son geçiş sunucuda (ElevenLabs), çeviri ve
/// not sunucu üzerinden Claude ile. Sunucuya ulaşılamazsa ve son bilinen hak durumu izin verdiyse kayıt çevrimdışı sürer,
/// toplantı bağlantı gelince işlenir. İşleme Mac'teki `processMeeting`'dir.
@MainActor
@Observable
final class PhoneRecorder {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneRecorder")
    /// Aynı anda en fazla bu kadar canlı çeviri isteği.
    private static let maxParallelTranslations: Int = 4
    /// Sesi gerçekten yakalanan akışlar: yüz yüze kayıtta odadaki herkes "Diğerleri"nde; "Sen" akışı baştan boştur.
    private static let capturedSpeakers: Set<Speaker> = [.others]
    /// "Bitir"den sonra canlı oturumun kapanması için en uzun bekleme (Deepgram kapanışı en çok ~5 sn + kalan sesin
    /// yarısı); aşılırsa kayıt canlı metnin sonu beklenmeden kapatılır.
    private static let finishingLimitSec: Double = 30
    /// Mikrofon yeniden ses verince bildirimin ekranda kalma süresi.
    private static let recoveryNoticeSec: Double = 4

    private(set) var phase: RecorderPhase = .idle
    private(set) var transcript: [LiveSegment] = []
    /// Kullanıcının kayıt sırasında yaptığı konuşmacı düzeltmeleri (otomatik ayırmanın üstüne uygulanır; Mac'teki gibi).
    private(set) var speakerCorrections: SpeakerCorrections = .none
    private(set) var translations: [SegmentID: String] = [:]
    /// Çevirisi başarısız bölümler (kayıt ekranında "Tekrar dene").
    private(set) var failedTranslations: Set<SegmentID> = []
    /// Duraklatma saati (kayıt ekranındaki ve canlı etkinlikteki süre duraklatılan zamanı saymaz).
    private(set) var pauseClock: PauseClock = .running
    private(set) var lockedLanguage: MeetingLanguage?
    /// Süren kaydın kullanıcının sabitlediği dili: kayıt başında seçili sabit dil; Otomatikte ve kayıtta dil
    /// değiştirildiyse nil (değişiklikten önceki konuşma önceki dildedir, süzülmez). Kayda yazılır; doluysa başka dildeki
    /// konuşma çevrilmez ve toplantıdan atlanır.
    private(set) var recordingFixedLanguage: MeetingLanguage?
    /// Kesinleşen bölümlerin güvenle algılanan dilleri (bkz. `confidentSpokenLanguage`); bölümlerle birlikte saklanır.
    private(set) var spokenLanguages: [SegmentID: String] = [:]
    /// Metni toplantı dilinden başka dilde olduğu için çevrilmeyen birimlerin bölümleri.
    private(set) var languageSkippedSegments: Set<SegmentID> = []
    private(set) var errorMessages: [String] = []
    private(set) var startedAt: Date?
    /// İşlenen toplantıların adımı (kimlik → adım).
    private(set) var processingSteps: [String: ProcessingStep] = [:]
    /// Son biten kaydın kimliği (hazırlanma kartı bunu izler).
    private(set) var lastMeetingID: String?
    /// Bir sonraki kaydın dil modu; seçim saklanır, yeniden açılışta sürer.
    var languageMode: LanguageMode = storedLanguageMode(value: UserDefaults.standard.string(forKey: PhoneSettingsKey.languageMode)) {
        didSet {
            UserDefaults.standard.set(languageModeStorageValue(mode: languageMode), forKey: PhoneSettingsKey.languageMode)
        }
    }
    /// Dil modunun bellekteki kopyasını kayıtlı değerle eşler (değer başka cihazdan eşitlenerek değiştiyse). Kayıt
    /// sürerken dokunulmaz: süren kaydın ayarları değişmez (eşitleme de o sırada ayar yazmaz).
    func refreshStoredSettings() {
        guard phase == .idle else {
            return
        }
        let stored: LanguageMode = storedLanguageMode(value: UserDefaults.standard.string(forKey: PhoneSettingsKey.languageMode))
        if languageMode != stored {
            languageMode = stored
        }
    }

    /// Kayıtta işaretlenen anlar (not onları öne çıkarır).
    private(set) var highlights: [Highlight] = []
    /// Kullanıcının kayıt sırasında yazdığı notlar (not bunları öncelik sayar).
    var myNotes: String = ""
    /// "Katılımcılara haber ver" bildirimi görünür (ayar açıksa kayıt başında açılır; kayıt ekranı 3 saniye sonra ya da
    /// dokununca kapatır).
    var consentReminderVisible: Bool = false
    /// Kayıt başlarken bağlı takvim toplantısıyla ilgili önceki toplantılardan açık görevler (`relatedOpenTasks`; yalnız
    /// yerel kayıtlar): kayıt ekranında hatırlatma. Kapatılınca ya da kayıt bitince boş.
    var relatedTasks: [RelatedOpenTask] = []
    /// Kaydın bağlı olduğu takvim toplantısı (takvim açıksa ve kayıt başlarken bir toplantı sürüyorsa): "Açık görevler"in
    /// "Tümünü gör"ü onun brifingini açar (Mac'teki `recordingCalendarMeeting`). Kayıt bitince nil.
    private(set) var recordingCalendarMeeting: CalendarMeeting?
    /// Kayıt sunucuya ulaşılamadan sürüyor (canlı metin bu iPhone'da; konuşmacılar ve not bağlantı gelince): kayıt
    /// ekranında bildirim (Mac'teki `isOfflineRecording`).
    private(set) var isOfflineRecording: Bool = false
    /// Aylık sınıra az kaldığı için sunucunun kısalttığı toplantının bitiş anı: kayıt ekranında kalan dakika (Mac'teki
    /// `shortMeetingDeadline`); olağan süredeki toplantıda nil.
    private(set) var shortMeetingDeadline: Date?
    let levels: AudioLevels = AudioLevels(count: 36, interval: 0.08)

    @ObservationIgnored private let store: PhoneStore
    @ObservationIgnored private let microphone: MicrophoneCapture = MicrophoneCapture()
    /// Mikrofonun durumu: kesinti (çağrı, alarm) ya da yeniden bağlanma kayıt ekranında ve canlı etkinlikte görünür;
    /// her iki durumda kayıt açık kalır ve ses gelince kendiliğinden sürer.
    private(set) var microphoneStatus: MicrophoneStatus = .running
    /// Mikrofon kesinti ya da yeniden kurmadan sonra yeniden ses veriyor: kayıt ekranında birkaç saniye bildirim.
    private(set) var microphoneRecoveredNoticeVisible: Bool = false
    /// "Bitir"e basılan an (ya da mikrofonun beklenmedik sonu): süre burada durur, bitirme sürerken saymaz.
    private(set) var stoppedAt: Date?
    @ObservationIgnored private var recoveryNoticeTask: Task<Void, Never>?
    /// Kayıt başlarken (`.starting`) "Bitir" istendi (Kısayollar, canlı etkinlik): başlatma mikrofon açılmadan önce
    /// iptal edilir; sunucu oturumu açıldıysa kayıt başlar başlamaz bitirilir (bkz. `stop`).
    @ObservationIgnored private var stopRequestedDuringStart: Bool = false
    /// `start` mikrofonun açılmasını (ilk kullanımda izin penceresi, ses oturumu) bekliyor.
    @ObservationIgnored private var isAwaitingMicrophone: Bool = false
    /// "Bitir"den sonra canlı oturum takılırsa kaydı yine de kapatan bekçi (bkz. `watchFinishing`).
    @ObservationIgnored private var finishingWatchdogTask: Task<Void, Never>?
    /// Kapanışı başlamış kaydın kuşağı: oturum sonu (olay akışı bitti ya da bekçi) aynı kayıt için bir kez işlenir.
    @ObservationIgnored private var endedGeneration: Int?
    /// Cihaz içi konuşma modelinin indirme ilerlemesi (0…1) kayıt başlarken; indirme yoksa nil.
    private(set) var speechModelProgress: Double?
    /// Cihaz içi konuşma tanıma motoru (Deepgram kullanılamazsa canlı metin bununla; model kayıtlar arasında bellekte kalır).
    @ObservationIgnored private let speechEngine: AppleSpeechEngine = AppleSpeechEngine()
    /// Toplantının süre sınırını izleyen görev (bkz. `watchRecordingLimit`).
    @ObservationIgnored private var recordingLimitTask: Task<Void, Never>?
    /// Bekleyen (çevrimdışı) kayıtların kuyruğu çalışıyor (eşzamanlı tetiklemeler ikinci kez çalıştırmasın; hesap
    /// değişimi biterken bekler).
    private(set) var isRunningQueue: Bool = false
    /// Notun yazılmaya başladığı an (toplantı başına; not süresi telemetrisi, bkz. `recordNoteOutcome`).
    @ObservationIgnored private var noteWritingStartedAt: [String: ContinuousClock.Instant] = [:]
    /// Sunucunun reddettiği bekleyen kayıtlar ve reddin anı (bkz. `hostedQueueCandidates`).
    @ObservationIgnored private var queueRejections: [String: Date] = [:]
    @ObservationIgnored private var active: ActiveRecording?
    /// Uygulama arka planda: kayıt ekranı görünmez; geçici bölümler bekletilir ve ses çubukları durur (arka planda
    /// her ses parçasında ve her geçici sonuçta SwiftUI işi yapılmaz; bkz. `enterBackground`).
    @ObservationIgnored private var isInBackground: Bool = false
    /// Arka planda bekletilen geçici bölümler (bkz. `routingLiveEvent`); öne dönünce transkripte uygulanır.
    @ObservationIgnored private var deferredPartials: [SegmentID: LiveSegment] = [:]
    /// Arka plana geçiş sayısı: toplantı işlenirken artarsa sistem uygulamayı askıya alıp istekleri kesmiş olabilir
    /// (başarısız not yeniden denenir, bkz. `process`).
    @ObservationIgnored private var backgroundEntries: Int = 0
    /// Ağ yolu: işleme sırasında bağlantı koptu mu; not yeniden denenmeden önce bağlantı beklenir.
    @ObservationIgnored private let network: NetworkPathWatch = NetworkPathWatch()
    /// Uygulama kayıt sürerken kapandığı için açılışta bulunan kayıtlar: işlenince toplantıda neden kısa olduğu yazılır
    /// (bkz. `resumeUnfinished`).
    @ObservationIgnored private var recoveredRecordingIDs: Set<String> = []
    /// Canlı çevirinin cümle birimlerini kuran durum (bkz. `TranslationUnit`): kesin bölümler cümle sonuna dek birikir.
    @ObservationIgnored private var unitBuilder: TranslationUnitBuilder = .empty
    /// Bu kayıtta kurulan çeviri birimleri (kuruluş sırasıyla): bağlam bunlardan.
    @ObservationIgnored private var translationUnits: [TranslationUnit] = []
    /// Konuşmacı başına sessizlik beklemesi: süre dolunca bekleyen yarım birim çevrilir; yeni kesin bölüm, yeni kayıt ve
    /// kayıt sonu iptal eder.
    @ObservationIgnored private var idleFlushTasks: [Speaker: Task<Void, Never>] = [:]
    /// Sırası gelmemiş çeviriler: yeni konuşma önce, çeviri sonradan açılınca biriken cümleler en yeniden eskiye (bkz.
    /// `LiveTranslationQueue`).
    @ObservationIgnored private var translationQueue: LiveTranslationQueue<TranslationUnit> = .empty
    @ObservationIgnored private var translationsInFlight: Int = 0
    /// Süren çevirilerden birikmiş cümlelerinkiler (en çok `backlogTranslationSlots`; bir yer yeni konuşmaya kalır).
    @ObservationIgnored private var backlogTranslationIDs: Set<UUID> = []
    /// Her kayıtta artar: önceki kaydın geç gelen çevirisi yenisine yazılmaz.
    @ObservationIgnored private var generation: Int = 0
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    /// Kontrol noktalarını ana iş parçacığı dışında yazar (uzun toplantıda kodlama arayüzü takmasın).
    @ObservationIgnored private let checkpointWriter: MeetingCheckpointWriter = MeetingCheckpointWriter()
    /// Kayıt sürerken boş yeri denetleyen görev (bkz. `startDiskSpaceWatch`).
    @ObservationIgnored private var diskSpaceTask: Task<Void, Never>?
    /// Kayıttan önce boş yerin durumu: azsa kayıt kartının altında kısa uyarı (bkz. `refreshRecordingDiskSpace`).
    private(set) var recordingDiskSpace: RecordingDiskSpace = .enough
    /// Kayıt ekranının canlı metinden türettiklerinin önbelleği (girdileri ve görünüm): her canlı güncellemede bir kez
    /// kurulur (bkz. `liveView`).
    @ObservationIgnored private var liveViewCache: (transcript: [LiveSegment], corrections: SpeakerCorrections, view: LiveTranscriptView)?
    /// Kendiliğinden yeniden denemeleri yoklayan görev (bkz. `startAutomaticRetryTimer`).
    @ObservationIgnored private var automaticRetryTask: Task<Void, Never>?
    /// Kilit ekranı ve Dynamic Island'daki canlı etkinlik; izin yoksa nil.
    @ObservationIgnored private var activity: Activity<RecordingActivityAttributes>?
    /// Süren arka plan görevleri (anahtar: toplantı kimliği): kayıt kapanışı ve işleme uygulama arka plandayken sürsün.
    @ObservationIgnored private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    /// Sistemin ilerleme arayüzüyle süren işleme görevleri (anahtar: toplantı kimliği).
    @ObservationIgnored private var continuedTasks: [String: BGContinuedProcessingTask] = [:]
    /// Süren işlemeler (anahtar: toplantı kimliği): sistem görevi sona erince iptal edilir.
    @ObservationIgnored private var processingTasks: [String: Task<Void, Never>] = [:]
    /// Canlı etkinlik en fazla bu sıklıkta güncellenir (sistem sık güncellemeyi kısar).
    @ObservationIgnored private var lastActivityUpdate: Date = .distantPast
    /// Kayıt başlarken takvimde süren toplantı (takvim açıksa; uygulama bağlar); başlık ve katılımcılar kayda geçer.
    @ObservationIgnored var currentCalendarMeeting: (@MainActor () -> CalendarMeeting?)?
    /// Toplantının işlenmesi bitip kaydedildi (uygulama bağlar): notu hazırsa bağlı hedeflere kendiliğinden gider.
    @ObservationIgnored var onMeetingProcessed: (@MainActor (MeetingRecord) -> Void)?

    /// Bu kaydedicinin kurulduğu hesap (bkz. `resolvedBoundAccountKey`): hesap yerinde değiştikten sonra eski hesabın
    /// kuyruğu ve yeniden denemeleri yeni hesabın oturumunu ve klasörünü kullanmaz.
    @ObservationIgnored private var accountKey: String?

    init(store: PhoneStore) {
        self.store = store
        accountKey = AppPaths.activeAccountKey()
    }

    /// Bağlı olunan hesap hâlâ yüklü ve giriş yapan (`signedInKey`) hesap mı (bkz. `isAccountSessionCurrent`); kurulurken
    /// hesap yüklü değildiyse ilk yüklenen hesaba bağlanır.
    private func isBoundAccountCurrent(signedInKey: String?) -> Bool {
        accountKey = resolvedBoundAccountKey(bound: accountKey, active: AppPaths.activeAccountKey())
        return isAccountSessionCurrent(boundKey: accountKey, activeKey: AppPaths.activeAccountKey(), signedInKey: signedInKey)
    }

    /// Kaydı başlatır. Giriş yapılmamışsa, yapay zekâ açıklaması kabul edilmemişse ya da hak durumu kaydı engelliyorsa
    /// (deneme bitti, aylık sınır…) hiçbir şey başlamaz ve neden görünür. Mikrofon açılınca ses hemen diske yazılır,
    /// sonra kaydın sunucu oturumu açılır; sunucu reddederse kayıt başlamaz ve yazılan ses silinir.
    func start() async {
        guard phase == .idle else {
            return
        }
        let account: HostedAccount = HostedAccount.shared
        // Giriş kapısının ikinci savunması: kısayol, Denetim Merkezi ve Eylem düğmesi kapıyı açmadan çağırabilir.
        guard !account.requiresSignIn else {
            Self.logger.info("Giriş yapılmadan kayıt istendi, başlatılmadı")
            errorMessages = appendUnique(messages: [], message: String(localized: "Kayıt için önce giriş yap."))
            return
        }
        guard phoneAIConsentGiven(account: account) else {
            Self.logger.info("Yapay zekâ açıklaması onaylanmadan kayıt istendi, başlatılmadı")
            errorMessages = appendUnique(messages: [], message: String(localized: "Kayıt için önce uygulamayı aç ve yapay zekâ kullanımını onayla."))
            return
        }
        if phoneStartBlockMessage(account: account, now: Date()) != nil {
            // Neden kayıt kartının altındaki plan notunda görünür (`PhonePlanNotice`); hata listesine ikinci kez yazılmaz
            // (abone olunca da orada kalırdı).
            Self.logger.info("Hak durumu kaydı engelliyor, başlatılmadı")
            errorMessages = []
            // Deneme bitti ya da plan sona erdi: abonelik ekranı açılır.
            if account.requiresSubscription {
                account.requestSubscription()
            }
            return
        }
        // Diskte kısa bir kayda bile yer yoksa kayıt başlamaz (başlar başlamaz bitirilirdi); az yer kayıt kartında uyarılır.
        refreshRecordingDiskSpace()
        guard recordingDiskSpace != .full else {
            Self.logger.warning("Diskte yer yok, kayıt başlatılmadı")
            errorMessages = appendUnique(messages: [], message: phoneDiskFullText())
            return
        }
        phase = .starting
        stopRequestedDuringStart = false
        generation += 1
        finishingWatchdogTask?.cancel()
        finishingWatchdogTask = nil
        stoppedAt = nil
        microphoneStatus = .running
        microphoneRecoveredNoticeVisible = false
        transcript = []
        deferredPartials = [:]
        speakerCorrections = .none
        translations = [:]
        failedTranslations = []
        pauseClock = .running
        translationQueue = .empty
        backlogTranslationIDs = []
        unitBuilder = .empty
        translationUnits = []
        idleFlushTasks.values.forEach { $0.cancel() }
        idleFlushTasks = [:]
        lockedLanguage = nil
        recordingFixedLanguage = fixedMeetingLanguage(mode: languageMode)
        spokenLanguages = [:]
        languageSkippedSegments = []
        errorMessages = []
        highlights = []
        myNotes = ""
        closeAssistantCard()
        // Canlı akış dil algılamaz (Deepgram da Apple konuşma tanıma da): sabit dil ya da ana toplantı dili.
        let speechLanguage: MeetingLanguage = appleSpeechLanguage(mode: languageMode, primary: phonePrimaryMeetingLanguage())
        let started: Date = Date()
        // Takvimde şu anki toplantı: başlık ve katılımcı adları kayda geçer, adlar tanımaya yardım eder.
        let linkedMeeting: CalendarMeeting? = currentCalendarMeeting?()
        let directory: URL
        do {
            directory = try AppPaths.newSessionDirectory(startedAt: started)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            phase = .idle
            return
        }
        let audio: AsyncStream<[Float]>
        let pauseGate: RecordingPauseGate
        do {
            let origin: ContinuousClock.Instant = .now
            microphone.onStatusChange = { [weak self] (status: MicrophoneStatus) -> Void in
                self?.microphoneStatusChanged(status: status)
            }
            // Duraklatma hizalanmış akışta süzülür: kesinti sonrası sessizlik dolgusu da duraklatılan aralığa düşüyorsa
            // atılır; mikrofon duraklatmada kapanmaz (yakalama yeniden kurulmaz, ikinci dinleyici takılmaz).
            pauseGate = RecordingPauseGate(sampleRate: 16000, origin: origin)
            isAwaitingMicrophone = true
            defer { isAwaitingMicrophone = false }
            let aligned: AsyncStream<[Float]> = clockAlignedStream(audio: try await microphone.start(), origin: origin, sampleRate: 16000, thresholdSec: 0.5)
            audio = pausableStream(audio: aligned, gate: pauseGate)
        } catch {
            // "Bitir" izin penceresi açıkken geldi: mikrofon açılmadı (`MicrophoneCapture.start` iptal etti); hata değil.
            if !stopRequestedDuringStart {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
            // Mikrofon açılamadı (izin yok, ses oturumu, başlarken bitirildi): boş toplantı klasörü kalmasın.
            discardUnstartedRecording(directory: directory)
            phase = .idle
            return
        }
        // "Bitir" mikrofon açılırken geldi: sunucu oturumu açılmadan (deneme hakkı yanmadan) mikrofon kapatılır.
        guard !stopRequestedDuringStart else {
            Self.logger.info("Kayıt başlarken bitirildi, mikrofon kapatıldı, sunucu oturumu açılmadı")
            microphone.stop()
            discardUnstartedRecording(directory: directory)
            phase = .idle
            return
        }
        // Arka planda başlatıldıysa (Kısayollar) çubuklar öne dönünce başlar (bkz. `enterForeground`).
        if !isInBackground {
            levels.start()
        }
        let levels: AudioLevels = levels
        // En yüksek seviye kilitli kutuda birikir; ana aktöre çubuk aralığının yarısında bir geçilir (her parça için
        // görev açılmaz; bkz. `levelThrottleInterval`).
        let throttle: LevelThrottle = LevelThrottle(intervalSec: levelThrottleInterval(barInterval: levels.interval))
        let metered: AsyncStream<[Float]> = meteredStream(audio: audio) { (level: Float) -> Void in
            guard let peak = throttle.add(level: level) else {
                return
            }
            Task { @MainActor in levels.record(level: peak) }
        }
        // Ses hemen diske yazılır: sunucu oturumu açılırken ve canlı motor seçilirken (ağ beklenirken) gelen ses de
        // dosyada durur. Yüz yüze: "Sen" akışı yoktur, odadaki herkes "Diğerleri" akışında konuşmacılara ayrılır.
        let recording: HybridRecording = startHybridRecording(directory: directory, meAudio: finishedAudioStream(), othersAudio: metered)
        // Sunucu oturumu ses başladıktan sonra açılır (mikrofon açılamazsa deneme hakkı yanmasın); sunucu reddederse
        // (deneme bitti, aylık sınır, harcama tavanı…) kayıt başlamaz, yazılan ses silinir ve neden görünür.
        let deadline: Date
        let offline: Bool
        let shortDeadline: Date?
        do {
            let requestedAt: Date = Date()
            switch try await account.startMeeting(recordID: directory.lastPathComponent) {
            case .online(let meeting):
                deadline = hostedRecordingDeadline(requestedAt: requestedAt, maxDurationMinutes: meeting.maxDurationMinutes, serverEndsAt: meeting.expiresAt)
                offline = false
                // Aylık sınıra az kaldıysa toplantı olağandan kısadır: kalan dakika kayıt ekranında görünür.
                shortDeadline = isShortenedHostedMeeting(started: meeting) ? deadline : nil
            case .offline(let maxMinutes):
                // Sunucuya ulaşılamadı: kayıt sürer (canlı metin bu iPhone'da), süre son bilinen hak durumuyla sınırlı;
                // toplantı bağlantı gelince işlenir (bkz. `runQueue`).
                deadline = requestedAt.addingTimeInterval(Double(maxMinutes) * 60)
                offline = true
                shortDeadline = nil
            }
        } catch {
            Self.logger.error("Toplantı oturumu açılamadı, kayıt başlatılmadı, hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            // Sunucu abonelik istedi (deneme bitti, abonelik gerekli, deneme bu cihazda kullanıldı): abonelik ekranı açılır.
            if let apiError = error as? HostedAPIError, let code = apiError.code, hostedSubscriptionRequiredCodes.contains(code) {
                account.requestSubscription()
            }
            // Ret aylık sınırdan ya da denemenin bitmesinden olabilir: hesap ekranı güncellensin.
            Task { await account.refresh() }
            microphone.stop()
            levels.stop()
            discardUnstartedRecording(directory: directory)
            phase = .idle
            return
        }
        // Canlı motoru sunucu seçer (Deepgram jetonu); jeton alınamazsa ya da akış durursa canlı metin bu iPhone'da.
        let choice: HostedLiveChoice = await hostedLiveChoice(
            language: speechLanguage,
            keyterms: keytermsWithAttendees(attendees: linkedMeeting?.attendees ?? [], keyterms: phoneRecognitionKeyterms(store: store), limit: 30)
        )
        Self.logger.info("Canlı motor seçildi, motor: \(choice.engine.rawValue, privacy: .public)")
        let handle: LiveSessionHandle = runHybridLiveSession(
            config: HybridLiveSessionConfig(
                speakers: Self.capturedSpeakers,
                local: LiveSessionConfig(
                    languageMode: .fixed(speechLanguage), segmenter: .live, recordingDirectory: directory, partialIntervalSec: 1.5,
                    minPartialSpeechSec: 1.0, languageLockAfterSec: 30, candidateLanguages: [speechLanguage]
                ),
                maxPendingAudioSec: 600
            ),
            start: choice.start,
            localEngine: { [weak self] () async throws -> any TranscriptionEngine in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.prepareLocalSpeech(language: speechLanguage)
            },
            recording: recording
        )
        let liveLLM: LLMProvider?
        do {
            liveLLM = try hostedMeetingLLMProvider()
        } catch {
            // Çevrimdışı kayıtta canlı çeviri yapılmaz (not ve konuşmacılar bağlantı gelince hazırlanır).
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            liveLLM = nil
        }
        let active: ActiveRecording = ActiveRecording(
            directory: directory, startedAt: started, handle: handle, liveLLM: liveLLM, engine: choice.engine == .deepgram ? .cloud : .local,
            offline: offline, linkedMeeting: linkedMeeting, template: phoneNewMeetingNoteTemplate(title: linkedMeeting?.title ?? ""),
            pauseGate: pauseGate
        )
        self.active = active
        recordingCalendarMeeting = linkedMeeting
        isOfflineRecording = offline
        shortMeetingDeadline = shortDeadline
        startedAt = started
        phase = .recording
        // Uygulama kayıt sırasında kapanırsa toplantı açılışta bulunup işlenir.
        saveRecord(record: liveRecord(recording: active, status: .recording, endedAt: nil), directory: directory)
        startCheckpoints()
        startDiskSpaceWatch(directory: directory, startedAt: started)
        startActivity(startedAt: started, title: linkedMeeting?.title ?? String(localized: "Toplantı"))
        watchRecordingLimit(deadline: deadline)
        Task { await scheduleRecordingLimitNotifications(deadline: deadline, warningLeadSec: hostedLimitWarningLeadSec) }
        consentReminderVisible = UserDefaults.standard.bool(forKey: PhoneSettingsKey.consentReminder)
        relatedTasks = linkedMeeting.map { (meeting: CalendarMeeting) -> [RelatedOpenTask] in
            relatedOpenTasks(meeting: meeting, records: store.meetings, userName: store.userName, before: started)
        } ?? []
        Self.logger.info("Kayıt başladı, klasör: \(directory.lastPathComponent, privacy: .public), çevrimdışı: \(offline, privacy: .public)")
        let sessionGeneration: Int = generation
        Task { [weak self] in
            for await event in handle.events {
                self?.handle(event: event, generation: sessionGeneration)
            }
            await self?.sessionEnded(sessionGeneration: sessionGeneration)
        }
        // "Bitir" sunucu oturumu açılırken geldi: kayıt uygulamadaki "Bitir" gibi bitirilir ve işlenir (oturum kapanır).
        if stopRequestedDuringStart {
            Self.logger.info("Kayıt başlarken bitirildi, kayıt hemen bitiriliyor")
            stop()
        }
    }

    /// Deepgram kullanılamayınca canlı metnin motoru: dilin cihaz içi konuşma modeli gerekirse indirilir (ilerleme kayıt
    /// ekranında). Hazırlanamazsa hata (canlı metin durur, kayıt sürer; son geçiş kaydın tamamını yazıya döker).
    private func prepareLocalSpeech(language: MeetingLanguage) async throws -> AppleSpeechEngine {
        defer { speechModelProgress = nil }
        _ = try await prepareAppleSpeech(language: language) { [weak self] (fraction: Double) -> Void in
            Task { @MainActor in
                self?.speechModelProgress = fraction < 1 ? fraction : nil
            }
        }
        return speechEngine
    }

    /// Toplantının süre sınırından 5 dk önce kayıt ekranında uyarı, sınırda kayıt "Bitir"e basılmış gibi bitirilir ve
    /// normal işlenir (Mac'teki gibi). Kayıt bitince (ya da yenisi başlayınca) görev kendiliğinden sona erer.
    private func watchRecordingLimit(deadline: Date) {
        recordingLimitTask?.cancel()
        let limitGeneration: Int = generation
        recordingLimitTask = Task { [weak self] in
            var warned: Bool = false
            while !Task.isCancelled {
                guard let self, self.phase == .recording, limitGeneration == self.generation else {
                    return
                }
                switch hostedRecordingLimitState(now: Date(), deadline: deadline, warningLeadSec: hostedLimitWarningLeadSec) {
                case .running:
                    break
                case .warning:
                    if !warned {
                        warned = true
                        let time: String = deadline.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
                        Self.logger.info("Toplantının süre sınırı yaklaşıyor, uyarı gösterildi")
                        self.errorMessages = appendUnique(messages: self.errorMessages, message: String(localized: "Bu toplantının süre sınırına 5 dakika kaldı; kayıt \(time) itibarıyla bitirilecek."))
                    }
                case .reached:
                    Self.logger.info("Toplantının süre sınırına ulaşıldı, kayıt bitiriliyor")
                    recordTelemetryCount(kind: .recordingOverrun)
                    self.errorMessages = appendUnique(messages: self.errorMessages, message: String(localized: "Bu toplantının süre sınırına ulaşıldı; kayıt bitirildi."))
                    self.stop()
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // İptal: kayıt bitti ya da yenisi başladı.
                    return
                }
            }
        }
    }

    /// Kayıt başlamadı (sunucu toplantıyı reddetti ya da başlarken bitirildi): o ana dek diske yazılan ses ve klasör
    /// silinir.
    private func discardUnstartedRecording(directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Self.logger.error("Reddedilen kaydın klasörü silinemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Mikrofonu kapatır; oturum kalan bölümleri bitirip kendiliğinden biter. Kayıt başlarken (`.starting`; Kısayollar,
    /// canlı etkinlik) çağrılırsa istek saklanır: mikrofon açılmadan önceyse başlatma iptal edilir (izin penceresi
    /// açıksa mikrofon hiç açılmaz), sunucu oturumu açıldıktan sonraysa kayıt başlar başlamaz bitirilir.
    func stop() {
        if phase == .starting {
            requestStopDuringStart()
            return
        }
        guard phase == .recording else {
            // Kayıt yokken "Bitir" (kilit ekranı, Denetim Merkezi): uygulama kayıt sırasında kapandıysa kalan canlı
            // etkinlik kalkar.
            endStaleActivities()
            return
        }
        phase = .finishing
        let stopped: Date = Date()
        stoppedAt = stopped
        // Duraklatılmışken bitirildi: süre duraklatma anında kalır; ses kapısı kapalı kalır (mikrofon kapanana dek gelen
        // ses de yazılmaz).
        pauseClock = pauseClock.resuming(at: stopped)
        closeAssistantCard()
        Self.logger.info("Kayıt bitiriliyor, duraklatılmış süre: \(self.pauseClock.completedSec, privacy: .public) sn")
        // Kapanış (son ses, son konuşmacı etiketleri, bekleyen çeviriler) uygulama arka plana geçse de bitsin.
        if let recording = active {
            let id: String = recording.directory.lastPathComponent
            beginBackgroundTask(id: id)
            // Sistem görevi kullanıcının "Bitir" anında istenir: istek yalnızca uygulama öndeyken kabul edilir. Çevrimdışı
            // kayıtta not şimdi hazırlanmaz (kuyruğa girer): sistem ilerlemesi istenmez (boş ilerleme ekranda kalırdı).
            if !recording.offline {
                submitContinuedProcessing(id: id, subtitle: continuedProcessingSubtitle(title: recording.linkedMeeting?.title ?? String(localized: "Toplantı"), startedAt: recording.startedAt))
            }
        }
        levels.stop()
        microphone.stop()
        updateActivityNow(state: activityState())
        watchFinishing()
    }

    /// Başlatma sürerken "Bitir": `start` bir sonraki adımda isteği uygular. Mikrofon açılıyorsa (izin penceresi, ses
    /// oturumu) yakalama durdurulur: `MicrophoneCapture.start` motoru kurmadan iptal eder.
    private func requestStopDuringStart() {
        guard !stopRequestedDuringStart else {
            return
        }
        stopRequestedDuringStart = true
        Self.logger.info("Kayıt başlarken bitirme istendi, mikrofon bekleniyor: \(self.isAwaitingMicrophone, privacy: .public)")
        if isAwaitingMicrophone {
            microphone.stop()
        }
    }

    /// "Bitir"den sonra canlı oturum (Deepgram kapanışı, cihaz içi tanımanın kalan sesi) `finishingLimitSec` içinde
    /// kapanmazsa kayıt canlı metnin sonu beklenmeden kapatılır: ses dosyası "Bitir" anında kapanmıştır ve son geçiş
    /// kaydın tamamını yazıya döker. Loglanır ve kayıt ekranında görünür; kullanıcı "Bitiriliyor"da takılı kalmaz.
    private func watchFinishing() {
        finishingWatchdogTask?.cancel()
        let finishingGeneration: Int = generation
        finishingWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.finishingLimitSec))
            } catch {
                // İptal: yeni kayıt başladı.
                return
            }
            guard let self, self.phase == .finishing, finishingGeneration == self.generation, self.endedGeneration != finishingGeneration else {
                return
            }
            Self.logger.error("Canlı oturum süre içinde kapanmadı, kayıt canlı metnin sonu beklenmeden kapatılıyor, süre: \(Self.finishingLimitSec, privacy: .public) sn")
            self.errorMessages = appendUnique(messages: self.errorMessages, message: String(localized: "Canlı metnin sonu beklenmeden kayıt kapatıldı; kaydın tamamı yine yazıya dökülür."))
            // Oturum bırakılır: Deepgram bağlantısı (WebSocket) kapanışı beklemeden kesilir; yoksa kayıt bittikten sonra
            // da açık kalıp canlı tutma mesajları yollayabilirdi.
            await self.active?.handle.cancel()
            await self.sessionEnded(sessionGeneration: finishingGeneration)
        }
    }

    /// Mikrofonun durumu değişti: kayıt ekranı ve canlı etkinlik güncellenir; ses geri gelince kısa bildirim.
    private func microphoneStatusChanged(status: MicrophoneStatus) {
        let previous: MicrophoneStatus = microphoneStatus
        microphoneStatus = status
        guard phase == .recording else {
            return
        }
        if isMicrophoneRecovery(previous: previous, current: status) {
            Self.logger.info("Mikrofon yeniden ses veriyor, kayıt sürüyor")
            showRecoveryNotice()
        }
        updateActivityNow(state: activityState())
    }

    /// "Mikrofon yeniden bağlandı" bildirimi birkaç saniye görünür.
    private func showRecoveryNotice() {
        recoveryNoticeTask?.cancel()
        microphoneRecoveredNoticeVisible = true
        recoveryNoticeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.recoveryNoticeSec))
            } catch {
                // İptal: yeni bildirim geldi.
                return
            }
            self?.microphoneRecoveredNoticeVisible = false
        }
    }

    // MARK: Arka plan ve öne dönüş

    /// Uygulama arka plana geçti: kayıt (mikrofon, diske yazma, canlı metin, çeviri, kontrol noktaları) sürer; yalnızca
    /// görünmeyen ekranın işi durur: ses çubuklarının saati durur, geçici bölümler bekletilir (kesin bölümler hemen
    /// uygulanır). Canlı etkinlik o anki durumla tazelenir: kilit ekranı kaydı gösterir.
    func enterBackground() {
        guard !isInBackground else {
            return
        }
        isInBackground = true
        backgroundEntries += 1
        // İşleme sürerken arka plana geçildi: sistem işlemeyi keserse not, uygulama açılmayı beklemeden sistemin sürdürme
        // göreviyle yazılsın.
        if !processingSteps.isEmpty {
            ProcessingResumeScheduler.shared.schedule(reason: "işleme sürerken arka plana geçildi")
        }
        Self.logger.info("Uygulama arka plana geçti, kayıt: \(String(describing: self.phase), privacy: .public), mikrofon: \(String(describing: self.microphoneStatus), privacy: .public), bölüm: \(self.transcript.count, privacy: .public), işlenen: \(self.processingSteps.count, privacy: .public)")
        guard phase == .recording, active != nil else {
            return
        }
        levels.stop()
        updateActivityNow(state: activityState())
    }

    /// Uygulama öne döndü: arka planda bekletilen geçici bölümler hemen transkripte uygulanır (kayıt ekranı uzaktayken
    /// gelen her şeyi gösterir), ses çubukları yeniden akar. Kayıt ekranı `phase`'e bağlıdır: kayıt sürüyorsa olduğu gibi
    /// görünür.
    func enterForeground() {
        guard isInBackground else {
            return
        }
        isInBackground = false
        let deferred: Int = deferredPartials.count
        if !deferredPartials.isEmpty {
            transcript = applyingDeferredPartials(transcript: transcript, deferredPartials: deferredPartials)
            deferredPartials = [:]
        }
        Self.logger.info("Uygulama öne döndü, kayıt: \(String(describing: self.phase), privacy: .public), mikrofon: \(String(describing: self.microphoneStatus), privacy: .public), bölüm: \(self.transcript.count, privacy: .public), bekletilen geçici bölüm: \(deferred, privacy: .public), işlenen: \(self.processingSteps.count, privacy: .public)")
        guard phase == .recording, active != nil else {
            return
        }
        levels.start()
        updateActivityNow(state: activityState())
    }

    /// Kullanımdaki toplantılar (kayıtta ya da işleniyor).
    var busyMeetingIDs: Set<String> {
        Set(processingSteps.keys).union([active?.directory.lastPathComponent].compactMap { $0 })
    }

    /// Şu anı işaretler: notta öne çıkar (söz bittikten sonra basılır; aralığı `Highlight` belirler). An kaydedilen sesin
    /// zaman çizgisindedir (duraklatılan süre düşülür; transkriptle aynı); duraklatılmışken işaretlenmez.
    func markMoment() {
        guard phase == .recording, !pauseClock.isPaused, let active else {
            return
        }
        highlights.append(Highlight(startSec: active.pauseGate.keptSeconds(at: .now), endSec: nil))
    }

    /// Kayıt sürüyor ve duraklatılmış mı.
    var isPaused: Bool {
        pauseClock.isPaused
    }

    /// Kaydı duraklatır (Mac'teki "Duraklat"): bu andan sonraki ses dosyaya yazılmaz, yazıya dökülmez ve sunucuya
    /// gönderilmez (son geçiş ve canlı metin bu süreyi saymaz); süre durur. Mikrofon açık kalır: kayıt arka planda ve
    /// kilit ekranında sürer, yakalama yeniden kurulmaz. Kesinti (çağrı) duraklatmadan bağımsızdır; ikisi bir arada da
    /// duraklatılan aralığa düşen ses atılır.
    func pause() {
        guard phase == .recording, !pauseClock.isPaused, let active else {
            // Kayıt yokken "Duraklat" (kilit ekranı): uygulama kayıt sırasında kapandıysa kalan canlı etkinlik kalkar.
            endStaleActivities()
            return
        }
        active.pauseGate.pause(at: .now)
        pauseClock = pauseClock.pausing(at: Date())
        Self.logger.info("Kayıt duraklatıldı")
        updateActivityNow(state: activityState())
    }

    /// Duraklatılan kaydı sürdürür: ses yeniden kaydedilir ve yazıya dökülür.
    func resume() {
        guard phase == .recording, pauseClock.isPaused, let active else {
            // Kayıt yokken "Devam et" (kilit ekranı): uygulama kayıt sırasında kapandıysa kalan canlı etkinlik kalkar.
            endStaleActivities()
            return
        }
        active.pauseGate.resume(at: .now)
        pauseClock = pauseClock.resuming(at: Date())
        Self.logger.info("Kayıt sürdürüldü, duraklatılmış süre: \(self.pauseClock.completedSec, privacy: .public) sn")
        updateActivityNow(state: activityState())
    }

    /// Kayıt sırasında dili değiştirir; o andan sonraki metin yeni dille yazılır.
    func setLanguage(language: MeetingLanguage) {
        guard phase == .recording, let handle = active?.handle else {
            languageMode = .fixed(language)
            return
        }
        // Toplantıda artık iki dil var: dil süzmesi bu kayıtta kalkar, değişiklikten önce önceki dilde konuşulanlar
        // toplantıdan atlanmasın.
        recordingFixedLanguage = nil
        languageSkippedSegments = []
        Task {
            await handle.setLanguage(language)
        }
    }

    // MARK: Canlı metin eylemleri

    /// Konuşmacı düzeltmeleri uygulanmış transkript (kayıt ekranı, asistan, canlı etkinlik ve saklanan toplantı bunu
    /// kullanır).
    var correctedTranscript: [LiveSegment] {
        liveView.corrected
    }

    /// Kayıt ekranının canlı metinden türettikleri (düzeltilmiş transkript, konuşmacı blokları, bilinen kişiler). Ekran
    /// bunları her çizimde birçok yerde okur; canlı metin ya da düzeltmeler değişmediyse önbellekten döner (dizinin aynı
    /// tampon olduğu karşılaştırması sabit sürelidir), değiştiyse bir kez yeniden kurulur. Girdiler her okumada okunur:
    /// SwiftUI değişiklikleri izlemeye devam eder.
    var liveView: LiveTranscriptView {
        let currentTranscript: [LiveSegment] = transcript
        let currentCorrections: SpeakerCorrections = speakerCorrections
        if let cached = liveViewCache, cached.corrections == currentCorrections, cached.transcript == currentTranscript {
            return cached.view
        }
        let view: LiveTranscriptView = liveTranscriptView(transcript: currentTranscript, corrections: currentCorrections)
        liveViewCache = (transcript: currentTranscript, corrections: currentCorrections, view: view)
        return view
    }

    /// Bir bloğu başka konuşmacıya atar (otomatik ayırma yanıldıysa); sonraki ayırma pencereleri bunu ezmez.
    func reassignBlock(segments: [SegmentID], person: Int) {
        speakerCorrections = speakerCorrections.assigning(segments: segments, to: person)
    }

    /// Bir konuşmacının tüm bölümlerini (geçmiş ve gelecek) diğeriyle birleştirir.
    func mergeLivePersons(from: Int, into: Int) {
        speakerCorrections = speakerCorrections.merging(person: from, into: into)
    }

    /// "Yeni konuşmacı" seçilince verilecek, hiç kullanılmamış numara.
    var newPersonNumber: Int {
        nextFreePerson(transcript: transcript, corrections: speakerCorrections)
    }

    /// "Tümünü kopyala": ekrandaki gibi (gösterim ayarına göre orijinal, çeviri ya da ikisi) konuşmacılı düz metin.
    var displayedText: String {
        displayedPlainText(
            blocks: liveView.blocks, translations: translations, displayMode: phoneDisplayMode()
        )
    }

    /// Canlı çeviriyi açar ya da kapatır (Mac'teki kayıt kartındaki "Canlı çeviri"; ayar olarak saklanır). Kayıt sürerken
    /// açılırsa o ana dek çevrilmeyen cümleler de çevrilir (toplantıda çevirisi eksik kalmasın); birime girmiş bölüm
    /// yeniden girmez.
    func selectDisplayMode(mode: DisplayMode) {
        let resumesTranslation: Bool = mode.needsLiveTranslation && !phoneDisplayMode().needsLiveTranslation
        UserDefaults.standard.set(mode.rawValue, forKey: PhoneSettingsKey.displayMode)
        guard resumesTranslation, phase == .recording else {
            return
        }
        // Birikmiş cümleler yeni konuşmanın önüne girmez: canlı görünüm güncel kalır, eskiler boş yerde en yeniden eskiye
        // çevrilir (bkz. `LiveTranslationQueue`).
        for segment in transcript where segment.isFinal && !segment.text.isEmpty && translations[segment.id] == nil && !failedTranslations.contains(segment.id) {
            addForTranslation(segment: segment, lane: .backlog)
        }
    }

    /// Başarısız çevirileri yeniden dener (Mac'teki "Tekrar dene"): verilen bölümleri içeren birimler bütünüyle yeniden
    /// çevrilir (birim iki bloğa yayılsa da). Yalnızca kayıtta: kayıt bittikten sonra çevrilen cümle toplantıya yazılmaz.
    func retryTranslations(ids: [SegmentID]) {
        guard phase == .recording, active?.liveLLM != nil else {
            return
        }
        // Yalnızca hâlâ başarısız bölümü olan birimler: çevrilmiş birim ikinci kez çevrilmez.
        for unit in unitsContaining(ids: ids, units: translationUnits) where !failedTranslations.isDisjoint(with: unit.segmentIDs) {
            failedTranslations.subtract(unit.segmentIDs)
            queueTranslation(unit: unit, lane: .live)
        }
    }

    /// Açılışta (ve arka plandan dönünce) kayıtta ya da işlemede kalmış toplantılar kaldığı yerden işlenir (son geçiş
    /// parçaları ve sonucu, notun parçaları kaydedilir; kaydın sunucu oturumu kapandıysa yeniden açılır, bkz.
    /// `hostedFinalPassPlan`, `withRecordedMeetingReopen`), sonra
    /// bekleyen (çevrimdışı) kayıtlar denenir. Uygulama kayıt sürerken kapandıysa kaydedilen kısım hemen hazırlanır ve
    /// kayıt ekranında gösterilir (kayıt yeniden başlatılmaz: mikrofon kullanıcı istemeden açılmaz).
    func resumeUnfinished() async {
        endStaleActivities()
        // Hesap yerinde değiştiyse (ya da çıkış yapıldıysa) eski hesabın toplantıları yeni hesabın oturumuyla işlenmez.
        guard phase == .idle, isBoundAccountCurrent(signedInKey: phoneSignedInAccountKey()) else {
            return
        }
        // Bu oturumda işlenmekte olanlar (sahne yeniden kurulduysa) ikinci kez işlenmez: çift ücret, aynı dosyaya iki yazar.
        let local: Set<String>
        let linked: Set<String>
        do {
            local = try AppPaths.localMeetingIDs()
            linked = try hostedLinkedRecordIDs()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            return
        }
        // Uygulama kayıt sürerken kapandı (iOS sonlandırdı, çöktü, kullanıcı kapattı): diske yazılan ses ve son kontrol
        // noktasındaki canlı metin durur. Kayıt sessizce kaybolmaz: kayıt ekranında nedeni ve hazırlanması görünür,
        // toplantıda neden kısa olduğu yazılır; açık kalan sunucu oturumu işlenmeden önce kapatılır (süre akmaz, not ve
        // son geçiş oturumun ek süresinde yapılır).
        let recovered: [String] = interruptedRecordingIDs(records: store.meetings.filter { local.contains($0.id) && processingSteps[$0.id] == nil })
        if !recovered.isEmpty {
            Self.logger.warning("Uygulama kayıt sürerken kapanmıştı, kaydedilen kısım işlenecek, kayıt sayısı: \(recovered.count, privacy: .public), en yeni: \(recovered.first ?? "", privacy: .public)")
            recoveredRecordingIDs.formUnion(recovered)
            await HostedAccount.shared.closeOrphanedMeeting()
        }
        // Sunucu oturumuna bağlı olmayan (çevrimdışı) yarım kayıt kuyruğa döner, bağlantı gelince kendi oturumuyla işlenir
        // (Mac'teki gibi); yeniden işlenseydi son geçiş "oturuma bağlı değil" diye atlanırdı. Sunucu oturumu kapatılırken
        // yeni kayıt başlamış olabilir: süren kayıt (ve klasörü bu okumadan sonra açılan) yarıda kalmış sayılmaz.
        let busy: Set<String> = busyMeetingIDs
        let stale: [MeetingRecord] = queuingUnlinkedInterrupted(
            records: staleStatusesToInterrupt(records: store.meetings.filter { local.contains($0.id) && !busy.contains($0.id) }).filter { processingSteps[$0.id] == nil },
            linkedRecordIDs: linked
        )
        for record in stale {
            do {
                let directory: URL = try store.sessionDirectory(id: record.id)
                guard record.status != .queued else {
                    Self.logger.info("Yarıda kalan çevrimdışı kayıt kuyruğa döndü, toplantı: \(record.id, privacy: .public)")
                    saveRecord(record: record, directory: directory)
                    continue
                }
                Self.logger.info("Yarıda kalan toplantı yeniden işleniyor, toplantı: \(record.id, privacy: .public), kayıt sürerken kesildi: \(self.recoveredRecordingIDs.contains(record.id), privacy: .public)")
                guard process(record: record.with(status: .processing, failureMessage: nil), directory: directory, finalPass: hostedFinalPassPlan) else {
                    continue
                }
                if record.id == recovered.first, phase == .idle {
                    // En son kesilen kayıt kayıt ekranında hazırlanırken görünür (hazırlık katmanı ve kartı); bitince
                    // toplantının sayfası açılır.
                    lastMeetingID = record.id
                    errorMessages = appendUnique(
                        messages: errorMessages, message: String(localized: "Kayıt, uygulama kapandığı için yarıda kesildi; o ana kadar kaydedilen kısım hazırlanıyor.")
                    )
                }
                submitContinuedProcessing(id: record.id, subtitle: continuedProcessingSubtitle(title: record.title, startedAt: record.startedAt))
            } catch {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
        }
        await runQueue()
        await retryFailedProcessing()
        startAutomaticRetryTimer()
    }

    /// İşlemesi geçici bir nedenle (ağ, askıya alma, sunucu 5xx, kapanmış oturum) başarısız biten toplantılar —
    /// işlemedeki hızlı denemelerden (`retryingFailedNote`) sonra da başarısız kalanlar — kullanıcı "Tekrar işle"ye
    /// basmadan yeniden işlenir (Mac'teki gibi): açılışta, uygulama öne gelince, ağ gelince (`queueTrigger`) ve uygulama
    /// açıkken `automaticRetryPollSec`'te bir; artan beklemeyle ve en çok `automaticRetryLimit` kez (bkz.
    /// `meetingsToRetryAutomatically`). Kalıcı başarısızlıklar (ses yok, dönüştürülemedi…) denenmez. İşleme kaldığı
    /// yerden sürer (son geçişin sonucu ve notun parçaları kaydedilmiştir): son geçiş yeniden faturalanmaz. Kayıt sürerken
    /// ve bağlantı yokken denenmez (deneme hakkı boşa gitmesin).
    func retryFailedProcessing() async {
        guard phase == .idle, network.isSatisfied else {
            return
        }
        let userID: String
        do {
            guard let signedIn = try await HostedAccount.shared.signedInUserID() else {
                return
            }
            userID = signedIn
        } catch {
            Self.logger.error("Yeniden deneme: oturum okunamadı, hata: \(String(describing: error), privacy: .private)")
            return
        }
        // Yüklü toplantılar giriş yapan hesabın değilse ya da hesap yerinde değiştiyse (bu kaydedici eski hesabın) hiçbiri
        // işlenmez: başka hesaba faturalanmaz.
        guard phase == .idle, isBoundAccountCurrent(signedInKey: accountDataKey(userId: userID)) else {
            return
        }
        let linked: Set<String>
        do {
            linked = try hostedLinkedRecordIDs()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            return
        }
        let candidates: [MeetingRecord] = store.meetings.filter { processingSteps[$0.id] == nil && !store.regeneratingIDs.contains($0.id) }
        for record in meetingsToRetryAutomatically(records: candidates, linkedRecordIDs: linked, now: Date()) {
            do {
                let directory: URL = try store.sessionDirectory(id: record.id)
                let retry: MeetingRecord = startingAutomaticRetry(record: record, now: Date())
                Self.logger.info("Başarısız işleme kendiliğinden yeniden deneniyor, toplantı: \(record.id, privacy: .public), deneme: \(retry.automaticRetries?.count ?? 0, privacy: .public)")
                process(record: retry, directory: directory, finalPass: hostedFinalPassPlan)
            } catch {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
        }
    }

    /// Vakti gelen kendiliğinden yeniden deneme uygulama açıkken `automaticRetryPollSec`'te bir yoklanır (bir kez kurulur;
    /// uygulama askıdayken görev de bekler).
    private func startAutomaticRetryTimer() {
        guard automaticRetryTask == nil else {
            return
        }
        automaticRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(automaticRetryPollSec))
                } catch {
                    return
                }
                await self?.retryFailedProcessing()
            }
        }
    }

    /// Sistemin sürdürme görevi (`ProcessingResumeScheduler`): yarıda kalan toplantılar işlenir ve süren işlemelerin
    /// (sıradaki bekleyen kayıtlar dahil) bitmesi beklenir. İşlenmeyi bekleyen toplantı kalmadıysa true; görev iptal
    /// edildiyse false.
    func resumeUnfinishedAndWait() async -> Bool {
        await resumeUnfinished()
        while let running = processingTasks.values.first {
            await running.value
            if Task.isCancelled {
                return false
            }
        }
        return processingSteps.isEmpty && !store.meetings.contains { (record: MeetingRecord) -> Bool in record.status == .processing }
    }

    /// Sistemin verdiği süre doldu: süren işlemeler iptal edilir (toplantılar diskte `processing` kalır ve kaldığı
    /// yerden sürer).
    func cancelProcessingForSystem() {
        for (id, task) in processingTasks {
            Self.logger.warning("İşleme sistem süresi dolduğu için iptal ediliyor, toplantı: \(id, privacy: .public)")
            task.cancel()
        }
    }

    /// Toplantıyı yeniden işler (Mac'teki "Tekrar işle"): son geçiş kaydın sunucu oturumu yeniden açılarak yapılır,
    /// not yeniden yazılır. Bekleyen (çevrimdışı) kayıt önce sunucu oturumunu almalı: kuyruktan işlenir. Kayıt sürerken,
    /// toplantı işlenirken, notu yazılırken ya da sesi silinmişse yapılmaz (hata fırlar).
    func reprocess(meetingID: String) throws {
        guard phase == .idle, let record = store.meetings.first(where: { $0.id == meetingID }), record.status != .recording,
              record.status != .processing, !record.audioDeleted, !store.regeneratingIDs.contains(meetingID), processingSteps[meetingID] == nil else {
            throw StorageError.writeFailed(path: meetingID, reason: "kayıtta, işleniyor ya da sesi yok")
        }
        if record.status == .queued {
            Task { await runQueue() }
            return
        }
        // Baştan yeniden işlenir: önceki işlemenin kontrol noktası ve son geçiş parçaları atılır, ses yeniden yazıya dökülür.
        let directory: URL = try store.sessionDirectory(id: meetingID)
        try discardProcessingProgress(directory: directory)
        process(record: record.with(status: .processing, failureMessage: nil), directory: directory, finalPass: hostedReprocessFinalPassPlan)
    }

    /// Bekleyen ilk toplantıyı (çevrimdışı kaydedilmiş ya da içe aktarılmış) işler (Mac'teki `runOfflineQueue`'nun karşılığı): kayıt yokken
    /// sunucu oturumu hazırlanır (bkz. `HostedAccount.prepareQueuedMeeting`), sonra son geçiş ve not o oturumla üretilir.
    /// Sunucuya hâlâ ulaşılamıyorsa bekler; sunucu şimdilik işlemiyorsa (deneme bitti, sınır) kayıt bekleyen kalır ve
    /// nedeni toplantıda görünür. Açılışta, uygulama öne gelince, ağ gelince ve hak durumu okununca (`queueTrigger`) ve
    /// her işleme bitince tetiklenir; birer birer işler.
    func runQueue() async {
        guard phase == .idle, !isRunningQueue else {
            return
        }
        isRunningQueue = true
        defer { isRunningQueue = false }
        let userID: String
        do {
            guard let signedIn = try await HostedAccount.shared.signedInUserID() else {
                return
            }
            userID = signedIn
        } catch {
            Self.logger.error("Kuyruk: oturum okunamadı, hata: \(String(describing: error), privacy: .private)")
            return
        }
        // Yüklü toplantılar giriş yapan hesabın değilse ya da hesap yerinde değiştiyse (bu kaydedici eski hesabın) hiçbiri
        // işlenmez: başka hesaba faturalanmaz.
        guard isBoundAccountCurrent(signedInKey: accountDataKey(userId: userID)) else {
            Self.logger.info("Kuyruk: yüklü toplantılar giriş yapan hesabın değil, işlenmedi")
            return
        }
        let queued: HostedQueuedRecords = hostedQueuedRecords(
            records: store.meetings.filter { processingSteps[$0.id] == nil }, owners: loadHostedRecordOwners(), userId: userID
        )
        for record in queued.foreign {
            noteQueued(recordID: record.id, notice: String(localized: "Bu kayıt başka bir hesapla yapıldı; o hesapla giriş yapınca işlenir."))
        }
        // Tetikleme başına en çok bir sunucu reddi (başlatma hız sınırı canlı kayda kalsın); ilk hazır olan işlenir.
        for record in hostedQueueCandidates(records: queued.own, rejections: queueRejections, now: Date(), cooldownSec: hostedQueueRejectionCooldownSec) {
            let recordID: String = record.id
            switch await HostedAccount.shared.prepareQueuedMeeting(recordID: recordID) {
            case .waitingForNetwork:
                return
            case .blocked(let reason):
                noteQueued(recordID: recordID, notice: reason)
            case .rejected(let reason):
                queueRejections[recordID] = Date()
                noteQueued(recordID: recordID, notice: reason)
                return
            case .ready:
                // Hazırlık sürerken kayıt başlamış ya da toplantı silinmiş olabilir.
                guard phase == .idle, let current = store.meetings.first(where: { $0.id == recordID }), current.status == .queued else {
                    return
                }
                do {
                    let directory: URL = try store.sessionDirectory(id: recordID)
                    Self.logger.info("Çevrimdışı kayıt işleniyor, toplantı: \(recordID, privacy: .public)")
                    process(record: current.with(status: .processing, failureMessage: nil).with(notice: nil), directory: directory, finalPass: hostedFinalPassPlan)
                } catch {
                    errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
                }
                return
            }
        }
    }

    /// "Şimdi dene" (Mac'teki gibi): bekleyen kaydı kendiliğinden yeniden denemeyi beklemeden kuyruğu hemen çalıştırır.
    /// Sunucunun bu kaydı az önce reddetmesinin bekleme süresi kullanıcının isteğiyle kalkar (tek kayıt, tek istek).
    func retryQueuedNow(meetingID: String) async {
        queueRejections[meetingID] = nil
        await runQueue()
    }

    /// Bekleyen kaydın işlenememe nedenini toplantıya yazar (değişmediyse dokunmaz).
    private func noteQueued(recordID: String, notice: String) {
        guard let current = store.meetings.first(where: { $0.id == recordID }), current.status == .queued, current.notice != notice else {
            return
        }
        do {
            saveRecord(record: current.with(notice: notice), directory: try store.sessionDirectory(id: recordID))
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    #if DEBUG
    /// `--ornek-kayit` (yalnız Debug, görsel kontrol): mikrofon ve bulut olmadan örnek bir canlı kayıt gösterir.
    func showSampleRecording() {
        // Çeviriler gerçek kayıttaki gibi not diline (çeviri hedefi) göre: İngilizce ya da Türkçe; başka dil için örnek
        // çeviri yok, satırlar çevirisiz görünür.
        let sampleTranslations: [String?] = switch phoneNoteLanguage() {
        case .english: [
            "Good morning, everyone, let's start the weekly meeting.",
            "The budget is ready now and goes to the board on Friday.",
            "Good. Who is taking care of the client presentation?",
        ]
        case .turkish: [
            "Herkese günaydın, haftalık toplantıya başlayalım.",
            "Bütçe hazır ve cuma günü yönetim kuruluna gidiyor.",
            "Güzel. Müşteri sunumunu kim üstleniyor?",
        ]
        default: [nil, nil, nil]
        }
        let sample: [(text: String, person: Int, translation: String?, isFinal: Bool)] = [
            ("Hyvää huomenta kaikille, aloitetaan viikkopalaveri.", 1, sampleTranslations[0], true),
            ("Budjetti on nyt valmis ja se lähtee hallitukselle perjantaina.", 1, sampleTranslations[1], true),
            ("Hyvä. Kuka hoitaa asiakasesityksen?", 2, sampleTranslations[2], true),
            ("Minä voin tehdä sen, kunhan saan luvut tiistaihin mennessä", 3, nil, false),
        ]
        transcript = sample.enumerated().map { (item: (offset: Int, element: (text: String, person: Int, translation: String?, isFinal: Bool))) -> LiveSegment in
            LiveSegment(
                id: SegmentID(speaker: .others, index: item.offset), startSec: Double(item.offset * 6), endSec: Double(item.offset * 6 + 5),
                text: item.element.text, isFinal: item.element.isFinal, failureMessage: nil, person: item.element.person
            )
        }
        translations = Dictionary(uniqueKeysWithValues: sample.enumerated().compactMap { (item: (offset: Int, element: (text: String, person: Int, translation: String?, isFinal: Bool))) -> (SegmentID, String)? in
            item.element.translation.map { (SegmentID(speaker: .others, index: item.offset), $0) }
        })
        lockedLanguage = .finnish
        startedAt = Date().addingTimeInterval(-754)
        levels.showSample(values: [0.1, 0.4, 0.7, 0.5, 0.9, 0.3, 0.6, 0.2, 0.8, 0.5])
        phase = .recording
        consentReminderVisible = true
        startActivity(startedAt: startedAt ?? Date(), title: String(localized: "Toplantı"))
        updateActivityNow(state: activityState())
    }

    /// `--ornek-duraklat` (yalnız Debug, görsel kontrol): örnek kayıt 40 sn önce duraklatılmış; bir cümlenin çevirisi
    /// alınamamış ("Tekrar dene").
    func showSamplePaused() {
        let failed: SegmentID = SegmentID(speaker: .others, index: 2)
        translations[failed] = nil
        failedTranslations = [failed]
        pauseClock = PauseClock.running.pausing(at: Date().addingTimeInterval(-40))
        updateActivityNow(state: activityState())
    }

    /// `--ornek-sinir` (yalnız Debug, görsel kontrol): örnek kayıt çevrimdışı sürüyor ve aylık sınır yüzünden 12 dakika
    /// sonra bitecek (iki bildirim birlikte).
    func showSampleLimits() {
        isOfflineRecording = true
        shortMeetingDeadline = Date().addingTimeInterval(12 * 60)
    }

    /// `--ornek-bitir` (yalnız Debug, görsel kontrol): örnek kayıt bitiriliyor durumunda kalır (oturum yok).
    func showSampleFinishing() {
        phase = .finishing
        stoppedAt = Date()
        levels.stop()
        updateActivityNow(state: activityState())
    }
    #endif

    // MARK: Oturum olayları

    private func handle(event: LiveSessionEvent, generation eventGeneration: Int) {
        guard eventGeneration == generation else {
            return
        }
        // Arka planda geçici bölümler bekletilir (ekran görünmez; her biri kayıt ekranını yeniden kurdururdu).
        let routing: BackgroundLiveRouting = routingLiveEvent(event: event, deferredPartials: deferredPartials, isInBackground: isInBackground)
        deferredPartials = routing.deferredPartials
        if routing.appliesNow {
            transcript = applyEvent(transcript: transcript, event: event)
        }
        switch event {
        case .segment(let segment):
            if segment.isFinal, !segment.text.isEmpty {
                // Dil, bölüm kesinleşince bir kez algılanır: sabit dilli kayıtta başka dildeki bölüm soluk görünür ve
                // toplantıdan atlanır.
                spokenLanguages[segment.id] = confidentSpokenLanguage(text: segment.text)
                addForTranslation(segment: segment, lane: .live)
                updateActivityThrottled()
            }
        case .languageLocked(let language):
            lockedLanguage = language
        case .captureEnded(let speaker):
            // Boş "Sen" akışının sonu beklenendir (yüz yüze kayıtta hemen biter); yalnız gerçekten ses veren akış
            // kayıt sürerken biterse mikrofon durmuştur: kayıt o ana dek kaydedilen sesle bitirilir ve işlenir.
            if isUnexpectedCaptureEnd(speaker: speaker, capturedSpeakers: Self.capturedSpeakers, isRecording: phase == .recording) {
                Self.logger.error("Mikrofon akışı kayıt sürerken bitti, kayıt bitiriliyor, konuşmacı: \(speaker.rawValue, privacy: .public)")
                errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Mikrofon beklenmedik şekilde durdu; kayıt o ana kadarki sesle bitirilip işleniyor."))
                stop()
            }
        case .recordingFailed(_, let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Ses diske yazılamadı: \(message)"))
        case .streamFailed(_, let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Canlı metin durdu: \(message)"))
        case .streamIncomplete(let speaker, let untranscribedSec):
            // iPhone'da ses "Diğerleri" akışındadır ve son geçişten her zaman geçer: eksik kalan son metin orada tamamlanır.
            Self.logger.warning("Canlı metnin sonu eksik, konuşmacı: \(speaker.rawValue, privacy: .public), süre: \(untranscribedSec, privacy: .public)")
        case .diarizationFailed(let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Konuşmacı ayırma başarısız: \(message)"))
        case .speakersAssigned:
            break
        case .liveEngineFellBack(let message):
            // iPhone hibrit oturum kullanmaz; olay gelirse yine görünür.
            errorMessages = appendUnique(messages: errorMessages, message: message)
        }
    }

    /// Oturum bitti (olay akışı bitti ya da kapanış bekçisi süreyi doldurdu): yarım çeviri birimleri çeviriye gider,
    /// bekleyen çeviriler (en fazla 10 sn) beklenir, toplantı saklanıp işlenir. Aynı kayıt için bir kez çalışır; başka
    /// kaydın (eski oturumun geç biten akışı) sonu yok sayılır.
    private func sessionEnded(sessionGeneration: Int) async {
        guard sessionGeneration == generation, endedGeneration != sessionGeneration else {
            Self.logger.info("Oturum sonu zaten işlendi ya da eski kayda ait, yok sayıldı")
            return
        }
        endedGeneration = sessionGeneration
        // Arka planda biten kayıtta bekletilen geçici bölümler de toplantıya girer (kesinleşmeden kalanlar).
        if !deferredPartials.isEmpty {
            transcript = applyingDeferredPartials(transcript: transcript, deferredPartials: deferredPartials)
            deferredPartials = [:]
        }
        flushAllUnits()
        let completed: Bool = await finishesWithin(seconds: 10) { [weak self] in
            while await self?.hasPendingTranslations() == true {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    // İptal: bekleme biter.
                    return
                }
            }
        }
        if !completed {
            Self.logger.warning("Kayıt sonunda bekleyen çeviriler süre içinde bitmedi")
        }
        // Başlamamış çeviriler artık başlamaz (oturum kapandı); kuyruk boşalmazsa bir sonraki kayda dek her 200 ms'de
        // bekleniyordu.
        translationQueue = .empty
        checkpointTask?.cancel()
        checkpointTask = nil
        diskSpaceTask?.cancel()
        diskSpaceTask = nil
        microphone.stop()
        levels.stop()
        endActivity()
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        cancelRecordingLimitNotifications()
        consentReminderVisible = false
        relatedTasks = []
        recordingCalendarMeeting = nil
        isOfflineRecording = false
        shortMeetingDeadline = nil
        guard let finished = active else {
            phase = .idle
            startedAt = nil
            stoppedAt = nil
            pauseClock = .running
            return
        }
        // Kapatılacak sunucu oturumu beklemeden önce alınır. Oturum kapanana dek kayıt "bitiyor"da kalır: bu arada yeni
        // kayıt başlayıp onun oturumunu ezmesin.
        let serverMeetingID: String? = HostedAccount.shared.currentMeeting?.meetingId
        do {
            // Not ve son geçiş sunucunun işleme süresinde (düzgün biten toplantıda 24 saat) aynı oturumla sürer.
            try await HostedAccount.shared.endMeeting(meetingID: serverMeetingID)
        } catch {
            Self.logger.error("Toplantı oturumu kapatılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Toplantı oturumu kapatılamadı: \(userFacingMessage(error: error))"))
        }
        phase = .idle
        active = nil
        // Biten kaydın geç çevirisi artık yazılmaz.
        generation += 1
        let record: MeetingRecord = liveRecord(recording: finished, status: .processing, endedAt: stoppedAt ?? Date())
        startedAt = nil
        stoppedAt = nil
        pauseClock = .running
        microphoneRecoveredNoticeVisible = false
        lastMeetingID = record.id
        Self.logger.info("Kayıt bitti, toplantı: \(record.id, privacy: .public), çevrimdışı: \(finished.offline, privacy: .public)")
        if finished.offline {
            // Çevrimdışı kayıt: ses ve canlı metin bu iPhone'da; son geçiş ve not bağlantı gelince (kayıt silinmez).
            saveRecord(
                record: record.with(status: .queued, failureMessage: nil).with(notice: String(localized: "Çevrimdışı kaydedildi; bağlantı gelince konuşmacılar ve not hazırlanır.")),
                directory: finished.directory
            )
            endBackgroundTask(id: record.id)
            return
        }
        process(record: record, directory: finished.directory, finalPass: hostedFinalPassPlan)
    }

    /// Toplantıyı işler (ses, son geçiş, not) ve saklar: son geçiş kaydın sunucu oturumuyla (`finalPass`: kaydın ardından
    /// ve sürdürmede `hostedFinalPassPlan`, "Tekrar işle"de `hostedReprocessFinalPassPlan`), not
    /// o oturumun bütçesinden (oturumu yoksa hesaptan; hakkı yoksa not yazılmaz ve nedeni toplantıda görünür). Uygulama
    /// arka plana geçerse iOS'tan ek süre istenir ve varsa sürdürülen işleme görevinin ilerlemesi güncellenir; süre
    /// yetmezse toplantı açılışta yeniden işlenir (`resumeUnfinished`). Aynı toplantı aynı anda iki kez işlenmez (çift
    /// ücret, aynı dosyaya iki yazar). İşleme başlatıldıysa true; toplantı zaten işleniyorsa false.
    @discardableResult
    private func process(
        record: MeetingRecord, directory: URL, finalPass resolveFinalPass: @escaping @Sendable ([String], String) async -> FinalPassPlan
    ) -> Bool {
        guard processingSteps[record.id] == nil else {
            Self.logger.warning("Toplantı zaten işleniyor, ikinci işleme başlatılmadı, toplantı: \(record.id, privacy: .public)")
            return false
        }
        saveRecord(record: record, directory: directory)
        processingSteps[record.id] = .convertingAudio
        beginBackgroundTask(id: record.id)
        processingTasks[record.id] = Task {
            // İşleme sırasında bağlantı koparsa ya da uygulama arka plana geçerse (sistem askıya alıp istekleri keser)
            // başarısız not yeniden denenir (bkz. `retryingFailedNote`).
            let networkLossesAtStart: Int = network.lossCount
            let backgroundEntriesAtStart: Int = backgroundEntries
            Self.logger.info("Toplantı işleniyor, toplantı: \(record.id, privacy: .public), bağlı: \(self.network.isSatisfied, privacy: .public), arka planda: \(self.isInBackground, privacy: .public)")
            let keyterms: [String] = keytermsWithAttendees(attendees: record.attendees ?? [], keyterms: phoneRecognitionKeyterms(store: store), limit: 30)
            let recordID: String = record.id
            // Son geçiş planı (sunucu oturumunu yeniden açma isteği) ve not sağlayıcısı ses dönüştürülürken hazırlanır:
            // ağ gidiş-dönüşü işlemeyi sırayla bekletmez (bkz. `processMeeting(record:directory:resolveFinalPass:resolveLLM:…)`).
            let processed: MeetingRecord = await processMeeting(
                record: record, directory: directory,
                resolveFinalPass: { () async -> FinalPassPlan in await resolveFinalPass(keyterms, recordID) },
                resolveLLM: { () async -> LLMProvider? in await self.recordedMeetingLLMReportingFailure(recordID: recordID) },
                languageMode: record.language.map { LanguageMode.fixed($0) } ?? .automatic, userName: store.userName, profile: store.userProfile,
                // The iPhone does not capture screens: notes are text only. Voiceprints are computed on this iPhone
                // (SpeakerKit) when voice recognition is on; they never leave the device.
                noteLanguage: phoneNoteLanguage(), voiceEmbedder: store.voices.embedderIfEnabled(), registry: store.voices.registered, screens: .off
            ) { (step: ProcessingStep) async -> Void in
                self.processingSteps[record.id] = step
                self.continuedTasks[record.id]?.progress.completedUnitCount = continuedProcessingCompletedUnits(step: step)
                if step == .writingNote {
                    self.noteWritingStartedAt[record.id] = .now
                }
            }
            let retried: MeetingRecord = await retryingFailedNote(
                result: processed, directory: directory, networkLossesSince: networkLossesAtStart, backgroundEntriesSince: backgroundEntriesAtStart
            )
            processingTasks[record.id] = nil
            guard !Task.isCancelled else {
                // Sistem görevi sona erdi: yarım sonuç saklanmaz; toplantı diskte `processing` kalır ve açılışta
                // kaldığı yerden işlenir (`resumeUnfinished`).
                Self.logger.warning("İşleme iptal edildi, toplantı açılışta yeniden işlenecek, toplantı: \(record.id, privacy: .public)")
                processingSteps[record.id] = nil
                endBackgroundTask(id: record.id)
                return
            }
            // Uygulama kayıt sürerken kapandıysa toplantıda neden kısa olduğu yazılır.
            let result: MeetingRecord = recoveredRecordingIDs.remove(record.id) == nil ? retried : withInterruptedRecordingNotice(record: retried)
            Self.logger.info("Toplantı işlendi, toplantı: \(record.id, privacy: .public), durum: \(result.status.rawValue, privacy: .public), not: \(result.note != nil, privacy: .public), son geçiş bölümü: \(result.finalSegments.count, privacy: .public)")
            recordNoteOutcome(result: result, writingStartedAt: noteWritingStartedAt.removeValue(forKey: record.id))
            // Tekrar işlemede eski not geçmişe girer (ilk işlemede not yoktur; Mac'teki gibi).
            let versioned: MeetingRecord = withNoteVersion(updated: result, previous: record, reason: String(localized: "Tekrar işlendi"), savedAt: Date())
            saveRecord(record: versioned, directory: directory)
            removeCheckpointIfDone(record: versioned, directory: directory)
            processingSteps[record.id] = nil
            onMeetingProcessed?(versioned)
            finishContinuedTask(meetingID: record.id, success: versioned.status == .done)
            // Son geçişin ses süresi aylık kullanıma sayılır: hesap durumu yenilenir.
            await HostedAccount.shared.refresh()
            endBackgroundTask(id: record.id)
            // Sıradaki bekleyen (çevrimdışı) kayıt.
            await runQueue()
        }
        return true
    }

    /// İşlenmiş toplantı "bitti" olarak saklandıysa işleme kontrol noktası silinir (not yazılamadıysa kalır: yarıda kalan
    /// işleme son geçişi yeniden yapmadan nottan sürer). Silinemezse loglanır; "Tekrar işle" onu yine atar.
    private func removeCheckpointIfDone(record: MeetingRecord, directory: URL) {
        guard record.status == .done else {
            return
        }
        do {
            try removeProcessingCheckpoint(directory: directory)
        } catch {
            Self.logger.error("İşleme kontrol noktası silinemedi, toplantı: \(record.id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// İşleme not adımında başarısız bittiyse (ses dönüştürüldü, yazıya dökülmüş metin var, not yok) not beklemeyle
    /// yeniden denenir (bkz. `shouldRetryMeetingNote`): istemcinin hızlı denemeleri birkaç saniyelik kopukluğa (toplantı
    /// odasından çıkarken Wi-Fi'dan hücresele geçiş) ya da uygulamanın arka planda askıya alınıp isteklerin kesilmesine
    /// yetmiyordu ve toplantı "başarısız" kalıyordu. Denemeden önce bağlantı beklenir (en çok 2 dk). Son geçiş yeniden
    /// yapılmaz (ses yeniden faturalanmasın): not son geçiş metninden, o yoksa canlı metinden yazılır. Her deneme
    /// loglanır; görev iptal edilirse eldeki sonuç döner (çağıran iptali işler).
    private func retryingFailedNote(result: MeetingRecord, directory: URL, networkLossesSince: Int, backgroundEntriesSince: Int) async -> MeetingRecord {
        var current: MeetingRecord = result
        var attempt: Int = 1
        var lossMark: Int = networkLossesSince
        var backgroundMark: Int = backgroundEntriesSince
        while !Task.isCancelled {
            let interrupted: Bool = network.lossCount != lossMark || backgroundEntries != backgroundMark || isInBackground || !network.isSatisfied
            let converted: Bool = !FileManager.default.fileExists(atPath: directory.appending(path: "others.caf").path)
            guard shouldRetryMeetingNote(result: current, audioConverted: converted, environmentInterrupted: interrupted, attempt: attempt) else {
                return current
            }
            let delay: Double = meetingNoteRetryDelaySec(attempt: attempt)
            Self.logger.warning("Not yazılamadı, yeniden denenecek, toplantı: \(current.id, privacy: .public), deneme: \(attempt, privacy: .public), bekleme: \(delay, privacy: .public) sn, bağlantı kesildi ya da arka plan: \(interrupted, privacy: .public)")
            do {
                try await Task.sleep(for: .seconds(delay))
                if try await !network.waitUntilSatisfied(limitSec: 120) {
                    Self.logger.warning("Not denemesinden önce bağlantı gelmedi, yine deneniyor, toplantı: \(current.id, privacy: .public)")
                }
            } catch {
                // İptal: işlemenin sistem görevi sona erdi; çağıran iptali işler (toplantı açılışta yeniden işlenir).
                return current
            }
            attempt += 1
            lossMark = network.lossCount
            backgroundMark = backgroundEntries
            processingSteps[current.id] = .writingNote
            noteWritingStartedAt[current.id] = .now
            current = await regenerateNote(
                record: current.with(status: .processing, failureMessage: nil), directory: directory, llm: recordedMeetingLLMReportingFailure(recordID: current.id),
                userName: store.userName, profile: store.userProfile, language: phoneNoteLanguage(), screens: .off
            )
            Self.logger.info("Not yeniden denendi, toplantı: \(current.id, privacy: .public), deneme: \(attempt, privacy: .public), durum: \(current.status.rawValue, privacy: .public)")
        }
        return current
    }

    /// Kaydı biten toplantının notu için sağlayıcı (bkz. `phoneRecordedMeetingLLMProvider`); kullanılamıyorsa nil ve neden
    /// kayıt ekranında görünür (not yazılmaz, sonra "Notu yenile" ile yazılabilir).
    private func recordedMeetingLLMReportingFailure(recordID: String) -> LLMProvider? {
        do {
            return try phoneRecordedMeetingLLMProvider(recordID: recordID)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Not yazılamadı: \(userFacingMessage(error: error))"))
            return nil
        }
    }

    // MARK: Asistan

    /// Kayıt sırasındaki asistan kartı ("Ne kaçırdım?" özeti ya da toplantıya sorulan sorunun cevabı; Mac'teki gibi).
    private(set) var assistantCard: AssistantCard?
    @ObservationIgnored private var assistantTask: Task<Void, Never>?
    /// Her istekte artar: yalnızca en son isteğin sonucu karta yazılır.
    @ObservationIgnored private var assistantRequestID: Int = 0

    /// Konuşmanın asistana giden metni: kaydın sabit dili dışındaki (atlanan) bölümler girmez.
    private var assistantTranscript: [LiveSegment] {
        let skipped: Set<SegmentID> = otherLanguageSegments
        return correctedTranscript.filter { !$0.text.isEmpty && !skipped.contains($0.id) }
    }

    /// Son N dakikanın (Ayarlar) not dilinde özeti ("Ne kaçırdım?"); o sürede konuşma yoksa istek atılmaz.
    func askWhatIMissed() {
        let minutes: Int = phoneMissedWindowMinutes()
        let nowSec: Double = transcript.map(\.endSec).max() ?? 0
        guard let request = missedSummaryRequest(segments: assistantTranscript, nowSec: nowSec, windowSec: Double(minutes * 60), language: phoneNoteLanguage()) else {
            cancelAssistant()
            assistantCard = .summary(MissedSummary(topic: String(localized: "Son \(minutes) dakikada konuşma yok."), decisions: [], askedOfYou: []))
            return
        }
        runAssistant(request: request, title: String(localized: "Ne kaçırdım?")) { (text: String) throws -> AssistantCard in
            .summary(try parseMissedSummary(text: text))
        }
    }

    /// Toplantıda konuşulanlara göre soru (cevap not dilinde); henüz konuşma yoksa istek atılmaz.
    func askDuringMeeting(question: String) {
        let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let request = questionRequest(segments: assistantTranscript, question: trimmed, language: phoneNoteLanguage()) else {
            cancelAssistant()
            assistantCard = .answer(question: trimmed, text: String(localized: "Henüz konuşma yok; sorular toplantıda konuşulanlara göre cevaplanır."))
            return
        }
        runAssistant(request: request, title: String(localized: "Cevap hazırlanıyor")) { (text: String) throws -> AssistantCard in
            .answer(question: trimmed, text: text)
        }
    }

    /// Kartı kapatır ve süren isteği iptal eder.
    func closeAssistantCard() {
        cancelAssistant()
        assistantCard = nil
    }

    /// Önceki isteği iptal edip yenisini kaydın canlı yapay zekâsıyla (toplantının sunucu oturumu) çalıştırır; sonucu
    /// yalnızca hâlâ en son istekse karta yazar. Canlı yapay zekâ bu kayıtta yoksa neden kartta görünür.
    private func runAssistant(request: LLMRequest, title: String, makeCard: @escaping @Sendable (String) throws -> AssistantCard) {
        cancelAssistant()
        guard let provider = active?.liveLLM else {
            assistantCard = .failed(message: String(localized: "Yapay zekâ bu kayıtta kullanılamıyor; not kayıt bitince yazılır."))
            return
        }
        let requestID: Int = assistantRequestID
        assistantCard = .loading(title: title)
        assistantTask = Task { [weak self] in
            let card: AssistantCard
            do {
                card = try await requestStructured(provider: provider, request: request, parse: makeCard)
            } catch {
                card = .failed(message: userFacingMessage(error: error))
            }
            guard let self, requestID == self.assistantRequestID, !Task.isCancelled else {
                return
            }
            self.assistantCard = card
        }
    }

    private func cancelAssistant() {
        assistantTask?.cancel()
        assistantTask = nil
        assistantRequestID += 1
    }

    // MARK: Dosya içe aktarma

    /// İçe aktarılmakta olan dosya sayısı (ses izi dönüştürülürken).
    private(set) var importingCount: Int = 0
    /// İçe aktarılamayan dosyalar ve nedenleri (Toplantılar'da görünür; yeni içe aktarma temizler).
    private(set) var importErrors: [String] = []

    /// Ses ya da video dosyalarını toplantı olarak içe aktarır (Mac'teki "İçe aktar"): ses izi `others.m4a` olur
    /// (kayıtla aynı biçim), toplantı bekleyen olarak kuyruğa girer; sunucu oturumu, son geçiş (konuşmacılar) ve not
    /// çevrimdışı kayıt gibi kuyrukta üretilir (haklar, deneme ve aylık süre sunucuda denetlenir). Dosyalar sırayla
    /// dönüştürülür; hepsi bitince döner. Kaynak dosyalara dokunulmaz (Dosyalar'dan seçilenler güvenlik kapsamıyla okunur).
    func importFiles(urls: [URL]) async {
        importErrors = []
        importingCount += urls.count
        for url in urls {
            await importOne(url: url)
            importingCount -= 1
        }
        await runQueue()
    }

    /// Paylaşım sayfasından gelen dosyaları içe aktarır (`importFiles` gibi); her dosyanın içe aktarması bitince
    /// `onImported` çağrılır (gelen kutusundaki kopya o an silinir). Uygulama kuyruk işlenirken kapanırsa kalan kopya yalnız
    /// henüz içe aktarılmamış dosyadır (açılışta yeniden bekler, `PhoneSharedFileInbox`); aynı toplantı iki kez oluşmaz.
    func importSharedFiles(urls: [URL], onImported: @MainActor (URL) -> Void) async {
        importErrors = []
        importingCount += urls.count
        for url in urls {
            await importOne(url: url)
            onImported(url)
            importingCount -= 1
        }
        await runQueue()
    }

    /// Uygulamadan yapılan aramanın indirilen kaydını içe aktarır (`importFiles` gibi): toplantı oluştuysa nil, olmadıysa
    /// bu dosyanın nedeni. Çağıran sağlayıcıdaki kopyayı yalnızca başarıda siler: içe aktarma başarısızsa kayıt orada
    /// kalır, yeniden denenir.
    func importCallRecording(url: URL) async -> String? {
        importErrors = []
        importingCount += 1
        let failure: String? = await importOne(url: url)
        importingCount -= 1
        await runQueue()
        return failure
    }

    /// Tek dosyayı içe aktarır; toplantı oluştuysa nil. Olmazsa yarım klasör silinir ve neden (dönüş değeri) listede de
    /// görünür.
    @discardableResult
    private func importOne(url: URL) async -> String? {
        let accessed: Bool = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var created: URL?
        do {
            let session: (url: URL, startedAt: Date) = try AppPaths.newExclusiveSessionDirectory(startedAt: Date())
            created = session.url
            let recordID: String = session.url.lastPathComponent
            // Uzun dosya dönüştürülürken uygulama arka plana geçerse iOS'tan ek süre istenir.
            beginBackgroundTask(id: recordID)
            defer { endBackgroundTask(id: recordID) }
            let duration: Double = try await importMediaAudio(source: url, destination: session.url.appending(path: "others.m4a"))
            let record: MeetingRecord = importedMeetingRecord(
                id: recordID, source: url, startedAt: session.startedAt, durationSec: duration, engine: .cloud,
                template: phoneNewMeetingNoteTemplate(title: url.deletingPathExtension().lastPathComponent)
            )
            // Toplantının ses hakkını aşan dosya kuyruğa alınmaz: son geçiş yarıda kalır, bekleyen kayıt hiç bitmezdi.
            // Hak durumu okunamadıysa sunucu son geçişte denetler.
            if case .signedIn(let entitlements) = HostedAccount.shared.state {
                try requireHostedImportFits(durationSec: duration, entitlements: entitlements)
            }
            // Kayıt giriş yapan hesaba yazılır: kuyruk yalnız o hesabın kayıtlarını işler (başka hesaba faturalanmaz).
            try await HostedAccount.shared.claimQueuedRecord(recordID: recordID)
            Self.logger.info("Dosya içe aktarıldı, toplantı: \(recordID, privacy: .public), süre: \(Int(duration), privacy: .public)")
            saveRecord(
                record: record.with(status: .queued, failureMessage: nil).with(notice: String(localized: "İçe aktarıldı; sunucuda işlenmeyi bekliyor.")),
                directory: session.url
            )
            return nil
        } catch {
            Self.logger.error("Dosya içe aktarılamadı, hata: \(String(describing: error), privacy: .private)")
            let message: String = String(localized: "\(url.lastPathComponent) içe aktarılamadı: \(mediaImportMessage(error: error))")
            importErrors = appendUnique(messages: importErrors, message: message)
            if let created {
                do {
                    try FileManager.default.removeItem(at: created)
                } catch {
                    Self.logger.error("Yarım içe aktarma klasörü silinemedi, hata: \(String(describing: error), privacy: .private)")
                }
            }
            return message
        }
    }

    // MARK: Arka plan

    /// Toplantı için iOS'tan arka planda çalışma süresi ister (kapanış ve işleme). Zaten varsa yenisi açılmaz. Süre
    /// dolarsa görev bitirilir (iOS uygulamayı sonlandırmasın); toplantı `processing` kalır ve açılışta kaldığı yerden
    /// işlenir (`resumeUnfinished`).
    private func beginBackgroundTask(id: String) {
        guard backgroundTasks[id] == nil else {
            return
        }
        backgroundTasks[id] = UIApplication.shared.beginBackgroundTask(withName: "AINotepad.\(id)") { [weak self] in
            MainActor.assumeIsolated {
                Self.logger.warning("Arka plan süresi doldu, toplantı açılışta ya da sistemin sürdürme göreviyle işlenecek, toplantı: \(id, privacy: .public)")
                ProcessingResumeScheduler.shared.schedule(reason: "arka plan süresi doldu")
                self?.endBackgroundTask(id: id)
            }
        }
    }

    private func endBackgroundTask(id: String) {
        guard let task = backgroundTasks.removeValue(forKey: id) else {
            return
        }
        UIApplication.shared.endBackgroundTask(task)
    }

    // MARK: Sürdürülen işleme

    /// Toplantının işlenmesi için iOS'tan sürdürülen işleme görevi ister: uygulamadan çıkılsa da işleme sistemin
    /// ilerleme arayüzüyle sürer. İstek reddedilirse (desteklenmiyor, kullanıcı arka plan çalışmasını kapattı, uygulama
    /// önde değil, sistem yoğun) uyarı loglanır ve işleme arka plan süresiyle (`beginBackgroundTask`) sürer; süre
    /// yetmezse açılışta yeniden işlenir.
    private func submitContinuedProcessing(id: String, subtitle: String) {
        let identifier: String = continuedProcessingIdentifier(suffix: UUID().uuidString)
        // Joker kalıbın (`<önek>.*`) kendisine işleyici kaydedilemez; her istek kendi tekil kimliğiyle kaydedilir.
        // Sürdürülen işleme görevleri açılış bittikten sonra da kaydedilebilir. İşleyici ana kuyrukta (ana aktörde)
        // çalışır.
        let registered: Bool = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] (task: BGTask) -> Void in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.attachContinuedTask(task: task, meetingID: id)
        }
        guard registered else {
            Self.logger.warning("Sürdürülen işleme görevi kaydedilemedi, işleme arka plan süresiyle sürecek, toplantı: \(id, privacy: .public), görev: \(identifier, privacy: .public)")
            return
        }
        let request: BGContinuedProcessingTaskRequest = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: String(localized: "Not hazırlanıyor"), subtitle: subtitle
        )
        // Sistem yoğunsa istek sıraya girer; işleme o arada uygulamada sürer, görev başlayınca ona bağlanır.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.logger.info("Sürdürülen işleme görevi istendi, toplantı: \(id, privacy: .public), görev: \(identifier, privacy: .public)")
        } catch {
            Self.logger.warning("Sürdürülen işleme görevi reddedildi, işleme arka plan süresiyle sürecek, toplantı: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Sistem görevi başladı: toplantının işlenmesine bağlanır (ilerleme, süre dolunca iptal). İşleme görev başlamadan
    /// bittiyse ya da toplantıya zaten bir görev bağlıysa yeni görev hemen tamamlanır (bağlı olanın yerine geçmez:
    /// sahipsiz kalan görevin süresi dolunca süren işleme iptal edilirdi).
    private func attachContinuedTask(task: BGTask, meetingID: String) {
        guard let continued = task as? BGContinuedProcessingTask else {
            Self.logger.error("Beklenmeyen arka plan görevi türü, görev: \(task.identifier, privacy: .public)")
            task.setTaskCompleted(success: false)
            return
        }
        guard continuedTasks[meetingID] == nil else {
            Self.logger.warning("Toplantıya zaten sürdürülen işleme görevi bağlı, yeni görev bitiriliyor, toplantı: \(meetingID, privacy: .public), görev: \(task.identifier, privacy: .public)")
            continued.setTaskCompleted(success: false)
            return
        }
        // Kapanış (mikrofon kapandı, oturum bitiyor) ya da işleme sürüyor.
        let running: Bool = processingSteps[meetingID] != nil || active?.directory.lastPathComponent == meetingID
        guard running else {
            let success: Bool = store.meetings.first { (record: MeetingRecord) -> Bool in record.id == meetingID }?.status == .done
            Self.logger.info("İşleme sistem görevi başlamadan bitti, toplantı: \(meetingID, privacy: .public)")
            continued.setTaskCompleted(success: success)
            return
        }
        continued.progress.totalUnitCount = continuedProcessingTotalUnits
        continued.progress.completedUnitCount = continuedProcessingCompletedUnits(step: processingSteps[meetingID])
        // Sistem işleyiciyi hangi kuyrukta çağıracağını belirtmez: ana aktöre geçilir.
        continued.expirationHandler = { @Sendable [weak self] () -> Void in
            Task { @MainActor in
                self?.expireContinuedTask(meetingID: meetingID)
            }
        }
        continuedTasks[meetingID] = continued
        Self.logger.info("Sürdürülen işleme görevi başladı, toplantı: \(meetingID, privacy: .public)")
    }

    /// Sistem görevinin süresi doldu ya da kullanıcı onu sistem arayüzünden durdurdu: işleme iptal edilir, toplantı
    /// `processing` kalır ve açılışta yeniden işlenir (`resumeUnfinished`).
    private func expireContinuedTask(meetingID: String) {
        guard let task = continuedTasks.removeValue(forKey: meetingID) else {
            return
        }
        Self.logger.warning("Sürdürülen işleme sona erdi, işleme iptal ediliyor, toplantı: \(meetingID, privacy: .public)")
        processingTasks[meetingID]?.cancel()
        ProcessingResumeScheduler.shared.schedule(reason: "sürdürülen işlemenin süresi doldu")
        task.setTaskCompleted(success: false)
    }

    /// İşleme bitti: varsa sistem görevi tamamlanır.
    private func finishContinuedTask(meetingID: String, success: Bool) {
        guard let task = continuedTasks.removeValue(forKey: meetingID) else {
            return
        }
        task.progress.completedUnitCount = continuedProcessingTotalUnits
        task.setTaskCompleted(success: success)
    }

    // MARK: Canlı etkinlik

    /// Canlı etkinlikteki son satır: son kesinleşen cümle ve konuşmacısı.
    private var activityLine: (text: String, speaker: String) {
        guard let last = correctedTranscript.last(where: { $0.isFinal && !$0.text.isEmpty }) else {
            return ("", "")
        }
        return (last.text, last.person.map { speakerLabel(speaker: last.id.speaker, person: $0) } ?? "")
    }

    /// Canlı etkinliğin şimdiki durumu: son cümle, bitiriliyor mu, mikrofon bekleniyor mu, duraklatıldı mı, süre durduysa
    /// anı ve duraklatılan süre (sayaç duraklatmayı saymaz).
    private func activityState() -> RecordingActivityAttributes.ContentState {
        let line: (text: String, speaker: String) = activityLine
        return RecordingActivityAttributes.ContentState(
            lastLine: line.text, speaker: line.speaker, isFinishing: phase == .finishing, isMicrophonePaused: microphoneStatus != .running,
            stoppedAt: stoppedAt, pausedAt: pauseClock.pausedAt, pausedSec: pauseClock.completedSec
        )
    }

    /// Kilit ekranı ve Dynamic Island'da kaydı gösterir. Kullanıcı canlı etkinlikleri kapattıysa gösterilmez (loglanır);
    /// kayıt etkilenmez. Süre etkinlikte sistem saatiyle akar (`Text(timerInterval:)`); güncellemeler yalnız metin ve
    /// durum içindir.
    private func startActivity(startedAt: Date, title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.info("Canlı etkinlikler kapalı; kayıt kilit ekranında ve Dynamic Island'da gösterilmiyor")
            return
        }
        // Uygulama kayıt sırasında kapanıp yeniden açıldıysa kalan eski etkinlik Dynamic Island'da yer tutmasın.
        let previous: [String] = Activity<RecordingActivityAttributes>.activities.map(\.id)
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(startedAt: startedAt, title: title),
                content: activityContent(state: activityState()),
                pushType: nil
            )
            lastActivityUpdate = .distantPast
            Self.logger.info("Canlı etkinlik başladı, önceki etkinlik sayısı: \(previous.count, privacy: .public)")
        } catch {
            Self.logger.error("Canlı etkinlik başlatılamadı, hata: \(String(describing: error), privacy: .private)")
        }
        guard !previous.isEmpty else {
            return
        }
        Task.detached {
            for stale in Activity<RecordingActivityAttributes>.activities where previous.contains(stale.id) {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Canlı etkinliği en fazla 2 sn'de bir günceller (her cümlede çağrılır; sistem sık güncellemeyi kısar).
    private func updateActivityThrottled() {
        guard Date().timeIntervalSince(lastActivityUpdate) >= 2 else {
            return
        }
        // Durum yalnızca güncellenecekse kurulur: uzun kayıtta (saatlerce, binlerce bölüm) her cümlede tüm transkripti
        // dolaşmasın.
        updateActivityNow(state: activityState())
    }

    /// Canlı etkinliği hemen günceller (kayıt başladı, bitiyor, sessizlikte tazeleme).
    private func updateActivityNow(state: RecordingActivityAttributes.ContentState) {
        guard let activity else {
            return
        }
        lastActivityUpdate = Date()
        let id: String = activity.id
        Task.detached {
            // Etkinlik görev içinde kimliğiyle bulunur (ana aktörden başka göreve geçirilmez).
            for running in Activity<RecordingActivityAttributes>.activities where running.id == id {
                await running.update(activityContent(state: state))
            }
        }
    }

    /// Uygulama kayıt sırasında kapandıysa kilit ekranında kalan canlı etkinlik kaldırılır (kayıt yokken çağrılır).
    private func endStaleActivities() {
        guard phase == .idle, activity == nil else {
            return
        }
        Task.detached {
            for stale in Activity<RecordingActivityAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Kayıt bitti: canlı etkinlik kalkar.
    private func endActivity() {
        guard let activity else {
            return
        }
        self.activity = nil
        let id: String = activity.id
        Task.detached {
            for running in Activity<RecordingActivityAttributes>.activities where running.id == id {
                await running.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: Çeviri

    /// Sabit toplantı dilinden başka dildeki bölümler (kayıt ekranında soluk): dili algılanan ve çevrilmeyen birimlerdeki.
    var otherLanguageSegments: Set<SegmentID> {
        otherLanguageSegmentIDs(spokenLanguages: spokenLanguages, fixedLanguage: recordingFixedLanguage).union(languageSkippedSegments)
    }

    /// Kesinleşmiş bölümü çeviri birimlerine ekler (Mac'teki gibi): tamamlanan birimler (cümle sonu, süre ya da uzunluk
    /// sınırı) çeviriye gider; yarım birim konuşmacı susunca (`liveTranslationUnitLimits.idleSec`) çevrilir. Toplantı
    /// not dilindeyse metin olduğu gibi kalır.
    private func addForTranslation(segment: LiveSegment, lane: TranslationLane) {
        // Canlı çeviri Ayarlar'dan kapatıldıysa yalnız orijinal metin akar (not yine not dilinde yazılır).
        guard phoneLiveTranslationEnabled() else {
            return
        }
        // Toplantı not dilindeyse aynı dile çeviri yapılmaz: orijinal tek başına görünür (LLM'e gitmez).
        guard needsLiveTranslation(spoken: lockedLanguage ?? fixedMeetingLanguage(mode: languageMode), noteLanguage: phoneNoteLanguage()) else {
            return
        }
        guard let provider = active?.liveLLM else {
            return
        }
        do {
            let language: MeetingLanguage? = lockedLanguage ?? fixedMeetingLanguage(mode: languageMode)
            try requireOnDeviceLanguages(provider: provider, meetingLanguages: language.map { [$0] } ?? [], outputLanguage: phoneNoteLanguage())
        } catch {
            // Cihaz içi model bu dili anlamıyor: bozuk çeviri yerine açık mesaj (bir kez).
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Çeviri: \(userFacingMessage(error: error))"))
            return
        }
        let step: TranslationUnitStep = addingFinal(
            builder: unitBuilder, segment: segment, nowSec: translationUnitClockSeconds(), limits: liveTranslationUnitLimits
        )
        unitBuilder = step.builder
        step.ready.forEach { (unit: TranslationUnit) -> Void in enqueueTranslation(unit: unit, lane: lane) }
        scheduleIdleFlush(speaker: segment.id.speaker)
    }

    /// Konuşmacının yarım birimi varsa sessizlik süresi sonunda çevrilmek üzere bekletir (önceki bekleme iptal edilir).
    private func scheduleIdleFlush(speaker: Speaker) {
        idleFlushTasks[speaker]?.cancel()
        idleFlushTasks[speaker] = nil
        guard !unitBuilder.pendingSegments(speaker: speaker).isEmpty else {
            return
        }
        let flushGeneration: Int = generation
        idleFlushTasks[speaker] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(liveTranslationUnitLimits.idleSec))
            } catch {
                // İptal: konuşmacıdan yeni bölüm geldi (bekleme yeniden kuruldu) ya da kayıt bitti ya da yenisi başladı.
                return
            }
            self?.flushIdleUnits(speaker: speaker, generation: flushGeneration)
        }
    }

    /// Sessizlik süresi dolan yarım birimleri çeviriye gönderir.
    private func flushIdleUnits(speaker: Speaker, generation flushGeneration: Int) {
        guard flushGeneration == generation else {
            return
        }
        idleFlushTasks[speaker] = nil
        let step: TranslationUnitStep = flushingIdle(builder: unitBuilder, nowSec: translationUnitClockSeconds(), limits: liveTranslationUnitLimits)
        unitBuilder = step.builder
        step.ready.forEach { (unit: TranslationUnit) -> Void in enqueueTranslation(unit: unit, lane: .live) }
        // Süre saat payı yüzünden henüz dolmadıysa bekleme yeniden kurulur: yarım birim takılı kalmaz.
        scheduleIdleFlush(speaker: speaker)
    }

    /// Kayıt sonu: sessizlik beklemeleri iptal edilir, bütün yarım birimler çeviriye gider.
    private func flushAllUnits() {
        idleFlushTasks.values.forEach { $0.cancel() }
        idleFlushTasks = [:]
        let step: TranslationUnitStep = flushingAll(builder: unitBuilder)
        unitBuilder = step.builder
        step.ready.forEach { (unit: TranslationUnit) -> Void in enqueueTranslation(unit: unit, lane: .live) }
    }

    /// Birimi kaydın birimlerine ekleyip çeviri sırasına alır. Metni sabit toplantı dilinden başka dildeyse çevrilmez
    /// (toplantıdan zaten atlanır; maliyet), bölümleri soluk kalır.
    private func enqueueTranslation(unit: TranslationUnit, lane: TranslationLane) {
        if isOtherLanguageUnit(unit: unit, fixedLanguage: recordingFixedLanguage) {
            languageSkippedSegments.formUnion(unit.segmentIDs)
            Self.logger.info("Başka dildeki birim çevrilmedi, birim sonu: \(segmentKey(id: unit.carrierID), privacy: .public), bölüm sayısı: \(unit.segmentIDs.count, privacy: .public)")
            return
        }
        translationUnits.append(unit)
        queueTranslation(unit: unit, lane: lane)
    }

    /// Kaydın birimlerindeki birimi `lane` yolunda çeviri sırasına alır (ilk çeviri ya da "Tekrar dene").
    private func queueTranslation(unit: TranslationUnit, lane: TranslationLane) {
        translationQueue = translationQueue.adding(job: unit, lane: lane)
        startQueuedTranslations()
    }

    private func startQueuedTranslations() {
        guard let provider = active?.liveLLM else {
            return
        }
        while translationsInFlight < Self.maxParallelTranslations,
              let next = translationQueue.next(
                  backlogInFlight: backlogTranslationIDs.count, backlogSlots: backlogTranslationSlots(maxParallel: Self.maxParallelTranslations)
              ) {
            translationQueue = next.queue
            let unit: TranslationUnit = next.job
            let context: [String] = translationContext(units: translationUnits, before: unit, count: translationContextUnits)
            let requestGeneration: Int = generation
            let id: UUID = UUID()
            if next.lane == .backlog {
                backlogTranslationIDs.insert(id)
            }
            translationsInFlight += 1
            Task {
                do {
                    let translated: String = try await translateSentence(provider: provider, sentence: unit.text, context: context, language: phoneNoteLanguage())
                    recordFeatureUsage(feature: .liveTranslation(phoneNoteLanguage()))
                    // Cümle zaten not dilindeyse (model aynen döndürdü) çeviri saklanmaz: aynı cümle iki kez görünmesin.
                    if requestGeneration == generation {
                        if isDistinctTranslation(original: unit.text, translated: translated) {
                            translations = applyingUnitTranslation(translations: translations, unit: unit, translation: translated)
                        }
                        failedTranslations.subtract(unit.segmentIDs)
                    }
                } catch {
                    Self.logger.error("Çeviri başarısız, birim sonu: \(segmentKey(id: unit.carrierID), privacy: .public), bölüm sayısı: \(unit.segmentIDs.count, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                    if requestGeneration == generation {
                        // Cümle kaybolmasın: kayıt ekranında "Tekrar dene"de kalır.
                        failedTranslations.formUnion(unit.segmentIDs)
                        errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Çeviri: \(userFacingMessage(error: error))"))
                    }
                }
                translationsInFlight -= 1
                backlogTranslationIDs.remove(id)
                startQueuedTranslations()
            }
        }
    }

    private func hasPendingTranslations() -> Bool {
        translationsInFlight > 0 || !translationQueue.isEmpty
    }

    // MARK: Saklama

    /// Canlı transkript ve çevirilerden toplantı kaydı.
    private func liveRecord(recording: ActiveRecording, status: MeetingStatus, endedAt: Date?) -> MeetingRecord {
        let base: MeetingRecord = MeetingRecord(
            id: recording.directory.lastPathComponent, title: recording.linkedMeeting?.title ?? String(localized: "Toplantı"), startedAt: recording.startedAt, endedAt: endedAt,
            language: lockedLanguage, status: status, failureMessage: nil,
            liveSegments: storedSegments(transcript: correctedTranscript, spokenLanguages: spokenLanguages), finalSegments: [],
            translations: Dictionary(uniqueKeysWithValues: translations.map { (segmentKey(id: $0.key), $0.value) }),
            speakerNames: [:], note: nil, audioDeleted: false, engine: recording.engine, notice: nil, meNeedsFinalPass: nil
        )
        .with(highlights: highlights)
        .with(myNotes: myNotes)
        .with(template: recording.template)
        // Sabit dil kayda yazılır: başka dildeki bölümler toplantı okunurken atlanır.
        .with(fixedLanguage: recordingFixedLanguage)
        // Mac'teki gibi: takvim etkinliğine bağlı kayıt katılımcıları ve etkinlik kimliğini taşır.
        return recording.linkedMeeting.map { base.with(attendees: $0.attendees).with(calendarEventID: $0.id) } ?? base
    }

    /// Kayıt sürerken her 30 sn'de transkript saklanır: uygulama kapanırsa metin toplantıda kalır.
    private func startCheckpoints() {
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // İptal: kayıt bitti.
                    return
                }
                guard let self, self.phase == .recording, let recording = self.active else {
                    return
                }
                self.saveCheckpoint(record: self.liveRecord(recording: recording, status: .recording, endedAt: nil), directory: recording.directory)
                // Sessizlikte de canlı etkinlik tazelenir: uygulama kapanırsa 2 dk sonra eskimiş görünür, saymayı sürdürmez.
                self.updateActivityNow(state: self.activityState())
            }
        }
    }

    /// Kontrol noktası: anlık görüntü burada (ana aktörde) alınır ve listeye yansır; kodlama ve atomik yazım arka planda,
    /// sırayla (4 saatlik toplantıda ana iş parçacığında yüzlerce ms sürebiliyordu). Kaydın bitişindeki yazım daha yeni
    /// sıradadır: arka plandaki eski görüntü onun üstüne yazılmaz.
    private func saveCheckpoint(record: MeetingRecord, directory: URL) {
        checkpointWriter.write(record: record, directory: directory) { [weak self] (error: any Error) -> Void in
            Self.logger.error("Kontrol noktası yazılamadı, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            guard let self else {
                return
            }
            self.errorMessages = appendUnique(messages: self.errorMessages, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
        store.upsert(record: record)
    }

    // MARK: Boş yer

    /// Kayıt öncesi boş yer yeniden okunur (kayıt sekmesi açılınca, uygulama öne gelince, kayıt başlarken). Okunamazsa
    /// loglanır ve önceki durum kalır (kayıt sırasındaki denetim yine çalışır).
    func refreshRecordingDiskSpace() {
        do {
            let available: Int64 = try availableCapacityForImportantUsage(directory: try AppPaths.sessionsDirectory())
            recordingDiskSpace = AINotepadCore.recordingDiskSpace(
                availableBytes: available, expectedDurationSec: expectedRecordingSec, streams: Self.capturedSpeakers.count
            )
        } catch {
            Self.logger.error("Boş yer okunamadı, hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Kayıt sürerken boş yer `diskSpaceCheckIntervalSec`'te bir denetlenir: iPhone dolmadan kayıt temiz biçimde bitirilir;
    /// o ana kadar kaydedilen her şey saklanır ve işlenir (`.m4a` dönüştürmesi ve işleme için yer ayrılır). Uygulama arka
    /// planda ya da telefon kilitliyse yerel bildirimle haber verilir.
    private func startDiskSpaceWatch(directory: URL, startedAt: Date) {
        diskSpaceTask?.cancel()
        let watchGeneration: Int = generation
        diskSpaceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(diskSpaceCheckIntervalSec))
                } catch {
                    // İptal: kayıt bitti ya da yenisi başladı.
                    return
                }
                guard let self, self.phase == .recording, watchGeneration == self.generation else {
                    return
                }
                self.stopRecordingIfDiskFull(directory: directory, startedAt: startedAt)
            }
        }
    }

    private func stopRecordingIfDiskFull(directory: URL, startedAt: Date) {
        let available: Int64
        do {
            available = try availableCapacityForImportantUsage(directory: directory)
        } catch {
            Self.logger.error("Kayıt sürerken boş yer okunamadı, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return
        }
        let streams: Int = Self.capturedSpeakers.count
        let recordedSec: Double = Date().timeIntervalSince(startedAt)
        guard shouldStopRecordingForDiskSpace(availableBytes: available, recordedSec: recordedSec, streams: streams, checkIntervalSec: diskSpaceCheckIntervalSec) else {
            return
        }
        Self.logger.warning("iPhone'da yer kalmadı, kayıt bitiriliyor, boş bayt: \(available, privacy: .public), süre: \(recordedSec, privacy: .public)")
        let message: String = String(localized: "Diskte yer kalmadığı için kayıt bitirildi; o ana kadar kaydedilenler saklandı ve not hazırlanıyor.")
        errorMessages = appendUnique(messages: errorMessages, message: message)
        recordingDiskSpace = .full
        stop()
        if isInBackground {
            Task { await notifyRecordingStoppedForDiskSpace(body: message) }
        }
    }

    private func saveRecord(record: MeetingRecord, directory: URL) {
        do {
            try saveMeeting(record: record, directory: directory)
            store.upsert(record: record)
        } catch {
            Self.logger.error("Toplantı kaydedilemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }
}

/// Sabit dil seçiliyse o dil; otomatikte nil. Saf fonksiyondur.
func fixedMeetingLanguage(mode: LanguageMode) -> MeetingLanguage? {
    guard case .fixed(let language) = mode else {
        return nil
    }
    return language
}

/// Hemen biten boş ses akışı (yüz yüze kayıtta "Sen" akışı yerine).
private func finishedAudioStream() -> AsyncStream<[Float]> {
    let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    continuation.finish()
    return stream
}

/// Sürdürülen işleme görevlerinin kimlik öneki; Info.plist'teki `BGTaskSchedulerPermittedIdentifiers` joker kalıbı
/// (`<önek>.*`, project.yml) ile aynı olmalı.
private let continuedProcessingIdentifierPrefix: String = "com.senoldogan.AINotepad.hosted.process"

/// Sürdürülen işleme görevinin tekil kimliği. Saf fonksiyondur.
private func continuedProcessingIdentifier(suffix: String) -> String {
    "\(continuedProcessingIdentifierPrefix).\(suffix)"
}

/// Sistem ilerlemesinin toplam birimi: işleme adımları (ses, son geçiş, not).
private let continuedProcessingTotalUnits: Int64 = Int64(ProcessingStep.allCases.count)

/// Adım başladığında tamamlanmış birim (önceki adımlar); işleme başlamadıysa 0. Saf fonksiyondur.
private func continuedProcessingCompletedUnits(step: ProcessingStep?) -> Int64 {
    Int64(step?.rawValue ?? 0)
}

/// Sistem görevinin alt başlığı: toplantının adı ve başlangıç saati ("Toplantı · 14:30"). Saf fonksiyondur.
private func continuedProcessingSubtitle(title: String, startedAt: Date) -> String {
    "\(title) · \(startedAt.formatted(date: .omitted, time: .shortened))"
}

/// Canlı etkinliğin eskimiş sayılma süresi: kayıt 30 sn'de bir tazeler; uygulama kapanırsa kilit ekranında saymayı
/// sürdürmez.
private let activityStaleSec: TimeInterval = 120

/// Kayıt etkinliğinin önceliği: başka uygulamaların canlı etkinlikleri de varken (ör. bir sohbet ya da yolculuk
/// uygulaması) sistem Dynamic Island'da en yüksek önceliklisini gösterir; varsayılan 0'da kayıt geri planda kalıyordu.
private let activityRelevanceScore: Double = 100

/// Canlı etkinliğin içeriği: durum, eskime anı ve öncelik.
private func activityContent(state: RecordingActivityAttributes.ContentState) -> ActivityContent<RecordingActivityAttributes.ContentState> {
    ActivityContent(state: state, staleDate: Date().addingTimeInterval(activityStaleSec), relevanceScore: activityRelevanceScore)
}
