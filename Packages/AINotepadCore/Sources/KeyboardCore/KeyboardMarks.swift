import Foundation

// Restoring the marks of a word typed without them ("gorusme" → "görüşme", "cok" → "çok"), as the system keyboard does
// for languages whose letters carry marks. Turkish only: its six marked letters each have one plain twin (c/ç, g/ğ,
// i/ı, o/ö, s/ş, u/ü), and vowel harmony says which spellings are worth asking the dictionary about.
//
// Apple's Turkish dictionary accepts the plain spelling of some of the most frequent words ("icin", "degil", "bugun",
// "simdi", measured with `UITextChecker` on the iOS Simulator), so a dictionary alone never restores them; a short
// hand-made table of frequent words whose plain spelling nobody means covers those.

/// How many dictionary checks one word's restoration may spend. Apple's checker takes about 0.6 ms per word (iOS
/// Simulator on an M-series Mac); most words need 1–4 checks.
public let keyboardMarkCheckBudget: Int = 12

/// The longest word whose marks are restored, and the most vowels (and consonants) in it that may get a mark: at most
/// 2^10 vowel choices are ranked.
let keyboardMarkMaximumLength: Int = 24
let keyboardMarkMaximumFlips: Int = 10

/// The spellings with marks restored for `word` typed in `language`, most likely first: one spelling is applied as the
/// autocorrection, several are only offered (the user picks; "aci" is "acı" or "açı"). Empty when the language has no
/// marks to restore, the word is not a plain lowercase, capitalised or all-caps word, or nothing fits.
///
/// A frequent word from the table is restored even when the dictionary accepts its plain spelling. Any other word is
/// restored only when the typing language's dictionary does not know it (`knownInTypingLanguage`; "isim" stays "isim")
/// and accepts a restored spelling (`isValid`, asked at most `checkBudget` times). A word another selected language
/// knows is never restored (`knownInOtherLanguage`, asked only when there is something to restore: a bilingual user's
/// English "once" stays). Pure function; the dictionaries are injected.
public func keyboardMarkRestorations(
    word: String, language: KeyboardLanguage, knownInTypingLanguage: Bool, knownInOtherLanguage: () -> Bool, checkBudget: Int,
    isValid: (String) -> Bool
) -> [String] {
    guard language == .turkish, isRestorable(word: word) else {
        return []
    }
    let lowered: String = word.lowercased(with: language.casingLocale)
    if let frequent = turkishFrequentRestorations[lowered] {
        return knownInOtherLanguage() ? [] : [matchingCase(frequent, typed: word, language: language)]
    }
    guard !knownInTypingLanguage else {
        return []
    }
    let candidates: [KeyboardMarkCandidate] = turkishMarkCandidates(lowered: lowered, limit: checkBudget)
    guard !candidates.isEmpty, !knownInOtherLanguage() else {
        return []
    }
    return turkishDictionaryRestorations(typed: lowered, candidates: candidates, checkBudget: checkBudget, isValid: isValid).map {
        matchingCase($0, typed: word, language: language)
    }
}

/// A word whose marks may be restored: letters only, 2–24 of them, and no capital inside it ("iPhone").
private func isRestorable(word: String) -> Bool {
    guard word.count >= 2, word.count <= keyboardMarkMaximumLength, word.allSatisfy(\.isLetter) else {
        return false
    }
    let tail: Substring = word.dropFirst()
    return word == word.uppercased() || tail == tail.lowercased()
}

/// One spelling of a typed word with some marks restored, and how far it strays from Turkish vowel harmony.
struct KeyboardMarkCandidate: Sendable, Hashable {
    let word: String
    let penalty: Int
}

private let turkishMarks: [Character: Character] = ["c": "ç", "g": "ğ", "i": "ı", "o": "ö", "s": "ş", "u": "ü"]
private let turkishBackVowels: Set<Character> = ["a", "ı", "o", "u"]
private let turkishFrontVowels: Set<Character> = ["e", "i", "ö", "ü"]

