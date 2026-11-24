import Foundation
import Testing
@testable import KeyboardCore

/// Turkish words typed without their marks get them back ("gorusme" → "görüşme"), through the autocorrection.
@Suite struct KeyboardMarksTests {
    /// A Turkish dictionary of a few words, counting how often it is asked.
    private final class FakeDictionary {
        let words: Set<String>
        var checks: Int = 0

        init(words: Set<String>) {
            self.words = words
        }

        func isValid(_ word: String) -> Bool {
            checks += 1
            return words.contains(word)
        }
    }

    private func restorations(_ word: String, dictionary: FakeDictionary, known: Bool, knownElsewhere: Bool, language: KeyboardLanguage) -> [String] {
        keyboardMarkRestorations(
            word: word, language: language, knownInTypingLanguage: known, knownInOtherLanguage: { knownElsewhere },
            checkBudget: keyboardMarkCheckBudget, isValid: dictionary.isValid
        )
    }

    @Test func unknownWordGetsTheOneSpellingTheDictionaryAccepts() {
        let dictionary: FakeDictionary = FakeDictionary(words: ["görüşmeler", "öğrencimiz", "çalışıyoruz", "düşündüm", "teşekkürlerimle"])
        let pairs: [(String, String)] = [
            ("gorusmeler", "görüşmeler"), ("ogrencimiz", "öğrencimiz"), ("calisiyoruz", "çalışıyoruz"), ("dusundum", "düşündüm"),
            ("tesekkurlerimle", "teşekkürlerimle"),
        ]
        for (typed, restored) in pairs {
            #expect(restorations(typed, dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == [restored])
        }
    }

    /// Apple's dictionary accepts "icin", "degil", "bugun": the frequent-word table restores them anyway, without asking.
    @Test func frequentWordIsRestoredEvenWhenItsPlainSpellingIsAccepted() {
        let dictionary: FakeDictionary = FakeDictionary(words: ["icin", "için", "degil", "değil"])
        #expect(restorations("icin", dictionary: dictionary, known: true, knownElsewhere: false, language: .turkish) == ["için"])
        #expect(restorations("degil", dictionary: dictionary, known: true, knownElsewhere: false, language: .turkish) == ["değil"])
        #expect(restorations("cok", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["çok"])
        #expect(restorations("tesekkurler", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["teşekkürler"])
        #expect(dictionary.checks == 0)
    }

    /// A plain spelling the dictionary knows is a word the user may mean ("isim", not "işim"): it stays, unasked.
    @Test func knownPlainWordStays() {
        let dictionary: FakeDictionary = FakeDictionary(words: ["isim", "işim", "oldu", "öldü"])
        #expect(restorations("isim", dictionary: dictionary, known: true, knownElsewhere: false, language: .turkish).isEmpty)
        #expect(restorations("oldu", dictionary: dictionary, known: true, knownElsewhere: false, language: .turkish).isEmpty)
        #expect(dictionary.checks == 0)
    }

    /// A bilingual user's English word stays ("once" is English, "önce" Turkish).
    @Test func wordAnotherLanguageKnowsStays() {
        let dictionary: FakeDictionary = FakeDictionary(words: ["önce", "görüşmeler"])
        #expect(restorations("once", dictionary: dictionary, known: false, knownElsewhere: true, language: .turkish).isEmpty)
        #expect(restorations("once", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["önce"])
        var asked: Int = 0
        let nothing: [String] = keyboardMarkRestorations(
            word: "xyz", language: .turkish, knownInTypingLanguage: false, knownInOtherLanguage: {
                asked += 1
                return false
            }, checkBudget: keyboardMarkCheckBudget, isValid: dictionary.isValid
        )
        #expect(nothing.isEmpty)
        // The other languages are asked only when there is something to restore.
        #expect(asked == 0)
    }

