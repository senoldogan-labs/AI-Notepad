import Foundation

// Abonelik sürümünün ilk açılış hunisi: Ayarlar'daki "Anonim kullanım istatistiklerini paylaş" açıkken kurulumun ilk
// açılışı ve giriş penceresinin adımları (`POST /v1/funnel`, jetonsuz) bildirilir; indirme ile hesap açılışı arasındaki
// boşluk (uygulama açıldı mı, giriş penceresi kapatıldı mı, giriş hata mı verdi) yönetim panelinde görünür. Gövde
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
}

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

/// Bildirilen huni adımı; ayrıntı adıma göre sağlayıcı ya da başarısızlık aşamasıdır (ilk açılışta yok).
public enum HostedFunnelStep: Sendable, Equatable {
    case firstLaunch
    case signInStarted(HostedSignInProvider)
    case signInCanceled(HostedSignInProvider)
    case signInFailed(HostedSignInFailureStage)
    case signedIn(HostedSignInProvider)

    /// Adımın türü.
    public var kind: HostedFunnelStepKind {
        switch self {
        case .firstLaunch: .firstLaunch
        case .signInStarted: .signInStarted
        case .signInCanceled: .signInCanceled
        case .signInFailed: .signInFailed
        case .signedIn: .signedIn
        }
    }

    /// Gövdedeki ayrıntı: sağlayıcı, aşama ya da (ilk açılışta) boş metin.
    public var detail: String {
        switch self {
        case .firstLaunch: ""
        case .signInStarted(let provider), .signInCanceled(let provider), .signedIn(let provider): provider.rawValue
        case .signInFailed(let stage): stage.rawValue
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
