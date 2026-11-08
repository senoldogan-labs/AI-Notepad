import Foundation

/// Sunucuya bildirilecek duraklatma ya da sürdürme (`POST /v1/meetings/{id}/pause` / `resume`).
public struct PauseReport: Sendable, Equatable {
    public let paused: Bool
    /// En az bir kez gönderilmeye çalışıldı: ağ hatası isteğin sunucuya varmadığı anlamına gelmez (yanıt yolda kaybolmuş
    /// olabilir), denenmiş bildirim artık geri alınamaz sayılır.
    public let attempted: Bool

    public init(paused: Bool, attempted: Bool) {
        self.paused = paused
        self.attempted = attempted
    }
}

/// Duraklatma bildirimlerinin kuyruğu ve sunucunun onayladığı duraklatma. Sunucu toplantının en geç bitişinin tek
/// kaynağıdır: uygulama yerel süre sınırını yalnızca sunucunun onayladığı duraklatma kadar ileri iter (bkz.
/// `confirmedPauseSec`). Bildirimler sırayla gider; ağ hatasında kuyrukta kalır ve yeniden denenir (bkz.
/// `pauseReportRetryDelaySec`). Değer türüdür; geçişler saf fonksiyonlardır.
public struct PauseReportQueue: Sendable, Equatable {
    /// Kuyruğun ait olduğu sunucu toplantısı (yoksa nil).
    public let meetingID: String?
    /// Henüz onaylanmamış bildirimler, sırayla; ilki gönderiliyor olabilir (`isSending`).
    public let pending: [PauseReport]
    /// İlk bildirim şu an gönderiliyor.
    public let isSending: Bool
    /// Sunucunun son yanıtındaki sayılan duraklatma (sn; süren duraklatma o ana dek dahil).
    public let confirmedPausedSec: Double
    /// Sunucunun süren diye onayladığı duraklatmanın onayının geldiği an (bu cihazın saatiyle); süren onaylı duraklatma
    /// yoksa nil. Sunucu duraklatmayı isteğin vardığı andan sayar: onayın geldiği an ondan sonradır, yerel hesap sunucunun
    /// önüne geçmez.
    public let confirmedOpenSince: Date?
    /// Son gönderim ağ ya da geçici sunucu hatasıyla başarısız oldu; kuyruk boşalana dek bildirim onaysızdır.
    public let lastAttemptFailed: Bool
    /// Sunucu bir bildirimi reddetti (ör. `pause_limit_reached`): o duraklatma süreden düşülmez, toplantı boyunca böyle
    /// kalır.
    public let hasRefusal: Bool

    public init(
        meetingID: String?, pending: [PauseReport], isSending: Bool, confirmedPausedSec: Double, confirmedOpenSince: Date?, lastAttemptFailed: Bool,
        hasRefusal: Bool
    ) {
        self.meetingID = meetingID
        self.pending = pending
        self.isSending = isSending
        self.confirmedPausedSec = confirmedPausedSec
        self.confirmedOpenSince = confirmedOpenSince
        self.lastAttemptFailed = lastAttemptFailed
        self.hasRefusal = hasRefusal
    }

    public static let empty: PauseReportQueue = PauseReportQueue(
        meetingID: nil, pending: [], isSending: false, confirmedPausedSec: 0, confirmedOpenSince: nil, lastAttemptFailed: false, hasRefusal: false
    )

    fileprivate func with(
        pending newPending: [PauseReport], isSending newSending: Bool, confirmedPausedSec newConfirmed: Double, confirmedOpenSince newOpen: Date?,
        lastAttemptFailed newFailed: Bool, hasRefusal newRefusal: Bool
    ) -> PauseReportQueue {
        PauseReportQueue(
            meetingID: meetingID, pending: newPending, isSending: newSending, confirmedPausedSec: newConfirmed, confirmedOpenSince: newOpen,
            lastAttemptFailed: newFailed, hasRefusal: newRefusal
        )
    }
}

/// Duraklatma bildiriminin sunucudaki durumu (kayıt ekranındaki uyarı için).
public enum PauseConfirmation: Sendable, Equatable {
    /// Bildirilecek bir şey yok ya da hepsi onaylandı.
    case confirmed
    /// Bildirim gönderilemedi, yeniden deneniyor: duraklatma onaylanana dek süre sınırını ileri itmez.
    case unconfirmed
    /// Sunucu bir duraklatmayı reddetti: o duraklatma süre sınırına sayılır.
    case refused
}

/// Kuyruğa yeni bildirim ekler. Başka toplantının kuyruğu yenisiyle değişir. Sürdürme, hiç gönderilmeye çalışılmamış bir
/// duraklatmayı izliyorsa ikisi de düşer: sunucu duraklatmayı isteğin vardığı andan sayar, sonradan ikisini birden
/// göndermek bir şey kazandırmaz. Denenmiş (gönderiliyor ya da ağ hatasıyla dönmüş) duraklatma sunucuya varmış
/// olabilir: arkasından sürdürme sıraya girer (sürdürme duraklatılmamış toplantıda yalnızca durumu döndürür). Saf
/// fonksiyondur.
public func queueingPauseReport(queue: PauseReportQueue, meetingID: String, paused: Bool) -> PauseReportQueue {
    let current: PauseReportQueue = queue.meetingID == meetingID
        ? queue
        : PauseReportQueue(meetingID: meetingID, pending: [], isSending: false, confirmedPausedSec: 0, confirmedOpenSince: nil, lastAttemptFailed: false, hasRefusal: false)
    let lastIsInFlight: Bool = current.isSending && current.pending.count == 1
    let neverSentPause: Bool = current.pending.last.map { $0.paused && !$0.attempted } == true && !lastIsInFlight
    let pending: [PauseReport] = !paused && neverSentPause
        ? Array(current.pending.dropLast())
        : current.pending + [PauseReport(paused: paused, attempted: false)]
    return current.with(
        pending: pending, isSending: current.isSending, confirmedPausedSec: current.confirmedPausedSec, confirmedOpenSince: current.confirmedOpenSince,
        lastAttemptFailed: current.lastAttemptFailed && !pending.isEmpty, hasRefusal: current.hasRefusal
    )
}

