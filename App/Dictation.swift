import AINotepadCore
import AINotepadUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import os

private let dictationLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Dictation")

/// Bundan kısa ses yazıya dökülmez ("Konuşma duyulmadı"): 16 kHz'de 0,25 sn.
private let dictationMinimumSamples: Int = 4000

/// Yapıştırmadan sonra hedef uygulamanın panoyu okuması için beklenen süre; sonra pano eski haline döner.
private let pasteboardRestoreDelay: Duration = .milliseconds(400)

/// Hata ve bilgi mesajlarının hapta kalma süresi.
private let pillMessageDuration: Duration = .seconds(4)

/// Sesle yazma mikrofonu kapandıktan sonra bu süre içinde de "mikrofonu biz açtık" sayılır (görüşme izleyicisi 5 sn'de
/// bir bakar). Saf fonksiyondur.
func dictationMicClosedRecently(closedAt: Date?, now: Date) -> Bool {
    guard let closedAt else {
        return false
    }
    return now.timeIntervalSince(closedAt) < 6
}

/// Sesle yazma hatasının hapta önem derecesi: ayar ya da izin meselesi (desteklenmeyen dil, parola alanı, mikrofon izni)
/// dikkat (amber), gerisi hata (kırmızı). Saf fonksiyondur.
func dictationFailureSeverity(error: any Error) -> NoticeSeverity {
    switch error {
    case is DictationError, AudioCaptureError.microphonePermissionDenied:
        .attention
    default:
        .error
    }
}

/// Erişilebilirlik izni verilmiş mi (sormadan okunur).
@MainActor
func isAccessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
}

/// Erişilebilirlik iznini macOS'un kendi penceresiyle ister (izin zaten varsa pencere açılmaz) ve Sistem Ayarları'nda
/// Erişilebilirlik bölümünü açar. Yalnızca kullanıcı Ayarlar'da düğmeye basınca çağrılır.
@MainActor
func requestAccessibilityPermission() {
    // "AXTrustedCheckOptionPrompt" = `kAXTrustedCheckOptionPrompt` (genel değişken Swift 6'da eşzamanlılık uyarısı verir).
    let options: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }
}

/// Hapa tıklanınca yapılacak iş.
enum DictationPillAction: Equatable {
    /// Giriş ekranını aç (abonelik, oturum yok).
    case signIn
    /// Ayarlar › Sesle yazma'yı aç (izin ver).
    case openSettings
    /// Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon'u aç (mikrofon izni yok).
    case openMicrophonePrivacy
}

/// Hata için hapın eylemi: mikrofon izni yoksa Sistem Ayarları'nın Mikrofon bölümü; başka hatada eylem yok. Saf
/// fonksiyondur.
func dictationFailureAction(error: any Error) -> DictationPillAction? {
    if case AudioCaptureError.microphonePermissionDenied = error {
        return .openMicrophonePrivacy
    }
    return nil
}

/// Erişilebilirlikle odaktaki öğe: metin alanı mı (bkz. `dictationFocus`). Okunamazsa bilinmez sayılır (yapıştırmak
/// denenir).
@MainActor
func focusedDictationTarget() -> DictationFocus {
    let systemWide: AXUIElement = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    let status: AXError = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
    switch status {
    case .success:
        break
    case .noValue:
        return dictationFocus(role: nil, hasSelectedTextRange: false)
    default:
        dictationLogger.info("Odaktaki öğe okunamadı, yapıştırma deneniyor, kod: \(status.rawValue, privacy: .public)")
        return .unknown
    }
    guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
        return .unknown
    }
    let element: AXUIElement = unsafeDowncast(focused, to: AXUIElement.self)
    var role: CFTypeRef?
    let roleStatus: AXError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    var range: CFTypeRef?
    let hasRange: Bool = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success && range != nil
    guard roleStatus == .success, let roleName = role as? String else {
        return hasRange ? .textInput : .unknown
    }
    return dictationFocus(role: roleName, hasSelectedTextRange: hasRange)
}

