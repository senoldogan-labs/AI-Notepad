import AINotepadCore
import Foundation
import KeyboardCore
import Observation
import os
import UIKit

private let keyboardHostLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "KeyboardHost")

/// Bundan kısa ses yazıya dökülmez ("Konuşma duyulmadı"): 16 kHz'de 0,25 sn (Sor'daki gibi).
private let keyboardMinimumSamples: Int = 4000

/// Klavye ayarlarının anahtarları (cihaz ayarı; hesaba bağlı değil).
enum PhoneKeyboardKey {
    static let languages: String = "keyboard.languages"
    static let autocorrect: String = "keyboard.autocorrect"
    static let sessionMinutes: String = "keyboard.sessionMinutes"
    static let meetingNotes: String = "keyboard.meetingNotes"
    static let voiceLanguage: String = "keyboard.voiceLanguage"
    static let swipeTyping: String = "keyboard.swipeTyping"
    static let mechanicalSounds: String = "keyboard.mechanicalSounds"
    /// When the keyboard last inserted a dictation (its `acknowledge` of a finished one): the setup's and the hub's proof
    /// that voice typing works on this iPhone. Only a time; no text.
    static let lastDictationSucceededAt: String = "keyboard.lastDictationSucceededAt"
}

/// Dikte modelinin hazırlığı (kurulumda; ilk dikte indirmeyi beklemesin).
enum PhoneKeyboardPreparation: Equatable {
    case idle
    case preparing(progress: Double?)
    case ready
    case failed(String)
}

/// How long the warm session waits for an interrupted microphone to come back before it ends.
let keyboardInterruptionGrace: TimeInterval = 60

/// Klavyenin sesle yazmasının uygulama tarafı: klavye uzantısı mikrofona erişemediği için sesi Gistsmith dinler.
///
/// Mikrofon kapalıyken klavye `gistsmith://keyboard/dictate/<istek>` ile uygulamayı açar; bağlantı yalnız App Group'ta
/// aynı istek için az önce yazılmış başlatma komutu varsa mikrofonu açar (`keyboardStartCommandIsValid`) ve yalnız
/// ısıtır: kullanıcı uygulamasına döner, klavyede yeniden dokununca dikte yerinde başlar (Darwin bildirimi,
/// `keyboardCommandStartsDictation`), ara metin klavyede akar. Mikrofon oturumu son dikteden
/// sonra ayardaki süre açık kalır: kullanıcı uygulamalar arasında gidip gelmeden yeniden dikte
/// edebilir. Dikte dışındaki ses hemen atılır, hiçbir yere yazılmaz. Oturum süre dolunca, kayıt başlayınca, ses bir
/// dakikadan uzun kesilince (çağrı) ve hesap değişince kapanır; telefon kilitlenince açık kalır (süre işler, turuncu nokta
/// ve canlı etkinlik görünür), kilit açılınca klavye yeniden uygulamaya gitmeden dikte eder. Yazıya dökme cihazda (`AppleDictationEngine`,
/// iOS 26+), kullanıcının sözlüğünden gelen en fazla 100 ipucuyla; ses ve metin hiçbir sunucuya gitmez.
@MainActor
@Observable
final class PhoneKeyboardHost {
    static let shared: PhoneKeyboardHost = PhoneKeyboardHost()

    /// Bağlantıyla açılan "dinliyor, uygulamana dön" sayfası.
    var isShowingSessionScreen: Bool = false
    /// The short "microphone ready" pop-up shown after the keyboard's first tap opened the app (`PhoneKeyboardHandoffPopup`).
    var isShowingHandoff: Bool = false
    /// Kurulum sayfası (Ayarlar'dan ya da klavyeden açılır).
    var isShowingSetup: Bool = false
    private(set) var isSessionActive: Bool = false
    private(set) var dictation: KeyboardDictation?
    private(set) var preparation: PhoneKeyboardPreparation = .idle
    /// Klavyenin son görülmesi (Tam Erişim açıkken klavye yazar).
    private(set) var report: KeyboardReport?
    /// Bu iPhone'un cihaz içi diktesinin dilleri (iOS 26+; boşsa henüz okunmadı ya da desteklenmiyor).
    private(set) var dictationLanguageCodes: [String] = []
    /// The last dictation the keyboard inserted (see `PhoneKeyboardKey.lastDictationSucceededAt`).
    private(set) var lastDictationSucceededAt: Date? = UserDefaults.standard.object(forKey: PhoneKeyboardKey.lastDictationSucceededAt) as? Date
    /// Bumped whenever the keyboard reports (`report.json` + Darwin signal), so the setup re-reads its facts at once.
    private(set) var reportRevision: Int = 0

