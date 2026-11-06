import Foundation
import Testing
@testable import AINotepadCore

/// Son geçiş bölümü (kelime zamanları olmadan).
private func finalSegment(_ index: Int, _ start: Double, _ end: Double, _ text: String, person: Int?) -> StoredSegment {
    StoredSegment(key: "final-\(index)", speaker: .others, person: person, startSec: start, endSec: end, text: text, words: nil)
}

/// Bölümlerden kayıt: canlı tarafta tek çevirili bölüm (kullanıcı toplantıyı çevirili izledi), dil İngilizce.
private func translatedRecord(final: [StoredSegment], translations: [String: String]) -> MeetingRecord {
    MeetingRecord(
        id: "m", title: "m", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, language: .english, status: .done, failureMessage: nil,
        liveSegments: [StoredSegment(key: "others-0", speaker: .others, person: nil, startSec: 0, endSec: 5, text: "live", words: nil)],
        finalSegments: final, translations: translations, speakerNames: [1: "Aino"], note: nil, audioDeleted: false,
        engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

/// `press-conference-en.tsv` (gerçek, herkese açık bir basın toplantısının son geçiş metni; 14 dk, 60 paragraf):
/// her satır `başlangıç sn \t kişi \t metin`.
func pressConferenceSegments() throws -> [StoredSegment] {
    let url: URL = try #require(Bundle.module.url(forResource: "press-conference-en", withExtension: "tsv", subdirectory: "Fixtures"))
    let lines: [Substring] = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    let rows: [(Double, Int, String)] = lines.compactMap { (line: Substring) -> (Double, Int, String)? in
        let fields: [Substring] = line.split(separator: "\t", maxSplits: 2)
        guard fields.count == 3, let start = Double(fields[0]), let person = Int(fields[1]) else {
            return nil
        }
        return (start, person, String(fields[2]))
    }
    return rows.enumerated().map { (item: (offset: Int, element: (Double, Int, String))) -> StoredSegment in
        let (start, person, text): (Double, Int, String) = item.element
        let end: Double = item.offset + 1 < rows.count ? max(start + 1, rows[item.offset + 1].0) : start + 20
        return finalSegment(item.offset, start, end, text, person: person)
    }
}

/// İki bölümü sırayla kurucuya verir.
private func feedPair(first: LiveSegment, second: LiveSegment) -> TranslationUnitStep {
    let step: TranslationUnitStep = addingFinal(builder: .empty, segment: first, nowSec: 3, limits: liveTranslationUnitLimits)
    let next: TranslationUnitStep = addingFinal(builder: step.builder, segment: second, nowSec: 12, limits: liveTranslationUnitLimits)
    return TranslationUnitStep(builder: next.builder, ready: step.ready + next.ready)
}

@Suite struct TranscriptTranslationTests {
    // Parçalar sırayla, karakter sınırına kadar aynı isteğe girer; bağlam toplantının bütün parçalarından gelir.
    @Test func batchesKeepOrderAndCarryContext() {
        let all: [StoredSegment] = (0..<6).map { finalSegment($0, Double($0 * 10), Double($0 * 10 + 9), String(repeating: "a", count: 40), person: 1) }
        let batches: [TranscriptTranslationBatch] = transcriptTranslationBatches(
            pieces: Array(all[1...5]), all: all, maxCharacters: 100, contextBefore: 2, contextAfter: 1
        )
        #expect(batches.map { $0.pieces.map(\.key) } == [["final-1", "final-2"], ["final-3", "final-4"], ["final-5"]])
        #expect(batches[0].before.map(\.key) == ["final-0"])
        #expect(batches[0].after.map(\.key) == ["final-3"])
        #expect(batches[1].before.map(\.key) == ["final-1", "final-2"])
        #expect(batches[2].after.isEmpty)
        // Sınırdan uzun tek parça kendi isteğidir (bölünmez, atlanmaz).
        let long: StoredSegment = finalSegment(9, 0, 9, String(repeating: "b", count: 300), person: 1)
        #expect(transcriptTranslationBatches(pieces: [long], all: [long], maxCharacters: 100, contextBefore: 2, contextAfter: 1).map(\.pieces.count) == [1])
    }

    // Gerçek basın toplantısı: her parça tam bir kez bir isteğe girer; 4 saatlik toplantı da makul sayıda isteğe bölünür.
    @Test func pressConferenceBatchesCoverEveryPieceOnce() throws {
        let record: MeetingRecord = translatedRecord(final: try pressConferenceSegments(), translations: ["others-0": "canlı"])
        let pieces: [StoredSegment] = transcriptTranslationPieces(record: record, language: .turkish)
        #expect(pieces.count == 60)
        let batches: [TranscriptTranslationBatch] = transcriptTranslationBatches(
            pieces: pieces, all: transcriptReadingPieces(record: record), maxCharacters: transcriptTranslationBatchCharacters,
            contextBefore: transcriptTranslationContextBefore, contextAfter: transcriptTranslationContextAfter
        )
        #expect(batches.flatMap { $0.pieces.map(\.key) } == pieces.map(\.key))
        #expect(batches.allSatisfy { $0.pieces.reduce(0) { $0 + $1.text.count } <= transcriptTranslationBatchCharacters })
        // 14 dk ≈ 14 bin karakter → ~6 istek; 4 saat ≈ 17 kat.
        #expect((5...9).contains(batches.count))
    }

    // 4 saatlik toplantı (basın toplantısı 17 kez art arda): parçalar tam bir kez, istekler sınırlı (çıktı sınırına
    // ve tek hatada yeniden çevrilecek parça sayısına dayanır).
    @Test func fourHourMeetingIsChunked() throws {
        let base: [StoredSegment] = try pressConferenceSegments()
        let span: Double = (base.last?.endSec ?? 0) + 1
        let long: [StoredSegment] = (0..<17).flatMap { (round: Int) -> [StoredSegment] in
            base.enumerated().map { (item: (offset: Int, element: StoredSegment)) -> StoredSegment in
                finalSegment(round * base.count + item.offset, item.element.startSec + Double(round) * span, item.element.endSec + Double(round) * span, item.element.text, person: item.element.person)
            }
        }
        let record: MeetingRecord = translatedRecord(final: long, translations: ["others-0": "canlı"])
        let pieces: [StoredSegment] = transcriptTranslationPieces(record: record, language: .turkish)
        let batches: [TranscriptTranslationBatch] = transcriptTranslationBatches(
            pieces: pieces, all: transcriptReadingPieces(record: record), maxCharacters: transcriptTranslationBatchCharacters,
            contextBefore: transcriptTranslationContextBefore, contextAfter: transcriptTranslationContextAfter
        )
        #expect(pieces.count == 1_020)
        #expect(batches.flatMap { $0.pieces.map(\.key) } == pieces.map(\.key))
        #expect((90...140).contains(batches.count))
        #expect(batches.allSatisfy { transcriptTranslationRequest(batch: $0, speakerNames: [:], terms: [], language: .turkish).maxTokens <= hostedMeetingMaxTokens })
    }

    // İstem: parçalar numaralı ve konuşmacı adıyla, bağlam ayrı, terimler listede; çıktı payı kaynağa göre.
    @Test func requestNumbersPiecesAndNamesSpeakers() {
        let batch: TranscriptTranslationBatch = TranscriptTranslationBatch(
            pieces: [finalSegment(1, 65, 70, "CENTCOM is doing a great job.", person: 1), finalSegment(2, 70, 75, "Thank you.", person: 2)],
            before: [finalSegment(0, 60, 65, "Earlier remark.", person: 1)], after: []
        )
        let request: LLMRequest = transcriptTranslationRequest(batch: batch, speakerNames: [1: "Aino"], terms: ["Aino", "CENTCOM"], language: .turkish)
        #expect(request.purpose == .transcriptTranslation)
        #expect(request.userText.contains(#"<parca id="1" konusmaci="Aino" zaman="01:05">"#))
        #expect(request.userText.contains(#"<parca id="2" konusmaci="Konuşmacı 2""#) || request.userText.contains(#"<parca id="2" konusmaci="#))
        #expect(request.userText.contains("[01:00] Aino: Earlier remark."))
        #expect(request.userText.contains("Aino, CENTCOM"))
        #expect(request.jsonSchema != nil)
        #expect(request.maxTokens >= 1_024)
    }

    // Yanıt: her parçanın boş olmayan çevirisi olmalı; eksik parça yanıtı bozuk sayılır (istek yeniden yapılır).
    @Test func parsingRequiresEveryPiece() throws {
        let ok: [Int: String] = try parseTranscriptTranslations(text: #"{"ceviriler":[{"id":"2","ceviri":"İki"},{"id":"1","ceviri":" Bir "}]}"#, count: 2)
        #expect(ok == [1: "Bir", 2: "İki"])
        #expect(throws: LLMError.self) {
            try parseTranscriptTranslations(text: #"{"ceviriler":[{"id":"1","ceviri":"Bir"}]}"#, count: 2)
        }
        // Yalnızca dolgudan oluşan parçanın boş çevirisi geçerli: isteğin diğer parçaları düşmez, boş çeviri saklanmaz.
        #expect(try parseTranscriptTranslations(text: #"{"ceviriler":[{"id":"1","ceviri":"Bir"},{"id":"2","ceviri":"  "}]}"#, count: 2) == [1: "Bir", 2: ""])
        #expect(throws: LLMError.self) {
            try parseTranscriptTranslations(text: "not json", count: 1)
        }
    }

    // Sonuçlar: çevrilenler kendi parçasına yazılır, çevrilemeyenler "Tekrar dene"ye; canlı çeviri ve başka parçalar kalır.
    @Test func applyingWritesOnePerPieceAndMarksFailures() {
        let final: [StoredSegment] = [finalSegment(0, 0, 9, "One.", person: 1), finalSegment(1, 10, 19, "Two.", person: 1), finalSegment(2, 20, 29, "Three.", person: 1)]
        let record: MeetingRecord = translatedRecord(final: final, translations: ["others-0": "canlı", "final-0": "eski blok", "final-2": "kalır"])
            .with(failedTranslationKeys: ["final-2"])
        let applied: MeetingRecord = applyingTranscriptTranslations(
            record: record, pieces: Array(final[0...1]), outcomes: [.translated(["final-0": "Bir."]), .failed(keys: ["final-1"])]
        )
        #expect(applied.translations == ["others-0": "canlı", "final-0": "Bir.", "final-2": "kalır"])
        #expect(applied.failedTranslationKeys == ["final-2", "final-1"])
        let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: applied)
        #expect(paragraphs.first?.turkish == "Bir. kalır")
        #expect(paragraphs.first?.translationFailed == true)
        // Model parçayı aynen döndürdüyse (zaten not dilinde) çeviri saklanmaz.
        let same: MeetingRecord = applyingTranscriptTranslations(record: record, pieces: [final[0]], outcomes: [.translated(["final-0": "One."])])
        #expect(same.translations["final-0"] == nil)
        let filler: MeetingRecord = applyingTranscriptTranslations(record: record, pieces: [final[0]], outcomes: [.translated(["final-0": ""])])
        #expect(filler.translations["final-0"] == nil && filler.failedTranslationKeys == ["final-2"])
    }

    // Yeniden işleme: son geçiş çevirileri ve başarısızlıkları silinir, canlı çeviriler kalır.
    @Test func reprocessingDropsFinalPassTranslations() {
        let record: MeetingRecord = translatedRecord(
            final: [finalSegment(0, 0, 9, "One.", person: 1)], translations: ["others-0": "canlı", "final-0": "Bir.", "me-final-1": "x", "final-0.1": "y"]
        ).with(failedTranslationKeys: ["final-0"])
        let dropped: MeetingRecord = droppingFinalPassTranslations(record: record)
        #expect(dropped.translations == ["others-0": "canlı"])
        #expect(dropped.failedTranslationKeys == nil)
    }

    // Çeviri yalnızca toplantı çevirili izlendiyse; canlı çeviriyi kapatan kullanıcıya maliyet çıkmaz. Eski toplantı
    // (canlı çeviri hizalanmış) "Tekrar işle"de aynı kuralla çevrilir. Not dilindeki parçalar çevrilmez: karışık dilli
    // toplantıda (ana dili Türkçe, konuk İngilizce) yalnızca İngilizce parçalar.
    @Test func translatesOnlyWatchedTranslatedForeignPieces() {
        let final: [StoredSegment] = [finalSegment(0, 0, 9, "One.", person: 1)]
        #expect(wantsTranscriptTranslation(record: translatedRecord(final: final, translations: ["others-0": "canlı"])))
        #expect(!wantsTranscriptTranslation(record: translatedRecord(final: final, translations: [:])))
        #expect(wantsTranscriptTranslation(record: translatedRecord(final: final, translations: [:]).with(failedTranslationKeys: ["final-0"])))
        let segments: [StoredSegment] = [
            finalSegment(0, 0, 9, "Merhaba, başlayalım.", person: 1).with(spokenLanguage: "tr"),
            finalSegment(1, 10, 19, "Thanks for having me.", person: 2).with(spokenLanguage: "en"),
            finalSegment(2, 20, 29, "Evet.", person: 1),
        ]
        let mixed: MeetingRecord = translatedRecord(final: segments, translations: ["others-0": "canlı"]).with(finalSegments: segments, language: .turkish)
        #expect(transcriptTranslationPieces(record: mixed, language: .turkish).map(\.key) == ["final-1"])
        #expect(transcriptTranslationPieces(record: mixed, language: .english).map(\.key) == ["final-0", "final-2"])
    }

    // İstek kesintisiz konuşmadır: arada çevrilmeyen söz varsa yeni istek başlar ve o söz bağlamda görünür.
    @Test func batchesBreakAtUntranslatedPieces() {
        let all: [StoredSegment] = (0..<5).map { finalSegment($0, Double($0 * 10), Double($0 * 10 + 9), "text \($0)", person: 1) }
        let batches: [TranscriptTranslationBatch] = transcriptTranslationBatches(
            pieces: [all[0], all[1], all[3], all[4]], all: all, maxCharacters: 1_000, contextBefore: 1, contextAfter: 1
        )
        #expect(batches.map { $0.pieces.map(\.key) } == [["final-0", "final-1"], ["final-3", "final-4"]])
        #expect(batches[0].after.map(\.key) == ["final-2"])
        #expect(batches[1].before.map(\.key) == ["final-2"])
    }

    // Sağlayıcı yoksa parçalar sessizce boş kalmaz: hepsi "Tekrar dene"ye düşer, canlı bloğa geri dönülmez.
    @Test func missingProviderMarksEveryPieceFailed() async {
        let final: [StoredSegment] = [finalSegment(0, 0, 9, "One.", person: 1), finalSegment(1, 10, 19, "...", person: 1), finalSegment(2, 20, 29, "Two.", person: 1)]
        let record: MeetingRecord = translatedRecord(final: final, translations: ["others-0": "canlı"])
        let result: MeetingRecord = await translatingTranscript(record: record, llm: nil, language: .turkish, userName: "")
        // Harfsiz parça ("...") çevrilmez.
        #expect(result.failedTranslationKeys == ["final-0", "final-2"])
        #expect(transcriptParagraphs(record: result).first?.translationFailed == true)
    }

    // Çeviri sürerken toplantı değişirse (ad) değişiklik korunur; transkript değiştiyse eski çeviri uygulanmaz.
    @Test func resultAppliesOntoCurrentRecord() {
        let final: [StoredSegment] = [finalSegment(0, 0, 9, "One.", person: 1)]
        let start: MeetingRecord = translatedRecord(final: final, translations: ["others-0": "canlı"]).with(failedTranslationKeys: ["final-0"])
        let translated: MeetingRecord = start.with(translations: ["others-0": "canlı", "final-0": "Bir."]).with(failedTranslationKeys: [])
        let renamed: MeetingRecord = start.with(title: "Yeni ad")
        let merged: MeetingRecord = withTranscriptTranslations(from: translated, onto: renamed)
        #expect(merged.title == "Yeni ad" && merged.translations["final-0"] == "Bir." && merged.failedTranslationKeys == nil)
        let reprocessed: MeetingRecord = renamed.with(finalSegments: [finalSegment(0, 0, 9, "Uno.", person: 1)], language: .english)
        #expect(withTranscriptTranslations(from: translated, onto: reprocessed) == reprocessed)
    }

    // Canlı: yeniden gönderilen ses aynı konuşmayı yeni kimlikle kesinleştirirse ikinci kez çevrilmez; kapanmış
    // birimlerin boş bıraktığı yeri dolduran geç bölüm yine çevrilir.
    @Test func replayedLiveSegmentIsNotTranslatedTwice() {
        let first: LiveSegment = LiveSegment(id: SegmentID(speaker: .others, index: 0), startSec: 0, endSec: 6, text: "I hope they look at all of it.", isFinal: true, failureMessage: nil, person: nil)
        let second: LiveSegment = LiveSegment(id: SegmentID(speaker: .others, index: 1), startSec: 10, endSec: 14, text: "That is another subject.", isFinal: true, failureMessage: nil, person: nil)
        let step1: TranslationUnitStep = addingFinal(builder: .empty, segment: first, nowSec: 6, limits: liveTranslationUnitLimits)
        let step2: TranslationUnitStep = addingFinal(builder: step1.builder, segment: second, nowSec: 14, limits: liveTranslationUnitLimits)
        #expect(step1.ready.count == 1 && step2.ready.count == 1)
        let replay: LiveSegment = LiveSegment(id: SegmentID(speaker: .others, index: 2), startSec: 0.2, endSec: 5.8, text: "I hope they're looking at all of it.", isFinal: true, failureMessage: nil, person: nil)
        let replayed: TranslationUnitStep = addingFinal(builder: step2.builder, segment: replay, nowSec: 15, limits: liveTranslationUnitLimits)
        #expect(replayed.ready.isEmpty)
        // Birimin içindeki sessiz aralığı sonradan dolduran bölüm de çevrilir (birimin süresi değil, bölümlerinki sayılır).
        let a: LiveSegment = LiveSegment(id: SegmentID(speaker: .me, index: 0), startSec: 0, endSec: 3, text: "So the plan", isFinal: true, failureMessage: nil, person: nil)
        let b: LiveSegment = LiveSegment(id: SegmentID(speaker: .me, index: 1), startSec: 9, endSec: 12, text: "is ready.", isFinal: true, failureMessage: nil, person: nil)
        let unit: TranslationUnitStep = feedPair(first: a, second: b)
        #expect(unit.ready.count == 1)
        let inside: LiveSegment = LiveSegment(id: SegmentID(speaker: .me, index: 2), startSec: 4, endSec: 8, text: "we discussed yesterday", isFinal: true, failureMessage: nil, person: nil)
        #expect(addingFinal(builder: unit.builder, segment: inside, nowSec: 20, limits: liveTranslationUnitLimits).ready.count == 1)
        let gap: LiveSegment = LiveSegment(id: SegmentID(speaker: .others, index: 3), startSec: 6.5, endSec: 9.5, text: "We have a right to know.", isFinal: true, failureMessage: nil, person: nil)
        let filled: TranslationUnitStep = addingFinal(builder: replayed.builder, segment: gap, nowSec: 16, limits: liveTranslationUnitLimits)
        #expect(filled.ready.map(\.text) == ["We have a right to know."])
        #expect(isReplayedFinal(endSec: 5.8, finalizedUntilSec: 6, toleranceSec: 0.05))
        #expect(!isReplayedFinal(endSec: 7, finalizedUntilSec: 6, toleranceSec: 0.05))
        #expect(coveredShare(startSec: 0, endSec: 10, spans: [TimeSpan(startSec: 0, endSec: 4), TimeSpan(startSec: 8, endSec: 12)]) == 0.6)
    }
}
