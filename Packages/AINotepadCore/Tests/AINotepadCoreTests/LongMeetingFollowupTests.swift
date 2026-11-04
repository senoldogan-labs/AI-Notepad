import Foundation
import Testing
@testable import AINotepadCore

/// Süre ölçümlerinin sınır çarpanı: paylaşılan CI makineleri (GitHub `CI=true` verir) geliştirme Mac'inden yavaştır.
private let performanceLimitScale: Double = ProcessInfo.processInfo.environment["CI"] == "true" ? 2 : 1

/// Saniye cinsinden geçen süre.
private func seconds(duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// 4 saatlik kayıt sürerken alınan kontrol noktası: her 5 sn'de bir bölüm (2 880 bölüm), her bölümde 14 zamanlı kelime
/// ve çevirisi; uzun bir toplantının `meeting.json`'u (~birkaç MB).
private func fourHourRecordingCheckpoint() -> MeetingRecord {
    let words: [String] = ["projekti", "aikataulu", "budjetti", "asiakas", "raportti", "viikko", "testaus", "julkaisu", "palaveri", "tehtävä", "sopimus", "tiimi", "laatu", "riski"]
    let segments: [StoredSegment] = (0..<2880).map { (index: Int) -> StoredSegment in
        let start: Double = Double(index) * 5
        let stored: [StoredWord] = (0..<14).map { (word: Int) -> StoredWord in
            StoredWord(text: words[(index + word) % words.count], startSec: start + Double(word) * 0.3, endSec: start + Double(word) * 0.3 + 0.25)
        }
        return StoredSegment(
            key: "others-\(index)", speaker: .others, person: index % 4, startSec: start, endSec: start + 4.5,
            text: stored.map(\.text).joined(separator: " "), words: stored
        )
    }
    let translations: [String: String] = Dictionary(uniqueKeysWithValues: segments.map { ($0.key, "Bölüm \($0.key) için Türkçe çeviri cümlesi") })
    return MeetingRecord(
        id: "20261104-090000", title: "Dört saatlik çalıştay", startedAt: Date(timeIntervalSince1970: 1_793_000_000), endedAt: nil,
        language: .finnish, status: .recording, failureMessage: nil, liveSegments: segments, finalSegments: [], translations: translations,
        speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

private func removeDirectory(url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("geçici klasör silinemedi: \(error)")
    }
}

@MainActor @Suite(.serialized) struct CheckpointWriteTests {
    // Önce: kontrol noktası ana aktörde kodlanıp yazılıyordu (4 saatte onlarca ms takılma). Sonra: ana aktör yalnızca sıra
    // alıp görev kurar; kodlama ve yazım arka planda. İkisi de ölçülür ve yazdırılır; yazılan dosya son anlık görüntüdür.
    @Test func fourHourCheckpointDoesNotBlockMainActor() async throws {
        let directory: URL = try temporaryDirectory()
        defer { removeDirectory(url: directory) }
        let record: MeetingRecord = fourHourRecordingCheckpoint()
        let clock: ContinuousClock = ContinuousClock()
        let before: Double = try (0..<3).map { (_: Int) throws -> Double in
            seconds(duration: try clock.measure { try saveMeeting(record: record, directory: directory) })
        }.min() ?? .infinity
        let size: Int = try Data(contentsOf: directory.appending(path: meetingFileName)).count
        let writer: MeetingCheckpointWriter = MeetingCheckpointWriter()
        var after: Double = .infinity
        for _ in 0..<3 {
            let elapsed: Duration = clock.measure {
                writer.write(record: record, directory: directory) { (error: any Error) -> Void in Issue.record("kontrol noktası yazılamadı: \(error)") }
            }
            after = min(after, seconds(duration: elapsed))
            await writer.drain()
        }
        print("4 saatlik kontrol noktası (\(size / 1_000_000) MB): ana aktörde kodlama + yazma \(before * 1000) ms → arka plana devir \(after * 1000) ms")
        #expect(try loadMeeting(directory: directory) == record)
        #expect(after < 0.005 * performanceLimitScale)
        #expect(after * 10 < before)
    }

    // Arka plandaki eski anlık görüntü, sonradan alınıp ana aktörde yazılan (kaydın bitişi) yeninin üstüne yazılmaz.
    @Test func olderSnapshotNeverOverwritesNewer() async throws {
        let directory: URL = try temporaryDirectory()
        defer { removeDirectory(url: directory) }
        let recording: MeetingRecord = fourHourRecordingCheckpoint()
        let finished: MeetingRecord = recording.with(status: .processing, failureMessage: nil)
        let writer: MeetingCheckpointWriter = MeetingCheckpointWriter()
        writer.write(record: recording, directory: directory) { (error: any Error) -> Void in Issue.record("kontrol noktası yazılamadı: \(error)") }
        try saveMeeting(record: finished, directory: directory)
        await writer.drain()
        #expect(try loadMeeting(directory: directory).status == .processing)
    }

    @Test func ticketsWriteInClaimOrder() throws {
        let directory: URL = try temporaryDirectory()
        defer { removeDirectory(url: directory) }
        let first: MeetingRecord = fourHourRecordingCheckpoint().with(title: "ilk")
        let second: MeetingRecord = first.with(title: "ikinci")
        let older: MeetingWriteTicket = claimMeetingWrite(directory: directory)
        let newer: MeetingWriteTicket = claimMeetingWrite(directory: directory)
        #expect(try saveMeeting(record: second, directory: directory, ticket: newer))
        #expect(try !saveMeeting(record: first, directory: directory, ticket: older))
        #expect(try loadMeeting(directory: directory).title == "ikinci")
    }
}

@Suite struct LiveTranscriptViewTests {
    // Kayıt ekranı görünümü tek seferde kurulur ve ayrı ayrı hesaplananlarla aynıdır.
    @Test func viewMatchesSeparateComputations() {
        let transcript: [LiveSegment] = (0..<12).map { (index: Int) -> LiveSegment in
            LiveSegment(
                id: SegmentID(speaker: .others, index: index), startSec: Double(index), endSec: Double(index) + 0.9,
                text: index == 5 ? "" : "cümle \(index)", isFinal: index < 11, failureMessage: nil, person: index / 4
            )
        }
        let corrections: SpeakerCorrections = SpeakerCorrections.none.merging(person: 2, into: 0)
        let view: LiveTranscriptView = liveTranscriptView(transcript: transcript, corrections: corrections)
        let corrected: [LiveSegment] = applyCorrections(transcript: transcript, corrections: corrections)
        #expect(view.corrected == corrected)
        #expect(view.blocks == groupBySpeaker(transcript: corrected.filter { !$0.text.isEmpty }))
        #expect(view.persons == [0, 1])
    }
}

@Suite struct RecordingDiskSpaceTests {
    // Boyutlar kodun yazdığı biçimlerden: `.caf` 16 kHz mono 16-bit (saatte 115,2 MB), `.m4a` 32 kbps (saatte 14,4 MB).
    @Test func bytesPerSecondFollowWrittenFormats() {
        #expect(cafBytesPerSecond * 3600 == 115_200_000)
        #expect(m4aBytesPerSecond * 3600 == 14_400_000)
        #expect(recordingBytesPerSecond(streams: 2) == 72_000)
    }

    @Test func fourHourMacMeetingNeedsAboutOnePointThreeGigabytes() {
        // Mac: "Sen" ve "Diğerleri" iki akış; 4 saat = 2 × 4 × 129,6 MB + 300 MB işleme ve güvenlik payı.
        let needed: Int64 = Int64(expectedRecordingSec) * recordingBytesPerSecond(streams: 2) + finalPassChunkReserveBytes + diskSafetyMarginBytes
        #expect(needed == 1_336_800_000)
        #expect(recordingDiskSpace(availableBytes: needed, expectedDurationSec: expectedRecordingSec, streams: 2) == .enough)
        #expect(recordingDiskSpace(availableBytes: needed - 1_000_000, expectedDurationSec: expectedRecordingSec, streams: 2) == .low(recordableMinutes: 239))
    }

    @Test func tooLittleSpaceRefusesToStart() {
        // iPhone tek akış: 5 dakikalık kayıt 10,8 MB + 300 MB pay.
        #expect(recordingDiskSpace(availableBytes: 300_000_000, expectedDurationSec: expectedRecordingSec, streams: 1) == .full)
        #expect(recordingDiskSpace(availableBytes: 310_800_000, expectedDurationSec: expectedRecordingSec, streams: 1) == .low(recordableMinutes: 5))
        #expect(recordingDiskSpace(availableBytes: 0, expectedDurationSec: expectedRecordingSec, streams: 1) == .full)
    }

    @Test func recordingStopsBeforeDiskIsFull() {
        // 2 saat kaydedildi (iPhone): dönüştürme 28,8 MB, sonraki iki denetim aralığı 2,16 MB, pay 300 MB.
        let threshold: Int64 = 28_800_000 + 2_160_000 + 300_000_000
        #expect(shouldStopRecordingForDiskSpace(availableBytes: threshold - 1, recordedSec: 7200, streams: 1, checkIntervalSec: diskSpaceCheckIntervalSec))
        #expect(!shouldStopRecordingForDiskSpace(availableBytes: threshold, recordedSec: 7200, streams: 1, checkIntervalSec: diskSpaceCheckIntervalSec))
    }

    @Test func readsFreeSpaceOfTemporaryVolume() throws {
        let directory: URL = try temporaryDirectory()
        defer { removeDirectory(url: directory) }
        #expect(try availableCapacityForImportantUsage(directory: directory) > 0)
    }
}

@Suite struct LiveTranslationQueueTests {
    // Çeviri toplantının ortasında açıldı: 1…5 birikmiş; sonra yeni konuşma 100, 101 geldi. Yeni konuşma önce ve geliş
    // sırasıyla, birikmiş en yeniden eskiye; birikmiş işler en çok `backlogSlots` yer kullanır.
    @Test func newSpeechFirstThenBacklogNewestFirst() {
        var queue: LiveTranslationQueue<Int> = .empty
        for job in 1...5 {
            queue = queue.adding(job: job, lane: .backlog)
        }
        queue = queue.adding(job: 100, lane: .live).adding(job: 101, lane: .live)
        var order: [Int] = []
        var lanes: [TranslationLane] = []
        while let next = queue.next(backlogInFlight: 0, backlogSlots: 3) {
            order.append(next.job)
            lanes.append(next.lane)
            queue = next.queue
        }
        #expect(order == [100, 101, 5, 4, 3, 2, 1])
        #expect(lanes == [.live, .live, .backlog, .backlog, .backlog, .backlog, .backlog])
        #expect(queue.isEmpty)
    }

    @Test func backlogLeavesASlotForNewSpeech() {
        let queue: LiveTranslationQueue<Int> = LiveTranslationQueue<Int>.empty.adding(job: 1, lane: .backlog).adding(job: 2, lane: .backlog)
        let slots: Int = backlogTranslationSlots(maxParallel: 4)
        #expect(slots == 3)
        // Üç birikmiş çeviri sürüyor: dördüncü yer yeni konuşmanın.
        #expect(queue.next(backlogInFlight: 3, backlogSlots: slots) == nil)
        #expect(queue.adding(job: 9, lane: .live).next(backlogInFlight: 3, backlogSlots: slots)?.job == 9)
        #expect(queue.next(backlogInFlight: 2, backlogSlots: slots)?.job == 2)
        #expect(backlogTranslationSlots(maxParallel: 1) == 1)
    }
}

@Suite struct AutomaticRetryTests {
    private func failedRecord(id: String, kind: ProcessingFailureKind?, retries: AutomaticRetries?) -> MeetingRecord {
        MeetingRecord(
            id: id, title: id, startedAt: Date(timeIntervalSince1970: 1_793_000_000 + Double(id.count)), endedAt: nil, language: .turkish,
            status: .failed, failureMessage: "Not oluşturulamadı", liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
            note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        .with(failureKind: kind)
        .with(automaticRetries: retries)
    }

    @Test func transientAndPermanentErrors() {
        let notActive: HostedAPIError = HostedAPIError(code: .meetingNotActive, rawCode: "meeting_not_active", status: 409, serverMessage: "", path: "/v1/llm")
        let upstream: HostedAPIError = HostedAPIError(code: nil, rawCode: "http_502", status: 502, serverMessage: "", path: "/v1/llm")
        let limit: HostedAPIError = HostedAPIError(code: .reprocessLimitReached, rawCode: "reprocess_limit_reached", status: 403, serverMessage: "", path: "/v1/meetings/x/reprocess")
        #expect(processingFailureKind(error: notActive) == .transient)
        #expect(processingFailureKind(error: LLMError.hosted(notActive)) == .transient)
        #expect(processingFailureKind(error: upstream) == .transient)
        #expect(processingFailureKind(error: LLMError.http(status: 529, body: "", model: "m", requestID: nil)) == .transient)
        #expect(processingFailureKind(error: URLError(.networkConnectionLost)) == .transient)
        #expect(processingFailureKind(error: URLError(.notConnectedToInternet)) == .transient)
        #expect(processingFailureKind(error: CancellationError()) == .transient)
        #expect(processingFailureKind(error: HostedClientError.network(path: "/v1/llm", reason: "offline")) == .transient)
        #expect(processingFailureKind(error: limit) == .permanent)
        #expect(processingFailureKind(error: LLMError.http(status: 400, body: "", model: "m", requestID: nil)) == .permanent)
        #expect(processingFailureKind(error: AudioCaptureError.recorderFailed(path: "me.caf", reason: "yok")) == .permanent)
        #expect(processingFailureKind(error: LLMError.truncated(model: "m")) == .permanent)
    }

    @Test func statusChangeClearsFailureKind() {
        let record: MeetingRecord = failedRecord(id: "a", kind: .transient, retries: nil)
        #expect(record.with(status: .processing, failureMessage: nil).failureKind == nil)
    }

    @Test func selectsOnlyDueTransientLinkedFailures() {
        let now: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh: MeetingRecord = failedRecord(id: "fresh", kind: .transient, retries: nil)
        let waiting: MeetingRecord = failedRecord(id: "waiting", kind: .transient, retries: AutomaticRetries(count: 1, lastAttemptAt: now.addingTimeInterval(-60)))
        let due: MeetingRecord = failedRecord(id: "due-one", kind: .transient, retries: AutomaticRetries(count: 1, lastAttemptAt: now.addingTimeInterval(-121)))
        let capped: MeetingRecord = failedRecord(id: "capped", kind: .transient, retries: AutomaticRetries(count: automaticRetryLimit, lastAttemptAt: .distantPast))
        let permanent: MeetingRecord = failedRecord(id: "permanent", kind: .permanent, retries: nil)
        let unknown: MeetingRecord = failedRecord(id: "unknown", kind: nil, retries: nil)
        let unlinked: MeetingRecord = failedRecord(id: "unlinked", kind: .transient, retries: nil)
        let noAudio: MeetingRecord = failedRecord(id: "no-audio", kind: .transient, retries: nil).withAudioDeleted()
        let records: [MeetingRecord] = [fresh, waiting, due, capped, permanent, unknown, unlinked, noAudio]
        let linked: Set<String> = Set(records.map(\.id)).subtracting(["unlinked"])
        #expect(meetingsToRetryAutomatically(records: records, linkedRecordIDs: linked, now: now).map(\.id) == ["fresh", "due-one"])
    }

    @Test func backoffGrowsAndAttemptsAreCounted() {
        #expect([1, 2, 3, 4].map { automaticRetryDelaySec(count: $0) } == [120, 600, 1800, 7200])
        let now: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let started: MeetingRecord = startingAutomaticRetry(record: failedRecord(id: "a", kind: .transient, retries: AutomaticRetries(count: 2, lastAttemptAt: .distantPast)), now: now)
        #expect(started.status == .processing)
        #expect(started.failureKind == nil)
        #expect(started.automaticRetries == AutomaticRetries(count: 3, lastAttemptAt: now))
    }
}
