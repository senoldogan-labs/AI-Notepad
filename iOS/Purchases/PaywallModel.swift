import AINotepadCore
import Foundation
import os
import SwiftUI

private let paywallLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Paywall")

/// Abonelik ekranının durumu ve işleri: paketleri okur, satın alır ya da geri yükler, sonra hakkın sunucuya gelmesini
/// bekler. Durum geçişleri çekirdekteki saf `paywallPhase` makinesidir; bu sınıf yalnızca RevenueCat ve sunucu
/// çağrılarını yapar ve olayları makineye verir.
@MainActor
@Observable
final class PaywallModel {
    private(set) var phase: PaywallPhase = .loadingProducts
    /// Teklifin okunan bütün paketleri (Pro'nunkiler de; gösterilenler `visiblePackages`).
    private(set) var packages: [PaywallPackage] = []
    /// Seçili katman (önce Kişisel; App Store abonesinde öbür katman).
    var selectedTier: HostedTier = .personal
    /// Seçili plan (önce yıllık; App Store abonesinde şimdiki planı).
    var selectedPlan: HostedBillingPlan = .yearly
    /// Tamamlanan satın alma bir plan değişikliğiydi: ne zaman geçerli olduğu (yeni abonelikte nil).
    private(set) var completedChange: HostedAppStoreChangeTiming?

    private let account: HostedAccount
    private let purchases: AppStorePurchases
    /// Ekranın açılma nedeni (huni telemetrisi ve başlık).
    let trigger: ConversionTrigger
    /// Ekranın gösterildiği bir kez sayıldı.
    private var isShownRecorded: Bool = false

    init(account: HostedAccount, purchases: AppStorePurchases, trigger: ConversionTrigger) {
        self.account = account
        self.purchases = purchases
        self.trigger = trigger
        // Aylık sınırdan gelen Kişisel aboneye Pro, şimdiki plan dönemiyle (yıllık kendiliğinden seçtirilmez).
        selectedTier = account.upsellPreselectedTier
        if selectedTier == .pro, case .signedIn(let entitlements) = account.state, let plan = hostedCurrentBillingPlan(entitlements: entitlements) {
            selectedPlan = plan
        }
    }

    /// Kullanıcı katman seçti (huniye yazılır).
    func select(tier: HostedTier) {
        guard tier != selectedTier else {
            return
        }
        selectedTier = tier
        account.recordConversion(.planSelected(surface: .paywall, trigger: trigger, tier: tier, plan: selectedPlan))
    }

    /// Kullanıcı plan dönemi seçti (huniye yazılır).
    func select(plan: HostedBillingPlan) {
        guard plan != selectedPlan else {
            return
        }
        selectedPlan = plan
        account.recordConversion(.planSelected(surface: .paywall, trigger: trigger, tier: showsPro ? selectedTier : .personal, plan: plan))
    }

    /// Ekran satın almadan kapatıldı (huniye yazılır).
    func recordClosed() {
        account.recordConversion(.paywallClosed(surface: .paywall, trigger: trigger))
    }

    /// Bu katman ve planın App Store fiyatı (kartta ve düğmede); paket okunmadıysa nil.
    func priceText(tier: HostedTier, plan: HostedBillingPlan) -> String? {
        packages.first { $0.tier == tier && $0.plan == plan }?.priceText
    }

    /// Seçili paket (düğmedeki fiyat ve yenileme satırı); okunmadıysa nil.
    var selectedPackage: PaywallPackage? {
        visiblePackages.first { $0.plan == selectedPlan }
    }

    /// Ekranın kullanıcının kendi deneme sonucundan başlığı.
    func headline(meetings: [MeetingRecord]) -> String {
        hostedPaywallHeadlineText(headline: hostedPaywallHeadline(value: hostedTrialValue(meetings: meetings), entitlements: entitlements, trigger: trigger, now: Date()))
    }

    /// Hesabın hak durumu; okunmadıysa nil.
    private var entitlements: HostedEntitlements? {
        if case .signedIn(let entitlements) = account.state {
            return entitlements
        }
        return nil
    }

