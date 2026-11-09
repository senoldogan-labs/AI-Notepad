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
    /// Soran alanın kimliği: cevap yalnız aynı alana kendiliğinden önerilir.
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

/// Klavyedeki "Gistsmith'e sor" şeridinin durumu.
public enum KeyboardAskState: Sendable, Hashable {
    /// Soru yok.
    case idle
    /// Uygulama açılıyor ya da cevaplıyor.
    case answering
    /// Cevap hazır: kullanıcı "Ekle"ye dokununca eklenir.
    case answered(String)
    /// Cevaplanamadı; neden uygulamanın yazdığı metin, yoksa nil (klavye kendi metnini gösterir).
    case failed(String?)
}

/// Şeridin durumu: klavyenin son sorusu ve uygulamanın cevabından. Yalnız son soruya ait, `release` edilmemiş ve
/// süresi geçmemiş cevap gösterilir; uygulama uzun süre cevaplamazsa soru başarısız sayılır. Saf fonksiyondur.
public func keyboardAskState(command: KeyboardAskCommand?, answer: KeyboardAskAnswer?, now: Date) -> KeyboardAskState {
    guard let command, command.action == .ask else {
        return .idle
    }
    guard let answer, answer.requestID == command.requestID else {
        // Uygulama henüz yazmadı: soru tazeyse bekleniyor.
        return now.timeIntervalSince(command.issuedAt) <= keyboardAskAnsweringTimeout ? .answering : .failed(nil)
    }
    switch answer.phase {
    case .answering:
        return now.timeIntervalSince(answer.updatedAt) <= keyboardAskAnsweringTimeout ? .answering : .failed(nil)
    case .answered:
        guard let text = answer.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .failed(nil)
        }
        return now.timeIntervalSince(answer.updatedAt) <= keyboardAskAnswerLifetime ? .answered(text) : .idle
    case .failed:
        return .failed(answer.failureReason)
    }
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
