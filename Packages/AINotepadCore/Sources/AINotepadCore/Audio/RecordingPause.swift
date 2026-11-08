import Foundation

/// Duraklatılan aralık, kaydın hizalanmış ses zaman çizgisinde (örnek; bkz. `clockAlignedStream`): `start` dahil, `end`
/// hariç; süren duraklatmada `end` nil.
public struct PausedSpan: Sendable, Equatable {
    public let start: Int
    public let end: Int?

    public init(start: Int, end: Int?) {
        self.start = start
        self.end = end
    }
}

/// Duraklatma başlar: süren duraklatma yoksa `at`'te açık bir aralık eklenir. Başlangıç önceki aralığın sonundan geri
/// gitmez (konum tahmini parça gelince biraz geri sıçrayabilir). Saf fonksiyondur.
public func pausing(pauses: [PausedSpan], at sample: Int) -> [PausedSpan] {
    guard pauses.last.map({ $0.end != nil }) ?? true else {
        return pauses
    }
    let floor: Int = pauses.last?.end ?? 0
    return pauses + [PausedSpan(start: max(sample, floor), end: nil)]
}

/// Duraklatma biter: süren aralık `at`'te kapanır (başlangıcından önceye düşmez); süren duraklatma yoksa değişmez. Saf
/// fonksiyondur.
public func resuming(pauses: [PausedSpan], at sample: Int) -> [PausedSpan] {
    guard let open = pauses.last, open.end == nil else {
        return pauses
    }
    return pauses.dropLast() + [PausedSpan(start: open.start, end: max(sample, open.start))]
}

/// `sample`'dan önce duraklatılmış toplam örnek. Saf fonksiyondur.
public func pausedSamples(before sample: Int, pauses: [PausedSpan]) -> Int {
    pauses.reduce(0) { (total: Int, span: PausedSpan) -> Int in
        total + max(0, min(span.end ?? Int.max, sample) - span.start)
    }
}

/// Hizalanmış zaman çizgisindeki bir konumun kaydedilen (duraklatılan kısımları atılmış) sesteki karşılığı. Saf
/// fonksiyondur.
public func keptSample(alignedSample: Int, pauses: [PausedSpan]) -> Int {
    alignedSample - pausedSamples(before: alignedSample, pauses: pauses)
}

/// Hizalanmış zaman çizgisinde `chunkStart`'tan başlayan `count` örneklik parçanın duraklatma dışında kalan kısımları
/// (parçanın içindeki aralıklar, sırayla). Saf fonksiyondur.
public func keptRanges(chunkStart: Int, count: Int, pauses: [PausedSpan]) -> [Range<Int>] {
    let chunkEnd: Int = chunkStart + count
    let removed: [Range<Int>] = pauses
        .compactMap { (span: PausedSpan) -> Range<Int>? in
            let lower: Int = max(span.start, chunkStart)
            let upper: Int = min(span.end ?? Int.max, chunkEnd)
            return lower < upper ? lower..<upper : nil
        }
        .sorted { $0.lowerBound < $1.lowerBound }
    var kept: [Range<Int>] = []
    var cursor: Int = chunkStart
    for range in removed {
        if range.lowerBound > cursor {
            kept.append(cursor..<range.lowerBound)
        }
        cursor = max(cursor, range.upperBound)
    }
    if cursor < chunkEnd {
        kept.append(cursor..<chunkEnd)
    }
    return kept.map { ($0.lowerBound - chunkStart)..<($0.upperBound - chunkStart) }
}

/// Şimdiki anın hizalanmış zaman çizgisindeki tahmini konumu: son parçanın sonu ve o parçadan beri geçen süre (parça
/// yakalandıktan hemen sonra gelir; sonraki parça buradan başlar). Saf fonksiyondur.
public func estimatedSamplePosition(lastEndSample: Int, sinceLastChunkSec: Double, sampleRate: Int) -> Int {
    lastEndSample + Int((max(0, sinceLastChunkSec) * Double(sampleRate)).rounded())
}

/// Kaydın duraklatma durumu ve ses akışındaki konumu (thread-safe). `pausableStream` hizalanmış akışın parçalarını
/// bununla süzer: duraklatılan süre ne dosyaya yazılır ne yazıya dökülür, kaydedilen ses kesintisiz birleşir (transkript
/// zamanları kaydedilen sese göredir). Duraklatma anı ses akışının konumundan ölçülür: parçalar sistemden toplu
/// gelse de (kesinti sonrası sessizlik dolgusu) duraklatılan aralığa düşen ses atılır, öncesi ve sonrası kalır.
public final class RecordingPauseGate: Sendable {
    private struct State {
        var pauses: [PausedSpan]
        /// Akışa girmiş hizalanmış ses (örnek): sıradaki parça buradan başlar.
        var position: Int
        /// Son parçanın geldiği an (ya da kayıt başı).
        var lastChunkAt: ContinuousClock.Instant
    }

    public let sampleRate: Int
    private let state: LockedState<State>

    /// `origin`: hizalanmış akışın başladığı an (`clockAlignedStream`'e verilen).
    public init(sampleRate: Int, origin: ContinuousClock.Instant) {
        self.sampleRate = sampleRate
        state = LockedState(State(pauses: [], position: 0, lastChunkAt: origin))
    }

