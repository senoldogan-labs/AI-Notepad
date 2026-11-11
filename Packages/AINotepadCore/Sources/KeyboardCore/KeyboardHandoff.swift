import Foundation

/// Klavyenin uygulamaya verdiği sesle yazma komutu (App Group'taki `command.json`). Klavye uzantıları mikrofona
/// erişemez: sesi uygulama dinler, metni geri yazar (bkz. docs/superpowers/specs/2026-11-09-voice-keyboard.md).
public struct KeyboardDictationCommand: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Hashable, Codable {
        /// Bu istek için dinlemeye başla.
        case start
        /// Dinlemeyi bitir, kalan sesi yazıya dök.
        case stop
        /// Dinlemeyi at; metin eklenmez.
        case cancel
        /// Klavye metni ekledi: sonuç silinsin.
        case acknowledge
        /// Mikrofon oturumunu kapat.
        case endSession
    }

    public let requestID: UUID
    public let action: Action
    /// İsteyen alanın kimliği (`documentIdentifier`): metin yalnız aynı alana kendiliğinden eklenir.
    public let documentID: UUID?
    /// Dikte dilinin kodu (ör. "tr").
    public let languageCode: String
    public let issuedAt: Date

    public init(requestID: UUID, action: Action, documentID: UUID?, languageCode: String, issuedAt: Date) {
        self.requestID = requestID
        self.action = action
        self.documentID = documentID
        self.languageCode = languageCode
        self.issuedAt = issuedAt
    }
}

/// Uygulamanın yazdığı durum (`status.json`).
public struct KeyboardDictationStatus: Sendable, Hashable, Codable {
    /// Açık mikrofon oturumu; yoksa nil.
    public let session: KeyboardSession?
    /// Son dikte; yoksa nil.
    public let dictation: KeyboardDictation?

    public init(session: KeyboardSession?, dictation: KeyboardDictation?) {
        self.session = session
        self.dictation = dictation
    }
}

/// Mikrofon oturumu: uygulama arka planda mikrofonu açık tutar (sesi yalnız dikte sırasında işler).
public struct KeyboardSession: Sendable, Hashable, Codable {
    public let startedAt: Date
    /// Bu andan sonra (son dikteden itibaren süre) oturum kapanır.
    public let expiresAt: Date
    /// Uygulamanın en son "buradayım" dediği an: eskiyse uygulama kapanmış sayılır.
    public let heartbeatAt: Date

    public init(startedAt: Date, expiresAt: Date, heartbeatAt: Date) {
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.heartbeatAt = heartbeatAt
    }
}

/// Bir dikte ve durumu.
public struct KeyboardDictation: Sendable, Hashable, Codable {
    public enum Phase: String, Sendable, Hashable, Codable {
        case preparing
        case listening
        case finishing
        case finished
        case failed
    }

    public let requestID: UUID
    public let documentID: UUID?
    public let phase: Phase
    /// Dinlerken şimdiye dek yazıya dökülen metin.
    public let partialText: String
    /// Bitince eklenecek metin.
    public let finalText: String?
    /// Hatanın türü (`failed`).
    public let failure: KeyboardDictationFailure?

    public init(requestID: UUID, documentID: UUID?, phase: Phase, partialText: String, finalText: String?, failure: KeyboardDictationFailure?) {
        self.requestID = requestID
        self.documentID = documentID
        self.phase = phase
        self.partialText = partialText
        self.finalText = finalText
        self.failure = failure
    }
}

/// Dikte hatası; klavye kendi metnini gösterir.
public enum KeyboardDictationFailure: String, Sendable, Hashable, Codable {
    case noSpeech
    case microphoneDenied
    case unsupportedLanguage
    case recordingMeeting
    case failed
}

/// Uygulamanın nabzı bu kadar eskiyse oturum yok sayılır (uygulama kapandı ya da askıya alındı).
public let keyboardHeartbeatTimeout: TimeInterval = 4
/// Klavyenin uygulamayı açarken bıraktığı başlatma komutu bu süre içinde geçerlidir: daha eski komutla gelen bağlantı
/// mikrofonu açmaz (başka bir uygulama ya da sayfa `gistsmith://keyboard/dictate` açarsa).
public let keyboardCommandLifetime: TimeInterval = 15
/// Mikrofon oturumunun seçilebilen süreleri (dakika; son dikteden itibaren) ve varsayılanı.
public let keyboardSessionMinuteChoices: [Int] = [1, 5, 15]
public let keyboardDefaultSessionMinutes: Int = 5

/// Oturum canlı mı: nabız taze ve süre dolmamış. Saf fonksiyondur.
public func keyboardSessionIsLive(session: KeyboardSession?, now: Date) -> Bool {
    guard let session else {
        return false
    }
    return now.timeIntervalSince(session.heartbeatAt) <= keyboardHeartbeatTimeout && now < session.expiresAt
}

