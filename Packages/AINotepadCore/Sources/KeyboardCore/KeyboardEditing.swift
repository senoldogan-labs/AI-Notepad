import CoreGraphics
import Foundation

// MARK: Space-bar cursor

/// How far a finger on the space bar must travel sideways before it moves the cursor instead of typing a space: a quick
/// tap that drifts a little still types the space.
public let keyboardSpaceCursorTravel: CGFloat = 20

/// How long a finger rests on the space bar before it turns into a trackpad (as on the system keyboard): from then on
/// any sideways movement moves the cursor, and lifting the finger types nothing.
public let keyboardSpaceCursorHold: TimeInterval = 0.45

/// Whether a touch on the space bar now moves the cursor: it was held long enough, or it travelled past the threshold.
/// Pure function.
public func keyboardSpaceStartsCursor(travel: CGFloat, heldFor: TimeInterval) -> Bool {
    abs(travel) >= keyboardSpaceCursorTravel || heldFor >= keyboardSpaceCursorHold
}

/// Where the cursor's travel is measured from once the space bar starts moving it at `x`: the point where the finger
/// crossed `keyboardSpaceCursorTravel` (so a single large move still moves the cursor by the travel beyond it), or the
/// finger's previous position when holding started it. Pure function.
public func keyboardSpaceCursorAnchor(startX: CGFloat, lastX: CGFloat, x: CGFloat) -> CGFloat {
    let travel: CGFloat = x - startX
    guard abs(travel) >= keyboardSpaceCursorTravel else {
        return lastX
    }
    return startX + (travel > 0 ? keyboardSpaceCursorTravel : -keyboardSpaceCursorTravel)
}

/// Points of finger travel per character the cursor moves at `speed` (points per second): fine control when slow, more
/// ground when fast (about 10 points per character at a crawl, 4 when flicking). Pure function.
public func keyboardCursorPointsPerCharacter(speed: CGFloat) -> CGFloat {
    let slow: CGFloat = 120
    let fast: CGFloat = 700
    let progress: CGFloat = min(max((abs(speed) - slow) / (fast - slow), 0), 1)
    return 10 - progress * 6
}

/// Whole characters the cursor moves for the finger's travel from `anchor` to `x`, and the new anchor (the remainder
/// carries over, so slow movements add up). Pure function.
public func keyboardCursorSteps(anchor: CGFloat, x: CGFloat, pointsPerCharacter: CGFloat) -> (steps: Int, anchor: CGFloat) {
    let steps: Int = Int((x - anchor) / pointsPerCharacter)
    return (steps, anchor + CGFloat(steps) * pointsPerCharacter)
}

/// The offset `UITextDocumentProxy.adjustTextPosition` takes (UTF-16 units) to move the cursor `characters` whole
/// characters (negative: left), so the cursor never lands inside an emoji or an accented letter. Movement beyond the
/// context the host handed over counts one unit per character. Pure function.
public func keyboardCursorOffset(characters: Int, contextBefore: String, contextAfter: String) -> Int {
    if characters < 0 {
        let known: Int = min(-characters, contextBefore.count)
        let units: Int = contextBefore.suffix(known).utf16.count
        return -(units + (-characters - known))
    }
    let known: Int = min(characters, contextAfter.count)
    let units: Int = contextAfter.prefix(known).utf16.count
    return units + (characters - known)
}

// MARK: Undoing an insertion

/// The text left of an insertion that is remembered with it: enough to tell this insertion from the same words elsewhere.
public let keyboardInsertionAnchorLength: Int = 20

/// Text the keyboard put into the field (a dictation, an answer) and the text that was left of it then.
public struct KeyboardInsertion: Sendable, Hashable {
    public let text: String
    /// Up to `keyboardInsertionAnchorLength` characters left of where the text went in (empty at the field's start).
    public let anchor: String

    public init(text: String, anchor: String) {
        self.text = text
        self.anchor = anchor
    }
}

