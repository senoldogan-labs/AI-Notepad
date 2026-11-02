import Foundation
import Speech

/// Sesle yazmada ana toplantı dilinin dikte (`DictationTranscriber`) yerel ayarı: kullanıcının bölgesi, sonra dilin kendi
/// ülkesi, sonra alfabetik ilk; Norveççe Bokmål ("nb"). Desteklenmiyorsa nil. Saf fonksiyondur.
public func appleDictationLocale(language: MeetingLanguage, dictationLocales: [String], regionCode: String?) -> String? {
    preferredLocaleIdentifier(languageCode: language == .norwegian ? "nb" : language.rawValue, identifiers: dictationLocales, regionCode: regionCode)
}

/// Sesle yazmanın dikte modülü: noktalamalı, kısa ya da uzun dikte (ipucu yok; eller serbest dikte uzun sürebilir).
@available(macOS 26.0, *)
private func dictationModule(localeIdentifier: String) -> DictationTranscriber {
    DictationTranscriber(
        locale: Locale(identifier: localeIdentifier), contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: []
    )
}

/// Sesle yazmanın Apple motoru (macOS 26+): `SpeechAnalyzer` + `DictationTranscriber`, tamamen cihaz içi (ses hiçbir
/// yere gönderilmez). Dil algılamaz; ana toplantı diliyle çalışır, desteklemiyorsa `DictationError.unsupportedLanguage`.
/// Dilin modeli yüklü değilse ilk hazırlıkta indirilir. Sistem eskiyse `AppleSpeechError.requiresNewerSystem`.
///
/// Actor yeniden girişlidir: çağıran taraf `prepare` bitmeden `transcribe` çağırmamalıdır (bkz. App/Dictation.swift).
public actor AppleDictationEngine: TranscriptionEngine {
    /// Hazırlanmış diller ve yerel ayarları (model kurulu).
    private var prepared: [MeetingLanguage: String] = [:]

    public init() {}

    public func detectLanguage(samples: [Float]) async throws -> [String: Float] {
        throw AppleSpeechError.languageDetectionUnsupported
    }

    /// Dilin dikte modelini hazırlar (gerekirse indirir; ilerleme 0…1 `onProgress`'e).
    public func prepare(language: MeetingLanguage, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        _ = try await preparedLocale(language: language, onProgress: onProgress)
    }

    /// Konuşma yoksa boş metin.
    public func transcribe(samples: [Float], language: MeetingLanguage) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerSystem
        }
        let identifier: String = try await preparedLocale(language: language) { (_: Double) -> Void in }
        return try await analyzedText(samples: samples, module: dictationModule(localeIdentifier: identifier), localeIdentifier: identifier) {
            (result: DictationTranscriber.Result) -> String in
            String(result.text.characters)
        }
    }

    @available(macOS 26.0, *)
    private func preparedLocale(language: MeetingLanguage, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        if let identifier = prepared[language] {
            onProgress(1)
            return identifier
        }
        let locales: [String] = await DictationTranscriber.supportedLocales.map(\.identifier)
        guard let identifier = appleDictationLocale(language: language, dictationLocales: locales, regionCode: Locale.current.region?.identifier) else {
            throw DictationError.unsupportedLanguage(language)
        }
        try await installSpeechAssets(module: dictationModule(localeIdentifier: identifier), localeIdentifier: identifier, onProgress: onProgress)
        prepared[language] = identifier
        return identifier
    }
}

/// Bu Mac'in cihaz içi diktesi (macOS 26+) dili destekliyor mu (Ayarlar'daki uyarı için; model indirilmez).
@available(macOS 26.0, *)
public func appleDictationSupports(language: MeetingLanguage) async -> Bool {
    let locales: [String] = await DictationTranscriber.supportedLocales.map(\.identifier)
    return appleDictationLocale(language: language, dictationLocales: locales, regionCode: Locale.current.region?.identifier) != nil
}