    /// Two equally likely spellings are both offered, neither applied.
    @Test func ambiguousWordOffersBothSpellings() {
        let dictionary: FakeDictionary = FakeDictionary(words: ["dış", "diş"])
        let found: [String] = restorations("dis", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish)
        #expect(Set(found) == ["dış", "diş"])
        let suggestions: KeyboardSuggestions = keyboardSuggestions(
            input: input("dis", known: false, guesses: ["dil"], rejected: [], allowed: true, personal: [], restorations: found)
        )
        #expect(suggestions.autocorrection == nil)
        #expect(Set(suggestions.items.map(\.text)) == ["dis", "dış", "diş"])
    }

    /// Apple's checker also takes a word with a mark left out or one too many: the spelling a mark away from all the
    /// others is the word, and of two a mark apart the one with the mark (only for longer words).
    @Test func leniencyOfTheCheckerIsSeenThrough() {
        let dictionary: FakeDictionary = FakeDictionary(words: [
            "çalısmalar", "calışmalar", "çalışmalar", "ögrenciler", "öğrenciler", "cocuğum", "çocuğum", "çoçuğum", "kası", "kaşı",
        ])
        #expect(restorations("calismalar", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["çalışmalar"])
        #expect(restorations("ogrenciler", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["öğrenciler"])
        #expect(restorations("cocugum", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["çocuğum"])
        // Short: two words, the one with more marks first.
        #expect(restorations("kasi", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["kaşı", "kası"])
    }

    /// A spelling that keeps vowel harmony wins over one that breaks it, even when the dictionary takes both.
    @Test func harmoniousSpellingWins() {
        let dictionary: FakeDictionary = FakeDictionary(words: ["düşünü", "duşunü"])
        #expect(restorations("dusunu", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["düşünü"])
    }

    @Test func keepsTheTypedCase() {
        let dictionary: FakeDictionary = FakeDictionary(words: ["görüşmeler"])
        #expect(restorations("Gorusmeler", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["Görüşmeler"])
        #expect(restorations("GORUSMELER", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["GÖRÜŞMELER"])
        #expect(restorations("İcin", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["İçin"])
        #expect(restorations("İCİN", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["İÇİN"])
        #expect(restorations("istanbul", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish) == ["İstanbul"])
    }

    /// A capitalised word inside a sentence is a name: "Mac" does not become "Maç". A capital the keyboard put there (a
    /// sentence start, a field that capitalises every word) says nothing, and a name the table knows gets its marks.
    @Test func capitalisedWordInsideASentenceKeepsItsLetters() {
        let dictionary: FakeDictionary = FakeDictionary(words: ["maç", "görüşme"])
        let mac: [String] = restorations("Mac", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish)
        #expect(mac == ["Maç"])
        func kept(_ restored: [String], _ typed: String, after context: String, _ capitalization: KeyboardAutocapitalization) -> [String] {
            keyboardMarkRestorationsKeepingNames(
                restorations: restored, typed: typed, contextBeforeWord: context, capitalization: capitalization, language: .turkish
            )
        }
        #expect(kept(mac, "Mac", after: "Yeni ", .sentences).isEmpty)
        #expect(kept(mac, "Mac", after: "Yeni ", .none).isEmpty)
        #expect(kept(mac, "Mac", after: "Bitti. ", .sentences) == ["Maç"])
        #expect(kept(mac, "Mac", after: "Bitti. ", .none) == ["Maç"])
        #expect(kept(["Görüşme"], "Gorusme", after: "Haftalik ", .words) == ["Görüşme"])
        #expect(kept(["maç"], "mac", after: "Yeni ", .sentences) == ["maç"])
        #expect(kept(["MAÇ"], "MAC", after: "Yeni ", .sentences) == ["MAÇ"])
        #expect(kept(["Türkiye"], "Turkiye", after: "Yeni ", .sentences) == ["Türkiye"])
        #expect(kept(["Şubat"], "Subat", after: "Toplantı 12 ", .sentences) == ["Şubat"])
        #expect(kept(["Perşembe"], "Persembe", after: "12 Şubat ", .sentences) == ["Perşembe"])
        #expect(kept(["Görüşme"], "Gorusme", after: "", .sentences) == ["Görüşme"])
    }

