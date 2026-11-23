import Foundation
import KeyboardCore
import NaturalLanguage
import OSLog
import Translation

private let translatorLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.keyboard", category: "KeyboardTranslator")

/// Translates a finished dictation with Apple's on-device Translation framework ("Söylediğimi çevir"). The models run in
/// the system's translation service, not in the keyboard's memory, and only installed languages are used: the keyboard
/// cannot show Apple's download sheet, so a missing pair fails with `notInstalled` and Gistsmith's Settings › Keyboard
/// downloads it. Nothing leaves the iPhone.
@available(iOS 26.0, *)
enum KeyboardTranslator {
    static func translate(text: String, pair: KeyboardTranslationPair) async throws(KeyboardTranslationFailure) -> String {
        let source: Locale.Language = Locale.Language(identifier: pair.sourceLanguageCode)
        let target: Locale.Language = Locale.Language(identifier: pair.targetLanguageCode)
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            break
        case .supported:
            throw .notInstalled
        case .unsupported:
            throw .unsupportedPair
        @unknown default:
            translatorLogger.error("Unknown translation availability, pair: \(pair.sourceLanguageCode, privacy: .public)→\(pair.targetLanguageCode, privacy: .public)")
            throw .failed
        }
        let session: TranslationSession = TranslationSession(installedSource: source, target: target)
        do {
            return try await session.translate(text).targetText
        } catch {
            translatorLogger.error(
                "Translation failed, pair: \(pair.sourceLanguageCode, privacy: .public)→\(pair.targetLanguageCode, privacy: .public), error: \(String(describing: error), privacy: .public)"
            )
            throw TranslationError.notInstalled ~= error ? .notInstalled : .failed
        }
    }
}

/// The language the text is written in among `candidates` (BCP 47), weighted towards `hint`; nil when it cannot tell.
/// Used for Gistsmith's dictations with automatic voice language, which may be in any of the keyboard's languages.
func keyboardDetectedLanguage(text: String, candidates: [KeyboardLanguage], hint: String) -> String? {
    let recognizer: NLLanguageRecognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = candidates.map { (language: KeyboardLanguage) -> NLLanguage in NLLanguage(rawValue: language.rawValue) }
    recognizer.languageHints = [NLLanguage(rawValue: keyboardLocaleLanguage(identifier: hint)): 0.6]
    recognizer.processString(text)
    return recognizer.dominantLanguage?.rawValue
}
