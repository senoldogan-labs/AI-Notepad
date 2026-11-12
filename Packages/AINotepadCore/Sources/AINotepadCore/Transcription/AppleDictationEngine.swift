import Foundation
import Speech

/// Sesle yazmada ana toplantı dilinin dikte (`DictationTranscriber`) yerel ayarı: kullanıcının bölgesi, sonra dilin kendi
/// ülkesi, sonra alfabetik ilk; Norveççe Bokmål ("nb"). Desteklenmiyorsa nil. Saf fonksiyondur.
public func appleDictationLocale(language: MeetingLanguage, dictationLocales: [String], regionCode: String?) -> String? {
    preferredLocaleIdentifier(languageCode: language == .norwegian ? "nb" : language.rawValue, identifiers: dictationLocales, regionCode: regionCode)
}

/// Sesle yazmanın dikte modülü: noktalamalı, kısa ya da uzun dikte (ipucu yok; eller serbest dikte uzun sürebilir).
@available(macOS 26.0, iOS 26.0, *)
private func dictationModule(localeIdentifier: String) -> DictationTranscriber {
    DictationTranscriber(
        locale: Locale(identifier: localeIdentifier), contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: []
    )
}

/// Sesle yazmanın canlı modülü: dinlerken çalışır; geçici sonuçlar hapta ara metni gösterir, sık kesinleştirme bırakınca
/// yazıya dökülecek kuyruğu kısaltır.
@available(macOS 26.0, iOS 26.0, *)
private func streamingDictationModule(localeIdentifier: String) -> DictationTranscriber {
    DictationTranscriber(
        locale: Locale(identifier: localeIdentifier), contentHints: [], transcriptionOptions: [.punctuation],
        reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: []
    )
}

