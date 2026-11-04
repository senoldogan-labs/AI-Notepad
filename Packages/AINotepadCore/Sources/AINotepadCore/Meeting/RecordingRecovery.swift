import Foundation

/// Açılışta hâlâ "kayıtta" görünen toplantılar: uygulama kayıt sürerken kapandı (iOS sonlandırdı, çöktü, kullanıcı
/// kapattı). En yeni önce: kayıt ekranı en son kesilen kaydın hazırlanmasını gösterir. Saf fonksiyondur.
public func interruptedRecordingIDs(records: [MeetingRecord]) -> [String] {
    records
        .filter { (record: MeetingRecord) -> Bool in record.status == .recording }
        .sorted { (left: MeetingRecord, right: MeetingRecord) -> Bool in left.startedAt > right.startedAt }
        .map(\.id)
}

/// Yarıda kesilen kaydın işlenmiş hâli: toplantıda neden kısa olduğu görünsün diye uyarının başına eklenir (son geçiş
/// ya da not uyarısı varsa korunur). Saf fonksiyondur.
public func withInterruptedRecordingNotice(record: MeetingRecord) -> MeetingRecord {
    let notice: String = String(localized: "Kayıt, uygulama kapandığı için yarıda kesildi; o ana kadar kaydedilen kısım işlendi.")
    guard let existing = record.notice, !existing.isEmpty else {
        return record.with(notice: notice)
    }
    return record.with(notice: "\(notice) \(existing)")
}

/// Notun yeniden deneneceği en çok deneme: işleme sırasında bağlantı koptuysa ya da uygulama arka plana geçtiyse
/// (sistem askıya alıp istekleri kesebilir).
public let meetingNoteMaxAttemptsAfterInterruption: Int = 3

/// Ortam sorunsuzken notun en çok denemesi: sunucunun kısa süren hatası istemcinin hızlı denemelerinden uzun sürdüyse
/// bir kez daha.
public let meetingNoteMaxAttempts: Int = 2

/// İşleme "başarısız" bittiğinde not yeniden denenmeli mi: başarısızlık not adımındaysa (ses dönüştürüldü, yazıya
/// dökülmüş metin var, not yok) ve deneme hakkı kaldıysa. Son geçiş yeniden yapılmaz (ses yeniden yüklenip yeniden
/// faturalanmasın): not son geçiş metninden, o yoksa canlı metinden yazılır. Saf fonksiyondur.
public func shouldRetryMeetingNote(result: MeetingRecord, audioConverted: Bool, environmentInterrupted: Bool, attempt: Int) -> Bool {
    guard result.status == .failed, result.note == nil, audioConverted,
          meetingSegments(record: result).contains(where: { !$0.text.isEmpty }) else {
        return false
    }
    let limit: Int = environmentInterrupted ? meetingNoteMaxAttemptsAfterInterruption : meetingNoteMaxAttempts
    return attempt < limit
}

/// Notun yeniden denenmesinden önceki bekleme (sn): 5, 20, 60; sonraki denemeler 60. Saf fonksiyondur.
public func meetingNoteRetryDelaySec(attempt: Int) -> Double {
    let delays: [Double] = [5, 20, 60]
    return delays[min(max(attempt, 1), delays.count) - 1]
}
