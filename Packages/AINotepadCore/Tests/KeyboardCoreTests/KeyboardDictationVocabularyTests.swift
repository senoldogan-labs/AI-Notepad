import Foundation
import Testing
@testable import KeyboardCore

/// The user's vocabulary spelled as listed, the space around unspaced scripts and the swipe choice after a delete.
@Suite struct KeyboardDictationVocabularyTests {
    private let common: Set<String> = ["it", "may", "schon", "state", "stacks", "hello", "this", "that"]

    private func apply(_ text: String, _ vocabulary: [String]) -> String {
        keyboardVocabularyApplied(text: text, vocabulary: vocabulary, isCommonWord: { common.contains($0) })
    }

    private func applyWithoutDictionary(_ text: String, _ vocabulary: [String]) -> String {
        keyboardVocabularyApplied(text: text, vocabulary: vocabulary, isCommonWord: { _ in nil })
    }

    @Test func singleWordsTakeTheListedSpelling() {
        #expect(apply("send it to acme, then gistsmith.", ["ACME", "Gistsmith"]) == "send it to ACME, then Gistsmith.")
        #expect(apply("(acme) and\nacme", ["ACME"]) == "(ACME) and\nACME")
    }

    @Test func ordinaryWordsKeepTheirCaseAndNoDictionaryMeansNoNearMiss() {
        #expect(apply("I think it works, may be", ["IT", "May"]) == "I think it works, may be")
        #expect(apply("It works", ["IT"]) == "It works")
        #expect(apply("ich bin schon da", ["Schön"]) == "ich bin schon da")
        #expect(applyWithoutDictionary("Stacy called", ["Stacey"]) == "Stacy called")
        #expect(applyWithoutDictionary("acme called", ["ACME"]) == "ACME called")
    }

    @Test func multiWordTermsMatchWordByWordAndJoined() {
        #expect(apply("ask senol dogan today", ["Şenol Doğan"]) == "ask Şenol Doğan today")
        #expect(apply("ask Senol, dogan", ["Şenol Doğan"]) == "ask Senol, dogan")
        #expect(apply("let's meet at a cafe", ["Ata"]) == "let's meet at a cafe")
        #expect(apply("I use open ai daily", ["OpenAI"]) == "I use OpenAI daily")
    }

    @Test func nearMissNamesAreOnlyFixedWhenTheHeardWordIsNotOrdinary() {
        #expect(apply("Stacy called", ["Stacey"]) == "Stacey called")
        #expect(apply("the state called", ["Stacey"]) == "the state called")
        #expect(apply("Stacks called", ["Stacey"]) == "Stacks called")
        #expect(apply("Tim called", ["Tom"]) == "Tim called")
        #expect(apply("Stacy called", ["Stacey", "Stacy2", "Stace"]) == "Stacy called")
    }

    @Test func japaneseAndChineseTakeNoSpace() {
        #expect(keyboardDictationInsertion(text: "今日は晴れです。", contextBefore: "こんにちは") == "今日は晴れです。")
        #expect(keyboardDictationInsertion(text: "你好", contextBefore: "hello") == "你好")
        #expect(keyboardDictationInsertion(text: "Tokyo", contextBefore: "東京") == "Tokyo")
        #expect(keyboardDictationInsertion(text: "。", contextBefore: "今日は晴れです") == "。")
        #expect(keyboardDictationInsertion(text: "ありがとう", contextBefore: "Thanks") == "ありがとう")
        #expect(keyboardDictationInsertion(text: "안녕하세요", contextBefore: "hello") == " 안녕하세요")
        #expect(keyboardDictationInsertion(text: "감사합니다", contextBefore: "안녕하세요") == " 감사합니다")
        #expect(keyboardDictationInsertion(text: "Hello", contextBefore: "Hi") == " Hello")
    }

    @Test func aRejectedSwipeWordGivesWayToTheNextMatch() {
        let matches: [SwipeMatch] = [SwipeMatch(word: "hello", score: 1), SwipeMatch(word: "help", score: 2), SwipeMatch(word: "held", score: 3)]
        #expect(swipeChoice(matches: matches, rejectedWords: []) == SwipeChoice(word: "hello", alternatives: ["help", "held"]))
        #expect(swipeChoice(matches: matches, rejectedWords: ["Hello"]) == SwipeChoice(word: "help", alternatives: ["hello", "held"]))
        #expect(swipeChoice(matches: matches, rejectedWords: ["held"]) == SwipeChoice(word: "hello", alternatives: ["help", "held"]))
        #expect(swipeChoice(matches: Array(matches.prefix(1)), rejectedWords: ["hello"]) == SwipeChoice(word: "hello", alternatives: []))
        #expect(swipeChoice(matches: [], rejectedWords: ["hello"]) == nil)
    }
}
