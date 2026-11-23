#if canImport(FoundationModels)
import Foundation
import FoundationModels
import NaturalLanguage
import os

/// Only failure kinds are logged; the dictated text never is.
private let polishLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.keyboard", category: "Polish")

/// The on-device clean-up of a polished dictation (`KeyboardDictationStyle.polished`): Apple Intelligence's model
/// (`SystemLanguageModel`) fixes misheard words, grammar and punctuation of the rule-formatted text. The model runs in
/// the system's own process, so the keyboard extension can use it within its memory limit; nothing leaves the iPhone.
/// Used by Gistsmith for dictations it hears and by the keyboard for the ones it hears itself.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class KeyboardPolisher {
    /// A session made and warmed when the dictation started (`prepare`), for the language it was made for; used once.
    private var prepared: (session: LanguageModelSession, language: String)?

    public init() {}

    /// Why polishing cannot run now for any of these languages; nil when it can for at least one.
    public static func unavailableReason(languageCodes: [String]) -> KeyboardPolishFailure? {
        let model: SystemLanguageModel = polishModel()
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            return keyboardPolishFailure(reason: reason)
        }
        let supported: Set<String> = Set(model.supportedLanguages.compactMap { $0.languageCode?.identifier })
        return keyboardPolishSupports(languageCodes: languageCodes, supported: supported) ? nil : .languageUnsupported
    }

    /// Loads the model while the user still speaks, so the clean-up starts warm (a cold start takes seconds).
    public func prepare(languageCode: String) {
        let language: String = keyboardLocaleLanguage(identifier: languageCode)
        guard Self.unavailableReason(languageCodes: [language]) == nil else {
            prepared = nil
            return
        }
        let session: LanguageModelSession = polishSession(language: language)
        session.prewarm()
        prepared = (session, language)
    }

    /// Drops the warmed session (the dictation was cancelled).
    public func reset() {
        prepared = nil
    }

    /// Polishes `text` (the dictation as the rules wrote it). The language is the candidate (dictation languages, the
    /// most likely first) the text reads as. Every failure is returned, never thrown: the caller then inserts `text` and
    /// says it was not polished.
    public func polish(text: String, candidateLanguages: [String], options: KeyboardDictationOptions) async -> KeyboardPolishState {
        let recognizer: NLLanguageRecognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        var hypotheses: [String: Double] = [:]
        for (language, probability) in recognizer.languageHypotheses(withMaximum: 5) {
            hypotheses[language.rawValue] = probability
        }
        guard let language = keyboardPolishLanguage(candidates: candidateLanguages, hypotheses: hypotheses) else {
            return .failed(.languageUnsupported)
        }
        if let reason = Self.unavailableReason(languageCodes: [language]) {
            polishLogger.info("Polish unavailable, reason: \(reason.rawValue, privacy: .public)")
            return .failed(reason)
        }
        let session: LanguageModelSession
        if let prepared, prepared.language == language {
            session = prepared.session
        } else {
            session = polishSession(language: language)
        }
        prepared = nil
        let prompt: String = keyboardPolishPrompt(text: text)
        let generation: GenerationOptions = GenerationOptions(
            sampling: .greedy, temperature: nil, maximumResponseTokens: keyboardPolishMaximumTokens(text: text)
        )
        let timeout: TimeInterval = keyboardPolishTimeout(text: text)
        let deadline: Date = Date().addingTimeInterval(timeout)
        let work: Task<String, any Error> = Task {
            try await session.respond(to: prompt, options: generation).content
        }
        let timer: Task<Void, Never> = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            work.cancel()
        }
        defer { timer.cancel() }
        let output: String
        do {
            // A cancelled dictation stops the generation too.
            output = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            let failure: KeyboardPolishFailure = Date() >= deadline ? .timedOut : keyboardPolishFailure(error: error)
            polishLogger.error("Polish failed, failure: \(failure.rawValue, privacy: .public), error: \(String(describing: type(of: error)), privacy: .public)")
            return .failed(failure)
        }
        let result: KeyboardPolishState = keyboardPolishResult(original: text, output: output, languageCode: language, options: options)
        if case .failed(let failure) = result {
            polishLogger.error("Polish output rejected, failure: \(failure.rawValue, privacy: .public)")
        }
        return result
    }

    private func polishSession(language: String) -> LanguageModelSession {
        let name: String = Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
        return LanguageModelSession(model: polishModel(), tools: [], instructions: keyboardPolishInstructions(languageName: name))
    }
}

/// The general model with guardrails for transforming the user's own text (as the app's on-device notes use).
@available(iOS 26.0, macOS 26.0, *)
private func polishModel() -> SystemLanguageModel {
    SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
}

@available(iOS 26.0, macOS 26.0, *)
private func keyboardPolishFailure(reason: SystemLanguageModel.Availability.UnavailableReason) -> KeyboardPolishFailure {
    switch reason {
    case .deviceNotEligible:
        .deviceNotEligible
    case .appleIntelligenceNotEnabled:
        .appleIntelligenceNotEnabled
    case .modelNotReady:
        .modelNotReady
    @unknown default:
        .failed
    }
}

@available(iOS 26.0, macOS 26.0, *)
private func keyboardPolishFailure(error: any Error) -> KeyboardPolishFailure {
    guard let generation = error as? LanguageModelSession.GenerationError else {
        return .failed
    }
    switch generation {
    case .unsupportedLanguageOrLocale:
        return .languageUnsupported
    case .assetsUnavailable:
        return .modelNotReady
    default:
        return .failed
    }
}
#endif
