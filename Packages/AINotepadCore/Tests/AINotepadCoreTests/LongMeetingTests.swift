import Foundation
import Testing
@testable import AINotepadCore

/// Sunucunun çağrı başına girdi sınırları (`server/wrangler.jsonc` `LLM_MAX_REQUEST_BYTES`, `LLM_MAX_INPUT_TOKENS`) ve
/// girdi tahmini (`server/src/llm/request.ts` `estimateInputTokens`: metin baytı / 3).
private let serverMaxRequestBytes: Int = 400_000
private let serverMaxInputTokens: Int = 100_000

/// İsteğin sunucudaki girdi tahmini (token). Saf fonksiyondur.
private func serverInputEstimate(request: LLMRequest) -> Int {
    Int((Double(request.system.utf8.count + request.userText.utf8.count) / 3).rounded(.up)) + 8
}

/// Sentetik uzun toplantı: her 5 sn'de bir, 6 kişi arasında dönen Fince benzeri (ä, ö) ~175 karakterlik bölümler.
/// Gerçek konuşma dakikada ~1.750 karakterdir (`noteChunkMaxChars` açıklaması).
private func syntheticMeeting(hours: Double) -> [StoredSegment] {
    let count: Int = Int(hours * 3600 / 5)
    let sentence: String = "Käydään läpi seuraavan vaiheen budjetti ja aikataulu, sovitaan kuka hoitaa asiakkaan esityksen ja milloin päätös tehdään hallituksessa."
    return (0..<count).map { (index: Int) -> StoredSegment in
        StoredSegment(
            key: "final-\(index)", speaker: index % 7 == 0 ? .me : .others, person: index % 7 == 0 ? nil : index % 6 + 1,
            startSec: Double(index) * 5, endSec: Double(index) * 5 + 4.5, text: "\(sentence) (\(index))", words: nil
        )
    }
}

@Suite struct LongMeetingProcessingTests {
    // 4 saatlik toplantının notu parçalara bölünür: hiçbir bölüm atlanmaz, sıra korunur ve her parça isteği (önceki
    // parçaların özetleri ve görevleri büyüdükçe de) sunucunun girdi sınırlarının altında kalır; kırpma yoktur.
    @Test func fourHourNoteChunksStayUnderServerLimits() {
        let segments: [StoredSegment] = syntheticMeeting(hours: 4)
        let totalChars: Int = segments.map(\.text.count).reduce(0, +)
        #expect(totalChars > 350_000)
        let chunks: [[StoredSegment]] = noteChunks(segments: segments, maxChars: noteChunkMaxChars)
        #expect(chunks.flatMap { $0 }.map(\.key) == segments.map(\.key))
        #expect(chunks.count >= 18 && chunks.count <= 30)
        // En kötü bağlam: son parçada önceki tüm parçaların özetleri (~600 karakter) ve 150 görev.
        let summary: String = String(repeating: "Tiivistelmä keskustelusta ja päätöksistä. ", count: 14)
        let state: ChunkedNoteState = ChunkedNoteState(
            partSummaries: (0..<chunks.count).map { "[\($0 * 12):00–\($0 * 12 + 12):00] \(summary)" },
            decisions: (0..<60).map { "Päätös numero \($0): budjetti hyväksytään ja aikataulu pidetään." },
            tasks: (0..<150).map { NoteTask(owner: "Aino", description: "Valmistele esitys asiakkaalle numero \($0) ja lähetä se tiimille", dueDate: "2026-11-20", isMine: false) },
            glossary: [], openQuestions: []
        )
        for (index, chunk) in chunks.enumerated() {
            let request: LLMRequest = noteChunkRequest(
                chunk: chunk, part: index + 1, partCount: chunks.count, state: state, speakerNames: [1: "Aino"], userName: "Doğan",
                template: .general, myNotes: "", language: .turkish
            )
            #expect(request.userText.utf8.count + request.system.utf8.count < serverMaxRequestBytes)
            #expect(serverInputEstimate(request: request) < serverMaxInputTokens)
            #expect(request.maxTokens <= 16000)
        }
        let overview: LLMRequest = noteOverviewRequest(state: state, userName: "Doğan", template: .general, myNotes: "", language: .turkish, screens: [])
        #expect(serverInputEstimate(request: overview) < serverMaxInputTokens)
        // Abonelik sunucusunda (büyük bağlam) özetler kısaltılmaz.
        #expect(overview.userText.contains(state.partSummaries[chunks.count - 1]))
    }