/// The insertion `text` makes after `contextBefore` (the text left of the cursor before it went in). Pure function.
public func keyboardInsertion(text: String, contextBefore: String) -> KeyboardInsertion {
    KeyboardInsertion(text: text, anchor: String(contextBefore.suffix(keyboardInsertionAnchorLength)))
}

/// How the keyboard takes an insertion back out: move the cursor to the insertion's end, delete it character by
/// character, then move the cursor back to where the user left it. Offsets are UTF-16 units (as
/// `adjustTextPosition` takes them); `deleteCount` is in characters (one `deleteBackward` each).
public struct KeyboardUndoEdit: Sendable, Hashable {
    public let moveToEnd: Int
    public let deleteCount: Int
    public let moveBack: Int

    public init(moveToEnd: Int, deleteCount: Int, moveBack: Int) {
        self.moveToEnd = moveToEnd
        self.deleteCount = deleteCount
        self.moveBack = moveBack
    }
}

/// How to remove `insertion` from the field now, or nil when it cannot be found exactly. The text around the cursor is
/// searched for the inserted text where the remembered anchor still precedes it (the context can start inside the anchor);
/// of several, the one nearest the cursor. A long insertion that the context shows only in part (the context is shorter
/// than it) is removed only while the cursor is right after it (`keyboardCanUndoInsertion`). Nothing else is ever
/// deleted. Pure function.
public func keyboardUndoEdit(insertion: KeyboardInsertion, contextBefore: String, contextAfter: String) -> KeyboardUndoEdit? {
    let text: String = insertion.text
    guard !text.isEmpty else {
        return nil
    }
    let window: String = contextBefore + contextAfter
    let cursor: String.Index = window.utf16.index(window.startIndex, offsetBy: contextBefore.utf16.count)
    var best: (edit: KeyboardUndoEdit, distance: Int)?
    for range in window.ranges(of: text) where anchorPrecedes(anchor: insertion.anchor, preceding: window[..<range.lowerBound]) {
        let edit: KeyboardUndoEdit
        let distance: Int
        if range.upperBound <= cursor {
            let between: Int = window[range.upperBound ..< cursor].utf16.count
            edit = KeyboardUndoEdit(moveToEnd: -between, deleteCount: text.count, moveBack: between)
            distance = between
        } else if range.lowerBound >= cursor {
            let toEnd: Int = window[cursor ..< range.upperBound].utf16.count
            let toStart: Int = window[cursor ..< range.lowerBound].utf16.count
            edit = KeyboardUndoEdit(moveToEnd: toEnd, deleteCount: text.count, moveBack: -toStart)
            distance = toStart
        } else {
            // The cursor is inside the insertion: it ends up where the insertion was.
            edit = KeyboardUndoEdit(moveToEnd: window[cursor ..< range.upperBound].utf16.count, deleteCount: text.count, moveBack: 0)
            distance = 0
        }
        if distance < best?.distance ?? Int.max {
            best = (edit, distance)
        }
    }
    if let best {
        return best.edit
    }
    if contextBefore.count < text.count, keyboardCanUndoInsertion(inserted: text, contextBefore: contextBefore) {
        return KeyboardUndoEdit(moveToEnd: 0, deleteCount: text.count, moveBack: 0)
    }
    return nil
}

/// Whether the text left of a match is consistent with the remembered anchor: it ends with it, or (the host's context
/// starts inside the anchor) the anchor ends with all of it. An empty anchor matches anywhere.
private func anchorPrecedes(anchor: String, preceding: Substring) -> Bool {
    if preceding.count >= anchor.count {
        return preceding.hasSuffix(anchor)
    }
    return anchor.hasSuffix(preceding)
}

// MARK: Pasting a dictation that did not go in

/// How long the keyboard offers "Paste dictation" for a finished dictation that never went into a field.
public let keyboardPasteDictationWindow: TimeInterval = 300

/// How long "Dictation added · Undo" stays on the keyboard after a dictation went in.
public let keyboardDictationUndoWindow: TimeInterval = 30

