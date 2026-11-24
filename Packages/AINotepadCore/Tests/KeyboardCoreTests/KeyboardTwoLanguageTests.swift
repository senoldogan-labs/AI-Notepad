import Foundation
import Testing
@testable import KeyboardCore

/// Two-language dictation: the merge of two transcribers over the same audio (word data measured on Apple's
/// `DictationTranscriber` for tr_TR and en_US, see `KeyboardTwoLanguageOnDeviceTests`).
@Suite struct KeyboardTwoLanguageTests {
    private func word(_ text: String, _ start: Double, _ end: Double, _ confidence: Double, phrase: Bool = false) -> KeyboardTimedWord {
        KeyboardTimedWord(text: text, start: start, end: end, confidence: confidence, startsPhrase: phrase)
    }

    private func merge(_ primary: [KeyboardTimedWord], _ secondary: [KeyboardTimedWord]) -> KeyboardMergedTranscript {
        keyboardMergeTwoLanguages(primary: primary, secondary: secondary, tuning: .standard)
    }

    // "Kardeşim, hele how are you? Hepsi daha iyi olması gerekiyor" spoken in Turkish and English.
    @Test func mixedSentenceTakesEachPartFromItsLanguage() {
        let turkish: [KeyboardTimedWord] = [
            word("Kardeşim ", 0, 0.81, 0.27, phrase: true), word("are you ", 1.41, 1.95, 0.02), word("hepsi ", 1.95, 2.40, 0.83),
            word("daha ", 2.40, 2.67, 0.85), word("iyi ", 2.67, 2.97, 0.83), word("olması ", 2.97, 3.45, 0.89), word("gerekiyor", 3.45, 4.56, 0.24),
        ]
        let english: [KeyboardTimedWord] = [
            word("Call ", 0, 0.36, 0.05, phrase: true), word("how ", 1.29, 1.53, 0.65), word("are ", 1.53, 1.62, 0.50), word("you", 1.62, 1.95, 0.25),
            word("? ", 2.40, 2.40, 0.25), word("How ", 2.40, 2.67, 0.16), word("you ", 2.67, 3.15, 0.12), word("must ", 3.15, 3.45, 0.23),
            word("get ", 3.45, 3.69, 0.55), word("a ", 3.69, 3.75, 0.35), word("key", 3.75, 4.02, 0.07),
        ]
        let merged: KeyboardMergedTranscript = merge(turkish, english)
        #expect(merged.text.hasPrefix("Kardeşim how are you"))
        #expect(merged.text.hasSuffix("daha iyi olması gerekiyor"))
        #expect(!merged.text.contains("Call"))
        #expect(!merged.text.contains("must get"))
        #expect(merged.dominant == .primary)
    }

    // The same audio read by one language that knows every word: the other's guesses never get in.
    @Test func monolingualSpeechStaysInItsLanguage() {
        let primary: [KeyboardTimedWord] = [
            word("Bu ", 0, 0.18, 0.21, phrase: true), word("proje ", 0.18, 0.54, 0.72), word("için ", 0.54, 1.05, 0.54), word("çok ", 1.2, 1.5, 0.74),
            word("önemli", 1.5, 2.1, 0.34),
        ]
        let secondary: [KeyboardTimedWord] = [word("Boo ", 0, 0.18, 0.08, phrase: true), word("pro jay ", 0.18, 1.05, 0.05), word("chalk ", 1.2, 1.5, 0.1), word("honey", 1.5, 2.1, 0.07)]
        let merged: KeyboardMergedTranscript = merge(primary, secondary)
        #expect(merged.text == "Bu proje için çok önemli")
        #expect(merged.dominant == .primary)
    }

    // A word the second language heard, as the majority of the speech, makes it the dominant (formatting) language.
    @Test func dominantLanguageIsTheOneWithMostSpokenTime() {
        let primary: [KeyboardTimedWord] = [word("Light ", 0, 0.3, 0.1, phrase: true), word("sketch ", 0.3, 0.9, 0.05), word("yarın ", 0.9, 1.3, 0.8)]
        let secondary: [KeyboardTimedWord] = [word("Let's ", 0, 0.3, 0.3, phrase: true), word("schedule ", 0.3, 0.9, 0.9), word("Sakuda", 0.9, 1.3, 0.14)]
        let merged: KeyboardMergedTranscript = merge(primary, secondary)
        #expect(merged.text == "Let's schedule yarın")
        #expect(merged.dominant == .secondary)
    }

    // One weak word between two strong ones of the other language does not flip the language (the switch has a cost).
    @Test func singleUnsureWordDoesNotSwitchLanguage() {
        let primary: [KeyboardTimedWord] = [
            word("Toplantıda ", 0, 0.6, 0.8, phrase: true), word("şimdi ", 0.6, 0.9, 0.5), word("başlıyoruz ", 0.9, 1.5, 0.8),
        ]
        let secondary: [KeyboardTimedWord] = [word("So ", 0, 0.6, 0.1, phrase: true), word("see ", 0.6, 0.9, 0.55), word("bus ", 0.9, 1.5, 0.1)]
        #expect(merge(primary, secondary).text == "Toplantıda şimdi başlıyoruz")
    }