    /// Yüklü hesabın tanıma ipuçları (ad, sözlük, kişiler, toplantı terimleri).
    @ObservationIgnored var recognitionTerms: @MainActor () -> [String] = { [] }
    /// Klavyeye gidecek kendi sözlüğü (ad ve tanıma sözlüğü) ve toplantılardan gelen adlar ve terimler.
    @ObservationIgnored var vocabularySources: @MainActor () -> (own: [String], meetingDerived: [String]) = { ([], []) }
    /// Klavyedeki toplantı listesi (yalnız ayar açıkken yazılır).
    @ObservationIgnored var meetingSnapshot: @MainActor () -> KeyboardMeetingSnapshot = { KeyboardMeetingSnapshot(meetings: []) }
    /// Toplantı kaydı sürüyor mu.
    @ObservationIgnored var isRecordingMeeting: @MainActor () -> Bool = { false }
    /// Bu cihazda oturum açık mı: kapalıyken (çıkış, hesap silme) hesabın sözlüğü ve toplantıları klavyeye yazılmaz.
    @ObservationIgnored var isAccountSignedIn: @MainActor () -> Bool = { false }
    /// Mikrofonu açmadan önce (Sor'daki sesle soru bırakılır; ses oturumu paylaşılır).
    @ObservationIgnored var onWillUseMicrophone: @MainActor () -> Void = {}

    @ObservationIgnored private let engine: AppleDictationEngine = AppleDictationEngine()
    @ObservationIgnored private var bridge: KeyboardBridge?
    @ObservationIgnored private var commandObserver: KeyboardSignalObserver?
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var feed: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var fedSamples: Int = 0
    @ObservationIgnored private var transcription: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var dictationLimit: Task<Void, Never>?
    @ObservationIgnored private var session: KeyboardSession?
    /// The open microphone session's identity: a late failure of an earlier session's microphone start is dropped
    /// (`keyboardMicrophoneFailureApplies`).
    @ObservationIgnored private var microphoneSession: UUID?
    /// Süren diktenin başladığı an: takılan hazırlık ya da bitirme mikrofonu süresiz açık tutmasın.
    @ObservationIgnored private var dictationStartedAt: Date?
    /// Since when the microphone is interrupted (another app's audio, Siri, a call): the heartbeat stops so the keyboard
    /// does not dictate into a dead microphone, and the session ends only if the interruption lasts.
    @ObservationIgnored private var interruptedSince: Date?
    @ObservationIgnored private var reportObserver: KeyboardSignalObserver?
    /// Unlock: the status written while the iPhone was locked failed (complete file protection), so it is written again.
    /// A session that ended while locked then leaves no text in the shared folder.
    @ObservationIgnored private var unlockObserver: (any NSObjectProtocol)?
    /// The request whose link opened the app to warm the microphone: its Darwin notification must not start a dictation.
    @ObservationIgnored private var warmedRequestID: UUID?
    /// The running transcription's identity: a cancelled attempt's late result never lands on a newer dictation, even
    /// one with the same request id.
    @ObservationIgnored private var dictationAttempt: UUID?
    /// The Dynamic Island / Lock Screen presence of the warm microphone.
    @ObservationIgnored private let activity: PhoneKeyboardActivity = PhoneKeyboardActivity()

    private init() {}

    // MARK: Bağlantı ve paylaşılan dosyalar

