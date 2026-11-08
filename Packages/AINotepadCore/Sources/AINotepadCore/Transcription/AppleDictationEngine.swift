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
            chunks: chunks, module: streamingDictationModule(localeIdentifier: identifier), localeIdentifier: identifier, onPartial: onPartial
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
    chunks: AsyncStream<[Float]>, module: DictationTranscriber, localeIdentifier: String, onPartial: @escaping @Sendable (String) -> Void
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

/// Bu Mac'in cihaz içi diktesi (macOS 26+) dili destekliyor mu (Ayarlar'daki uyarı için; model indirilmez).
@available(macOS 26.0, iOS 26.0, *)
public func appleDictationSupports(language: MeetingLanguage) async -> Bool {
    let locales: [String] = await DictationTranscriber.supportedLocales.map(\.identifier)
    return appleDictationLocale(language: language, dictationLocales: locales, regionCode: Locale.current.region?.identifier) != nil
}
