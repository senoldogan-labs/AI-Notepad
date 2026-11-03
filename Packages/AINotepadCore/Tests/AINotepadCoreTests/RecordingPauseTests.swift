import Foundation
import Testing
@testable import AINotepadCore

struct RecordingPauseTests {
    private let rate: Int = 16000

    @Test func keptRangesCutPausedPartsOutOfChunk() {
        // Parça 1000…2600; duraklatma 1500…2000: başı ve sonu kalır.
        #expect(keptRanges(chunkStart: 1000, count: 1600, pauses: [PausedSpan(start: 1500, end: 2000)]) == [0..<500, 1000..<1600])
        // Süren duraklatma parçanın ortasında başladı: yalnız başı kalır.
        #expect(keptRanges(chunkStart: 1000, count: 1600, pauses: [PausedSpan(start: 1200, end: nil)]) == [0..<200])
        // Parça tümüyle duraklatmada: hiçbir şey kalmaz.
        #expect(keptRanges(chunkStart: 1000, count: 1600, pauses: [PausedSpan(start: 500, end: nil)]).isEmpty)
        // Duraklatma parçadan önce bitti: parça olduğu gibi.
        #expect(keptRanges(chunkStart: 1000, count: 1600, pauses: [PausedSpan(start: 100, end: 900)]) == [0..<1600])
        // Bir parçaya iki duraklatma düştü (kesinti sonrası toplu sessizlik dolgusu).
        let spans: [PausedSpan] = [PausedSpan(start: 1100, end: 1200), PausedSpan(start: 2000, end: 2100)]
        #expect(keptRanges(chunkStart: 1000, count: 1600, pauses: spans) == [0..<100, 200..<1000, 1100..<1600])
    }

    @Test func pausingAndResumingKeepSpansOrdered() {
        let paused: [PausedSpan] = pausing(pauses: [], at: 32000)
        #expect(paused == [PausedSpan(start: 32000, end: nil)])
        // İkinci "Duraklat" süren duraklatmayı değiştirmez.
        #expect(pausing(pauses: paused, at: 40000) == paused)
        // Konum tahmini geri sıçrasa da aralık başlangıcından önce kapanmaz.
        #expect(resuming(pauses: paused, at: 31000) == [PausedSpan(start: 32000, end: 32000)])
        let resumed: [PausedSpan] = resuming(pauses: paused, at: 48000)
        #expect(resumed == [PausedSpan(start: 32000, end: 48000)])
        // Duraklatılmamışken "Devam" değiştirmez; yeni duraklatma öncekinin sonundan geri gitmez.
        #expect(resuming(pauses: resumed, at: 50000) == resumed)
        #expect(pausing(pauses: resumed, at: 47000) == resumed + [PausedSpan(start: 48000, end: nil)])
    }

    @Test func keptTimelineSubtractsPausedTime() {
        // 2. sn'den 5. sn'ye duraklatıldı, 8. sn'de yeniden duraklatıldı (sürüyor).
        let spans: [PausedSpan] = [PausedSpan(start: 2 * rate, end: 5 * rate), PausedSpan(start: 8 * rate, end: nil)]
        #expect(pausedSamples(before: 1 * rate, pauses: spans) == 0)
        #expect(keptSample(alignedSample: 3 * rate, pauses: spans) == 2 * rate)
        #expect(keptSample(alignedSample: 7 * rate, pauses: spans) == 4 * rate)
        // Süren duraklatmada kaydedilen ses ilerlemez.
        #expect(keptSample(alignedSample: 20 * rate, pauses: spans) == 5 * rate)
    }

    @Test func gateDropsAudioAfterPauseAndKeepsItAfterResume() {
        let origin: ContinuousClock.Instant = .now
        let gate: RecordingPauseGate = RecordingPauseGate(sampleRate: rate, origin: origin)
        // 0,1 sn'lik parçalar zamanında geliyor.
        #expect(gate.admit(count: 1600, at: origin + .milliseconds(100)) == [0..<1600])
        #expect(gate.admit(count: 1600, at: origin + .milliseconds(200)) == [0..<1600])
        // 0,25. sn'de duraklatıldı: sıradaki parçanın ilk 0,05 sn'si kalır.
        gate.pause(at: origin + .milliseconds(250))
        #expect(gate.isPaused)
        #expect(gate.admit(count: 1600, at: origin + .milliseconds(300)) == [0..<800])
        #expect(gate.admit(count: 1600, at: origin + .milliseconds(400)).isEmpty)
        // İşaretlenen an duraklatmada ilerlemez.
        #expect(gate.keptSeconds(at: origin + .milliseconds(1000)) == 0.25)
        // 0,45. sn'de sürdü: sıradaki parçanın son 0,05 sn'si kalır.
        gate.resume(at: origin + .milliseconds(450))
        #expect(!gate.isPaused)
        #expect(gate.admit(count: 1600, at: origin + .milliseconds(500)) == [800..<1600])
        #expect(gate.admit(count: 1600, at: origin + .milliseconds(600)) == [0..<1600])
        #expect(gate.pauses == [PausedSpan(start: 4000, end: 7200)])
        // 0,6 sn hizalanmış ses − 0,2 sn duraklatma.
        #expect(gate.keptSeconds(at: origin + .milliseconds(600)) == 0.4)
    }

