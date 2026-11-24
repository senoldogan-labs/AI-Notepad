import Foundation

/// One word (or punctuation mark) one speech model heard, with where it sits in the audio.
public struct KeyboardTimedWord: Sendable, Hashable {
    public let text: String
    /// Seconds from the start of the audio.
    public let start: Double
    public let end: Double
    /// The model's confidence, 0…1.
    public let confidence: Double
    /// The first word of a transcriber result (a phrase): the model capitalized it as a sentence start.
    public let startsPhrase: Bool

    public init(text: String, start: Double, end: Double, confidence: Double, startsPhrase: Bool) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.startsPhrase = startsPhrase
    }
}

/// Which of the two transcribers a merged word came from.
public enum KeyboardTranscriberSide: Sendable, Hashable {
    case primary
    case secondary
}

/// How the two transcripts are weighed against each other.
public struct KeyboardTwoLanguageTuning: Sendable, Hashable {
    /// Cost (confidence-seconds) of switching the language between two neighbouring words: keeps one-word flicker out.
    public let switchPenalty: Double
    /// Added to the primary language per second: the tie-break when both models are equally unsure.
    public let primaryBias: Double

    public init(switchPenalty: Double, primaryBias: Double) {
        self.switchPenalty = switchPenalty
        self.primaryBias = primaryBias
    }

    /// Measured on mixed Turkish/English speech (`KeyboardTwoLanguageOnDeviceTests`): 0.05 and 0.12 tie, 0.25 is worse;
    /// a dictionary signal on top of the confidence did not help.
    public static let standard: KeyboardTwoLanguageTuning = KeyboardTwoLanguageTuning(switchPenalty: 0.12, primaryBias: 0.02)
}

/// The merged transcript of two transcribers over the same audio.
public struct KeyboardMergedTranscript: Sendable, Hashable {
    public let text: String
    /// The language that carries most of the spoken time: the language the dictation formats in (spoken punctuation).
    public let dominant: KeyboardTranscriberSide
}

private struct MergeWord {
    let id: Int
    let word: KeyboardTimedWord
    let side: KeyboardTranscriberSide
    let isContent: Bool
    let score: Double
}

private let mergeEpsilon: Double = 0.001

