import Foundation
import Testing
@testable import KeyboardCore

/// Space-bar cursor, undoing an insertion wherever the cursor went, "Paste dictation" and mid-sentence casing.
@Suite struct KeyboardEditingTests {
    @Test func aSloppyTapOnSpaceStillTypesASpace() {
        #expect(!keyboardSpaceStartsCursor(travel: 14, heldFor: 0.12))
        #expect(!keyboardSpaceStartsCursor(travel: -19, heldFor: 0.3))
        #expect(keyboardSpaceStartsCursor(travel: 20, heldFor: 0.1))
        #expect(keyboardSpaceStartsCursor(travel: -24, heldFor: 0.1))
        // Held still: the space bar becomes a trackpad.
        #expect(keyboardSpaceStartsCursor(travel: 0, heldFor: 0.45))
        // Travel beyond the threshold in the same move still counts; a hold measures from the finger.
        #expect(keyboardSpaceCursorAnchor(startX: 200, lastX: 200, x: 168) == 180)
        #expect(keyboardSpaceCursorAnchor(startX: 200, lastX: 205, x: 226) == 220)
        #expect(keyboardSpaceCursorAnchor(startX: 200, lastX: 204, x: 206) == 204)
    }

    @Test func cursorMovesFinerWhenSlowAndCarriesTheRemainder() {
        #expect(keyboardCursorPointsPerCharacter(speed: 50) == 10)
        #expect(keyboardCursorPointsPerCharacter(speed: -2000) == 4)
        let first: (steps: Int, anchor: CGFloat) = keyboardCursorSteps(anchor: 100, x: 125, pointsPerCharacter: 10)
        #expect(first.steps == 2 && first.anchor == 120)
        let second: (steps: Int, anchor: CGFloat) = keyboardCursorSteps(anchor: first.anchor, x: 129, pointsPerCharacter: 10)
        #expect(second.steps == 0 && second.anchor == 120)
        let back: (steps: Int, anchor: CGFloat) = keyboardCursorSteps(anchor: 120, x: 95, pointsPerCharacter: 10)
        #expect(back.steps == -2 && back.anchor == 100)
    }

    @Test func cursorSkipsWholeEmoji() {
        #expect(keyboardCursorOffset(characters: -1, contextBefore: "hi 👍🏽", contextAfter: "") == -4)
        #expect(keyboardCursorOffset(characters: 2, contextBefore: "", contextAfter: "é!x") == 2)
        // Past the context the host handed over: one unit per character.
        #expect(keyboardCursorOffset(characters: -3, contextBefore: "a", contextAfter: "") == -3)
    }

    @Test func undoRemovesTheInsertionRightBeforeTheCursor() {
        let insertion: KeyboardInsertion = keyboardInsertion(text: " see you at five", contextBefore: "Thanks")
        #expect(insertion.anchor == "Thanks")
        let edit: KeyboardUndoEdit? = keyboardUndoEdit(insertion: insertion, contextBefore: "Thanks see you at five", contextAfter: "")
        #expect(edit == KeyboardUndoEdit(moveToEnd: 0, deleteCount: 16, moveBack: 0))
    }

    @Test func undoFindsTheInsertionAfterTheCursorMoved() {
        let insertion: KeyboardInsertion = keyboardInsertion(text: " see you", contextBefore: "Thanks")
        // The cursor went back to after "Than".
        let left: KeyboardUndoEdit? = keyboardUndoEdit(insertion: insertion, contextBefore: "Than", contextAfter: "ks see you. Bye")
        #expect(left == KeyboardUndoEdit(moveToEnd: 10, deleteCount: 8, moveBack: -2))
        // The cursor went to the end, past text that was already there.
        let right: KeyboardUndoEdit? = keyboardUndoEdit(insertion: insertion, contextBefore: "Thanks see you. Bye", contextAfter: "")
        #expect(right == KeyboardUndoEdit(moveToEnd: -5, deleteCount: 8, moveBack: 5))
        // The cursor is inside the insertion.
        let inside: KeyboardUndoEdit? = keyboardUndoEdit(insertion: insertion, contextBefore: "Thanks se", contextAfter: "e you")
        #expect(inside == KeyboardUndoEdit(moveToEnd: 5, deleteCount: 8, moveBack: 0))
    }

    @Test func undoNeverDeletesOtherText() {
        let insertion: KeyboardInsertion = keyboardInsertion(text: " see you", contextBefore: "Thanks")
        // The same words elsewhere, without the anchor before them.
        #expect(keyboardUndoEdit(insertion: insertion, contextBefore: "Ok see you", contextAfter: "") == nil)
        // The user edited the inserted words.
        #expect(keyboardUndoEdit(insertion: insertion, contextBefore: "Thanks see ya", contextAfter: "") == nil)
        #expect(keyboardUndoEdit(insertion: keyboardInsertion(text: "", contextBefore: "a"), contextBefore: "a", contextAfter: "") == nil)
    }

    @Test func undoPicksTheOccurrenceNearestTheCursor() {
        let insertion: KeyboardInsertion = keyboardInsertion(text: " ok", contextBefore: "")
        let edit: KeyboardUndoEdit? = keyboardUndoEdit(insertion: insertion, contextBefore: "a ok b ok", contextAfter: " c")
        #expect(edit == KeyboardUndoEdit(moveToEnd: 0, deleteCount: 3, moveBack: 0))
    }

