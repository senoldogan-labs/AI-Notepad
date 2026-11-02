import AINotepadCore
import Foundation
import os
import RevenueCat
import StoreKit
import UIKit

// App Store aboneliğinin RevenueCat bağlantısı (dış sistem adaptörü): yapılandırma, hesap kimliği, paketler (fiyatlar
// StoreKit'ten, kullanıcının bölgesinde), satın alma, geri yükleme ve Apple'ın abonelik yönetimi penceresi. Kararlar
// (kimlik eşleme, ekran durumu, hak beklemesi) çekirdekte saf fonksiyonlardır: Packages/.../Hosted/HostedAppStore.swift.
// RevenueCat projesi "Gistsmith": ürünler `com.senoldogan.gistsmith.monthly` ve `.yearly`, ikisi de `pro` hakkında,
// teklif `default` (`$rc_monthly`, `$rc_annual`). Sunucu satın almayı RevenueCat'ten okur (bkz. server/src/appStore.ts).

private let purchasesLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AppStorePurchases")

/// RevenueCat'teki hak (her iki ürün de buna bağlı).
private let proEntitlementID: String = "pro"

/// Info.plist'teki RevenueCat anahtarının adı (project.yml, `REVENUECAT_API_KEY`).
private let revenueCatAPIKeyInfoKey: String = "RevenueCatAPIKey"

/// App Store satın almasının hataları.
enum AppStorePurchaseError: Error, Equatable {
    /// Info.plist'te RevenueCat anahtarı yok ya da biçimsiz (derleme yapılandırması hatası).
    case apiKeyMissing(value: String)
    /// RevenueCat'te geçerli teklif (`default`) yok ya da paketleri boş.
    case offeringUnavailable
    /// Teklifte planın paketi yok (RevenueCat panelindeki paket kimlikleri değişmiş).
    case packageMissing(plan: HostedBillingPlan)
    /// Bu plan için paket henüz okunmadı (ekran paketleri okumadan satın alma istendi).
    case packagesNotLoaded
    /// RevenueCat açılışta yapılandırılamadı (bkz. `apiKeyMissing`).
    case notConfigured
    /// Uygulamanın sahnesi yok (Apple'ın abonelik penceresi açılamadı).
    case noWindowScene
    /// RevenueCat ya da StoreKit hatası (`code`: RevenueCat `ErrorCode`; `detail` hata ayıklama içindir, İngilizce).
    case store(code: Int, detail: String)
}

/// Ekranda gösterilen paket: plan, App Store'un yerel fiyatı ve dönemi.
struct PaywallPackage: Identifiable, Equatable {
    let plan: HostedBillingPlan
    let productID: String
    /// Ürünün App Store'daki adı (ör. "Gistsmith Monthly").
    let title: String
    /// Yerel para biriminde fiyat, ör. "$5.99".
    let priceText: String
    let price: Decimal
    /// Yıllık planın aylık karşılığı, ör. "$4.08"; aylıkta nil.
    let monthlyEquivalentText: String?

    var id: String { productID }
}

/// Satın almanın sonucu.
enum StorePurchaseOutcome: Equatable {
    /// Apple işlemi onayladı.
    case confirmed
    /// Kullanıcı Apple'ın penceresini kapattı.
    case cancelled
}

/// Geri yüklemenin sonucu.
enum StoreRestoreOutcome: Equatable {
    /// Etkin abonelik bulundu (bu hesaba aktarıldı).
    case confirmed
    /// App Store hesabında etkin abonelik yok.
    case nothingFound
}

/// RevenueCat bağlantısı. Uygulama açılırken bir kez yapılandırılır (`configure`); RevenueCat kimliği giriş yapan hesabın
/// kimliğiyle eşlenir (`syncIdentity`): satın alma sunucuda bu hesaba yazılır (`app_user_id` = hesap kimliği).
@MainActor
final class AppStorePurchases {
    static let shared: AppStorePurchases = AppStorePurchases()

    /// Son okunan teklifin paketleri (plan → RevenueCat paketi); satın alma bunlardan yapılır.
    private var packagesByPlan: [HostedBillingPlan: Package] = [:]
    /// Süren kimlik eşlemesi: art arda gelen eşlemeler sırayla çalışır (logIn ve logOut yarışmasın).
    private var identityTask: Task<Void, Never>?

    private init() {}

