import Foundation
import Synchronization
import Testing
@testable import AINotepadCore

/// Jeton isteklerini sayar; ret hemen bildirilir (bağlantı ağa çıkmaz).
private final class TokenRequests: Sendable {
    private let count: Mutex<Int> = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func record() {
        count.withLock { $0 += 1 }
    }
}

/// Sunucunun bilerek verdiği ret: akış yeniden denemeden `.failed` ile durur.
private let refusal: HostedAPIError = HostedAPIError(
    code: .deepgramUnavailable, rawCode: "deepgram_unavailable", status: 503, serverMessage: "", path: "/v1/live/deepgram-token"
)

/// İlk seste açılan akış: her bağlantı jetonu sayılır ve reddedilir.
private func refusedStreamOnFirstSound(audio: AsyncStream<[Float]>, requests: TokenRequests) -> DeepgramStream {
    startDeepgramStreamOnFirstSound(audio: audio, sampleRate: 16000) { (forward: AsyncStream<[Float]>) -> DeepgramStream in
        startDeepgramStream(
            token: { () async throws -> String in
                requests.record()
                throw refusal
            },
            options: developerDeepgramListenOptions, language: .finnish, keyterms: [], onConnectionEvent: { (_: DeepgramConnectionEvent) -> Void in },
            audio: forward
        )
    }
}

@Suite struct DeferredDeepgramStreamTests {
    @Test func silenceIsDetectedOnlyForAllZeroChunks() {
        #expect(isSilentChunk(samples: []))
        #expect(isSilentChunk(samples: [0, 0, 0]))
        #expect(!isSilentChunk(samples: [0, 0.001, 0]))
    }

    @Test func eventTimesMoveToTheRecordingTimeline() {
        #expect(shiftedStreamingEvent(event: .final(text: "moi", startSec: 1, endSec: 2), offsetSec: 600) == .final(text: "moi", startSec: 601, endSec: 602))
        #expect(shiftedStreamingEvent(event: .partial(text: "mo", startSec: 0.5, endSec: 1), offsetSec: 10) == .partial(text: "mo", startSec: 10.5, endSec: 11))
        #expect(shiftedStreamingEvent(event: .failed(message: "x"), offsetSec: 10) == .failed(message: "x"))
        #expect(shiftedStreamingEvent(event: .incomplete(untranscribedSec: 2), offsetSec: 10) == .incomplete(untranscribedSec: 2))
    }

    // Mikrofon hiç açılmadı: akış yalnızca sessizlik taşır, bağlantı açılmaz ve ücretlenmez.
    @Test func silentAudioNeverOpensAConnection() async {
        let requests: TokenRequests = TokenRequests()
        let stream: DeepgramStream = refusedStreamOnFirstSound(
            audio: chunkedStream(samples: [Float](repeating: 0, count: 64_000), chunkSize: 16_000), requests: requests
        )
        var events: [StreamingEvent] = []
        for await event in stream.events {
            events.append(event)
        }
        #expect(events.isEmpty)
        #expect(requests.value == 0)
    }

    // Mikrofon kayıt sırasında açıldı: sessizlikten sonra ilk seste tek bağlantı açılır, sonucu iletilir.
    @Test func firstSoundOpensOneConnection() async {
        let requests: TokenRequests = TokenRequests()
        let samples: [Float] = [Float](repeating: 0, count: 48_000) + [Float](repeating: 0.02, count: 32_000)
        let stream: DeepgramStream = refusedStreamOnFirstSound(audio: chunkedStream(samples: samples, chunkSize: 16_000), requests: requests)
        var failures: [String] = []
        for await event in stream.events {
            if case .failed(let message) = event {
                failures.append(message)
            }
        }
        #expect(requests.value == 1)
        #expect(failures == [userFacingMessage(error: refusal)])
    }

    // Kayıt bitti ya da oturum bırakıldı: sonra gelen ses bağlantı açmaz.
    @Test func cancelledStreamNeverOpens() async {
        let requests: TokenRequests = TokenRequests()
        let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let stream: DeepgramStream = refusedStreamOnFirstSound(audio: audio, requests: requests)
        await stream.cancel()
        input.yield([Float](repeating: 0.02, count: 16_000))
        input.finish()
        var events: [StreamingEvent] = []
        for await event in stream.events {
            events.append(event)
        }
        #expect(events.isEmpty)
        #expect(requests.value == 0)
    }
}