/// Gönderilecek ilk bildirim (gönderiliyor olarak işaretlenir); gönderim sürüyorsa ya da kuyruk boşsa nil. Saf
/// fonksiyondur.
public func nextPauseReport(queue: PauseReportQueue) -> (queue: PauseReportQueue, report: PauseReport)? {
    guard !queue.isSending, let first = queue.pending.first else {
        return nil
    }
    let sent: PauseReport = PauseReport(paused: first.paused, attempted: true)
    return (
        queue.with(
            pending: [sent] + queue.pending.dropFirst(), isSending: true, confirmedPausedSec: queue.confirmedPausedSec, confirmedOpenSince: queue.confirmedOpenSince,
            lastAttemptFailed: queue.lastAttemptFailed, hasRefusal: queue.hasRefusal
        ),
        first
    )
}

/// Sunucu ilk bildirimi onayladı (`paused`, `pausedSeconds` yanıttan; `at` onayın geldiği an): sayılan duraklatma
/// sunucunun değeridir; süren duraklatma onaylandıysa `at`'ten itibaren sayılır. Kuyruk boşalınca hata işareti kalkar.
/// Saf fonksiyondur.
public func acknowledgingPauseReport(queue: PauseReportQueue, paused: Bool, pausedSeconds: Int, at: Date) -> PauseReportQueue {
    let pending: [PauseReport] = Array(queue.pending.dropFirst())
    return queue.with(
        pending: pending, isSending: false, confirmedPausedSec: Double(pausedSeconds), confirmedOpenSince: paused ? at : nil,
        lastAttemptFailed: queue.lastAttemptFailed && !pending.isEmpty, hasRefusal: queue.hasRefusal
    )
}

/// İlk bildirim ağ ya da geçici sunucu hatasıyla gitmedi: kuyrukta kalır, yeniden denenecek. Saf fonksiyondur.
public func failingPauseReport(queue: PauseReportQueue) -> PauseReportQueue {
    queue.with(
        pending: queue.pending, isSending: false, confirmedPausedSec: queue.confirmedPausedSec, confirmedOpenSince: queue.confirmedOpenSince,
        lastAttemptFailed: true, hasRefusal: queue.hasRefusal
    )
}

/// Sunucu ilk bildirimi reddetti (yeniden denemek değiştirmez): düşer, ret işaretlenir. Saf fonksiyondur.
public func refusingPauseReport(queue: PauseReportQueue) -> PauseReportQueue {
    let pending: [PauseReport] = Array(queue.pending.dropFirst())
    return queue.with(
        pending: pending, isSending: false, confirmedPausedSec: queue.confirmedPausedSec, confirmedOpenSince: queue.confirmedOpenSince,
        lastAttemptFailed: queue.lastAttemptFailed && !pending.isEmpty, hasRefusal: true
    )
}

/// `meetingID` toplantısının sunucuca onaylanmış duraklatması (sn) `now` anında: son onaydaki sayılan süre + onaylı süren
/// duraklatmanın onaydan beri geçen süresi, en çok `maxPauseSec`. Başka toplantının kuyruğunda 0. Saf fonksiyondur.
public func confirmedPauseSec(queue: PauseReportQueue, meetingID: String, now: Date, maxPauseSec: Double) -> Double {
    guard queue.meetingID == meetingID else {
        return 0
    }
    let open: Double = queue.confirmedOpenSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
    return min(max(0, maxPauseSec), queue.confirmedPausedSec + open)
}

/// Kayıt ekranındaki uyarı için bildirimlerin durumu. Saf fonksiyondur.
public func pauseConfirmation(queue: PauseReportQueue, meetingID: String) -> PauseConfirmation {
    guard queue.meetingID == meetingID else {
        return .confirmed
    }
    if queue.hasRefusal {
        return .refused
    }
    return queue.lastAttemptFailed && !queue.pending.isEmpty ? .unconfirmed : .confirmed
}

/// Canlı metin jetonu beklemeli mi: kayıt duraklatılmışsa ya da sürdürme henüz sunucuya varmadıysa (sunucu duraklatmada
/// verdiği jetonu ses sayıp duraklatmayı kapatır). Saf fonksiyondur.
public func pauseBlocksLiveToken(queue: PauseReportQueue, meetingID: String, locallyPaused: Bool) -> Bool {
    guard queue.meetingID == meetingID else {
        return locallyPaused
    }
    return locallyPaused || queue.pending.contains { !$0.paused }
}

/// Başarısız bildirimin `attempt`. (0'dan) yeniden denemesinden önceki bekleme: 2 sn'den ikiye katlanır, 60 sn'de
/// sabitlenir. Ağ geri gelince beklemeden denenir. Saf fonksiyondur.
public func pauseReportRetryDelaySec(attempt: Int) -> Double {
    min(60, 2 * pow(2, Double(min(max(0, attempt), 10))))
}
