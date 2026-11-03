import Foundation
import Testing
@testable import AINotepadCore

/// Örnekleri verilen boyutta parçalar halinde veren ve sonra biten bir akış.
func chunkedStream(samples: [Float], chunkSize: Int) -> AsyncStream<[Float]> {
    let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    var offset: Int = 0
    while offset < samples.count {
        let end: Int = min(offset + chunkSize, samples.count)
        continuation.yield(Array(samples[offset..<end]))
        offset = end
    }
    continuation.finish()
    return stream
}

/// Metinde Arap ya da Kiril harfi var mı (multi modunda yanlış yazı denetimi).
func containsArabicOrCyrillic(text: String) -> Bool {
    text.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in
        (0x0600...0x06FF).contains(scalar.value) || (0x0400...0x04FF).contains(scalar.value)
    }
}

@Suite struct DeepgramTimelineTests {
    @Test func timelineOffsetsAcrossReconnects() {
        #expect(absoluteTime(deepgramSec: 2.5, connectionStartSample: 160_000, sampleRate: 16000) == 12.5)
    }
}

extension CloudTests {
@Suite struct DeepgramStreamTests {
    @Test func streamsFinnishDialog() async throws {
        let key: String = try cloudKey(account: .deepgram)
        let audio: AsyncStream<[Float]> = chunkedStream(samples: try loadFixture(name: "fi-dialog"), chunkSize: 3200)
        var finals: [(text: String, start: Double)] = []
        var failures: [String] = []
        for await event in startDeepgramStream(apiKey: key, language: .finnish, keyterms: ["Aino", "raportti"], audio: audio).events {
            switch event {
            case .final(let text, let start, _): finals.append((text, start))
            case .failed(let message): failures.append(message)
            case .incomplete(let untranscribedSec): failures.append("sesin sonu yazıya dökülmedi: \(untranscribedSec) sn")
            case .partial: break
            }
        }
        let joined: String = finals.map(\.text).joined(separator: " ").lowercased()
        #expect(failures.isEmpty, "hatalar: \(failures)")
        #expect(finals.count >= 2, "kesin: \(finals)")
        #expect(joined.contains("raportti") || joined.contains("raportin"), "metin: \(joined)")
        #expect(finals.map(\.start) == finals.map(\.start).sorted())
        #expect(!containsArabicOrCyrillic(text: joined), "metin: \(joined)")
    }

    // Otomatik mod: İngilizce başlayan akış Fince'ye geçince Fince metin gelmeli.
    @Test func switchesLanguageMidStream() async throws {
        let key: String = try cloudKey(account: .deepgram)
        let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let stream: DeepgramStream = startDeepgramStream(apiKey: key, language: .english, keyterms: [], audio: audio)
        await stream.switchLanguage(to: .finnish)
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        for offset in stride(from: 0, to: fixture.count, by: 3200) {
            input.yield(Array(fixture[offset..<min(offset + 3200, fixture.count)]))
        }
        input.finish()
        var finals: [String] = []
        for await event in stream.events {
            if case .final(let text, _, _) = event { finals.append(text) }
            if case .failed(let message) = event { Issue.record("hata: \(message)") }
        }
        let joined: String = finals.joined(separator: " ").lowercased()
        #expect(joined.contains("raportti") || joined.contains("raportin"), "metin: \(joined)")
    }

    // Yeni diller: sabit dilde Deepgram canlı metni o dilde yazar (anahtar terimlerle de).
    @Test(arguments: [(MeetingLanguage.swedish, "sv-meeting", ["rapporten", "budgeten"]), (MeetingLanguage.german, "de-meeting", ["bericht", "budget"])])
    func streamsOtherLanguages(language: MeetingLanguage, fixture: String, words: [String]) async throws {
        let key: String = try cloudKey(account: .deepgram)
        let audio: AsyncStream<[Float]> = chunkedStream(samples: try loadFixture(name: fixture), chunkSize: 3200)
        var finals: [String] = []
        for await event in startDeepgramStream(apiKey: key, language: language, keyterms: ["Aino"], audio: audio).events {
            if case .final(let text, _, _) = event { finals.append(text) }
            if case .failed(let message) = event { Issue.record("hata: \(message)") }
        }
        let joined: String = finals.joined(separator: " ").lowercased()
        #expect(words.allSatisfy { joined.contains($0) }, "metin: \(joined)")
    }

    @Test func invalidKeyFailsWithStatus() async throws {
        let audio: AsyncStream<[Float]> = chunkedStream(samples: silence(seconds: 1), chunkSize: 3200)
        var events: [StreamingEvent] = []
        for await event in startDeepgramStream(apiKey: "gecersiz", language: .finnish, keyterms: [], audio: audio).events {
            events.append(event)
        }
        guard case .failed(let message) = events.first else {
            Issue.record("ilk olay hata değil: \(events)")
            return
        }
        #expect(message.contains("401"), "mesaj: \(message)")
    }

