import Foundation
import Testing
@testable import AINotepadCore

/// Haiku 5.5 fiyatı ($ / milyon token): girdi ve çıktı.
private let haikuInputUSDPerMillion: Double = 0.10
private let haikuOutputUSDPerMillion: Double = 0.50

extension CloudTests {
    /// Toplantı sonu çevirisinin gerçek çağrıyla kanıtı (Gistsmith'in modeli, Haiku 5.5, sunucunun ilettiği gövdeyle):
    /// gerçek, herkese açık bir basın toplantısının 14 dakikalık son geçiş metni (`press-conference-en.tsv`) uygulamanın
    /// istekleriyle Türkçeye çevrilir. Her parça kendi Türkçesini almalı; canlı çevirinin duyma hataları ("CENTCOM" →
    /// "sitcom", "autopen" → "euro pen") düzgün metinden gelmemeli. Ölçülen token ve $ (saatlik karşılığıyla) yazdırılır.
    /// Çalıştırma: `AINOTEPAD_CLOUD_TESTS=1 swift test --filter TranscriptTranslationCloudTests` (~$0.01).
    @Suite(.serialized)
    struct TranscriptTranslationCloudTests {
        @Test func pressConferenceTranslatesEveryPieceWithKeyTerms() async throws {
            let segments: [StoredSegment] = try pressConferenceSegments()
            let record: MeetingRecord = MeetingRecord(
                id: "press", title: "press", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, language: .english, status: .done,
                failureMessage: nil, liveSegments: [], finalSegments: segments, translations: ["others-0": "canlı"], speakerNames: [:], note: nil,
                audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
            )
            let pieces: [StoredSegment] = transcriptTranslationPieces(record: record, language: .turkish)
            let batches: [TranscriptTranslationBatch] = transcriptTranslationBatches(
                pieces: pieces, all: transcriptReadingPieces(record: record), maxCharacters: transcriptTranslationBatchCharacters,
                contextBefore: transcriptTranslationContextBefore, contextAfter: transcriptTranslationContextAfter
            )
            let apiKey: String = try cloudKey(account: .anthropic)
            var input: Int = 0
            var output: Int = 0
            var translations: [String: String] = [:]
            for batch in batches {
                let request: LLMRequest = transcriptTranslationRequest(batch: batch, speakerNames: [:], terms: [], language: .turkish)
                let call: MeasuredNoteCall = try await measuredHostedNoteCall(request: request, apiKey: apiKey)
                input += call.inputTokens
                output += call.outputTokens
                let numbered: [Int: String] = try parseTranscriptTranslations(text: call.text, count: batch.pieces.count)
                for (offset, piece) in batch.pieces.enumerated() {
                    translations[piece.key] = numbered[offset + 1]
                }
            }
            let applied: MeetingRecord = applyingTranscriptTranslations(record: record, pieces: pieces, outcomes: [.translated(translations)])
            let minutes: Double = ((segments.last?.endSec ?? 0) - (segments.first?.startSec ?? 0)) / 60
            let dollars: Double = Double(input) / 1_000_000 * haikuInputUSDPerMillion + Double(output) / 1_000_000 * haikuOutputUSDPerMillion
            print("transcript translation: \(batches.count) requests, input \(input) tok, output \(output) tok, $\(String(format: "%.4f", dollars)) for \(String(format: "%.1f", minutes)) min → $\(String(format: "%.4f", dollars * 60 / minutes)) / hour")
            for key in ["final-2", "final-3", "final-5", "final-19", "final-40"] {
                print("[\(key)] \(applied.translations[key] ?? "—")")
            }

            // Her harfli parça Türkçe aldı (boşluk yok, tekrar yok).
            #expect(applied.failedTranslationKeys == nil)
            let missing: [String] = pieces.map(\.key).filter { applied.translations[$0] == nil }
            #expect(missing.isEmpty, "untranslated: \(missing)")
            // Anahtar terimler: kısaltma korunur, canlıdaki duyma hataları yok; autopen anlamıyla (imza makinesi) aktarılır.
            let all: String = pieces.compactMap { applied.translations[$0.key] }.joined(separator: "\n")
            let centcom: String = try #require(pieces.first { $0.text.contains("CENTCOM") }.flatMap { applied.translations[$0.key] })
            #expect(centcom.contains("CENTCOM"))
            let autopen: String = try #require(pieces.first { $0.text.lowercased().contains("autopen") }.flatMap { applied.translations[$0.key] })
            #expect(autopen.lowercased().contains("imza"))
            #expect(!all.lowercased().contains("sitcom") && !all.lowercased().contains("euro pen") && !all.contains("Senkamp"))
            // Bir saat en çok birkaç sent (Gistsmith toplantı bütçesi ve fiyatlandırma için).
            #expect(dollars * 60 / minutes < 0.10)
        }
    }
}