/// A vowel of the typed word, for the harmony penalty: whether it is back as typed and once marked, whether it is an
/// "o" or "ö", the bit of the vowel mask that marks it (nil when it cannot get a mark), and whether it is the fixed "o"
/// of "-yor".
private struct TurkishVowel {
    let isBack: Bool
    let isBackMarked: Bool
    let isPlainO: Bool
    let isTypedOWithUmlaut: Bool
    let bit: Int?
    let isPresentTenseO: Bool
}

/// The first `limit` spellings of the lowercased `lowered` with some of its plain letters marked, the typed spelling
/// left out, the most harmonious first. A "g" only becomes "ğ" after a vowel (no Turkish word starts with "ğ" or has it
/// after a consonant), and the "o" of the present-tense "-yor" stays. Only the vowels decide harmony, so the vowel
/// choices are ranked (at most 2^10, integer work) and the spellings are built lazily, `limit` at most. Empty when more
/// than `keyboardMarkMaximumFlips` vowels or consonants could be marked. Pure function.
func turkishMarkCandidates(lowered: String, limit: Int) -> [KeyboardMarkCandidate] {
    let letters: [Character] = Array(lowered)
    let flippable: [Int] = letters.indices.filter { turkishCarriesMark(letters, at: $0) }
    let vowelPositions: [Int] = flippable.filter { isTurkishVowel(letters[$0]) }
    let consonantPositions: [Int] = flippable.filter { !isTurkishVowel(letters[$0]) }
    guard !flippable.isEmpty, vowelPositions.count <= keyboardMarkMaximumFlips, consonantPositions.count <= keyboardMarkMaximumFlips else {
        return []
    }
    let vowels: [TurkishVowel] = letters.indices.filter { isTurkishVowel(letters[$0]) }.map { (position: Int) -> TurkishVowel in
        let letter: Character = letters[position]
        let marked: Character = turkishMarks[letter] ?? letter
        return TurkishVowel(
            isBack: turkishBackVowels.contains(letter), isBackMarked: turkishBackVowels.contains(marked), isPlainO: letter == "o",
            isTypedOWithUmlaut: letter == "ö", bit: vowelPositions.firstIndex(of: position), isPresentTenseO: isTurkishPresentTenseO(letters, at: position)
        )
    }
    let vowelMasks: [(mask: Int, penalty: Int)] = (0 ..< (1 << vowelPositions.count)).map { (mask: Int) -> (mask: Int, penalty: Int) in
        (mask, turkishHarmonyPenalty(vowels: vowels, mask: mask))
    }.sorted { $0.penalty < $1.penalty }
    var candidates: [KeyboardMarkCandidate] = []
    for vowelMask in vowelMasks {
        for consonantMask in 0 ..< (1 << consonantPositions.count) where vowelMask.mask != 0 || consonantMask != 0 {
            guard candidates.count < limit else {
                return candidates
            }
            var spelled: [Character] = letters
            for (bit, position) in vowelPositions.enumerated() where vowelMask.mask & (1 << bit) != 0 {
                spelled[position] = turkishMarks[letters[position]] ?? letters[position]
            }
            for (bit, position) in consonantPositions.enumerated() where consonantMask & (1 << bit) != 0 {
                spelled[position] = turkishMarks[letters[position]] ?? letters[position]
            }
            candidates.append(KeyboardMarkCandidate(word: String(spelled), penalty: vowelMask.penalty))
        }
    }
    return candidates
}

/// Asks the dictionary about `candidates` (`turkishMarkCandidates`, most harmonious first) tier by tier (equal harmony
/// penalty) and picks among the accepted spellings of the first tier that has any (`turkishChosenRestorations`): a less
/// harmonious spelling never competes with a more harmonious one. Stops after `checkBudget` checks. `typed` is the
/// lowercased typed word.
func turkishDictionaryRestorations(typed: String, candidates: [KeyboardMarkCandidate], checkBudget: Int, isValid: (String) -> Bool) -> [String] {
    var found: [String] = []
    var tier: Int?
    var checks: Int = 0
    for candidate in candidates {
        if let tier, candidate.penalty != tier, !found.isEmpty {
            break
        }
        guard checks < checkBudget else {
            break
        }
        checks += 1
        tier = candidate.penalty
        if isValid(candidate.word) {
            found.append(candidate.word)
        }
    }
    return turkishChosenRestorations(typed: typed, accepted: found)
}

