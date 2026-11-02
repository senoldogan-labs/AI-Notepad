import AINotepadCore
import Foundation

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
    /// Başka bir hesapla giriş yapıldı: kayıt ve işleme bitince uygulama yeniden başlar ve o hesabın verisini yükler.
    case relaunchRequired(accountKey: String)
}

/// Hesabın kendi ayar alanı (klasörler, Sor tarifleri, dışa aktarma ayarları, açık sunucu oturumları):
/// `<paket kimliği>.account.<anahtar>`.
func hostedAccountDefaults(accountKey: String) throws -> UserDefaults {
    guard isValidAccountDataKey(key: accountKey) else {
        throw StorageError.invalidAccountKey(key: accountKey)
    }
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
        throw StorageError.writeFailed(path: Bundle.main.bundlePath, reason: "paket kimliği yok, hesabın ayar alanı adlandırılamadı")
    }
    let suite: String = "\(bundleIdentifier).account.\(accountKey)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw StorageError.writeFailed(path: suite, reason: "hesabın ayar alanı açılamadı")
    }
    return defaults
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
