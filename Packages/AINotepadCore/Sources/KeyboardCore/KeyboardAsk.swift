import Foundation

/// Klavyeden Gistsmith'e soru (`ask.json`; yalnız klavye yazar). Klavye hesabın oturumunu bilmez ve ağa çıkmaz: soruyu
/// uygulama kendi oturumuyla Sor'a sorar, cevabı `ask-answer.json`'a yazar.
public struct KeyboardAskCommand: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Hashable, Codable {
        /// Soruyu sor.
        case ask
        /// Cevap eklendi ya da bırakıldı: cevap dosyası silinsin.
        case release
    }

    public let requestID: UUID
    public let action: Action
    /// Kullanıcının klavyedeki soru alanına yazdığı soru (yalnız bu gider; alandaki diğer metin gitmez).
    public let question: String
    /// Soran alanın kimliği (bilgi için). Cevap hiçbir alana kendiliğinden eklenmez: kullanıcı "Ekle"ye dokunduğu alana
    /// eklenir.
    public let documentID: UUID?
    public let issuedAt: Date

    public init(requestID: UUID, action: Action, question: String, documentID: UUID?, issuedAt: Date) {
        self.requestID = requestID
        self.action = action
        self.question = question
        self.documentID = documentID
        self.issuedAt = issuedAt
    }
}

/// Uygulamanın yazdığı cevap durumu (`ask-answer.json`).
public struct KeyboardAskAnswer: Sendable, Hashable, Codable {
    public enum Phase: String, Sendable, Hashable, Codable {
        case answering
        case answered
        case failed
    }

    public let requestID: UUID
    public let phase: Phase
    /// Cevabın düz metni (yalnız `answered`).
    public let answer: String?
    /// Kullanıcıya gösterilecek neden (yalnız `failed`; uygulamanın dilinde).
    public let failureReason: String?
    /// Durumun yazıldığı an: eski cevaplar gösterilmez, silinir.
    public let updatedAt: Date

    public init(requestID: UUID, phase: Phase, answer: String?, failureReason: String?, updatedAt: Date) {
        self.requestID = requestID
        self.phase = phase
        self.answer = answer
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }
}

/// Sorunun en uzun hâli (karakter): klavyedeki soru alanı bunu aşmaz.
public let keyboardAskQuestionLimit: Int = 500
/// Cevap bu kadar süre sonra gösterilmez ve silinir (dakika).
public let keyboardAskAnswerLifetime: TimeInterval = 10 * 60
/// Uygulama bu kadar süre "cevaplanıyor" diye kalırsa (kapandı, askıya alındı) soru başarısız sayılır.
public let keyboardAskAnsweringTimeout: TimeInterval = 2 * 60
/// How long a question waits for Gistsmith to pick it up (the link, the signal of a running session, or opening
/// Gistsmith by hand). Gistsmith writes `answering` at once when it does; after this the keyboard says the question
/// never reached it, and Gistsmith no longer asks it.
public let keyboardAskDeliveryWindow: TimeInterval = 60

/// Klavyedeki "Gistsmith'e sor" şeridinin durumu.
public enum KeyboardAskState: Sendable, Hashable {
    /// Soru yok.
    case idle
    /// The question is written but Gistsmith has not picked it up yet (it is opening, or must be opened by hand). Does
    /// not lock asking: a new question replaces it.
    case awaitingApp
    /// Gistsmith is answering.
    case answering
    /// Cevap hazır: kullanıcı "Ekle"ye dokununca eklenir.
    case answered(String)
    /// Cevaplanamadı; neden uygulamanın yazdığı metin, yoksa nil (klavye kendi metnini gösterir).
    case failed(String?)
    /// Gistsmith never picked the question up within `keyboardAskDeliveryWindow`: open Gistsmith and ask again.
    case notDelivered

    /// Whether a new question must wait: only while Gistsmith is answering (Ask answers one question at a time).
    public var locksAsking: Bool {
        self == .answering
    }
}

