import Foundation

/// iPhone uygulamasının kökünde gösterilen: giriş kapısı, yapay zekâ açıklaması ya da uygulamanın kendisi (karşılama ve
/// abonelik ekranı uygulamanın üstünde ayrı sunulur; bkz. `phoneRootCover`).
public enum PhoneAppGate: Sendable, Equatable {
    case signIn
    case aiConsent
    case main
}

/// Kökte ne gösterilir. Kayıt sürerken (başlıyor, kaydediyor, bitiriliyor) hep uygulama: oturum kayıt sırasında
/// kapanırsa "Bitir" kaybolmaz, kapı kayıt bitip toplantı saklanınca açılır; açıklama onayı kayıttan önce alınmıştır.
/// Saf fonksiyondur.
public func phoneAppGate(requiresSignIn: Bool, isRecording: Bool, aiConsentGiven: Bool) -> PhoneAppGate {
    if isRecording {
        return .main
    }
    if requiresSignIn {
        return .signIn
    }
    return aiConsentGiven ? .main : .aiConsent
}

/// Uygulamanın üstündeki tam ekran sunum (tektir; iki `fullScreenCover` aynı anda sunulamaz).
public enum PhoneRootCover: Identifiable, Sendable, Equatable {
    /// İlk açılış karşılaması.
    case onboarding
    /// Abonelik ekranı (açılma nedeniyle).
    case paywall(HostedUpsellMoment)

    public var id: String {
        switch self {
        case .onboarding:
            "onboarding"
        case .paywall(let reason):
            "paywall.\(reason.rawValue)"
        }
    }
}

/// Gösterilecek tam ekran sunum: karşılama bitmediyse karşılama (abonelik isteği bekler), bittiyse istenen abonelik
/// ekranı, yoksa nil. Saf fonksiyondur.
public func phoneRootCover(onboardingCompleted: Bool, upsell: HostedUpsellMoment?) -> PhoneRootCover? {
    guard onboardingCompleted else {
        return .onboarding
    }
    return upsell.map { PhoneRootCover.paywall($0) }
}
