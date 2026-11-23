import Foundation

/// How fast the keyboard's answer card writes the answer out, in words per second.
public let keyboardAnswerRevealWordsPerSecond: Double = 28

/// How long "Added · Undo" stays on the keyboard after an answer was added.
public let keyboardAnswerUndoWindow: TimeInterval = 8

/// The answer as the keyboard's answer card shows it `elapsed` seconds after it arrived: word by word at
/// `wordsPerSecond`, whole once every word is out (and before it arrived, nothing). Pure function.
public func keyboardAnswerReveal(answer: String, elapsed: TimeInterval, wordsPerSecond: Double) -> String {
    guard elapsed >= 0 else {
        return ""
    }
    let shownWords: Double = elapsed * wordsPerSecond
    var words: Int = 0
    var isInWord: Bool = false
    for index in answer.indices {
        let isSpace: Bool = answer[index].isWhitespace
        if !isSpace, !isInWord {
            words += 1
            if Double(words) > shownWords {
                return String(answer[..<index])
            }
        }
        isInWord = !isSpace
    }
    return answer
}

/// Whether the answer just added can be taken back with one delete per character of `inserted`: the text before the
/// cursor still ends with it. iOS hands a keyboard only part of a long text before the cursor; when that part is shorter
/// than what was added, it must be the end of it (at least 20 characters, or all of a shorter answer). Pure function.
public func keyboardCanUndoInsertion(inserted: String, contextBefore: String) -> Bool {
    guard !inserted.isEmpty else {
        return false
    }
    if contextBefore.count >= inserted.count {
        return contextBefore.hasSuffix(inserted)
    }
    return contextBefore.count >= min(20, inserted.count) && inserted.hasSuffix(contextBefore)
}

/// The App Group file that turns the keyboard's sample answers on (`--klavye-sor-ornek`, Debug builds only).
public let keyboardAskDemoFileName: String = "ask-demo"