    /// App Group'a bağlanır ve klavyenin komutlarını dinlemeye başlar (uygulama açılışında bir kez).
    func start() {
        guard bridge == nil else {
            return
        }
        do {
            bridge = try KeyboardBridge(containerURL: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: keyboardAppGroupIdentifier))
        } catch {
            keyboardHostLogger.error("Klavyenin App Group kabı açılamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
        commandObserver = KeyboardSignalObserver(signal: .command) { [weak self] in
            self?.commandArrived()
        }
        reportObserver = KeyboardSignalObserver(signal: .report) { [weak self] in
            self?.refreshReport()
        }
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] (_: Notification) in
            MainActor.assumeIsolated {
                self?.writeStatus()
            }
        }
        // A session left by a killed app has no microphone behind it: its Live Activity goes (not the one a session opened in this launch).
        activity.endLeftovers()
        // Uygulama kapalıyken ya da askıdayken klavyenin eklediği veya bıraktığı sonuç ya da kapanan oturumdan kalan metin
        // silinir.
        clearAcknowledgedResult()
        clearOrphanedText()
        refreshReport()
        Task {
            await loadDictationLanguages()
        }
    }

    /// Klavyenin son görülmesini yeniden okur (kurulum sayfası açılınca ve uygulama öne gelince).
    func refreshReport() {
        guard let bridge else {
            return
        }
        do {
            report = try bridge.read(KeyboardReport.self, file: .report)
            reportRevision += 1
        } catch {
            keyboardHostLogger.error("Klavye raporu okunamadı, hata: \(String(describing: error), privacy: .public)")
        }
    }

    /// Ayarları, sözlüğü ve (ayar açıksa) toplantı listesini klavyeye yazar; ayar kapalıysa liste silinir. Ayarlar,
    /// toplantılar ya da hesap değişince çağrılır.
    func syncShared() {
        guard let bridge else {
            return
        }
        let defaults: UserDefaults = .standard
        // Oturum yokken klavyede hesabın hiçbir verisi kalmaz: sözlük boş, toplantı listesi silinir.
        let isSignedIn: Bool = isAccountSignedIn()
        let meetingNotes: Bool = isSignedIn && defaults.bool(forKey: PhoneKeyboardKey.meetingNotes)
        let sources: (own: [String], meetingDerived: [String]) = isSignedIn ? vocabularySources() : ([], [])
        let config: KeyboardSharedConfig = KeyboardSharedConfig(
            languages: phoneKeyboardLanguages(), autocorrect: phoneKeyboardAutocorrect(),
            swipeTyping: defaults.object(forKey: PhoneKeyboardKey.swipeTyping) as? Bool ?? true,
            mechanicalSounds: defaults.bool(forKey: PhoneKeyboardKey.mechanicalSounds), sessionMinutes: phoneKeyboardSessionMinutes(),
            meetingNotesEnabled: meetingNotes, voiceLanguageCode: phoneKeyboardVoiceLanguage(),
            vocabulary: keyboardVocabulary(own: sources.own, meetingDerived: sources.meetingDerived, meetingNotesEnabled: meetingNotes, limit: 300)
        )
        do {
            try bridge.write(config, file: .config)
            if meetingNotes {
                try bridge.write(meetingSnapshot(), file: .meetings)
            } else {
                try bridge.remove(file: .meetings)
            }
        } catch {
            keyboardHostLogger.error("Klavye ayarları yazılamadı, hata: \(String(describing: error), privacy: .public)")
        }
    }

    /// Klavye dillerinin (ya da seçili sesle yazma dilinin) dikte modelini indirir; kurulum sayfası ilerlemeyi gösterir.
    @available(iOS 26, *)
    func prepareDictation() async {
        let codes: [String] = phoneKeyboardVoiceLanguage().map { [$0] } ?? phoneDictationLanguageCodes()
        preparation = .preparing(progress: nil)
        do {
            for code in codes {
                guard let locale = await appleDictationLocale(languageCode: code) else {
                    keyboardHostLogger.warning("Klavye dili için cihaz içi dikte yok, dil: \(code, privacy: .public)")
                    continue
                }
                let host: PhoneKeyboardHost = self
                try await engine.prepare(localeIdentifier: locale) { (fraction: Double) -> Void in
                    Task { @MainActor in
                        // Bitmiş hazırlığın geç gelen ilerlemesi durumu geri almasın.
                        if case .preparing = host.preparation {
                            host.preparation = .preparing(progress: fraction < 1 ? fraction : nil)
                        }
                    }
                }
            }
            preparation = .ready
        } catch {
            keyboardHostLogger.error("Klavye dikte modeli hazırlanamadı, hata: \(String(describing: error), privacy: .public)")
            preparation = .failed(userFacingMessage(error: error))
        }
    }

    /// Klavye sonucu ekledi ya da bıraktıysa (uygulama askıdayken gelen `acknowledge`/`cancel` bildirimi işlenmemiş
    /// olabilir) bellekteki dikte düşer: silinen metin diske geri yazılmaz.
    private func dropDictationReleasedByKeyboard(bridge: KeyboardBridge) {
        guard let current = dictation, current.phase == .finished || current.phase == .failed else {
            return
        }
        do {
            if let command = try bridge.read(KeyboardDictationCommand.self, file: .command), command.requestID == current.requestID,
               command.action == .acknowledge || command.action == .cancel {
                // The keyboard inserted it (its notification may not have been handled yet): that is the proof too.
                if current.phase == .finished, command.action == .acknowledge {
                    recordDictationSucceeded()
                }
                dictation = nil
            }
        } catch {
            keyboardHostLogger.error("Klavye komutu okunamadı, hata: \(String(describing: error), privacy: .public)")
        }
    }

    /// Önceki süreçte kapanmamış oturumdan kalan dikteyi (bitmiş ya da ara metin) siler: uygulama zorla kapatılınca,
    /// çökünce ya da sistem onu sonlandırınca `endSession` çalışmaz.
    private func clearOrphanedText() {
        guard let bridge else {
            return
        }
        do {
            let status: KeyboardDictationStatus? = try bridge.read(KeyboardDictationStatus.self, file: .status)
            guard keyboardStatusHasOrphanedText(status: status, now: Date()) else {
                return
            }
            try bridge.write(KeyboardDictationStatus(session: nil, dictation: nil), file: .status)
        } catch {
            keyboardHostLogger.error("Kapanan oturumdan kalan metin silinemedi, hata: \(String(describing: error), privacy: .public)")
        }
    }

    /// Son komut sonucu eklendi ya da bırakıldı dediyse (`acknowledge`, `cancel`) durumdaki o dikte silinir.
    private func clearAcknowledgedResult() {
        guard let bridge else {
            return
        }
        do {
            guard let command = try bridge.read(KeyboardDictationCommand.self, file: .command),
                  command.action == .acknowledge || command.action == .cancel,
                  let cleared = keyboardStatusClearingDictation(
                    status: try bridge.read(KeyboardDictationStatus.self, file: .status), requestID: command.requestID
                  )
            else {
                return
            }
            try bridge.write(cleared, file: .status)
        } catch {
            keyboardHostLogger.error("Klavyenin bıraktığı sonuç silinemedi, hata: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadDictationLanguages() async {
        guard #available(iOS 26, *) else {
            return
        }
        dictationLanguageCodes = await appleDictationLanguageCodes()
    }

    // MARK: Klavyeden gelenler

    /// `gistsmith://keyboard/…` bağlantısı.
    func open(route: KeyboardLinkRoute) {
        start()
        switch route {
        case .setup:
            refreshReport()
            isShowingSetup = true
        case .dictate(let requestID):
            startFromLink(requestID: requestID)
        case .ask(let requestID):
            PhoneKeyboardAskHost.shared.open(requestID: requestID)
        }
    }

    private func startFromLink(requestID: UUID) {
        guard let bridge else {
            return
        }
        let command: KeyboardDictationCommand?
        do {
            command = try bridge.read(KeyboardDictationCommand.self, file: .command)
        } catch {
            keyboardHostLogger.error("Klavye komutu okunamadı, hata: \(String(describing: error), privacy: .public)")
            command = nil
        }
        // Başka bir uygulama ya da sayfa bu bağlantıyı açtıysa (klavyenin az önce bıraktığı komut yok) mikrofon açılmaz.
        guard let command, keyboardStartCommandIsValid(command: command, requestID: requestID, now: Date()) else {
            keyboardHostLogger.warning("Klavye bağlantısı geçerli bir başlatma komutu olmadan geldi; kurulum açılıyor")
            refreshReport()
            isShowingSetup = true
            return
        }
        warm(command: command)
    }

    /// The link from the keyboard's first tap: the microphone opens (or stays open) and the app tells the user to go
    /// back; the dictation starts when they tap the keyboard again, in place. Nothing is transcribed for this tap.
    private func warm(command: KeyboardDictationCommand) {
        let appWasInFront: Bool = UIApplication.shared.applicationState == .active
        warmedRequestID = command.requestID
        if isRecordingMeeting() {
            fail(command: command, failure: .recordingMeeting)
            // The sheet says why; the keyboard shows it too.
            isShowingSessionScreen = !isShowingSetup
            return
        }
        guard #available(iOS 26, *) else {
            fail(command: command, failure: .unsupportedLanguage)
            isShowingSessionScreen = !isShowingSetup
            return
        }
        if !isSessionActive {
            openMicrophone()
        }
        // The session counts as opened now: the keyboard treats a start issued before the session opened as the warm-up
        // tap (`keyboardMicState`), also when the microphone was already warm and only the keyboard thought it was not.
        if session != nil {
            let now: Date = Date()
            session = KeyboardSession(startedAt: now, expiresAt: now.addingTimeInterval(sessionLength()), heartbeatAt: now)
        }
        writeStatus()
        // During the guided setup, or when the link found Gistsmith already in front (typing in one of its own fields),
        // the user is already in Gistsmith's own text field: the pop-up would end by sending them to the home screen and
        // taking the field away. Then only the sheet shows (not during setup), as before.
        if isShowingSetup {
            return
        }
        if appWasInFront {
            isShowingSessionScreen = true
        } else {
            isShowingHandoff = true
        }
    }

    private func commandArrived() {
        guard let bridge else {
            return
        }
        let command: KeyboardDictationCommand
        do {
            guard let read = try bridge.read(KeyboardDictationCommand.self, file: .command) else {
                return
            }
            command = read
        } catch {
            keyboardHostLogger.error("Klavye komutu okunamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
        switch command.action {
        case .start:
            // Oturum kapalıyken başlatma bağlantıyla gelir (`startFromLink`, yalnız ısıtır); burada yalnız açık oturumda,
            // her istek için bir kez başlar.
            if keyboardCommandStartsDictation(
                command: command, isSessionActive: isSessionActive, currentRequestID: dictation?.requestID, warmedRequestID: warmedRequestID, now: Date()
            ) {
                begin(command: command)
            }
        case .stop:
            if dictation?.requestID == command.requestID {
                finishDictation()
            }
        case .cancel:
            if dictation?.requestID == command.requestID {
                cancelDictation()
            }
        case .acknowledge:
            if let current = dictation, current.requestID == command.requestID {
                if current.phase == .finished {
                    recordDictationSucceeded()
                }
                dictation = nil
                writeStatus()
            }
        case .endSession:
            endSession(reason: "klavyeden bitirildi")
        }
    }

    // MARK: Oturum

    /// Dikteyi başlatır; oturum yoksa önce mikrofonu açar. Kayıt sürüyorsa ya da sistem eskiyse neden klavyeye yazılır.
    private func begin(command: KeyboardDictationCommand) {
        if isRecordingMeeting() {
            fail(command: command, failure: .recordingMeeting)
            return
        }
        guard #available(iOS 26, *) else {
            fail(command: command, failure: .unsupportedLanguage)
            return
        }
        if dictation != nil {
            cancelDictation()
        }
        // The microphone is interrupted: no dictation into silence and no answer, so the keyboard opens Gistsmith
        // (`openGistsmithUnlessStarted`) and the capture resumes when the app comes to the foreground.
        if isSessionActive, interruptedSince != nil {
            keyboardHostLogger.info("Klavye mikrofonu kesik; başlatma yanıtsız bırakıldı")
            return
        }
        if !isSessionActive {
            openMicrophone()
        }
        startDictation(command: command)
    }

    /// The keyboard inserted a dictation: the proof the setup and the hub show.
    private func recordDictationSucceeded() {
        let now: Date = Date()
        lastDictationSucceededAt = now
        UserDefaults.standard.set(now, forKey: PhoneKeyboardKey.lastDictationSucceededAt)
    }

    /// Çıkış ya da hesap silme: mikrofon kapanır, klavyedeki toplantı listesi ve hesabın sözlüğü silinir.
    func clearAccountData() {
        endSession(reason: "oturum kapandı")
        dictation = nil
        writeStatus()
        syncShared()
    }

    /// Klavyesiz oturum açar (Ayarlar › Klavye › Mikrofonu hazırla): klavyedeki mikrofon uygulamayı açmadan dikte eder.
    func startSessionManually() {
        start()
        guard !isSessionActive, !isRecordingMeeting() else {
            return
        }
        openMicrophone()
        writeStatus()
    }

    private func openMicrophone() {
        onWillUseMicrophone()
        let microphone: MicrophoneCapture = MicrophoneCapture(input: personalAudioInputRequest)
        self.microphone = microphone
        let sessionID: UUID = UUID()
        microphoneSession = sessionID
        isSessionActive = true
        let now: Date = Date()
        session = KeyboardSession(startedAt: now, expiresAt: now.addingTimeInterval(sessionLength()), heartbeatAt: now)
        interruptedSince = nil
        microphone.onStatusChange = { [weak self] (status: MicrophoneStatus) -> Void in
            // An interruption (another app's audio, Siri, the Camera; `.heldByCall` while a call holds the microphone)
            // usually ends by itself and the capture resumes (`MicrophoneCapture`): the session waits for it
            // (`keyboardInterruptionGrace`) instead of ending, so the next tap still dictates in place.
            guard let self else {
                return
            }
            if isMicrophoneInterrupted(status: status) {
                if self.interruptedSince == nil {
                    self.interruptedSince = Date()
                    keyboardHostLogger.info("Klavye mikrofonu kesildi; oturum bekliyor")
                }
            } else if status == .running, self.interruptedSince != nil {
                self.interruptedSince = nil
                keyboardHostLogger.info("Klavye mikrofonu yeniden açıldı")
            }
        }
        pump = Task { [weak self] in
            let stream: AsyncStream<[Float]>
            do {
                stream = try await microphone.start()
            } catch {
                keyboardHostLogger.error("Klavye için mikrofon açılamadı, hata: \(String(describing: error), privacy: .public)")
                self?.microphoneFailed(error: error, sessionID: sessionID)
                return
            }
            for await chunk in stream {
                // Dikte yokken gelen ses atılır.
                guard let self, let feed = self.feed else {
                    continue
                }
                feed.yield(chunk)
                self.fedSamples += chunk.count
            }
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] (_: Timer) in
            MainActor.assumeIsolated {
                self?.beat()
            }
        }
        activity.start(startedAt: now, expiresAt: now.addingTimeInterval(sessionLength()))
        keyboardHostLogger.info("Klavye mikrofon oturumu açıldı, süre (sn): \(self.sessionLength(), privacy: .public)")
    }

    private func beat() {
        guard let current = session else {
            return
        }
        let now: Date = Date()
        let isDictating: Bool = dictation.map { $0.phase == .preparing || $0.phase == .listening || $0.phase == .finishing } ?? false
        if now >= current.expiresAt, !isDictating {
            endSession(reason: "süre doldu")
            return
        }
        if let since = interruptedSince {
            if now.timeIntervalSince(since) > keyboardInterruptionGrace {
                endSession(reason: "ses kesildi")
            }
            // No heartbeat while the microphone is interrupted: the keyboard opens Gistsmith instead of dictating into
            // silence.
            return
        }
        // Dinleme 5 dakikayla sınırlı; hazırlık (model indirme) ya da bitirme takılırsa da bir dakika payla kapanır.
        if isDictating, let started = dictationStartedAt, let current = dictation, now.timeIntervalSince(started) > dictationMaxListeningSec + 60 {
            keyboardHostLogger.error(
                "Klavye diktesi takıldı, mikrofon kapatılıyor; evre: \(current.phase.rawValue, privacy: .public), süre (sn): \(Int(now.timeIntervalSince(started)), privacy: .public)"
            )
            // Neden klavyede görünsün: başarısız dikte oturum kapanınca da kalır.
            transcription?.cancel()
            transcription = nil
            dictation = KeyboardDictation(
                requestID: current.requestID, documentID: current.documentID, phase: .failed, partialText: "", finalText: nil, failure: .failed
            )
            endSession(reason: "dikte takıldı")
            return
        }
        // While the iPhone is locked the shared files cannot be written (complete file protection); the session stays
        // open and the heartbeat resumes as soon as it is unlocked.
        guard UIApplication.shared.isProtectedDataAvailable else {
            return
        }
        // Dikte sürerken oturum dolmaz: süre son dikteden itibaren sayılır (klavye dinlemeyi boşta göstermesin).
        let expiresAt: Date = isDictating ? max(current.expiresAt, now.addingTimeInterval(sessionLength())) : current.expiresAt
        session = KeyboardSession(startedAt: current.startedAt, expiresAt: expiresAt, heartbeatAt: now)
        writeStatus()
    }

    /// Mikrofonu kapatır ve dikteyi atar. Eklenmemiş bitmiş metin de silinir: metin oturumdan uzun diskte kalmaz. Oturum
    /// süre dolunca (son dikteden en az bir dakika sonra), ses bir dakikadan uzun kesilince, kayıt başlayınca, Sor'da sesle soru
    /// açılınca, klavyeden ya da Ayarlar'dan bitirilince, hesap değişince ve dikte altı dakikayı aşıp takılınca (neden
    /// klavyede "yazıya dökülemedi" olarak görünür) kapanır. Uygulama kapanırsa bu çalışmaz; o
    /// zaman kalan metni klavye ve sonraki açılış siler (`keyboardStatusHasOrphanedText`). Başarısızlığın nedeni klavye onu
    /// görene dek kalır (metin taşımaz).
    func endSession(reason: String) {
        guard isSessionActive else {
            return
        }
        keyboardHostLogger.info("Klavye mikrofon oturumu kapandı, neden: \(reason, privacy: .public)")
        if let current = dictation, current.phase != .failed {
            transcription?.cancel()
            dictation = nil
        }
        feed?.finish()
        feed = nil
        transcription = nil
        dictationLimit?.cancel()
        dictationLimit = nil
        heartbeat?.invalidate()
        heartbeat = nil
        interruptedSince = nil
        microphone?.stop()
        microphone = nil
        pump?.cancel()
        pump = nil
        session = nil
        microphoneSession = nil
        dictationAttempt = nil
        warmedRequestID = nil
        isSessionActive = false
        activity.end()
        writeStatus()
    }

    /// Kayıt başlamadan önce: mikrofon kayda geçer.
    func recordingWillStart() {
        endSession(reason: "toplantı kaydı başlıyor")
    }

    private func microphoneFailed(error: any Error, sessionID: UUID) {
        // A session ended during the permission prompt fails its start with a cancellation, possibly after a newer
        // session opened: that one keeps running.
        guard keyboardMicrophoneFailureApplies(failedSession: sessionID, currentSession: microphoneSession, error: error) else {
            keyboardHostLogger.info("Önceki klavye oturumunun mikrofon hatası yok sayıldı")
            return
        }
        // Yazıya dökme görevi kapanan akışla dönüp nedeni ("konuşma duyulmadı") ezmesin.
        transcription?.cancel()
        transcription = nil
        if let current = dictation {
            dictation = KeyboardDictation(
                requestID: current.requestID, documentID: current.documentID, phase: .failed, partialText: "", finalText: nil,
                failure: isMicrophoneDenied(error) ? .microphoneDenied : .failed
            )
        } else if let warmed = warmedRequestID {
            // The warm-up tap had no dictation yet: the reason still reaches the sheet and the keyboard.
            dictation = KeyboardDictation(
                requestID: warmed, documentID: nil, phase: .failed, partialText: "", finalText: nil,
                failure: isMicrophoneDenied(error) ? .microphoneDenied : .failed
            )
        }
        // The warm-up tap's pop-up (possibly already gone: the permission prompt can outlast it) gives way to the sheet that
        // says why and how to fix it, unless the guided setup is open.
        let wasWarmUp: Bool = warmedRequestID != nil
        endSession(reason: "mikrofon açılamadı")
        if wasWarmUp, !isShowingSetup {
            isShowingHandoff = false
            isShowingSessionScreen = true
        }
    }

    private func isMicrophoneDenied(_ error: any Error) -> Bool {
        if case AudioCaptureError.microphonePermissionDenied = error {
            return true
        }
        return false
    }

    private func sessionLength() -> TimeInterval {
        TimeInterval(phoneKeyboardSessionMinutes() * 60)
    }

    // MARK: Dikte

    private func startDictation(command: KeyboardDictationCommand) {
        let requestID: UUID = command.requestID
        let attempt: UUID = UUID()
        dictationAttempt = attempt
        dictationStartedAt = Date()
        extendSession()
        dictation = KeyboardDictation(requestID: requestID, documentID: command.documentID, phase: .preparing, partialText: "", finalText: nil, failure: nil)
        writeStatus()
        let (chunks, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        feed = continuation
        fedSamples = 0
        let terms: [String] = Array(recognitionTerms().prefix(dictationContextualStringLimit))
        let engine: AppleDictationEngine = engine
        let languageCode: String = command.languageCode
        let voiceLanguage: String? = phoneKeyboardVoiceLanguage()
        // Uygulama boyunca yaşayan tek nesne: ara metin bildirimi onu güçlü tutabilir.
        let host: PhoneKeyboardHost = self
        transcription = Task { [weak self] in
            do {
                guard #available(iOS 26, *) else {
                    throw AppleSpeechError.requiresNewerSystem
                }
                guard let locale = await appleDictationLocale(languageCode: languageCode) else {
                    keyboardHostLogger.warning("Klavye dikte dili bu iPhone'da yok, dil: \(languageCode, privacy: .public)")
                    self?.unsupported(requestID: requestID, attempt: attempt)
                    return
                }
                try await engine.prepare(localeIdentifier: locale) { (_: Double) -> Void in }
                self?.update(requestID: requestID, attempt: attempt, phase: .listening, partial: "")
                let onPartial: @Sendable (String) -> Void = { (text: String) -> Void in
                    Task { @MainActor in
                        host.update(requestID: requestID, attempt: attempt, phase: nil, partial: text)
                    }
                }
                // Without an explicit voice language the spoken language is detected among the keyboard's languages
                // (the layout's current language is only the tie-break): a Finnish speaker on a Turkish layout is
                // otherwise transcribed with the Turkish model.
                let candidates: [DictationCandidateLocale] = voiceLanguage == nil ? await installedDetectionCandidates(commandLanguageCode: languageCode) : []
                let raw: String
                if candidates.count > 1 {
                    raw = try await engine.transcribe(
                        chunks: chunks, candidateLocales: candidates, preferredLocale: locale, contextualStrings: terms, onPartial: onPartial
                    )
                } else {
                    raw = try await engine.transcribe(chunks: chunks, localeIdentifier: locale, contextualStrings: terms, onPartial: onPartial)
                }
                // A cancelled attempt's stream ends early with no text: it must not report "No speech heard".
                try Task.checkCancellation()
                self?.complete(requestID: requestID, attempt: attempt, raw: raw)
            } catch is CancellationError {
                return
            } catch {
                self?.transcriptionFailed(requestID: requestID, attempt: attempt, error: error)
            }
        }
        // Tek dikte en çok 5 dakika (sesle yazmadaki sınır).
        dictationLimit?.cancel()
        dictationLimit = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(dictationMaxListeningSec))
            } catch {
                return
            }
            if self?.dictation?.requestID == requestID {
                self?.finishDictation()
            }
        }
    }

    /// Dinlemeyi bitirir; kalan ses yazıya dökülür.
    func finishDictation() {
        guard let current = dictation, current.phase == .listening || current.phase == .preparing else {
            return
        }
        feed?.finish()
        feed = nil
        dictationLimit?.cancel()
        dictationLimit = nil
        dictation = KeyboardDictation(
            requestID: current.requestID, documentID: current.documentID, phase: .finishing, partialText: current.partialText, finalText: nil, failure: nil
        )
        writeStatus()
    }

    /// Dikteyi atar; metin eklenmez.
    func cancelDictation() {
        transcription?.cancel()
        transcription = nil
        dictationAttempt = nil
        feed?.finish()
        feed = nil
        dictationLimit?.cancel()
        dictationLimit = nil
        dictation = nil
        extendSession()
        writeStatus()
    }

    private func update(requestID: UUID, attempt: UUID, phase: KeyboardDictation.Phase?, partial: String) {
        guard attempt == dictationAttempt, let current = dictation, current.requestID == requestID, current.phase != .finished, current.phase != .failed else {
            return
        }
        // Kullanıcı hazırlık sürerken bitirdiyse (`finishing`) hazırlığın sonu dinlemeye geri döndürmez.
        let next: KeyboardDictation.Phase = current.phase == .finishing ? .finishing : (phase ?? current.phase)
        dictation = KeyboardDictation(
            requestID: requestID, documentID: current.documentID, phase: next, partialText: partial, finalText: nil, failure: nil
        )
        writeStatus()
    }

    private func complete(requestID: UUID, attempt: UUID, raw: String) {
        guard attempt == dictationAttempt, let current = dictation, current.requestID == requestID, current.phase != .failed, current.phase != .finished else {
            return
        }
        transcription = nil
        let text: String? = fedSamples >= keyboardMinimumSamples ? dictationInsertText(raw: raw) : nil
        dictation = KeyboardDictation(
            requestID: requestID, documentID: current.documentID, phase: text == nil ? .failed : .finished, partialText: "", finalText: text,
            failure: text == nil ? .noSpeech : nil
        )
        extendSession()
        writeStatus()
    }

    private func transcriptionFailed(requestID: UUID, attempt: UUID, error: any Error) {
        guard attempt == dictationAttempt, let current = dictation, current.requestID == requestID, current.phase != .failed, current.phase != .finished else {
            return
        }
        keyboardHostLogger.error("Klavye diktesi yazıya dökülemedi, hata: \(String(describing: error), privacy: .private)")
        let failure: KeyboardDictationFailure =
            switch error {
            case AppleSpeechError.requiresNewerSystem: .unsupportedLanguage
            case AudioCaptureError.microphonePermissionDenied: .microphoneDenied
            default: .failed
            }
        transcription = nil
        feed?.finish()
        feed = nil
        dictation = KeyboardDictation(requestID: requestID, documentID: current.documentID, phase: .failed, partialText: "", finalText: nil, failure: failure)
        writeStatus()
    }

    private func unsupported(requestID: UUID, attempt: UUID) {
        guard attempt == dictationAttempt, let current = dictation, current.requestID == requestID else {
            return
        }
        transcription = nil
        feed?.finish()
        feed = nil
        dictation = KeyboardDictation(requestID: requestID, documentID: current.documentID, phase: .failed, partialText: "", finalText: nil, failure: .unsupportedLanguage)
        writeStatus()
    }

    private func fail(command: KeyboardDictationCommand, failure: KeyboardDictationFailure) {
        dictation = KeyboardDictation(requestID: command.requestID, documentID: command.documentID, phase: .failed, partialText: "", finalText: nil, failure: failure)
        writeStatus()
    }

    /// Oturumun süresi son dikteden itibaren yeniden başlar.
    private func extendSession() {
        guard let current = session else {
            return
        }
        let now: Date = Date()
        session = KeyboardSession(startedAt: current.startedAt, expiresAt: now.addingTimeInterval(sessionLength()), heartbeatAt: now)
    }

    private func writeStatus() {
        guard let bridge else {
            return
        }
        dropDictationReleasedByKeyboard(bridge: bridge)
        if let session {
            let isListening: Bool = dictation.map { $0.phase == .preparing || $0.phase == .listening || $0.phase == .finishing } ?? false
            activity.update(expiresAt: session.expiresAt, isListening: isListening)
        }
        do {
            try bridge.write(KeyboardDictationStatus(session: session, dictation: dictation), file: .status)
        } catch {
            keyboardHostLogger.error("Klavye durumu yazılamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
        bridge.post(.status)
    }
}

/// Dictation models being downloaded in the background (one download per locale; a finished one stays listed, as
/// the model is then installed).
@MainActor
private var dictationModelDownloads: Set<String> = []

/// Dictation locales whose models are installed for the command's language and the keyboard's languages (at most
/// three, command language first, Norwegian as "nb").
@available(iOS 26, *)
@MainActor
private func installedDetectionCandidates(commandLanguageCode: String) async -> [DictationCandidateLocale] {
    let codes: [String] = dictationCandidateCodes(
        commandLanguageCode: commandLanguageCode, layoutLanguageCodes: phoneDictationLanguageCodes(), limit: 3
    )
    var candidates: [DictationCandidateLocale] = []
    for code in codes {
        if let locale = await installedAppleDictationLocale(languageCode: code) {
            candidates.append(DictationCandidateLocale(locale: locale))
        } else if let missing = await appleDictationLocale(languageCode: code), !dictationModelDownloads.contains(missing) {
            dictationModelDownloads.insert(missing)
            // Not installed yet (the keyboard was set up before this language counted): it is downloaded in the
            // background and takes part from the next dictation on.
            keyboardHostLogger.warning("Dikte dili modeli kurulu değil, indiriliyor, dil: \(code, privacy: .public)")
            Task.detached(priority: .utility) {
                do {
                    try await AppleDictationEngine().prepare(localeIdentifier: missing) { (_: Double) -> Void in }
                } catch {
                    // A failed download may be tried again on a later dictation.
                    await MainActor.run { _ = dictationModelDownloads.remove(missing) }
                    keyboardHostLogger.error("Dikte dili modeli indirilemedi, dil: \(code, privacy: .public), hata: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
    return candidates
}

/// Languages the user may speak: the keyboard's languages, then the language of the iPhone's region (a Finnish
/// speaker in Finland whose keyboard only lists Turkish and English). Norwegian as "nb".
func phoneDictationLanguageCodes() -> [String] {
    let layouts: [String] = phoneKeyboardLanguages().map { (language: KeyboardLanguage) -> String in language.rawValue }
    guard let region = Locale.current.region?.identifier,
          let regionLanguage = Locale.Language(identifier: "und-\(region)").maximalIdentifier.split(separator: "-").first.map(String.init),
          let keyboardLanguage = keyboardLanguage(identifier: regionLanguage)
    else {
        return layouts
    }
    return layouts.contains(keyboardLanguage.rawValue) ? layouts : layouts + [keyboardLanguage.rawValue]
}

// MARK: Ayarlar

/// Klavye dilleri (Ayarlar › Klavye); seçilmemişse cihazın dillerinden.
func phoneKeyboardLanguages() -> [KeyboardLanguage] {
    let stored: [KeyboardLanguage] = (UserDefaults.standard.stringArray(forKey: PhoneKeyboardKey.languages) ?? []).compactMap(KeyboardLanguage.init(rawValue:))
    return stored.isEmpty ? defaultKeyboardLanguages(preferredLanguages: Locale.preferredLanguages) : stored
}

/// Kendiliğinden düzeltme (varsayılan açık).
func phoneKeyboardAutocorrect() -> Bool {
    UserDefaults.standard.object(forKey: PhoneKeyboardKey.autocorrect) as? Bool ?? true
}

/// Mikrofon oturumunun süresi (dakika), izin verilen seçeneklerden biri.
func phoneKeyboardSessionMinutes() -> Int {
    let stored: Int = UserDefaults.standard.integer(forKey: PhoneKeyboardKey.sessionMinutes)
    return keyboardSessionMinuteChoices.contains(stored) ? stored : keyboardDefaultSessionMinutes
}

/// Sesle yazma dili; nil ise konuşulan dil, klavyelerin dilleri arasından algılanır (klavyenin o anki dili yalnız eşitlikte kazanır).
func phoneKeyboardVoiceLanguage() -> String? {
    let stored: String = UserDefaults.standard.string(forKey: PhoneKeyboardKey.voiceLanguage) ?? ""
    return stored.isEmpty ? nil : stored
}

/// Klavyedeki "Gistsmith'ten ekle" listesi: örnek toplantı dışındaki, notu olan son 20 toplantı. Saf fonksiyondur.
func phoneKeyboardMeetingSnapshot(records: [MeetingRecord], userName: String) -> KeyboardMeetingSnapshot {
    let items: [KeyboardMeetingItem] = realMeetings(records: records)
        .filter { $0.note != nil }
        .sorted { $0.startedAt > $1.startedAt }
        .prefix(20)
        .compactMap { (record: MeetingRecord) -> KeyboardMeetingItem? in
            guard let note = record.note else {
                return nil
            }
            let tasks: [NoteTask] = namedTasks(record: record, userName: userName)
            return KeyboardMeetingItem(
                id: record.id, title: note.title.isEmpty ? record.title : note.title, date: record.startedAt, summary: note.summary,
                actionItems: tasks.map { $0.owner.isEmpty ? $0.description : "\($0.owner): \($0.description)" },
                myTasks: tasks.filter(\.isMine).map(\.description)
            )
        }
    return KeyboardMeetingSnapshot(meetings: items)
}
