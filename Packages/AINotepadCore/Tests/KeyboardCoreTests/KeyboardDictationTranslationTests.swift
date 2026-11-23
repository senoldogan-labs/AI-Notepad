import Foundation
import Testing
@testable import KeyboardCore

/// Whether and from which language a finished dictation is translated, and how the translation is finished.
@Suite struct KeyboardDictationTranslationTests {
    @Test func translatesOnlyIntoAnotherWrittenLanguage() {
        #expect(keyboardTranslationPair(sourceLanguageCode: "tr", targetLanguageCode: "en") == KeyboardTranslationPair(sourceLanguageCode: "tr", targetLanguageCode: "en"))
        #expect(keyboardTranslationPair(sourceLanguageCode: "tr", targetLanguageCode: nil) == nil)
        #expect(keyboardTranslationPair(sourceLanguageCode: "en-US", targetLanguageCode: "en-GB") == nil)
        #expect(keyboardTranslationPair(sourceLanguageCode: "pt", targetLanguageCode: "pt-PT") == nil)
        #expect(keyboardTranslationPair(sourceLanguageCode: "zh", targetLanguageCode: "zh-TW") != nil)
        #expect(keyboardTranslationPair(sourceLanguageCode: "nb", targetLanguageCode: "nb-NO") == nil)
    }

    @Test func sourceIsTheVoiceLanguageOrTheDetectedKeyboardLanguage() {
        let languages: [KeyboardLanguage] = [.turkish, .finnish]
        #expect(keyboardDictationSourceLanguage(voiceLanguageCode: "ja", startedLanguageCode: "tr", detectedLanguageCode: "fi", keyboardLanguages: languages) == "ja")
        #expect(keyboardDictationSourceLanguage(voiceLanguageCode: nil, startedLanguageCode: "tr", detectedLanguageCode: "fi", keyboardLanguages: languages) == "fi")
        // Detection outside the keyboard's languages, or none (in-place dictation): the language the dictation started in.
        #expect(keyboardDictationSourceLanguage(voiceLanguageCode: nil, startedLanguageCode: "tr", detectedLanguageCode: "de", keyboardLanguages: languages) == "tr")
        #expect(keyboardDictationSourceLanguage(voiceLanguageCode: nil, startedLanguageCode: "tr", detectedLanguageCode: nil, keyboardLanguages: languages) == "tr")
    }

    @Test func translationKeepsTheResultOptions() {
        let options: KeyboardDictationOptions = KeyboardDictationOptions(
            spokenPunctuation: true, formatLists: true, cleanUp: true, endWithPeriod: false, lowercase: true
        )
        #expect(keyboardTranslatedDictation(text: " Hello, the meeting is at three. ", targetLanguageCode: "en", options: options) == "hello, the meeting is at three")
        #expect(keyboardTranslatedDictation(text: "Is it Friday?", targetLanguageCode: "en", options: options) == "is it friday?")
        #expect(keyboardTranslatedDictation(text: "Toplantı İzmir'de.", targetLanguageCode: "tr", options: options) == "toplantı izmir'de")
        #expect(keyboardTranslatedDictation(text: "Hello.", targetLanguageCode: "en", options: .standard) == "Hello.")
    }
}