    @Test func leavesOtherLanguagesAndOddWordsAlone() {
        let dictionary: FakeDictionary = FakeDictionary(words: ["görüşme", "çok"])
        #expect(restorations("cok", dictionary: dictionary, known: false, knownElsewhere: false, language: .english).isEmpty)
        #expect(restorations("cok", dictionary: dictionary, known: false, knownElsewhere: false, language: .german).isEmpty)
        for word in ["gOrusme", "gorusme2", "c", "gorus'me"] {
            #expect(restorations(word, dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish).isEmpty)
        }
    }

    /// A word with many letters that could carry a mark costs at most the budget in dictionary checks.
    @Test func dictionaryChecksStayWithinTheBudget() {
        let dictionary: FakeDictionary = FakeDictionary(words: [])
        #expect(restorations("cicekcisisiniz", dictionary: dictionary, known: false, knownElsewhere: false, language: .turkish).isEmpty)
        #expect(dictionary.checks == keyboardMarkCheckBudget)
    }

    /// "ğ" only after a vowel, "-yor" keeps its "o", and the most harmonious spellings come first.
    @Test func candidatesFollowTurkishSpelling() {
        let gorusme: [KeyboardMarkCandidate] = turkishMarkCandidates(lowered: "gorusme", limit: 1000)
        #expect(!gorusme.contains { $0.word.hasPrefix("ğ") })
        #expect(gorusme.first?.penalty == 0)
        #expect(gorusme.filter { $0.penalty == 0 }.map(\.word).contains("görüşme"))
        #expect(!turkishMarkCandidates(lowered: "geliyor", limit: 1000).contains { $0.word.contains("ö") })
        #expect(turkishMarkCandidates(lowered: "kapi", limit: 1000).first?.word == "kapı")
        #expect(turkishMarkCandidates(lowered: "bed", limit: 1000).isEmpty)
        // 2^3 spellings (o, u, s; not the first g), the typed one left out; only as many are built as asked for.
        #expect(turkishMarkCandidates(lowered: "gorusme", limit: 1000).count == 7)
        #expect(turkishMarkCandidates(lowered: "gorusme", limit: 3).count == 3)
    }

    /// Every table entry is its word with the marks taken off, so it never turns one word into another.
    @Test func frequentWordTableIsConsistent() {
        #expect(turkishCalendarNames.allSatisfy { turkishFrequentRestorations[$0] != nil })
        let plain: [Character: Character] = ["ç": "c", "ğ": "g", "ı": "i", "ö": "o", "ş": "s", "ü": "u"]
        let turkish: Locale = Locale(identifier: "tr")
        for (typed, word) in turkishFrequentRestorations {
            let folded: String = String(word.lowercased(with: turkish).map { plain[$0] ?? $0 })
            #expect(folded == typed, "\(typed) → \(word)")
            #expect(typed.allSatisfy { $0.isASCII && $0.isLowercase })
        }
    }