/// Sesle yazma hapının durumu.
enum DictationPillState: Equatable {
    case hidden
    /// Dinleniyor; `handsFree` ise bitirme ipucu gösterilir: kısayol, `canEscape` ise Esc de.
    case listening(handsFree: Bool, canEscape: Bool, shortcut: String)
    /// Dinleme bitti, dikte modeli hâlâ hazırlanıyor (ilk kullanımda indirme); ilerleme biliniyorsa 0…1.
    case preparing(progress: Double?)
    case transcribing
    /// Mesaj: bilgi vurgu renginde; dikkat (izin eksik, engel) amber, hata kırmızı (`NoticeSeverity`).
    case message(text: String, severity: NoticeSeverity, action: DictationPillAction?)
}

/// Sesle yazmanın kısa sesleri: dinleme başladı, dinleme bitti.
enum DictationSoundCue: Hashable {
    case start
    case stop

    /// macOS'un yerleşik sesi (/System/Library/Sounds).
    var systemSoundName: NSSound.Name {
        switch self {
        case .start: "Tink"
        case .stop: "Pop"
        }
    }
}

/// Sesle yazma: kısayolla mikrofonu açar, sesi bu Mac'te yazıya döker ve odaktaki uygulamaya yapıştırır. Toplantı
/// oturumu açmaz; abonelikte deneme ya da aylık süreden düşmez. Tuş mantığı `dictationTransition`'da (saf).
@MainActor
@Observable
final class DictationController {
    private let model: AppModel
    private let hotKeys: HotKeyCenter
    /// Kısayolun güncel adı (eller serbest ipucunda), ör. "⌃⌥D".
    private let shortcutName: @MainActor () -> String
    private let onAction: @MainActor (DictationPillAction) -> Void
    /// Hapın durumu ve dinlerken ses seviyesi.
    private(set) var pill: DictationPillState = .hidden
    /// Dinlerken şimdiye dek yazıya dökülen metin (macOS 26+; WhisperKit'te boş kalır). Hap gösterir.
    private(set) var partialText: String = ""
    let levels: AudioLevels = AudioLevels(count: 18, interval: 0.1)
    /// Kısayol şu an basılı mı (tanıtımdaki tuş kapağı yanar). Kısayol denemesinde de güncellenir.
    private(set) var isShortcutHeld: Bool = false
    /// Kısayol denemesi başladığından beri kısayola kaç kez basıldı (tanıtım "denendi" der).
    private(set) var keyTestPresses: Int = 0
    /// Kısayol denemesi sürüyor: kısayol yalnızca sayılır, mikrofon açılmaz (tanıtımın ilk adımı).
    @ObservationIgnored private var isKeyTestActive: Bool = false
    @ObservationIgnored private var sounds: [DictationSoundCue: NSSound] = [:]
    @ObservationIgnored private var keyState: DictationKeyState = .idle
    @ObservationIgnored private var language: MeetingLanguage = .finnish
    @ObservationIgnored private var microphone: MicrophoneCapture?
    /// Mikrofonu açıp dinleme bitene dek parçaları yazıya dökmeye aktarır; örnek sayısını döndürür.
    @ObservationIgnored private var capture: Task<Int, any Error>?
    /// Dilin dikte modelini (ya da WhisperKit'i) hazırlar; dinleme başlarken başlar.
    @ObservationIgnored private var preparation: Task<any LiveDictationEngine, any Error>?
    /// Hazırlık bitince dinlerken yazıya döker (macOS 26+; WhisperKit mikrofon kapanınca); metni döndürür.
    @ObservationIgnored private var transcription: Task<String, any Error>?
    @ObservationIgnored private var isPreparing: Bool = false
    /// Her dinlemede artar: eski dinlemenin geç biten hazırlığı ya da mikrofonu yenisinin durumunu bozmasın.
    @ObservationIgnored private var listeningID: Int = 0
    @ObservationIgnored private var preparationProgress: Double?
    @ObservationIgnored private var timeLimit: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private let appleEngine: AppleDictationEngine = AppleDictationEngine()
    @ObservationIgnored private var window: DictationPillWindow?

