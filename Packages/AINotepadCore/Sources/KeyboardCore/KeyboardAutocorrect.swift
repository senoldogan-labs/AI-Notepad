import Foundation

/// Öneri çubuğundaki bir öneri.
public struct KeyboardSuggestion: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Yazılan kelimenin kendisi (tırnak içinde): düzeltmeyi istemeyen buna dokunur.
        case typed
        /// Düzeltme (yazım hatası, kısaltma, sözlükteki yazım).
        case correction
        /// Yarım kelimenin tamamlanışı.
        case completion
    }

    public let text: String
    public let kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

/// Öneri çubuğu: en fazla üç öneri ve boşluğa basınca kendiliğinden uygulanacak düzeltme (varsa çubukta vurgulu).
public struct KeyboardSuggestions: Sendable, Hashable {
    public let items: [KeyboardSuggestion]
    public let autocorrection: String?

    public init(items: [KeyboardSuggestion], autocorrection: String?) {
        self.items = items
        self.autocorrection = autocorrection
    }

    public static let empty: KeyboardSuggestions = KeyboardSuggestions(items: [], autocorrection: nil)
}

/// Öneri hesabının girdileri. Sözlük sorguları (`UITextChecker`, `UILexicon`) uzantıda yapılır, sonuçları buraya gelir.
public struct KeyboardSuggestionInput: Sendable, Hashable {
    public let typed: String
    public let language: KeyboardLanguage
    /// Kelime seçili dillerden birinin sözlüğünde var (iki dilli kullanıcı: Türkçe yazarken İngilizce kelime düzeltilmez).
    public let isKnownWord: Bool
    /// Dil sözlüğünün yazım önerileri (en olası önce).
    public let guesses: [String]
    /// Dil sözlüğünün tamamlamaları.
    public let completions: [String]
    /// Kişisel sözlük: Gistsmith sözlüğü, adınız, öğrenilen kelimeler, rehberdeki adlar.
    public let personalWords: [String]
    /// Metin değiştirmeleri (Ayarlar › Klavye › Metin Değiştirme; kısaltma → metin).
    public let shortcuts: [String: String]
    /// Bu alanda geri alınan düzeltmeler: aynı kelime yeniden düzeltilmez.
    public let rejected: Set<String>
    /// Ayar ve alan kendiliğinden düzeltmeye izin veriyor.
    public let autocorrectAllowed: Bool

    public init(
        typed: String, language: KeyboardLanguage, isKnownWord: Bool, guesses: [String], completions: [String], personalWords: [String],
        shortcuts: [String: String], rejected: Set<String>, autocorrectAllowed: Bool
    ) {
        self.typed = typed
        self.language = language
        self.isKnownWord = isKnownWord
        self.guesses = guesses
        self.completions = completions
        self.personalWords = personalWords
        self.shortcuts = shortcuts
        self.rejected = rejected
        self.autocorrectAllowed = autocorrectAllowed
    }
}

/// Önerileri ve kendiliğinden düzeltmeyi hesaplar. Kendiliğinden düzeltme yalnız şu durumlarda olur: metin değiştirme
/// kısaltması, İngilizce kısaltma ("dont" → "don't"), kişisel sözlükteki kelimenin büyük harf yazımı ya da sözlükte
/// olmayan kelimeye tek açık aday (en çok 1–2 harf farkı, kişisel sözlük kelimeleri önce). Kişisel sözlükteki, bilinen
/// ya da bu alanda geri alınmış kelime düzeltilmez; rakam, "@", "/" içeren ve kelime içinde büyük harfli yazımlara
/// dokunulmaz. Saf fonksiyondur.
public func keyboardSuggestions(input: KeyboardSuggestionInput) -> KeyboardSuggestions {
    let typed: String = input.typed
    guard !typed.isEmpty else {
        return .empty
    }
    let lowered: String = typed.lowercased()
    let personalExact: String? = input.personalWords.first { $0.lowercased() == lowered }
    let autocorrection: String? = input.autocorrectAllowed && !input.rejected.contains(typed) ? autocorrectionCandidate(input: input, personalExact: personalExact) : nil
    var items: [KeyboardSuggestion] = []
    func add(_ suggestion: KeyboardSuggestion) {
        guard items.count < 3, !items.contains(where: { $0.text == suggestion.text }) else {
            return
        }
        items.append(suggestion)
    }
    if let autocorrection {
        add(KeyboardSuggestion(text: typed, kind: .typed))
        add(KeyboardSuggestion(text: autocorrection, kind: .correction))
    }
    if let personalExact, personalExact != typed {
        add(KeyboardSuggestion(text: personalExact, kind: .correction))
    }
    if let contraction = keyboardContraction(word: typed, language: input.language) {
        add(KeyboardSuggestion(text: contraction.replacement, kind: .correction))
    }
    let personalCompletions: [String] = input.personalWords.filter {
        $0.count > typed.count && $0.lowercased().hasPrefix(lowered)
    }
    for word in personalCompletions.sorted(by: { $0.count < $1.count }) {
        add(KeyboardSuggestion(text: matchingCase(word, typed: typed, language: input.language), kind: .completion))
    }
    if !input.isKnownWord && personalExact == nil {
        for guess in input.guesses.prefix(2) {
            add(KeyboardSuggestion(text: matchingCase(guess, typed: typed, language: input.language), kind: .correction))
        }
    }
    for completion in input.completions where completion.lowercased() != lowered {
        add(KeyboardSuggestion(text: matchingCase(completion, typed: typed, language: input.language), kind: .completion))
    }
    if autocorrection == nil, !items.isEmpty, !items.contains(where: { $0.text == typed }) {
        // Yazılan kelime de seçilebilsin (iOS'taki gibi solda tırnak içinde); yer yoksa son öneri çıkar.
        items = [KeyboardSuggestion(text: typed, kind: .typed)] + items.prefix(2)
    }
    return KeyboardSuggestions(items: items, autocorrection: autocorrection)
}

