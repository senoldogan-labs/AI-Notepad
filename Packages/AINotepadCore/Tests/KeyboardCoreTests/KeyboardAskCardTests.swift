import Foundation
import Testing
@testable import KeyboardCore

/// The keyboard's answer card: the answer written out word by word, and taking an added answer back.
@Suite struct KeyboardAskCardTests {
    @Test func answerIsWrittenOutWordByWord() {
        let answer: String = "Pro stays at 14 dollars.\nTeam plan on Friday."
        #expect(keyboardAnswerReveal(answer: answer, elapsed: -1, wordsPerSecond: 10) == "")
        #expect(keyboardAnswerReveal(answer: answer, elapsed: 0, wordsPerSecond: 10) == "")
        #expect(keyboardAnswerReveal(answer: answer, elapsed: 0.1, wordsPerSecond: 10) == "Pro ")
        #expect(keyboardAnswerReveal(answer: answer, elapsed: 0.5, wordsPerSecond: 10) == "Pro stays at 14 dollars.\n")
        #expect(keyboardAnswerReveal(answer: answer, elapsed: 5, wordsPerSecond: 10) == answer)
    }

    @Test func addedAnswerCanBeTakenBackOnlyWhileItIsStillThere() {
        #expect(keyboardCanUndoInsertion(inserted: " Pro stays.", contextBefore: "Hi Ayşe, Pro stays."))
        // Typed after it, or nothing added.
        #expect(!keyboardCanUndoInsertion(inserted: " Pro stays.", contextBefore: "Hi Ayşe, Pro stays. ok"))
        #expect(!keyboardCanUndoInsertion(inserted: "", contextBefore: "Hi"))
        // Part of it already deleted by hand.
        #expect(!keyboardCanUndoInsertion(inserted: " Pro stays.", contextBefore: "stays."))
    }

    @Test func longAnswerIsCheckedByItsEndWhenIOSGivesOnlyPartOfTheText() {
        let inserted: String = String(repeating: "word ", count: 80) + "end."
        let visible: String = String(inserted.suffix(120))
        #expect(keyboardCanUndoInsertion(inserted: inserted, contextBefore: visible))
        #expect(!keyboardCanUndoInsertion(inserted: inserted, contextBefore: visible + "x"))
    }
}