    /// RevenueCat'i açılışta bir kez yapılandırır; oturum varsa hesabın kimliğiyle (anonim kimlik hiç oluşmaz), yoksa
    /// anonim. Anahtar Info.plist'te yoksa hata fırlar (derleme yapılandırması hatası); o zaman abonelik ekranı hatayı
    /// gösterir, satın alma yapılmaz.
    func configure(userID: String?) throws {
        guard !Purchases.isConfigured else {
            return
        }
        let value: String = Bundle.main.object(forInfoDictionaryKey: revenueCatAPIKeyInfoKey) as? String ?? ""
        guard value.hasPrefix("appl_") else {
            throw AppStorePurchaseError.apiKeyMissing(value: value)
        }
        #if DEBUG
        Purchases.logLevel = .info
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(with: Configuration.Builder(withAPIKey: value).with(appUserID: userID).build())
        purchasesLogger.info("RevenueCat yapılandırıldı, oturum: \(userID != nil, privacy: .public)")
    }

    /// RevenueCat kimliğini giriş yapan hesapla eşler (giriş, çıkış, hesap değişimi, hesap silme; arka planda, sırayla).
    /// Başarısız eşleme loglanır; satın alma ve geri yükleme öncesi `ensureIdentity` yeniden dener ve hatayı gösterir.
    func syncIdentity(userID: String?) {
        let previous: Task<Void, Never>? = identityTask
        identityTask = Task { @MainActor in
            await previous?.value
            do {
                try await self.applyIdentity(userID: userID)
            } catch {
                purchasesLogger.warning("RevenueCat kimliği eşlenemedi, hata: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Satın alma ve geri yükleme öncesi: RevenueCat bu hesabın kimliğinde değilse giriş yapılır; olmazsa hata fırlar
    /// (satın alma başka bir kimliğe yazılmasın).
    func ensureIdentity(userID: String) async throws {
        await identityTask?.value
        try await applyIdentity(userID: userID)
    }

    /// Yapılandırılmış RevenueCat; açılışta yapılandırılamadıysa (anahtar yok) hata.
    private func configuredPurchases() throws -> Purchases {
        guard Purchases.isConfigured else {
            throw AppStorePurchaseError.notConfigured
        }
        return Purchases.shared
    }

    private func applyIdentity(userID: String?) async throws {
        let purchases: Purchases = try configuredPurchases()
        switch purchaseIdentityAction(currentAppUserID: purchases.appUserID, isAnonymous: purchases.isAnonymous, signedInUserID: userID) {
        case .none:
            return
        case .logIn(let id):
            do {
                _ = try await purchases.logIn(id)
                purchasesLogger.info("RevenueCat hesaba bağlandı")
            } catch {
                throw storeError(error: error)
            }
        case .logOut:
            do {
                _ = try await purchases.logOut()
                purchasesLogger.info("RevenueCat hesaptan çıktı (anonim)")
            } catch {
                throw storeError(error: error)
            }
        }
    }

    /// Geçerli teklifin aylık ve yıllık paketleri (fiyatlar StoreKit'ten). Teklif ya da paket yoksa hata.
    func loadPackages() async throws -> [PaywallPackage] {
        let offerings: Offerings
        do {
            offerings = try await configuredPurchases().offerings()
        } catch {
            throw storeError(error: error)
        }
        guard let offering = offerings.current else {
            throw AppStorePurchaseError.offeringUnavailable
        }
        let byPlan: [HostedBillingPlan: Package] = try [HostedBillingPlan.monthly, .yearly].reduce(into: [:]) {
            (result: inout [HostedBillingPlan: Package], plan: HostedBillingPlan) throws -> Void in
            guard let package = plan == .monthly ? offering.monthly : offering.annual else {
                throw AppStorePurchaseError.packageMissing(plan: plan)
            }
            result[plan] = package
        }
        packagesByPlan = byPlan
        return [HostedBillingPlan.yearly, .monthly].compactMap { (plan: HostedBillingPlan) -> PaywallPackage? in
            byPlan[plan].map { (package: Package) -> PaywallPackage in
                PaywallPackage(
                    plan: plan, productID: package.storeProduct.productIdentifier, title: package.storeProduct.localizedTitle,
                    priceText: package.storeProduct.localizedPriceString, price: package.storeProduct.price,
                    monthlyEquivalentText: plan == .yearly ? package.storeProduct.localizedPricePerMonth : nil
                )
            }
        }
    }

    /// Planı Apple'ın satın alma penceresiyle satın alır. Kullanıcı vazgeçerse `cancelled`; Apple onaylarsa `confirmed`
    /// (hak sunucuda ayrıca beklenir). Onay bekleyen (Satın Alma İzni) ödeme `store` hatasıdır.
    func purchase(plan: HostedBillingPlan) async throws -> StorePurchaseOutcome {
        guard let package = packagesByPlan[plan] else {
            throw AppStorePurchaseError.packagesNotLoaded
        }
        let purchases: Purchases = try configuredPurchases()
        do {
            let result: PurchaseResultData = try await purchases.purchase(package: package)
            if result.userCancelled {
                purchasesLogger.info("Satın alma penceresi kapatıldı, plan: \(plan.rawValue, privacy: .public)")
                return .cancelled
            }
            purchasesLogger.info("Satın alma Apple'da onaylandı, plan: \(plan.rawValue, privacy: .public), hak etkin: \(result.customerInfo.entitlements[proEntitlementID]?.isActive == true, privacy: .public)")
            return .confirmed
        } catch let error as RevenueCat.ErrorCode where error == .purchaseCancelledError {
            return .cancelled
        } catch {
            throw storeError(error: error)
        }
    }

    /// App Store hesabındaki önceki satın almaları bu hesaba geri yükler.
    func restore() async throws -> StoreRestoreOutcome {
        let purchases: Purchases = try configuredPurchases()
        do {
            let info: CustomerInfo = try await purchases.restorePurchases()
            let active: Bool = info.entitlements[proEntitlementID]?.isActive == true
            purchasesLogger.info("Geri yükleme bitti, hak etkin: \(active, privacy: .public)")
            return active ? .confirmed : .nothingFound
        } catch {
            throw storeError(error: error)
        }
    }

    /// RevenueCat hatasını tipli hataya çevirir (kod ve İngilizce açıklama hata ayıklama içindir).
    private func storeError(error: any Error) -> AppStorePurchaseError {
        let nsError: NSError = error as NSError
        purchasesLogger.error("RevenueCat hatası, kod: \(nsError.code, privacy: .public), alan: \(nsError.domain, privacy: .public), açıklama: \(nsError.localizedDescription, privacy: .public)")
        return .store(code: nsError.code, detail: nsError.localizedDescription)
    }
}

/// Apple'ın abonelik yönetimi penceresini (Ayarlar › Abonelikler) uygulamanın içinde açar; pencere kapanınca döner.
@MainActor
func showAppStoreManageSubscriptions() async throws {
    let scenes: [UIWindowScene] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
        throw AppStorePurchaseError.noWindowScene
    }
    try await AppStore.showManageSubscriptions(in: scene)
}

/// Satın alma hatasının kullanıcı metni. Saf fonksiyondur.
func appStorePurchaseMessage(error: AppStorePurchaseError) -> String {
    switch error {
    case .apiKeyMissing, .notConfigured, .offeringUnavailable, .packageMissing, .packagesNotLoaded:
        return String(localized: "Abonelikler şu an yüklenemiyor; biraz sonra yeniden dene.")
    case .noWindowScene:
        return String(localized: "Apple'ın abonelik penceresi açılamadı; yeniden dene.")
    case .store(let code, let detail):
        switch RevenueCat.ErrorCode(rawValue: code) {
        case .networkError, .offlineConnectionError:
            return String(localized: "App Store'a ulaşılamadı. Bağlantını denetleyip yeniden dene.")
        case .paymentPendingError:
            return String(localized: "Ödeme onay bekliyor (ör. Satın Alma İzni). Onaylanınca aboneliğin kendiliğinden açılır.")
        case .purchaseNotAllowedError:
            return String(localized: "Bu cihazda satın alma kapalı (Ekran Süresi › İçerik ve Gizlilik Sınırlamaları).")
        case .productNotAvailableForPurchaseError:
            return String(localized: "Bu abonelik şu an satın alınamıyor; biraz sonra yeniden dene.")
        default:
            return String(localized: "Satın alma tamamlanamadı: \(detail)")
        }
    }
}

/// Hak sunucuda görünmediğinde kullanıcı metni (ödeme alındı; yeniden denemek ödemeyi yinelemez). Saf fonksiyondur.
func appStoreEntitlementMissingMessage(error: HostedAppStoreEntitlementMissing) -> String {
    let base: String = String(localized: "Apple ödemeyi onayladı ama \(appName) aboneliğini henüz göremiyor. Yeniden ücret alınmaz; “Yeniden dene”ye bas ya da birkaç dakika sonra uygulamayı aç.")
    guard let lastError = error.lastError else {
        return base
    }
    return "\(base) (\(lastError))"
}
