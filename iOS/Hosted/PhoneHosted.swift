import AINotepadCore
import Foundation
import os

// iPhone'un abonelik hesabına bağlandığı noktalar: hesap verisinin hazırlanması (Mac'teki karşılığı
// App/Hosted/HostedAccountData.swift), kaydı engelleyen hak durumu ve plan durumunun metinleri, yasal sayfalar.
// iPhone'da uygulama içinden App Store dışı bir satın alma yoluna yönlendirilmez (App Store 3.1.1): metinler abone
// olmayı önermez, ödeme ya da müşteri portalı bağlantısı vermez; yalnızca durumu söyler.

private let phoneHostedLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneHosted")

/// Giriş yapan hesabın verisini bu süreç için hazırlar ve yükler: bu uygulamanın kabındaki önceki (hesapsız) veri kimse
/// sahiplenmediyse ya da bu hesabınsa hesaba taşınır (bkz. `migrateLegacyUserData`), sonra hesap yüklenir. Mac'e özgü
/// ayar ve bağlantı taşıması yoktur (iPhone'da kanal ve görev aracı bağlantısı yok). Taşıma başarısız olursa hata
/// fırlar, hesap yüklenmez ve veri yerinde kalır.
func prepareHostedAccountData(userId: String) throws -> String {
    let key: String = accountDataKey(userId: userId)
    let ownerKeys: [String: String] = loadHostedRecordOwners().mapValues { (owner: String) -> String in accountDataKey(userId: owner) }
    let result: LegacyMigrationResult = try migrateLegacyUserData(dataRoot: try AppPaths.applicationSupport(), accountKey: key, recordOwnerKeys: ownerKeys)
    try AppPaths.activateAccount(key: key)
    phoneHostedLogger.info("Hesap verisi yüklendi, eski veri: \(String(describing: result.claim), privacy: .public), taşınan: \(result.moves.count, privacy: .public)")
    return key
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
        let minutes: Int? = hostedOfflineRecordingMinutes(
            permit: loadHostedOfflinePermit(), userId: account.signedInUserIDCache, now: now, maxAgeSec: hostedOfflinePermitMaxAgeSec
        )
        return minutes == nil ? userFacingMessage(error: HostedClientError.offlineNotAllowed) : nil
    }
    guard case .signedIn(let entitlements) = account.state, let block = hostedStartBlock(entitlements: entitlements) else {
        return nil
    }
    return phoneStartBlockText(block: block, trialRefusedHere: account.isTrialRefusedOnThisMac, now: now)
}

/// Plan durumunun iPhone metni (hesap ekranı). Saf fonksiyondur.
func phonePlanStatusText(status: HostedPlanStatus) -> String {
    switch status {
    case .trial(let left, _):
        left == 0 ? String(localized: "Ücretsiz denemen bitti.") : String(localized: "Ücretsiz deneme: \(hostedTrialLeftText(left: left)).")
    case .subscribed(let renewsAt):
        String(localized: "Abonelik etkin; dönem \(hostedDayText(date: renewsAt)) tarihinde yenilenir.")
    case .complimentary:
        String(localized: "Ücretsiz tam erişim.")
    case .ending(let endsAt):
        String(localized: "Abonelik \(hostedDayText(date: endsAt)) tarihine kadar etkin, yenilenmeyecek.")
    case .grace(let endsAt):
        String(localized: "Ödeme alınamadı; erişimin \(hostedDayText(date: endsAt)) tarihine kadar sürer.")
    case .paymentOverdue:
        String(localized: "Ödeme alınamadığı için yeni toplantı başlatılamıyor.")
    case .expired(let endedAt):
        String(localized: "Planın \(hostedDayText(date: endedAt)) tarihinde sona erdi.")
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