    init(model: AppModel, hotKeys: HotKeyCenter, shortcutName: @escaping @MainActor () -> String, onAction: @escaping @MainActor (DictationPillAction) -> Void) {
        self.model = model
        self.hotKeys = hotKeys
        self.shortcutName = shortcutName
        self.onAction = onAction
    }

    /// Kısayola basıldı. Boştayken önce başlatma engelleri denetlenir (oturum, kayıt, parola alanı). Kısayol denemesinde
    /// yalnızca basış sayılır.
    func keyDown(at time: Double) {
        isShortcutHeld = true
        if isKeyTestActive {
            keyTestPresses += 1
            return
        }
        if keyState == .idle,
           let refusal = dictationStartRefusal(
               isSignedIn: !isSignInRequired(), isMeetingActive: model.isRecording || model.isStarting || model.isFinishing,
               isSecureInputActive: IsSecureEventInputEnabled()
           ) {
            refuse(error: refusal)
            return
        }
        apply(event: .keyDown(at: time))
    }

    func keyUp(at time: Double) {
        isShortcutHeld = false
        if isKeyTestActive {
            return
        }
        apply(event: .keyUp(at: time))
    }

    /// Kısayol denemesini başlatır (tanıtımın ilk adımı): süren dikte bırakılır, kısayol bitene dek yalnızca sayılır.
    func startKeyTest() {
        cancel()
        keyTestPresses = 0
        isKeyTestActive = true
    }

    /// Kısayol denemesini bitirir; kısayol yeniden dikte başlatır.
    func endKeyTest() {
        isKeyTestActive = false
        isShortcutHeld = false
    }

    /// Dinleme sürüyorsa sesi atıp kapatır, yazıya dökülüyorsa metni yapıştırmadan atar (toplantı kaydı başlıyor,
    /// kısayol bırakıldı ya da sesle yazma kapatıldı).
    func cancel() {
        apply(event: .cancel)
    }

    /// Hapa tıklandı.
    func pillTapped() {
        guard case .message(_, _, let action?) = pill else {
            return
        }
        setPill(.hidden)
        onAction(action)
    }

    private func apply(event: DictationKeyEvent) {
        let transition: DictationKeyTransition = dictationTransition(state: keyState, event: event, holdThresholdSec: dictationHoldThresholdSec)
        keyState = transition.state
        switch transition.effect {
        case .startListening: startListening()
        case .enterHandsFree: enterHandsFree()
        case .finishListening: finishListening()
        case .cancelListening: cancelListening()
        case .discardText: discardText()
        case nil: break
        }
    }

    private func refuse(error: DictationError) {
        dictationLogger.info("Sesle yazma başlatılmadı, neden: \(String(describing: error), privacy: .public)")
        // Giriş bir uyarı değil: tıklanınca giriş ekranı açılır. Kayıt ve parola alanı engeli amber.
        if error == .signInRequired {
            showMessage(text: userFacingMessage(error: error), severity: .info, action: .signIn)
        } else {
            showMessage(text: userFacingMessage(error: error), severity: .attention, action: nil)
        }
    }

    // MARK: Dinleme

