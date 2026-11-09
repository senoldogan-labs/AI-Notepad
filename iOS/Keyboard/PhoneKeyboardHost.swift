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
}

/// Dikte modelinin hazırlığı (kurulumda; ilk dikte indirmeyi beklemesin).
enum PhoneKeyboardPreparation: Equatable {
    case idle
    case preparing(progress: Double?)
    case ready
    case failed(String)
}

/// Klavyenin sesle yazmasının uygulama tarafı: klavye uzantısı mikrofona erişemediği için sesi Gistsmith dinler.
///
/// Klavye `gistsmith://keyboard/dictate/<istek>` ile uygulamayı açar; bağlantı yalnız App Group'ta aynı istek için az
/// önce yazılmış başlatma komutu varsa mikrofonu açar (`keyboardStartCommandIsValid`). Mikrofon oturumu son dikteden
/// sonra ayardaki süre (1, 5 ya da 15 dakika) açık kalır: kullanıcı uygulamalar arasında gidip gelmeden yeniden dikte
/// edebilir. Dikte dışındaki ses hemen atılır, hiçbir yere yazılmaz. Oturum süre dolunca, kayıt başlayınca, ses
/// kesilince (çağrı), telefon kilitlenince ve hesap değişince kapanır. Yazıya dökme cihazda (`AppleDictationEngine`,
/// iOS 26+), kullanıcının sözlüğünden gelen en fazla 100 ipucuyla; ses ve metin hiçbir sunucuya gitmez.
@MainActor
@Observable
final class PhoneKeyboardHost {
    static let shared: PhoneKeyboardHost = PhoneKeyboardHost()

