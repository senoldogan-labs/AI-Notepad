import Foundation

// Abonelik sürümünde canlı metnin nerede çalışacağı: bulut (Deepgram), cihazdaki motor ya da hiçbiri. Mac'te cihazdaki
// motor her zaman var (WhisperKit); iPhone'da cihaz içi konuşma tanıma (`SpeechAnalyzer`) iOS 26 ister, iOS 18–25'te yok.

/// Bulut canlı metni kalıcı olarak durunca (jeton alınamadı, bağlantı bütçe içinde kurulamadı) hibrit oturumun yaptığı.
public enum HybridCloudFailure: Sendable, Equatable {
    /// Cihazdaki motora geçilir (Mac; iOS 26+ iPhone); geçiş tek yönlüdür.
    case switchToLocal
    /// Cihazda motor yok (iPhone, iOS 18–25): konuşmacının bulut akışı geri çekilerek yeniden açılır; beklemeler
    /// `delaysSec` sırasıyla, sonuncusu tekrarlanır. Arada ses kayda yazılır, canlı metne gitmez (son geçiş kapsar).
    case reconnectCloud(delaysSec: [Double])
}

/// iPhone'un yeniden bağlanma beklemeleri (sn): kısa kopmada hızlı, uzun kopmada dakikada bir.
public let cloudReconnectDelaysSec: [Double] = [1, 2, 5, 10, 20, 30, 60]

/// Bulut akışı durunca ne yapılacağı: cihazda motor varsa ona geçilir, yoksa bulut yeniden denenir. Saf fonksiyondur.
public func hybridCloudFailure(localSpeechAvailable: Bool, reconnectDelaysSec: [Double]) -> HybridCloudFailure {
    localSpeechAvailable ? .switchToLocal : .reconnectCloud(delaysSec: reconnectDelaysSec)
}

/// `attempt`. yeniden bağlanma denemesinden önceki bekleme: liste bitince son değer tekrarlanır; liste boşsa 0. Saf
/// fonksiyondur.
public func cloudReconnectDelaySec(attempt: Int, delaysSec: [Double]) -> Double {
    guard let last = delaysSec.last else {
        return 0
    }
    return attempt < delaysSec.count ? delaysSec[max(0, attempt)] : last
}

/// Canlı metnin başlangıcı.
public enum HostedLiveStartPlan: Sendable, Equatable {
    /// Bulut (Deepgram).
    case cloud
    /// Cihazdaki motor (Mac'te WhisperKit, iOS 26+ iPhone'da Apple'ın konuşma tanıması).
    case local
    /// Canlı metin yok: bulut kullanılamıyor, cihazda motor yok. Kayıt sürer, metin ve not kayıttan sonra hazırlanır.
    case unavailable
}

/// Canlı metnin başlangıcını seçer: sunucu bulutu öneriyor ve ilk jeton alındıysa bulut; değilse (politika kapalı,
/// bütçe doldu, jeton alınamadı, çevrimdışı başlangıç: toplantının sunucu oturumu yokken jeton da istenemez) cihazdaki
/// motor, o da yoksa canlı metin yok. Saf fonksiyondur.
public func hostedLiveStartPlan(cloudGranted: Bool, localSpeechAvailable: Bool) -> HostedLiveStartPlan {
    if cloudGranted {
        return .cloud
    }
    return localSpeechAvailable ? .local : .unavailable
}