/// A finished dictation the keyboard saw (kept in memory only, never on disk).
public struct KeyboardHeardDictation: Sendable, Hashable {
    public let requestID: UUID
    public let text: String
    public let heardAt: Date

    public init(requestID: UUID, text: String, heardAt: Date) {
        self.requestID = requestID
        self.text = text
        self.heardAt = heardAt
    }
}

/// The dictation text "Paste dictation" offers: the last finished dictation when it was not put into a field (the
/// result expired, Gistsmith closed, the field changed, the user closed the panel) and is at most
/// `keyboardPasteDictationWindow` old; nil otherwise. Pure function.
public func keyboardPastableDictation(heard: KeyboardHeardDictation?, insertedRequestID: UUID?, now: Date) -> String? {
    guard let heard, heard.requestID != insertedRequestID, !heard.text.isEmpty else {
        return nil
    }
    let age: TimeInterval = now.timeIntervalSince(heard.heardAt)
    return age >= 0 && age <= keyboardPasteDictationWindow ? heard.text : nil
}

// MARK: Casing in the middle of a sentence

/// The dictation as it goes in after `contextBefore`: in the middle of a sentence its first word is lowercased when the
/// recogniser only capitalised it for starting an utterance (`isCommonWord` says the lowercase word is an ordinary
/// dictionary word, not a name or a vocabulary term). "I" and its contractions, words with capitals inside ("iPhone")
/// and all-caps words keep their case; at a sentence start (by the field's `rule`) nothing changes. Pure function.
public func keyboardDictationCased(
    text: String, contextBefore: String, rule: KeyboardAutocapitalization, locale: Locale, isCommonWord: (String) -> Bool
) -> String {
    let leading: String = keyboardDictationSpace(leadingSpace: keyboardDictationLeadingSpace(contextBefore: contextBefore), text: text)
    guard !keyboardShouldCapitalize(contextBefore: contextBefore + leading, rule: rule) else {
        return text
    }
    guard let start = text.firstIndex(where: { !$0.isWhitespace }), !text[..<start].contains(where: { $0.isNewline }), text[start].isLetter,
          text[start].isUppercase
    else {
        return text
    }
    let end: String.Index = text[start...].firstIndex { !$0.isLetter && $0 != "'" && $0 != "’" } ?? text.endIndex
    let word: Substring = text[start ..< end]
    // Only a plain word: what follows it up to the next space is closing punctuation at most, so initialisms ("U.S."),
    // codes ("A4") and joined forms ("E-mail") keep their case; a lone letter before a period is an initial ("A. Smith").
    let tokenEnd: String.Index = text[end...].firstIndex { $0.isWhitespace } ?? text.endIndex
    let trailing: Substring = text[end ..< tokenEnd]
    guard trailing.allSatisfy({ ",;:!?)\"”’".contains($0) }) || (trailing == "." && word.count > 1) else {
        return text
    }
    // A capital anywhere after the first letter, also after an apostrophe ("O'Brien"), marks a name or a brand spelling.
    let rest: Substring = word.dropFirst()
    guard word.prefix(while: { $0.isLetter }) != "I", rest == rest.lowercased(with: locale) else {
        return text
    }
    guard isCommonWord(word.lowercased(with: locale)) else {
        return text
    }
    return String(text[..<start]) + String(text[start]).lowercased(with: locale) + String(word.dropFirst()) + String(text[end...])
}

/// The spelling to learn for a word the user kept: a word capitalised only because it started a sentence (`startsSentence`)
/// is learned in lowercase, so it is not capitalised later in the middle of a sentence. Pure function.
public func keyboardLearnedSpelling(word: String, startsSentence: Bool, language: KeyboardLanguage) -> String {
    guard startsSentence, let first = word.first, first.isUppercase else {
        return word
    }
    let tail: Substring = word.dropFirst()
    guard !tail.isEmpty, tail == tail.lowercased(with: language.casingLocale) else {
        return word
    }
    return String(first).lowercased(with: language.casingLocale) + tail
}
