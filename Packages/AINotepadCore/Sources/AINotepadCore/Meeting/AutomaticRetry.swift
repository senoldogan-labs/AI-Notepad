import Foundation

/// İşlemenin neden başarısız olduğunun türü (bkz. `processingFailureKind`).
public enum ProcessingFailureKind: String, Sendable, Equatable, Codable {
    /// Geçici: ağ yok ya da koptu, uygulama askıya alınıp istek kesildi, sunucu 5xx/zaman aşımı/hız sınırı, kaydın sunucu
    /// oturumu kapalı (`meeting_not_active`). Kendiliğinden yeniden denenir.
    case transient
    /// Kalıcı: ses dönüştürülemedi, metin yok, anahtar ya da hak yok, istek reddedildi. Kendiliğinden denenmez.
    case permanent
}

/// Başarısız işlemenin kendiliğinden yeniden denemeleri.
public struct AutomaticRetries: Sendable, Equatable, Codable {
    /// Yapılan deneme sayısı.
    public let count: Int
    /// Son denemenin başladığı an.
    public let lastAttemptAt: Date

    public init(count: Int, lastAttemptAt: Date) {
        self.count = count
        self.lastAttemptAt = lastAttemptAt
    }
}

/// Bir toplantının kendiliğinden yeniden denenme sınırı: sonra "Tekrar işle" kullanıcıya kalır.
public let automaticRetryLimit: Int = 5

/// Kendiliğinden yeniden denemelerin yoklanma aralığı (sn): uygulama açıkken vakti gelen deneme kaçmasın.
public let automaticRetryPollSec: Double = 300

/// İşleme hatasının türü: yeniden denemenin sonucu değiştirebileceği hatalar geçicidir. Tanınmayan hata kalıcı sayılır
/// (kendiliğinden deneme ücret ya da hak harcamasın). Saf fonksiyondur.
public func processingFailureKind(error: any Error) -> ProcessingFailureKind {
    switch error {
    case is CancellationError:
        return .transient
    case HostedClientError.network:
        return .transient
    case let error as HostedAPIError:
        return hostedFailureKind(error: error)
    case let error as LLMError:
        return llmFailureKind(error: error)
    case let error as URLError:
        return transientURLErrorCodes.contains(error.code) ? .transient : .permanent
    default:
        return .permanent
    }
}

/// Bağlantı ya da askıya alma kaynaklı URL hataları (istek yeniden gönderilebilir).
private let transientURLErrorCodes: Set<URLError.Code> = [
    .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    .cancelled, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .backgroundSessionWasDisconnected,
]

private func hostedFailureKind(error: HostedAPIError) -> ProcessingFailureKind {
    switch error.code {
    case .some(.meetingNotActive), .some(.internalError), .some(.upstreamUnavailable), .some(.rateLimited), .some(.transcriptionInProgress),
         .some(.meetingInProgress):
        return .transient
    case .none:
        return transientStatus(status: error.status) ? .transient : .permanent
    case .some:
        return .permanent
    }
}

private func llmFailureKind(error: LLMError) -> ProcessingFailureKind {
    switch error {
    case .http(let status, _, _, _):
        return transientStatus(status: status) ? .transient : .permanent
    case .streamFailed:
        // Akış yarıda kesildi (sunucu aşırı yüklü ya da bağlantı koptu).
        return .transient
    case .hosted(let hosted):
        return hostedFailureKind(error: hosted)
    case .truncated, .refusal, .malformed, .empty, .invalidSchema, .notConfigured:
        return .permanent
    }
}

/// Sunucu hatası, zaman aşımı ya da hız sınırı.
private func transientStatus(status: Int) -> Bool {
    status >= 500 || status == 408 || status == 429
}

/// `count` denemeden sonraki denemeye kadar bekleme (sn): 2 dk, 10 dk, 30 dk, 2 sa; sonrakiler 6 sa. Saf fonksiyondur.
public func automaticRetryDelaySec(count: Int) -> Double {
    let delays: [Double] = [0, 120, 600, 1800, 7200]
    return count < delays.count ? delays[max(count, 0)] : 21_600
}

/// Kendiliğinden yeniden denenebilir mi (vakti gelmemiş olabilir): işleme geçici bir nedenle başarısız, ses duruyor,
/// sunucu oturumuna bağlı ve deneme hakkı kalmış. Saf fonksiyondur.
public func isAutomaticallyRetryable(record: MeetingRecord, linkedRecordIDs: Set<String>) -> Bool {
    record.status == .failed && record.failureKind == .transient && !record.audioDeleted && linkedRecordIDs.contains(record.id)
        && (record.automaticRetries?.count ?? 0) < automaticRetryLimit
}

/// Kendiliğinden yeniden denenebilir toplantının sıradaki denemesinin vakti: ilk deneme hemen (oturumdaki hızlı
/// denemeler zaten yapıldı), sonrakiler artan beklemeyle. Saf fonksiyondur.
public func automaticRetryDueAt(record: MeetingRecord) -> Date? {
    guard let retries = record.automaticRetries else {
        return nil
    }
    return retries.lastAttemptAt.addingTimeInterval(automaticRetryDelaySec(count: retries.count))
}

/// Şimdi kendiliğinden yeniden denenecek toplantılar, eskiden yeniye. Saf fonksiyondur.
public func meetingsToRetryAutomatically(records: [MeetingRecord], linkedRecordIDs: Set<String>, now: Date) -> [MeetingRecord] {
    records
        .filter { (record: MeetingRecord) -> Bool in
            isAutomaticallyRetryable(record: record, linkedRecordIDs: linkedRecordIDs) && (automaticRetryDueAt(record: record).map { $0 <= now } ?? true)
        }
        .sorted { (left: MeetingRecord, right: MeetingRecord) -> Bool in left.startedAt < right.startedAt }
}

/// Kendiliğinden yeniden denemeye başlarken toplantı: deneme sayılır ve işleniyor olur. Saf fonksiyondur.
public func startingAutomaticRetry(record: MeetingRecord, now: Date) -> MeetingRecord {
    record
        .with(automaticRetries: AutomaticRetries(count: (record.automaticRetries?.count ?? 0) + 1, lastAttemptAt: now))
        .with(status: .processing, failureMessage: nil)
}
