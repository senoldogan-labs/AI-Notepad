import Foundation

/// Sor alanına sesle söylenen soruyu ekler: alan boşsa söylenen metin alanın kendisi olur, doluysa sonuna (gerekirse bir
/// boşlukla) eklenir. Metin gönderilmez; kullanıcı gözden geçirip kendisi gönderir. Saf fonksiyondur.
public func askQuestionAppending(question: String, dictated: String) -> String {
    guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return dictated
    }
    return question.last?.isWhitespace == true ? question + dictated : question + " " + dictated
}