/// Bağlantıyla gelen istek mikrofonu açabilir mi: App Group'taki komut aynı istek, "start" ve taze olmalı. Saf
/// fonksiyondur.
public func keyboardStartCommandIsValid(command: KeyboardDictationCommand?, requestID: UUID, now: Date) -> Bool {
    guard let command, command.requestID == requestID, command.action == .start else {
        return false
    }
    let age: TimeInterval = now.timeIntervalSince(command.issuedAt)
    return age >= -1 && age <= keyboardCommandLifetime
}

/// Whether a start command that reached the app over the Darwin notification starts a dictation in place: only while the
/// microphone session is open, only for a fresh start, and never twice for one request. The tap that opened the app
/// through the link only warms the microphone (`warmedRequestID`); its notification can arrive after the link and must
/// not start a dictation the user did not ask for yet. A second start for the dictation already running would cancel it
/// and let the first transcription's late, empty result fail the new one with "No speech heard". Pure function.
public func keyboardCommandStartsDictation(
    command: KeyboardDictationCommand, isSessionActive: Bool, currentRequestID: UUID?, warmedRequestID: UUID?, now: Date
) -> Bool {
    guard command.action == .start, isSessionActive, command.requestID != currentRequestID, command.requestID != warmedRequestID else {
        return false
    }
    let age: TimeInterval = now.timeIntervalSince(command.issuedAt)
    return age >= -1 && age <= keyboardCommandLifetime
}

/// Klavyedeki mikrofon şeridinin durumu.
public enum KeyboardMicState: Sendable, Hashable {
    /// Tam Erişim kapalı: App Group ve uygulamayla iletişim yok; dokununca nedeni gösterilir.
    case needsFullAccess
    /// Hazır. Oturum açıksa kalan süre (saniye); kapalıysa nil (dokununca uygulama açılır).
    case idle(sessionRemaining: TimeInterval?)
    /// Uygulama açılıyor ya da hazırlanıyor (bu istek için).
    case starting
    /// Dinliyor; şimdiye dek metin.
    case listening(text: String)
    /// Son kısım yazıya dökülüyor.
    case finishing(text: String)
    /// Metin hazır. `autoInsert` true ise aynı alana kendiliğinden eklenir; değilse "Ekle" düğmesiyle.
    case finished(text: String, autoInsert: Bool)
    case failed(KeyboardDictationFailure)
}

/// Mikrofon şeridinin durumu: tam erişim, oturum, dikte ve klavyenin son komutundan (`command.json`; klavye yeniden
/// açılınca da okunur). Dikte yalnız son komut onu başlatan komutsa gösterilir: kullanıcı ekleyince ya da vazgeçince
/// (`acknowledge`, `cancel`) şerit kapanır. Bitmiş metin yalnız istediği alana (`documentID`) kendiliğinden eklenir;
/// başka alanda (klavye yeniden açıldı, alan değişti) "Ekle" ile sunulur. Saf fonksiyondur.
public func keyboardMicState(
    hasFullAccess: Bool, status: KeyboardDictationStatus?, lastCommand: KeyboardDictationCommand?, documentID: UUID?, now: Date
) -> KeyboardMicState {
    guard hasFullAccess else {
        return .needsFullAccess
    }
    let isLive: Bool = keyboardSessionIsLive(session: status?.session, now: now)
    let isOpenRequest: (UUID) -> Bool = { (requestID: UUID) -> Bool in
        guard let lastCommand, lastCommand.requestID == requestID else {
            return false
        }
        return lastCommand.action == .start || lastCommand.action == .stop
    }
    if let dictation = status?.dictation, isOpenRequest(dictation.requestID) {
        switch dictation.phase {
        case .finished:
            // Metin yalnız oturum canlıyken sunulur: mikrofon kapandıysa (uygulama kapandı, süre doldu) metin de gitmiştir.
            if isLive, let text = dictation.finalText, !text.isEmpty {
                return .finished(text: text, autoInsert: dictation.documentID != nil && dictation.documentID == documentID)
            }
        case .failed:
            return .failed(dictation.failure ?? .failed)
        case .preparing:
            if isLive {
                return .starting
            }
        case .listening:
            if isLive {
                return .listening(text: dictation.partialText)
            }
        case .finishing:
            if isLive {
                return .finishing(text: dictation.partialText)
            }
        }
    }
    // A start issued before the live session opened is the tap that opened Gistsmith to warm the microphone: the app
    // does not dictate it (the user speaks after coming back), so the keyboard is ready, not starting.
    let warmedBySession: Bool
    if isLive, let session = status?.session, let lastCommand {
        warmedBySession = lastCommand.issuedAt <= session.startedAt
    } else {
        warmedBySession = false
    }
    if let lastCommand, lastCommand.action == .start, now.timeIntervalSince(lastCommand.issuedAt) <= keyboardCommandLifetime,
       status?.dictation?.requestID != lastCommand.requestID, !warmedBySession {
        return .starting
    }
    if isLive, let session = status?.session {
        return .idle(sessionRemaining: max(0, session.expiresAt.timeIntervalSince(now)))
    }
    return .idle(sessionRemaining: nil)
}

