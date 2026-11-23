import Foundation
import Testing
@testable import KeyboardCore

/// The spelling lookups the keyboard keeps per word, and the facts that let it skip checker calls: the space bar's
/// autocorrection needs no completions, and a known word needs no guesses.
@Suite struct KeyboardSpellingTests {
    @Test func dictionaryMatchesTheLanguageCode() {
        let available: [String] = ["en", "en_GB", "tr_TR", "no", "de_DE"]
        #expect(keyboardTextCheckerLanguage(for: .english, available: available) == "en")
        #expect(keyboardTextCheckerLanguage(for: .turkish, available: available) == "tr_TR")
        #expect(keyboardTextCheckerLanguage(for: .norwegian, available: available) == "no")
        #expect(keyboardTextCheckerLanguage(for: .norwegian, available: ["nb-NO"]) == "nb-NO")
        #expect(keyboardTextCheckerLanguage(for: .finnish, available: available) == nil)
    }

    @Test func spellingAnswersOnlyTheSameWordInTheSameDictionaries() {
        let spelling: KeyboardSpelling = KeyboardSpelling(
            word: "tset", typingDictionary: "en", dictionaries: ["en", "tr_TR"], isKnownWord: false, guesses: ["test"]
        )
        #expect(spelling.answers(word: "tset", typingDictionary: "en", dictionaries: ["en", "tr_TR"]))
        #expect(!spelling.answers(word: "tse", typingDictionary: "en", dictionaries: ["en", "tr_TR"]))
        #expect(!spelling.answers(word: "Tset", typingDictionary: "en", dictionaries: ["en", "tr_TR"]))
        #expect(!spelling.answers(word: "tset", typingDictionary: "tr_TR", dictionaries: ["tr_TR", "en"]))
        #expect(!spelling.answers(word: "tset", typingDictionary: "en", dictionaries: ["en"]))
    }

    /// The space bar asks the checker only for what autocorrection uses.
    @Test func autocorrectionDoesNotDependOnCompletions() {
        for (typed, known, guesses): (String, Bool, [String]) in [("tset", false, ["test", "set"]), ("dont", false, []), ("omw", false, []), ("hello", true, [])] {
            let withCompletions: KeyboardSuggestions = keyboardSuggestions(input: input(typed: typed, known: known, guesses: guesses, completions: ["testing", "tsetse"]))
            let without: KeyboardSuggestions = keyboardSuggestions(input: input(typed: typed, known: known, guesses: guesses, completions: []))
            #expect(withCompletions.autocorrection == without.autocorrection)
        }
        #expect(keyboardSuggestions(input: input(typed: "tset", known: false, guesses: ["test"], completions: [])).autocorrection == "test")
    }

    /// A word a selected language knows is never corrected from guesses, so the checker is not asked for them.
    @Test func knownWordIgnoresGuesses() {
        let withGuesses: KeyboardSuggestions = keyboardSuggestions(input: input(typed: "form", known: true, guesses: ["from", "firm"], completions: ["format"]))
        let without: KeyboardSuggestions = keyboardSuggestions(input: input(typed: "form", known: true, guesses: [], completions: ["format"]))
        #expect(withGuesses == without)
    }

    @Test func cancelledTouchTypesOnlyWhenItWasATap() {
        #expect(keyboardCancelledTouchIsTap(travel: 0, heldFor: 0.08))
        #expect(keyboardCancelledTouchIsTap(travel: 6, heldFor: 0.2))
        // A swipe up from the bottom row (the Home gesture) or a held key is not a tap.
        #expect(!keyboardCancelledTouchIsTap(travel: 30, heldFor: 0.1))
        #expect(!keyboardCancelledTouchIsTap(travel: 2, heldFor: 0.5))
    }

    private func input(typed: String, known: Bool, guesses: [String], completions: [String]) -> KeyboardSuggestionInput {
        KeyboardSuggestionInput(
            typed: typed, language: .english, isKnownWord: known, guesses: guesses, completions: completions, personalWords: ["Gistsmith"],
            shortcuts: ["omw": "On my way!"], rejected: [], autocorrectAllowed: true
        )
    }
}
