import AINotepadCore
import Foundation

// Abonelik sürümünün Mac ve iPhone'da ortak, saf metin yardımcıları (hesap, kullanım ve deneme satırları).

/// Aylık kullanım: "Bu ay 2,5 / 10 saat". Saf fonksiyondur.
func hostedMonthlyUsageText(used: Double, cap: Double) -> String {
    let style: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0...1)).locale(interfaceLocale())
    return String(localized: "Bu ay \(used.formatted(style)) / \(cap.formatted(style)) saat")
}

/// Ayın sıfırlanma günü, ör. "1 Kasım" (sunucu ayı UTC'ye göre sayar; gün UTC'de yazılır). Saf fonksiyondur.
func hostedResetDayText(now: Date) -> String {
    var style: Date.FormatStyle = Date.FormatStyle.dateTime.day().month(.wide).locale(interfaceLocale())
    style.timeZone = .gmt
    return hostedMonthResetDate(now: now).formatted(style)
}

/// Arayüz dilinde gün, ör. "1 Kas 2026". Saf fonksiyondur.
func hostedDayText(date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))
}

/// Denemenin koşulu sunucunun bildirdiği değerlerle, ör. "3 toplantı ya da 7 gün" (gün bilinmiyorsa yalnızca toplantı).
/// Saf fonksiyondur.
func hostedTrialTermsText(entitlements: HostedEntitlements) -> String {
    guard let days = entitlements.trialDays else {
        return String(localized: "\(entitlements.trialMeetingsTotal) toplantı")
    }
    return String(localized: "\(entitlements.trialMeetingsTotal) toplantı ya da \(days) gün")
}

/// Kısa saat metni, ör. "3,4 / 10 sa". Saf fonksiyondur.
func hostedCompactHoursText(used: Double, cap: Double) -> String {
    let style: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0...1)).locale(interfaceLocale())
    return String(localized: "\(used.formatted(style)) / \(cap.formatted(style)) sa")
}

/// Kalan deneme toplantısı, ör. "2 toplantı kaldı"; bitmişse "Deneme bitti". Saf fonksiyondur.
func hostedTrialLeftText(left: Int) -> String {
    left == 0 ? String(localized: "Deneme bitti") : String(localized: "\(left) toplantı kaldı")
}

/// Dolar tutarı arayüz dilinde, ör. "$5.99", "$49" (tam dolarda kuruş yazılmaz). Saf fonksiyondur.
func hostedUSDText(cents: Int) -> String {
    let amount: Decimal = Decimal(cents) / 100
    return amount.formatted(.currency(code: "USD").precision(.fractionLength(cents % 100 == 0 ? 0 : 2)).locale(interfaceLocale()))
}

/// Arkadaşa gönderilecek davet metni (bağlantı dahil): web'den abone olursa aylıkta ilk ay ücretsiz, yıllıkta bir aylık
/// ücret kadar indirim (indirim web ödemesine uygulanır). Saf fonksiyondur.
func hostedInviteText(inviteURL: URL) -> String {
    let discount: String = hostedUSDText(cents: hostedMonthlyPriceCents)
    return String(localized: "Toplantılarım için Gistsmith kullanıyorum: konuşulanı canlı yazıya döküyor, toplantı bitince notu ve görevleri hazırlıyor. Bu bağlantıyla web'den abone olursan aylık planda ilk ayın ücretsiz, yıllık planda ilk yılın \(discount) indirimli: \(inviteURL.absoluteString)")
}

/// Davetin ne kazandırdığı: arkadaşın indirimi her durumda; davet edenin ödülü (sonraki web ödemesinden bir aylık ücret)
/// yalnızca web aboneliğinde. Ücretsiz erişimde ödenecek fatura, App Store aboneliğinde düşülecek web ödemesi yoktur:
/// ödül yazılmadığı açıkça söylenir. Saf fonksiyondur.
func hostedReferralRewardText(referral: HostedReferral) -> String {
    let friend: String = String(localized: "Arkadaşın davet bağlantınla web'den abone olunca aylık planda ilk ayı ücretsiz olur.")
    if referral.complimentary {
        return friend + " " + String(localized: "Hesabın zaten ücretsiz olduğu için sana ödül yazılmaz.")
    }
    if referral.appStoreBilled == true {
        return friend + " " + String(localized: "Ödül ayı web aboneliğinin ödemesinden düşülür; aboneliğin App Store'dan alındığı için sana ödül yazılmaz.")
    }
    let reward: String = hostedUSDText(cents: Int((referral.rewardUsd * 100).rounded()))
    return friend + " " + String(localized: "Onun ilk ödemesinden \(referral.holdDays) gün sonra sana da bir ay bedava: sonraki ödemenden \(reward) düşülür (yılda en çok \(referral.rewardsPerYear)).")
}

/// Davet sayaçları, ör. "Katılan arkadaş: 2 · Kazandığın ay: 1 · Sıradaki ödül: 3 Ara 2026 civarı"; ödül yazılmayan
/// hesapta yalnızca katılan arkadaşlar. Saf fonksiyondur.
func hostedReferralStatsText(referral: HostedReferral) -> String {
    if referral.complimentary || referral.appStoreBilled == true {
        return String(localized: "Katılan arkadaş: \(referral.joined)")
    }
    let stats: String = String(localized: "Katılan arkadaş: \(referral.joined) · Kazandığın ay: \(referral.rewarded)")
    guard let next = referral.nextRewardAt else {
        return stats
    }
    return stats + " · " + String(localized: "Sıradaki ödül: \(hostedDayText(date: next)) civarı")
}

/// Duraklatma sunucuya bildirilemeyince kayıt ekranındaki uyarı: kayıt sürer, yalnızca bu duraklatma süre sınırına
/// sayılabilir.
func pauseReportFailedText(error: any Error) -> String {
    String(localized: "Duraklatma sunucuya bildirilemedi; bu duraklatma toplantının süre sınırına sayılabilir. (\(userFacingMessage(error: error)))")
}