/// Sesle yazmanın Apple motoru (macOS 26+): `SpeechAnalyzer` + `DictationTranscriber`, tamamen cihaz içi (ses hiçbir
/// yere gönderilmez). Dil algılamaz; ana toplantı diliyle çalışır, desteklemiyorsa `DictationError.unsupportedLanguage`.
/// Dilin modeli yüklü değilse ilk hazırlıkta indirilir. Sistem eskiyse `AppleSpeechError.requiresNewerSystem`.
/// Sesle yazma `transcribe(chunks:…)` ile dinlerken yazıya döker; bırakınca yalnız son kısım kalır.
///
/// Actor yeniden girişlidir: çağıran taraf `prepare` bitmeden `transcribe` çağırmamalıdır (bkz. App/Dictation.swift).
public actor AppleDictationEngine: TranscriptionEngine, LiveDictationEngine {
    /// Hazırlanmış diller ve yerel ayarları (model kurulu).
    private var prepared: [MeetingLanguage: String] = [:]

    public init() {}

    public func detectLanguage(samples: [Float]) async throws -> [String: Float] {
        throw AppleSpeechError.languageDetectionUnsupported
    }

    /// Dilin dikte modelini hazırlar (gerekirse indirir; ilerleme 0…1 `onProgress`'e).
    public func prepare(language: MeetingLanguage, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        _ = try await preparedLocale(language: language, onProgress: onProgress)
    }

    /// Konuşma yoksa boş metin.
    public func transcribe(samples: [Float], language: MeetingLanguage) async throws -> String {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        let identifier: String = try await preparedLocale(language: language) { (_: Double) -> Void in }
        return try await analyzedText(samples: samples, module: dictationModule(localeIdentifier: identifier), localeIdentifier: identifier) {
            (result: DictationTranscriber.Result) -> String in
            String(result.text.characters)
        }
    }

    /// Parçalar geldikçe yazıya döker (bkz. `LiveDictationEngine`).
    public func transcribe(chunks: AsyncStream<[Float]>, language: MeetingLanguage, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        let identifier: String = try await preparedLocale(language: language) { (_: Double) -> Void in }
        return try await streamedDictationText(
            chunks: chunks, module: streamingDictationModule(localeIdentifier: identifier), localeIdentifier: identifier, contextualStrings: [],
            onPartial: onPartial
        )
    }

    /// Klavyeyle sesle yazma: yerel ayar kimliğiyle (ör. "tr_TR") ve kullanıcının sözlüğünden gelen ipuçlarıyla
    /// (`contextualStrings`, en fazla 100; Apple'ın sınırı) dinlerken yazıya döker. Model `prepare(localeIdentifier:…)`
    /// ile hazırlanmış olmalı.
    public func transcribe(
        chunks: AsyncStream<[Float]>, localeIdentifier: String, contextualStrings: [String], onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        return try await streamedDictationText(
            chunks: chunks, module: streamingDictationModule(localeIdentifier: localeIdentifier), localeIdentifier: localeIdentifier,
            contextualStrings: Array(contextualStrings.prefix(dictationContextualStringLimit)), onPartial: onPartial
        )
    }

    /// Keyboard dictation without a fixed language: buffers the first `dictationDetectionSampleCount` samples, scores them
    /// with every candidate locale's dictation model (mean transcription confidence), picks the best locale with
    /// `dictationLanguagePick`, then transcribes the buffered samples followed by the live stream with that locale.
    /// The candidates' models must be installed (no download happens here). Returns the transcript.
    public func transcribe(
        chunks: AsyncStream<[Float]>, candidateLocales: [DictationCandidateLocale], preferredLocale: String, contextualStrings: [String],
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        let (merged, mergedContinuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let (decisions, decisionContinuation): (AsyncStream<Result<String, any Error>>, AsyncStream<Result<String, any Error>>.Continuation) =
            AsyncStream.makeStream(of: Result<String, any Error>.self)
        let forwarder: Task<Void, Never> = Task {
            defer { mergedContinuation.finish() }
            var iterator: AsyncStream<[Float]>.Iterator = chunks.makeAsyncIterator()
            var buffered: [Float] = []
            while buffered.count < dictationDetectionSampleCount, let chunk = await iterator.next() {
                buffered.append(contentsOf: chunk)
            }
            do {
                let scores: [DictationLanguageScore] = try await dictationLanguageScores(samples: buffered, candidates: candidateLocales)
                let chosen: String = dictationLanguagePick(scores: scores, preferred: preferredLocale)
                let summary: String = scores.map { "\($0.locale)=\(String(format: "%.2f", $0.confidence))" }.joined(separator: " ")
                speechLogger.info("Dictation language picked, locale: \(chosen, privacy: .public), scores: \(summary, privacy: .public)")
                decisionContinuation.yield(.success(chosen))
            } catch {
                decisionContinuation.yield(.failure(error))
                decisionContinuation.finish()
                return
            }
            decisionContinuation.finish()
            mergedContinuation.yield(buffered)
            while let chunk = await iterator.next() {
                mergedContinuation.yield(chunk)
            }
        }
        return try await withTaskCancellationHandler {
            var decisionIterator: AsyncStream<Result<String, any Error>>.Iterator = decisions.makeAsyncIterator()
            guard let decision = await decisionIterator.next() else {
                throw CancellationError()
            }
            let locale: String = try decision.get()
            return try await streamedDictationText(
                chunks: merged, module: streamingDictationModule(localeIdentifier: locale), localeIdentifier: locale,
                contextualStrings: Array(contextualStrings.prefix(dictationContextualStringLimit)), onPartial: onPartial
            )
        } onCancel: {
            forwarder.cancel()
        }
    }

    /// Yerel ayarın dikte modelini hazırlar (gerekirse indirir; ilerleme 0…1 `onProgress`'e).
    public func prepare(localeIdentifier: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        try await installSpeechAssets(
            module: streamingDictationModule(localeIdentifier: localeIdentifier), localeIdentifier: localeIdentifier, onProgress: onProgress
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func preparedLocale(language: MeetingLanguage, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        if let identifier = prepared[language] {
            onProgress(1)
            return identifier
        }
        let locales: [String] = await DictationTranscriber.supportedLocales.map(\.identifier)
        guard let identifier = appleDictationLocale(language: language, dictationLocales: locales, regionCode: Locale.current.region?.identifier) else {
            throw DictationError.unsupportedLanguage(language)
        }
        try await installSpeechAssets(module: streamingDictationModule(localeIdentifier: identifier), localeIdentifier: identifier, onProgress: onProgress)
        prepared[language] = identifier
        return identifier
    }
}

/// Parça akışını dinlerken tek bir çözümleyiciye verir; her sonuçta güncel metni `onPartial`'a bildirir. Akış bitince
/// kalan ses kesinleştirilir ve tüm metin döner. İptal edilirse çözümleyici hemen durur.
@available(macOS 26.0, iOS 26.0, *)
private func streamedDictationText(
    chunks: AsyncStream<[Float]>, module: DictationTranscriber, localeIdentifier: String, contextualStrings: [String],
    onPartial: @escaping @Sendable (String) -> Void
) async throws -> String {
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
        throw AppleSpeechError.noAudioFormat(locale: localeIdentifier)
    }
    let analyzer: SpeechAnalyzer = SpeechAnalyzer(modules: [module], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
    let collector: Task<DictationTranscript, any Error> = Task {
        var transcript: DictationTranscript = DictationTranscript(finalized: [], volatile: "")
        for try await result in module.results {
            transcript = dictationTranscriptApplying(transcript: transcript, text: String(result.text.characters), isFinal: result.isFinal)
            onPartial(dictationTranscriptText(transcript: transcript))
        }
        return transcript
    }
    let (input, continuation): (AsyncStream<AnalyzerInput>, AsyncStream<AnalyzerInput>.Continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    // Mikrofon parçaları modülün biçimine (16 kHz Int16) çevrilip çözümleyiciye akar; akış bitince giriş de biter.
    let pump: Task<Void, any Error> = Task {
        defer { continuation.finish() }
        for await chunk in chunks where !chunk.isEmpty {
            continuation.yield(AnalyzerInput(buffer: try convertedBuffer(samples: chunk, format: format)))
        }
    }
    return try await withTaskCancellationHandler {
        do {
            try await analyzer.prepareToAnalyze(in: format)
            if !contextualStrings.isEmpty {
                let context: AnalysisContext = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: input)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await pump.value
            return dictationTranscriptText(transcript: try await collector.value)
        } catch let error as AppleSpeechError {
            collector.cancel()
            throw error
        } catch is CancellationError {
            collector.cancel()
            throw CancellationError()
        } catch {
            collector.cancel()
            throw AppleSpeechError.analysisFailed(locale: localeIdentifier, reason: String(describing: error))
        }
    } onCancel: {
        pump.cancel()
        collector.cancel()
        Task {
            await analyzer.cancelAndFinishNow()
        }
    }
}

/// Dikteye verilen ipucu sayısının üst sınırı: "Limit the total number of phrases across all tags to no more than 100"
/// (Speech, `AnalysisContext.contextualStrings`).
public let dictationContextualStringLimit: Int = 100

/// Dil kodunun (ör. "tr", "nb") cihaz içi dikte yerel ayarı: kullanıcının bölgesi, sonra dilin kendi ülkesi;
/// desteklenmiyorsa nil.
@available(macOS 26.0, iOS 26.0, *)
public func appleDictationLocale(languageCode: String) async -> String? {
    let locales: [String] = await DictationTranscriber.supportedLocales.map(\.identifier)
    return preferredLocaleIdentifier(languageCode: languageCode, identifiers: locales, regionCode: Locale.current.region?.identifier)
}

/// Cihaz içi diktenin desteklediği dil kodları (ör. "ja", "tr"), sıralı.
@available(macOS 26.0, iOS 26.0, *)
public func appleDictationLanguageCodes() async -> [String] {
    let locales: [String] = await DictationTranscriber.supportedLocales.map(\.identifier)
    return Array(Set(locales.map { localeLanguagePart(identifier: $0) })).sorted()
}

/// Bu Mac'in cihaz içi diktesi (macOS 26+) dili destekliyor mu (Ayarlar'daki uyarı için; model indirilmez).
@available(macOS 26.0, iOS 26.0, *)
public func appleDictationSupports(language: MeetingLanguage) async -> Bool {
    let locales: [String] = await DictationTranscriber.supportedLocales.map(\.identifier)
    return appleDictationLocale(language: language, dictationLocales: locales, regionCode: Locale.current.region?.identifier) != nil
}

/// How much audio (16 kHz samples, about 2.5 s) the keyboard buffers to detect the spoken language.
public let dictationDetectionSampleCount: Int = 40_000

/// A dictation locale that takes part in spoken-language detection.
public struct DictationCandidateLocale: Sendable, Hashable {
    public let locale: String

    public init(locale: String) {
        self.locale = locale
    }
}

/// How well one locale's dictation model understood the buffered audio: mean transcription confidence, 0 when it heard nothing.
public struct DictationLanguageScore: Sendable, Hashable {
    public let locale: String
    public let confidence: Double

    public init(locale: String, confidence: Double) {
        self.locale = locale
        self.confidence = confidence
    }
}

/// A locale must beat the preferred one by this much confidence to replace it (measured: right language 0.76-0.98, wrong 0.09-0.29).
public let dictationLanguageSwitchMargin: Double = 0.1

/// The locale to dictate with: the best-scoring one when it clearly beats the preferred locale, otherwise the preferred
/// one (tie, nothing heard, or the preferred locale is not scored and nothing scored above zero). Pure function.
public func dictationLanguagePick(scores: [DictationLanguageScore], preferred: String) -> String {
    guard let best = scores.max(by: { $0.confidence < $1.confidence }), best.confidence > 0 else {
        return preferred
    }
    let preferredConfidence: Double = scores.first(where: { $0.locale == preferred })?.confidence ?? 0
    return best.confidence - preferredConfidence > dictationLanguageSwitchMargin ? best.locale : preferred
}

/// Language codes to consider for spoken-language detection: the command's language first, then the keyboard layouts'
/// languages, without duplicates, at most `limit`. Pure function.
public func dictationCandidateCodes(commandLanguageCode: String, layoutLanguageCodes: [String], limit: Int) -> [String] {
    var seen: Set<String> = []
    return ([commandLanguageCode] + layoutLanguageCodes).filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
}

/// Installed dictation locale for a language code (nil when unsupported or its model is not installed); never downloads.
@available(macOS 26.0, iOS 26.0, *)
public func installedAppleDictationLocale(languageCode: String) async -> String? {
    guard let identifier = await appleDictationLocale(languageCode: languageCode) else {
        return nil
    }
    let installed: Set<String> = Set(await DictationTranscriber.installedLocales.map { Locale(identifier: $0.identifier).identifier })
    return installed.contains(Locale(identifier: identifier).identifier) ? identifier : nil
}

/// Scores the samples with each candidate's dictation model, one after the other (keeps the load low).
@available(macOS 26.0, iOS 26.0, *)
private func dictationLanguageScores(samples: [Float], candidates: [DictationCandidateLocale]) async throws -> [DictationLanguageScore] {
    var scores: [DictationLanguageScore] = []
    for candidate in candidates {
        let confidence: Double = try await dictationConfidence(samples: samples, localeIdentifier: candidate.locale)
        scores.append(DictationLanguageScore(locale: candidate.locale, confidence: confidence))
    }
    return scores
}

/// Mean confidence over the final results' text runs of one locale's dictation of the samples; 0 when nothing was heard.
@available(macOS 26.0, iOS 26.0, *)
private func dictationConfidence(samples: [Float], localeIdentifier: String) async throws -> Double {
    let module: DictationTranscriber = DictationTranscriber(
        locale: Locale(identifier: localeIdentifier), contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [],
        attributeOptions: [.transcriptionConfidence]
    )
    let perResult: [Double] = try await analyzedValues(samples: samples, module: module, localeIdentifier: localeIdentifier) {
        (result: DictationTranscriber.Result) -> Double? in
        let runs: [Double] = result.text.runs.compactMap { $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] }
        return runs.isEmpty ? nil : runs.reduce(0, +) / Double(runs.count)
    }
    return perResult.isEmpty ? 0 : perResult.reduce(0, +) / Double(perResult.count)
}
