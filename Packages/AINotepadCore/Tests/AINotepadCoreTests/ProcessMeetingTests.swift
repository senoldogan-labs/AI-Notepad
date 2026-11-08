import Foundation
import Testing
@testable import AINotepadCore

/// İşleme adımlarını sırayla toplar.
@MainActor
final class StepLog {
    var steps: [ProcessingStep] = []
}

// Yarıda kalan son geçiş: yazıya dökülen kısmın son geçişi, kalan kısmın canlı "Diğerleri" metni; "Sen" canlıdan
// buraya girmez. Geçiş tamamsa canlı metin eklenmez.
@Test func partialFinalPassKeepsLiveTail() {
    let final: [StoredSegment] = [stored("final-0", .others, 1, 10, "Alku")]
    let live: [StoredSegment] = [
        stored("live-0", .others, nil, 12, "Alku live"),
        stored("live-1", .others, nil, 3000, "Loppu"),
        stored("live-2", .me, nil, 3100, "Minä"),
    ]
    #expect(finalSegmentsWithLiveTail(final: final, live: live, coveredUntilSec: 2940).map(\.key) == ["final-0", "live-1"])
    #expect(finalSegmentsWithLiveTail(final: final, live: live, coveredUntilSec: nil).map(\.key) == ["final-0"])
}

extension CloudTests {
@Suite struct ProcessMeetingTests {
    @Test func processesRecordedMeetingIntoNote() async throws {
        let directory: URL = try temporaryDirectory()
        let others: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "others.caf"))
        try others.append(samples: try loadFixture(name: "fi-dialog"))
        others.close()
        let me: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "me.caf"))
        try me.append(samples: silence(seconds: 3))
        me.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: nil, status: .processing,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )

        let log: StepLog = await StepLog()
        let result: MeetingRecord = await processMeeting(
            record: recording,
            directory: directory,
            finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: ["Aino", "raportti"])),
            llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))),
            languageMode: .automatic,
            userName: "Doğan", profile: .empty,
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
            screens: .off,
            onStep: { (step: ProcessingStep) async -> Void in log.steps.append(step) }
        )

        // Arayüz ilerlemesi adımları sırayla alır.
        #expect(await log.steps == [.convertingAudio, .finalPass, .writingNote])
        #expect(result.status == .done, "hata: \(result.failureMessage ?? "")")
        #expect(!result.finalSegments.isEmpty)
        #expect(result.note != nil)
        #expect(result.title == result.note?.title)
        #expect(result.language == .finnish)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "others.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "others.caf").path))
    }

    // Son geçiş durdurulursa (sunucu güncel değil) not canlı metinden yazılmaz: toplantı başarısız, neden görünür.
    @Test func stoppedFinalPassFailsWithoutWritingNote() async throws {
        let directory: URL = try temporaryDirectory()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: .finnish, status: .processing,
            failureMessage: nil, liveSegments: longMeetingSegments(rounds: 1),
            finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory, finalPass: .stop(HostedClientError.serverOutdated(path: "/v1/meetings/{id}/reprocess")),
            llm: nil, languageMode: .automatic, userName: "Doğan", profile: .empty, noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
            screens: .off,
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .failed)
        #expect(result.note == nil)
        #expect(result.failureMessage?.contains("Tekrar işle") == true)
    }

    // Son geçiş başarısız olursa (ör. ElevenLabs kotası/anahtarı) not yine canlı metinden yazılır, uyarı kalır.
    @Test func finalPassFailureStillWritesNoteFromLiveText() async throws {
        let directory: URL = try temporaryDirectory()
        let others: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "others.caf"))
        try others.append(samples: try loadFixture(name: "fi-dialog"))
        others.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: .finnish, status: .processing,
            failureMessage: nil, liveSegments: longMeetingSegments(rounds: 1),
            finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory, finalPass: .run(ElevenLabsFinalTranscriber(apiKey: "gecersiz", keyterms: [])),
            llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), languageMode: .automatic, userName: "Doğan", profile: .empty,
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
            screens: .off,
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .done, "hata: \(result.failureMessage ?? "")")
        #expect(result.note != nil)
        #expect(result.finalSegments.isEmpty)
        #expect(result.notice?.contains("Tekrar işle") == true, "uyarı: \(result.notice ?? "")")
    }

    // Ağ gidip "Sen"in canlı akışı koptuysa "Sen" kaydı da son geçişten geçer: konuşma not ve transkriptte kaybolmaz.
    @Test func brokenLiveStreamTranscribesOwnAudio() async throws {
        let directory: URL = try temporaryDirectory()
        let me: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "me.caf"))
        try me.append(samples: try loadFixture(name: "fi-dialog"))
        me.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: .finnish, status: .processing,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
            engine: .cloud, notice: nil, meNeedsFinalPass: true
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory, finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: ["Aino", "raportti"])),
            llm: nil, languageMode: .fixed(.finnish), userName: "Doğan", profile: .empty,
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
            screens: .off,
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        let mine: [StoredSegment] = meetingSegments(record: result).filter { $0.speaker == .me }
        #expect(!mine.isEmpty, "uyarı: \(result.notice ?? "")")
        #expect(mine.allSatisfy { $0.person == nil })
    }

    @Test func missingAnthropicKeyFailsButKeepsTranscript() async throws {
        let directory: URL = try temporaryDirectory()
        let others: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "others.caf"))
        try others.append(samples: try loadFixture(name: "fi-dialog"))
        others.close()
        let recording: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: nil, status: .processing,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let result: MeetingRecord = await processMeeting(
            record: recording, directory: directory, finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: ["Aino", "raportti"])),
            llm: nil, languageMode: .automatic, userName: "Doğan", profile: .empty,
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [],
            screens: .off,
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .failed)
        #expect(!result.finalSegments.isEmpty)
        #expect(result.failureMessage?.contains("LLM") == true)
    }
}
}

