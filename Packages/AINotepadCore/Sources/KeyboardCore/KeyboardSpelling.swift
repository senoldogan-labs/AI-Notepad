import CoreGraphics
import Foundation

/// The spelling dictionary (`UITextChecker` language, e.g. "tr_TR") for `language` among the `available` ones; nil when
/// the iPhone has none for it. Norwegian Bokmål also takes a plain "no" dictionary. Pure function.
public func keyboardTextCheckerLanguage(for language: KeyboardLanguage, available: [String]) -> String? {
    let codes: [String] = language == .norwegian ? ["nb", "no"] : [language.rawValue]
    return available.first { (identifier: String) -> Bool in
        codes.contains(String(identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first ?? ""))
    }
}

/// What the spelling dictionaries said about one typed word. Apple's checker takes milliseconds per call, tens of them
/// for a guess (measured on the Simulator), so the keyboard asks once per word: the suggestion bar's pass after a pause
/// keeps the answer and the space bar's autocorrection reuses it when the word is still the same.
public struct KeyboardSpelling: Sendable, Hashable {
    public let word: String
    /// The typing language's dictionary, which the guesses come from; nil without one (nothing is corrected then).
    public let typingDictionary: String?
    /// The dictionaries of every selected language, which decide whether the word is known.
    public let dictionaries: [String]
    /// The word is spelled right in one of the selected languages (a bilingual user's English word is not corrected
    /// while typing Turkish).
    public let isKnownWord: Bool
    /// The typing dictionary's guesses, most likely first. Only looked up for a word no selected language knows:
    /// `keyboardSuggestions` uses guesses for nothing else.
    public let guesses: [String]

    public init(word: String, typingDictionary: String?, dictionaries: [String], isKnownWord: Bool, guesses: [String]) {
        self.word = word
        self.typingDictionary = typingDictionary
        self.dictionaries = dictionaries
        self.isKnownWord = isKnownWord
        self.guesses = guesses
    }

    /// Whether this answers `word` in these dictionaries.
    public func answers(word: String, typingDictionary: String?, dictionaries: [String]) -> Bool {
        self.word == word && self.typingDictionary == typingDictionary && self.dictionaries == dictionaries
    }
}

/// How far a key touch that iOS cancelled may have moved, and how long it may have lasted, to still count as a tap. iOS
/// cancels a touch near the screen's edges when it might start a system gesture (the Home indicator under the bottom
/// row); a real gesture travels further than this.
public let keyboardCancelledTapTravel: CGFloat = 8
public let keyboardCancelledTapDuration: TimeInterval = 0.35

/// Whether a key touch that iOS cancelled was a tap the user meant (it types, as on the system keyboard): it barely moved
/// and was short. Pure function.
public func keyboardCancelledTouchIsTap(travel: CGFloat, heldFor: TimeInterval) -> Bool {
    travel <= keyboardCancelledTapTravel && heldFor < keyboardCancelledTapDuration
}
