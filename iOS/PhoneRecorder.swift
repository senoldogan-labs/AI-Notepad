import ActivityKit
import AINotepadCore
import AINotepadUI
import BackgroundTasks
import Foundation
import os
import UIKit
import WidgetKit

/// Kaydın görünen durumu (`RecorderState`'in ekranlar için özeti).
enum RecorderPhase: Equatable {
    case idle
    case starting
    case recording
    /// Mikrofon kapandı; Deepgram ve konuşmacı ayırma son bölümleri bitiriyor.
    case finishing
}

/// Kaydın durumundan ekranların gösterdiği aşama. Saf fonksiyondur.
func recorderPhase(state: RecorderState) -> RecorderPhase {
    switch state {
    case .idle, .failed:
        .idle
    case .starting:
        .starting
    case .recording:
        .recording
    case .finishing:
        .finishing
    }
}

/// Süren kaydın oturum verisi (durumu `RecorderState`'te).
private struct ActiveRecording {
    let id: RecordingID
    let directory: URL
    let startedAt: Date
    let handle: LiveSessionHandle
    /// Canlı çeviri: kaydın sunucu oturumunun bütçesinden (`hostedMeetingLLMProvider`); çevrimdışı kayıtta ya da
    /// kullanılamıyorsa nil (neden kayıt ekranında görünür).
    let liveLLM: LLMProvider?
    /// Canlı metnin başladığı motor: bulut (Deepgram) ya da bu iPhone (Apple konuşma tanıma). Son geçiş her durumda
    /// sunucudadır.
    let engine: RecordingEngine
    /// Kaydın bağlandığı takvim etkinliği (başlık ve katılımcılar kayda geçer); yoksa nil.
    let linkedMeeting: CalendarMeeting?
    /// Notun şablonu: kayıt başlarken Ayarlar'daki varsayılan ya da takvim etkinliğinin adına göre seçilen (kayıt
    /// sırasında değişmez).
    let template: NoteTemplate
    /// Duraklatma: duraklatılan ses akıştan atılır (dosyaya yazılmaz, yazıya dökülmez); mikrofon açık kalır.
    let pauseGate: RecordingPauseGate
    /// Kayıt başında hesaplanan süre sınırı ve sınırı en çok ne kadar duraklatmanın ileri itebileceği (toplantının en
    /// uzun süresi; sunucudaki sınırla aynı). Duraklatılan süre sınıra sayılmaz (bkz. `currentRecordingDeadline`).
    let limitDeadline: Date
    let maxPauseSec: Double
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
    /// Kapanışta sunucu oturumunun kapanması için en uzun bekleme: aşılırsa kapanış arka planda sürer, kayıt
    /// "Bitiriliyor"da takılı kalmaz.
    private static let serverEndLimitSec: Double = 20
    /// Mikrofon yeniden ses verince bildirimin ekranda kalma süresi.
    private static let recoveryNoticeSec: Double = 4

    /// Kaydın durumu: tek kaynak; her değişiklik `send` ile `recorderStep`ten geçer.
    private(set) var state: RecorderState = .idle {
        didSet {
            // Denetim Merkezi'ndeki aç/kapa düğmesi kaydın durumunu göstersin.
            if recorderPhase(state: oldValue) != recorderPhase(state: state) {
                ControlCenter.shared.reloadControls(ofKind: recordControlKind)
            }
        }
    }
    /// Kayıt başlamak üzere (oturum bağlar): Sor alanındaki sesle soru bırakılır. Ses oturumu tektir; dikte mikrofonu
    /// kaydınkini açtıktan sonra kapansaydı oturumu kapatıp kaydı keserdi.
    @ObservationIgnored var onRecordingWillStart: (@MainActor () -> Void)?
    /// Ekranların gösterdiği aşama.
    var phase: RecorderPhase {
        recorderPhase(state: state)
    }
    /// Süren kaydın kimliği (bildirimler ve kilit ekranı eylemleri bunu taşır); kayıt yoksa nil.
    var recordingID: RecordingID? {
        state.activeID
    }
    private(set) var transcript: [LiveSegment] = []
    /// Kullanıcının kayıt sırasında yaptığı konuşmacı düzeltmeleri (otomatik ayırmanın üstüne uygulanır; Mac'teki gibi).
    private(set) var speakerCorrections: SpeakerCorrections = .none
    private(set) var translations: [SegmentID: String] = [:]
    /// Çevirisi başarısız bölümler (kayıt ekranında "Tekrar dene").
    private(set) var failedTranslations: Set<SegmentID> = []
    /// Duraklatma saati (kayıt ekranındaki ve canlı etkinlikteki süre duraklatılan zamanı saymaz).
    var pauseClock: PauseClock {
        state.clock
    }
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
    /// Kaydın başladığı an (mikrofon açılınca); kayıt yoksa nil.
    var startedAt: Date? {
        state.startedAt
    }
    /// İşlenen toplantıların adımı (kimlik → adım; toplantı işleri depoda tek haritadadır, bkz. `PhoneStore.meetingJobs`).
    var processingSteps: [String: ProcessingStep] {
        store.processingSteps
    }
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
    var isOfflineRecording: Bool {
        state.server == .offline
    }
    /// Aylık sınıra az kaldığı için sunucunun kısalttığı toplantının bitiş anı: kayıt ekranında kalan dakika (Mac'teki
    /// `shortMeetingDeadline`); olağan süredeki toplantıda nil.
    private(set) var shortMeetingDeadline: Date?
    let levels: AudioLevels = AudioLevels(count: 36, interval: 0.08)

    @ObservationIgnored private let store: PhoneStore
    @ObservationIgnored private let microphone: MicrophoneCapture = MicrophoneCapture(input: roomAudioInputRequest)
    /// Mikrofonun durumu: kesinti (çağrı, alarm) ya da yeniden bağlanma kayıt ekranında ve canlı etkinlikte görünür;
    /// her iki durumda kayıt açık kalır ve ses gelince kendiliğinden sürer.
    private(set) var microphoneStatus: MicrophoneStatus = .running
    /// Mikrofon kesinti ya da yeniden kurmadan sonra yeniden ses veriyor: kayıt ekranında birkaç saniye bildirim.
    private(set) var microphoneRecoveredNoticeVisible: Bool = false
    /// Kayıtta kullanılan mikrofon girişi (kayıt ekranındaki hızlı seçim adını gösterir); kayıt yokken nil.
    private(set) var audioInput: ActiveAudioInput?
    /// Kısa süreli mikrofon bildirimi (başka girişe geçildi, saklanan seçim okunamadı): kayıt ekranında
    /// `audioInputNoticeSec` boyunca; yoksa nil. Seçilen giriş kullanılamıyorsa ekran bunu ayrıca durum sürdükçe gösterir.
    private(set) var audioInputNotice: AudioInputNotice?
    @ObservationIgnored private var audioInputNoticeTask: Task<Void, Never>?
    /// "Bitir"e basılan an (ya da mikrofonun beklenmedik sonu): süre burada durur, bitirme sürerken saymaz.
    var stoppedAt: Date? {
        if case .finishing(let finishing) = state {
            return finishing.stoppedAt
        }
        return nil
    }
    /// Toplantı bitmiş gibi (takvim bitti ya da uzun sessizlik): kayıt ekranında "Toplantı bitti mi?" sorulur; yanıtlanınca
    /// ya da kayıt bitince nil.
    private(set) var meetingOverPrompt: MeetingOverReason?
    /// Bu kayıtta sorulan "Toplantı bitti mi?" nedenleri (her neden bir kez).
    @ObservationIgnored private var askedMeetingOver: Set<MeetingOverReason> = []
    /// Son konuşmanın (kesinleşen metin), kayıt başının ya da sürdürmenin anı: uzun sessizlik buna göre ölçülür.
    @ObservationIgnored private var lastActivityAt: Date = Date()
    /// Kayıt sürerken 30 sn'de bir: canlı etkinliği tazeler (kilit ekranı eskimesin), "kayıt durmuş olabilir" bildirimini
    /// erteler ve toplantının bitip bitmediğine bakar.
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private let notifier: MeetingNotifier = MeetingNotifier()
    @ObservationIgnored private var recoveryNoticeTask: Task<Void, Never>?
    /// "Bitir"den sonra canlı oturum takılırsa kaydı yine de kapatan bekçi (bkz. `watchFinishing`).
    @ObservationIgnored private var finishingWatchdogTask: Task<Void, Never>?
    /// Cihaz içi konuşma modelinin indirme ilerlemesi (0…1) kayıt başlarken; indirme yoksa nil.
    private(set) var speechModelProgress: Double?
    /// Cihaz içi konuşma tanıma motoru (Deepgram kullanılamazsa canlı metin bununla; model kayıtlar arasında bellekte kalır).
    @ObservationIgnored private let speechEngine: AppleSpeechEngine = AppleSpeechEngine()
    /// The on-device live preview's engine (installed models only; never downloads mid-meeting).
    @ObservationIgnored private let previewEngine: InstalledAppleSpeechEngine = InstalledAppleSpeechEngine()
    /// The current recording's live text: its route ("Diğerleri", the microphone; moved to the local engine on cloud
    /// fallback) and whether it stopped (`liveTextStep`); nil before the first recording of this launch.
    private(set) var liveText: LiveTextState?