    /// Bağlantıyla açılan "dinliyor, uygulamana dön" sayfası.
    var isShowingSessionScreen: Bool = false
    /// Kurulum sayfası (Ayarlar'dan ya da klavyeden açılır).
    var isShowingSetup: Bool = false
    private(set) var isSessionActive: Bool = false
    private(set) var dictation: KeyboardDictation?
    private(set) var preparation: PhoneKeyboardPreparation = .idle
    /// Klavyenin son görülmesi (Tam Erişim açıkken klavye yazar).
    private(set) var report: KeyboardReport?
    /// Bu iPhone'un cihaz içi diktesinin dilleri (iOS 26+; boşsa henüz okunmadı ya da desteklenmiyor).
    private(set) var dictationLanguageCodes: [String] = []

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
    @ObservationIgnored private var lockObserver: (any NSObjectProtocol)?

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
            languages: phoneKeyboardLanguages(), autocorrect: phoneKeyboardAutocorrect(), sessionMinutes: phoneKeyboardSessionMinutes(),
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
        let codes: [String] = phoneKeyboardVoiceLanguage().map { [$0] } ?? phoneKeyboardLanguages().map(\.rawValue)
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
        isShowingSessionScreen = true
        begin(command: command)
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
            // Oturum kapalıyken başlatma bağlantıyla gelir (`startFromLink`); burada yalnız açık oturumda başlar.
            if isSessionActive {
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
            if dictation?.requestID == command.requestID {
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
        if !isSessionActive {
            openMicrophone()
        }
        startDictation(command: command)
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
        let microphone: MicrophoneCapture = MicrophoneCapture()
        self.microphone = microphone
        isSessionActive = true
        let now: Date = Date()
        session = KeyboardSession(startedAt: now, expiresAt: now.addingTimeInterval(sessionLength()), heartbeatAt: now)
        microphone.onStatusChange = { [weak self] (status: MicrophoneStatus) -> Void in
            if status == .interrupted {
                self?.endSession(reason: "ses kesildi")
            }
        }
        // Telefon kilitlenince oturum kapanır: kilitli ekranda mikrofon açık kalmaz. Parolalı cihazda veri koruması
        // bildirir; parolasız cihazda bu bildirim gelmez, orada süre dolunca kapanır (gizlilik metninde yazılı).
        lockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
        ) { [weak self] (_: Notification) in
            MainActor.assumeIsolated {
                self?.endSession(reason: "telefon kilitlendi")
            }
        }
        pump = Task { [weak self] in
            let stream: AsyncStream<[Float]>
            do {
                stream = try await microphone.start()
            } catch {
                keyboardHostLogger.error("Klavye için mikrofon açılamadı, hata: \(String(describing: error), privacy: .public)")
                self?.microphoneFailed(error: error)
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
        // Dikte sürerken oturum dolmaz: süre son dikteden itibaren sayılır (klavye dinlemeyi boşta göstermesin).
        let expiresAt: Date = isDictating ? max(current.expiresAt, now.addingTimeInterval(sessionLength())) : current.expiresAt
        session = KeyboardSession(startedAt: current.startedAt, expiresAt: expiresAt, heartbeatAt: now)
        writeStatus()
    }

    /// Mikrofonu kapatır ve dikteyi atar. Eklenmemiş bitmiş metin de silinir: metin oturumdan uzun diskte kalmaz. Oturum
    /// süre dolunca (son dikteden en az bir dakika sonra), kilitte, ses kesilince, kayıt başlayınca, Sor'da sesle soru
    /// açılınca, klavyeden ya da Ayarlar'dan bitirilince ve hesap değişince kapanır. Uygulama kapanırsa bu çalışmaz; o
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
        if let lockObserver {
            NotificationCenter.default.removeObserver(lockObserver)
        }
        lockObserver = nil
        microphone?.stop()
        microphone = nil
        pump?.cancel()
        pump = nil
        session = nil
        isSessionActive = false
        writeStatus()
    }

    /// Kayıt başlamadan önce: mikrofon kayda geçer.
    func recordingWillStart() {
        endSession(reason: "toplantı kaydı başlıyor")
    }

    private func microphoneFailed(error: any Error) {
        // Yazıya dökme görevi kapanan akışla dönüp nedeni ("konuşma duyulmadı") ezmesin.
        transcription?.cancel()
        transcription = nil
        if let current = dictation {
            dictation = KeyboardDictation(
                requestID: current.requestID, documentID: current.documentID, phase: .failed, partialText: "", finalText: nil,
                failure: isMicrophoneDenied(error) ? .microphoneDenied : .failed
            )
        }
        endSession(reason: "mikrofon açılamadı")
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
        extendSession()
        dictation = KeyboardDictation(requestID: requestID, documentID: command.documentID, phase: .preparing, partialText: "", finalText: nil, failure: nil)
        writeStatus()
        let (chunks, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        feed = continuation
        fedSamples = 0
        let terms: [String] = Array(recognitionTerms().prefix(dictationContextualStringLimit))
        let engine: AppleDictationEngine = engine
        let languageCode: String = command.languageCode
        // Uygulama boyunca yaşayan tek nesne: ara metin bildirimi onu güçlü tutabilir.
        let host: PhoneKeyboardHost = self
        transcription = Task { [weak self] in
            do {
                guard #available(iOS 26, *) else {
                    throw AppleSpeechError.requiresNewerSystem
                }
                guard let locale = await appleDictationLocale(languageCode: languageCode) else {
                    keyboardHostLogger.warning("Klavye dikte dili bu iPhone'da yok, dil: \(languageCode, privacy: .public)")
                    self?.unsupported(requestID: requestID)
                    return
                }
                try await engine.prepare(localeIdentifier: locale) { (_: Double) -> Void in }
                self?.update(requestID: requestID, phase: .listening, partial: "")
                let raw: String = try await engine.transcribe(chunks: chunks, localeIdentifier: locale, contextualStrings: terms) { (text: String) -> Void in
                    Task { @MainActor in
                        host.update(requestID: requestID, phase: nil, partial: text)
                    }
                }
                self?.complete(requestID: requestID, raw: raw)
            } catch is CancellationError {
                return
            } catch {
                self?.transcriptionFailed(requestID: requestID, error: error)
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
        feed?.finish()
        feed = nil
        dictationLimit?.cancel()
        dictationLimit = nil
        dictation = nil
        extendSession()
        writeStatus()
    }

    private func update(requestID: UUID, phase: KeyboardDictation.Phase?, partial: String) {
        guard let current = dictation, current.requestID == requestID, current.phase != .finished, current.phase != .failed else {
            return
        }
        dictation = KeyboardDictation(
            requestID: requestID, documentID: current.documentID, phase: phase ?? current.phase, partialText: partial, finalText: nil, failure: nil
        )
        writeStatus()
    }

    private func complete(requestID: UUID, raw: String) {
        guard let current = dictation, current.requestID == requestID, current.phase != .failed, current.phase != .finished else {
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

    private func transcriptionFailed(requestID: UUID, error: any Error) {
        guard let current = dictation, current.requestID == requestID, current.phase != .failed, current.phase != .finished else {
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

    private func unsupported(requestID: UUID) {
        guard let current = dictation, current.requestID == requestID else {
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
        do {
            try bridge.write(KeyboardDictationStatus(session: session, dictation: dictation), file: .status)
        } catch {
            keyboardHostLogger.error("Klavye durumu yazılamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
        bridge.post(.status)
    }
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

/// Sesle yazma dili; nil ise klavyenin o anki dili.
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
