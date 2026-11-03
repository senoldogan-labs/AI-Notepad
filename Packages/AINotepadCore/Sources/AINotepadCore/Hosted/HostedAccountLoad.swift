import Foundation

/// Hesabın ilk okumasının (oturum, cihaz doğrulaması, hak durumu) en çok bekleneceği süre (sn). İstekler tek tek
/// sınırlıdır (30 sn boşta kalma, 3 deneme, jeton yenilemesi), ama toplamı dakikaları bulabilir: bu süre dolunca hesap
/// "durumu okunamadı" gösterir ("Yeniden dene" ile); okuma sürer, dönünce gerçek durumu yazar.
public let hostedAccountLoadDeadlineSec: Double = 20

/// Hesap okumasının adımı: süre dolunca hangi adımın beklediği loglanır.
public enum HostedAccountLoadStep: String, Sendable, Equatable {
    /// Kayıtlı oturum ve kullanıcı (Anahtar Zinciri).
    case session
    /// Cihaz doğrulaması (App Attest; iPhone'da atlanır).
    case deviceAttestation
    /// Hak durumu (`GET /v1/me`, gerekirse jeton yenilemesiyle).
    case entitlements
}

/// Süresi dolan okuma hesabı "durumu okunamadı" yapmalı mı: hesap hâlâ ilk okumayı bekliyor, bu okuma en yenisi
/// (bkz. `isCurrentSessionGeneration`; yenisi kendi süresini sayar) ve bu cihazda kayıtlı oturum var (yoksa giriş
/// kapısı açıktır, beklenen bir durum gösterilmez). Saf fonksiyondur.
public func isHostedAccountLoadOverdue(isAwaitingFirstRead: Bool, hasSession: Bool?, started: Int, current: Int) -> Bool {
    isAwaitingFirstRead && hasSession == true && isCurrentSessionGeneration(started: started, current: current)
}
