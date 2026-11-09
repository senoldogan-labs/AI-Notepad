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
    /// Toplantı kaydı sürüyor: mikrofon kayıtta, sesle yazma başlamaz.
    public let isRecordingMeeting: Bool

    public init(session: KeyboardSession?, dictation: KeyboardDictation?, isRecordingMeeting: Bool) {
        self.session = session
        self.dictation = dictation
        self.isRecordingMeeting = isRecordingMeeting
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

/// Sesle yazma neden kullanılamıyor.
public enum KeyboardVoiceUnavailable: Sendable, Hashable {
    /// Tam Erişim kapalı (App Group ve uygulamayla iletişim yok).
    case needsFullAccess
    /// Toplantı kaydı sürüyor.
    case recordingMeeting
}

/// Klavyedeki mikrofon şeridinin durumu.
public enum KeyboardMicState: Sendable, Hashable {
    /// Kullanılamıyor; dokununca nedeni gösterilir.
    case unavailable(KeyboardVoiceUnavailable)
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

/// Klavyenin bildiği bekleyen istek (son verdiği başlatma).
public struct KeyboardPendingRequest: Sendable, Hashable {
    public let requestID: UUID
    public let issuedAt: Date

    public init(requestID: UUID, issuedAt: Date) {
        self.requestID = requestID
        self.issuedAt = issuedAt
    }
}

/// Mikrofon şeridinin durumu: tam erişim, kayıt, oturum, dikte ve bu klavyenin bekleyen isteğinden. Bitmiş dikte
/// yalnız istediği alana (`documentID`) kendiliğinden eklenir; başka alanda (klavye yeniden açıldı, alan değişti)
/// kullanıcıya "Ekle" ile sunulur. Saf fonksiyondur.
public func keyboardMicState(
    hasFullAccess: Bool, status: KeyboardDictationStatus?, pending: KeyboardPendingRequest?, documentID: UUID?, now: Date
) -> KeyboardMicState {
    guard hasFullAccess else {
        return .unavailable(.needsFullAccess)
    }
    let isLive: Bool = keyboardSessionIsLive(session: status?.session, now: now)
    if let dictation = status?.dictation {
        switch dictation.phase {
        case .finished:
            if let text = dictation.finalText, !text.isEmpty {
                return .finished(text: text, autoInsert: dictation.documentID != nil && dictation.documentID == documentID)
            }
        case .failed:
            if pending?.requestID == dictation.requestID {
                return .failed(dictation.failure ?? .failed)
            }
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
    if status?.isRecordingMeeting == true {
        return .unavailable(.recordingMeeting)
    }
    if let pending, now.timeIntervalSince(pending.issuedAt) <= keyboardCommandLifetime, status?.dictation?.requestID != pending.requestID {
        return .starting
    }
    if isLive, let session = status?.session {
        return .idle(sessionRemaining: max(0, session.expiresAt.timeIntervalSince(now)))
    }
    return .idle(sessionRemaining: nil)
}

/// Dikte metnini alandaki metne ekler: solda boşluk yoksa (ve satır başı değilse) bir boşluk koyar. Saf fonksiyondur.
public func keyboardDictationInsertion(text: String, contextBefore: String) -> String {
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = contextBefore.last, !last.isWhitespace else {
        return trimmed
    }
    return " " + trimmed
}
