import Foundation
import os

// Kullanıcının adı (notta "Sen" ve sana düşen görevler) ve tanıma sözlüğü. Geliştirici sürümünde standart ayarlardadır;
// abonelikte (Mac ve iPhone Gistsmith) hesabın ayar alanındadır: aynı cihazda başka bir hesapla giriş yapılınca önceki
// hesabın adı notlarda görünmez. Güncellemeden önce standart ayarlarda duran değerler, güncellemeden sonra ilk yüklenen
// hesaba bir kez taşınır (bkz. `moveIdentityToAccountOnce`).

private let accountIdentityLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AccountIdentity")

/// Kullanıcının adının ayar anahtarı (Mac ve iPhone'da aynı).
public let userNameDefaultsKey: String = "userName"

/// Tanıma sözlüğünün ayar anahtarı (satır başına bir ad ya da terim; Mac ve iPhone'da aynı).
public let customVocabularyDefaultsKey: String = "customVocabulary"

/// Hesaba taşınan kimlik ayarları.
public let accountIdentityDefaultsKeys: [String] = [userNameDefaultsKey, customVocabularyDefaultsKey]

/// Standart ayarlarda: kimlik ayarlarının taşınması yapıldı (bir hesaba taşındı ya da taşınacak bir şey yoktu); sonraki
/// hesaplara taşıma yapılmaz.
public let accountIdentityMigratedKey: String = "migration.identityToAccount"

/// Kimlik ayarlarının hesaba taşınmasının sonucu.
public struct IdentityMigrationResult: Equatable, Sendable {
    /// Taşıma bu çağrıda yapıldı (güncellemeden sonra ilk yüklenen hesap); false: daha önce yapılmıştı.
    public let ran: Bool
    /// Hesaba taşınan anahtarlar.
    public let moved: [String]
    /// Hesapta zaten değeri olduğu için taşınmayan anahtarlar: standart ayardaki değer yerinde kalır (silinmez; artık
    /// okunmaz).
    public let kept: [String]
}

/// Standart ayarlardaki adı ve tanıma sözlüğünü (`source`) hesabın ayar alanına (`destination`) bir kez taşır: yalnızca
/// güncellemeden sonra ilk yüklenen hesap alır (taşıma işareti `source`'a yazılır, sonraki hesaplar boş başlar). Boş
/// değer taşınmaz. Hesapta zaten dolu bir değer varsa üzerine yazılmaz. Taşınan değer `source`'tan silinir: ayar
/// alanları aynı süreçte okunur, iki yerde kalmaz.
public func moveIdentityToAccountOnce(source: UserDefaults, destination: UserDefaults) -> IdentityMigrationResult {
    guard !source.bool(forKey: accountIdentityMigratedKey) else {
        return IdentityMigrationResult(ran: false, moved: [], kept: [])
    }
    var moved: [String] = []
    var kept: [String] = []
    for key in accountIdentityDefaultsKeys {
        guard let value = source.string(forKey: key), !value.isEmpty else {
            continue
        }
        guard (destination.string(forKey: key) ?? "").isEmpty else {
            accountIdentityLogger.warning("Kimlik ayarı hesapta zaten var, eski değer yerinde bırakıldı, anahtar: \(key, privacy: .public)")
            kept.append(key)
            continue
        }
        destination.set(value, forKey: key)
        source.removeObject(forKey: key)
        moved.append(key)
        accountIdentityLogger.info("Kimlik ayarı hesaba taşındı, anahtar: \(key, privacy: .public)")
    }
    source.set(true, forKey: accountIdentityMigratedKey)
    return IdentityMigrationResult(ran: true, moved: moved, kept: kept)
}