    // Konuşmacı incelemesi 4 saatlik transkriptte sunucunun sınırına sığacak kadar bölüm seçer: her kişi görünür, her
    // kişinin ilk sözleri girer, sıra korunur; kısa toplantıda transkriptin tamamı gider.
    @Test func speakerReviewFitsFourHourMeeting() throws {
        let segments: [StoredSegment] = syntheticMeeting(hours: 4)
        let chosen: [StoredSegment] = speakerReviewSegments(segments: segments, maxBytes: speakerReviewMaxTranscriptBytes)
        #expect(chosen.count < segments.count)
        #expect(chosen.map { $0.text.utf8.count + 24 }.reduce(0, +) <= speakerReviewMaxTranscriptBytes)
        #expect(chosen.map(\.startSec) == chosen.map(\.startSec).sorted())
        #expect(Set(chosen.compactMap(\.person)) == Set(segments.compactMap(\.person)))
        // Toplantının sonu da incelenir (eşit aralık).
        #expect((chosen.last?.startSec ?? 0) > 3.5 * 3600)
        for person in 1...6 {
            let first: [String] = segments.filter { $0.person == person }.prefix(speakerReviewIntroductionSegments).map(\.key)
            #expect(Set(first).isSubset(of: Set(chosen.map(\.key))))
        }
        let request: LLMRequest = try #require(
            speakerReviewRequest(segments: segments, speakerNames: [:], userName: "Doğan", attendees: [], language: .turkish)
        )
        #expect(serverInputEstimate(request: request) < serverMaxInputTokens)
        let short: [StoredSegment] = syntheticMeeting(hours: 0.25)
        #expect(speakerReviewSegments(segments: short, maxBytes: speakerReviewMaxTranscriptBytes).map(\.key) == short.map(\.key))
    }

    // 4 saatlik kaydın ses boyutu ve son geçiş parçaları: 16 kHz mono 16 bit ~115 MB/saat; 60 dakikalık, bir dakika
    // örtüşen beş parça kaydın tamamını kapsar ve yazılan toplam ses sunucunun toplantı ses hakkına (en çok süre + her
    // `chunkStepSeconds` (2900 sn) için 60 sn örtüşme payı) sığar.
    @Test func fourHourRecordingChunksFitServerAudioAllowance() {
        let seconds: Int = 4 * 3600
        let totalSamples: Int = seconds * hostedTranscribeSampleRate
        #expect(totalSamples * 2 == 460_800_000)
        let spans: [AudioChunkSpan] = wavChunkSpans(
            totalSamples: totalSamples, maxSamples: Int(hostedFlacChunkMaxSec) * hostedTranscribeSampleRate,
            overlapSamples: Int(hostedChunkOverlapSec) * hostedTranscribeSampleRate
        )
        #expect(spans.count == 5)
        #expect(spans.first?.startSample == 0)
        #expect(spans.last.map { $0.startSample + $0.sampleCount } == totalSamples)
        let writtenSec: Int = spans.map(\.sampleCount).reduce(0, +) / hostedTranscribeSampleRate
        let serverAllowance: Int = seconds + seconds / 2900 * 60
        #expect(writtenSec <= serverAllowance)
        // FLAC parçası sunucunun yükleme sınırına (95 MB) en kötü durumda (sıkıştırılamayan ses) da 60 dakikada sığmaz:
        // kodlayıcı parçayı kısaltır (`shortenedFlacSampleCount`); kısalan parçalarla da toplam pay içinde kalır.
        let shortSpans: [AudioChunkSpan] = wavChunkSpans(
            totalSamples: totalSamples, maxSamples: maxSamplesPerWavChunk(maxBytes: hostedTranscribeMaxBytes),
            overlapSamples: Int(hostedChunkOverlapSec) * hostedTranscribeSampleRate
        )
        #expect(shortSpans.map(\.sampleCount).reduce(0, +) / hostedTranscribeSampleRate <= serverAllowance)
    }

    // Son geçiş parça ilerlemesi: aynı kayıt (örnek sayısı) ve aynı parça sınırlarında kullanılır; parça yeniden
    // yazılınca sonrakiler atılır; başka kaydın ilerlemesi yok sayılır.
    @Test func finalPassProgressResumesOnlyMatchingChunks() throws {
        let span0: AudioChunkSpan = AudioChunkSpan(startSample: 0, sampleCount: 57_600_000)
        let span1: AudioChunkSpan = AudioChunkSpan(startSample: 56_640_000, sampleCount: 57_600_000)
        var progress: HostedFinalPassProgress = usableFinalPassProgress(progress: nil, totalSamples: 230_400_000)
        #expect(progress.chunks.isEmpty)
        progress = recordingChunk(progress: progress, index: 0, chunk: HostedChunkProgress(startSample: 0, sampleCount: 57_600_000, uploadKey: "k0", response: Data("{}".utf8)))
        progress = recordingChunk(progress: progress, index: 1, chunk: HostedChunkProgress(startSample: 56_640_000, sampleCount: 57_600_000, uploadKey: "k1", response: nil))
        #expect(resumableChunk(progress: progress, index: 0, span: span0)?.response == Data("{}".utf8))
        // Yarıda kalan parça aynı anahtarla yeniden gönderilir (sunucu sonucu yeniden faturalamadan döndürür).
        #expect(resumableChunk(progress: progress, index: 1, span: span1)?.uploadKey == "k1")
        #expect(resumableChunk(progress: progress, index: 1, span: AudioChunkSpan(startSample: 1, sampleCount: 57_600_000)) == nil)
        #expect(resumableChunk(progress: progress, index: 2, span: span1) == nil)
        // İlk parça yeniden yazılınca sonrakilerin kaydı atılır.
        #expect(recordingChunk(progress: progress, index: 0, chunk: HostedChunkProgress(startSample: 0, sampleCount: 1, uploadKey: "k2", response: nil)).chunks.count == 1)
        #expect(usableFinalPassProgress(progress: progress, totalSamples: 1).chunks.isEmpty)

        let directory: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-progress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url: URL = hostedFinalPassProgressURL(audioURL: directory.appending(path: "others.caf"))
        #expect(url.lastPathComponent == "final-pass-others.json")
        saveFinalPassProgress(progress: progress, url: url)
        #expect(loadFinalPassProgress(url: url) == progress)
        try Data("bozuk".utf8).write(to: directory.appending(path: "final-pass-me.json"))
        #expect(loadFinalPassProgress(url: directory.appending(path: "final-pass-me.json")) == nil)
        try removeFinalPassProgress(directory: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    // Kaydı bitmiş toplantının notu `meeting_not_active` alırsa toplantı yeniden açılır; canlı çağrı ve hesap çağrısı
    // ya da başka hata açılmaz.
    @Test func onlyRecordedMeetingCallsReopenOnClosedSession() {
        let closed: LLMError = .hosted(HostedAPIError(code: .meetingNotActive, rawCode: "meeting_not_active", status: 403, serverMessage: "", path: "/v1/llm/messages"))
        let budget: LLMError = .hosted(HostedAPIError(code: .meetingBudgetExhausted, rawCode: "meeting_budget_exhausted", status: 429, serverMessage: "", path: "/v1/llm/messages"))
        #expect(recordedMeetingToReopen(scope: .recordedMeeting(serverMeetingID: "m1"), error: closed) == "m1")
        #expect(recordedMeetingToReopen(scope: .recordedMeeting(serverMeetingID: "m1"), error: budget) == nil)
        #expect(recordedMeetingToReopen(scope: .meeting, error: closed) == nil)
        #expect(recordedMeetingToReopen(scope: .account, error: closed) == nil)
        #expect(recordedMeetingToReopen(scope: .recordedMeeting(serverMeetingID: "m1"), error: URLError(.timedOut)) == nil)
    }

    // Uzun kesintiden sonra biriken ses (30 dakika ≈ 29 milyon örnek) yarım saniyelik parçalarla doğrusal sürede
    // gönderilir; yeniden bağlanmada geri alınan parçalar başa döner ve sıra korunur.
    @Test func sampleQueueDrainsLongBacklogLinearly() async {
        let drained: SampleQueueDrain = await offCooperativePool { () -> SampleQueueDrain in
            var queue: SampleQueue = SampleQueue()
            let backlog: [Float] = (0..<(30 * 60 * 16000)).map { Float($0 % 1000) }
            queue.append(contentsOf: backlog)
            let clock: ContinuousClock = ContinuousClock()
            var sent: Int = 0
            var lastFirst: Float = -1
            let elapsed: Duration = clock.measure {
                while !queue.isEmpty {
                    let chunk: [Float] = queue.popFront(maxCount: 8000)
                    sent += chunk.count
                    lastFirst = chunk.first ?? -1
                }
            }
            return SampleQueueDrain(sent: sent, total: backlog.count, lastFirst: lastFirst, expectedLastFirst: backlog[backlog.count - 8000], elapsed: elapsed)
        }
        #expect(drained.sent == drained.total)
        #expect(drained.lastFirst == drained.expectedLastFirst)
        #expect(drained.elapsed < .seconds(5))
        var queue: SampleQueue = SampleQueue()
        queue.append(contentsOf: [1, 2, 3, 4])
        let taken: [Float] = queue.popFront(maxCount: 3)
        queue.prepend(taken)
        #expect(queue.samples == [1, 2, 3, 4])
        #expect(queue.count == 4)
    }

    // Açılışta yalnızca işlenirken kalan ve sunucu oturumuna bağlı toplantılar kendiliğinden sürdürülür.
    @Test func onlyLinkedProcessingMeetingsResume() {
        let make: (String, MeetingStatus) -> MeetingRecord = { (id: String, status: MeetingStatus) -> MeetingRecord in
            MeetingRecord(
                id: id, title: id, startedAt: Date(), endedAt: Date(), language: nil, status: status, failureMessage: nil, liveSegments: [],
                finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
            )
        }
        let records: [MeetingRecord] = [make("a", .processing), make("b", .processing), make("c", .recording), make("d", .done)]
        #expect(processingToResume(records: records, linkedRecordIDs: ["a", "c", "d"]).map(\.id) == ["a"])
    }
}

/// Uzun birikimin boşaltılma sonucu (`sampleQueueDrainsLongBacklogLinearly`).
private struct SampleQueueDrain: Sendable {
    let sent: Int
    let total: Int
    let lastFirst: Float
    let expectedLastFirst: Float
    let elapsed: Duration
}