/// Son geçişe verilen dosyaları toplar.
private final class ReceivedAudio: Sendable {
    let names: LockedState<[String]> = LockedState([])
}

/// Ağsız son geçiş: aldığı dosyanın adını yazar, "Konuşmacı 1"in 0–60 sn'lik tek bölümünü döndürür.
private struct RecordingFinalTranscriber: FinalTranscriber {
    let source: FinalPassSource
    let received: ReceivedAudio

    func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult {
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        received.names.withLock { $0.append(audioURL.lastPathComponent) }
        return FinalPassResult(
            segments: [StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 60, text: "Hei kaikki", words: nil)],
            language: .finnish, notice: nil, coveredUntilSec: nil
        )
    }
}

/// Parçanın tamamını tek konuşmacı sayan, sesten bağımsız gömme (sıralamayı ve eşlemeyi denetlemek için).
private struct WholeWindowEmbedder: VoiceEmbedder {
    func clusters(samples: [Float]) async throws -> [VoiceCluster] {
        [VoiceCluster(turns: [0...Double(samples.count) / 16000], centroid: [1, 0, 0])]
    }
}

/// Kayıt sonrası işlemenin sırası (ağsız): sunucudaki son geçiş dönüştürmeyi beklemeden kayıpsız `.caf`'ı okur, cihazdaki
/// son geçiş `.m4a`'yı; sonunda `.caf`'lar silinir ve `.m4a`'lar kalır. Ses izleri son geçişle aynı anda çıkarılsa da
/// sıralı hesapla aynıdır.
@Suite struct ProcessMeetingOrderTests {
    private func recordedMeeting(meNeedsFinalPass: Bool?) throws -> (directory: URL, record: MeetingRecord) {
        let directory: URL = try temporaryDirectory()
        for name in ["others", "me"] {
            let recorder: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "\(name).caf"))
            try recorder.append(samples: silence(seconds: 30))
            recorder.close()
        }
        let record: MeetingRecord = MeetingRecord(
            id: directory.lastPathComponent, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: .finnish, status: .processing,
            failureMessage: nil, liveSegments: [stored("live-0", .others, nil, 1, "Hei")], finalSegments: [], translations: [:], speakerNames: [:],
            note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: meNeedsFinalPass
        )
        return (directory, record)
    }

    private func process(
        record: MeetingRecord, directory: URL, transcriber: any FinalTranscriber, voiceEmbedder: (any VoiceEmbedder)?, log: StepLog
    ) async -> MeetingRecord {
        await processMeeting(
            record: record, directory: directory,
            resolveFinalPass: { () async -> FinalPassPlan in .run(transcriber) }, resolveLLM: { () async -> LLMProvider? in nil },
            languageMode: .fixed(.finnish), userName: "Doğan", profile: .empty, noteLanguage: .turkish, voiceEmbedder: voiceEmbedder, registry: [], screens: .off,
            onStep: { (step: ProcessingStep) async -> Void in log.steps.append(step) }
        )
    }

    @Test func serverFinalPassReadsLosslessRecordings() async throws {
        let (directory, record): (URL, MeetingRecord) = try recordedMeeting(meNeedsFinalPass: true)
        let received: ReceivedAudio = ReceivedAudio()
        let log: StepLog = await StepLog()
        let result: MeetingRecord = await process(
            record: record, directory: directory, transcriber: RecordingFinalTranscriber(source: .originalRecording, received: received),
            voiceEmbedder: nil, log: log
        )
        #expect(received.names.withLock { $0 } == ["others.caf", "me.caf"])
        #expect(await log.steps == [.convertingAudio, .finalPass, .writingNote])
        #expect(result.finalSegments.map(\.key) == ["final-0", "me-final-0"])
        for name in ["others", "me"] {
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(name).m4a").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(name).caf").path))
        }
    }

    @Test func deviceFinalPassReadsCompressedRecordings() async throws {
        let (directory, record): (URL, MeetingRecord) = try recordedMeeting(meNeedsFinalPass: true)
        let received: ReceivedAudio = ReceivedAudio()
        _ = await process(
            record: record, directory: directory, transcriber: RecordingFinalTranscriber(source: .compressedRecording, received: received),
            voiceEmbedder: nil, log: await StepLog()
        )
        #expect(received.names.withLock { $0 } == ["others.m4a", "me.m4a"])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "others.caf").path))
    }

    // "Tekrar işle"de (ilerleme atılır) `.caf` yok: sunucudaki son geçiş de `.m4a`'yı okur.
    @Test func reprocessingReadsCompressedRecording() async throws {
        let (directory, record): (URL, MeetingRecord) = try recordedMeeting(meNeedsFinalPass: nil)
        let received: ReceivedAudio = ReceivedAudio()
        let transcriber: RecordingFinalTranscriber = RecordingFinalTranscriber(source: .originalRecording, received: received)
        _ = await process(record: record, directory: directory, transcriber: transcriber, voiceEmbedder: nil, log: await StepLog())
        try discardProcessingProgress(directory: directory)
        _ = await process(record: record, directory: directory, transcriber: transcriber, voiceEmbedder: nil, log: await StepLog())
        #expect(received.names.withLock { $0 } == ["others.caf", "others.m4a"])
    }

    // İşleme not adımında kesildi (uygulama kapandı, iPhone'da sistem işlemeyi durdurdu): yeniden işleme son geçişin
    // kontrol noktasından sürer; ses yeniden yazıya dökülmez (yeniden faturalanmaz), not son geçiş metninden yazılır.
    // İşlenmiş toplantı saklanınca kontrol noktası silinir.
    @Test func interruptedProcessingResumesFromCheckpointWithoutSecondFinalPass() async throws {
        let (directory, record): (URL, MeetingRecord) = try recordedMeeting(meNeedsFinalPass: nil)
        let received: ReceivedAudio = ReceivedAudio()
        let transcriber: RecordingFinalTranscriber = RecordingFinalTranscriber(source: .originalRecording, received: received)
        let first: MeetingRecord = await process(record: record, directory: directory, transcriber: transcriber, voiceEmbedder: nil, log: await StepLog())
        // Not sağlayıcısı yoktu: not adımı başarısız, son geçiş kontrol noktasında.
        #expect(first.status == .failed)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "processing-checkpoint.json").path))
        // Diskteki toplantı hâlâ işlemede (son geçiş metni saklanmadan kesildi): yeniden işleme kontrol noktasından sürer.
        let log: StepLog = await StepLog()
        let resumed: MeetingRecord = await process(
            record: record.with(notice: nil), directory: directory, transcriber: transcriber, voiceEmbedder: WholeWindowEmbedder(), log: log
        )
        #expect(received.names.withLock { $0 } == ["others.caf"])
        #expect(await log.steps == [.convertingAudio, .finalPass, .writingNote])
        #expect(resumed.finalSegments.map(\.key) == ["final-0"])
        #expect(resumed.language == .finnish)
        // Ses izleri sürdürmede de çıkarılır.
        #expect(resumed.voiceprints?.isEmpty == false)
        try removeProcessingCheckpoint(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "processing-checkpoint.json").path))
        // Başka toplantının kontrol noktası kullanılmaz: son geçiş yeniden yapılır.
        let foreign: MeetingRecord = MeetingRecord(
            id: "baska-toplanti", title: "Başka", startedAt: Date(), endedAt: Date(), language: nil, status: .processing, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil,
            meNeedsFinalPass: nil
        )
        try saveProcessingCheckpoint(record: foreign, directory: directory)
        _ = await process(record: record, directory: directory, transcriber: transcriber, voiceEmbedder: nil, log: await StepLog())
        #expect(received.names.withLock { $0 } == ["others.caf", "others.m4a"])
    }

    // Kontrol noktası yazılamazsa (disk dolu) kayıpsız kayıtlar silinmez ve toplantı "başarısız" döner: "Tekrar dene"
    // son geçişi kayıtların kendisinden yeniden yapabilir.
    @Test func failedCheckpointKeepsOriginalRecordings() async throws {
        let (directory, record): (URL, MeetingRecord) = try recordedMeeting(meNeedsFinalPass: nil)
        // Kontrol noktasının yerinde bir klasör: dosya oraya yazılamaz.
        let blocker: URL = directory.appending(path: "processing-checkpoint.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appending(path: "keep"))
        let result: MeetingRecord = await process(
            record: record, directory: directory, transcriber: RecordingFinalTranscriber(source: .originalRecording, received: ReceivedAudio()),
            voiceEmbedder: nil, log: await StepLog()
        )
        #expect(result.status == .failed)
        #expect(result.failureMessage?.hasPrefix(String(localized: "İşleme ilerlemesi kaydedilemedi")) == true)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "others.caf").path))
    }

    @Test func overlappedVoiceprintsEqualSequentialOnes() async throws {
        let (directory, record): (URL, MeetingRecord) = try recordedMeeting(meNeedsFinalPass: nil)
        let result: MeetingRecord = await process(
            record: record, directory: directory, transcriber: RecordingFinalTranscriber(source: .originalRecording, received: ReceivedAudio()),
            voiceEmbedder: WholeWindowEmbedder(), log: await StepLog()
        )
        let expected: [Int: Voiceprint] = try await meetingVoiceprints(
            samples: try loadMonoSamples(url: directory.appending(path: "others.m4a")), segments: meetingSegments(record: result),
            embedder: WholeWindowEmbedder(), windowSec: 120
        )
        #expect(!expected.isEmpty)
        #expect(result.voiceprints == expected)
    }

    @Test func conversionFailureFailsMeeting() async throws {
        let (directory, record): (URL, MeetingRecord) = try recordedMeeting(meNeedsFinalPass: nil)
        try Data("bozuk".utf8).write(to: directory.appending(path: "others.caf"))
        let result: MeetingRecord = await process(
            record: record, directory: directory, transcriber: RecordingFinalTranscriber(source: .originalRecording, received: ReceivedAudio()),
            voiceEmbedder: nil, log: await StepLog()
        )
        #expect(result.status == .failed)
        #expect(result.failureMessage?.hasPrefix(String(localized: "Ses dönüştürülemedi")) == true)
        #expect(result.finalSegments.isEmpty)
    }
}
