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
/// The AI disclosure comes before the app while the account has not answered it (`hostedAIConsentNeedsPrompt`); after
/// "Not now" the app opens and AI features ask again when used. The Mac main window uses the same gate (`isRecording`:
/// the recorder is not idle, starting included, so "Cancel" stays when the session ends while a recording starts). Saf
/// fonksiyondur.
public func phoneAppGate(requiresSignIn: Bool, isRecording: Bool, needsAIConsentPrompt: Bool) -> PhoneAppGate {
    if isRecording {
        return .main
    }
    if requiresSignIn {
        return .signIn
    }
    return needsAIConsentPrompt ? .aiConsent : .main
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
/// ekranı, yoksa nil. Kendiliğinden gelen anlar (not hazır, deneme bitiyor ya da bitti, geri çağırma; bkz.
/// `hostedUpsellPresentation`) ana ekranda kart olur, tam ekran açmaz: ekran yalnızca kullanıcı karttan "Planları
/// gör"e basınca (`isExpanded`) açılır. Saf fonksiyondur.
public func phoneRootCover(onboardingCompleted: Bool, upsell: HostedUpsellMoment?, isExpanded: Bool) -> PhoneRootCover? {
    guard onboardingCompleted else {
        return .onboarding
    }
    guard let upsell, hostedUpsellPresentation(moment: upsell) == .sheet || isExpanded else {
        return nil
    }
    return .paywall(upsell)
}