    @Test func undoWorksWhenTheContextStartsInsideTheAnchor() {
        let insertion: KeyboardInsertion = keyboardInsertion(text: " done", contextBefore: "The whole long sentence before it")
        // The host hands over only the end of the anchor.
        let edit: KeyboardUndoEdit? = keyboardUndoEdit(insertion: insertion, contextBefore: "before it done", contextAfter: "")
        #expect(edit == KeyboardUndoEdit(moveToEnd: 0, deleteCount: 5, moveBack: 0))
    }

    @Test func pasteIsOfferedOnlyForAFreshDictationThatDidNotGoIn() {
        let id: UUID = UUID()
        let heard: KeyboardHeardDictation = KeyboardHeardDictation(requestID: id, text: "Call me later", heardAt: Date(timeIntervalSince1970: 1000))
        #expect(keyboardPastableDictation(heard: heard, insertedRequestID: nil, now: Date(timeIntervalSince1970: 1010)) == "Call me later")
        #expect(keyboardPastableDictation(heard: heard, insertedRequestID: id, now: Date(timeIntervalSince1970: 1010)) == nil)
        #expect(keyboardPastableDictation(heard: heard, insertedRequestID: UUID(), now: Date(timeIntervalSince1970: 1301)) == nil)
        #expect(keyboardPastableDictation(heard: nil, insertedRequestID: nil, now: Date()) == nil)
    }

    @Test func dictationMidSentenceStartsLowercase() {
        let english: Locale = Locale(identifier: "en")
        let common: (String) -> Bool = { ["see", "the"].contains($0) }
        #expect(keyboardDictationCased(text: "See you there.", contextBefore: "I will", rule: .sentences, locale: english, isCommonWord: common) == "see you there.")
        #expect(keyboardDictationCased(text: "See you", contextBefore: "Ok, ", rule: .sentences, locale: english, isCommonWord: common) == "see you")
        // Sentence start, a name, "I", a brand spelling and an all-caps word keep their case.
        #expect(keyboardDictationCased(text: "See you", contextBefore: "Done.", rule: .sentences, locale: english, isCommonWord: common) == "See you")
        #expect(keyboardDictationCased(text: "See you", contextBefore: "", rule: .sentences, locale: english, isCommonWord: common) == "See you")
        #expect(keyboardDictationCased(text: "Paris it is", contextBefore: "to", rule: .sentences, locale: english, isCommonWord: common) == "Paris it is")
        #expect(keyboardDictationCased(text: "I'm late", contextBefore: "so", rule: .sentences, locale: english, isCommonWord: { _ in true }) == "I'm late")
        #expect(keyboardDictationCased(text: "THE end", contextBefore: "so", rule: .sentences, locale: english, isCommonWord: common) == "THE end")
        #expect(keyboardDictationCased(text: "See you", contextBefore: "so", rule: .words, locale: english, isCommonWord: common) == "See you")
        // A dictation opening with a line break starts a new line: left alone.
        #expect(keyboardDictationCased(text: "\nSee you", contextBefore: "so", rule: .sentences, locale: english, isCommonWord: common) == "\nSee you")
        // Turkish casing.
        let turkish: Locale = Locale(identifier: "tr")
        #expect(keyboardDictationCased(text: "İyi akşamlar", contextBefore: "herkese", rule: .sentences, locale: turkish, isCommonWord: { _ in true }) == "iyi akşamlar")
    }

    @Test func wordsCapitalisedForASentenceStartAreLearnedLowercase() {
        #expect(keyboardLearnedSpelling(word: "Will", startsSentence: true, language: .english) == "will")
        #expect(keyboardLearnedSpelling(word: "Will", startsSentence: false, language: .english) == "Will")
        #expect(keyboardLearnedSpelling(word: "iPhone", startsSentence: true, language: .english) == "iPhone")
        #expect(keyboardLearnedSpelling(word: "NASA", startsSentence: true, language: .english) == "NASA")
        #expect(keyboardLearnedSpelling(word: "Işık", startsSentence: true, language: .turkish) == "ışık")
    }
}

/// The keyboard fits the height iOS gives it: the bar shrinks, row gaps and labels get smaller instead of keys clipping.
@Suite struct KeyboardFitTests {
    @Test func barKeepsItsHeightWithEnoughRoom() {
        #expect(keyboardTopBarHeight(available: 0, preferredKeyboard: 266, preferredBar: 50) == 50)
        #expect(keyboardTopBarHeight(available: 266, preferredKeyboard: 266, preferredBar: 50) == 50)
        #expect(keyboardTopBarHeight(available: 213, preferredKeyboard: 266, preferredBar: 50) == 40)
        #expect(keyboardTopBarHeight(available: 120, preferredKeyboard: 266, preferredBar: 50) == 40)
    }

    @Test func shortRowsGetSmallerGapsAndLabels() {
        // Portrait (216 pt for four rows) and landscape (162 pt) keep their gaps and full-size labels.
        #expect(keyboardRowGap(rowPitch: 53, preferred: 11) == 11)
        #expect(keyboardRowGap(rowPitch: 39.5, preferred: 7) == 7)
        #expect(keyboardKeyLabelScale(keyHeight: 42) == 1)
        #expect(keyboardKeyLabelScale(keyHeight: 32.5) == 1)
        // Squeezed to 30 pt per row.
        #expect(keyboardRowGap(rowPitch: 30, preferred: 11) == 6)
        #expect(keyboardKeyLabelScale(keyHeight: 24) == 0.8)
        #expect(keyboardKeyLabelScale(keyHeight: 10) == 0.6)
    }
}