/// Merges what two transcribers (the same audio, two languages) heard into one text, switching language where the
/// speaker did. The timeline is cut at every word boundary; for each slice the language whose word covers it scores
/// its confidence, and a two-state
/// Viterbi search picks the best language per slice with a cost for switching. A word is kept when its own language
/// holds most of its span; punctuation follows the word before it. Pure function.
public func keyboardMergeTwoLanguages(
    primary: [KeyboardTimedWord], secondary: [KeyboardTimedWord], tuning: KeyboardTwoLanguageTuning
) -> KeyboardMergedTranscript {
    let words: [MergeWord] = (mergeWords(primary, side: .primary) + mergeWords(secondary, side: .secondary)).enumerated().map {
        (index: Int, item: MergeWord) -> MergeWord in
        MergeWord(id: index, word: item.word, side: item.side, isContent: item.isContent, score: item.score)
    }
    let content: [MergeWord] = words.filter(\.isContent)
    guard !content.isEmpty else {
        return KeyboardMergedTranscript(text: "", dominant: .primary)
    }
    let bounds: [Double] = Array(Set(content.flatMap { [$0.word.start, $0.word.end] })).sorted()
    var slices: [(start: Double, end: Double)] = []
    for index in 1..<max(bounds.count, 1) where bounds[index] - bounds[index - 1] > mergeEpsilon {
        slices.append((bounds[index - 1], bounds[index]))
    }
    let sides: [KeyboardTranscriberSide] = viterbi(slices: slices, content: content, tuning: tuning)

    // Share of a word's span the language holds.
    let kept: (MergeWord) -> Bool = { (item: MergeWord) -> Bool in
        // No slices (every word has no length): the primary transcript alone.
        if slices.isEmpty {
            return item.side == .primary
        }
        let span: Double = item.word.end - item.word.start
        if span <= mergeEpsilon {
            let index: Int = slices.lastIndex { $0.start <= item.word.start + mergeEpsilon } ?? 0
            return sides[min(index, sides.count - 1)] == item.side
        }
        var held: Double = 0
        for (index, slice) in slices.enumerated() where sides[index] == item.side {
            held += max(0, min(slice.end, item.word.end) - max(slice.start, item.word.start))
        }
        return held >= span / 2
    }
    let spoken: [MergeWord] = content.filter(kept).sorted { (lhs: MergeWord, rhs: MergeWord) -> Bool in
        abs(lhs.word.start - rhs.word.start) > mergeEpsilon ? lhs.word.start < rhs.word.start : lhs.word.end < rhs.word.end
    }
    // A mark goes right after the word before it in its own transcript, wherever the other language's words fall.
    var marks: [Int: [MergeWord]] = [:]
    for side in [KeyboardTranscriberSide.primary, .secondary] {
        let own: [MergeWord] = words.filter { $0.side == side }
        for (index, item) in own.enumerated() where !item.isContent {
            if let before = own[..<index].last(where: { $0.isContent }), kept(before) {
                marks[before.id, default: []].append(item)
            }
        }
    }
    let included: [MergeWord] = spoken.flatMap { (item: MergeWord) -> [MergeWord] in [item] + (marks[item.id] ?? []) }
    let primarySeconds: Double = spoken.filter { $0.side == .primary }.reduce(0) { $0 + $1.word.end - $1.word.start }
    let secondarySeconds: Double = spoken.filter { $0.side == .secondary }.reduce(0) { $0 + $1.word.end - $1.word.start }
    return KeyboardMergedTranscript(text: joined(included.map(\.word)), dominant: secondarySeconds > primarySeconds ? .secondary : .primary)
}

private func mergeWords(_ words: [KeyboardTimedWord], side: KeyboardTranscriberSide) -> [MergeWord] {
    words.compactMap { (word: KeyboardTimedWord) -> MergeWord? in
        let trimmed: String = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let isContent: Bool = !trimmed.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).isEmpty
        let cleaned: KeyboardTimedWord = KeyboardTimedWord(
            text: trimmed, start: word.start, end: max(word.end, word.start), confidence: word.confidence, startsPhrase: word.startsPhrase
        )
        // A heard word always beats silence in the other language: the score is never below a small floor.
        return MergeWord(id: 0, word: cleaned, side: side, isContent: isContent, score: max(0, word.confidence) + 0.02)
    }
}

private func viterbi(slices: [(start: Double, end: Double)], content: [MergeWord], tuning: KeyboardTwoLanguageTuning) -> [KeyboardTranscriberSide] {
    guard !slices.isEmpty else {
        return []
    }
    let score: (Int, KeyboardTranscriberSide) -> Double = { (index: Int, side: KeyboardTranscriberSide) -> Double in
        let slice: (start: Double, end: Double) = slices[index]
        let middle: Double = (slice.start + slice.end) / 2
        let covering: Double = content.filter { $0.side == side && $0.word.start <= middle && middle < $0.word.end }.map(\.score).max() ?? 0
        return (slice.end - slice.start) * (covering + (side == .primary ? tuning.primaryBias : 0))
    }
    var best: [Double] = [score(0, .primary), score(0, .secondary)]
    var back: [[Int]] = []
    for index in 1..<slices.count {
        var next: [Double] = [0, 0]
        var from: [Int] = [0, 0]
        for state in 0..<2 {
            let stay: Double = best[state]
            let move: Double = best[1 - state] - tuning.switchPenalty
            from[state] = stay >= move ? state : 1 - state
            next[state] = max(stay, move) + score(index, state == 0 ? .primary : .secondary)
        }
        best = next
        back.append(from)
    }
    var state: Int = best[0] >= best[1] ? 0 : 1
    var path: [Int] = [state]
    for from in back.reversed() {
        state = from[state]
        path.append(state)
    }
    return path.reversed().map { $0 == 0 ? KeyboardTranscriberSide.primary : .secondary }
}

