import Foundation

/// Mikrofon yakalamasının durumu: iPhone kayıt ekranı ve canlı etkinlik bunu gösterir.
public enum MicrophoneStatus: Sendable, Equatable {
    /// Ses geliyor.
    case running
    /// Ses oturumu kesildi (telefon çağrısı, alarm): kesinti bitince yakalama kendiliğinden sürer.
    case interrupted
    /// Ses oturumu kesildi ve yeniden açılamıyor çünkü bu iPhone'da başka bir uygulama görüşme yürütüyor (Zoom, Teams,
    /// FaceTime, telefon): iOS görüşme sürerken mikrofonu yalnızca görüşme uygulamasına verir. Görüşme bitince yakalama
    /// kendiliğinden sürer; kesinti gibi kaydı duraklatır.
    case heldByCall
    /// Ses gelmiyor ve motor yeniden kuruluyor (ses yolu değişti, motor durdu, ses servisleri sıfırlandı); kayıt
    /// açık kalır, aradaki boşluk sessizlikle doldurulur.
    case reconnecting(reason: MicrophoneRecoveryReason)
}

/// Mikrofonun yeniden kurulma nedeni (loglarda ve teşhiste görünür).
public enum MicrophoneRecoveryReason: String, Sendable, Equatable {
    /// Giriş cihazı ya da ses yolu değişti (AirPods, CarPlay, başka uygulamanın ses oturumu).
    case configurationChange
    /// Motor ses vermeyi bıraktı ama sistem bildirim göndermedi.
    case stalled
    /// Sistemin ses servisleri sıfırlandı: motor baştan kurulur.
    case mediaServicesReset
    /// Kesinti (çağrı, alarm) bitti: ses oturumu yeniden açılıp motor kurulur.
    case interruptionEnded
    /// Kullanıcı başka bir mikrofon seçti.
    case inputSelected
}

/// `AVAudioSession.ErrorCode.insufficientPriority` ('!pri'): başka bir uygulama görüşme yürütürken `record` ya da
/// `playAndRecord` oturumu açılmak istendi (Apple: "not permitted to capture the microphone of the active call").
public let audioSessionInsufficientPriorityCode: Int = 561_017_449

/// Ses oturumu hatasının kodu, bu iPhone'daki bir görüşmenin mikrofonu tuttuğunu mu söylüyor. Saf fonksiyondur.
public func isCallHoldingMicrophone(code: Int) -> Bool {
    code == audioSessionInsufficientPriorityCode
}

/// Mikrofon kesinti yüzünden ses vermiyor mu (çağrı, alarm ya da görüşme); kayıt bu sürede duraklar. Saf fonksiyondur.
public func isMicrophoneInterrupted(status: MicrophoneStatus) -> Bool {
    switch status {
    case .interrupted, .heldByCall: true
    case .running, .reconnecting: false
    }
}

/// Görüşme mikrofonu tutarken oturumu yeniden açma zamanı geldi mi: görüşme uygulamaları kesintinin bittiğini her zaman
/// bildirmez, deneme görüşme sürerken zararsızca reddedilir. Saf fonksiyondur.
public func shouldRetryAfterCall(status: MicrophoneStatus, isRestarting: Bool, sinceLastAttemptSec: Double, retryIntervalSec: Double) -> Bool {
    guard status == .heldByCall, !isRestarting else {
        return false
    }
    return sinceLastAttemptSec >= retryIntervalSec
}

/// Yakalama sonu (`.captureEnded`) kullanıcıya "mikrofon durdu" olarak gösterilmeli mi: yalnızca kayıt sürerken ve
/// gerçekten ses verilen bir akış bittiyse. Yüz yüze iPhone kaydında "Sen" akışı baştan boştur ve hemen biter; onun sonu
/// beklenendir (eskiden kayıt başlar başlamaz yanlış "Mikrofon beklenmedik şekilde durdu" uyarısı çıkarıyordu). Saf
/// fonksiyondur.
public func isUnexpectedCaptureEnd(speaker: Speaker, capturedSpeakers: Set<Speaker>, isRecording: Bool) -> Bool {
    isRecording && capturedSpeakers.contains(speaker)
}

/// Kayıt ekranındaki süre: kayıt bitirildiyse ("Bitir" anı) o anda durur, sürüyorsa şimdiye dek; saat geri gitse de
/// negatif olmaz. Saf fonksiyondur.
public func recordingElapsedSec(startedAt: Date, stoppedAt: Date?, now: Date) -> TimeInterval {
    let end: Date = stoppedAt.map { min($0, now) } ?? now
    return max(0, end.timeIntervalSince(startedAt))
}

/// Mikrofon takıldı mı: yakalama çalışıyor sayılırken motor durmuşsa ya da `thresholdSec`'ten uzun süredir ses parçası
/// gelmediyse. Kesinti (çağrı) ve süren yeniden kurma sırasında takılma sayılmaz. Saf fonksiyondur.
public func isMicrophoneStalled(status: MicrophoneStatus, engineRunning: Bool, silentForSec: Double, thresholdSec: Double) -> Bool {
    guard status == .running else {
        return false
    }
    return !engineRunning || silentForSec > thresholdSec
}

/// Yeniden kurma sürerken yeni deneme zamanı geldi mi (önceki deneme dizisi başarısız oldu). Saf fonksiyondur.
public func shouldRetryMicrophone(status: MicrophoneStatus, isRestarting: Bool, sinceLastAttemptSec: Double, retryIntervalSec: Double) -> Bool {
    guard case .reconnecting = status, !isRestarting else {
        return false
    }
    return sinceLastAttemptSec >= retryIntervalSec
}

/// Mikrofon kesinti ya da yeniden kurmadan sonra yeniden ses vermeye başladı mı (kayıt ekranı kısa bir bildirim
/// gösterir). Saf fonksiyondur.
public func isMicrophoneRecovery(previous: MicrophoneStatus, current: MicrophoneStatus) -> Bool {
    previous != .running && current == .running
}
