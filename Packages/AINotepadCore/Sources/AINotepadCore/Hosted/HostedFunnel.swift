import Foundation

// Abonelik sürümünün ilk açılış hunisi: Ayarlar'daki "Anonim kullanım istatistiklerini paylaş" açıkken kurulumun ilk
// açılışı, giriş penceresinin adımları ve girişten sonraki karşılamanın adımları (`POST /v1/funnel`, jetonsuz)
// bildirilir; indirme ile ilk toplantı arasındaki boşluk (uygulama açıldı mı, giriş penceresi kapatıldı mı, giriş hata
// mı verdi, karşılama hangi adımda bırakıldı) yönetim panelinde görünür. Gövde
// yalnızca sabit listelerden adım ve ayrıntı taşır; sunucu gün, adım, ayrıntı ve uygulama sürümü başına sayar, tanımlayıcı
// saklamaz. Listeler sunucunun `server/src/funnel.ts` dizileriyle birebir aynıdır (bkz. `ServerParityTests`).

/// Huninin adımının türü (sunucunun `funnelSteps` listesi).
public enum HostedFunnelStepKind: String, Sendable, CaseIterable {
    /// Kurulumun ilk açılışı.
    case firstLaunch = "first_launch"
    /// Giriş penceresi açıldı.
    case signInStarted = "sign_in_started"
    /// Kullanıcı giriş penceresini kapattı.
    case signInCanceled = "sign_in_canceled"
    /// Giriş başarısız oldu.
    case signInFailed = "sign_in_failed"
    /// Giriş tamamlandı.
    case signedIn = "signed_in"
    /// Karşılamanın bir adımı ilk kez gösterildi (giriş sonrası; ayrıntı adım).
    case onboardingStep = "onboarding_step"
    /// Karşılama kapandı (ayrıntı: son adımda bitirildi ya da atlandı).
    case onboardingClosed = "onboarding_closed"
}

/// Karşılamanın nasıl kapandığı (sunucunun `funnelOnboardingEndings` listesi).
public enum HostedOnboardingEnding: String, Sendable, CaseIterable {
    /// Son adımda "Başla" ya da "Örnek notu aç".
    case finished
    /// "Kurulumu atla".
    case skipped
}

/// Abonelik sürümünün karşılama adımlarının huni ayrıntıları (sunucunun `funnelOnboardingSteps` listesi), sırasıyla.
public let hostedFunnelOnboardingSteps: [String] = hostedOnboardingSteps.map(\.rawValue)

/// Girişin başarısız olduğu aşama (sunucunun `funnelFailureStages` listesi).
public enum HostedSignInFailureStage: String, Sendable, CaseIterable {
    /// Giriş penceresi (ASWebAuthenticationSession) açılamadı ya da dönüşsüz kapandı.
    case window
    /// Dönüş adresi reddedildi (biçim, süre ya da nonce).
    case callback
    /// Sunucudaki giriş çağrısı başarısız oldu.
    case server
    /// Giriş çağrısında ağ hatası.
    case network
}

/// Bildirilen huni adımı; ayrıntı adıma göre sağlayıcı, başarısızlık aşaması, karşılama adımı ya da karşılamanın
/// kapanışıdır (ilk açılışta yok).
public enum HostedFunnelStep: Sendable, Equatable {
    case firstLaunch
    case signInStarted(HostedSignInProvider)
    case signInCanceled(HostedSignInProvider)
    case signInFailed(HostedSignInFailureStage)
    case signedIn(HostedSignInProvider)
    case onboardingStep(OnboardingStep)
    case onboardingClosed(HostedOnboardingEnding)

    /// Adımın türü.
    public var kind: HostedFunnelStepKind {
        switch self {
        case .firstLaunch: .firstLaunch
        case .signInStarted: .signInStarted
        case .signInCanceled: .signInCanceled
        case .signInFailed: .signInFailed
        case .signedIn: .signedIn
        case .onboardingStep: .onboardingStep
        case .onboardingClosed: .onboardingClosed
        }
    }

    /// Gövdedeki ayrıntı: sağlayıcı, aşama ya da (ilk açılışta) boş metin.
    public var detail: String {
        switch self {
        case .firstLaunch: ""
        case .signInStarted(let provider), .signInCanceled(let provider), .signedIn(let provider): provider.rawValue
        case .signInFailed(let stage): stage.rawValue
        case .onboardingStep(let step): step.rawValue
        case .onboardingClosed(let ending): ending.rawValue
        }
    }
}

/// `POST /v1/funnel` gövdesi.
private struct HostedFunnelBody: Encodable {
    let step: String
    let detail: String
}

/// Adımın gövdesi (`{"step": …, "detail": …}`). Saf fonksiyondur.
public func hostedFunnelBody(step: HostedFunnelStep) throws -> Data {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(HostedFunnelBody(step: step.kind.rawValue, detail: step.detail))
}

/// Sunucudaki giriş çağrısının hatasının aşaması: sunucuya ulaşılamadıysa `network`, geri kalanı (sunucu reddi,
/// beklenmeyen yanıt, oturumun yazılamaması) `server`. Saf fonksiyondur.
public func hostedSignInFailureStage(error: any Error) -> HostedSignInFailureStage {
    if let clientError = error as? HostedClientError, case .network = clientError {
        return .network
    }
    return .server
}