    /// Pro gösterilir mi: sunucu Pro'yu satıyor ve Pro paketleri geçerli teklifte (ikisi birden; açılış kapısı).
    var showsPro: Bool {
        guard let entitlements, hostedProOffer(entitlements: entitlements) != nil else {
            return false
        }
        return packages.contains { (package: PaywallPackage) -> Bool in package.tier == .pro }
    }

    /// Katman seçicisindeki katmanlar (sunucunun sırası ve sınırlarıyla); Pro gösterilmiyorsa boş (seçici görünmez).
    var tierOffers: [HostedTierOffer] {
        guard showsPro, let entitlements else {
            return []
        }
        return hostedOfferedTiers(entitlements: entitlements)
    }

    /// Seçili katmanın gösterilen paketleri (yıllık önce).
    var visiblePackages: [PaywallPackage] {
        let tier: HostedTier = showsPro ? selectedTier : .personal
        return packages.filter { (package: PaywallPackage) -> Bool in package.tier == tier }
    }

    /// Seçili katmanın aylık kayıt saati: sunucunun sunduğu katmandan; katmanları bilmeyen eski sunucuda hesabın sınırı
    /// (o sunucu yalnızca Kişisel'i satar); hesap okunmadıysa nil.
    var monthlyHours: Double? {
        guard let entitlements else {
            return nil
        }
        let tier: HostedTier = showsPro ? selectedTier : .personal
        if let offer = hostedOfferedTiers(entitlements: entitlements).first(where: { $0.tier == tier }) {
            return offer.monthlyHours
        }
        return entitlements.monthlyHoursCap
    }

    /// Erişimi süren App Store aboneliği (aynı abonelik grubunda başka ürüne geçiş); yoksa nil.
    var currentAppStoreSubscription: HostedAppStoreSubscription? {
        guard let subscription = entitlements?.appStoreSubscription, subscription.access != .none else {
            return nil
        }
        return subscription
    }

    /// Seçili paket App Store abonesinin şimdiki ürünü mü (yeniden satın alınmaz).
    var isCurrentSelection: Bool {
        guard let current = currentAppStoreSubscription else {
            return false
        }
        return visiblePackages.first { $0.plan == selectedPlan }?.productID == current.productId
    }

    /// App Store abonesinde seçili pakete geçişin ne zaman geçerli olacağı; abone değilse ya da katmanı bilinmiyorsa nil.
    var selectedChangeTiming: HostedAppStoreChangeTiming? {
        guard let current = currentAppStoreSubscription?.subscriptionTier else {
            return nil
        }
        return hostedAppStoreChangeTiming(current: current, target: showsPro ? selectedTier : .personal)
    }

    /// Seçili katmanın yıllık planının aylık ödemeye göre tasarrufu (App Store fiyatlarından); bilinmiyorsa nil.
    var yearlySavings: Int? {
        let shown: [PaywallPackage] = visiblePackages
        guard let monthly = shown.first(where: { $0.plan == .monthly }), let yearly = shown.first(where: { $0.plan == .yearly }) else {
            return nil
        }
        return yearlySavingsPercent(monthlyPrice: monthly.price, yearlyPrice: yearly.price)
    }

    private func send(event: PaywallEvent) {
        let next: PaywallPhase = paywallPhase(current: phase, event: event)
        if next != phase {
            paywallLogger.info("Abonelik ekranı: \(String(describing: self.phase), privacy: .public) → \(String(describing: next), privacy: .public)")
        }
        phase = next
    }