/// The words as one text: a space between words, none before punctuation; a word a model capitalized only because it
/// began its own phrase is lowercased where the merged sentence goes on. Pure function.
private func joined(_ words: [KeyboardTimedWord]) -> String {
    var text: String = ""
    for word in words {
        var piece: String = word.text
        let isPunctuation: Bool = piece.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).isEmpty
        let sentenceEnded: Bool = text.isEmpty || text.last.map { ".?!\n".contains($0) } == true
        if word.startsPhrase, !sentenceEnded, !isPunctuation, let first = piece.first, first.isUppercase, first != "İ",
           piece.dropFirst().first.map({ $0.isLowercase }) == true {
            piece = first.lowercased() + piece.dropFirst()
        }
        if !text.isEmpty, !isPunctuation {
            text += " "
        }
        text += piece
    }
    return text
}

/// While speaking, volatile results come as one text per model without word data, so they cannot be mixed: the text
/// shown is the model's whose language's dictionary knows more of its words (the other model forced foreign sounds into
/// words that are none). The secondary needs a clear lead; ties and no verdicts keep the primary. Pure function.
public func keyboardPreferredLiveSide(
    primary: String, secondary: String, primaryIsKnown: (String) -> Bool?, secondaryIsKnown: (String) -> Bool?
) -> KeyboardTranscriberSide {
    let ratio: (String, (String) -> Bool?) -> Double? = { (text: String, isKnown: (String) -> Bool?) -> Double? in
        let verdicts: [Bool] = text.split(whereSeparator: { $0.isWhitespace }).compactMap { (word: Substring) -> Bool? in
            let letters: String = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
            return letters.isEmpty ? nil : isKnown(letters)
        }
        return verdicts.isEmpty ? nil : Double(verdicts.filter { $0 }.count) / Double(verdicts.count)
    }
    guard let first = ratio(primary, primaryIsKnown), let second = ratio(secondary, secondaryIsKnown) else {
        return .primary
    }
    return second >= first + 0.2 ? .secondary : .primary
}

/// The second dictation language: the first of the user's other keyboard languages (in their order) that has an
/// installed dictation model, as the model's locale; nil when there is none. `primaryLanguageCode` is the voice
/// language. Pure function.
public func keyboardSecondDictationLocale(
    primaryLanguageCode: String, keyboardLanguageCodes: [String], installed: [String], regionCode: String?
) -> String? {
    let primary: String = primaryLanguageCode.lowercased()
    for code in keyboardLanguageCodes where code.lowercased() != primary {
        if let locale = keyboardDictationLocale(languageCode: code, installed: installed, regionCode: regionCode) {
            return locale
        }
    }
    return nil
}

/// Whether the keyboard may run a second transcriber: the user turned two-language dictation on and the extension has
/// the memory (`keyboardTwoLanguageHeadroomBytes`; 0 means iOS does not say, the Simulator). Pure function.
public func keyboardTwoLanguageIsReady(enabled: Bool, secondLocale: String?, headroomBytes: UInt64) -> Bool {
    enabled && secondLocale != nil && (headroomBytes == 0 || headroomBytes >= keyboardTwoLanguageHeadroomBytes)
}

/// Memory to keep free for the second transcriber on top of `keyboardInPlaceHeadroomBytes`: measured at under 1 MB of
/// the app's own footprint (the models run in the system's speech service), so a small margin for its result buffers.
public let keyboardTwoLanguageHeadroomBytes: UInt64 = keyboardInPlaceHeadroomBytes + 4 * 1_048_576
