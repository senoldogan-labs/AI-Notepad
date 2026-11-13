import Testing
@testable import AINotepadCore

/// Spoken-language pick for keyboard dictation (pure functions; confidences measured on real speech).
@Suite struct KeyboardDictationLanguageTests {
    private func scores(_ pairs: [(String, Double)]) -> [DictationLanguageScore] {
        pairs.map { DictationLanguageScore(locale: $0.0, confidence: $0.1) }
    }

    @Test func clearWinnerReplacesThePreferredLocale() {
        let finnish: [DictationLanguageScore] = scores([("tr_TR", 0.09), ("fi_FI", 0.76), ("en_US", 0.21)])
        #expect(dictationLanguagePick(scores: finnish, preferred: "tr_TR") == "fi_FI")
    }

    @Test func preferredLocaleWinsTiesAndSilence() {
        #expect(dictationLanguagePick(scores: scores([("tr_TR", 0.91), ("en_US", 0.22)]), preferred: "tr_TR") == "tr_TR")
        #expect(dictationLanguagePick(scores: scores([("tr_TR", 0.5), ("en_US", 0.55)]), preferred: "tr_TR") == "tr_TR")
        #expect(dictationLanguagePick(scores: scores([("tr_TR", 0), ("en_US", 0)]), preferred: "tr_TR") == "tr_TR")
        #expect(dictationLanguagePick(scores: [], preferred: "tr_TR") == "tr_TR")
    }

    @Test func candidateCodesPutTheCommandLanguageFirstWithoutDuplicates() {
        #expect(dictationCandidateCodes(commandLanguageCode: "tr", layoutLanguageCodes: ["en", "tr", "fi", "nb"], limit: 3) == ["tr", "en", "fi"])
    }
}