    private func startListening() {
        hideTask?.cancel()
        language = primaryMeetingLanguage()
        listeningID += 1
        let id: Int = listeningID
        isPreparing = true
        preparationProgress = nil
        let language: MeetingLanguage = language
        let preparation: Task<any LiveDictationEngine, any Error> = Task { [weak self] () async throws -> any LiveDictationEngine in
            guard let self else {
                throw CancellationError()
            }
            defer { self.preparationEnded(id: id) }
            return try await self.preparedEngine(language: language)
        }
        self.preparation = preparation
        // Mikrofon parçaları hazırlık bitene dek akışta bekler, sonra motora akar.
        let (chunks, feed): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let transcription: Task<String, any Error> = Task { [weak self] () async throws -> String in
            let engine: any LiveDictationEngine = try await preparation.value
            return try await engine.transcribe(chunks: chunks, language: language) { (text: String) -> Void in
                Task { @MainActor in
                    self?.partialTextChanged(text: text, listeningID: id)
                }
            }
        }
        self.transcription = transcription
        // Hazırlık hatası da buradan gelir (yazıya dökme hazırlığı bekler).
        stopListeningOnFailure(of: transcription, listeningID: id)
        let microphone: MicrophoneCapture = MicrophoneCapture()
        self.microphone = microphone
        model.isDictationMicOpen = true
        levels.start()
        setPill(.listening(handsFree: false, canEscape: false, shortcut: shortcutName()))
        playSound(cue: .start)
        let capture: Task<Int, any Error> = Task { [weak self, levels] () async throws -> Int in
            // Mikrofon açılamasa da akış biter: yazıya dökme sonsuza dek beklemez.
            defer { feed.finish() }
            let stream: AsyncStream<[Float]> = try await microphone.start()
            // Dinleme mikrofon açılmadan bittiyse (çok kısa basış) akış hemen kapatılır.
            if self?.microphone !== microphone {
                microphone.stop()
            }
            var sampleCount: Int = 0
            for await chunk in stream {
                sampleCount += chunk.count
                feed.yield(chunk)
                levels.record(level: audioLevel(samples: chunk))
            }
            return sampleCount
        }
        self.capture = capture
        stopListeningOnFailure(of: capture, listeningID: id)
        timeLimit = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(dictationMaxListeningSec))
            } catch {
                return
            }
            self?.apply(event: .timeLimit)
        }
        dictationLogger.info("Sesle yazma dinliyor, dil: \(language.rawValue, privacy: .public)")
    }

    /// Bu dinlemenin ara metni değişti (eski dinlemeninki ve yapıştırıldıktan sonra geleni yok sayılır).
    private func partialTextChanged(text: String, listeningID id: Int) {
        guard id == listeningID else {
            return
        }
        switch pill {
        case .listening, .transcribing:
            partialText = text
        case .hidden, .preparing, .message:
            return
        }
    }

    /// Bu dinlemenin hazırlığı bitti (eski bir dinlemeninki yeni dinlemenin göstergesini değiştirmez).
    private func preparationEnded(id: Int) {
        if id == listeningID {
            isPreparing = false
        }
    }

    /// Dinlerken iş (dil modeli hazırlığı ya da mikrofon) başarısız olursa dinleme hemen kesilir ve neden gösterilir
    /// (dil desteklenmiyor, model inmedi, mikrofon izni yok): kullanıcı boşuna konuşmaya devam etmez. Dinleme bittikten
    /// sonraki hatayı `finishListening` gösterir.
    private func stopListeningOnFailure<Success: Sendable>(of task: Task<Success, any Error>, listeningID id: Int) {
        Task { [weak self] in
            do {
                _ = try await task.value
            } catch {
                guard let self, self.listeningID == id, dictationIsListening(state: self.keyState) else {
                    return
                }
                dictationLogger.error("Sesle yazma dinlerken durdu, hata: \(String(describing: error), privacy: .private)")
                self.apply(event: .cancel)
                self.showMessage(text: userFacingMessage(error: error), severity: dictationFailureSeverity(error: error), action: dictationFailureAction(error: error))
            }
        }
    }

    private func enterHandsFree() {
        let canEscape: Bool
        do {
            try hotKeys.bindEscape { [weak self] in
                self?.apply(event: .escape)
            }
            canEscape = true
        } catch {
            // Esc başka bir uygulamada özel kayıtlı: kısayola yeniden dokunmak yine bitirir; ipucu Esc'yi anmaz.
            dictationLogger.error("Esc dinlenemiyor, hata: \(String(describing: error), privacy: .public)")
            canEscape = false
        }
        setPill(.listening(handsFree: true, canEscape: canEscape, shortcut: shortcutName()))
    }

    /// Mikrofonu kapatır; kalan ses `transcription`'a akar.
    private func closeMicrophone() {
        timeLimit?.cancel()
        timeLimit = nil
        hotKeys.unbindEscape()
        microphone?.stop()
        microphone = nil
        levels.stop()
        model.isDictationMicOpen = false
        model.dictationMicClosedAt = Date()
    }

    private func cancelListening() {
        closeMicrophone()
        capture?.cancel()
        capture = nil
        transcription?.cancel()
        transcription = nil
        preparation = nil
        setPill(.hidden)
        dictationLogger.info("Sesle yazma iptal edildi")
    }

    /// Yazıya dökülen metin yapıştırılmaz: dinleme kimliği değişir, süren bitirme işi (`finishListening`) metni bırakır.
    private func discardText() {
        listeningID += 1
        setPill(.hidden)
        dictationLogger.info("Sesle yazma metni yapıştırılmadan atıldı")
    }

    private func finishListening() {
        closeMicrophone()
        playSound(cue: .stop)
        guard let capture, let preparation, let transcription else {
            apply(event: .finished)
            return
        }
        self.capture = nil
        self.preparation = nil
        self.transcription = nil
        // Metin atılırsa (`discardText`) kimlik değişir: bu iş yapıştırmaz, hapı ve durumu yeni dinlemeye bırakır.
        let id: Int = listeningID
        setPill(isPreparing ? .preparing(progress: preparationProgress) : .transcribing)
        Task {
            do {
                let sampleCount: Int = try await capture.value
                guard sampleCount >= dictationMinimumSamples else {
                    transcription.cancel()
                    throw DictationError.noSpeech
                }
                _ = try await preparation.value
                guard id == listeningID else {
                    throw CancellationError()
                }
                setPill(.transcribing)
                // macOS 26+'da ses dinlerken yazıya döküldü; burada yalnız son kısım kesinleşir.
                let raw: String = try await transcription.value
                guard let text = dictationInsertText(raw: raw) else {
                    throw DictationError.noSpeech
                }
                try await deliver(text: text, listeningID: id)
                recordFeatureUsage(feature: .dictation)
            } catch {
                // Metin atıldı: hap ve durum yeni dinlemenindir; hata da gösterilmez.
                guard id == listeningID else {
                    dictationLogger.info("Atılan sesle yazmanın bitirmesi durdu, neden: \(String(describing: error), privacy: .public)")
                    return
                }
                if case DictationError.noSpeech = error {
                    showMessage(text: userFacingMessage(error: DictationError.noSpeech), severity: .info, action: nil)
                } else {
                    dictationLogger.error("Sesle yazma başarısız, hata: \(String(describing: error), privacy: .private)")
                    showMessage(text: userFacingMessage(error: error), severity: dictationFailureSeverity(error: error), action: dictationFailureAction(error: error))
                }
            }
            apply(event: .finished)
        }
    }

    /// Dilin motoru: macOS 26+'da Apple'ın cihaz içi diktesi, eskisinde Mac'teki WhisperKit (yüklü değilse indirilir).
    private func preparedEngine(language: MeetingLanguage) async throws -> any LiveDictationEngine {
        guard appleSpeechSupportedBySystem() else {
            return BatchDictation(engine: try await model.requireLocalEngine())
        }
        try await appleEngine.prepare(language: language) { [weak self] (fraction: Double) -> Void in
            Task { @MainActor in
                self?.preparationProgressChanged(fraction: fraction)
            }
        }
        return appleEngine
    }

    private func preparationProgressChanged(fraction: Double) {
        preparationProgress = fraction < 1 ? fraction : nil
        if case .preparing = pill {
            setPill(.preparing(progress: preparationProgress))
        }
    }

    // MARK: Teslim

    /// Metni odaktaki uygulamaya yapıştırır; izin yoksa panoya kopyalar ve söyler. Metin atıldıysa (`discardText`:
    /// dinleme kimliği değişti) panoya da yazılmaz, `CancellationError` fırlatır.
    private func deliver(text: String, listeningID id: Int) async throws {
        guard id == listeningID else {
            throw CancellationError()
        }
        let trusted: Bool = isAccessibilityTrusted()
        switch dictationDelivery(isAccessibilityTrusted: trusted, isSecureInputActive: IsSecureEventInputEnabled(), focus: trusted ? focusedDictationTarget() : .unknown) {
        case .refuse(let error):
            throw error
        case .copyOnly:
            let pasteboard: NSPasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            showMessage(
                text: String(localized: "Panoya kopyalandı; ⌘V ile yapıştır. Doğrudan yazması için Erişilebilirlik izni ver (tıkla)."),
                severity: .attention, action: .openSettings
            )
        case .copyNoTextField:
            // ⌘V boşa gidip pano geri yüklenince metin kaybolurdu: panoda kalır.
            let pasteboard: NSPasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            showMessage(text: String(localized: "Yazı alanı seçili değil; metin panoya kopyalandı. ⌘V ile yapıştır."), severity: .info, action: nil)
        case .paste:
            // Kısayolun değiştiricileri bırakılsın (⌘V'ye karışmasın). Beklerken atılmış olabilir; denetimden ⌘V'ye dek
            // bekleme yok, iptal araya giremez.
            await waitForModifierRelease()
            guard id == listeningID else {
                throw CancellationError()
            }
            try await paste(text: text)
            setPill(.hidden)
        }
    }

    // MARK: Ses efektleri

    /// Ayar açıksa (Ayarlar › Sesle yazma › Ses efektleri) kısa sistem sesini çalar.
    private func playSound(cue: DictationSoundCue) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.voiceTypingSoundEffects) else {
            return
        }
        guard let sound = sounds[cue] ?? NSSound(named: cue.systemSoundName) else {
            dictationLogger.error("Sesle yazma sesi bulunamadı, ad: \(cue.systemSoundName, privacy: .public)")
            return
        }
        sounds[cue] = sound
        sound.volume = 0.35
        sound.stop()
        sound.play()
    }

    // MARK: Hap

    private func setPill(_ state: DictationPillState) {
        pill = state
        switch state {
        case .listening, .transcribing:
            break
        case .hidden, .preparing, .message:
            partialText = ""
        }
        if state == .hidden {
            window?.hide()
            return
        }
        let window: DictationPillWindow = self.window ?? DictationPillWindow(controller: self)
        self.window = window
        window.show(isClickable: { if case .message(_, _, .some) = state { true } else { false } }())
    }

    private func showMessage(text: String, severity: NoticeSeverity, action: DictationPillAction?) {
        setPill(.message(text: text, severity: severity, action: action))
        // Hap odak almaz: VoiceOver kullanıcısı mesajı duyurudan öğrenir.
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            do {
                try await Task.sleep(for: pillMessageDuration)
            } catch {
                return
            }
            guard let self, case .message = self.pill else {
                return
            }
            self.setPill(.hidden)
        }
    }
}