    /// Through the suggestion bar: the restoration is the autocorrection, unless it was undone in this field, the word is
    /// a personal one, or autocorrection is off (then it is only offered).
    @Test func restorationGoesThroughTheAutocorrection() {
        let applied: KeyboardSuggestions = keyboardSuggestions(input: input("gorusme", known: false, guesses: ["gorusime"], rejected: [], allowed: true, personal: [], restorations: ["görüşme"]))
        #expect(applied.autocorrection == "görüşme")
        #expect(applied.items.prefix(2) == [KeyboardSuggestion(text: "gorusme", kind: .typed), KeyboardSuggestion(text: "görüşme", kind: .correction)])
        let known: KeyboardSuggestions = keyboardSuggestions(input: input("icin", known: true, guesses: [], rejected: [], allowed: true, personal: [], restorations: ["için"]))
        #expect(known.autocorrection == "için")
        let undone: KeyboardSuggestions = keyboardSuggestions(input: input("gorusme", known: false, guesses: [], rejected: ["gorusme"], allowed: true, personal: [], restorations: ["görüşme"]))
        #expect(undone.autocorrection == nil)
        let off: KeyboardSuggestions = keyboardSuggestions(input: input("gorusme", known: false, guesses: [], rejected: [], allowed: false, personal: [], restorations: ["görüşme"]))
        #expect(off.autocorrection == nil)
        #expect(off.items.contains(KeyboardSuggestion(text: "görüşme", kind: .correction)))
        let personal: KeyboardSuggestions = keyboardSuggestions(input: input("gorusme", known: false, guesses: [], rejected: [], allowed: true, personal: ["gorusme"], restorations: ["görüşme"]))
        #expect(personal.autocorrection == nil)
    }

    /// The lenient checker accepts "şöyleyeceğim" as well as "söyleyeceğim": the verb wins; the adverb's own forms stay.
    @Test func verbStemWinsOverTheAdverbTheCheckerAlsoAccepts() {
        let verb: FakeDictionary = FakeDictionary(words: ["söyleyeceğim", "şöyleyeceğim", "söyledim", "şöyledim"])
        #expect(restorations("soyleyecegim", dictionary: verb, known: false, knownElsewhere: false, language: .turkish) == ["söyleyeceğim"])
        #expect(turkishStemPreferred(accepted: ["söyledim", "şöyledim"]) == ["söyledim"])
        #expect(turkishStemPreferred(accepted: ["söylece", "şöylece"]) == ["söylece", "şöylece"])
        #expect(turkishStemPreferred(accepted: ["şöyledim"]) == ["şöyledim"])
    }

    private func input(
        _ typed: String, known: Bool, guesses: [String], rejected: Set<String>, allowed: Bool, personal: [String], restorations: [String]
    ) -> KeyboardSuggestionInput {
        KeyboardSuggestionInput(
            typed: typed, language: .turkish, isKnownWord: known, guesses: guesses, completions: [], personalWords: personal,
            shortcuts: [:], rejected: rejected, autocorrectAllowed: allowed, restorations: restorations
        )
    }
}

#if canImport(UIKit)
import UIKit

/// The real `UITextChecker` (iOS Simulator; `xcodebuild test` of the package). The Simulator's Turkish dictionary misses
/// basic words ("ev", "kitap") but has this one.
@Suite struct KeyboardMarksCheckerTests {
    @MainActor @Test func gorusmeGetsItsMarksFromTheRealDictionary() {
        guard let turkish = UITextChecker.availableLanguages.first(where: { $0.hasPrefix("tr") }) else {
            Issue.record("No Turkish spelling dictionary on this Simulator")
            return
        }
        let checker: UITextChecker = UITextChecker()
        func accepts(_ word: String) -> Bool {
            let range: NSRange = NSRange(location: 0, length: (word as NSString).length)
            return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: turkish).location == NSNotFound
        }
        #expect(!accepts("gorusme"))
        let candidates: [KeyboardMarkCandidate] = turkishMarkCandidates(lowered: "gorusme", limit: keyboardMarkCheckBudget)
        #expect(turkishDictionaryRestorations(typed: "gorusme", candidates: candidates, checkBudget: keyboardMarkCheckBudget, isValid: accepts) == ["görüşme"])
        let restored: [String] = keyboardMarkRestorations(
            word: "gorusmeler", language: .turkish, knownInTypingLanguage: accepts("gorusmeler"), knownInOtherLanguage: { false },
            checkBudget: keyboardMarkCheckBudget, isValid: accepts
        )
        #expect(restored == ["görüşmeler"])
    }
}
#endif
