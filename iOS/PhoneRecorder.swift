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
    /// Notun şablonu: kayıt başlarken Ayarlar'daki varsayılan (kayıt sırasında değişmez).
    let template: NoteTemplate
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
    private(set) var translations: [SegmentID: String] = [:]
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
    var languageMode: LanguageMode = .automatic
    /// Kayıtta işaretlenen anlar (not onları öne çıkarır).
    private(set) var highlights: [Highlight] = []
    /// Kullanıcının kayıt sırasında yazdığı notlar (not bunları öncelik sayar).
    var myNotes: String = ""
    /// "Katılımcılara haber ver" bildirimi görünür (ayar açıksa kayıt başında açılır; kayıt ekranı 3 saniye sonra ya da
    /// dokununca kapatır).
    var consentReminderVisible: Bool = false
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
    /// Canlı çevirinin cümle birimlerini kuran durum (bkz. `TranslationUnit`): kesin bölümler cümle sonuna dek birikir.
    @ObservationIgnored private var unitBuilder: TranslationUnitBuilder = .empty
    /// Bu kayıtta kurulan çeviri birimleri (kuruluş sırasıyla): bağlam bunlardan.
    @ObservationIgnored private var translationUnits: [TranslationUnit] = []
    /// Konuşmacı başına sessizlik beklemesi: süre dolunca bekleyen yarım birim çevrilir; yeni kesin bölüm, yeni kayıt ve
    /// kayıt sonu iptal eder.
    @ObservationIgnored private var idleFlushTasks: [Speaker: Task<Void, Never>] = [:]
    @ObservationIgnored private var translationQueue: [TranslationUnit] = []
    @ObservationIgnored private var translationsInFlight: Int = 0
    /// Her kayıtta artar: önceki kaydın geç gelen çevirisi yenisine yazılmaz.
    @ObservationIgnored private var generation: Int = 0
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
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

    init(store: PhoneStore) {
        self.store = store
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
        guard UserDefaults.standard.bool(forKey: PhoneSettingsKey.aiDisclosureAccepted) else {
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
        phase = .starting
        generation += 1
        finishingWatchdogTask?.cancel()
        finishingWatchdogTask = nil
        stoppedAt = nil
        microphoneStatus = .running
        microphoneRecoveredNoticeVisible = false
        transcript = []
        translations = [:]
        translationQueue = []
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
        let audio: AsyncStream<[Float]>
        do {
            directory = try AppPaths.newSessionDirectory(startedAt: started)
            let origin: ContinuousClock.Instant = .now
            microphone.onStatusChange = { [weak self] (status: MicrophoneStatus) -> Void in
                self?.microphoneStatusChanged(status: status)
            }
            audio = clockAlignedStream(audio: try await microphone.start(), origin: origin, sampleRate: 16000, thresholdSec: 0.5)
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            phase = .idle
            return
        }
        levels.start()
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
        do {
            let requestedAt: Date = Date()
            switch try await account.startMeeting(recordID: directory.lastPathComponent) {
            case .online(let meeting):
                deadline = hostedRecordingDeadline(requestedAt: requestedAt, maxDurationMinutes: meeting.maxDurationMinutes, serverEndsAt: meeting.expiresAt)
                offline = false
            case .offline(let maxMinutes):
                // Sunucuya ulaşılamadı: kayıt sürer (canlı metin bu iPhone'da), süre son bilinen hak durumuyla sınırlı;
                // toplantı bağlantı gelince işlenir (bkz. `runQueue`).
                deadline = requestedAt.addingTimeInterval(Double(maxMinutes) * 60)
                offline = true
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
            discardRefusedRecording(directory: directory)
            phase = .idle
            return
        }
        // Canlı motoru sunucu seçer (Deepgram jetonu); jeton alınamazsa ya da akış durursa canlı metin bu iPhone'da.
        let choice: HostedLiveChoice = await hostedLiveChoice(
            language: speechLanguage,
            keyterms: keytermsWithAttendees(attendees: linkedMeeting?.attendees ?? [], keyterms: phoneRecognitionKeyterms(records: store.meetings, people: store.peopleBook), limit: 30)
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
            offline: offline, linkedMeeting: linkedMeeting, template: phoneNoteTemplate()
        )
        self.active = active
        startedAt = started
        phase = .recording
        // Uygulama kayıt sırasında kapanırsa toplantı açılışta bulunup işlenir.
        saveRecord(record: liveRecord(recording: active, status: .recording, endedAt: nil), directory: directory)
        startCheckpoints()
        startActivity(startedAt: started, title: linkedMeeting?.title ?? String(localized: "Toplantı"))
        watchRecordingLimit(deadline: deadline)
        consentReminderVisible = UserDefaults.standard.bool(forKey: PhoneSettingsKey.consentReminder)
        Self.logger.info("Kayıt başladı, klasör: \(directory.lastPathComponent, privacy: .public), çevrimdışı: \(offline, privacy: .public)")
        let sessionGeneration: Int = generation
        Task { [weak self] in
            for await event in handle.events {
                self?.handle(event: event, generation: sessionGeneration)
            }
            await self?.sessionEnded(sessionGeneration: sessionGeneration)
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

    /// Sunucu toplantıyı reddetti: kayıt başlamadı, o ana dek diske yazılan ses ve klasör silinir.
    private func discardRefusedRecording(directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Self.logger.error("Reddedilen kaydın klasörü silinemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
        }
    }

    /// Mikrofonu kapatır; oturum kalan bölümleri bitirip kendiliğinden biter.
    func stop() {
        guard phase == .recording else {
            // Kayıt yokken "Bitir" (kilit ekranı, Denetim Merkezi): uygulama kayıt sırasında kapandıysa kalan canlı
            // etkinlik kalkar.
            endStaleActivities()
            return
        }
        phase = .finishing
        stoppedAt = Date()
        closeAssistantCard()
        Self.logger.info("Kayıt bitiriliyor")
        // Kapanış (son ses, son konuşmacı etiketleri, bekleyen çeviriler) uygulama arka plana geçse de bitsin.
        if let recording = active {
            let id: String = recording.directory.lastPathComponent
            beginBackgroundTask(id: id)
            // Sistem görevi kullanıcının "Bitir" anında istenir: istek yalnızca uygulama öndeyken kabul edilir.
            submitContinuedProcessing(id: id, subtitle: continuedProcessingSubtitle(title: recording.linkedMeeting?.title ?? String(localized: "Toplantı"), startedAt: recording.startedAt))
        }
        levels.stop()
        microphone.stop()
        updateActivityNow(state: activityState())
        watchFinishing()
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

    /// Kullanımdaki toplantılar (kayıtta ya da işleniyor).
    var busyMeetingIDs: Set<String> {
        Set(processingSteps.keys).union([active?.directory.lastPathComponent].compactMap { $0 })
    }

    /// Şu anı işaretler: notta öne çıkar (söz bittikten sonra basılır; aralığı `Highlight` belirler).
    func markMoment() {
        guard phase == .recording, let startedAt else {
            return
        }
        highlights.append(Highlight(startSec: Date().timeIntervalSince(startedAt), endSec: nil))
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

    /// Açılışta (ve arka plandan dönünce) kayıtta ya da işlemede kalmış toplantılar yeniden işlenir (son geçiş ve not
    /// kaydın sunucu oturumuyla; oturumun ek süresi geçtiyse yeniden işleme için açılır, bkz. `hostedFinalPassPlan`), sonra
    /// bekleyen (çevrimdışı) kayıtlar denenir.
    func resumeUnfinished() async {
        endStaleActivities()
        guard phase == .idle else {
            return
        }
        // Bu oturumda işlenmekte olanlar (sahne yeniden kurulduysa) ikinci kez işlenmez: çift ücret, aynı dosyaya iki yazar.
        let local: Set<String>
        do {
            local = try AppPaths.localMeetingIDs()
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            return
        }
        let stale: [MeetingRecord] = staleStatusesToInterrupt(records: store.meetings.filter { local.contains($0.id) }).filter { processingSteps[$0.id] == nil }
        for record in stale {
            do {
                let directory: URL = try store.sessionDirectory(id: record.id)
                Self.logger.info("Yarıda kalan toplantı yeniden işleniyor, toplantı: \(record.id, privacy: .public)")
                guard process(record: record.with(status: .processing, failureMessage: nil), directory: directory) else {
                    continue
                }
                submitContinuedProcessing(id: record.id, subtitle: continuedProcessingSubtitle(title: record.title, startedAt: record.startedAt))
            } catch {
                errorMessages = appendUnique(messages: errorMessages, message: userFacingMessage(error: error))
            }
        }
        await runQueue()
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
        process(record: record.with(status: .processing, failureMessage: nil), directory: try store.sessionDirectory(id: meetingID))
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
        // Yüklü toplantılar giriş yapan hesabın değilse hiçbiri işlenmez: başka hesaba faturalanmaz.
        guard AppPaths.activeAccountKey() == accountDataKey(userId: userID) else {
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
                    process(record: current.with(status: .processing, failureMessage: nil).with(notice: nil), directory: directory)
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
        transcript = applyEvent(transcript: transcript, event: event)
        switch event {
        case .segment(let segment):
            if segment.isFinal, !segment.text.isEmpty {
                // Dil, bölüm kesinleşince bir kez algılanır: sabit dilli kayıtta başka dildeki bölüm soluk görünür ve
                // toplantıdan atlanır.
                spokenLanguages[segment.id] = confidentSpokenLanguage(text: segment.text)
                addForTranslation(segment: segment)
                updateActivityThrottled(state: activityState())
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
        translationQueue = []
        checkpointTask?.cancel()
        checkpointTask = nil
        microphone.stop()
        levels.stop()
        endActivity()
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        consentReminderVisible = false
        guard let finished = active else {
            phase = .idle
            startedAt = nil
            stoppedAt = nil
            return
        }
        // Kapatılacak sunucu oturumu beklemeden önce alınır. Oturum kapanana dek kayıt "bitiyor"da kalır: bu arada yeni
        // kayıt başlayıp onun oturumunu ezmesin.
        let serverMeetingID: String? = HostedAccount.shared.currentMeeting?.meetingId
        do {
            // Not ve son geçiş sunucunun ek süresinde aynı oturumla sürer.
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
        process(record: record, directory: finished.directory)
    }

    /// Toplantıyı işler (ses, son geçiş, not) ve saklar: son geçiş kaydın sunucu oturumuyla (`hostedFinalPassPlan`), not
    /// o oturumun bütçesinden (oturumu yoksa hesaptan; hakkı yoksa not yazılmaz ve nedeni toplantıda görünür). Uygulama
    /// arka plana geçerse iOS'tan ek süre istenir ve varsa sürdürülen işleme görevinin ilerlemesi güncellenir; süre
    /// yetmezse toplantı açılışta yeniden işlenir (`resumeUnfinished`). Aynı toplantı aynı anda iki kez işlenmez (çift
    /// ücret, aynı dosyaya iki yazar). İşleme başlatıldıysa true; toplantı zaten işleniyorsa false.
    @discardableResult
    private func process(record: MeetingRecord, directory: URL) -> Bool {
        guard processingSteps[record.id] == nil else {
            Self.logger.warning("Toplantı zaten işleniyor, ikinci işleme başlatılmadı, toplantı: \(record.id, privacy: .public)")
            return false
        }
        saveRecord(record: record, directory: directory)
        processingSteps[record.id] = .convertingAudio
        beginBackgroundTask(id: record.id)
        processingTasks[record.id] = Task {
            let finalPass: FinalPassPlan = await hostedFinalPassPlan(
                keyterms: keytermsWithAttendees(attendees: record.attendees ?? [], keyterms: phoneRecognitionKeyterms(records: store.meetings, people: store.peopleBook), limit: 30),
                recordID: record.id
            )
            let llm: LLMProvider? = recordedMeetingLLMReportingFailure(recordID: record.id)
            let result: MeetingRecord = await processMeeting(
                record: record, directory: directory, finalPass: finalPass, llm: llm,
                languageMode: record.language.map { LanguageMode.fixed($0) } ?? .automatic, userName: phoneUserName(),
                // The iPhone does not capture screens: notes are text only.
                noteLanguage: phoneNoteLanguage(), voiceEmbedder: nil, registry: [], screens: .off
            ) { (step: ProcessingStep) async -> Void in
                self.processingSteps[record.id] = step
                self.continuedTasks[record.id]?.progress.completedUnitCount = continuedProcessingCompletedUnits(step: step)
                if step == .writingNote {
                    self.noteWritingStartedAt[record.id] = .now
                }
            }
            processingTasks[record.id] = nil
            guard !Task.isCancelled else {
                // Sistem görevi sona erdi: yarım sonuç saklanmaz; toplantı diskte `processing` kalır ve açılışta
                // kaldığı yerden işlenir (`resumeUnfinished`).
                Self.logger.warning("İşleme iptal edildi, toplantı açılışta yeniden işlenecek, toplantı: \(record.id, privacy: .public)")
                processingSteps[record.id] = nil
                endBackgroundTask(id: record.id)
                return
            }
            recordNoteOutcome(result: result, writingStartedAt: noteWritingStartedAt.removeValue(forKey: record.id))
            // Tekrar işlemede eski not geçmişe girer (ilk işlemede not yoktur; Mac'teki gibi).
            let versioned: MeetingRecord = withNoteVersion(updated: result, previous: record, reason: String(localized: "Tekrar işlendi"), savedAt: Date())
            saveRecord(record: versioned, directory: directory)
            processingSteps[record.id] = nil
            finishContinuedTask(meetingID: record.id, success: versioned.status == .done)
            // Son geçişin ses süresi aylık kullanıma sayılır: hesap durumu yenilenir.
            await HostedAccount.shared.refresh()
            endBackgroundTask(id: record.id)
            // Sıradaki bekleyen (çevrimdışı) kayıt.
            await runQueue()
        }
        return true
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
        return transcript.filter { !$0.text.isEmpty && !skipped.contains($0.id) }
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

    /// Tek dosyayı içe aktarır; olmazsa yarım klasör silinir ve neden listede görünür.
    private func importOne(url: URL) async {
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
                id: recordID, source: url, startedAt: session.startedAt, durationSec: duration, engine: .cloud, template: phoneNoteTemplate()
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
        } catch {
            Self.logger.error("Dosya içe aktarılamadı, hata: \(String(describing: error), privacy: .private)")
            importErrors = appendUnique(
                messages: importErrors, message: String(localized: "\(url.lastPathComponent) içe aktarılamadı: \(mediaImportMessage(error: error))")
            )
            if let created {
                do {
                    try FileManager.default.removeItem(at: created)
                } catch {
                    Self.logger.error("Yarım içe aktarma klasörü silinemedi, hata: \(String(describing: error), privacy: .private)")
                }
            }
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
                Self.logger.warning("Arka plan süresi doldu, toplantı açılışta işlenecek, toplantı: \(id, privacy: .public)")
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
        guard let last = transcript.last(where: { $0.isFinal && !$0.text.isEmpty }) else {
            return ("", "")
        }
        return (last.text, last.person.map { speakerLabel(speaker: last.id.speaker, person: $0) } ?? "")
    }

    /// Canlı etkinliğin şimdiki durumu: son cümle, bitiriliyor mu, mikrofon bekleniyor mu, süre durduysa anı.
    private func activityState() -> RecordingActivityAttributes.ContentState {
        let line: (text: String, speaker: String) = activityLine
        return RecordingActivityAttributes.ContentState(
            lastLine: line.text, speaker: line.speaker, isFinishing: phase == .finishing, isMicrophonePaused: microphoneStatus != .running,
            stoppedAt: stoppedAt
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
    private func updateActivityThrottled(state: RecordingActivityAttributes.ContentState) {
        guard Date().timeIntervalSince(lastActivityUpdate) >= 2 else {
            return
        }
        updateActivityNow(state: state)
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
    private func addForTranslation(segment: LiveSegment) {
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
        step.ready.forEach { (unit: TranslationUnit) -> Void in enqueueTranslation(unit: unit) }
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
        step.ready.forEach { (unit: TranslationUnit) -> Void in enqueueTranslation(unit: unit) }
        // Süre saat payı yüzünden henüz dolmadıysa bekleme yeniden kurulur: yarım birim takılı kalmaz.
        scheduleIdleFlush(speaker: speaker)
    }

    /// Kayıt sonu: sessizlik beklemeleri iptal edilir, bütün yarım birimler çeviriye gider.
    private func flushAllUnits() {
        idleFlushTasks.values.forEach { $0.cancel() }
        idleFlushTasks = [:]
        let step: TranslationUnitStep = flushingAll(builder: unitBuilder)
        unitBuilder = step.builder
        step.ready.forEach { (unit: TranslationUnit) -> Void in enqueueTranslation(unit: unit) }
    }

    /// Birimi kaydın birimlerine ekleyip çeviri sırasına alır. Metni sabit toplantı dilinden başka dildeyse çevrilmez
    /// (toplantıdan zaten atlanır; maliyet), bölümleri soluk kalır.
    private func enqueueTranslation(unit: TranslationUnit) {
        if isOtherLanguageUnit(unit: unit, fixedLanguage: recordingFixedLanguage) {
            languageSkippedSegments.formUnion(unit.segmentIDs)
            Self.logger.info("Başka dildeki birim çevrilmedi, birim sonu: \(segmentKey(id: unit.carrierID), privacy: .public), bölüm sayısı: \(unit.segmentIDs.count, privacy: .public)")
            return
        }
        translationUnits.append(unit)
        translationQueue.append(unit)
        startQueuedTranslations()
    }

    private func startQueuedTranslations() {
        guard let provider = active?.liveLLM else {
            return
        }
        while translationsInFlight < Self.maxParallelTranslations, !translationQueue.isEmpty {
            let unit: TranslationUnit = translationQueue.removeFirst()
            let context: [String] = translationContext(units: translationUnits, before: unit, count: 3)
            let requestGeneration: Int = generation
            translationsInFlight += 1
            Task {
                do {
                    let translated: String = try await translateSentence(provider: provider, sentence: unit.text, context: context, language: phoneNoteLanguage())
                    recordFeatureUsage(feature: .liveTranslation(phoneNoteLanguage()))
                    // Cümle zaten not dilindeyse (model aynen döndürdü) çeviri saklanmaz: aynı cümle iki kez görünmesin.
                    if requestGeneration == generation, isDistinctTranslation(original: unit.text, translated: translated) {
                        translations = applyingUnitTranslation(translations: translations, unit: unit, translation: translated)
                    }
                } catch {
                    Self.logger.error("Çeviri başarısız, birim sonu: \(segmentKey(id: unit.carrierID), privacy: .public), bölüm sayısı: \(unit.segmentIDs.count, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                    if requestGeneration == generation {
                        errorMessages = appendUnique(messages: errorMessages, message: String(localized: "Çeviri: \(userFacingMessage(error: error))"))
                    }
                }
                translationsInFlight -= 1
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
            liveSegments: storedSegments(transcript: transcript, spokenLanguages: spokenLanguages), finalSegments: [],
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
                self.saveRecord(record: self.liveRecord(recording: recording, status: .recording, endedAt: nil), directory: recording.directory)
                // Sessizlikte de canlı etkinlik tazelenir: uygulama kapanırsa 2 dk sonra eskimiş görünür, saymayı sürdürmez.
                self.updateActivityNow(state: self.activityState())
            }
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
