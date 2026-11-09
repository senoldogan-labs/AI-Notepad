import Foundation
import Testing
@testable import AINotepadCore

struct RecordingHealthTests {
    @Test func emptyMeStreamEndIsNotAMicrophoneFailure() {
        // Yüz yüze iPhone kaydı: "Sen" akışı baştan boştur, hemen biter; uyarı vermemeli.
        #expect(!isUnexpectedCaptureEnd(speaker: .me, capturedSpeakers: [.others], isRecording: true))
        #expect(isUnexpectedCaptureEnd(speaker: .others, capturedSpeakers: [.others], isRecording: true))
        // "Bitir"den sonra akışın bitmesi beklenendir.
        #expect(!isUnexpectedCaptureEnd(speaker: .others, capturedSpeakers: [.others], isRecording: false))
    }

    @Test func emptyMeStreamEmitsCaptureEndRightAway() async throws {
        // Yanlış uyarının kaynağı: boş "Sen" akışı kayıt başlar başlamaz `.captureEnded(.me)` yayınlar.
        let directory: URL = try temporaryDirectory()
        let (me, meInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        meInput.finish()
        let (others, othersInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let recording: HybridRecording = startHybridRecording(directory: directory, meAudio: me, othersAudio: others)
        var iterator: AsyncStream<LiveSessionEvent>.Iterator = recording.events.makeAsyncIterator()
        let first: LiveSessionEvent? = await iterator.next()
        #expect(first == .captureEnded(speaker: .me))
        othersInput.finish()
    }

    @Test func elapsedFreezesAtStop() {
        let start: Date = Date(timeIntervalSince1970: 1_000)
        #expect(recordingElapsedSec(startedAt: start, stoppedAt: nil, now: start.addingTimeInterval(130)) == 130)
        // "Bitir"e 02:10'da basıldı: süre sonra da 02:10'da kalır.
        #expect(recordingElapsedSec(startedAt: start, stoppedAt: start.addingTimeInterval(130), now: start.addingTimeInterval(175)) == 130)
        #expect(recordingElapsedSec(startedAt: start, stoppedAt: nil, now: start.addingTimeInterval(-5)) == 0)
    }

    @Test func stallIsDetectedOnlyWhileRunning() {
        #expect(isMicrophoneStalled(status: .running, engineRunning: true, silentForSec: 4, thresholdSec: 3))
        #expect(isMicrophoneStalled(status: .running, engineRunning: false, silentForSec: 0, thresholdSec: 3))
        #expect(!isMicrophoneStalled(status: .running, engineRunning: true, silentForSec: 1, thresholdSec: 3))
        #expect(!isMicrophoneStalled(status: .interrupted, engineRunning: false, silentForSec: 60, thresholdSec: 3))
        #expect(!isMicrophoneStalled(status: .reconnecting(reason: .stalled), engineRunning: false, silentForSec: 60, thresholdSec: 3))
    }

    @Test func recoveryIsReportedOnlyWhenSoundReturns() {
        #expect(isMicrophoneRecovery(previous: .interrupted, current: .running))
        #expect(isMicrophoneRecovery(previous: .reconnecting(reason: .stalled), current: .running))
        #expect(!isMicrophoneRecovery(previous: .running, current: .running))
        #expect(!isMicrophoneRecovery(previous: .running, current: .interrupted))
    }

    @Test func callHoldingTheMicrophoneIsRecognisedAndPauses() {
        // '!pri' (561017449): başka bir uygulama görüşme yürütürken kayıt oturumu açılamaz.
        #expect(isCallHoldingMicrophone(code: 561_017_449))
        #expect(!isCallHoldingMicrophone(code: 560_557_684))
        #expect(!isCallHoldingMicrophone(code: 0))
        // Görüşme kaydı duraklatır (kesinti gibi); takılma sayılmaz.
        #expect(isMicrophoneInterrupted(status: .heldByCall))
        #expect(isMicrophoneInterrupted(status: .interrupted))
        #expect(!isMicrophoneInterrupted(status: .running))
        #expect(!isMicrophoneInterrupted(status: .reconnecting(reason: .stalled)))
        #expect(!isMicrophoneStalled(status: .heldByCall, engineRunning: false, silentForSec: 600, thresholdSec: 3))
        #expect(isMicrophoneRecovery(previous: .heldByCall, current: .running))
    }

    @Test func callHoldingTheMicrophoneSaysWhyAndWhatWorks() {
        // Genel "giriş cihazını kontrol et" yerine neden (görüşme) ve çare (Mac, görüşmeden sonra).
        let message: String = userFacingMessage(error: AudioCaptureError.microphoneHeldByCall)
        #expect(message == microphoneHeldByCallText())
        #expect(message.contains("görüşme"))
        #expect(message.contains("Mac"))
        #expect(!message.contains("Giriş cihazını"))
    }
}
