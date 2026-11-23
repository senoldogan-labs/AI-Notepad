import Foundation
import Testing

@testable import KeyboardCore

@Suite struct KeyboardLetterLayoutTests {
    /// Every language in every layout keeps all of its letters (accents included), once each, within its widest row.
    @Test func everyLayoutKeepsEveryLetterOfTheLanguage() {
        for language in KeyboardLanguage.allCases {
            let native: [Character] = keyboardLetterRows(language: language).joined().sorted()
            let limit: Int = keyboardLetterRows(language: language).prefix(2).map(\.count).max() ?? 0
            for layout in KeyboardLetterLayout.allCases {
                let rows: [String] = keyboardLetterRows(language: language, layout: layout)
                #expect(rows.joined().sorted() == native, "\(language) \(layout)")
                #expect(rows.prefix(2).allSatisfy { $0.count <= limit }, "\(language) \(layout)")
                #expect(rows[2].count <= limit - 3, "\(language) \(layout) third row leaves room for Shift and Delete")
            }
        }
    }

    @Test func nativeLayoutIsTheLanguagesOwn() {
        #expect(keyboardLetterRows(language: .turkish, layout: .qwerty) == ["qwertyuıopğü", "asdfghjklşi", "zxcvbnmöç"])
        #expect(keyboardLetterRows(language: .german, layout: .qwertz).first == "qwertzuiopü")
        #expect(keyboardLetterRows(language: .french, layout: .azerty).first == "azertyuiop")
    }

    @Test func chosenLayoutMovesOnlyTheBaseLetters() {
        #expect(keyboardLetterRows(language: .english, layout: .azerty) == ["azertyuiop", "qsdfghjklm", "wxcvbn"])
        #expect(keyboardLetterRows(language: .english, layout: .qwertz) == ["qwertzuiop", "asdfghjkl", "yxcvbnm"])
        // Turkish in QWERTZ: the six extra letters are still on the keys.
        let turkish: String = keyboardLetterRows(language: .turkish, layout: .qwertz).joined()
        for letter in "ğüşıöç" {
            #expect(turkish.contains(letter))
        }
    }

    @Test func alternatesFollowTheLayoutsTopRow() {
        #expect(keyboardAlternates(character: "a", language: .english, layout: .azerty).first == "1")
        #expect(keyboardAlternates(character: "q", language: .english, layout: .azerty).first != "1")
    }

    @Test func extrasDecodeWithoutNewFieldsAndPickTheNativeLayout() throws {
        let extras: KeyboardTypingExtras = KeyboardTypingExtras.standard
        #expect(extras.layout(for: .german) == .qwertz)
        let chosen: KeyboardTypingExtras = KeyboardTypingExtras(
            layouts: ["de": .qwerty], emojiSuggestions: true, learnsWords: true, emojiHistoryClearedAt: nil, learnedWordsClearedAt: nil
        )
        #expect(chosen.layout(for: .german) == .qwerty)
        #expect(chosen.layout(for: .french) == .azerty)
    }
}

@Suite struct KeyboardEmojiSuggestionTests {
    @Test func wordsMapToEmojiInEnglishAndTurkish() {
        #expect(keyboardEmojiSuggestion(word: "pizza", language: .english) == "🍕")
        #expect(keyboardEmojiSuggestion(word: "Love", language: .english) == "❤️")
        #expect(keyboardEmojiSuggestion(word: "AŞK", language: .turkish) == "❤️")
        #expect(keyboardEmojiSuggestion(word: "kahve", language: .turkish) == "☕")
        // English applies in every language; Turkish only in Turkish.
        #expect(keyboardEmojiSuggestion(word: "pizza", language: .turkish) == "🍕")
        #expect(keyboardEmojiSuggestion(word: "aşk", language: .english) == nil)
        #expect(keyboardEmojiSuggestion(word: "zzzzqq", language: .english) == nil)
    }

    @Test func emojiTakesTheLastSlotButKeepsAPendingCorrection() {
        let items: [KeyboardSuggestion] = [
            KeyboardSuggestion(text: "“pizzaa”", kind: .typed), KeyboardSuggestion(text: "pizza", kind: .correction),
            KeyboardSuggestion(text: "pizzas", kind: .completion),
        ]
        let pizzaFirst: KeyboardSuggestions = KeyboardSuggestions(items: items, autocorrection: "pizza")
        let shown: KeyboardSuggestions = keyboardSuggestionsAddingEmoji(pizzaFirst, emoji: "🍕")
        #expect(shown.items.map(\.text) == ["“pizzaa”", "pizza", "🍕"])
        #expect(shown.items.last?.kind == .emoji)
        let thirdIsCorrection: KeyboardSuggestions = KeyboardSuggestions(items: items, autocorrection: "pizzas")
        #expect(keyboardSuggestionsAddingEmoji(thirdIsCorrection, emoji: "🍕") == thirdIsCorrection)
    }
}

@Suite struct KeyboardResetStampTests {
    @Test func aStampAppliesOnceAndNewerStampsApplyAgain() {
        let first: Date = Date(timeIntervalSince1970: 1_000)
        let second: Date = Date(timeIntervalSince1970: 2_000)
        #expect(!keyboardResetIsPending(clearedAt: nil, appliedAt: nil))
        #expect(keyboardResetIsPending(clearedAt: first, appliedAt: nil))
        #expect(!keyboardResetIsPending(clearedAt: first, appliedAt: first))
        #expect(keyboardResetIsPending(clearedAt: second, appliedAt: first))
    }
}