/// The shortest word whose spelling with one mark more wins over the one without (`turkishChosenRestorations`).
let turkishFullestMarksLength: Int = 5

/// The word among the `accepted` spellings of `typed` (lowercased), or all of them, the likeliest first, when it is not
/// clear. Apple's Turkish checker is lenient: it also accepts a word with a mark left out and now and then one with a
/// mark too many ("çalışmalar" with "çalısmalar" and "calışmalar"; "çocuğum" with "cocuğum" and "çoçuğum"; measured
/// with `NSSpellChecker` on macOS, whose Turkish dictionary the iPhone shares; the iOS Simulator's misses basic words
/// such as "ev" and "kitap"). So the word is the one spelling a single mark away from every other accepted one. Of two
/// spellings a mark apart, the one with the mark is the word (a left-out mark is what the checker forgives most:
/// "ögrenciler", "yapacagım"), but only from `turkishFullestMarksLength` letters: shorter ones are different words
/// ("acı", "açı"). Otherwise the most central spellings come first, then those with the most marks. Pure function.
func turkishChosenRestorations(typed: String, accepted: [String]) -> [String] {
    guard accepted.count > 1 else {
        return accepted
    }
    let typedLetters: [Character] = Array(typed)
    let spellings: [[Character]] = accepted.map { Array($0) }
    let neighbours: [Int] = spellings.map { (spelling: [Character]) -> Int in
        spellings.filter { markDistance(spelling, $0) == 1 }.count
    }
    let marks: [Int] = spellings.map { markDistance($0, typedLetters) }
    let ranked: [Int] = accepted.indices.sorted { (lhs: Int, rhs: Int) -> Bool in
        neighbours[lhs] != neighbours[rhs] ? neighbours[lhs] > neighbours[rhs] : marks[lhs] > marks[rhs]
    }
    let centers: [Int] = ranked.filter { neighbours[$0] == accepted.count - 1 }
    if centers.count == 1, accepted.count > 2 {
        return [accepted[centers[0]]]
    }
    if accepted.count == 2, centers.count == 2, typedLetters.count >= turkishFullestMarksLength, marks[ranked[0]] > marks[ranked[1]] {
        return [accepted[ranked[0]]]
    }
    return ranked.map { accepted[$0] }
}

/// How many letters two spellings of the same word differ in.
private func markDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
    zip(lhs, rhs).filter { $0 != $1 }.count
}

private func turkishCarriesMark(_ letters: [Character], at index: Int) -> Bool {
    let letter: Character = letters[index]
    guard turkishMarks[letter] != nil else {
        return false
    }
    switch letter {
    case "g":
        return index > 0 && isTurkishVowel(letters[index - 1])
    case "o":
        return !isTurkishPresentTenseO(letters, at: index)
    default:
        return true
    }
}

/// The "o" of "-iyor", "-ıyor", "-uyor", "-üyor": always back, whatever vowel comes before it.
private func isTurkishPresentTenseO(_ letters: [Character], at index: Int) -> Bool {
    letters[index] == "o" && index >= 2 && index + 1 < letters.count && letters[index - 1] == "y" && letters[index + 1] == "r"
        && isTurkishVowel(letters[index - 2])
}

private func isTurkishVowel(_ letter: Character) -> Bool {
    turkishBackVowels.contains(letter) || turkishFrontVowels.contains(letter)
}

