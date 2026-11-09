import AINotepadCore
import AVFoundation
import Foundation
import os

// iPhone'un abonelik hesabına bağlandığı noktalar: hesap verisinin hazırlanması (Mac'teki karşılığı
// App/Hosted/HostedAccountData.swift), kaydı engelleyen hak durumu ve plan durumunun metinleri, yasal sayfalar.
// iPhone'da abonelik yalnızca uygulama içi satın almayla (App Store, bkz. iOS/Purchases/) alınır; App Store dışı bir
// satın alma yoluna (site, Stripe, müşteri portalı) bağlantı ya da yönlendirme yoktur (App Store 3.1.1).

private let phoneHostedLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneHosted")

/// Giriş yapan hesabın verisini bu süreç için hazırlar ve yükler: bu uygulamanın kabındaki önceki (hesapsız) veri kimse
/// sahiplenmediyse ya da bu hesabınsa hesaba taşınır (bkz. `migrateLegacyUserData`), ad ve tanıma sözlüğü güncellemeden
/// sonra ilk yüklenen hesaba bir kez geçer (bkz. `moveIdentityIntoAccount`), sonra hesap yüklenir. Mac'e özgü başka
/// ayar ve bağlantı taşıması yoktur (iPhone'un kanal ve görev aracı bağlantıları baştan hesabın Anahtar Zinciri
/// servisindedir, bkz. `PhoneIntegrations`). Taşıma başarısız olursa hata fırlar, hesap yüklenmez ve veri yerinde kalır.
func prepareHostedAccountData(userId: String) throws -> String {
    let key: String = accountDataKey(userId: userId)
    let result: LegacyMigrationResult = try migratePhoneLegacyData(accountKey: key)
    try moveIdentityIntoAccount(accountKey: key)
    try AppPaths.activateAccount(key: key)
    phoneHostedLogger.info("Hesap verisi yüklendi, eski veri: \(String(describing: result.claim), privacy: .public), taşınan: \(result.moves.count, privacy: .public)")
    return key
}

/// Yüklü hesabı (`loadedKey`) giriş yapan hesapla yerinde değiştirir (iPhone kendini yeniden başlatamaz): eski veri bu
/// hesabınsa yerinde kalanlar taşınır (başka hesabınsa dokunulmaz), sonra hesap değiştirilir. Yalnız yazan her iş
/// kapalıyken çağrılabilir (`writers`). Taşıma başarısız olursa hata fırlar, eski hesap yüklü kalır.
func switchHostedAccountData(userId: String, from loadedKey: String, writers: ClosedAccountWriters) throws -> String {
    let key: String = accountDataKey(userId: userId)
    let result: LegacyMigrationResult = try migratePhoneLegacyData(accountKey: key)
    try moveIdentityIntoAccount(accountKey: key)
    try AppPaths.switchAccount(from: loadedKey, to: key, writers: writers)
    phoneHostedLogger.info("Hesap verisi değiştirildi, eski veri: \(String(describing: result.claim), privacy: .public), taşınan: \(result.moves.count, privacy: .public)")
    return key
}

/// Bu uygulamanın kabındaki önceki (hesapsız) veriyi hesaba taşır (bkz. `migrateLegacyUserData`); bekleyen kayıtlar
/// sahiplerine gider.
private func migratePhoneLegacyData(accountKey: String) throws -> LegacyMigrationResult {
    let ownerKeys: [String: String] = loadHostedRecordOwners().mapValues { (owner: String) -> String in accountDataKey(userId: owner) }
    return try migrateLegacyUserData(dataRoot: try AppPaths.applicationSupport(), accountKey: accountKey, recordOwnerKeys: ownerKeys)
}

/// Ad ve tanıma sözlüğü güncellemeden önce bu iPhone'un ortak ayarındaydı: güncellemeden sonra ilk yüklenen hesaba bir
/// kez taşınır, sonraki hesaplar boş başlar (başka hesabın adı notlarda "Sen" olarak görünmesin; bkz.
/// `moveIdentityToAccountOnce(source:destination:)`).
private func moveIdentityIntoAccount(accountKey: String) throws {
    let result: IdentityMigrationResult = moveIdentityToAccountOnce(source: .standard, destination: try hostedAccountDefaults(accountKey: accountKey))
    if result.ran {
        phoneHostedLogger.info("Ad ve sözlük hesaba taşındı, taşınan: \(result.moved.count, privacy: .public), yerinde kalan: \(result.kept.count, privacy: .public)")
    }
}

