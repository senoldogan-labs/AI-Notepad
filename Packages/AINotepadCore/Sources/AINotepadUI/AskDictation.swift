import AINotepadCore
import Foundation
import Observation
import os

private let askDictationLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AskDictation")

/// Bundan kısa ses yazıya dökülmez ("Konuşma duyulmadı"): 16 kHz'de 0,25 sn (sesle yazmadaki gibi).
private let askDictationMinimumSamples: Int = 4000

/// Sor alanına sesle sorunun durumu.
public enum AskDictationPhase: Equatable, Sendable {
    case idle
    /// Mikrofon açık; ara metin `AskDictation.partialText`'te.
    case listening
    /// Mikrofon kapandı, dikte modeli hâlâ hazırlanıyor (ilk kullanımda indirme); ilerleme biliniyorsa 0…1.
    case preparing(progress: Double?)
    /// Mikrofon kapandı, son kısım yazıya dökülüyor.
    case transcribing
    /// Alanın altında kalan kısa not (izin yok, dil desteklenmiyor, kayıt sürüyor, konuşma duyulmadı).
    case notice(AskDictationNotice)
}

/// Sesle sorunun alan altındaki notu.
public struct AskDictationNotice: Equatable, Sendable {
    public let text: String
    public let severity: NoticeSeverity
    /// Mikrofon izni yok: yanında izin ayarını açan düğme görünür.
    public let opensMicrophoneSettings: Bool

    public init(text: String, severity: NoticeSeverity, opensMicrophoneSettings: Bool) {
        self.text = text
        self.severity = severity
        self.opensMicrophoneSettings = opensMicrophoneSettings
    }
}

/// Dikte hatasının notu: ayar ya da izin meselesi (desteklenmeyen dil, mikrofon izni) dikkat, konuşma duyulmadı bilgi,
/// gerisi hata. Saf fonksiyondur.
public func askDictationNotice(error: any Error) -> AskDictationNotice {
    switch error {
    case DictationError.noSpeech:
        AskDictationNotice(text: userFacingMessage(error: error), severity: .info, opensMicrophoneSettings: false)
    case AudioCaptureError.microphonePermissionDenied:
        AskDictationNotice(text: userFacingMessage(error: error), severity: .attention, opensMicrophoneSettings: true)
    case is DictationError:
        AskDictationNotice(text: userFacingMessage(error: error), severity: .attention, opensMicrophoneSettings: false)
    default:
        AskDictationNotice(text: userFacingMessage(error: error), severity: .error, opensMicrophoneSettings: false)
    }
}

/// Kayıt sürerken mikrofon düğmesine basılınca görünen not: mikrofon toplantıdadır, soru yazılabilir.
@MainActor
public func askDictationMeetingNotice() -> AskDictationNotice {
    AskDictationNotice(
        text: String(localized: "Toplantı kaydı sürüyor; mikrofon toplantıda. Soruyu yazabilir ya da kayıt bitince sesle sorabilirsin."),
        severity: .attention, opensMicrophoneSettings: false
    )
}

/// Sor alanına sesle soru (Mac'te Sor sayfası, iPhone'da Sor): mikrofona dokununca dinler, ara metni gösterir; yeniden
/// dokununca kalan sesi bu cihazda yazıya döker ve metni alana ekler (gönderilmez, kullanıcı gözden geçirir). Sesle
/// yazmanın motorunu ve mikrofonunu kullanır (`LiveDictationEngine`, `MicrophoneCapture`); ses hiçbir yere gönderilmez,
/// abonelikte süreden düşmez.
///
/// Uygulamada tektir: kayıt başlamadan önce uygulama `cancel()` çağırır (iPhone'da ses oturumu kaydınkiyle paylaşılır;
/// dikte mikrofonu kayıt oturumunu açtıktan sonra kapansaydı kaydı keserdi). Kayıt sürerken soru alanı başlatmaz, nedenini
/// gösterir (`askDictationMeetingNotice`). Birden çok soru alanı (iPhone'da kök ve sohbet) aynı denetleyiciyi kullanır:
/// durumu yalnız başlatan alan (`owner`) gösterir, metin onun `onText`'ine gider.
@MainActor
@Observable
public final class AskDictation {
    public private(set) var phase: AskDictationPhase = .idle
    /// Dinlerken şimdiye dek yazıya dökülen metin (akışlı motorda; toplu motorda boş kalır).
    public private(set) var partialText: String = ""
    /// Durumu gösteren soru alanı; boştayken nil.
    public private(set) var owner: UUID?
    public let levels: AudioLevels = AudioLevels(count: 14, interval: 0.1)
    /// Dilin motorunu hazırlar (gerekirse indirir; ilerleme 0…1 ikinci parametreye).
    @ObservationIgnored private let prepareEngine: @MainActor (MeetingLanguage, @escaping @Sendable (Double) -> Void) async throws -> any LiveDictationEngine
    /// Dikte dili: ana toplantı dili (sesle yazmadaki gibi).
    @ObservationIgnored private let language: @MainActor () -> MeetingLanguage
    /// Mikrofon açıldı (true) ya da kapandı (false): Mac'te görüşme algılama kendi diktemizi görüşme sanmasın.
    @ObservationIgnored private let onMicrophoneChange: @MainActor (Bool) -> Void
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var capture: Task<Int, any Error>?
    @ObservationIgnored private var preparation: Task<any LiveDictationEngine, any Error>?
    @ObservationIgnored private var transcription: Task<String, any Error>?
    @ObservationIgnored private var isPreparing: Bool = false
    @ObservationIgnored private var preparationProgress: Double?
    @ObservationIgnored private var timeLimit: Task<Void, Never>?
    @ObservationIgnored private var onText: (@MainActor (String) -> Void)?
    /// Her dinlemede ve iptalde artar: eski dinlemenin geç biten işi yenisinin durumunu bozmasın.
    @ObservationIgnored private var generation: Int = 0

