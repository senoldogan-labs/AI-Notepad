import Foundation
import Testing
@testable import KeyboardCore

/// Sistem tamamlanışları (sözlük isteği XPC yanıt kuyruğunda gelir) ana kuyruk dışında çağrılır. Ana aktörde yazılmış
/// kapanış oraya doğrudan verilseydi Swift 6 çalışma zamanı uzantıyı durdururdu (`_dispatch_assert_queue_fail`;
/// Simülatörde klavye böyle çöktü). Testler sarılmış tamamlanışı arka kuyruktan çağırır: tuzak test sürecini öldürürdü.
@Suite struct KeyboardCallbackIsolationTests {
    /// Değer kabı Sendable değildir (`UILexicon` gibi).
    final class Payload {
        let words: [String]

        init(words: [String]) {
            self.words = words
        }
    }

    @Test func completionCalledOnABackgroundQueueRunsOnTheMainQueue() async {
        let delivered: (words: [String], onMain: Bool) = await withCheckedContinuation { (continuation: CheckedContinuation<(words: [String], onMain: Bool), Never>) in
            let handler: (Payload) -> Void = keyboardMainQueueHandler { (payload: Payload) in
                continuation.resume(returning: (payload.words, Thread.isMainThread))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                handler(Payload(words: ["Gistsmith", "Kahvila"]))
            }
        }
        #expect(delivered.words == ["Gistsmith", "Kahvila"])
        #expect(delivered.onMain)
    }
}
