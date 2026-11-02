import Foundation

// iPhone'daki App Store aboneliğinin saf mantığı (RevenueCat'e bağlanan adaptör iOS/Purchases/ içinde): RevenueCat
// kimliğinin hesapla eşlenmesi, abonelik ekranının durum makinesi ve satın almadan sonra sunucudaki hakkın beklenmesi.
// Sunucu tarafı: server/src/appStore.ts (`app_user_id` = hesap kimliği, `users.id`).

/// RevenueCat kimliğini giriş yapan hesapla eşlemek için yapılacak iş.
public enum PurchaseIdentityAction: Equatable, Sendable {
    /// RevenueCat zaten bu hesapla (ya da oturum yokken anonim).
    case none
    /// Bu hesap kimliğiyle giriş (`Purchases.logIn`): satın alma sunucuda bu hesaba yazılır.
    case logIn(userID: String)
    /// Hesaptan çıkıldı: RevenueCat anonim kimliğe döner (`Purchases.logOut`); sonraki hesabın satın alması öncekine
    /// yazılmaz.
    case logOut
}

/// RevenueCat'in şimdiki kimliğinden (`currentAppUserID`, anonimse `isAnonymous`) giriş yapan hesaba (`signedInUserID`;
/// oturum yoksa nil) geçmek için gereken iş. Saf fonksiyondur.
public func purchaseIdentityAction(currentAppUserID: String, isAnonymous: Bool, signedInUserID: String?) -> PurchaseIdentityAction {
    guard let signedInUserID else {
        return isAnonymous ? .none : .logOut
    }
    return !isAnonymous && currentAppUserID == signedInUserID ? .none : .logIn(userID: signedInUserID)
}

/// Hesabın App Store aboneliği sunucuda erişim veriyor mu: `subscriptionSources`'ta `app_store` var ya da App Store
/// aboneliğinin erişimi sürüyor (etkin ya da ek sürede). Satın alma ve geri yüklemeden sonra beklenen durum. Saf
/// fonksiyondur.
public func hostedAppStoreAccessActive(entitlements: HostedEntitlements) -> Bool {
    if entitlements.subscriptionSources?.contains(HostedPaymentSource.appStore.rawValue) == true {
        return true
    }
    guard let subscription = entitlements.appStoreSubscription else {
        return false
    }
    return subscription.access != .none
}

/// Satın almadan sonra sunucudaki hakkın beklendiği aralıklar (sn): ilk deneme hemen (eşitleme ucu RevenueCat'ten
/// okur), sonra giderek seyrelen aralıklarla yaklaşık 30 sn. RevenueCat webhook'u genellikle birkaç saniyede gelir.
public let hostedAppStoreEntitlementDelays: [Double] = [1, 2, 3, 4, 5, 6, 8]

/// Hak beklemesinin sonraki adımı.
public enum HostedEntitlementWaitStep: Equatable, Sendable {
    /// Hak geldi: bekleme biter.
    case arrived
    /// Bu kadar saniye sonra yeniden sorulur.
    case retry(afterSeconds: Double)
    /// Denemeler bitti, hak gelmedi: kullanıcıya açık hata gösterilir (sessizce vazgeçilmez).
    case gaveUp
}

/// `completedAttempts` deneme yapıldıktan sonra (son okunan hak durumu `latest`; okunamadıysa nil) yapılacak iş:
/// hak geldiyse biter, `delays`'te sıradaki aralık varsa bekleyip yeniden sorar, yoksa vazgeçer. Saf fonksiyondur.
public func hostedEntitlementWaitStep(latest: HostedEntitlements?, completedAttempts: Int, delays: [Double]) -> HostedEntitlementWaitStep {
    if let latest, hostedAppStoreAccessActive(entitlements: latest) {
        return .arrived
    }
    let index: Int = completedAttempts - 1
    guard index >= 0, delays.indices.contains(index) else {
        return .gaveUp
    }
    return .retry(afterSeconds: delays[index])
}

// MARK: Abonelik ekranı

