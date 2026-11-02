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
    private(set) var packages: [PaywallPackage] = []
    /// Seçili plan (önce yıllık).
    var selectedPlan: HostedBillingPlan = .yearly

    private let account: HostedAccount
    private let purchases: AppStorePurchases

    init(account: HostedAccount, purchases: AppStorePurchases) {
        self.account = account
        self.purchases = purchases
    }

    /// Yıllık planın aylık ödemeye göre tasarrufu (App Store fiyatlarından); bilinmiyorsa nil.
    var yearlySavings: Int? {
        guard let monthly = packages.first(where: { $0.plan == .monthly }), let yearly = packages.first(where: { $0.plan == .yearly }) else {
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
            send(event: .productsLoaded)
        } catch let error as AppStorePurchaseError {
            send(event: .productsFailed(message: appStorePurchaseMessage(error: error)))
        } catch {
            send(event: .productsFailed(message: userFacingMessage(error: error)))
        }
    }

    /// Seçili planı satın alır; Apple onaylarsa hak beklenir.
    func purchase() async {
        let plan: HostedBillingPlan = selectedPlan
        send(event: .purchaseTapped(plan: plan))
        guard phase == .purchasing(plan: plan) else {
            return
        }
        do {
            try await prepareIdentity()
            switch try await purchases.purchase(plan: plan) {
            case .cancelled:
                send(event: .purchaseCancelled)
            case .confirmed:
                send(event: .storeConfirmed)
                await finish()
            }
        } catch let error as AppStorePurchaseError {
            send(event: .storeFailed(message: appStorePurchaseMessage(error: error)))
        } catch {
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
            try await prepareIdentity()
            switch try await purchases.restore() {
            case .nothingFound:
                send(event: .restoreFoundNothing)
            case .confirmed:
                send(event: .storeConfirmed)
                await finish()
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
        await finish()
    }

    /// RevenueCat'i giriş yapan hesabın kimliğine bağlar (satın alma sunucuda bu hesaba yazılsın). Oturum yoksa hata.
    private func prepareIdentity() async throws {
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz: sahte hesabın kimliği RevenueCat'e gönderilmez (anonim kalır).
        if isDemoMode {
            return
        }
        #endif
        guard let userID = account.signedInUserIDCache else {
            throw HostedClientError.notSignedIn
        }
        try await purchases.ensureIdentity(userID: userID)
    }

    /// Hakkın sunucuya gelmesini bekler (bkz. `HostedAccount.confirmAppStorePurchase`).
    private func finish() async {
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz: hak sunucudan beklenmez, sahte hesap App Store abonesi gösterilir.
        if isDemoMode {
            account.showAccountForDemo(entitlements: phoneDemoAppStoreEntitlements(now: Date()), referral: nil)
            send(event: .entitlementArrived)
            return
        }
        #endif
        do {
            try await account.confirmAppStorePurchase()
            send(event: .entitlementArrived)
        } catch let error as HostedAppStoreEntitlementMissing {
            send(event: .entitlementTimedOut(message: appStoreEntitlementMissingMessage(error: error)))
        } catch {
            send(event: .entitlementTimedOut(message: userFacingMessage(error: error)))
        }
    }
}