    /// The live text is written on this iPhone right now (on-device live preview, not stopped): the live screen's empty
    /// state says so.
    var isLivePreviewOnDevice: Bool {
        liveText.map(liveTextOnDevice(state:)) ?? false
    }
    /// Toplantının süre sınırını izleyen görev (bkz. `watchRecordingLimit`).
    @ObservationIgnored private var recordingLimitTask: Task<Void, Never>?
    /// Süre sınırı bildirimlerinin kurulduğu sınır; sınır değişince (duraklatma onaylandı) yeniden kurulur.
    @ObservationIgnored private var scheduledLimitDeadline: Date?
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
    /// Sistemin ilerleme arayüzüyle süren işleme görevleri (anahtar: toplantı kimliği). Değerler
    /// `BGContinuedProcessingTask` (iOS 26+; eski sürümde görev istenmez, sözlük boş kalır).
    @ObservationIgnored private var continuedTasks: [String: BGTask] = [:]
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

    /// Why a recording cannot start now (checked in this order); nil when it can. `start()` refuses for exactly these, and
    /// the Watch's "Start on iPhone" reports the same reason. Reads the free disk space first.
    func startRefusal() -> PhoneStartRefusal? {
        let account: HostedAccount = HostedAccount.shared
        if account.requiresSignIn {
            return .signInRequired
        }
        if !phoneAIConsentGiven(account: account) {
            return .aiConsentMissing
        }
        if let message = phoneStartBlockMessage(account: account, now: Date()) {
            return .planBlocked(message: message)
        }
        refreshRecordingDiskSpace()
        if recordingDiskSpace == .full {
            return .diskFull
        }
        return nil
    }