/// Abonelik ekranının durumu.
public enum PaywallPhase: Equatable, Sendable {
    /// Paketler (fiyatlar App Store'dan) okunuyor.
    case loadingProducts
    /// Paketler okunamadı; neden gösterilir, "Yeniden dene" yeniden okur.
    case productsUnavailable(message: String)
    /// Paketler hazır, kullanıcı seçiyor.
    case choosing
    /// Apple'ın satın alma penceresi açık.
    case purchasing(plan: HostedBillingPlan)
    /// Önceki satın almalar geri yükleniyor.
    case restoring
    /// Apple ödemeyi onayladı; sunucudaki hak bekleniyor ("Satın alman tamamlanıyor…").
    case finishing
    /// Hak sunucuda göründü.
    case completed
    /// Geri yüklenecek etkin abonelik yok.
    case nothingToRestore
    /// Satın alma ya da geri yükleme başarısız; ekran seçime döner, neden görünür.
    case purchaseFailed(message: String)
    /// Ödeme alındı ama hak sunucuda görünmedi: "Yeniden dene" beklemeyi yeniden başlatır (ödeme yeniden alınmaz).
    case finishingFailed(message: String)
}

/// Abonelik ekranındaki olaylar.
public enum PaywallEvent: Equatable, Sendable {
    case productsLoaded
    case productsFailed(message: String)
    case retryProducts
    case purchaseTapped(plan: HostedBillingPlan)
    case restoreTapped
    /// Kullanıcı Apple'ın penceresini kapattı.
    case purchaseCancelled
    /// Apple işlemi onayladı (satın alma ya da etkin abonelik bulan geri yükleme).
    case storeConfirmed
    /// Geri yükleme etkin abonelik bulmadı.
    case restoreFoundNothing
    case storeFailed(message: String)
    case entitlementArrived
    case entitlementTimedOut(message: String)
    case retryFinishing
}

/// Durum makinesi: geçersiz olay (ör. satın alma sürerken ikinci dokunuş) durumu değiştirmez. Saf fonksiyondur.
public func paywallPhase(current: PaywallPhase, event: PaywallEvent) -> PaywallPhase {
    switch (current, event) {
    case (.loadingProducts, .productsLoaded):
        return .choosing
    case (.loadingProducts, .productsFailed(let message)):
        return .productsUnavailable(message: message)
    case (.productsUnavailable, .retryProducts):
        return .loadingProducts
    case (.choosing, .purchaseTapped(let plan)), (.nothingToRestore, .purchaseTapped(let plan)), (.purchaseFailed, .purchaseTapped(let plan)):
        return .purchasing(plan: plan)
    case (.choosing, .restoreTapped), (.nothingToRestore, .restoreTapped), (.purchaseFailed, .restoreTapped):
        return .restoring
    // Geri yükleme fiyatlar okunamasa da yapılabilir (önceki satın alma App Store hesabında).
    case (.productsUnavailable, .restoreTapped):
        return .restoring
    case (.purchasing, .purchaseCancelled):
        return .choosing
    case (.purchasing, .storeConfirmed), (.restoring, .storeConfirmed):
        return .finishing
    case (.restoring, .restoreFoundNothing):
        return .nothingToRestore
    case (.purchasing, .storeFailed(let message)), (.restoring, .storeFailed(let message)):
        return .purchaseFailed(message: message)
    case (.finishing, .entitlementArrived):
        return .completed
    case (.finishing, .entitlementTimedOut(let message)):
        return .finishingFailed(message: message)
    case (.finishingFailed, .retryFinishing):
        return .finishing
    default:
        return current
    }
}

/// Ekran kullanıcının işlemi beklerken kilitli mi (satın alma, geri yükleme ya da hak beklemesi sürüyor): düğmeler
/// kapalı, ekran kaydırarak kapatılamaz. Saf fonksiyondur.
public func isPaywallBusy(phase: PaywallPhase) -> Bool {
    switch phase {
    case .purchasing, .restoring, .finishing:
        true
    case .loadingProducts, .productsUnavailable, .choosing, .completed, .nothingToRestore, .purchaseFailed, .finishingFailed:
        false
    }
}

