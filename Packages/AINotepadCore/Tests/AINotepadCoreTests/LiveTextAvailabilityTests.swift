import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

/// Jeton isteklerini sayar (yeniden bağlanma denemelerini görmek için).
private actor RequestCounter {
    private(set) var count: Int = 0

    func increment() {
        count += 1
    }
}

/// Oturumun olaylarını toplar (eşzamanlı kapanıştan güvenle okunur).
private actor EventLog {
    private(set) var events: [LiveSessionEvent] = []

    func append(event: LiveSessionEvent) {
        events.append(event)
    }
}

/// Hazırlanırsa testi bozan cihaz motoru: iOS 18–25 yolunda cihaza geçilmemeli.
private struct UnexpectedLocalEngine: TranscriptionEngine {
    func detectLanguage(samples: [Float]) async throws -> [String: Float] {
        [:]
    }

    func transcribe(samples: [Float], language: MeetingLanguage) async throws -> String {
        "cihaz"
    }
}

private func availabilityConfig(directory: URL, cloudFailure: HybridCloudFailure) -> HybridLiveSessionConfig {
    HybridLiveSessionConfig(
        speakers: [.others],
        lateSpeakers: [],
        local: LiveSessionConfig(
            languageMode: .fixed(.finnish), segmenter: .live, recordingDirectory: directory,
            partialIntervalSec: 1000, minPartialSpeechSec: 1.0, languageLockAfterSec: 30, candidateLanguages: [.finnish]
        ),
        maxPendingAudioSec: 300,
        cloudFailure: cloudFailure
    )
}

@Suite struct LiveTextAvailabilityTests {
    // Başlangıç: bulut verildiyse bulut; verilmediyse (politika kapalı, bütçe, jeton yok, çevrimdışı) cihazdaki motor,
    // o da yoksa (iPhone, iOS 18–25) canlı metin yok.
    @Test func startPlanPrefersCloudThenLocalThenNothing() {
        #expect(hostedLiveStartPlan(cloudGranted: true, localSpeechAvailable: true) == .cloud)
        #expect(hostedLiveStartPlan(cloudGranted: true, localSpeechAvailable: false) == .cloud)
        #expect(hostedLiveStartPlan(cloudGranted: false, localSpeechAvailable: true) == .local)
        #expect(hostedLiveStartPlan(cloudGranted: false, localSpeechAvailable: false) == .unavailable)
    }

    // Bulut durunca: cihazda motor varsa ona geçilir, yoksa bulut yeniden denenir.
    @Test func cloudFailureReconnectsOnlyWithoutLocalSpeech() {
        #expect(hybridCloudFailure(localSpeechAvailable: true, reconnectDelaysSec: [1, 2]) == .switchToLocal)
        #expect(hybridCloudFailure(localSpeechAvailable: false, reconnectDelaysSec: [1, 2]) == .reconnectCloud(delaysSec: [1, 2]))
    }

    @Test func reconnectDelaysRepeatTheLastStep() {
        #expect(cloudReconnectDelaySec(attempt: 0, delaysSec: [1, 2, 5]) == 1)
        #expect(cloudReconnectDelaySec(attempt: 2, delaysSec: [1, 2, 5]) == 5)
        #expect(cloudReconnectDelaySec(attempt: 9, delaysSec: [1, 2, 5]) == 5)
        #expect(cloudReconnectDelaySec(attempt: 0, delaysSec: []) == 0)
        #expect(cloudReconnectDelaysSec.last == 60)
    }

    // iOS 18–25: bulut akışı durunca cihaz motoruna geçilmez; "yeniden bağlanılıyor" bir kez bildirilir, jeton geri
    // çekilerek yeniden istenir, kayıt kesintisiz sürer ve ses bitince oturum beklemeden kapanır.
    @Test func reconnectsCloudInsteadOfSwitchingToLocal() async throws {
        let directory: URL = try temporaryDirectory()
        let (me, meInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let (others, othersInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        meInput.finish()
        let refused: HostedAPIError = HostedAPIError(code: .deepgramUnavailable, rawCode: "deepgram_unavailable", status: 503, serverMessage: "", path: "/v1/live/deepgram-token")
        let requests: RequestCounter = RequestCounter()
        let source: DeepgramLiveSource = DeepgramLiveSource(
            language: .finnish, keyterms: [], options: DeepgramListenOptions(model: "nova-3", optOutOfModelImprovement: true),
            onConnectionEvent: { (_: DeepgramConnectionEvent) -> Void in }
        ) { () async throws -> String in
            await requests.increment()
            throw refused
        }
        let samples: [Float] = silence(seconds: 1)
        let handle: LiveSessionHandle = runHybridLiveSession(
            config: availabilityConfig(directory: directory, cloudFailure: .reconnectCloud(delaysSec: [0.05])),
            start: .deepgram(source),
            localEngine: { () async throws -> any TranscriptionEngine in
                Issue.record("iOS 18–25 yolunda cihaz motoru hazırlanmamalı")
                return UnexpectedLocalEngine()
            },
            recording: startHybridRecording(directory: directory, meAudio: me, othersAudio: others)
        )
        othersInput.yield(samples)
        let log: EventLog = EventLog()
        let finished: Bool = await completes(within: hangDetectionLimit) {
            for await event in handle.events {
                await log.append(event: event)
                if case .liveTextReconnecting = event {
                    // En az iki yeniden deneme görülene dek beklenir, sonra ses biter.
                    while await requests.count < 3 {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    othersInput.finish()
                }
            }
        }
        #expect(finished, "ses bittikten sonra oturum kapanmadı")
        let events: [LiveSessionEvent] = await log.events
        #expect(await requests.count >= 3)
        #expect(events.filter { if case .liveTextReconnecting = $0 { true } else { false } }.count == 1)
        #expect(!events.contains { if case .liveEngineFellBack = $0 { true } else { false } })
        #expect(events.contains(.captureEnded(speaker: .others)))
        #expect(try AVAudioFile(forReading: directory.appending(path: "others.caf")).length == AVAudioFramePosition(samples.count))
    }

    // Bulut yok, cihazda motor yok: canlı metin olmadığı açıkça bildirilir, ses kaydı sürer.
    @Test func unavailableStartSaysSoAndKeepsRecording() async throws {
        let directory: URL = try temporaryDirectory()
        let samples: [Float] = silence(seconds: 1)
        let handle: LiveSessionHandle = runHybridLiveSession(
            config: availabilityConfig(directory: directory, cloudFailure: .reconnectCloud(delaysSec: [1])),
            start: .unavailable(message: "canlı metin yok"),
            localEngine: { () async throws -> any TranscriptionEngine in
                Issue.record("canlı metin yokken cihaz motoru hazırlanmamalı")
                return UnexpectedLocalEngine()
            },
            recording: startHybridRecording(
                directory: directory, meAudio: chunkedStream(samples: [], chunkSize: 1600), othersAudio: chunkedStream(samples: samples, chunkSize: 1600)
            )
        )
        var events: [LiveSessionEvent] = []
        for await event in handle.events {
            events.append(event)
        }
        #expect(events.contains(.streamFailed(speaker: .others, message: "canlı metin yok")))
        #expect(!events.contains { if case .segment = $0 { true } else { false } })
        #expect(try AVAudioFile(forReading: directory.appending(path: "others.caf")).length == AVAudioFramePosition(samples.count))
    }
}
