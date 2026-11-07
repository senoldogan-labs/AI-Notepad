import AINotepadCore
import Foundation
import os

private let hostedScopeLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedAccount")

// Abonelik hesabının Mac ve iPhone uygulamalarında ortak kapsamı: bu süreçte yüklü hesap verisinin durumu, hesabın kendi
// ayar alanı ve Anahtar Zinciri'nde kayıtlı oturumun kullanıcısı (bkz. `HostedAccount`). Platforma özgü veri taşıma Mac'te
// HostedAccountData.swift'te, iPhone'da iOS/Hosted/PhoneHostedAccountData.swift'tedir.

/// Bu süreçte yüklü hesap verisinin durumu.
enum HostedDataState: Equatable {
    /// Hesap verisi yüklenmedi (açılışta oturum yoktu; giriş yapılınca yüklenir).
    case notLoaded
    /// Bu hesabın verisi yüklü.
    case loaded(accountKey: String)
    /// Hesabın verisi hazırlanamadı (ör. önceki toplantılar hesaba taşınamadı); veri yerinde kalır, neden gösterilir.
    case failed(message: String)
    /// Başka bir hesapla (`accountKey`) giriş yapıldı: kayıt ve işleme bitince o hesabın verisi yüklenir (Mac yeniden
    /// başlar, iPhone hesabı yerinde değiştirir, bkz. `HostedAccount.completeAccountSwitch`).
    case switchPending(accountKey: String)
}

/// Uygulamanın paket kimliği (kendi ayar alanının adı).
private func hostedBundleIdentifier() throws -> String {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
        throw StorageError.writeFailed(path: Bundle.main.bundlePath, reason: "paket kimliği yok, hesabın ayar alanı adlandırılamadı")
    }
    return bundleIdentifier
}

/// Hesabın ayar alanının adı: `<paket kimliği>.account.<anahtar>`.
private func hostedAccountSuiteName(accountKey: String) throws -> String {
    guard isValidAccountDataKey(key: accountKey) else {
        throw StorageError.invalidAccountKey(key: accountKey)
    }
    return "\(try hostedBundleIdentifier()).account.\(accountKey)"
}

/// Hesabın ayar alanında yapay zekâ açıklamasının onayı (iPhone'da girişten sonra bir kez, hesap başına; bkz.
/// `PhoneAIDisclosure`). Hesap silinince silinir.
let hostedAIDisclosureAcceptedKey: String = "hosted.aiDisclosureAccepted"

/// Hesabın kendi ayar alanı (klasörler, Sor tarifleri, dışa aktarma ayarları, açık sunucu oturumları, eşitlenen
/// ayarların değişiklik saatleri).
func hostedAccountDefaults(accountKey: String) throws -> UserDefaults {
    let suite: String = try hostedAccountSuiteName(accountKey: accountKey)
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw StorageError.writeFailed(path: suite, reason: "hesabın ayar alanı açılamadı")
    }
    return defaults
}

/// Hesapla eşitlenen ayarların yerleri: değerler uygulamanın kendi ayar alanında (`@AppStorage`), değişiklik saatleri
/// hesabın ayar alanında (bkz. `SyncedSettingsDomains`).
func hostedSyncedSettingsDomains(accountKey: String) throws -> SyncedSettingsDomains {
    SyncedSettingsDomains(valuesDomain: try hostedBundleIdentifier(), accountSuite: try hostedAccountSuiteName(accountKey: accountKey))
}

/// Ayarlar değişince (`UserDefaults.didChangeNotification`) ve hesap yüklenince çağrılır: yüklü hesabın eşitlenen
/// ayarlarında bu cihazda yapılan değişikliklere değişiklik anını yazar (Mac ile iPhone arasında ayar başına son yazan
/// kazanır; bkz. `recordSyncedSettingChanges`). Başka cihazdan gelip uygulanan değerler değişiklik sayılmaz. Hesap
/// yüklü değilse bir şey yapmaz.
@MainActor
func recordHostedSyncedSettingChanges() {
    guard case .loaded(let accountKey) = HostedAccount.shared.dataState else {
        return
    }
    do {
        try recordSyncedSettingChanges(domains: try hostedSyncedSettingsDomains(accountKey: accountKey), now: Date())
    } catch {
        hostedScopeLogger.error("Eşitlenen ayar değişiklikleri kaydedilemedi, hata: \(String(describing: error), privacy: .public)")
    }
}

/// Yüklü hesabın ayar alanı; hesap yüklenmediyse `accountNotSelected`.
func hostedActiveAccountDefaults() throws -> UserDefaults {
    guard let key = AppPaths.activeAccountKey() else {
        throw StorageError.accountNotSelected
    }
    return try hostedAccountDefaults(accountKey: key)
}

/// Bu cihazda kayıtlı oturumun kullanıcısı (Anahtar Zinciri; ağa gidilmez); oturum yoksa nil. Servis adı tanımlı
/// değilse ya da Anahtar Zinciri okunamazsa hata fırlar.
func hostedStoredUserID(bundle: Bundle) throws -> String? {
    try HostedKeychainTokenStorage(service: hostedKeychainService(bundle: bundle)).load()?.userId
}
