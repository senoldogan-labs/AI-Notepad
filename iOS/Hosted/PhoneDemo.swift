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
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode(HostedEntitlements.self, from: Data(json.utf8))
    } catch {
        fatalError("Tanıtım hak durumu çözülemedi: \(error)")
    }
}
#endif