    /// Paketleri (fiyatlarla) okur; ekran açılınca ve "Yeniden dene"de.
    func loadPackages() async {
        if case .productsUnavailable = phase {
            send(event: .retryProducts)
        }
        guard phase == .loadingProducts else {
            return
        }
        do {
            packages = try await purchases.loadPackages()
            #if DEBUG
            // Tanıtım modu: Pro ürünleri App Store'da yokken de Pro görünsün (görsel kontrol; satın alınmaz).
            if isDemoMode, !packages.contains(where: { $0.tier == .pro }) {
                packages += phoneDemoProPackages()
            }
            #endif
            if let entitlements, hostedProOffer(entitlements: entitlements) != nil, !packages.contains(where: { $0.tier == .pro }) {
                // Açılış kapısı: sunucu Pro'yu satıyor ama RevenueCat'in geçerli teklifinde Pro paketleri yok.
                paywallLogger.warning("Sunucu Pro'yu sunuyor ama geçerli teklifte Pro paketleri yok; Pro gizlendi")
            }
            preselectForCurrentSubscription()
            send(event: .productsLoaded)
            if !isShownRecorded {
                isShownRecorded = true
                account.recordConversion(.paywallShown(surface: .paywall, trigger: trigger, tiersOffered: showsPro ? .personalPro : .personal))
            }
        } catch let error as AppStorePurchaseError {
            account.recordConversion(.purchaseFailed(surface: .paywall, trigger: trigger, reason: conversionReason(appStoreError: error)))
            send(event: .productsFailed(message: appStorePurchaseMessage(error: error)))
        } catch {
            account.recordConversion(.purchaseFailed(surface: .paywall, trigger: trigger, reason: conversionReason(error: error)))
            send(event: .productsFailed(message: userFacingMessage(error: error)))
        }
    }

    /// App Store abonesinde öbür katman (Pro gösteriliyorsa) ve şimdiki plan dönemi seçilir: "Planı değiştir" ile
    /// açılan ekran geçişi önerir.
    private func preselectForCurrentSubscription() {
        guard let current = currentAppStoreSubscription else {
            return
        }
        if let plan = current.plan.flatMap({ HostedBillingPlan(rawValue: $0) }) {
            selectedPlan = plan
        }
        if showsPro, let tier = current.subscriptionTier {
            selectedTier = tier == .personal ? .pro : .personal
        }
    }

    /// Seçili katman ve planı satın alır; Apple onaylarsa hak beklenir (App Store abonesinde Apple'ın geçiş kuralıyla).
    func purchase() async {
        let plan: HostedBillingPlan = selectedPlan
        let choice: PaywallChoice = PaywallChoice(tier: showsPro ? selectedTier : .personal, plan: plan)
        guard !isCurrentSelection else {
            return
        }
        let timing: HostedAppStoreChangeTiming? = selectedChangeTiming
        send(event: .purchaseTapped(plan: plan))
        guard phase == .purchasing(plan: plan) else {
            return
        }
        account.recordConversion(.purchaseStarted(surface: .paywall, trigger: trigger, tier: choice.tier, plan: plan))
        do {
            #if DEBUG
            // Tanıtım modunun sahte Pro paketi App Store'da yok: satın alınmaz, onaylanmış sayılır.
            if isDemoMode, phoneDemoProPackages().contains(where: { $0.choice == choice }) {
                send(event: .storeConfirmed)
                await finish(choice: choice, timing: timing)
                return
            }
            #endif
            switch try await purchaseOutcome(choice: choice) {
            case .cancelled:
                account.recordConversion(.purchaseCancelled(surface: .paywall, trigger: trigger, tier: choice.tier, plan: plan))
                send(event: .purchaseCancelled)
            case .confirmed:
                send(event: .storeConfirmed)
                await finish(choice: choice, timing: timing)
            }
        } catch let error as AppStorePurchaseError {
            account.recordConversion(.purchaseFailed(surface: .paywall, trigger: trigger, reason: conversionReason(appStoreError: error)))
            send(event: .storeFailed(message: appStorePurchaseMessage(error: error)))
        } catch {
            account.recordConversion(.purchaseFailed(surface: .paywall, trigger: trigger, reason: conversionReason(error: error)))
            send(event: .storeFailed(message: userFacingMessage(error: error)))
        }
    }

    /// App Store hesabındaki aboneliği bu hesaba geri yükler; etkin abonelik varsa hak beklenir.
    func restore() async {
        send(event: .restoreTapped)
        guard phase == .restoring else {
            return
        }
        do {
            switch try await restoreOutcome() {
            case .nothingFound:
                account.recordConversion(.purchaseRestored(surface: .paywall, result: .nothingFound))
                send(event: .restoreFoundNothing)
            case .confirmed:
                account.recordConversion(.purchaseRestored(surface: .paywall, result: .restored))
                send(event: .storeConfirmed)
                await finish(choice: nil, timing: nil)
            }
        } catch let error as AppStorePurchaseError {
            send(event: .storeFailed(message: appStorePurchaseMessage(error: error)))
        } catch {
            send(event: .storeFailed(message: userFacingMessage(error: error)))
        }
    }

