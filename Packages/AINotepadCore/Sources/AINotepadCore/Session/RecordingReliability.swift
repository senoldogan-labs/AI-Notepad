import Foundation

// Kaydın güvenilirlik kuralları (Mac ve iPhone ortak): eski bildirime dokunmak kayıt başlatmasın, kesilen mikrofon
// yüksek sesle bildirilsin, biten toplantı sorulsun.

/// Toplantı bildirimine ("1 dk sonra: …", "Bir görüşme başlamış olabilir") dokunuşun sonucu.
public enum MeetingNotificationTap: Sendable, Equatable {
    /// Kayıt başlar.
    case startRecording
    /// Ana sayfa açılır (başlat düğmesi orada); kayıt başlamaz.
    case openHome
}

/// Toplantı bildiriminin "Kaydı başlat" eylemi bu süreden eski bildirimde kayıt başlatmaz (sn).
public let meetingNotificationFreshnessSec: Double = 600

/// Bildirime dokunuşun sonucu: yalnızca "Kaydı başlat" eylemi, kayıt yokken ve bildirim taze ise kaydı başlatır;
/// bildirimin kendisine dokunmak (ya da saatler sonra Bildirim Merkezi'nden eylem) yalnızca Ana sayfayı açar. Saf
/// fonksiyondur.
public func meetingNotificationTap(isStartAction: Bool, deliveredAt: Date, now: Date, isRecording: Bool) -> MeetingNotificationTap {
    guard isStartAction, !isRecording, now.timeIntervalSince(deliveredAt) <= meetingNotificationFreshnessSec else {
        return .openHome
    }
    return .startRecording
}

/// Mikrofondan bu kadar süre ses gelmezse (yeniden bağlanma sürüyor) kullanıcı sesle ve bildirimle uyarılır (sn).
public let microphoneOutageAlertSec: Double = 20

/// Mikrofon kesintisi için yüksek sesli uyarının zamanı geldi mi: kesinti `thresholdSec`'ten uzun sürdü ve bu kesintide
/// henüz uyarılmadı. Saf fonksiyondur.
public func isMicrophoneOutageAlertDue(outageStartedAt: Date?, now: Date, alreadyAlerted: Bool, thresholdSec: Double) -> Bool {
    guard let outageStartedAt, !alreadyAlerted else {
        return false
    }
    return now.timeIntervalSince(outageStartedAt) >= thresholdSec
}

/// "Toplantı bitti mi?" sorusunun nedeni.
public enum MeetingOverReason: Sendable, Equatable {
    /// Bağlı takvim etkinliğinin bitişi geçti.
    case calendarEnded
    /// Uzun süredir konuşma yok.
    case longSilence
}

/// Takvim etkinliği bittikten sonra sormadan önceki bekleme (toplantılar çoğu zaman biraz uzar; sn).
public let meetingOverCalendarGraceSec: Double = 120
/// Bu kadar süre konuşma (kesinleşen metin) gelmezse toplantının bittiği sorulur (sn).
public let meetingOverSilenceSec: Double = 600

/// Toplantı bitmiş gibi mi: duraklatılmış kayıtta sorulmaz; takvim bitişi (pay ile) geçtiyse ya da son konuşmadan
/// (ya da kayıt başından/sürdürmeden) beri `silenceSec` geçtiyse nedeni, değilse nil. Daha önce sorulan neden yeniden
/// sorulmaz (`asked`). Saf fonksiyondur.
public func meetingOverReason(
    now: Date, calendarEnd: Date?, lastActivityAt: Date, isPaused: Bool, asked: Set<MeetingOverReason>, calendarGraceSec: Double, silenceSec: Double
) -> MeetingOverReason? {
    guard !isPaused else {
        return nil
    }
    if let calendarEnd, now.timeIntervalSince(calendarEnd) >= calendarGraceSec, !asked.contains(.calendarEnded) {
        return .calendarEnded
    }
    if now.timeIntervalSince(lastActivityAt) >= silenceSec, !asked.contains(.longSilence) {
        return .longSilence
    }
    return nil
}

/// Kayıt sürerken uygulamanın yaşadığını gösteren yenileme aralığı: kilit ekranındaki canlı etkinlik ve "kayıt durmuş
/// olabilir" bildirimi bu aralıkla ileri atılır (sn).
public let recordingHeartbeatSec: Double = 30
/// Uygulama bu kadar süre yenileme yapmazsa (çöktü, sistem kapattı) "kayıt durmuş olabilir" bildirimi çıkar (sn).
public let recordingStoppedAlertSec: Double = 90
