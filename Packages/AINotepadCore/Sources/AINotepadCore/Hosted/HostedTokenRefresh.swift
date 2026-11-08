import Foundation

/// Erişim jetonu bitmeden bu kadar saniye önce yenilenir: istek yoldayken (ve yeniden denenirken) süresi dolmasın.
public let hostedAccessTokenLeewaySec: Double = 60

/// Kimlikli istekten önce yapılacak iş.
public enum HostedTokenAction: Sendable, Equatable {
    /// Kayıtlı oturum yok: giriş gerekir.
    case signedOut
    /// Erişim jetonu geçerli.
    case use(accessToken: String)
    /// Erişim jetonu bitti ya da bitmek üzere: önce yenilenir.
    case refresh(refreshToken: String)
}

/// Saklanan oturuma ve saate göre ne yapılacağı. Saf fonksiyondur.
public func hostedTokenAction(tokens: HostedTokens?, now: Date, leewaySec: Double) -> HostedTokenAction {
    guard let tokens else {
        return .signedOut
    }
    if tokens.accessExpiresAt.timeIntervalSince(now) > leewaySec {
        return .use(accessToken: tokens.accessToken)
    }
    return .refresh(refreshToken: tokens.refreshToken)
}

/// Sunucu bir erişim jetonunu 401 ile reddettikten sonra isteğin yinelenmesi.
public enum HostedRejectionAction: Sendable, Equatable {
    /// Kayıtlı oturum yok.
    case signedOut
    /// Reddedilen jeton şimdiki oturumun değil (istek sürerken çıkış ya da başka bir girişle oturum değişti): istek
    /// yinelenmez; yeni oturumun jetonuyla gönderilse eski hesabın isteği yeni hesaba yazılırdı.
    case sessionChanged
    /// Aynı oturumda jeton bu arada yenilendi: yenilemeden güncel jetonla yinelenir.
    case use(accessToken: String)
    /// Reddedilen jeton güncel: önce yenilenir.
    case refresh
}

/// 401'den sonra ne yapılacağı. `sessionAccessTokens`, şimdiki oturumun verdiği erişim jetonlarıdır (yenilemelerle
/// birlikte; oturum değişince boşalır). Reddedilen jeton onlardan değilse istek başka bir oturumundur ve yinelenmez;
/// saklanan jeton reddedilenden farklıysa (aynı oturumda yenilendi) yenilemeden o kullanılır, böylece bayat 401
/// gereksiz bir yenileme yapmaz; değilse yenilenir. Saf fonksiyondur.
public func hostedTokenActionAfterRejection(tokens: HostedTokens?, rejectedAccessToken: String, sessionAccessTokens: Set<String>) -> HostedRejectionAction {
    guard let tokens else {
        return .signedOut
    }
    guard sessionAccessTokens.contains(rejectedAccessToken) else {
        return .sessionChanged
    }
    if tokens.accessToken != rejectedAccessToken {
        return .use(accessToken: tokens.accessToken)
    }
    return .refresh
}

/// Bellekteki jeton önbelleği: saklama alanı henüz okunmadı ya da okundu (oturum yoksa nil). Tek değer "okunmadı" ile
/// "okundu, oturum yok"u karıştırmaz.
public enum HostedTokenCache: Sendable, Equatable {
    case unloaded
    case loaded(HostedTokens?)
}

/// Yenileme başladığından beri oturum değişmedi mi (çıkış, hesap silme, yeni giriş ya da ret kuşağı artırır): değiştiyse
/// dönen jetonlar yazılmaz (çıkış yapılmış oturum geri gelmez) ve ret yeni oturumu silmez. Saf fonksiyondur.
public func isCurrentSessionGeneration(started: Int, current: Int) -> Bool {
    started == current
}

/// Yenileme isteğinin sonucu.
public enum HostedRefreshResult: Sendable, Equatable {
    /// Yeni jetonlar (yenileme jetonu her seferinde döner; eskisi bir daha kullanılmamalı).
    case refreshed(HostedTokens)
    /// Sunucu jetonu reddetti (401): süresi dolmuş, çıkış yapılmış ya da yeniden kullanılmış (sunucu bu durumda tüm
    /// oturum ailesini kapatır). Yerel oturum silinir, kullanıcı yeniden giriş yapar.
    case revoked(HostedAPIError)
    /// Geçici ya da beklenmeyen hata; oturum korunur, hata kullanıcıya gösterilir.
    case failed(HostedAPIError)
}

/// Yenileme yanıtını sınıflandırır; 2xx gövde bozuksa `malformedResponse`. Saf fonksiyondur.
public func hostedRefreshResult(status: Int, data: Data, receivedAt: Date) throws -> HostedRefreshResult {
    let path: String = "/v1/auth/refresh"
    guard (200..<300).contains(status) else {
        return hostedRefreshFailure(error: parseHostedAPIError(status: status, data: data, path: path))
    }
    do {
        return .refreshed(hostedTokens(response: try hostedJSONDecoder().decode(HostedSessionResponse.self, from: data), receivedAt: receivedAt))
    } catch {
        // Gövde jeton içerebilir: hataya yazılmaz.
        throw HostedClientError.malformedResponse(path: path, status: status, body: "(oturum yanıtı çözülemedi: \(error))")
    }
}

/// Başarısız yenileme: 401 oturumun bittiğidir (jeton geçersiz, süresi dolmuş, aile kapatılmış ya da jeton yeniden
/// kullanılmış); diğer hatalar geçicidir, oturum korunur. Saf fonksiyondur.
public func hostedRefreshFailure(error: HostedAPIError) -> HostedRefreshResult {
    error.status == 401 ? .revoked(error) : .failed(error)
}

/// Bir istek denemesinin başarısızlığı (yeniden deneme kararı için).
public enum HostedAttemptFailure: Sendable, Equatable {
    /// İstek sunucuya ulaşamadı ya da yanıt gelmedi.
    case network(URLError.Code)
    /// Sunucu hata döndürdü.
    case server(HostedAPIError)
}

/// Tekrarı zararsız istekler (okuma, çıkış, hesap silme, ödeme sayfası, ses yükleme, yenileme jetonu döndürme): ağ
/// hatası ve geçici sunucu hatası yeniden denenir. Yenileme de buradadır: sunucu, yanıtı kaybolan yenilemenin jetonunu
/// halefi kullanılmadıkça 10 dakika boyunca yeniden kabul eder (aileyi düşürmez, yeni çift verir); zaman aşımından
/// sonra aynı jetonla hemen yeniden denemek oturumu korur. Saf fonksiyondur.
public func isRetryableRepeatableRequest(failure: HostedAttemptFailure) -> Bool {
    switch failure {
    case .network(let code):
        code != .cancelled
    case .server(let error):
        isRetryableHostedError(error: error)
    }
}

/// Tekrarı zararlı olabilecek istekler (tek kullanımlık nonce ile giriş, cihaz doğrulama, toplantı başlatma): yalnızca
/// sunucunun isteği hiç işlemediği kesin olan durumlar yeniden denenir (bağlantı kurulamadı ya da hız sınırı). Zaman
/// aşımında istek işlenmiş olabilir: nonce ikinci kez kullanılamaz, toplantıyı ikinci kez başlatmak bir deneme hakkı
/// daha harcar. Saf fonksiyondur.
public func isRetryableOneShotRequest(failure: HostedAttemptFailure) -> Bool {
    switch failure {
    case .network(let code):
        isSafeToRetryPost(code: code)
    case .server(let error):
        error.code == .rateLimited
    }
}