/// Paket seçimi yapılabilir mi (fiyatlar okundu, iş sürmüyor). Saf fonksiyondur.
public func canChoosePaywallPackage(phase: PaywallPhase) -> Bool {
    switch phase {
    case .choosing, .nothingToRestore, .purchaseFailed:
        true
    case .loadingProducts, .productsUnavailable, .purchasing, .restoring, .finishing, .completed, .finishingFailed:
        false
    }
}

// MARK: Hesap silme

/// Hesap silinirken aboneliğe ne olacağı (silme onayında söylenir).
public enum HostedDeletionSubscriptionEffect: Equatable, Sendable {
    /// Süren abonelik yok.
    case none
    /// Web (Stripe) aboneliği silmeyle hemen iptal edilir.
    case stripeCanceled
    /// App Store aboneliği silmeyle iptal olmaz: Apple yenilemeye devam eder; kullanıcı Apple'da iptal etmeli.
    case appStoreKeepsRenewing
    /// App Store aboneliği zaten yenilenmeyecek (iptal edilmiş); dönem sonuna dek sürer, yeniden ücret alınmaz.
    case appStoreEnding
    /// İkisi birden: Stripe iptal edilir, App Store aboneliği Apple'da iptal edilmeli.
    case stripeCanceledAppStoreKeepsRenewing
}

/// Hak durumundan silmenin aboneliğe etkisi: erişimi süren Stripe aboneliği iptal edilir (sunucu `closeStripeForDeletion`);
/// erişimi süren App Store aboneliği iptal edilmez (sunucu `accountDeletionResult`). Ücretsiz erişimin faturası yoktur.
/// Saf fonksiyondur.
public func hostedDeletionSubscriptionEffect(entitlements: HostedEntitlements) -> HostedDeletionSubscriptionEffect {
    let sources: [String] = entitlements.subscriptionSources ?? []
    let stripe: Bool = sources.contains(HostedPaymentSource.stripe.rawValue) && entitlements.subscription?.complimentary != true
    let appStore: HostedAppStoreSubscription? = entitlements.appStoreSubscription.flatMap { $0.access == .none ? nil : $0 }
    switch (stripe, appStore) {
    case (true, .some(let subscription)) where subscription.willRenew:
        return .stripeCanceledAppStoreKeepsRenewing
    case (true, _):
        return .stripeCanceled
    case (false, .some(let subscription)):
        return subscription.willRenew ? .appStoreKeepsRenewing : .appStoreEnding
    case (false, nil):
        return .none
    }
}

// MARK: Fiyatlar

/// Yıllık planın 12 aylık ödemeye göre tasarrufu (yüzde, aşağı yuvarlanır: "en az bu kadar"); fiyatlar App Store'un
/// kullanıcının bölgesindeki fiyatlarıdır (sabit yazılmaz). Aylık fiyat sıfırsa ya da tasarruf yoksa nil. Saf fonksiyondur.
public func yearlySavingsPercent(monthlyPrice: Decimal, yearlyPrice: Decimal) -> Int? {
    let twelveMonths: Decimal = monthlyPrice * 12
    guard twelveMonths > 0 else {
        return nil
    }
    let ratio: Double = NSDecimalNumber(decimal: (twelveMonths - yearlyPrice) / twelveMonths).doubleValue
    let percent: Int = Int((ratio * 100).rounded(.down))
    return percent > 0 ? percent : nil
}

/// Satın almadan sonra hak sunucuda görünmedi (webhook ve eşitleme gecikti ya da sunucu RevenueCat'e ulaşamadı). Ödeme
/// Apple'da alınmıştır; yeniden denemek ödemeyi yinelemez.
public struct HostedAppStoreEntitlementMissing: Error, Equatable, Sendable {
    /// Yapılan deneme sayısı.
    public let attempts: Int
    /// Son denemenin hatası (okunamadıysa); hak okunduysa ama App Store aboneliği yoksa nil.
    public let lastError: String?

    public init(attempts: Int, lastError: String?) {
        self.attempts = attempts
        self.lastError = lastError
    }
}
