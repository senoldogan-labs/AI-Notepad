import Foundation

/// Bir hesabın son girdisi ve sonucu: girdi aynıysa sonuç yeniden hesaplanmaz (Kişiler ve İstatistikler bütün arşivi
/// her çizimde baştan hesaplıyordu). Girdi eşitliği ucuzdur: değişmemiş dizi aynı depoyu paylaşır, `==` öğelere inmez.
public struct MemoCache<Input: Equatable & Sendable, Output: Sendable>: Sendable {
    let input: Input?
    let output: Output?

    /// Boş önbellek.
    public static var empty: MemoCache<Input, Output> { MemoCache(input: nil, output: nil) }
}

/// `input` önbellekteki girdiyle aynıysa saklı sonuç, değilse `compute(input)` ve yeni önbellek. Saf fonksiyondur
/// (`compute` saf olduğu sürece).
public func memoized<Input: Equatable & Sendable, Output: Sendable>(
    input: Input, cache: MemoCache<Input, Output>, compute: (Input) -> Output
) -> (output: Output, cache: MemoCache<Input, Output>) {
    if let cachedInput = cache.input, let cachedOutput = cache.output, cachedInput == input {
        return (output: cachedOutput, cache: cache)
    }
    let output: Output = compute(input)
    return (output: output, cache: MemoCache(input: input, output: output))
}

/// Kişiler dizininin girdisi (bkz. `peopleDirectory`).
public struct PeopleDirectoryInput: Sendable, Equatable {
    public let records: [MeetingRecord]
    public let voices: [RegisteredVoice]
    public let book: PeopleBook
    public let userName: String

    public init(records: [MeetingRecord], voices: [RegisteredVoice], book: PeopleBook, userName: String) {
        self.records = records
        self.voices = voices
        self.book = book
        self.userName = userName
    }
}

/// İstatistiklerin girdisi (bkz. `meetingAnalytics`); `day` bugünün başı: gün dönünce dönem kayar.
public struct AnalyticsInput: Sendable, Equatable {
    public let records: [MeetingRecord]
    public let period: AnalyticsPeriod
    public let userName: String
    public let day: Date

    public init(records: [MeetingRecord], period: AnalyticsPeriod, userName: String, day: Date) {
        self.records = records
        self.period = period
        self.userName = userName
        self.day = day
    }
}