/// Şeridin durumu: klavyenin son sorusu ve uygulamanın cevabından. Yalnız son soruya ait, `release` edilmemiş ve
/// süresi geçmemiş cevap gösterilir. A question older than `keyboardAskAnswerLifetime` shows nothing, whichever side
/// deleted its answer file first (an expired answer disappears; it is not a failure). A question Gistsmith has not
/// picked up waits `keyboardAskDeliveryWindow`, then is shown as not delivered; one it stopped answering (closed,
/// suspended) fails after `keyboardAskAnsweringTimeout`. Saf fonksiyondur.
public func keyboardAskState(command: KeyboardAskCommand?, answer: KeyboardAskAnswer?, now: Date) -> KeyboardAskState {
    guard let command, command.action == .ask else {
        return .idle
    }
    let age: TimeInterval = now.timeIntervalSince(command.issuedAt)
    guard age <= keyboardAskAnswerLifetime else {
        return .idle
    }
    guard let answer, answer.requestID == command.requestID else {
        // Gistsmith writes `answering` as soon as it picks the question up: nothing yet means it has not.
        return age <= keyboardAskDeliveryWindow ? .awaitingApp : .notDelivered
    }
    switch answer.phase {
    case .answering:
        return now.timeIntervalSince(answer.updatedAt) <= keyboardAskAnsweringTimeout ? .answering : .failed(nil)
    case .answered:
        guard let text = answer.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .failed(nil)
        }
        return .answered(text)
    case .failed:
        return .failed(answer.failureReason)
    }
}

/// Whether Gistsmith, coming to the front without the question's link (opened by hand because the link could not open
/// it), asks the keyboard's waiting question: an "ask" with a question, issued within `keyboardAskDeliveryWindow`, that
/// Gistsmith has not picked up yet (no answer file of its own, and not the last question this run asked, even if writing
/// its answer file failed). Pure function.
public func keyboardAskHostShouldAdopt(command: KeyboardAskCommand?, answer: KeyboardAskAnswer?, askedRequest: UUID?, now: Date) -> Bool {
    guard let command, command.action == .ask, askedRequest != command.requestID, answer?.requestID != command.requestID else {
        return false
    }
    let question: String = command.question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, question.count <= keyboardAskQuestionLimit else {
        return false
    }
    let age: TimeInterval = now.timeIntervalSince(command.issuedAt)
    return age >= -1 && age <= keyboardAskDeliveryWindow
}

/// Whether a microphone start failure still concerns the keyboard's session: only the session that started it, and not
/// a cancellation (its session was ended while the permission prompt was up). A failure of an earlier session must not
/// fail a newer one. Pure function.
public func keyboardMicrophoneFailureApplies(failedSession: UUID, currentSession: UUID?, error: any Error) -> Bool {
    failedSession == currentSession && !(error is CancellationError)
}

/// Bağlantıyla gelen soru uygulamada sorulabilir mi: `ask.json`'daki komut aynı istek, "ask", taze ve boş olmayan bir
/// soru olmalı. Saf fonksiyondur.
public func keyboardAskCommandIsValid(command: KeyboardAskCommand?, requestID: UUID, now: Date) -> Bool {
    guard let command, command.requestID == requestID, command.action == .ask else {
        return false
    }
    let question: String = command.question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, question.count <= keyboardAskQuestionLimit else {
        return false
    }
    let age: TimeInterval = now.timeIntervalSince(command.issuedAt)
    return age >= -1 && age <= keyboardCommandLifetime
}

/// Cevap dosyası silinmeli mi: süresi geçmiş ya da artık son soruya ait değil. Saf fonksiyondur.
public func keyboardAskAnswerIsStale(answer: KeyboardAskAnswer?, command: KeyboardAskCommand?, now: Date) -> Bool {
    guard let answer else {
        return false
    }
    guard let command, command.requestID == answer.requestID, command.action == .ask else {
        return true
    }
    return now.timeIntervalSince(answer.updatedAt) > keyboardAskAnswerLifetime
}

/// Soru alanına harf ekler; sınırı aşan metin kesilir. Saf fonksiyondur.
public func keyboardAskQuestionAppending(question: String, text: String) -> String {
    String((question + text).prefix(keyboardAskQuestionLimit))
}

/// Sorulacak bağlantı (`gistsmith://keyboard/ask/<istek>`). Saf fonksiyondur.
public func keyboardAskURL(requestID: UUID) -> URL {
    // Şema, ana bilgisayar ve UUID metni her zaman geçerli bir adres oluşturur.
    URL(string: "gistsmith://keyboard/ask/\(requestID.uuidString)")!
}