    @Test func pauseDuringInterruptionDropsOnlyPausedPartOfSilenceFill() {
        // Kesinti (çağrı) 0,2. sn'de başladı: parça gelmiyor. 1. sn'de duraklatıldı, 2. sn'de sürdü; kesinti 3. sn'de bitti
        // ve hizalama 0,2…3 sn arasını tek seferde sessizlikle doldurdu. Yalnız duraklatılan 1…2 sn atılır.
        let origin: ContinuousClock.Instant = .now
        let gate: RecordingPauseGate = RecordingPauseGate(sampleRate: rate, origin: origin)
        #expect(gate.admit(count: 3200, at: origin + .milliseconds(200)) == [0..<3200])
        gate.pause(at: origin + .seconds(1))
        gate.resume(at: origin + .seconds(2))
        // Dolgu 1 sn'lik parçalarla gelir (0,2…1,2 / 1,2…2,2 / 2,2…2,9), sonra gerçek parça (2,9…3,0).
        #expect(gate.admit(count: 16000, at: origin + .seconds(3)) == [0..<12800])
        #expect(gate.admit(count: 16000, at: origin + .seconds(3)) == [12800..<16000])
        #expect(gate.admit(count: 11200, at: origin + .seconds(3)) == [0..<11200])
        #expect(gate.admit(count: 1600, at: origin + .seconds(3)) == [0..<1600])
        #expect(gate.pauses == [PausedSpan(start: 16000, end: 32000)])
    }

    @Test func pausableStreamDropsSamplesInsteadOfSilencing() async {
        let origin: ContinuousClock.Instant = .now
        let gate: RecordingPauseGate = RecordingPauseGate(sampleRate: rate, origin: origin)
        // Akış başlamadan (kayıt başında) duraklatıldı: gelen ses hiç yazılmaz.
        gate.pause(at: origin)
        let (source, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        input.yield([Float](repeating: 0.5, count: 1600))
        input.finish()
        var output: [[Float]] = []
        for await chunk in pausableStream(audio: source, gate: gate) {
            output.append(chunk)
        }
        #expect(output.isEmpty)
    }

    @Test func activeClockFreezesWhilePausedAndAtStop() {
        let start: Date = Date(timeIntervalSince1970: 1_000)
        let paused: PauseClock = PauseClock.running.pausing(at: start.addingTimeInterval(60))
        // Duraklatıldı: süre 01:00'de kalır.
        #expect(recordingActiveSec(startedAt: start, stoppedAt: nil, pause: paused, now: start.addingTimeInterval(90)) == 60)
        // 30 sn sonra sürdü: sayaç 30 sn geriden akar.
        let resumed: PauseClock = paused.resuming(at: start.addingTimeInterval(90))
        #expect(resumed == PauseClock(pausedAt: nil, completedSec: 30))
        #expect(recordingActiveSec(startedAt: start, stoppedAt: nil, pause: resumed, now: start.addingTimeInterval(120)) == 90)
        #expect(resumed.timerStart(startedAt: start) == start.addingTimeInterval(30))
        // Duraklatılmışken bitirildi ("Bitir" duraklatmayı kapatır): süre duraklatma anında kalır.
        let pausedAgain: PauseClock = resumed.pausing(at: start.addingTimeInterval(150))
        let stoppedAt: Date = start.addingTimeInterval(200)
        let finished: PauseClock = pausedAgain.resuming(at: stoppedAt)
        #expect(recordingActiveSec(startedAt: start, stoppedAt: stoppedAt, pause: finished, now: start.addingTimeInterval(500)) == 120)
        #expect(recordingActiveSec(startedAt: start, stoppedAt: stoppedAt, pause: pausedAgain, now: start.addingTimeInterval(500)) == 120)
        // Saat geri gitse de negatif olmaz.
        #expect(recordingActiveSec(startedAt: start, stoppedAt: nil, pause: .running, now: start.addingTimeInterval(-5)) == 0)
    }
}

struct DeepgramIdleTests {
    @Test func finalizesOnceThenKeepsAliveWhileAudioIsIdle() {
        // Ses akıyor: mesaj yok (Mac'te ses sürekli akar).
        #expect(deepgramIdleMessage(audioIdleSec: 0.2, finalizedSinceAudio: false, sinceLastSendSec: 0.2, finalizeAfterSec: 1.5, keepAliveIntervalSec: 4) == nil)
        // Duraklatıldı: önce son cümlenin kesin sonucu istenir.
        #expect(deepgramIdleMessage(audioIdleSec: 1.6, finalizedSinceAudio: false, sinceLastSendSec: 1.6, finalizeAfterSec: 1.5, keepAliveIntervalSec: 4) == .finalize)
        // Sonra son gönderimden 4 sn geçtikçe bağlantı canlı tutulur.
        #expect(deepgramIdleMessage(audioIdleSec: 3, finalizedSinceAudio: true, sinceLastSendSec: 1.4, finalizeAfterSec: 1.5, keepAliveIntervalSec: 4) == nil)
        #expect(deepgramIdleMessage(audioIdleSec: 60, finalizedSinceAudio: true, sinceLastSendSec: 4, finalizeAfterSec: 1.5, keepAliveIntervalSec: 4) == .keepAlive)
    }

    @Test func silenceIsUnresponsiveOnlyAfterAudioWasSent() {
        // Ses verilmedi (duraklatma): ne kadar sürerse sürsün kopma sayılmaz.
        #expect(!isDeepgramUnresponsive(unansweredForSec: nil, timeoutSec: 20))
        #expect(!isDeepgramUnresponsive(unansweredForSec: 5, timeoutSec: 20))
        #expect(isDeepgramUnresponsive(unansweredForSec: 21, timeoutSec: 20))
    }
}
