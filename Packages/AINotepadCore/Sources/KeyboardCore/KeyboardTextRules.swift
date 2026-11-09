import Foundation

/// Alanın büyük harf kuralı (`UITextAutocapitalizationType`'ın karşılığı; UIKit'e bağlı kalmasın diye).
public enum KeyboardAutocapitalization: Sendable, Hashable {
    case none
    case words
    case sentences
    case allCharacters
}

/// Kelimenin parçası sayılan karakterler: harf, rakam ve kelime içi kesme işareti ("don't", "Ali'nin", "l'homme").
func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "'" || character == "’"
}

/// İmlecin hemen solundaki yarım kelime (boşluk ya da noktalamadan sonrası); yoksa boş. Saf fonksiyondur.
public func keyboardCurrentWord(contextBefore: String) -> String {
    String(contextBefore.reversed().prefix { isWordCharacter($0) }.reversed())
}

/// Sıradaki harf büyük mü yazılmalı. Cümle kuralında alan başı, satır başı ve ". ! ?" ardından boşluk büyük harf
/// ister. Saf fonksiyondur.
public func keyboardShouldCapitalize(contextBefore: String, rule: KeyboardAutocapitalization) -> Bool {
    switch rule {
    case .none:
        return false
    case .allCharacters:
        return true
    case .words:
        guard let last = contextBefore.last else {
            return true
        }
        return last.isWhitespace
    case .sentences:
        guard let last = contextBefore.last else {
            return true
        }
        if last.isNewline {
            return true
        }
        guard last.isWhitespace else {
            return false
        }
        let beforeSpaces: String = String(contextBefore.reversed().drop { $0 == " " }.reversed())
        guard let end = beforeSpaces.last else {
            return true
        }
        return end == "." || end == "!" || end == "?" || end.isNewline
    }
}

/// Çift boşluk noktası: sol tarafta bir kelime ve tek boşluk varsa ikinci boşluk ". " olur. Silinecek karakter sayısı
/// (1, boşluk) döner; uygulanmayacaksa nil. Saf fonksiyondur.
public func keyboardDoubleSpacePeriod(contextBefore: String) -> Int? {
    guard contextBefore.hasSuffix(" "), !contextBefore.hasSuffix("  ") else {
        return nil
    }
    let withoutSpace: Substring = contextBefore.dropLast()
    guard let previous = withoutSpace.last, previous.isLetter || previous.isNumber else {
        return nil
    }
    return 1
}

/// İngilizce kesme işaretli kısaltmalar: `UITextChecker` önermez, sistem klavyesi düzeltir ("dont" → "don't",
/// tek başına "i" → "I"). Gerçek kelime olanlar ("were", "ill", "lets", "id") listede yok.
private let englishContractions: [String: String] = [
    "i": "I", "im": "I'm", "ive": "I've", "ill": "I'll", "id": "I'd",
    "dont": "don't", "cant": "can't", "wont": "won't", "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't",
    "werent": "weren't", "didnt": "didn't", "doesnt": "doesn't", "hasnt": "hasn't", "havent": "haven't",
    "hadnt": "hadn't", "couldnt": "couldn't", "shouldnt": "shouldn't", "wouldnt": "wouldn't", "mustnt": "mustn't",
    "youre": "you're", "youve": "you've", "youll": "you'll", "theyre": "they're", "theyve": "they've",
    "theyll": "they'll", "thats": "that's", "whats": "what's", "theres": "there's", "heres": "here's",
    "shes": "she's", "hes": "he's", "weve": "we've", "lets": "let's", "itll": "it'll", "wheres": "where's",
]

/// "ill", "id", "lets" İngilizcede gerçek kelimedir: yalnız büyük "I" ile kullanılan ikisi ("ill", "id") ve "lets"
/// kendiliğinden düzeltilmez, yalnız öneri olur.
private let englishContractionsSuggestOnly: Set<String> = ["ill", "id", "lets"]

/// İngilizce kısaltma düzeltmesi: kelime listede varsa doğru yazımı (büyük harfi korur) ve kendiliğinden uygulanıp
/// uygulanmayacağı. Saf fonksiyondur.
public func keyboardContraction(word: String, language: KeyboardLanguage) -> (replacement: String, autoApply: Bool)? {
    guard language == .english, let fixed = englishContractions[word.lowercased()] else {
        return nil
    }
    let replacement: String = word.first?.isUppercase == true ? keyboardCapitalizedFirst(fixed, language: language) : fixed
    guard replacement != word else {
        return nil
    }
    return (replacement, !englishContractionsSuggestOnly.contains(word.lowercased()))
}

/// Alanın içeriği: hassas alanlarda kelime öğrenilmez, kendiliğinden düzeltme yapılmaz.
public struct KeyboardFieldTraits: Sendable, Hashable {
    /// Alan otomatik düzeltmeyi kapattı (`autocorrectionType == .no`).
    public let autocorrectionDisabled: Bool
    /// `textContentType` ham değeri (ör. "one-time-code", "password"); yoksa nil.
    public let contentType: String?
    /// Rakam ya da telefon klavyesi isteyen alan.
    public let isNumeric: Bool

    public init(autocorrectionDisabled: Bool, contentType: String?, isNumeric: Bool) {
        self.autocorrectionDisabled = autocorrectionDisabled
        self.contentType = contentType
        self.isNumeric = isNumeric
    }
}

/// Hassas sayılan `textContentType` değerleri (UIKit sabitlerinin ham değerleri).
private let sensitiveContentTypes: Set<String> = [
    "one-time-code", "password", "new-password", "username", "tel", "cc-number", "cc-csc", "cc-exp", "cc-name",
    "cc-given-name", "cc-family-name", "cc-additional-name", "cc-exp-month", "cc-exp-year", "cc-type",
    "creditCardNumber", "oneTimeCode", "newPassword", "telephoneNumber",
]

/// Alanda kendiliğinden düzeltme ve öğrenme yapılabilir mi. Saf fonksiyondur.
public func keyboardAllowsLearning(traits: KeyboardFieldTraits) -> Bool {
    guard !traits.autocorrectionDisabled, !traits.isNumeric else {
        return false
    }
    guard let type = traits.contentType else {
        return true
    }
    return !sensitiveContentTypes.contains(type)
}
