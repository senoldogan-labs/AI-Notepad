import Foundation

/// The languages a finished dictation is translated between (Settings › Keyboard, "Söylediğimi çevir"). Both are BCP 47
/// codes ("tr", "en-GB", "zh-TW"); the keyboard translates with Apple's on-device Translation framework.
public struct KeyboardTranslationPair: Sendable, Hashable {
    public let sourceLanguageCode: String
    public let targetLanguageCode: String

    public init(sourceLanguageCode: String, targetLanguageCode: String) {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
    }
}

/// Why a dictation's translation did not come through. The keyboard shows it and inserts nothing by itself: the spoken
/// text goes in only when the user asks for it untranslated.
public enum KeyboardTranslationFailure: Error, Sendable, Hashable {
    /// Apple supports the pair, but its languages are not downloaded on this iPhone.
    case notInstalled
    /// Apple's on-device translation has no model for the pair.
    case unsupportedPair
    /// The translation itself failed.
    case failed
}

/// The translation a finished dictation gets: none when no target is chosen or the dictation is already in the target
/// language (same language and script; regional variants such as "pt" and "pt-PT" count as the same). Pure function.
public func keyboardTranslationPair(sourceLanguageCode: String, targetLanguageCode: String?) -> KeyboardTranslationPair? {
    guard let targetLanguageCode, !keyboardIsSameWrittenLanguage(sourceLanguageCode, targetLanguageCode) else {
        return nil
    }
    return KeyboardTranslationPair(sourceLanguageCode: sourceLanguageCode, targetLanguageCode: targetLanguageCode)
}

/// Whether two BCP 47 codes write the same language in the same script ("zh" and "zh-TW" differ: Simplified and
/// Traditional). Pure function.
public func keyboardIsSameWrittenLanguage(_ first: String, _ second: String) -> Bool {
    let lhs: Locale.Language = Locale.Language(identifier: first)
    let rhs: Locale.Language = Locale.Language(identifier: second)
    guard let lhsCode = lhs.languageCode, let rhsCode = rhs.languageCode else {
        return first.lowercased() == second.lowercased()
    }
    return lhsCode == rhsCode && lhs.maximalIdentifierScript == rhs.maximalIdentifierScript
}

private extension Locale.Language {
    /// The script of the language's likely full form ("zh-TW" → Hant, "tr" → Latn).
    var maximalIdentifierScript: Locale.Script? {
        Locale.Language(identifier: maximalIdentifier).script
    }
}

/// The language a finished dictation was spoken in, as the translation's source. A chosen voice language is what the
/// dictation used. Without one, Gistsmith detects the spoken language among the keyboard's languages, so the language
/// detected in the text counts when it is one of them; otherwise it is the language the dictation started in.
/// `detectedLanguageCode` is nil for the keyboard's own (in-place) dictation, which always uses the started language.
/// Pure function.
public func keyboardDictationSourceLanguage(
    voiceLanguageCode: String?, startedLanguageCode: String, detectedLanguageCode: String?, keyboardLanguages: [KeyboardLanguage]
) -> String {
    if let voiceLanguageCode {
        return voiceLanguageCode
    }
    guard let detectedLanguageCode, let detected = keyboardLanguage(identifier: detectedLanguageCode), keyboardLanguages.contains(detected) else {
        return startedLanguageCode
    }
    return detected.rawValue
}

/// A translated dictation as the field receives it: the dictation options that are about the result (final period,
/// lowercase) applied again in the target language, since a translation writes its own period and capitals. Spoken
/// marks, lists and clean-up were applied before translating. Pure function.
public func keyboardTranslatedDictation(text: String, targetLanguageCode: String, options: KeyboardDictationOptions) -> String {
    var result: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !options.endWithPeriod {
        result = dictationWithoutFinalPeriod(text: result)
    }
    if options.lowercase {
        result = result.lowercased(with: Locale(identifier: keyboardLocaleLanguage(identifier: targetLanguageCode)))
    }
    return result
}