    /// Hak gelmediyse beklemeyi yeniden başlatır (ödeme yinelenmez).
    func retryFinishing() async {
        send(event: .retryFinishing)
        guard phase == .finishing else {
            return
        }
        await finish(choice: pendingChoice, timing: completedChange)
    }

    /// Buys `choice` under the signed-in account's RevenueCat identity (the purchase is then written to this account on
    /// the server). The identity is applied and checked right before the purchase, and the account must still be the one
    /// that tapped (`AppStorePurchases.purchase`). No session: error.
    private func purchaseOutcome(choice: PaywallChoice) async throws -> StorePurchaseOutcome {
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz: sahte hesabın kimliği RevenueCat'e gönderilmez (anonim kalır).
        if isDemoMode {
            return try await purchases.purchaseUnderCurrentIdentity(choice: choice)
        }
        #endif
        guard let userID = account.signedInUserIDCache else {
            throw HostedClientError.notSignedIn
        }
        let account: HostedAccount = account
        return try await purchases.purchase(choice: choice, userID: userID) { (expected: String) -> Bool in
            account.signedInUserIDCache == expected
        }
    }

    /// Restores App Store purchases under the signed-in account's identity (see `purchaseOutcome`).
    private func restoreOutcome() async throws -> StoreRestoreOutcome {
        #if DEBUG
        if isDemoMode {
            return try await purchases.restoreUnderCurrentIdentity()
        }
        #endif
        guard let userID = account.signedInUserIDCache else {
            throw HostedClientError.notSignedIn
        }
        let account: HostedAccount = account
        return try await purchases.restore(userID: userID) { (expected: String) -> Bool in
            account.signedInUserIDCache == expected
        }
    }

    /// Beklenen satın alma (hak gelmezse "Yeniden dene" aynısını bekler); geri yüklemede nil.
    private var pendingChoice: PaywallChoice?

    /// Hakkın sunucuya gelmesini bekler. `choice`: satın alınan paket (geri yüklemede nil); `timing`: App Store abonesinin
    /// geçişi (yeni abonelikte nil). Hemen geçerli olan Pro satın almasında (yeni ya da yükseltme) hak App Store
    /// aboneliğinin katmanı Pro olunca gelir (`confirmAppStoreTier`); başka durumda erişim yeter
    /// (`confirmAppStorePurchase`; yenilemede başlayan geçişte sunucu aboneliği hemen yeniden okur, katman dönem sonuna
    /// dek aynı kalır).
    private func finish(choice: PaywallChoice?, timing: HostedAppStoreChangeTiming?) async {
        pendingChoice = choice
        completedChange = timing
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz: hak sunucudan beklenmez, sahte hesap App Store abonesi gösterilir.
        if isDemoMode {
            let tier: HostedTier = timing == .atRenewal ? (currentAppStoreSubscription?.subscriptionTier ?? .personal) : (choice?.tier ?? .personal)
            account.showAccountForDemo(entitlements: phoneDemoAppStoreEntitlements(now: Date(), tier: tier), referral: phoneDemoReferral(now: Date()))
            send(event: .entitlementArrived)
            return
        }
        #endif
        do {
            if choice?.tier == .pro, timing != .atRenewal {
                try await account.confirmAppStoreTier(tier: .pro)
            } else {
                try await account.confirmAppStorePurchase()
            }
            if let choice {
                account.recordConversion(.purchaseCompleted(surface: .paywall, trigger: trigger, tier: choice.tier, plan: choice.plan))
            }
            send(event: .entitlementArrived)
        } catch let error as HostedAppStoreEntitlementMissing {
            account.recordConversion(.purchaseFailed(surface: .paywall, trigger: trigger, reason: .entitlementTimeout))
            send(event: .entitlementTimedOut(message: appStoreEntitlementMissingMessage(error: error)))
        } catch {
            account.recordConversion(.purchaseFailed(surface: .paywall, trigger: trigger, reason: conversionReason(error: error)))
            send(event: .entitlementTimedOut(message: userFacingMessage(error: error)))
        }
    }
}
