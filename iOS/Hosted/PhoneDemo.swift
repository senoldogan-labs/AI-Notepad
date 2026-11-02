#if DEBUG
import AINotepadCore
import Foundation

// Tanıtım modu (yalnız Debug, Simülatör'de görsel kontrol): `--tanitim` ile uygulama sunucuya bağlanmadan, sahte bir
// denemedeki hesapla açılır; giriş kapısı ve yapay zekâ açıklaması atlanır (Mac'teki App/DemoData.swift'in karşılığı).
// Veri Simülatör'ün uygulama kabındaki ayrı bir hesap klasörüne yazılır; Anahtar Zinciri okunmaz.

/// `--tanitim` başlatma argümanı: tanıtım modu açık mı (`HostedAccount` sunucuya bağlanmaz).
let isDemoMode: Bool = CommandLine.arguments.contains("--tanitim")

/// Tanıtım hesabının verisini yükler (`HostedAccount` oluşturulmadan önce çağrılır: hesap verisi yüklü sayılsın).
func activatePhoneDemoAccount() {
    do {
        try AppPaths.activateAccount(key: accountDataKey(userId: "tanitim"))
    } catch {
        fatalError("Tanıtım hesabı yüklenemedi: \(error)")
    }
}

/// Tanıtım hesabının hak durumu: 3 toplantılık denemede 2 toplantı kalmış, bu ay 3,4 / 10 saat. Sunucu yanıtıyla aynı
/// JSON'dan çözülür.
func phoneDemoEntitlements(now: Date) -> HostedEntitlements {
    let iso: (Date) -> String = { (date: Date) -> String in date.formatted(Date.ISO8601FormatStyle()) }
    let json: String = """
    {"userId":"tanitim","plan":"trial","trialMeetingsTotal":3,"trialDays":7,
     "trialMeetingsLeft":2,"accountTrialMeetingsLeft":2,"deviceTrialMeetingsLeft":null,
     "trialEndsAt":"\(iso(now.addingTimeInterval(5 * 86_400)))",
     "monthlyHoursUsed":3.4,"monthlyHoursCap":10,"subscription":null,"liveEngine":"deepgram",
     "accountTokensUsed":180000,"accountTokensCap":1500000,"accountTokensPeriod":"month",
     "accountTokensResetsAt":"\(iso(now.addingTimeInterval(20 * 86_400)))","monthlyResetsAt":"\(iso(now.addingTimeInterval(20 * 86_400)))",
     "meetingMaxMinutes":90}
    """
    return decodedPhoneDemoEntitlements(json: json)
}

/// Tanıtım hesabının App Store abonesi hali (abonelik ekranında satın alma ya da geri yüklemeden sonra; sunucuya
/// bağlanılmaz): aylık plan, yenilenecek, bu ay 3,4 / 10 saat.
func phoneDemoAppStoreEntitlements(now: Date) -> HostedEntitlements {
    let iso: (Date) -> String = { (date: Date) -> String in date.formatted(Date.ISO8601FormatStyle()) }
    let renewsAt: String = iso(now.addingTimeInterval(30 * 86_400))
    let json: String = """
    {"userId":"tanitim","plan":"subscription","trialMeetingsTotal":3,"trialDays":7,
     "trialMeetingsLeft":0,"accountTrialMeetingsLeft":0,"deviceTrialMeetingsLeft":null,"trialEndsAt":null,
     "monthlyHoursUsed":3.4,"monthlyHoursCap":10,"liveEngine":"deepgram",
     "accountTokensUsed":180000,"accountTokensCap":3000000,"accountTokensPeriod":"month",
     "accountTokensResetsAt":"\(iso(now.addingTimeInterval(20 * 86_400)))","monthlyResetsAt":"\(iso(now.addingTimeInterval(20 * 86_400)))",
     "meetingMaxMinutes":240,"subscriptionSources":["app_store"],
     "appStoreSubscription":{"status":"active","plan":"monthly","productId":"com.senoldogan.gistsmith.monthly","access":"active",
       "expiresAt":"\(renewsAt)","willRenew":true,"graceEndsAt":null,"environment":"SANDBOX",
       "manageUrl":"https://apps.apple.com/account/subscriptions"},
     "subscription":{"source":"app_store","status":"active","currentPeriodEnd":"\(renewsAt)","cancelAt":null,"access":"active",
       "graceEndsAt":null,"plan":"monthly","complimentary":false}}
    """
    return decodedPhoneDemoEntitlements(json: json)
}

/// Tanıtım abonesinin davet bilgisi: bir arkadaş katılmış; abonelik App Store'dan olduğu için ödül yazılmaz.
func phoneDemoReferral(now: Date) -> HostedReferral {
    HostedReferral(
        enabled: true, code: "K7M2QX9D", inviteUrl: URL(string: "https://gistsmith.com/invite?code=K7M2QX9D"), joined: 1, rewarded: 0,
        pending: 1, nextRewardAt: now.addingTimeInterval(24 * 86_400), complimentary: false, appStoreBilled: true, rewardsLeftThisYear: 12,
        rewardsPerYear: 12, rewardUsd: 5.99, holdDays: 30
    )
}

/// Tanıtım hak durumunu sunucu yanıtıyla aynı JSON'dan çözer; çözülemezse tanıtım açılmaz (programcı hatası).
private func decodedPhoneDemoEntitlements(json: String) -> HostedEntitlements {
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode(HostedEntitlements.self, from: Data(json.utf8))
    } catch {
        fatalError("Tanıtım hak durumu çözülemedi: \(error)")
    }
}
#endif