/// Kendiliğinden uygulanacak düzeltme; yoksa nil.
private func autocorrectionCandidate(input: KeyboardSuggestionInput, personalExact: String?) -> String? {
    let typed: String = input.typed
    if let shortcut = input.shortcuts.first(where: { $0.key.lowercased() == typed.lowercased() })?.value, shortcut != typed {
        return shortcut
    }
    if let contraction = keyboardContraction(word: typed, language: input.language), contraction.autoApply {
        return contraction.replacement
    }
    if let personalExact {
        // Sözlükteki yazım ("gistsmith" → "Gistsmith"); kullanıcı zaten büyük yazdıysa dokunulmaz.
        return personalExact != typed && typed == typed.lowercased() ? personalExact : nil
    }
    guard !input.isKnownWord, isCorrectable(word: typed) else {
        return nil
    }
    let limit: Int = maximumEditDistance(length: typed.count)
    guard limit > 0 else {
        return nil
    }
    let lowered: String = typed.lowercased()
    let personal: [(word: String, distance: Int)] = input.personalWords.compactMap { (word: String) -> (word: String, distance: Int)? in
        let distance: Int = keyboardEditDistance(lowered, word.lowercased())
        return distance <= limit ? (word, distance) : nil
    }
    if let best = personal.min(by: { $0.distance < $1.distance }) {
        return best.word
    }
    guard let first = input.guesses.first else {
        return nil
    }
    let distance: Int = keyboardEditDistance(lowered, first.lowercased())
    guard distance <= limit else {
        return nil
    }
    // İkinci aday da aynı yakınlıktaysa seçim belirsizdir: düzeltilmez, yalnız önerilir.
    if input.guesses.count > 1, keyboardEditDistance(lowered, input.guesses[1].lowercased()) == distance, distance > 1 {
        return nil
    }
    return matchingCase(first, typed: typed, language: input.language)
}

/// Düzeltilebilir yazım: harflerden oluşur (kelime içi kesme işareti olabilir), rakam, "@", "/" ve "." içermez,
/// kelimenin ortasında büyük harf yoktur ("iPhone", "McDonald" gibi bilerek yazılmış biçimler).
private func isCorrectable(word: String) -> Bool {
    guard word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else {
        return false
    }
    let tail: Substring = word.dropFirst()
    let isAllCaps: Bool = word == word.uppercased()
    return isAllCaps || tail == tail.lowercased()
}

/// Kelime uzunluğuna göre izin verilen fark: 1–2 harf düzeltilmez, 3–5 harfte 1, daha uzunda 2.
func maximumEditDistance(length: Int) -> Int {
    switch length {
    case ..<3:
        0
    case 3 ... 5:
        1
    default:
        2
    }
}

/// Önerinin büyük harfini yazılana uydurur: tamamı büyükse tamamı, ilk harf büyükse ilk harf.
private func matchingCase(_ candidate: String, typed: String, language: KeyboardLanguage) -> String {
    if typed.count > 1, typed == keyboardUppercased(typed, language: language), typed != typed.lowercased() {
        return keyboardUppercased(candidate, language: language)
    }
    if typed.first?.isUppercase == true {
        return keyboardCapitalizedFirst(candidate, language: language)
    }
    return candidate
}

/// İki kelime arasındaki harf farkı (ekleme, silme, değiştirme, yan yana iki harfin yer değiştirmesi). Saf fonksiyondur.
public func keyboardEditDistance(_ lhs: String, _ rhs: String) -> Int {
    let a: [Character] = Array(lhs)
    let b: [Character] = Array(rhs)
    if a.isEmpty {
        return b.count
    }
    if b.isEmpty {
        return a.count
    }
    var table: [[Int]] = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0 ... a.count {
        table[i][0] = i
    }
    for j in 0 ... b.count {
        table[0][j] = j
    }
    for i in 1 ... a.count {
        for j in 1 ... b.count {
            let cost: Int = a[i - 1] == b[j - 1] ? 0 : 1
            var value: Int = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
            if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                value = min(value, table[i - 2][j - 2] + 1)
            }
            table[i][j] = value
        }
    }
    return table[a.count][b.count]
}

/// Öğrenilebilir kelime: en az iki harf, rakam yok, en fazla 40 karakter. Saf fonksiyondur.
public func keyboardIsLearnable(word: String) -> Bool {
    word.count >= 2 && word.count <= 40 && word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
}

/// Öğrenilen kelimeler listesine ekler: zaten varsa en sona taşır, en fazla `limit` kelime tutar (eskiler düşer).
/// Saf fonksiyondur.
public func keyboardLearnedWordsAdding(word: String, to words: [String], limit: Int) -> [String] {
    guard keyboardIsLearnable(word: word) else {
        return words
    }
    let others: [String] = words.filter { $0 != word }
    return Array((others + [word]).suffix(limit))
}