/// Durumda oturumu kapanmış bir dikte kaldı mı (uygulama kapanınca `endSession` çalışmaz): bitmiş metin ya da dinlerken
/// yazılan ara metin. Klavye ve uygulama onu siler. Başarısız dikte metin taşımaz, nedeni klavye görene dek kalır. Saf
/// fonksiyondur.
public func keyboardStatusHasOrphanedText(status: KeyboardDictationStatus?, now: Date) -> Bool {
    guard let dictation = status?.dictation, dictation.phase != .failed else {
        return false
    }
    return !keyboardSessionIsLive(session: status?.session, now: now)
}

/// Eklenen ya da bırakılan diktenin sonucunu durumdan çıkarır (oturum kalır): metin paylaşılan klasörde kalmaz, uygulama
/// o an çalışmıyor olsa da. Durum başka bir dikteyi gösteriyorsa nil (dokunulmaz). Saf fonksiyondur.
public func keyboardStatusClearingDictation(status: KeyboardDictationStatus?, requestID: UUID) -> KeyboardDictationStatus? {
    guard let status, status.dictation?.requestID == requestID else {
        return nil
    }
    return KeyboardDictationStatus(session: status.session, dictation: nil)
}

/// Dikte metnini alandaki metne ekler: solda boşluk yoksa (ve satır başı değilse) bir boşluk koyar. Saf fonksiyondur.
public func keyboardDictationInsertion(text: String, contextBefore: String) -> String {
    keyboardDictationLeadingSpace(contextBefore: contextBefore) + text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The space a dictation needs before it: one when the text left of the cursor ends in a non-space character, none at
/// the start of the field or after a space or line break. Live typing decides it once, before its marked text becomes
/// part of the context. Pure function.
public func keyboardDictationLeadingSpace(contextBefore: String) -> String {
    guard let last = contextBefore.last, !last.isWhitespace else {
        return ""
    }
    return " "
}

/// Whether the dictation covers the keys with its own panel (cancel, finish, the waveform and the reason when it
/// failed): from the start until the text is in the field. Ready, idle and a text being inserted on its own show the
/// keys. Pure function.
public func keyboardMicStateCoversKeys(_ state: KeyboardMicState) -> Bool {
    switch state {
    case .starting, .listening, .finishing, .failed, .finished(text: _, autoInsert: false):
        true
    case .needsFullAccess, .idle, .finished(text: _, autoInsert: true):
        false
    }
}

/// Klavyenin uygulamayı açtığı bağlantılar (yalnız iPhone): `gistsmith://keyboard/dictate/<istek>` sesle yazmayı,
/// `gistsmith://keyboard/setup` kurulum sayfasını açar.
public enum KeyboardLinkRoute: Sendable, Hashable {
    case dictate(requestID: UUID)
    /// Klavyeden Gistsmith'e soru (`gistsmith://keyboard/ask/<istek>`).
    case ask(requestID: UUID)
    case setup
}

/// Klavye bağlantısının yeri; klavye bağlantısı değilse nil. Saf fonksiyondur.
public func keyboardLinkRoute(url: URL) -> KeyboardLinkRoute? {
    guard url.scheme?.lowercased() == "gistsmith", url.host?.lowercased() == "keyboard" else {
        return nil
    }
    let segments: [String] = url.pathComponents.filter { $0 != "/" }
    switch segments.first?.lowercased() {
    case "setup" where segments.count == 1:
        return .setup
    case "dictate" where segments.count == 2:
        return UUID(uuidString: segments[1]).map { KeyboardLinkRoute.dictate(requestID: $0) }
    case "ask" where segments.count == 2:
        return UUID(uuidString: segments[1]).map { KeyboardLinkRoute.ask(requestID: $0) }
    default:
        return nil
    }
}

/// Sesle yazma bağlantısı (klavye uygulamayı bununla açar). Saf fonksiyondur.
public func keyboardDictateURL(requestID: UUID) -> URL {
    // Şema, ana bilgisayar ve UUID metni her zaman geçerli bir adres oluşturur.
    URL(string: "gistsmith://keyboard/dictate/\(requestID.uuidString)")!
}

/// Kurulum bağlantısı.
public let keyboardSetupURL: URL = URL(string: "gistsmith://keyboard/setup")!