    // Bağlantı konuşma ortasında koparsa yeniden bağlanmalı, kesinleşmemiş ses yeniden gönderilmeli.
    @Test func forcedDisconnectKeepsTranscribing() async throws {
        let key: String = try cloudKey(account: .deepgram)
        let stream: DeepgramStream = startDeepgramStream(apiKey: key, language: .finnish, keyterms: ["Aino", "raportti"], audio: pacedStream(samples: try loadFixture(name: "fi-dialog")))
        Task {
            // 2. cümlenin ortası ("Minulla on raportti valmiina").
            try await Task.sleep(for: .seconds(4.5))
            await stream.dropConnectionForTesting()
        }
        var finals: [(text: String, start: Double)] = []
        for await event in stream.events {
            if case .final(let text, let start, _) = event { finals.append((text, start)) }
            if case .failed(let message) = event { Issue.record("hata: \(message)") }
        }
        let joined: String = finals.map(\.text).joined(separator: " ").lowercased()
        #expect(joined.contains("minulla") || joined.contains("raportti valmiina"), "metin: \(joined)")
        #expect(joined.contains("huomenna"), "metin: \(joined)")
        #expect(finals.map(\.start) == finals.map(\.start).sorted(), "başlangıçlar: \(finals.map(\.start))")
    }

    // Duraklatma (iPhone): ses 15 sn gelmez. Bağlantı kopmamalı (KeepAlive), yarım kalan cümle duraklatmada kesinleşmeli
    // (Finalize) ve sürdürünce metin aynı zaman çizgisinde (boşluksuz) sürmeli.
    @Test func idleAudioKeepsConnectionAndFinalizesLastSentence() async throws {
        let key: String = try cloudKey(account: .deepgram)
        let samples: [Float] = try loadFixture(name: "fi-dialog")
        // 2. cümlenin ortasında ("Minulla on raportti valmiina", 4,4. sn) duraklatıldı; parça sınırında.
        let cut: Int = 22 * 3200
        let gapSec: Double = 15
        let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let clock: ContinuousClock = ContinuousClock()
        let started: ContinuousClock.Instant = clock.now
        Task {
            for offset in stride(from: 0, to: samples.count, by: 3200) {
                if offset == cut {
                    try await Task.sleep(for: .seconds(gapSec))
                }
                input.yield(Array(samples[offset..<min(offset + 3200, samples.count)]))
                try await Task.sleep(for: .milliseconds(200))
            }
            input.finish()
        }
        let connectionEvents: ConnectionEventLog = ConnectionEventLog()
        let stream: DeepgramStream = startDeepgramStream(
            authorization: .apiKey(key), options: developerDeepgramListenOptions, language: .finnish, keyterms: ["raportti"],
            onConnectionEvent: { (event: DeepgramConnectionEvent) -> Void in Task { await connectionEvents.add(event: event) } }, audio: audio
        )
        let cutSec: Double = Double(cut) / 16000
        let resumedAfterSec: Double = cutSec + gapSec
        var finals: [(text: String, start: Double, end: Double, arrivedSec: Double)] = []
        for await event in stream.events {
            let elapsed: Duration = clock.now - started
            let arrived: Double = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if case .final(let text, let start, let end) = event { finals.append((text, start, end, arrived)) }
            if case .failed(let message) = event { Issue.record("hata: \(message)") }
        }
        let dropped: [DeepgramConnectionEvent] = await connectionEvents.events
        #expect(dropped.isEmpty, "bağlantı duraklatmada koptu: \(dropped)")
        // Duraklatmadan önce gönderilen cümlenin sonu duraklatma sürerken kesinleşti.
        let finalizedDuringPause: Bool = finals.contains { $0.end >= cutSec - 1 && $0.arrivedSec > cutSec + 1 && $0.arrivedSec < resumedAfterSec }
        #expect(finalizedDuringPause, "kesin sonuçlar: \(finals.map { ($0.text, $0.end, $0.arrivedSec) })")
        let joined: String = finals.map(\.text).joined(separator: " ").lowercased()
        #expect(joined.contains("huomenna"), "metin: \(joined)")
        // Zaman çizgisi gönderilen sese göredir: duraklatma metne boşluk olarak girmez.
        let totalSec: Double = Double(samples.count) / 16000
        #expect((finals.map(\.end).max() ?? 0) <= totalSec + 0.5, "son: \(finals.map(\.end).max() ?? 0), ses: \(totalSec)")
        #expect(finals.map(\.start) == finals.map(\.start).sorted(), "başlangıçlar: \(finals.map(\.start))")
    }
}
}

/// Abonelik sürümünün canlı metin hataları konuşma tanıma hizmetinin adını söylemez (adlar gizlilik politikasında).
@Suite struct HostedLiveFailureMessageTests {
    @Test func hostedMessagesNameNoProvider() {
        let errors: [CloudSTTError] = [
            .connectionFailed(service: "deepgram", reason: "akış kapandı"),
            .http(service: "deepgram", status: 401, body: ""),
            .http(service: "deepgram", status: 503, body: ""),
            .malformedMessage(service: "deepgram", body: "{}"),
        ]
        for error in errors {
            let message: String = hostedLiveFailureMessage(error: error)
            #expect(!message.isEmpty)
            #expect(!message.lowercased().contains("deepgram"), "metin: \(message)")
        }
    }
}

/// Testte bildirilen Deepgram bağlantı olayları.
private actor ConnectionEventLog {
    private(set) var events: [DeepgramConnectionEvent] = []

    func add(event: DeepgramConnectionEvent) {
        events.append(event)
    }
}