    public init(
        prepareEngine: @escaping @MainActor (MeetingLanguage, @escaping @Sendable (Double) -> Void) async throws -> any LiveDictationEngine,
        language: @escaping @MainActor () -> MeetingLanguage,
        onMicrophoneChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.prepareEngine = prepareEngine
        self.language = language
        self.onMicrophoneChange = onMicrophoneChange
    }

    /// Bu alan için dinleniyor mu.
    public func isListening(owner id: UUID) -> Bool {
        owner == id && phase == .listening
    }

    /// Bu alanın durumu (başka alanınki ya da boştaysa `.idle`).
    public func phase(owner id: UUID) -> AskDictationPhase {
        owner == id ? phase : .idle
    }

    /// Dinlemeyi başlatır; süren başka bir dinleme (başka alanda) atılır. Bitince metin `onText`'e gider.
    public func start(owner id: UUID, onText: @escaping @MainActor (String) -> Void) {
        cancel()
        generation += 1
        let current: Int = generation
        owner = id
        self.onText = onText
        partialText = ""
        let language: MeetingLanguage = language()
        isPreparing = true
        preparationProgress = nil
        let prepareEngine: @MainActor (MeetingLanguage, @escaping @Sendable (Double) -> Void) async throws -> any LiveDictationEngine = self.prepareEngine
        let preparation: Task<any LiveDictationEngine, any Error> = Task { [weak self] () async throws -> any LiveDictationEngine in
            defer { self?.preparationEnded(generation: current) }
            return try await prepareEngine(language) { [weak self] (fraction: Double) -> Void in
                Task { @MainActor [weak self] in
                    self?.preparationProgressChanged(fraction: fraction, generation: current)
                }
            }
        }
        self.preparation = preparation
        // Mikrofon parçaları hazırlık bitene dek akışta bekler, sonra motora akar.
        let (chunks, feed): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let transcription: Task<String, any Error> = Task { [weak self] () async throws -> String in
            let engine: any LiveDictationEngine = try await preparation.value
            return try await engine.transcribe(chunks: chunks, language: language) { [weak self] (text: String) -> Void in
                Task { @MainActor [weak self] in
                    self?.partialTextChanged(text: text, generation: current)
                }
            }
        }
        self.transcription = transcription
        stopOnFailure(of: transcription, generation: current)
        let microphone: MicrophoneCapture = MicrophoneCapture()
        self.microphone = microphone
        onMicrophoneChange(true)
        levels.start()
        phase = .listening
        let capture: Task<Int, any Error> = Task { [weak self, levels] () async throws -> Int in
            // Mikrofon açılamasa da akış biter: yazıya dökme sonsuza dek beklemez.
            defer { feed.finish() }
            let stream: AsyncStream<[Float]>
            do {
                stream = try await microphone.start()
            } catch {
                // Neden (izin yok) akış bitmeden gösterilir: bitince yazıya dökme de boş sesle hata verir, o hata bunu
                // örtmemeli.
                self?.stopListening(error: error, generation: current)
                throw error
            }
            // Dinleme mikrofon açılırken bittiyse (izin penceresi) akış hemen kapatılır.
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
        stopOnFailure(of: capture, generation: current)
        timeLimit = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(dictationMaxListeningSec))
            } catch {
                return
            }
            self?.finish()
        }
        askDictationLogger.info("Sor alanı sesle dinliyor, dil: \(language.rawValue, privacy: .public)")
    }

    /// Dinlemeyi bitirir: mikrofon kapanır, kalan ses yazıya dökülür ve metin alana eklenir.
    public func finish() {
        guard phase == .listening, let capture, let preparation, let transcription else {
            return
        }
        closeMicrophone()
        self.capture = nil
        self.preparation = nil
        self.transcription = nil
        let current: Int = generation
        phase = isPreparing ? .preparing(progress: preparationProgress) : .transcribing
        Task { [weak self] in
            do {
                let sampleCount: Int = try await capture.value
                guard sampleCount >= askDictationMinimumSamples else {
                    transcription.cancel()
                    throw DictationError.noSpeech
                }
                _ = try await preparation.value
                guard let self, self.generation == current else {
                    throw CancellationError()
                }
                self.phase = .transcribing
                let raw: String = try await transcription.value
                guard let text = dictationInsertText(raw: raw) else {
                    throw DictationError.noSpeech
                }
                guard self.generation == current else {
                    throw CancellationError()
                }
                self.onText?(text)
                self.reset()
            } catch {
                guard let self, self.generation == current else {
                    askDictationLogger.info("Atılan sesle sorunun bitirmesi durdu, neden: \(String(describing: error), privacy: .public)")
                    return
                }
                askDictationLogger.error("Sesle soru yazıya dökülemedi, hata: \(String(describing: error), privacy: .private)")
                self.showNotice(askDictationNotice(error: error))
            }
        }
    }

    /// Dinlemeyi ya da yazıya dökmeyi bırakır; metin alana eklenmez, not da kalkar (soru gönderildi, alan kapandı,
    /// sayfadan çıkıldı ya da kayıt başlıyor).
    public func cancel() {
        generation += 1
        if microphone != nil {
            closeMicrophone()
        }
        capture?.cancel()
        transcription?.cancel()
        capture = nil
        preparation = nil
        transcription = nil
        if phase != .idle {
            askDictationLogger.info("Sesle soru bırakıldı")
        }
        reset()
    }

    /// Bu alanın notunu gösterir (ör. kayıt sürüyor); süren dinleme atılır.
    public func show(notice: AskDictationNotice, owner id: UUID) {
        cancel()
        owner = id
        phase = .notice(notice)
    }

    /// Örnek dinleme (önizleme ve ekran görüntüsü kipi): mikrofon açılmaz, ara metin ve ses çubukları olduğu gibi kalır.
    public func showSampleListening(owner id: UUID, partialText sample: String, levels sampleLevels: [Float]) {
        cancel()
        owner = id
        partialText = sample
        levels.showSample(values: sampleLevels)
        phase = .listening
    }

    /// Notu kapatır.
    public func dismissNotice() {
        if case .notice = phase {
            reset()
        }
    }

    private func reset() {
        phase = .idle
        partialText = ""
        owner = nil
        onText = nil
    }

    private func showNotice(_ notice: AskDictationNotice) {
        partialText = ""
        onText = nil
        phase = .notice(notice)
    }

    private func closeMicrophone() {
        timeLimit?.cancel()
        timeLimit = nil
        microphone?.stop()
        microphone = nil
        levels.stop()
        onMicrophoneChange(false)
    }

    private func partialTextChanged(text: String, generation current: Int) {
        guard current == generation else {
            return
        }
        switch phase {
        case .listening, .transcribing:
            partialText = text
        case .idle, .preparing, .notice:
            return
        }
    }

    private func preparationEnded(generation current: Int) {
        if current == generation {
            isPreparing = false
        }
    }

    private func preparationProgressChanged(fraction: Double, generation current: Int) {
        guard current == generation else {
            return
        }
        preparationProgress = fraction < 1 ? fraction : nil
        if case .preparing = phase {
            phase = .preparing(progress: preparationProgress)
        }
    }

    /// Dinlerken iş (dil modeli hazırlığı ya da mikrofon) başarısız olursa dinleme hemen kesilir ve neden görünür:
    /// kullanıcı boşuna konuşmaya devam etmez. Dinleme bittikten sonraki hatayı `finish` gösterir.
    private func stopOnFailure<Success: Sendable>(of task: Task<Success, any Error>, generation current: Int) {
        Task { [weak self] in
            do {
                _ = try await task.value
            } catch {
                self?.stopListening(error: error, generation: current)
            }
        }
    }

    /// Bu dinleme hâlâ sürüyorsa keser ve hatanın notunu gösterir; dinleme bittiyse ya da yenisi başladıysa bir şey
    /// yapmaz (ilk gelen hata kalır).
    private func stopListening(error: any Error, generation current: Int) {
        guard generation == current, phase == .listening else {
            return
        }
        askDictationLogger.error("Sesle soru dinlerken durdu, hata: \(String(describing: error), privacy: .private)")
        let id: UUID? = owner
        cancel()
        owner = id
        phase = .notice(askDictationNotice(error: error))
    }
}