// MARK: Yapıştırma (pano + ⌘V)

/// Panonun tüm öğelerini ve türlerini okur (gizli ya da geçici işaretli öğeyi planlayıcı tanısın diye bütün tür adları
/// da; bkz. `pasteboardRestore`).
@MainActor
private func pasteboardSnapshot(pasteboard: NSPasteboard) -> PasteboardSnapshot {
    let items: [PasteboardItemSnapshot] = (pasteboard.pasteboardItems ?? []).map { (item: NSPasteboardItem) -> PasteboardItemSnapshot in
        PasteboardItemSnapshot(
            types: item.types.map(\.rawValue),
            representations: item.types.compactMap { (type: NSPasteboard.PasteboardType) -> PasteboardRepresentation? in
                item.data(forType: type).map { PasteboardRepresentation(type: type.rawValue, data: $0) }
            }
        )
    }
    return PasteboardSnapshot(items: items)
}

/// Planı panoya uygular.
@MainActor
private func applyPasteboardRestore(plan: PasteboardRestore, pasteboard: NSPasteboard) {
    switch plan {
    case .keep:
        return
    case .clear:
        pasteboard.clearContents()
    case .restore(let items):
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { (snapshot: PasteboardItemSnapshot) -> NSPasteboardItem in
            let item: NSPasteboardItem = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        if !pasteboard.writeObjects(restored) {
            dictationLogger.error("Pano eski haline döndürülemedi, öğe: \(items.count, privacy: .public)")
        }
    }
}

/// Pano yöneticilerinin (Maccy, Raycast…) geçmişe almadığı geçici içerik işareti (nspasteboard.org).
private let transientPasteboardType: NSPasteboard.PasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

/// Metni panoya yazar, ⌘V gönderir, sonra panoyu eski haline döndürür (bu arada başka bir şey kopyalandıysa dokunmaz).
/// ⌘V gönderilemezse metin panoda kalır ve `DictationError.pasteEventFailed`. Kısayolun değiştiricilerini çağıran bekler
/// (`waitForModifierRelease`); pano yazılıp ⌘V gönderilene dek beklenmez.
@MainActor
private func paste(text: String) async throws {
    let pasteboard: NSPasteboard = NSPasteboard.general
    let snapshot: PasteboardSnapshot = pasteboardSnapshot(pasteboard: pasteboard)
    pasteboard.clearContents()
    let item: NSPasteboardItem = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setData(Data(), forType: transientPasteboardType)
    guard pasteboard.writeObjects([item]) else {
        throw DictationError.pasteEventFailed
    }
    let written: Int = pasteboard.changeCount
    try postCommandV()
    try await Task.sleep(for: pasteboardRestoreDelay)
    applyPasteboardRestore(
        plan: pasteboardRestore(snapshot: snapshot, writtenChangeCount: written, currentChangeCount: pasteboard.changeCount), pasteboard: pasteboard
    )
}

/// Kısayolun değiştiricileri (⌃⌥⇧⌘) hâlâ basılıysa en fazla 1 sn bırakılmasını bekler: ⌘V'ye karışıp başka bir
/// kısayol olmasın.
@MainActor
private func waitForModifierRelease() async {
    let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    for _ in 0..<50 where !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
        do {
            try await Task.sleep(for: .milliseconds(20))
        } catch {
            return
        }
    }
}