/// How far a spelling (the vowels with `mask`'s marks) strays from Turkish vowel harmony: one point for each back vowel
/// next to a front one (the "-yor" suffix starts over as back) and for each "ö" after the first syllable (native words
/// have it only there).
private func turkishHarmonyPenalty(vowels: [TurkishVowel], mask: Int) -> Int {
    var penalty: Int = 0
    var previousIsBack: Bool?
    for (index, vowel) in vowels.enumerated() {
        let isMarked: Bool = vowel.bit.map { mask & (1 << $0) != 0 } ?? false
        if index > 0, vowel.isTypedOWithUmlaut || (vowel.isPlainO && isMarked) {
            penalty += 1
        }
        if vowel.isPresentTenseO {
            previousIsBack = true
            continue
        }
        let isBack: Bool = isMarked ? vowel.isBackMarked : vowel.isBack
        if let previousIsBack, previousIsBack != isBack {
            penalty += 1
        }
        previousIsBack = isBack
    }
    return penalty
}

/// Frequent Turkish words written without marks, mapped to the word meant. Only words whose plain spelling is not a
/// word anyone means and that have one marked reading ("oldu"/"öldü", "isim"/"işim", "koy"/"köy", "dis"/"diş"/"dış"
/// are not here). Several plain spellings are accepted by Apple's Turkish dictionary ("icin", "degil", "bugun", "yarin",
/// "aksam", "kisi", "simdi", "kucuk"), the reason this table exists; the rest skip the dictionary.
let turkishFrequentRestorations: [String: String] = [
    // Function words.
    "icin": "için", "icinde": "içinde", "icine": "içine", "degil": "değil", "degilim": "değilim", "degiliz": "değiliz",
    "degilsin": "değilsin", "degildi": "değildi", "degilse": "değilse", "cok": "çok", "sey": "şey", "seyler": "şeyler",
    "seyi": "şeyi", "simdi": "şimdi", "simdilik": "şimdilik", "soyle": "şöyle", "boyle": "böyle", "oyle": "öyle",
    "boylece": "böylece", "cunku": "çünkü", "gore": "göre", "once": "önce", "onceki": "önceki", "oncelikle": "öncelikle",
    "uzere": "üzere", "hic": "hiç", "hicbir": "hiçbir", "bircok": "birçok", "cogu": "çoğu", "bazi": "bazı", "baska": "başka",
    "ayni": "aynı", "diger": "diğer", "butun": "bütün", "tum": "tüm", "nasil": "nasıl", "nasilsin": "nasılsın",
    "nasilsiniz": "nasılsınız", "kac": "kaç", "disinda": "dışında", "uzerinde": "üzerinde", "uzerine": "üzerine",
    "yuzunden": "yüzünden", "ragmen": "rağmen", "asagi": "aşağı", "artik": "artık", "aslinda": "aslında",
    "yakinda": "yakında", "yalniz": "yalnız", "gercekten": "gerçekten", "gercek": "gerçek", "keske": "keşke",
    "cabuk": "çabuk", "kisisel": "kişisel", "kisilik": "kişilik", "dogrudan": "doğrudan", "icerik": "içerik",
    "dusundum": "düşündüm", "icerisinde": "içerisinde", "isci": "işçi",
    // Plain spellings with two marked readings, one far more frequent ("acı" over "açı", "sık" over "şık").
    "aci": "acı", "sik": "sık",
    // Time.
    "bugun": "bugün", "bugunku": "bugünkü", "yarin": "yarın", "dun": "dün", "aksam": "akşam", "aksamlar": "akşamlar",
    "ogle": "öğle", "oglen": "öğlen", "ogleden": "öğleden", "gun": "gün", "gunler": "günler", "gunu": "günü", "yil": "yıl",
    "gec": "geç", "gecen": "geçen", "sali": "salı", "carsamba": "çarşamba", "persembe": "perşembe", "subat": "şubat",
    "mayis": "mayıs", "agustos": "ağustos", "eylul": "eylül", "kasim": "kasım", "aralik": "aralık",
    // Numbers.
    "dort": "dört", "bes": "beş", "alti": "altı", "altmis": "altmış", "yetmis": "yetmiş", "yuz": "yüz", "ucuncu": "üçüncü",
    "ceyrek": "çeyrek",
    // Greetings and courtesy.
    "tesekkur": "teşekkür", "tesekkurler": "teşekkürler", "lutfen": "lütfen", "gunaydin": "günaydın",
    "gorusuruz": "görüşürüz", "goruselim": "görüşelim", "gorustuk": "görüştük", "hosca": "hoşça", "hos": "hoş",
    "hosgeldin": "hoşgeldin", "hosgeldiniz": "hoşgeldiniz", "sagol": "sağol", "sag": "sağ", "saglik": "sağlık",
    "gecmis": "geçmiş", "hayir": "hayır", "insallah": "inşallah", "masallah": "maşallah", "ozur": "özür", "canim": "canım",
    "tatlim": "tatlım",
    // Work and meetings.
    "toplanti": "toplantı", "toplantiya": "toplantıya", "toplantida": "toplantıda", "toplantiyi": "toplantıyı",
    "toplantisi": "toplantısı", "gorusme": "görüşme", "gorusmek": "görüşmek", "sirket": "şirket", "musteri": "müşteri",
    "ogrenci": "öğrenci", "ogretmen": "öğretmen", "kisi": "kişi", "kisiler": "kişiler", "butce": "bütçe", "ucret": "ücret",
    "odeme": "ödeme", "sozlesme": "sözleşme", "gorev": "görev", "gorevler": "görevler", "yonetici": "yönetici",
    "calisan": "çalışan", "calisanlar": "çalışanlar", "calisma": "çalışma", "calismak": "çalışmak",
    "calisiyorum": "çalışıyorum", "iletisim": "iletişim", "cozum": "çözüm", "sonuc": "sonuç", "degisiklik": "değişiklik",
    "guncelleme": "güncelleme", "ozellik": "özellik", "urun": "ürün", "kullanici": "kullanıcı", "yazilim": "yazılım",
    "isler": "işler", "gorus": "görüş", "oneri": "öneri", "onemli": "önemli", "mumkun": "mümkün", "musait": "müsait",
    "mesgul": "meşgul", "hazir": "hazır", "acik": "açık", "kapali": "kapalı", "kapi": "kapı", "hizli": "hızlı",
    "yavas": "yavaş", "kisa": "kısa", "guzel": "güzel", "kotu": "kötü", "buyuk": "büyük", "kucuk": "küçük",
    "dogru": "doğru", "yanlis": "yanlış", "basarili": "başarılı", "cikti": "çıktı", "cikis": "çıkış", "giris": "giriş",
    "basla": "başla", "baslayalim": "başlayalım", "duzelt": "düzelt", "duzenle": "düzenle", "degistir": "değiştir",
    "gonder": "gönder", "gonderdim": "gönderdim", "gordum": "gördüm", "anladim": "anladım", "anlamadim": "anlamadım",
    "lazim": "lazım", "yapiyorum": "yapıyorum", "dusunuyorum": "düşünüyorum", "soyledim": "söyledim",
    "konusalim": "konuşalım", "konusma": "konuşma", "konustuk": "konuştuk", "bakarim": "bakarım", "olmus": "olmuş",
    // Everyday words.
    "odev": "ödev", "sinav": "sınav", "sinif": "sınıf", "universite": "üniversite", "muzik": "müzik", "otobus": "otobüs",
    "ucak": "uçak", "gunes": "güneş", "yagmur": "yağmur", "soguk": "soğuk", "sicak": "sıcak", "uzgun": "üzgün",
    "cocuk": "çocuk", "cocuklar": "çocuklar", "kiz": "kız", "oglum": "oğlum", "kizim": "kızım", "kardes": "kardeş",
    "arkadas": "arkadaş", "arkadaslar": "arkadaşlar", "sehir": "şehir", "ulke": "ülke", "dunya": "dünya",
    "turkiye": "Türkiye", "turkce": "Türkçe", "ingilizce": "İngilizce", "istanbul": "İstanbul", "izmir": "İzmir",
    "cay": "çay", "seker": "şeker", "sut": "süt", "balik": "balık", "ilac": "ilaç", "isik": "ışık", "saka": "şaka",
    "ask": "aşk", "mac": "maç", "kis": "kış",
]