/// Bekleyen hesap değişimi tamamlanamadı.
enum HostedAccountSwitchError: Error, Equatable {
    /// Değişim bekleyen bir hesap yok (`state`: o anki veri durumu) ya da oturum bu arada değişti.
    case noPendingSwitch(state: HostedDataState)
}

/// Kaydı biten toplantının notu: kaydın kendi sunucu oturumunun bütçesinden; kaydın oturumu yoksa hesap çağrısı ve hakkı
/// yoksa (deneme bitti, plan sona erdi) istek sunucuya gitmez (Mac'teki `resolveRecordedMeetingLLMProvider`).
@MainActor
func phoneRecordedMeetingLLMProvider(recordID: String) throws -> LLMProvider {
    let provider: LLMProvider = try hostedRecordedMeetingLLMProvider(recordID: recordID)
    if case .hosted(let config) = provider, config.scope == .account {
        try requireHostedAIAllowance()
    }
    return provider
}

/// Toplantı dışı yapay zekâ çağrıları (Sor, notu yenileme ve düzenleme): kullanıcının hesabından; hakkı yoksa istek
/// sunucuya gitmez (Mac'teki `resolveLLMProvider`).
@MainActor
func phoneAccountLLMProvider() throws -> LLMProvider {
    try requireHostedAIAllowance()
    return try hostedAccountLLMProvider()
}

/// Kaydı engelleyen hak durumunun iPhone metni (`block`, `trialRefusedHere`: sunucu bu hesabın denemesini bu iPhone'da
/// reddetti). Saf fonksiyondur.
func phoneStartBlockText(block: HostedStartBlock, trialRefusedHere: Bool, now: Date) -> String {
    switch block {
    case .trialEnded where trialRefusedHere:
        String(localized: "Bu iPhone'da ücretsiz deneme başka bir hesapla kullanıldı.")
    case .trialEnded:
        String(localized: "Ücretsiz denemen bitti.")
    case .monthlyCapReached:
        String(localized: "Bu ayki kullanım sınırın doldu; \(hostedResetDayText(now: now)) tarihinde sıfırlanır.")
    case .subscriptionEnded:
        String(localized: "Planın sona erdi.")
    case .paymentOverdue:
        String(localized: "Ödeme alınamadığı için yeni toplantı başlatılamıyor.")
    }
}

/// Kaydı başlatmadan önce gösterilen engel (Mac'teki `hostedStartBlockNotice`'in iPhone karşılığı): hak durumu
/// okunamıyorsa (çevrimdışı) son bilinen hak durumu son 7 günde izin vermediyse neden; hak durumu kaydı engelliyorsa
/// neden; kayıt başlayabilirse nil.
@MainActor
func phoneStartBlockMessage(account: HostedAccount, now: Date) -> String? {
    if case .signedInStatusUnknown = account.state {
        // İzin oturumdaki kullanıcınınsa geçer (başka hesabın son izni bu hesaba kayıt açmaz).
        let minutes: Int? = hostedOfflineRecordingMinutes(permit: loadHostedOfflinePermit(), userId: account.signedInUserIDCache, now: now)
        return minutes == nil ? userFacingMessage(error: HostedClientError.offlineNotAllowed) : nil
    }
    guard case .signedIn(let entitlements) = account.state, let block = hostedStartBlock(entitlements: entitlements, now: now) else {
        return nil
    }
    return phoneStartBlockText(block: block, trialRefusedHere: account.isTrialRefusedOnThisMac, now: now)
}

/// Kayıt uygulama açılmadan (Denetim Merkezi, Kısayollar) başlatılabilir mi: giriş yapılmış, yapay zekâ açıklaması
/// onaylanmış, hak durumu engellemiyor ve mikrofon izni verilmiş olmalı. Değilse niyet uygulamayı açar (izin penceresi,
/// giriş ya da abonelik ekranı yalnız önde gösterilebilir).
@MainActor
func canStartRecordingInBackground() -> Bool {
    let account: HostedAccount = HostedAccount.shared
    guard !account.requiresSignIn, UserDefaults.standard.bool(forKey: PhoneSettingsKey.aiDisclosureAccepted),
          phoneStartBlockMessage(account: account, now: Date()) == nil else {
        return false
    }
    return AVAudioApplication.shared.recordPermission == .granted
}