/// ⌘V klavye olayını gönderir. "V" tuşu klavye düzenine göre bulunur (Türkçe F, Dvorak…); Latin olmayan düzende macOS'un
/// kısayollar için kullandığı ASCII düzeni okunur.
@MainActor
private func postCommandV() throws {
    let keyCode: CGKeyCode = try keyCode(character: "v")
    let source: CGEventSource? = CGEventSource(stateID: .combinedSessionState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        throw DictationError.pasteEventFailed
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

/// Karakteri değiştiricisiz üreten tuş kodu (geçerli ASCII uyumlu klavye düzeninde); yoksa `pasteEventFailed`.
@MainActor
private func keyCode(character: Character) throws -> CGKeyCode {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        dictationLogger.error("Klavye düzeni okunamadı")
        throw DictationError.pasteEventFailed
    }
    let layoutData: Data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    let target: String = String(character)
    let found: CGKeyCode? = layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> CGKeyCode? in
        guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
            return nil
        }
        return (0..<128).map { CGKeyCode($0) }.first { (code: CGKeyCode) -> Bool in
            var deadKeyState: UInt32 = 0
            var length: Int = 0
            var characters: [UniChar] = [UniChar](repeating: 0, count: 4)
            let status: OSStatus = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
            return status == noErr && String(utf16CodeUnits: characters, count: length) == target
        }
    }
    guard let found else {
        dictationLogger.error("Klavye düzeninde tuş bulunamadı, karakter: \(target, privacy: .public)")
        throw DictationError.pasteEventFailed
    }
    return found
}
