import AINotepadCore
import Foundation
import os

/// Yapay zekâ açıklamasının onayı hesap başınadır (`PhoneAIDisclosure`): onay oturumdaki hesabın ayar alanında
/// (`hostedAccountDefaults`) tutulur. Bu iPhone'da başka bir hesapla giriş yapılınca açıklama o hesaba yeniden gösterilir;
/// hesap silinince onayı da gider (bkz. `HostedAccount.finishAccountDeletion`). Tanıtım modunda (giriş yok) onay ortak
/// ayardadır (`--aciklama` yeniden gösterir).

private let consentLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneAIConsent")

/// Oturumdaki hesap yapay zekâ açıklamasını onayladı mı. Oturum yoksa (giriş kapısı açık) false. Önceki sürümlerin
/// cihaz başına onayı, ilk giren hesabın onayı sayılır (`migrateLegacyPhoneAIConsent` onu o hesaba taşır).
@MainActor
func phoneAIConsentGiven(account: HostedAccount) -> Bool {
    if phoneIsDemoLaunch() {
        return UserDefaults.standard.bool(forKey: PhoneSettingsKey.aiDisclosureAccepted)
    }
    guard let userID = account.signedInUserIDCache else {
        return false
    }
    if UserDefaults.standard.bool(forKey: PhoneSettingsKey.aiDisclosureAccepted) {
        return true
    }
    do {
        return try hostedAccountDefaults(accountKey: accountDataKey(userId: userID)).bool(forKey: hostedAIDisclosureAcceptedKey)
    } catch {
        consentLogger.error("Hesabın ayar alanı okunamadı, yapay zekâ onayı yok sayıldı, hata: \(String(describing: error), privacy: .private)")
        return false
    }
}

/// Oturumdaki hesabın onayını saklar. Hesabın ayar alanı açılamazsa hata fırlatır (onay saklanmadan devam edilmez).
@MainActor
func recordPhoneAIConsent(account: HostedAccount) throws {
    if phoneIsDemoLaunch() {
        UserDefaults.standard.set(true, forKey: PhoneSettingsKey.aiDisclosureAccepted)
        return
    }
    guard let userID = account.signedInUserIDCache else {
        throw PhoneAIConsentError.signedOut
    }
    try hostedAccountDefaults(accountKey: accountDataKey(userId: userID)).set(true, forKey: hostedAIDisclosureAcceptedKey)
}

/// Önceki sürümlerin cihaz başına onayını oturumdaki hesaba taşır ve ortak ayardan siler (sonraki hesaplar açıklamayı
/// kendileri görür). Oturum yoksa ya da tanıtım modunda bir şey yapmaz.
@MainActor
func migrateLegacyPhoneAIConsent(account: HostedAccount) {
    guard !phoneIsDemoLaunch(), let userID = account.signedInUserIDCache,
          UserDefaults.standard.bool(forKey: PhoneSettingsKey.aiDisclosureAccepted) else {
        return
    }
    do {
        try hostedAccountDefaults(accountKey: accountDataKey(userId: userID)).set(true, forKey: hostedAIDisclosureAcceptedKey)
        UserDefaults.standard.removeObject(forKey: PhoneSettingsKey.aiDisclosureAccepted)
    } catch {
        consentLogger.error("Eski yapay zekâ onayı hesaba taşınamadı, hata: \(String(describing: error), privacy: .private)")
    }
}

/// Onay saklanamadı.
enum PhoneAIConsentError: Error, CustomStringConvertible {
    /// Oturum yok: onay bir hesaba yazılamaz.
    case signedOut

    var description: String {
        switch self {
        case .signedOut:
            String(localized: "Onay saklanamadı: oturum açık değil. Yeniden giriş yap.")
        }
    }
}
