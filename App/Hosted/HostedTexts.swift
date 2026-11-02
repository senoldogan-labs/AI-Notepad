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