/// Hâlâ geçerli hata mesajları: abonelik etkinse aboneliğin çözdüğü retler ("deneme bitti", "bu cihazda deneme
/// kullanıldı"…) düşer (Mac'teki `resolvedErrorMessages` gibi).
@MainActor
func phoneUnresolvedErrors(messages: [String], account: HostedAccount) -> [String] {
    guard case .signedIn(let entitlements) = account.state else {
        return messages
    }
    switch hostedPlanStatus(entitlements: entitlements, now: Date()) {
    case .subscribed, .complimentary, .ending, .grace:
        let resolved: [String] = hostedMessagesResolvedBySubscription()
        return messages.filter { !resolved.contains($0) }
    case .trial, .expired, .paymentOverdue:
        return messages
    }
}

/// Sitedeki yasal sayfa (`privacy`, `terms`); site adresi geçersizse nil (bağlantı gösterilmez, hata loglanır).
func phoneLegalURL(path: String) -> URL? {
    do {
        return try HostedServices.siteBase().appending(path: path)
    } catch {
        phoneHostedLogger.error("Site adresi geçersiz, yasal bağlantı gösterilmiyor, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

/// Abonelik ekranının kendiliğinden bir kez açılacağı durumun anahtarı (UserDefaults; gösterilince işaretlenir): deneme
/// bitti (hesap başına bir kez) ya da abonelik sona erdi (biten dönem başına bir kez). Engel yoksa, aylık sınır dolduysa
/// ya da ödeme gecikmişse (yeni abonelik çözmez) nil. Saf fonksiyondur.
func phoneAutoPaywallKey(state: HostedAccountState) -> String? {
    guard case .signedIn(let entitlements) = state, let block = hostedStartBlock(entitlements: entitlements, now: Date()) else {
        return nil
    }
    switch block {
    case .trialEnded:
        return "phone.paywall.auto.trialEnded.\(entitlements.userId)"
    case .subscriptionEnded:
        let periodEnd: Int = Int(entitlements.subscription?.currentPeriodEnd.timeIntervalSince1970 ?? 0)
        return "phone.paywall.auto.subscriptionEnded.\(entitlements.userId).\(periodEnd)"
    case .monthlyCapReached, .paymentOverdue:
        return nil
    }
}

/// Hesap ekranında aboneliğin nerede yönetileceği.
enum PhoneSubscriptionManagement: Equatable {
    /// Abonelik yok (deneme ya da sona ermiş): "Abone ol" abonelik ekranını açar.
    case subscribe
    /// App Store aboneliği: "Aboneliği yönet" Apple'ın abonelik penceresini açar.
    case appStore
    /// Web (Stripe) aboneliği: yalnızca "web'de yönetiliyor" yazar; bağlantı yok (App Store 3.1.1).
    case web
    /// Ücretsiz tam erişim: yönetilecek bir şey yok.
    case nothing
}

/// Hak durumundan hesap ekranının abonelik satırı: erişimi süren ya da ödemesi sorunlu App Store aboneliği Apple'da,
/// erişimi süren ya da ödemesi gecikmiş Stripe aboneliği web'de yönetilir; ücretsiz erişimde bir şey yok; gerisinde
/// abone olunur. Saf fonksiyondur.
func phoneSubscriptionManagement(entitlements: HostedEntitlements) -> PhoneSubscriptionManagement {
    if let appStore = entitlements.appStoreSubscription, appStore.access != .none || appStore.status == "billing_issue" {
        return .appStore
    }
    switch hostedPlanStatus(entitlements: entitlements, now: Date()) {
    case .subscribed, .ending, .grace, .paymentOverdue:
        return entitlements.subscription?.paymentSource == .appStore ? .appStore : .web
    case .complimentary:
        return .nothing
    case .trial, .expired:
        return .subscribe
    }
}
