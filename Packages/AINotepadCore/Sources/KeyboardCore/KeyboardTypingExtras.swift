import Foundation

/// Letter layouts, emoji suggestions and what the keyboard learns (Settings › Keyboard). Carried in the shared config
/// as one optional field so configs from apps before it still decode.
public struct KeyboardTypingExtras: Sendable, Hashable, Codable {
    /// The chosen layout per language (`KeyboardLanguage.rawValue`); a language without an entry uses its own layout.
    public let layouts: [String: KeyboardLetterLayout]
    /// An emoji for the word being typed shows in the suggestion bar.
    public let emojiSuggestions: Bool
    /// Off stops the keyboard from learning new words (the ones it has stay until deleted).
    public let learnsWords: Bool
    /// "Clear emoji history" was pressed at this time: the keyboard drops its recent emoji once per stamp.
    public let emojiHistoryClearedAt: Date?
    /// "Delete learned words" was pressed at this time: the keyboard drops what it learned once per stamp.
    public let learnedWordsClearedAt: Date?

    public init(
        layouts: [String: KeyboardLetterLayout], emojiSuggestions: Bool, learnsWords: Bool, emojiHistoryClearedAt: Date?,
        learnedWordsClearedAt: Date?
    ) {
        self.layouts = layouts
        self.emojiSuggestions = emojiSuggestions
        self.learnsWords = learnsWords
        self.emojiHistoryClearedAt = emojiHistoryClearedAt
        self.learnedWordsClearedAt = learnedWordsClearedAt
    }

    /// The defaults, also used for configs written before these options existed.
    public static let standard: KeyboardTypingExtras = KeyboardTypingExtras(
        layouts: [:], emojiSuggestions: true, learnsWords: true, emojiHistoryClearedAt: nil, learnedWordsClearedAt: nil
    )

    /// The language's chosen layout, or its own when none was chosen.
    public func layout(for language: KeyboardLanguage) -> KeyboardLetterLayout {
        layouts[language.rawValue] ?? keyboardNativeLayout(language: language)
    }
}

/// The words the keyboard learned (`learned-words.json`, keyboard → app, Full Access only), so the app can list and
/// count them. Never leaves the iPhone.
public struct KeyboardLearnedWords: Sendable, Hashable, Codable {
    public let words: [String]
    public let updatedAt: Date

    public init(words: [String], updatedAt: Date) {
        self.words = words
        self.updatedAt = updatedAt
    }
}

/// Whether a "clear" stamp from the app is newer than the last one the keyboard applied (a stamp is applied once, so
/// words learned after it are kept). Pure function.
public func keyboardResetIsPending(clearedAt: Date?, appliedAt: Date?) -> Bool {
    guard let clearedAt else {
        return false
    }
    guard let appliedAt else {
        return true
    }
    return clearedAt > appliedAt
}