    public var isPaused: Bool {
        state.withLock { $0.pauses.last.map { $0.end == nil } ?? false }
    }

    /// Duraklatılan aralıklar (testler ve loglar için).
    public var pauses: [PausedSpan] {
        state.withLock { $0.pauses }
    }

    /// `at` anından sonra gelen ses atılır (zaten duraklatılmışsa değişmez).
    public func pause(at instant: ContinuousClock.Instant) {
        state.withLock { (state: inout State) -> Void in
            state.pauses = pausing(pauses: state.pauses, at: currentPosition(state: state, at: instant))
        }
    }

    /// `at` anından sonra gelen ses yeniden kaydedilir (duraklatılmamışsa değişmez).
    public func resume(at instant: ContinuousClock.Instant) {
        state.withLock { (state: inout State) -> Void in
            state.pauses = resuming(pauses: state.pauses, at: currentPosition(state: state, at: instant))
        }
    }

    /// `at` anının kaydedilen sesteki karşılığı (saniye): işaretlenen anlar ve transkript bu zaman çizgisindedir.
    public func keptSeconds(at instant: ContinuousClock.Instant) -> Double {
        state.withLock { (state: inout State) -> Double in
            Double(keptSample(alignedSample: currentPosition(state: state, at: instant), pauses: state.pauses)) / Double(sampleRate)
        }
    }

    /// `at` anında gelen `count` örneklik parçayı akışa alır; parçanın kaydedilecek kısımlarını döndürür.
    public func admit(count: Int, at instant: ContinuousClock.Instant) -> [Range<Int>] {
        state.withLock { (state: inout State) -> [Range<Int>] in
            let kept: [Range<Int>] = keptRanges(chunkStart: state.position, count: count, pauses: state.pauses)
            state.position += count
            state.lastChunkAt = instant
            return kept
        }
    }

    private func currentPosition(state: State, at instant: ContinuousClock.Instant) -> Int {
        let since: Duration = instant - state.lastChunkAt
        let sinceSec: Double = Double(since.components.seconds) + Double(since.components.attoseconds) / 1e18
        return estimatedSamplePosition(lastEndSample: state.position, sinceLastChunkSec: sinceSec, sampleRate: sampleRate)
    }
}

/// Hizalanmış akıştan duraklatılan kısımları atar (sessizlikle değiştirmez): duraklatılan süre kaydedilmez, yazıya
/// dökülmez ve ücretlendirilmez. Mikrofon duraklatmada açık kalır (iOS'ta kayıt arka planda sürsün; yeniden kurulmaz).
public func pausableStream(audio: AsyncStream<[Float]>, gate: RecordingPauseGate) -> AsyncStream<[Float]> {
    let (output, sink): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    let task: Task<Void, Never> = Task {
        for await chunk in audio {
            let kept: [Range<Int>] = gate.admit(count: chunk.count, at: .now)
            if kept == [0..<chunk.count] {
                sink.yield(chunk)
                continue
            }
            for range in kept {
                sink.yield(Array(chunk[range]))
            }
        }
        sink.finish()
    }
    sink.onTermination = { (_: AsyncStream<[Float]>.Continuation.Termination) -> Void in
        task.cancel()
    }
    return output
}

/// Kayıt ekranındaki duraklatma saati (duvar saati): süren duraklatmanın başladığı an ve biten duraklatmaların toplamı.
public struct PauseClock: Sendable, Equatable {
    public let pausedAt: Date?
    public let completedSec: TimeInterval

    public init(pausedAt: Date?, completedSec: TimeInterval) {
        self.pausedAt = pausedAt
        self.completedSec = completedSec
    }

    public static let running: PauseClock = PauseClock(pausedAt: nil, completedSec: 0)

    public var isPaused: Bool {
        pausedAt != nil
    }

    /// `at`'te duraklatılır (zaten duraklatılmışsa değişmez).
    public func pausing(at date: Date) -> PauseClock {
        pausedAt == nil ? PauseClock(pausedAt: date, completedSec: completedSec) : self
    }

    /// `at`'te sürer: süren duraklatma toplama eklenir (duraklatılmamışsa değişmez).
    public func resuming(at date: Date) -> PauseClock {
        guard let pausedAt else {
            return self
        }
        return PauseClock(pausedAt: nil, completedSec: completedSec + max(0, date.timeIntervalSince(pausedAt)))
    }

    /// Süre sayacının duvar saatindeki başlangıcı: kayıt başı, biten duraklatmalar kadar ileri (canlı etkinliğin sistem
    /// saatiyle akan sayacı buradan sayar).
    public func timerStart(startedAt: Date) -> Date {
        startedAt.addingTimeInterval(completedSec)
    }
}

/// Kaydın duraklatılmadan geçen süresi: "Bitir"e basıldıysa o anda, duraklatıldıysa duraklatma anında durur; negatif
/// olmaz. Saf fonksiyondur.
public func recordingActiveSec(startedAt: Date, stoppedAt: Date?, pause: PauseClock, now: Date) -> TimeInterval {
    let frozen: Date = [stoppedAt, pause.pausedAt, now].compactMap { $0 }.min() ?? now
    return max(0, frozen.timeIntervalSince(startedAt) - pause.completedSec)
}
