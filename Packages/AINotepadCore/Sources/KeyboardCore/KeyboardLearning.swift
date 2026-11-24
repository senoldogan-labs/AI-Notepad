import Foundation

/// The words the keyboard learned, kept per language (Settings › Keyboard, "Learn each language separately"). Words
/// learned before languages were kept apart, or while the choice was off, stay in `shared`: their language is unknown, so
/// they apply to every language and nothing is lost when the choice changes.
public struct KeyboardLearnedStore: Sendable, Hashable, Codable {
    public let shared: [String]
    /// Words per language (`KeyboardLanguage.rawValue`).
    public let byLanguage: [String: [String]]

    public init(shared: [String], byLanguage: [String: [String]]) {
        self.shared = shared
        self.byLanguage = byLanguage
    }

    public static let empty: KeyboardLearnedStore = KeyboardLearnedStore(shared: [], byLanguage: [:])
}

/// The store a list learned before this existed becomes: all of it shared. Pure function.
public func keyboardLearnedStoreMigrating(legacyWords: [String]) -> KeyboardLearnedStore {
    KeyboardLearnedStore(shared: legacyWords, byLanguage: [:])
}

/// The words that apply while typing `language`: the shared ones plus that language's own when languages are kept apart,
/// otherwise every word. Pure function.
public func keyboardLearnedWords(in store: KeyboardLearnedStore, language: KeyboardLanguage, perLanguage: Bool) -> [String] {
    if perLanguage {
        return keyboardDistinct(store.shared + (store.byLanguage[language.rawValue] ?? []))
    }
    return keyboardLearnedWordsAll(in: store)
}

/// Every learned word of every language, for the app's list and count. Pure function.
public func keyboardLearnedWordsAll(in store: KeyboardLearnedStore) -> [String] {
    keyboardDistinct(store.shared + store.byLanguage.keys.sorted().flatMap { store.byLanguage[$0] ?? [] })
}

/// The store with `word` learned: in the language's list when languages are kept apart, in the shared one otherwise
/// (`keyboardLearnedWordsAdding`: the newest `limit` words of that list stay). Pure function.
public func keyboardLearnedStoreAdding(
    _ store: KeyboardLearnedStore, word: String, language: KeyboardLanguage, perLanguage: Bool, limit: Int
) -> KeyboardLearnedStore {
    if perLanguage {
        var byLanguage: [String: [String]] = store.byLanguage
        byLanguage[language.rawValue] = keyboardLearnedWordsAdding(word: word, to: store.byLanguage[language.rawValue] ?? [], limit: limit)
        return KeyboardLearnedStore(shared: store.shared, byLanguage: byLanguage)
    }
    return KeyboardLearnedStore(shared: keyboardLearnedWordsAdding(word: word, to: store.shared, limit: limit), byLanguage: store.byLanguage)
}

/// The key under which corrections the user undid are remembered while typing `language`: the language's own when
/// languages are kept apart, else one for all. Pure function.
public func keyboardLearningScope(language: KeyboardLanguage, perLanguage: Bool) -> String {
    perLanguage ? language.rawValue : "*"
}

private func keyboardDistinct(_ words: [String]) -> [String] {
    var seen: Set<String> = []
    return words.filter { seen.insert($0).inserted }
}