    /// Kaydı başlatır. Giriş yapılmamışsa, yapay zekâ açıklaması kabul edilmemişse ya da hak durumu kaydı engelliyorsa
    /// (deneme bitti, aylık sınır…) hiçbir şey başlamaz ve neden görünür. Mikrofon açılınca ses hemen diske yazılır,
    /// sonra kaydın sunucu oturumu açılır; sunucu reddederse kayıt başlamaz ve yazılan ses silinir.
    func start() async {
        // Kayıt sürerken ya da başlatılırken yinelenen istek (Kısayollar, Denetim Merkezi, bildirim) bir şey yapmaz: başlatma
        // istekleri süren başlatmayı asla iptal etmez.
        guard state.isIdle else {
            return
        }
        let account: HostedAccount = HostedAccount.shared
        switch startRefusal() {
        case .signInRequired:
            // Giriş kapısının ikinci savunması: kısayol, Denetim Merkezi ve Eylem düğmesi kapıyı açmadan çağırabilir.
            Self.logger.info("Giriş yapılmadan kayıt istendi, başlatılmadı")
            errorMessages = appendUnique(messages: [], message: phoneStartRefusalText(refusal: .signInRequired))
            return
        case .aiConsentMissing:
            Self.logger.info("Yapay zekâ açıklaması onaylanmadan kayıt istendi, başlatılmadı")
            errorMessages = appendUnique(messages: [], message: phoneStartRefusalText(refusal: .aiConsentMissing))
            return
        case .planBlocked:
            // Neden kayıt kartının altındaki plan notunda görünür (`PhonePlanNotice`); hata listesine ikinci kez yazılmaz
            // (abone olunca da orada kalırdı).
            Self.logger.info("Hak durumu kaydı engelliyor, başlatılmadı")
            errorMessages = []
            // Deneme bitti ya da plan sona erdi: abonelik ekranı açılır.
            if account.requiresSubscription {
                account.requestSubscriptionToRecord()
            }
            return
        case .diskFull:
            // Diskte kısa bir kayda bile yer yoksa kayıt başlamaz (başlar başlamaz bitirilirdi); az yer kayıt kartında uyarılır.
            Self.logger.warning("Diskte yer yok, kayıt başlatılmadı")
            errorMessages = appendUnique(messages: [], message: phoneStartRefusalText(refusal: .diskFull))
            return
        case nil:
            break
        }
        let id: RecordingID = RecordingID(rawValue: UUID().uuidString)
        guard send(event: .startRequested(id: id, micMuted: false)).contains(.beginStart(id: id)) else {
            return
        }
        // Sor alanındaki sesle soru mikrofonu kayıt ses oturumunu açmadan önce kapanır (oturum kuyruğunda sıra korunur).
        onRecordingWillStart?()
        meetingOverPrompt = nil
        askedMeetingOver = []
        generation += 1
        finishingWatchdogTask?.cancel()
        finishingWatchdogTask = nil
        microphoneStatus = .running
        microphoneRecoveredNoticeVisible = false
        clearAudioInput()
        // Saklanan seçim okunamıyorsa bir kez silinir ve kayıt başında söylenir ("Otomatik" kullanılıyor).
        if resetUnreadableAudioInputChoice(defaults: .standard) {
            showAudioInputNotice(notice: .storedChoiceUnreadable)
        }
        transcript = []
        deferredPartials = [:]
        speakerCorrections = .none
        translations = [:]
        failedTranslations = []
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
        liveText = nil
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
            send(event: .startFailed(id: id))
            return
        }
        let audio: AsyncStream<[Float]>
        let pauseGate: RecordingPauseGate
        do {
            let origin: ContinuousClock.Instant = .now
            microphone.onStatusChange = { [weak self] (status: MicrophoneStatus) -> Void in
                self?.microphoneStatusChanged(status: status)
            }
            microphone.onInputChange = { [weak self] (input: ActiveAudioInput) -> Void in
                self?.microphoneInputChanged(input: input)
            }
            // Duraklatma hizalanmış akışta süzülür: kesinti sonrası sessizlik dolgusu da duraklatılan aralığa düşüyorsa
            // atılır; mikrofon duraklatmada kapanmaz (yakalama yeniden kurulmaz, ikinci dinleyici takılmaz).
            pauseGate = RecordingPauseGate(sampleRate: 16000, origin: origin)
            send(event: .awaitingCapture(id: id))
            let aligned: AsyncStream<[Float]> = clockAlignedStream(audio: try await microphone.start(), origin: origin, sampleRate: 16000, thresholdSec: 0.5)
            audio = pausableStream(audio: aligned, gate: pauseGate)
        } catch {
            // "Bitir" izin penceresi açıkken geldi: mikrofon açılmadı (`MicrophoneCapture.start` iptal etti); hata değil.
            if isStarting(id: id), !isStartAbortRequested {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
            // Mikrofon açılamadı (izin yok, ses oturumu, başlarken bitirildi): boş toplantı klasörü kalmasın.
            send(event: .startFailed(id: id))
            discardUnstartedRecording(directory: directory)
            return
        }
        // "Bitir" mikrofon açılırken geldiyse kayıt burada bırakılır: sunucu oturumu açılmaz (deneme hakkı yanmaz).
        send(event: .captureOpened(id: id, at: started))
        guard isStarting(id: id) else {
            Self.logger.info("Kayıt başlarken bitirildi, mikrofon kapatıldı, sunucu oturumu açılmadı")
            discardUnstartedRecording(directory: directory)
            return
        }
        // Canlı etkinlik mikrofon açılır açılmaz başlar (sunucu ve canlı motor beklenmeden): kayıt kilit ekranında ve
        // Dynamic Island'da hemen görünür; arka planda (Denetim Merkezi, Kısayollar) başlatılan kayıt da öyle.
        startActivity(recordingID: id, startedAt: started, title: linkedMeeting?.title ?? String(localized: "Toplantı"))
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
        let server: RecordingServerSession
        let shortDeadline: Date?
        do {
            let requestedAt: Date = Date()
            switch try await account.startMeeting(recordID: directory.lastPathComponent) {
            case .online(let meeting):
                deadline = hostedRecordingDeadline(requestedAt: requestedAt, maxDurationMinutes: meeting.maxDurationMinutes, serverEndsAt: meeting.expiresAt)
                server = .online(meetingID: meeting.meetingId)
                // Aylık sınıra az kaldıysa toplantı olağandan kısadır: kalan dakika kayıt ekranında görünür.
                shortDeadline = isShortenedHostedMeeting(started: meeting) ? deadline : nil
            case .offline(let maxMinutes):
                // Sunucuya ulaşılamadı: kayıt sürer (canlı metin bu iPhone'da), süre son bilinen hak durumuyla sınırlı;
                // toplantı bağlantı gelince işlenir (bkz. `runQueue`).
                deadline = requestedAt.addingTimeInterval(Double(maxMinutes) * 60)
                server = .offline
                shortDeadline = nil
            }
        } catch {
            Self.logger.error("Toplantı oturumu açılamadı, kayıt başlatılmadı, hata: \(String(describing: error), privacy: .private)")
            if isStarting(id: id), !isStartAbortRequested {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
                // Sunucu abonelik istedi (deneme bitti, abonelik gerekli, deneme bu cihazda kullanıldı): abonelik ekranı açılır.
                if let apiError = error as? HostedAPIError, let code = apiError.code, hostedSubscriptionRequiredCodes.contains(code) {
                    account.requestSubscriptionToRecord()
                }
            }
            // Ret aylık sınırdan ya da denemenin bitmesinden olabilir: hesap ekranı güncellensin.
            Task { await account.refresh() }
            send(event: .startFailed(id: id))
            discardUnstartedRecording(directory: directory)
            return
        }
        // "Kaydı sil" (ya da mikrofon açılmadan "Bitir") sunucu oturumu açılırken geldiyse kayıt bırakılır ve açılan oturum
        // kapatılır (toplantı oluşmaz; bkz. `abandonStart`). "Bitir" kaydı korur: kayıt başlayınca bitirilip işlenir.
        send(event: .serverStarted(id: id, server: server))
        guard isStarting(id: id) else {
            Self.logger.info("Kayıt sunucu oturumu açılırken iptal edildi, oturum kapatılıyor, klasör siliniyor")
            discardUnstartedRecording(directory: directory)
            return
        }
        // The microphone track is re-transcribed by the final pass: on-device preview when the user is in the rollout and
        // the language's model is installed; otherwise the server's cloud stream, and this iPhone if that is unavailable.
        let choice: HostedLiveChoice = await hostedLiveChoice(
            language: speechLanguage,
            keyterms: keytermsWithAttendees(attendees: linkedMeeting?.attendees ?? [], keyterms: phoneRecognitionKeyterms(store: store), limit: 30),
            liveSpeakers: Self.capturedSpeakers,
            localSpeechAvailable: appleSpeechSupportedBySystem()
        )
        liveText = LiveTextState(routes: choice.routes, liveSpeakers: Self.capturedSpeakers, stopped: [:])
        Self.logger.info("Canlı yol seçildi, yol: \(String(describing: choice.routes.others), privacy: .public)")
        // The on-device preview never downloads mid-meeting; the cloud fallback engine prepares (and may download) the model.
        let localConfig: LiveSessionConfig = LiveSessionConfig(
            languageMode: .fixed(speechLanguage), segmenter: .live, recordingDirectory: directory, partialIntervalSec: 1.5,
            minPartialSpeechSec: 1.0, languageLockAfterSec: 30, candidateLanguages: [speechLanguage]
        )
        let previewEngine: InstalledAppleSpeechEngine = self.previewEngine
        let handle: LiveSessionHandle = runSplitHybridLiveSession(
            config: HybridLiveSessionConfig(
                speakers: Self.capturedSpeakers,
                // iPhone tek akış kaydeder (mikrofon, "Diğerleri"): sonradan katılan konuşmacı yok.
                lateSpeakers: [],
                local: localConfig,
                maxPendingAudioSec: 600,
                // iOS 18–25'te cihaz içi tanıma yok: bulut akışı kopunca yeniden bağlanılır (cihaza geçilmez).
                cloudFailure: hybridCloudFailure(localSpeechAvailable: appleSpeechSupportedBySystem(), reconnectDelaysSec: cloudReconnectDelaysSec)
            ),
            start: choice.start,
            onDeviceSpeakers: choice.onDeviceSpeakers,
            preview: OnDevicePreviewEngine(local: localConfig, engine: { () async throws -> any TranscriptionEngine in previewEngine }),
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
            id: id, directory: directory, startedAt: started, handle: handle, liveLLM: liveLLM, engine: choice.routes.others == .cloud ? .cloud : .local,
            linkedMeeting: linkedMeeting, template: phoneNewMeetingNoteTemplate(title: linkedMeeting?.title ?? ""),
            pauseGate: pauseGate, limitDeadline: deadline, maxPauseSec: max(0, deadline.timeIntervalSince(started))
        )
        self.active = active
        recordingCalendarMeeting = linkedMeeting
        shortMeetingDeadline = shortDeadline
        // Uygulama kayıt sırasında kapanırsa toplantı açılışta bulunup işlenir.
        saveRecord(record: liveRecord(recording: active, status: .recording, endedAt: nil), directory: directory)
        startCheckpoints()
        startDiskSpaceWatch(directory: directory, startedAt: started)
        lastActivityAt = started
        startHeartbeat()
        scheduledLimitDeadline = deadline
        consentReminderVisible = UserDefaults.standard.bool(forKey: PhoneSettingsKey.consentReminder)
        relatedTasks = linkedMeeting.map { (meeting: CalendarMeeting) -> [RelatedOpenTask] in
            relatedOpenTasks(meeting: meeting, records: store.meetings, userName: store.userName, before: started)
        } ?? []
        Self.logger.info("Kayıt başladı, klasör: \(directory.lastPathComponent, privacy: .public), çevrimdışı: \(server == .offline, privacy: .public)")
        let sessionGeneration: Int = generation
        Task { [weak self] in
            for await event in handle.events {
                self?.handle(event: event, generation: sessionGeneration)
            }
            self?.send(event: .sessionDrained(id: id, at: Date()))
        }
        // Başlarken istenenler burada uygulanır: kesinti sürüyorsa kayıt duraklatılmış başlar; başlatılırken "Bitir"
        // geldiyse kayıt hemen bitirilip işlenir, "Kaydı sil" geldiyse silinerek bitirilir (bkz. `recorderStep`).
        send(event: .sessionStarted(id: id, at: Date()))
        guard case .recording = state, state.activeID == id else {
            return
        }
        watchRecordingLimit()
        updateActivityNow(state: activityState())
        Task {
            await scheduleRecordingLimitNotifications(deadline: deadline, warningLeadSec: hostedLimitWarningLeadSec)
            // Kayıt bu arada bittiyse geç kurulan bildirim kalmasın.
            if self.state.isIdle {
                cancelRecordingLimitNotifications()
            }
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

    /// Toplantının şimdiki süre sınırı: kayıt başındaki sınır, duraklatılan süre kadar ileri (en çok toplantının en uzun
    /// süresi kadar). Sunucu bitişin tek kaynağıdır: çevrimiçi kayıtta yalnızca sunucunun onayladığı duraklatma sayılır;
    /// çevrimdışı kayıtta (sunucu oturumu yok) yerel duraklatma saati. Kayıt yoksa nil.
    private func currentRecordingDeadline(now: Date) -> Date? {
        guard let active else {
            return nil
        }
        // Kaydın kendi sunucu oturumu (başlarken açılan; oturum kapansa da kimliği kayıtta kalır).
        guard let serverMeetingID = state.server?.meetingID else {
            return pausedRecordingDeadline(deadline: active.limitDeadline, pause: pauseClock, maxPauseSec: active.maxPauseSec, now: now)
        }
        return active.limitDeadline.addingTimeInterval(
            HostedAccount.shared.confirmedPauseSec(meetingID: serverMeetingID, now: now, maxPauseSec: active.maxPauseSec)
        )
    }

    /// Duraklatma bildirimlerinin uyarısını kayıt ekranında gösterir (yoksa kaldırır).
    private func showPauseConfirmation() {
        guard let serverMeetingID = state.server?.meetingID else {
            return
        }
        let text: String? = pauseConfirmationText(confirmation: HostedAccount.shared.pauseConfirmation(meetingID: serverMeetingID))
        let stale: [String] = pauseConfirmationTexts().filter { $0 != text }
        if errorMessages.contains(where: { stale.contains($0) }) {
            errorMessages.removeAll { stale.contains($0) }
        }
        if let text {
            errorMessages = appendUnique(messages: errorMessages, message: text)
        }
    }

    /// Toplantının süre sınırından 5 dk önce kayıt ekranında uyarı, sınırda kayıt "Bitir"e basılmış gibi bitirilir ve
    /// normal işlenir (Mac'teki gibi). Duraklatılan süre sınırı ileri iter. Kayıt bitince (ya da yenisi başlayınca) görev
    /// kendiliğinden sona erer.
    private func watchRecordingLimit() {
        recordingLimitTask?.cancel()
        let limitGeneration: Int = generation
        recordingLimitTask = Task { [weak self] in
            var warned: Bool = false
            while !Task.isCancelled {
                guard let self, self.phase == .recording, limitGeneration == self.generation, let deadline = self.currentRecordingDeadline(now: Date()) else {
                    return
                }
                if self.shortMeetingDeadline != nil, self.shortMeetingDeadline != deadline {
                    self.shortMeetingDeadline = deadline
                }
                self.showPauseConfirmation()
                // Kilit ekranı bildirimleri sınır duruyorken, o sınırla kurulur (sınır değişince yeniden). Sınır ilerlerken
                // (onaylanmış duraklatma sayılırken: duraklatmada ya da sürdürme sunucuya henüz varmadığında, en çok
                // duraklatma hakkı dolana dek) kurulmaz: sınır o sürede gelemez, eski sınırla kurulan bildirim erken
                // çıkardı. Duraklatma onaylanmadıysa ya da hak dolduysa sınır durur ve bildirimler kurulu kalır.
                let now: Date = Date()
                let isMoving: Bool = self.currentRecordingDeadline(now: now.addingTimeInterval(1)).map { $0.timeIntervalSince(deadline) > 0.5 } ?? false
                if isMoving {
                    if self.scheduledLimitDeadline != nil {
                        self.scheduledLimitDeadline = nil
                        cancelRecordingLimitNotifications()
                    }
                } else if self.scheduledLimitDeadline.map({ abs($0.timeIntervalSince(deadline)) > 1 }) ?? true {
                    self.scheduledLimitDeadline = deadline
                    Task { await scheduleRecordingLimitNotifications(deadline: deadline, warningLeadSec: hostedLimitWarningLeadSec) }
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
    /// canlı etkinlik) çağrılırsa: mikrofon açılıyorsa (izin penceresi) hiç açılmaz ve kayıt başlamaz; mikrofon açıldıysa
    /// kaydedilen ses korunur, kayıt başlar başlamaz bitirilip işlenir (uygulamadaki "Bitir" gibi). `target`: bildirim ve kilit ekranı eylemleri kendi kaydını hedefler
    /// (başka kaydınki yok sayılır).
    func stop(target: RecorderTarget) {
        send(event: .stopRequested(target: target, at: Date()))
    }

    /// Süren kaydı bitirir (uygulamadaki "Bitir", süre sınırı, mikrofonun beklenmedik sonu, yer kalmadı).
    func stop() {
        stop(target: .current)
    }

    /// Kaydın durumu `start(id:)` adımı mı (başlatma sürüyor ve bırakılmadı).
    private func isStarting(id: RecordingID) -> Bool {
        if case .starting(let starting) = state {
            return starting.id == id
        }
        return false
    }

    /// Başlatılırken iptal istendi ("Kaydı sil" ya da mikrofon açılmadan "Bitir"): başlatmanın hatası gösterilmez. Mikrofon
    /// açıldıktan sonraki "Bitir"de kayıt korunmak istenir; korunamazsa (sunucu reddi) neden görünür.
    private var isStartAbortRequested: Bool {
        if case .starting(let starting) = state {
            return starting.intents.cancel
        }
        return false
    }

    /// Olayı durum makinesinden geçirir ve çıkan işleri sırayla yürütür; yürütülen işleri döndürür.
    @discardableResult
    private func send(event: RecorderEvent) -> [RecorderEffect] {
        let step: RecorderStep = recorderStep(state: state, event: event, finishingLimitSec: Self.finishingLimitSec)
        state = step.state
        step.effects.forEach { perform(effect: $0) }
        return step.effects
    }

    /// Durum makinesinin bir işini yürütür (mikrofon, canlı etkinlik, sunucu oturumu, dosyalar).
    private func perform(effect: RecorderEffect) {
        switch effect {
        case .beginStart:
            // Başlatmayı `start` yürütür (olayı gönderdikten hemen sonra).
            break
        case .cancelCapture:
            // Mikrofon açılırken (izin penceresi, ses oturumu): `MicrophoneCapture.start` motoru kurmadan iptal eder.
            Self.logger.info("Kayıt başlarken bitirme istendi, mikrofon açılışı iptal ediliyor")
            microphone.stop()
        case .abandonStart(let id, let server):
            abandonStart(id: id, server: server)
        case .applyMicMuted:
            // iPhone'da "Sen" ayrı akış değildir: odadaki herkes mikrofondan gelir.
            break
        case .setAudioPaused(_, let paused, _):
            setAudioPaused(paused: paused)
        case .reportPause(let meetingID, let paused):
            HostedAccount.shared.reportPause(meetingID: meetingID, paused: paused)
        case .stopCapture(let id, let discard):
            stopCapture(id: id, discard: discard)
        case .scheduleFinishDeadline(let id, let deadline):
            watchFinishing(id: id, deadline: deadline)
        case .cancelLiveSession(let id):
            cancelLiveSession(id: id)
        case .close(let id, let server):
            Task { await close(id: id, server: server) }
        case .complete(let id, let server, let discard, let stoppedAt):
            complete(id: id, server: server, discard: discard, stoppedAt: stoppedAt)
        case .dismissStaleIndicators:
            // Kayıt yokken bitir/duraklat/sürdür (kilit ekranı, Denetim Merkezi): uygulama kayıt sırasında kapandıysa
            // kalan canlı etkinlik kalkar.
            endStaleActivities()
        }
    }

    /// Başlamayan kayıt bırakılır: mikrofon, ses çubukları ve canlı etkinlik kapanır; sunucu oturumu açıldıysa kapatılır
    /// (deneme ya da aylık süre boşa akmasın, 0 sn'lik toplantı oluşmasın). Klasörü başlatma siler.
    private func abandonStart(id: RecordingID, server: RecordingServerSession?) {
        Self.logger.info("Kayıt başlamadı, bırakılıyor, kayıt: \(id.rawValue, privacy: .public)")
        microphone.stop()
        levels.stop()
        endActivity()
        // Sunucu oturumu açıldıysa kapatılır; çevrimdışı başladıysa hesabın çevrimdışı kayıt durumu biter (`nil`).
        guard let server, server != .local else {
            return
        }
        let meetingID: String? = server.meetingID
        Task {
            do {
                try await HostedAccount.shared.endMeeting(meetingID: meetingID)
                Self.logger.info("Başlamayan kaydın sunucu oturumu kapatıldı")
            } catch {
                // Kimlik açık oturumlar listesinde kalır; yetim kapatma (ağ gelince, öne gelince, açılışta) kapatır.
                Self.logger.warning("Başlamayan kaydın sunucu oturumu kapatılamadı, sonra yeniden denenecek, hata: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// "Bitir": mikrofon kapanır; canlı oturum kalan bölümleri bitirir (bkz. `close`). `discard` ("Kaydı sil"): not
    /// hazırlanmayacak; sistem ilerleme görevi istenmez (yoksa silinen toplantı için %0'da kalırdı).
    private func stopCapture(id: RecordingID, discard: Bool) {
        meetingOverPrompt = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        notifier.removeRecordingAlerts()
        closeAssistantCard()
        Self.logger.info("Kayıt bitiriliyor, duraklatılmış süre: \(self.pauseClock.completedSec, privacy: .public) sn")
        // Kapanış (son ses, son konuşmacı etiketleri, bekleyen çeviriler) uygulama arka plana geçse de bitsin.
        if let recording = active, recording.id == id {
            let meetingID: String = recording.directory.lastPathComponent
            beginBackgroundTask(id: meetingID)
            // Sistem görevi kullanıcının "Bitir" anında istenir: istek yalnızca uygulama öndeyken kabul edilir. Çevrimdışı
            // kayıtta not şimdi hazırlanmaz (kuyruğa girer): sistem ilerlemesi istenmez (boş ilerleme ekranda kalırdı).
            if state.server != .offline && !discard {
                submitContinuedProcessing(id: meetingID, subtitle: continuedProcessingSubtitle(title: recording.linkedMeeting?.title ?? String(localized: "Toplantı"), startedAt: recording.startedAt))
            }
        }
        levels.stop()
        microphone.stop()
        updateActivityNow(state: activityState())
    }

    /// "Bitir"den sonra canlı oturum (Deepgram kapanışı, cihaz içi tanımanın kalan sesi) `deadline`'a dek kapanmazsa kayıt
    /// canlı metnin sonu beklenmeden kapatılır: ses dosyası "Bitir" anında kapanmıştır ve son geçiş kaydın tamamını yazıya
    /// döker. Kullanıcı "Bitiriliyor"da takılı kalmaz.
    private func watchFinishing(id: RecordingID, deadline: Date) {
        finishingWatchdogTask?.cancel()
        finishingWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            } catch {
                // İptal: yeni kayıt başladı.
                return
            }
            self?.send(event: .finishNow(id: id))
        }
    }

    /// Bitirme süresi doldu: canlı oturum bırakılır (Deepgram bağlantısı kapanışı beklemeden kesilir; yoksa kayıt
    /// bittikten sonra da açık kalıp canlı tutma mesajları yollayabilirdi). Loglanır ve kayıt ekranında görünür.
    private func cancelLiveSession(id: RecordingID) {
        Self.logger.error("Canlı oturum süre içinde kapanmadı, kayıt canlı metnin sonu beklenmeden kapatılıyor, süre: \(Self.finishingLimitSec, privacy: .public) sn")
        errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Canlı metnin sonu beklenmeden kayıt kapatıldı; kaydın tamamı yine yazıya dökülür."))
        guard let handle = active?.handle, active?.id == id else {
            return
        }
        Task { await handle.cancel() }
    }

    /// Ses kapısını duraklatır ya da sürdürür (kullanıcı ya da kesinti); süre saati durumda. Süre sınırı bildirimlerini
    /// sınır izleyici yeni sınıra göre kurar ya da kaldırır (bkz. `watchRecordingLimit`).
    private func setAudioPaused(paused: Bool) {
        guard let active else {
            return
        }
        if paused {
            active.pauseGate.pause(at: .now)
        } else {
            active.pauseGate.resume(at: .now)
            lastActivityAt = Date()
            // Süre sınırı bildirimleri sınır izleyicide yeni sınırla yeniden kurulur (sunucu onayından sonra da).
            scheduledLimitDeadline = nil
        }
        updateActivityNow(state: activityState())
    }

    /// Mikrofonun durumu değişti: kayıt ekranı ve canlı etkinlik güncellenir; ses geri gelince kısa bildirim.
    private func microphoneStatusChanged(status: MicrophoneStatus) {
        let previous: MicrophoneStatus = microphoneStatus
        microphoneStatus = status
        // Kesintide (arama, alarm) kayıt kendiliğinden duraklar: aradaki sessizlik yazılmaz, yazıya dökülmez ve sunucuya
        // gönderilmez; kesinti bitince kayıt kendiliğinden sürer. Kullanıcının duraklatması ayrıdır: kesinti bitince
        // kalkmaz, kesinti sürerken "Devam" kaydı sürdürmez. Kayıt başlarken gelen kesinti kayıt başlayınca uygulanır.
        let wasPaused: Bool = state.pause.isPaused
        send(event: .interruptionChanged(interrupted: isMicrophoneInterrupted(status: status), at: Date()))
        guard phase == .recording else {
            return
        }
        if wasPaused != state.pause.isPaused {
            Self.logger.info("Kesinti nedeniyle kayıt \(self.state.pause.isPaused ? "kendiliğinden duraklatıldı" : "kendiliğinden sürdürüldü", privacy: .public)")
        }
        // Giriş değişince (AirPods, seçim) motor yeniden kurulur: "yeniden bağlandı" yerine giriş bildirimi görünür.
        if isMicrophoneRecovery(previous: previous, current: status), visibleAudioInputNotice(active: audioInput, transient: audioInputNotice) == nil {
            Self.logger.info("Mikrofon yeniden ses veriyor, kayıt sürüyor")
            showRecoveryNotice()
        }
        updateActivityNow(state: activityState())
    }

    /// Kayıt sürerken 30 sn'de bir: canlı etkinlik tazelenir (sessiz toplantıda da eskimesin; eskirse kilit ekranı
    /// "kayıt durmuş olabilir" der), "kayıt durmuş olabilir" bildirimi 90 sn ileri ertelenir (uygulama ölürse çıkar) ve
    /// toplantının bitip bitmediğine bakılır.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let heartbeatGeneration: Int = generation
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .recording, heartbeatGeneration == self.generation else {
                    return
                }
                self.updateActivityNow(state: self.activityState())
                do {
                    try await self.notifier.deferRecordingStoppedAlert(seconds: recordingStoppedAlertSec)
                } catch {
                    Self.logger.warning("Kayıt durmuş olabilir bildirimi kurulamadı, hata: \(String(describing: error), privacy: .private)")
                }
                self.checkMeetingOver()
                do {
                    try await Task.sleep(for: .seconds(recordingHeartbeatSec))
                } catch {
                    // İptal: kayıt bitti.
                    return
                }
            }
        }
    }

    /// Toplantı bitmiş gibiyse (takvim etkinliği bitti ya da 10 dk konuşma yok) kayıt ekranında ve bildirimle sorulur.
    private func checkMeetingOver() {
        guard phase == .recording, let active,
              let reason = meetingOverReason(
                  now: Date(), calendarEnd: active.linkedMeeting?.end, lastActivityAt: lastActivityAt, isPaused: pauseClock.isPaused,
                  asked: askedMeetingOver, calendarGraceSec: meetingOverCalendarGraceSec, silenceSec: meetingOverSilenceSec
              ) else {
            return
        }
        askedMeetingOver.insert(reason)
        meetingOverPrompt = reason
        Self.logger.info("Toplantı bitmiş gibi, soruluyor, neden: \(String(describing: reason), privacy: .public)")
        let recordingID: RecordingID = active.id
        Task {
            do {
                try await notifier.askMeetingOver(reason: reason, recordingID: recordingID)
            } catch {
                Self.logger.warning("Toplantı bitti mi bildirimi gösterilemedi, hata: \(String(describing: error), privacy: .private)")
            }
            // Kayıt bildirim kurulurken bittiyse soru kalmasın (eylemi zaten başka kayda uygulanmaz).
            if self.state.activeID != recordingID {
                self.notifier.removeMeetingOverPrompt()
            }
        }
    }

    /// "Toplantı bitti mi?" sorusuna "Sürüyor": soru kalkar; sessizlik yeniden sayılır.
    func dismissMeetingOverPrompt() {
        meetingOverPrompt = nil
        lastActivityAt = Date()
        notifier.removeRecordingAlerts()
        if phase == .recording {
            // Bekleyen "kayıt durmuş olabilir" bildirimi de kalktı: hemen yeniden kurulur.
            startHeartbeat()
        }
    }

    /// "Kaydı sil" (onaylandıktan sonra): mikrofon kapanır, toplantı işlenmez ve not yazılmaz; kaydedilen ses ve metin
    /// silinir. Sunucu oturumu kapanır (geçen süre kullanıma sayılır).
    func discard() {
        Self.logger.info("Kayıt silme istendi, aşama: \(String(describing: self.phase), privacy: .public)")
        // Bitirme sürerken de geçerlidir (süre sınırı ya da mikrofon kaydı kendiliğinden bitirdiyse): toplantı işlenmez.
        send(event: .discardRequested(target: .current, at: Date()))
    }

    /// Kayıt hatalarını kapatır (ana ekrandaki kapatma düğmesi).
    func dismissErrors() {
        errorMessages = []
    }

    /// Kayıtta mikrofon girişi değişti: başka girişe geçildiyse kayıt ekranında kısa bildirim; seçilen giriş
    /// kullanılamıyorsa ekran bunu durum sürdükçe gösterir (`visibleAudioInputNotice`). Kayıt sürer; yakalama yeni
    /// girişle zaten yeniden kuruldu (`MicrophoneCapture`).
    private func microphoneInputChanged(input: ActiveAudioInput) {
        let notice: AudioInputNotice? = audioInputChangeNotice(previous: audioInput, current: input)
        audioInput = input
        // Giriş değişince motor yeniden kurulur: "yeniden bağlandı" yerine giriş bildirimi görünür.
        if notice != nil || input.unavailableChoice != nil {
            recoveryNoticeTask?.cancel()
            microphoneRecoveredNoticeVisible = false
        }
        guard let notice else {
            return
        }
        Self.logger.info("Mikrofon girişi değişti, kayıt sürüyor, tür: \(input.device.kind.rawValue, privacy: .public)")
        showAudioInputNotice(notice: notice)
    }

    /// Kısa süreli mikrofon bildirimi (`audioInputNoticeSec`).
    private func showAudioInputNotice(notice: AudioInputNotice) {
        audioInputNotice = notice
        audioInputNoticeTask?.cancel()
        audioInputNoticeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(audioInputNoticeSec))
            } catch {
                // İptal: yeni bildirim geldi ya da kayıt bitti.
                return
            }
            self?.audioInputNotice = nil
        }
    }

    private func clearAudioInput() {
        audioInputNoticeTask?.cancel()
        audioInputNoticeTask = nil
        audioInputNotice = nil
        audioInput = nil
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

    /// Kayıt sürerken çekilen fotoğrafın yeri: toplantının klasörü ve kaydedilen sesin zaman çizgisinde şu an
    /// (duraklatılan süre düşülür; işaretlenen anlar ve transkriptle aynı çizgi). Kayıt yoksa nil.
    func livePhotoTarget() -> LivePhotoTarget? {
        guard phase == .recording, let active else {
            return nil
        }
        return LivePhotoTarget(meetingID: active.directory.lastPathComponent, directory: active.directory, offsetSec: active.pauseGate.keptSeconds(at: .now))
    }

    /// Kayıt sürüyor ve duraklatılmış mı.
    var isPaused: Bool {
        pauseClock.isPaused
    }

    /// Kaydı duraklatır (Mac'teki "Duraklat"): bu andan sonraki ses dosyaya yazılmaz, yazıya dökülmez ve sunucuya
    /// gönderilmez (son geçiş ve canlı metin bu süreyi saymaz); süre durur. Mikrofon açık kalır: kayıt arka planda ve
    /// kilit ekranında sürer, yakalama yeniden kurulmaz. Kesinti (çağrı) duraklatmadan bağımsızdır; ikisi bir arada da
    /// duraklatılan aralığa düşen ses atılır. Çevrimiçi kayıtta duraklatma kaydın kendi sunucu oturumuna bildirilir
    /// (Mac'teki gibi): duraklatılan süre toplantının süre sınırına ve aylık kullanıma sayılmaz. Kayıt yokken (kilit ekranı)
    /// uygulama kayıt sırasında kapandıysa kalan canlı etkinlik kalkar. `target`: kilit ekranı eylemleri kendi kaydını
    /// hedefler.
    func pause(target: RecorderTarget) {
        send(event: .pauseRequested(target: target, at: Date()))
        Self.logger.info("Kayıt duraklatma istendi, duraklatma: \(String(describing: self.state.pause), privacy: .public)")
    }

    func pause() {
        pause(target: .current)
    }

    /// Duraklatılan kaydı sürdürür: ses yeniden kaydedilir ve yazıya dökülür. Kesinti (arama) sürüyorsa kayıt kesinti
    /// bitene dek duraklatılmış kalır (aramadaki sessizlik kaydedilmez).
    func resume(target: RecorderTarget) {
        send(event: .resumeRequested(target: target, at: Date()))
        Self.logger.info("Kayıt sürdürme istendi, duraklatılmış süre: \(self.pauseClock.completedSec, privacy: .public) sn, duraklatma: \(String(describing: self.state.pause), privacy: .public)")
    }

    func resume() {
        resume(target: .current)
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
        let candidates: [MeetingRecord] = store.meetings.filter { store.meetingJobs[$0.id] == nil }
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
              record.status != .processing, !record.audioDeleted, store.meetingJobs[meetingID] == nil else {
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
        let sampleID: RecordingID = RecordingID(rawValue: "sample")
        let sampleStart: Date = Date().addingTimeInterval(-754)
        levels.showSample(values: [0.1, 0.4, 0.7, 0.5, 0.9, 0.3, 0.6, 0.2, 0.8, 0.5])
        state = .recording(RecorderRecording(id: sampleID, server: .local, startedAt: sampleStart, pause: .running, clock: .running, micMuted: false))
        consentReminderVisible = true
        audioInput = ActiveAudioInput(device: sampleBuiltInMicrophone(), unavailableChoice: nil)
        startActivity(recordingID: sampleID, startedAt: sampleStart, title: String(localized: "Toplantı"))
        updateActivityNow(state: activityState())
    }

    /// `--ornek-duraklat` (yalnız Debug, görsel kontrol): örnek kayıt 40 sn önce duraklatılmış; bir cümlenin çevirisi
    /// alınamamış ("Tekrar dene").
    func showSamplePaused() {
        let failed: SegmentID = SegmentID(speaker: .others, index: 2)
        translations[failed] = nil
        failedTranslations = [failed]
        if case .recording(let recording) = state {
            let pausedAt: Date = Date().addingTimeInterval(-40)
            state = .recording(RecorderRecording(
                id: recording.id, server: recording.server, startedAt: recording.startedAt, pause: .user(since: pausedAt),
                clock: PauseClock.running.pausing(at: pausedAt), micMuted: false
            ))
        }
        updateActivityNow(state: activityState())
    }

    /// `--ornek-sinir` (yalnız Debug, görsel kontrol): örnek kayıt çevrimdışı sürüyor ve aylık sınır yüzünden 12 dakika
    /// sonra bitecek (iki bildirim birlikte).
    func showSampleLimits() {
        if case .recording(let recording) = state {
            state = .recording(RecorderRecording(
                id: recording.id, server: .offline, startedAt: recording.startedAt, pause: recording.pause, clock: recording.clock, micMuted: false
            ))
        }
        shortMeetingDeadline = Date().addingTimeInterval(12 * 60)
    }

    /// `--ornek-cihazda` (Debug only, visual check): the sample recording has just started with the on-device live
    /// preview (no text yet), so the listening state's on-device line shows.
    func showSampleOnDevicePreview() {
        transcript = []
        translations = [:]
        liveText = LiveTextState(
            routes: HostedLiveRoutes(me: .local, others: .onDevice(AppleSpeechChoice(kind: .speech, localeIdentifier: "en-US"))),
            liveSpeakers: Self.capturedSpeakers, stopped: [:]
        )
    }

    /// `--ornek-mikrofon` (yalnız Debug, görsel kontrol): seçilen AirPods kayıtta çıkarıldı; kayıt iPhone mikrofonuyla
    /// sürüyor (bildirim seçim kullanılamadıkça görünür).
    func showSampleInputLost() {
        let builtIn: AudioInputDevice = sampleBuiltInMicrophone()
        consentReminderVisible = false
        audioInput = ActiveAudioInput(device: builtIn, unavailableChoice: .bluetoothHeadset)
    }

    /// Örnek kayıtların iPhone mikrofonu (adı sistemdeki gibi arayüz dilinde).
    private func sampleBuiltInMicrophone() -> AudioInputDevice {
        AudioInputDevice(id: "sample-built-in", name: audioInputChoiceTitle(choice: .builtIn), kind: .builtIn)
    }

    /// `--ornek-bitir` (yalnız Debug, görsel kontrol): örnek kayıt bitiriliyor durumunda kalır (oturum yok).
    func showSampleFinishing() {
        if case .recording(let recording) = state {
            let now: Date = Date()
            state = .finishing(RecorderFinishing(
                id: recording.id, server: recording.server, startedAt: recording.startedAt, stoppedAt: now, clock: recording.clock.resuming(at: now),
                discardRequested: false, stage: .closing
            ))
        }
        levels.stop()
        updateActivityNow(state: activityState())
    }

    /// `--ornek-gorusme` (yalnız Debug, görsel kontrol): bu iPhone'daki bir görüşme mikrofonu tutuyor. Örnek kayıtla
    /// (`--ornek-kayit`) kayıt ekranındaki uyarı ve duraklatılmış kayıt, tek başına ana ekrandaki başlatma hatası.
    func showSampleCallHold() {
        guard case .recording(let recording) = state else {
            errorMessages = [microphoneHeldByCallText()]
            return
        }
        let heldAt: Date = Date().addingTimeInterval(-20)
        state = .recording(RecorderRecording(
            id: recording.id, server: recording.server, startedAt: recording.startedAt, pause: .interruption(since: heldAt),
            clock: PauseClock.running.pausing(at: heldAt), micMuted: false
        ))
        microphoneStatus = .heldByCall
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
                lastActivityAt = Date()
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
        case .streamFailed(let speaker, let message):
            if let liveText, liveTextIsOnDevice(state: liveText, speaker: speaker) {
                recordTelemetryCount(kind: .onDeviceLiveFailed)
            }
            // The empty state no longer says the live text is written here (`isLivePreviewOnDevice`); the error line says
            // it stopped, until it comes back (`.streamRecovered`).
            liveText = liveText.map { liveTextStep(state: $0, event: .streamFailed(speaker: speaker, message: message)) }
            errorMessages = appendUnique(messages: errorMessages, message: phoneLiveTextStoppedText(message: message))
        case .streamRecovered(let speaker, let message):
            liveText = liveText.map { liveTextStep(state: $0, event: .streamRecovered(speaker: speaker)) }
            errorMessages = errorMessages.filter { $0 != phoneLiveTextStoppedText(message: message) }
        case .streamIncomplete(let speaker, let untranscribedSec):
            // iPhone'da ses "Diğerleri" akışındadır ve son geçişten her zaman geçer: eksik kalan son metin orada tamamlanır.
            Self.logger.warning("Canlı metnin sonu eksik, konuşmacı: \(speaker.rawValue, privacy: .public), süre: \(untranscribedSec, privacy: .public)")
        case .diarizationFailed(let message):
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Konuşmacı ayırma başarısız: \(message)"))
        case .speakersAssigned:
            break
        case .liveEngineFellBack(let message):
            // Bulut durdu, canlı metin bu iPhone'da sürüyor (iOS 26+; kayıt kesilmedi).
            liveText = liveText.map { liveTextStep(state: $0, event: .cloudFellBack) }
            errorMessages = appendUnique(messages: errorMessages, message: message)
        case .liveTextReconnecting(let message):
            errorMessages = appendUnique(messages: errorMessages, message: message)
        case .liveTextReconnected(let message):
            errorMessages = errorMessages.filter { $0 != message }
        }
    }

    /// Kapanış (canlı oturum bitti ya da bitirme süresi doldu): yarım çeviri birimleri çeviriye gider, bekleyen çeviriler
    /// (en fazla 10 sn) beklenir, kaydın sunucu oturumu (başlarken yakalanan kimlikle; hesabın oturumu kapanmış olsa da)
    /// en fazla `serverEndLimitSec` beklenerek kapatılır, sonra `closed` gönderilir. Durum makinesi bunu kayıt başına bir
    /// kez ister; "Bitiriliyor…" bu yüzden süreyle sınırlıdır.
    private func close(id: RecordingID, server: RecordingServerSession) async {
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
        finishingWatchdogTask?.cancel()
        finishingWatchdogTask = nil
        microphone.stop()
        levels.stop()
        endActivity()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        notifier.removeRecordingAlerts()
        meetingOverPrompt = nil
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        cancelRecordingLimitNotifications()
        consentReminderVisible = false
        relatedTasks = []
        recordingCalendarMeeting = nil
        shortMeetingDeadline = nil
        if server != .local {
            // Not ve son geçiş sunucunun işleme süresinde (düzgün biten toplantıda 24 saat) aynı oturumla sürer. Ağ takılırsa
            // kapanış arka planda sürer, kayıt "Bitiriliyor"da kalmaz; kapatılamazsa kimlik açık oturumlar listesinde kalır
            // ve yetim kapatma (ağ gelince, öne gelince, aynı hesapla girişte) kapatır.
            let meetingID: String? = server.meetingID
            let ended: Bool = await finishesWithin(seconds: Self.serverEndLimitSec) { [weak self] in
                await self?.endServerMeeting(meetingID: meetingID)
            }
            if !ended {
                Self.logger.warning("Toplantı oturumunun kapanışı süre içinde bitmedi, arka planda sürüyor, süre: \(Self.serverEndLimitSec, privacy: .public) sn")
            }
        }
        send(event: .closed(id: id))
    }

    /// Kaydın sunucu oturumunu kapatır (çevrimdışı kayıtta `nil`: hesabın çevrimdışı kayıt durumu biter); kapatılamazsa
    /// neden kayıt ekranında görünür.
    private func endServerMeeting(meetingID: String?) async {
        do {
            try await HostedAccount.shared.endMeeting(meetingID: meetingID)
        } catch {
            Self.logger.error("Toplantı oturumu kapatılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Toplantı oturumu kapatılamadı: \(userFacingMessage(error: error))"))
        }
    }

    /// Kayıt bitti: toplantı saklanıp işlenir (çevrimdışıysa kuyruğa girer) ya da "Kaydı sil" istendiyse klasörü silinir.
    private func complete(id: RecordingID, server: RecordingServerSession, discard: Bool, stoppedAt: Date) {
        guard let finished = active, finished.id == id else {
            Self.logger.error("Biten kaydın oturum verisi yok, kayıt: \(id.rawValue, privacy: .public)")
            return
        }
        active = nil
        // Biten kaydın geç çevirisi artık yazılmaz.
        generation += 1
        let record: MeetingRecord = liveRecord(recording: finished, status: .processing, endedAt: stoppedAt)
        microphoneRecoveredNoticeVisible = false
        clearAudioInput()
        lastMeetingID = record.id
        Self.logger.info("Kayıt bitti, toplantı: \(record.id, privacy: .public), çevrimdışı: \(server == .offline, privacy: .public)")
        if discard {
            // "Kaydı sil": işlenmez; ses, metin ve klasör silinir.
            lastMeetingID = nil
            Self.logger.info("Silinen kaydın klasörü kaldırılıyor, toplantı: \(record.id, privacy: .public)")
            discardUnstartedRecording(directory: finished.directory)
            store.reload()
            // "Bitir"den sonra silindiyse not için istenen sistem görevi başlamış olabilir: kapatılır.
            finishContinuedTask(meetingID: record.id, success: false)
            endBackgroundTask(id: record.id)
            return
        }
        if server == .offline {
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
        guard store.beginMeetingJob(meetingID: record.id, job: .processing(.convertingAudio)) else {
            return false
        }
        saveRecord(record: record, directory: directory)
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
                // The iPhone does not capture screens; photos the user added go with the note when "Use photos in notes" is on.
                // Voiceprints are computed on this iPhone
                // (SpeakerKit) when voice recognition is on; they never leave the device.
                noteLanguage: phoneNoteLanguage(), voiceEmbedder: store.voices.embedderIfEnabled(), registry: store.voices.registered, screens: phoneScreenNotesPlan()
            ) { (step: ProcessingStep) async -> Void in
                self.store.advanceProcessing(meetingID: record.id, step: step)
                self.setContinuedProgress(meetingID: record.id, completedUnits: continuedProcessingCompletedUnits(step: step))
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
                store.endMeetingJob(meetingID: record.id)
                endBackgroundTask(id: record.id)
                return
            }
            // Uygulama kayıt sürerken kapandıysa toplantıda neden kısa olduğu yazılır.
            let result: MeetingRecord = recoveredRecordingIDs.remove(record.id) == nil ? retried : withInterruptedRecordingNotice(record: retried)
            Self.logger.info("Toplantı işlendi, toplantı: \(record.id, privacy: .public), durum: \(result.status.rawValue, privacy: .public), not: \(result.note != nil, privacy: .public), son geçiş bölümü: \(result.finalSegments.count, privacy: .public)")
            recordNoteOutcome(result: result, writingStartedAt: noteWritingStartedAt.removeValue(forKey: record.id))
            // Tekrar işlemede eski not geçmişe girer (ilk işlemede not yoktur; Mac'teki gibi).
            let versioned: MeetingRecord = withNoteVersion(updated: result, previous: record, reason: String(localized: "Tekrar işlendi"), savedAt: Date())
            guard saveRecord(record: versioned, directory: directory) else {
                // The result could not be written: the checkpoint stays, the meeting stays `processing` on disk and is
                // processed again on the next launch (`resumeUnfinished`); the save error stays on screen.
                store.endMeetingJob(meetingID: record.id)
                finishContinuedTask(meetingID: record.id, success: false)
                endBackgroundTask(id: record.id)
                // The queue skips this meeting for its cooldown (a disk that stays full must not reprocess it, with paid
                // server calls, in a loop); the next queued meeting does not wait for another trigger.
                queueRejections[record.id] = Date()
                await runQueue()
                return
            }
            removeCheckpointIfDone(record: versioned, directory: directory)
            store.endMeetingJob(meetingID: record.id)
            // Not hazır: kaydın uyarıları ana ekranda günlerce kalmasın.
            if versioned.status == .done, versioned.id == lastMeetingID {
                errorMessages = []
            }
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
            store.advanceProcessing(meetingID: current.id, step: .writingNote)
            noteWritingStartedAt[current.id] = .now
            current = await regenerateNote(
                record: current.with(status: .processing, failureMessage: nil), directory: directory, llm: recordedMeetingLLMReportingFailure(recordID: current.id),
                userName: store.userName, profile: store.userProfile, language: phoneNoteLanguage(), screens: phoneScreenNotesPlan()
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

    /// İçe aktarma işleri (dosyalar ve görüşme kayıtları ayrı; bkz. `ImportJob`): her işin kalan dosyası ve hataları.
    private(set) var importJobs: [ImportJob] = []

    /// İçe aktarılmakta olan dosya sayısı (ses izi dönüştürülürken).
    var importingCount: Int {
        AINotepadCore.importingCount(jobs: importJobs)
    }

    /// İçe aktarılamayan dosyalar ve nedenleri (Toplantılar'da ve ana ekranda kapatılabilir satır): kullanıcı kapatana
    /// (`dismissImportErrors`) ya da aynı kaynaktan yeni içe aktarma başlayana dek kalır; arka planda gelen görüşme kaydı
    /// dosyalarınkine dokunmaz.
    var importErrors: [String] {
        AINotepadCore.importErrors(jobs: importJobs)
    }

    /// İçe aktarma hatalarını kapatır (bkz. `dismissingImportErrors`): süren içe aktarmalar sürer.
    func dismissImportErrors() {
        importJobs = dismissingImportErrors(jobs: importJobs)
    }

    /// Ses ya da video dosyalarını toplantı olarak içe aktarır (Mac'teki "İçe aktar"): ses izi `others.m4a` olur
    /// (kayıtla aynı biçim), toplantı bekleyen olarak kuyruğa girer; sunucu oturumu, son geçiş (konuşmacılar) ve not
    /// çevrimdışı kayıt gibi kuyrukta üretilir (haklar, deneme ve aylık süre sunucuda denetlenir). Dosyalar sırayla
    /// dönüştürülür; hepsi bitince döner. Kaynak dosyalara dokunulmaz (Dosyalar'dan seçilenler güvenlik kapsamıyla okunur).
    func importFiles(urls: [URL]) async {
        let job: UUID = beginImportJob(source: .files, count: urls.count)
        for url in urls {
            await importOne(url: url, job: job)
        }
        await runQueue()
    }

    /// Paylaşım sayfasından gelen dosyaları içe aktarır (`importFiles` gibi); her dosyanın içe aktarması bitince
    /// `onImported` çağrılır (gelen kutusundaki kopya o an silinir). Uygulama kuyruk işlenirken kapanırsa kalan kopya yalnız
    /// henüz içe aktarılmamış dosyadır (açılışta yeniden bekler, `PhoneSharedFileInbox`); aynı toplantı iki kez oluşmaz.
    func importSharedFiles(urls: [URL], onImported: @MainActor (URL) -> Void) async {
        let job: UUID = beginImportJob(source: .files, count: urls.count)
        for url in urls {
            await importOne(url: url, job: job)
            onImported(url)
        }
        await runQueue()
    }

    /// Görüşme kaydını (uygulamadan yapılan aramanın indirilen kaydı, deneysel görüşme yakalama) içe aktarır
    /// (`importFiles` gibi): toplantı oluştuysa nil, olmadıysa bu dosyanın nedeni. Çağıran kaynağı yalnızca başarıda siler:
    /// içe aktarma başarısızsa kayıt orada kalır, yeniden denenir.
    func importCallRecording(url: URL) async -> String? {
        let job: UUID = beginImportJob(source: .callRecording, count: 1)
        let failure: String? = await importOne(url: url, job: job)
        await runQueue()
        return failure
    }

    /// Yeni içe aktarma işi açar (aynı kaynağın biten işleri düşer; bkz. `beginningImportJob`).
    private func beginImportJob(source: ImportSource, count: Int) -> UUID {
        let id: UUID = UUID()
        importJobs = beginningImportJob(jobs: importJobs, id: id, source: source, count: count)
        return id
    }

    /// Tek dosyayı içe aktarır ve işinde bitmiş sayar; toplantı oluştuysa nil. Olmazsa yarım klasör silinir ve neden (dönüş
    /// değeri) işin hatalarına yazılır (listede görünür).
    @discardableResult
    private func importOne(url: URL, job: UUID) async -> String? {
        let accessed: Bool = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try await importAudio(url: url, title: url.deletingPathExtension().lastPathComponent, startedAt: Date())
            importJobs = finishingImportItem(jobs: importJobs, id: job)
            return nil
        } catch {
            let message: String = String(localized: "\(url.lastPathComponent) içe aktarılamadı: \(mediaImportMessage(error: error))")
            importJobs = failingImportItem(jobs: importJobs, id: job, message: message)
            return message
        }
    }

    /// Apple Watch'ta kaydedilen sesi saatteki başlık ve başlangıç anıyla toplantı olarak kuyruğa koyar; kuyruğu işlemez
    /// (çağıran önce kaydı içe aktarıldı diye işaretler, sonra `runQueue`: arada uygulama kapanırsa aynı ses ikinci kez
    /// toplantı olmaz). Hata fırlatır: çağıran (`PhoneWatchLink`) oturum yokken dosyayı saklar; toplantının ses hakkından
    /// uzun kayıt kesilmez, reddedilir ve gelen kutusunda kalır (hak yenilenince "Yeniden dene"; ses hiç kaybolmaz).
    func importWatchRecording(url: URL, title: String, startedAt: Date) async throws {
        let job: UUID = beginImportJob(source: .files, count: 1)
        // The job only counts the file while it imports: a failure is shown (with "Try again" and "Delete") by the Watch
        // recordings list (`PhoneWatchLink.failedImports`), and a sign-out is a wait, not a failure.
        defer { importJobs = finishingImportItem(jobs: importJobs, id: job) }
        try await importAudio(url: url, title: title, startedAt: startedAt)
    }

    /// Ses dosyasını `startedAt` anlı, `title` başlıklı toplantı olarak içe aktarır ve kuyruğa koyar. Olmazsa yarım
    /// klasör silinir ve hata fırlatılır.
    private func importAudio(url: URL, title: String, startedAt: Date) async throws {
        var created: URL?
        do {
            let session: (url: URL, startedAt: Date) = try AppPaths.newExclusiveSessionDirectory(startedAt: startedAt)
            created = session.url
            let recordID: String = session.url.lastPathComponent
            // Uzun dosya dönüştürülürken uygulama arka plana geçerse iOS'tan ek süre istenir.
            beginBackgroundTask(id: recordID)
            defer { endBackgroundTask(id: recordID) }
            let duration: Double = try await importMediaAudio(source: url, destination: session.url.appending(path: "others.m4a"))
            let record: MeetingRecord = importedMeetingRecord(
                id: recordID, source: url, startedAt: session.startedAt, durationSec: duration, engine: .cloud,
                template: phoneNewMeetingNoteTemplate(title: title)
            )
            .with(title: title)
            // Toplantının ses hakkını aşan dosya kuyruğa alınmaz: son geçiş yarıda kalır, bekleyen kayıt hiç bitmezdi.
            // Hak durumu okunamadıysa sunucu son geçişte denetler.
            if case .signedIn(let entitlements) = HostedAccount.shared.state {
                try requireHostedImportFits(durationSec: duration, entitlements: entitlements)
            }
            // Kayıt giriş yapan hesaba yazılır: kuyruk yalnız o hesabın kayıtlarını işler (başka hesaba faturalanmaz).
            try await HostedAccount.shared.claimQueuedRecord(recordID: recordID)
            // A failed save throws: the caller keeps the source (the Watch inbox copy, a call recording) instead of
            // treating the import as done.
            try persistRecord(
                record: record.with(status: .queued, failureMessage: nil).with(notice: String(localized: "İçe aktarıldı; sunucuda işlenmeyi bekliyor.")),
                directory: session.url
            )
            Self.logger.info("Dosya içe aktarıldı, toplantı: \(recordID, privacy: .public), süre: \(Int(duration), privacy: .public)")
        } catch {
            Self.logger.error("Dosya içe aktarılamadı, hata: \(String(describing: error), privacy: .private)")
            if let created {
                do {
                    try FileManager.default.removeItem(at: created)
                } catch {
                    Self.logger.error("Yarım içe aktarma klasörü silinemedi, hata: \(String(describing: error), privacy: .private)")
                }
            }
            throw error
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
        // iOS 18–25'te sürdürülen işleme görevi yok: işleme uygulamanın arka plan süresiyle sürer, bitmezse açılışta
        // yeniden işlenir (`ProcessingResumeScheduler`, `resumeUnfinished`).
        guard #available(iOS 26.0, *) else {
            Self.logger.info("Sürdürülen işleme görevi bu iOS sürümünde yok, işleme arka plan süresiyle sürecek, toplantı: \(id, privacy: .public)")
            return
        }
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
    @available(iOS 26.0, *)
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
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
            continued.progress.completedUnitCount = continuedProcessingTotalUnits
        }
        task.setTaskCompleted(success: success)
    }

    /// Sistem görevinin ilerlemesi (işleme adımı değişince); görev yoksa bir şey yapmaz.
    private func setContinuedProgress(meetingID: String, completedUnits: Int64) {
        if #available(iOS 26.0, *), let continued = continuedTasks[meetingID] as? BGContinuedProcessingTask {
            continued.progress.completedUnitCount = completedUnits
        }
    }

    // MARK: Canlı etkinlik

    /// Canlı etkinlikteki son satır: son kesinleşen cümle ve konuşmacısı.
    private var activityLine: (text: String, speaker: String) {
        guard let last = correctedTranscript.last(where: { $0.isFinal && !$0.text.isEmpty }) else {
            return ("", "")
        }
        return (last.text, last.person.map { speakerLabel(speaker: last.id.speaker, person: $0) } ?? "")
    }

    /// Canlı etkinliğin şimdiki durumu: son cümle, kaydın durumu (bkz. `liveRecordingStatus`) ve duraklatılan süre (sayaç
    /// duraklatmayı saymaz).
    private func activityState() -> RecordingActivityAttributes.ContentState {
        let line: (text: String, speaker: String) = activityLine
        return RecordingActivityAttributes.ContentState(
            lastLine: line.text, speaker: line.speaker, status: liveRecordingStatus(state: state, microphoneRunning: microphoneStatus == .running),
            pausedSec: pauseClock.completedSec
        )
    }

    /// Kilit ekranı ve Dynamic Island'da kaydı gösterir. Kullanıcı canlı etkinlikleri kapattıysa gösterilmez (loglanır);
    /// kayıt etkilenmez. Süre etkinlikte sistem saatiyle akar (`Text(timerInterval:)`); güncellemeler yalnız metin ve
    /// durum içindir.
    private func startActivity(recordingID: RecordingID, startedAt: Date, title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.info("Canlı etkinlikler kapalı; kayıt kilit ekranında ve Dynamic Island'da gösterilmiyor")
            return
        }
        // Uygulama kayıt sırasında kapanıp yeniden açıldıysa kalan eski etkinlik Dynamic Island'da yer tutmasın.
        let previous: [String] = Activity<RecordingActivityAttributes>.activities.map(\.id)
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(startedAt: startedAt, title: title, recordingID: recordingID.rawValue),
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

    /// Saves the meeting to disk and the in-memory list; throws when the write fails (the list is then unchanged). Paths
    /// that act on the saved meeting afterwards (deleting the source audio, marking an import done) use this one.
    private func persistRecord(record: MeetingRecord, directory: URL) throws {
        try saveMeeting(record: record, directory: directory)
        store.upsert(record: record)
    }

    /// Saves the meeting (see `persistRecord`); a failed write is logged and shown to the user. Returns whether the
    /// meeting was saved, so callers never treat a failed save as done.
    @discardableResult
    private func saveRecord(record: MeetingRecord, directory: URL) -> Bool {
        do {
            try persistRecord(record: record, directory: directory)
            return true
        } catch {
            Self.logger.error("Toplantı kaydedilemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
            return false
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
    "\(title) · \(startedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale())))"
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

/// Canlı etkinliğin durumu: bitiriliyorsa "Bitir" anı, kullanıcı duraklattıysa (kesinti de sürse) duraklatma,
/// kesintide ya da mikrofon yeniden bağlanırken "mikrofon bekleniyor" (kesintide süre durur), değilse kaydediliyor.
/// Saf fonksiyondur.
private func liveRecordingStatus(state: RecorderState, microphoneRunning: Bool) -> LiveRecordingStatus {
    switch state {
    case .finishing(let finishing):
        return .finishing(stoppedAt: finishing.stoppedAt)
    case .recording(let recording):
        if recording.pause.isPausedByUser, let since = recording.clock.pausedAt {
            return .paused(since: since)
        }
        if recording.pause.isPaused || !microphoneRunning {
            return .waitingForMicrophone(timerStoppedAt: recording.clock.pausedAt)
        }
        return .recording
    case .idle, .starting, .failed:
        return microphoneRunning ? .recording : .waitingForMicrophone(timerStoppedAt: nil)
    }
}

/// Why the iPhone refuses to start a recording before anything opens (`PhoneRecorder.startRefusal`).
enum PhoneStartRefusal: Equatable {
    case signInRequired
    case aiConsentMissing
    /// The plan blocks recording (trial ended, monthly limit…); `message` says why (`phoneStartBlockMessage`).
    case planBlocked(message: String)
    case diskFull
}

/// The refusal as the user reads it (on the iPhone and on the Watch).
func phoneStartRefusalText(refusal: PhoneStartRefusal) -> String {
    switch refusal {
    case .signInRequired:
        String(localized: "Kayıt için önce giriş yap.")
    case .aiConsentMissing:
        String(localized: "Kayıt için önce uygulamayı aç ve yapay zekâ kullanımını onayla.")
    case .planBlocked(let message):
        message
    case .diskFull:
        phoneDiskFullText()
    }
}

/// The error line of a stopped live text; the same text is removed when it comes back.
func phoneLiveTextStoppedText(message: String) -> String {
    String(localized: "Canlı metin durdu: \(message)")
}
