import Foundation

/// Parçanın tamamı tam sessizlik mi (sıfır örnekler: hizalama dolgusu, kapalı mikrofon kapısı). Boş parça da sessizdir.
/// Saf fonksiyondur.
public func isSilentChunk(samples: [Float]) -> Bool {
    samples.allSatisfy { $0 == 0 }
}

/// Akış olayının zamanlarını `offsetSec` kadar kaydırır (sonradan açılan akışın olayları kaydın zaman çizgisine
/// taşınır). Saf fonksiyondur.
public func shiftedStreamingEvent(event: StreamingEvent, offsetSec: Double) -> StreamingEvent {
    switch event {
    case .partial(let text, let startSec, let endSec):
        .partial(text: text, startSec: startSec + offsetSec, endSec: endSec + offsetSec)
    case .final(let text, let startSec, let endSec):
        .final(text: text, startSec: startSec + offsetSec, endSec: endSec + offsetSec)
    case .failed, .incomplete:
        event
    }
}

/// İlk sesli parçada açılacak Deepgram akışının durumu (bkz. `startDeepgramStreamOnFirstSound`): açılmadan seçilen dil
/// saklanır, bırakılan akış açılmaz.
actor DeferredDeepgramStart {
    private let events: AsyncStream<StreamingEvent>.Continuation
    private var stream: DeepgramStream?
    private var pendingLanguage: MeetingLanguage?
    private var isCancelled: Bool = false

    init(events: AsyncStream<StreamingEvent>.Continuation) {
        self.events = events
    }

    /// Akışı açar (bekleyen dil uygulanır); bırakıldıysa açmaz ve nil döner.
    func open(start: @Sendable () -> DeepgramStream) async -> DeepgramStream? {
        guard !isCancelled else {
            return nil
        }
        let opened: DeepgramStream = start()
        stream = opened
        if let pendingLanguage {
            await opened.switchLanguage(to: pendingLanguage)
        }
        return opened
    }

    func switchLanguage(to language: MeetingLanguage) async {
        guard let stream else {
            pendingLanguage = language
            return
        }
        await stream.switchLanguage(to: language)
    }

    /// Açıksa bağlantı kesilir (olay akışı onunla biter); açılmadıysa olay akışı hemen biter ve bir daha açılmaz.
    func cancel() async {
        isCancelled = true
        guard let stream else {
            events.finish()
            return
        }
        await stream.cancel()
    }

    func dropConnectionForTesting() async {
        await stream?.dropConnectionForTesting()
    }
}
