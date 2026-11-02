import Foundation

/// Dinlerken sesi alıp yazıya döken sesle yazma motoru. Örnekler 16 kHz mono Float32'dir.
public protocol LiveDictationEngine: Sendable {
    /// Parça akışı bitene dek (mikrofon kapanınca) dinler; değişen ara metni `onPartial`'a verir (motor desteklemiyorsa
    /// hiç çağrılmaz). Akış bitince kalan sesi yazıya döküp tüm metni döndürür; konuşma yoksa boş metin.
    func transcribe(chunks: AsyncStream<[Float]>, language: MeetingLanguage, onPartial: @escaping @Sendable (String) -> Void) async throws -> String
}

/// Canlı dikte metni: kesinleşmiş parçalar ve sonraki sonuçla değişebilecek son (geçici) parça.
public struct DictationTranscript: Sendable, Equatable {
    public let finalized: [String]
    public let volatile: String

    public init(finalized: [String], volatile: String) {
        self.finalized = finalized
        self.volatile = volatile
    }
}

/// Motor sonucunu metne işler: kesin sonuç kesinleşmişlere eklenir ve geçici parça silinir; geçici sonuç önceki geçici
/// parçanın yerini alır. Saf fonksiyondur.
public func dictationTranscriptApplying(transcript: DictationTranscript, text: String, isFinal: Bool) -> DictationTranscript {
    isFinal
        ? DictationTranscript(finalized: transcript.finalized + [text], volatile: "")
        : DictationTranscript(finalized: transcript.finalized, volatile: text)
}

/// Metnin tamamı: kesinleşmiş parçalar ve geçici parça, kırpılıp tek boşlukla birleştirilir (boş parçalar atlanır).
/// Saf fonksiyondur.
public func dictationTranscriptText(transcript: DictationTranscript) -> String {
    (transcript.finalized + [transcript.volatile])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

/// Akış desteklemeyen motor (WhisperKit, macOS 26'dan eski): dinlerken örnekleri biriktirir, mikrofon kapanınca hepsini
/// birden yazıya döker. Ara metin vermez.
public struct BatchDictation: LiveDictationEngine {
    private let engine: any TranscriptionEngine

    public init(engine: any TranscriptionEngine) {
        self.engine = engine
    }

    public func transcribe(chunks: AsyncStream<[Float]>, language: MeetingLanguage, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        var samples: [Float] = []
        for await chunk in chunks {
            samples.append(contentsOf: chunk)
        }
        // İptal edilen dinlemenin sesi yazıya dökülmez.
        try Task.checkCancellation()
        return try await engine.transcribe(samples: samples, language: language)
    }
}