    @Test func punctuationFollowsItsWordAndNothingIsLostWhenOneSideIsEmpty() {
        let english: [KeyboardTimedWord] = [word("How ", 0, 0.3, 0.7, phrase: true), word("are ", 0.3, 0.5, 0.7), word("you", 0.5, 0.9, 0.7), word("? ", 0.9, 0.9, 0.7)]
        #expect(merge([], english).text == "How are you?")
        #expect(merge(english, []).text == "How are you?")
        #expect(merge([], []).text == "")
    }

    // "Double" opens the second model's phrase, so it carries a sentence-start capital that the merged sentence lacks.
    @Test func phraseStartCapitalIsLoweredInTheMiddleOfASentence() {
        let primary: [KeyboardTimedWord] = [word("Bunu ", 0, 0.6, 0.9, phrase: true), word("gösterme ", 0.6, 1.2, 0.9), word("Double ", 1.2, 1.8, 0.01), word("check", 1.8, 2.4, 0.01)]
        let secondary: [KeyboardTimedWord] = [word("Bone ", 0, 0.6, 0.1, phrase: true), word("show ", 0.6, 1.2, 0.1), word("Double ", 1.2, 1.8, 0.7, phrase: true), word("check", 1.8, 2.4, 0.7)]
        #expect(merge(primary, secondary).text == "Bunu gösterme double check")
        let sentence: [KeyboardTimedWord] = [word("Hello. ", 0, 0.5, 0.9, phrase: true), word("Double ", 0.5, 1.0, 0.9, phrase: true), word("I ", 1.0, 1.2, 0.9)]
        #expect(merge(sentence, []).text == "Hello. Double I")
    }

    @Test func liveTailPrefersTheLanguageThatKnowsItsWords() {
        let turkish: Set<String> = ["kardeşim", "hepsi", "daha", "iyi"]
        let english: Set<String> = ["how", "are", "you", "call"]
        let isTurkish: (String) -> Bool? = { turkish.contains($0) }
        let isEnglish: (String) -> Bool? = { english.contains($0) }
        #expect(keyboardPreferredLiveSide(primary: "Kardeşim hepsi daha iyi", secondary: "Call how", primaryIsKnown: isTurkish, secondaryIsKnown: isEnglish) == .primary)
        #expect(keyboardPreferredLiveSide(primary: "Har are zu", secondary: "How are you", primaryIsKnown: isTurkish, secondaryIsKnown: isEnglish) == .secondary)
        #expect(keyboardPreferredLiveSide(primary: "Har are zu", secondary: "How are you", primaryIsKnown: { _ in nil }, secondaryIsKnown: isEnglish) == .primary)
        #expect(keyboardPreferredLiveSide(primary: "", secondary: "How", primaryIsKnown: isTurkish, secondaryIsKnown: isEnglish) == .primary)
    }

    @Test func secondLocaleIsTheFirstOtherKeyboardLanguageWithAModel() {
        let installed: [String] = ["en_US", "tr_TR", "fi_FI"]
        #expect(keyboardSecondDictationLocale(primaryLanguageCode: "tr", keyboardLanguageCodes: ["tr", "en"], installed: installed, regionCode: "TR") == "en_US")
        #expect(keyboardSecondDictationLocale(primaryLanguageCode: "en", keyboardLanguageCodes: ["en", "de", "tr"], installed: installed, regionCode: nil) == "tr_TR")
        #expect(keyboardSecondDictationLocale(primaryLanguageCode: "tr", keyboardLanguageCodes: ["tr"], installed: installed, regionCode: nil) == nil)
        #expect(keyboardSecondDictationLocale(primaryLanguageCode: "tr", keyboardLanguageCodes: ["tr", "de"], installed: installed, regionCode: nil) == nil)
    }

    @Test func twoLanguageNeedsTheSettingASecondModelAndMemory() {
        let enough: UInt64 = keyboardTwoLanguageHeadroomBytes
        #expect(keyboardTwoLanguageIsReady(enabled: true, secondLocale: "en_US", headroomBytes: enough))
        #expect(keyboardTwoLanguageIsReady(enabled: true, secondLocale: "en_US", headroomBytes: 0))
        #expect(!keyboardTwoLanguageIsReady(enabled: true, secondLocale: "en_US", headroomBytes: enough - 1))
        #expect(!keyboardTwoLanguageIsReady(enabled: false, secondLocale: "en_US", headroomBytes: enough))
        #expect(!keyboardTwoLanguageIsReady(enabled: true, secondLocale: nil, headroomBytes: enough))
    }

    @Test func translationSourceIsTheOtherLanguageWhenTheDominantOneIsTheTarget() {
        #expect(keyboardTwoLanguageTranslationSource(dominant: "tr", other: "en", target: "en") == "tr")
        #expect(keyboardTwoLanguageTranslationSource(dominant: "en", other: "tr", target: "en") == "tr")
        #expect(keyboardTwoLanguageTranslationSource(dominant: "en", other: "tr", target: "de") == "en")
        #expect(keyboardTwoLanguageTranslationSource(dominant: "en", other: nil, target: "en") == "en")
        #expect(keyboardTwoLanguageTranslationSource(dominant: "en", other: "tr", target: nil) == "en")
        #expect(keyboardTwoLanguageTranslationSource(dominant: "zh", other: "en", target: "zh-TW") == "en")
    }
}
