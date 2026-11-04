import AINotepadCore
import Foundation
import Testing

/// Sunucu biçimindeki hak durumu: `sources` (`subscriptionSources`), App Store aboneliği (`appStore`: JSON ya da "null")
/// ve asıl abonelik (`subscription`: JSON ya da "null").
private func entitlements(sources: String, appStore: String, subscription: String) throws -> HostedEntitlements {
    let json: String = #"""
    {"userId":"7f0c2a54-1b9e-4d55-8c3a-0e6f2b1d9a77","plan":"subscription","trialMeetingsTotal":3,"trialMeetingsLeft":0,
     "accountTrialMeetingsLeft":0,"deviceTrialMeetingsLeft":null,"monthlyHoursUsed":1,"monthlyHoursCap":10,
     "subscriptionSources":\#(sources),"appStoreSubscription":\#(appStore),"subscription":\#(subscription)}
    """#
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { (decoder: any Decoder) throws -> Date in
        try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(try decoder.singleValueContainer().decode(String.self))
    }
    return try decoder.decode(HostedEntitlements.self, from: Data(json.utf8))
}

/// Sunucunun `appStoreSubscription` alanı.
private func appStoreJSON(status: String, access: String, willRenew: Bool) -> String {
    #"""
    {"status":"\#(status)","plan":"monthly","productId":"com.senoldogan.gistsmith.monthly","access":"\#(access)",
     "expiresAt":"2026-12-02T10:00:00.000Z","willRenew":\#(willRenew),"graceEndsAt":null,"environment":"SANDBOX",
     "manageUrl":"https://apps.apple.com/account/subscriptions"}
    """#
}

private let stripeSubscriptionJSON: String =
    #"{"source":"stripe","status":"active","complimentary":false,"currentPeriodEnd":"2026-12-01T00:00:00.000Z","cancelAt":null,"access":"active","graceEndsAt":null,"plan":"monthly"}"#

@Suite struct HostedAppStoreTests {
    // RevenueCat kimliği giriş yapan hesapla eşlenir; çıkışta anonime döner, anonimken çıkış yapılmaz.
    @Test func identityFollowsSignedInAccount() {
        #expect(purchaseIdentityAction(currentAppUserID: "$RCAnonymousID:abc", isAnonymous: true, signedInUserID: "u1") == .logIn(userID: "u1"))
        #expect(purchaseIdentityAction(currentAppUserID: "u1", isAnonymous: false, signedInUserID: "u1") == .none)
        #expect(purchaseIdentityAction(currentAppUserID: "u1", isAnonymous: false, signedInUserID: "u2") == .logIn(userID: "u2"))
        #expect(purchaseIdentityAction(currentAppUserID: "u1", isAnonymous: false, signedInUserID: nil) == .logOut)
        #expect(purchaseIdentityAction(currentAppUserID: "$RCAnonymousID:abc", isAnonymous: true, signedInUserID: nil) == .none)
    }

    // Hak beklemesi: hak gelince biter; gelmezse aralıklar bitene dek yeniden sorar, sonra açıkça vazgeçer.
    @Test func entitlementWaitStopsWhenAppStoreAccessArrives() throws {
        let trial: HostedEntitlements = try entitlements(sources: "[]", appStore: "null", subscription: "null")
        let arrived: HostedEntitlements = try entitlements(
            sources: #"["app_store"]"#, appStore: appStoreJSON(status: "active", access: "active", willRenew: true), subscription: "null"
        )
        let delays: [Double] = [1, 2]
        #expect(hostedEntitlementWaitStep(latest: arrived, completedAttempts: 1, delays: delays) == .arrived)
        #expect(hostedEntitlementWaitStep(latest: trial, completedAttempts: 1, delays: delays) == .retry(afterSeconds: 1))
        #expect(hostedEntitlementWaitStep(latest: nil, completedAttempts: 2, delays: delays) == .retry(afterSeconds: 2))
        #expect(hostedEntitlementWaitStep(latest: trial, completedAttempts: 3, delays: delays) == .gaveUp)
        // Süresi geçmiş App Store aboneliği hak sayılmaz.
        let expired: HostedEntitlements = try entitlements(sources: "[]", appStore: appStoreJSON(status: "expired", access: "none", willRenew: false), subscription: "null")
        #expect(!hostedAppStoreAccessActive(entitlements: expired))
    }

    // Ekran: satın alma → hak beklemesi → tamam; vazgeçme seçime döner; hak gelmezse yeniden beklenir, ödeme yeniden alınmaz.
    @Test func paywallPurchaseFlow() {
        var phase: PaywallPhase = .loadingProducts
        phase = paywallPhase(current: phase, event: .productsLoaded)
        #expect(phase == .choosing)
        phase = paywallPhase(current: phase, event: .purchaseTapped(plan: .yearly))
        #expect(phase == .purchasing(plan: .yearly))
        #expect(isPaywallBusy(phase: phase))
        // Sürerken ikinci dokunuş yok sayılır.
        #expect(paywallPhase(current: phase, event: .purchaseTapped(plan: .monthly)) == .purchasing(plan: .yearly))
        #expect(paywallPhase(current: phase, event: .purchaseCancelled) == .choosing)
        phase = paywallPhase(current: phase, event: .storeConfirmed)
        #expect(phase == .finishing)
        phase = paywallPhase(current: phase, event: .entitlementTimedOut(message: "not yet"))
        #expect(phase == .finishingFailed(message: "not yet"))
        #expect(!canChoosePaywallPackage(phase: phase))
        phase = paywallPhase(current: phase, event: .retryFinishing)
        #expect(phase == .finishing)
        #expect(paywallPhase(current: phase, event: .entitlementArrived) == .completed)
    }

    // Geri yükleme: etkin abonelik yoksa söylenir; fiyatlar okunamasa da yapılabilir; hata seçime döner.
    @Test func paywallRestoreFlow() {
        #expect(paywallPhase(current: .productsUnavailable(message: "offline"), event: .restoreTapped) == .restoring)
        // Hak gelmediyse geri yükleme düğmesi de çalışır (açık görünüp hiçbir şey yapmıyordu).
        #expect(!isPaywallBusy(phase: .finishingFailed(message: "not yet")))
        #expect(paywallPhase(current: .finishingFailed(message: "not yet"), event: .restoreTapped) == .restoring)
        #expect(paywallPhase(current: .restoring, event: .restoreFoundNothing) == .nothingToRestore)
        #expect(paywallPhase(current: .restoring, event: .storeConfirmed) == .finishing)
        #expect(paywallPhase(current: .restoring, event: .storeFailed(message: "x")) == .purchaseFailed(message: "x"))
        #expect(paywallPhase(current: .purchaseFailed(message: "x"), event: .purchaseTapped(plan: .monthly)) == .purchasing(plan: .monthly))
        #expect(paywallPhase(current: .loadingProducts, event: .productsFailed(message: "y")) == .productsUnavailable(message: "y"))
        #expect(paywallPhase(current: .productsUnavailable(message: "y"), event: .retryProducts) == .loadingProducts)
    }

    // Silme onayı: Stripe iptal edilir, yenilenecek App Store aboneliği Apple'da iptal edilmeli.
    @Test func deletionEffectBySource() throws {
        let none: HostedEntitlements = try entitlements(sources: "[]", appStore: "null", subscription: "null")
        #expect(hostedDeletionSubscriptionEffect(entitlements: none) == .none)
        let stripe: HostedEntitlements = try entitlements(sources: #"["stripe"]"#, appStore: "null", subscription: stripeSubscriptionJSON)
        #expect(hostedDeletionSubscriptionEffect(entitlements: stripe) == .stripeCanceled)
        let appStore: HostedEntitlements = try entitlements(
            sources: #"["app_store"]"#, appStore: appStoreJSON(status: "active", access: "active", willRenew: true), subscription: "null"
        )
        #expect(hostedDeletionSubscriptionEffect(entitlements: appStore) == .appStoreKeepsRenewing)
        let ending: HostedEntitlements = try entitlements(
            sources: #"["app_store"]"#, appStore: appStoreJSON(status: "canceled", access: "active", willRenew: false), subscription: "null"
        )
        #expect(hostedDeletionSubscriptionEffect(entitlements: ending) == .appStoreEnding)
        let both: HostedEntitlements = try entitlements(
            sources: #"["stripe","app_store"]"#, appStore: appStoreJSON(status: "active", access: "active", willRenew: true), subscription: stripeSubscriptionJSON
        )
        #expect(hostedDeletionSubscriptionEffect(entitlements: both) == .stripeCanceledAppStoreKeepsRenewing)
    }
}

@Suite struct HostedAppStorePriceTests {
    // Tasarruf App Store fiyatlarından hesaplanır, aşağı yuvarlanır: 49 / (5,99 × 12) → %31.
    @Test func yearlySavingsFromStorePrices() {
        #expect(yearlySavingsPercent(monthlyPrice: Decimal(string: "5.99")!, yearlyPrice: 49) == 31)
        #expect(yearlySavingsPercent(monthlyPrice: 0, yearlyPrice: 49) == nil)
        #expect(yearlySavingsPercent(monthlyPrice: 4, yearlyPrice: 48) == nil)
    }
}
