import AINotepadCore
import AINotepadUI
import SwiftUI

// Hesap ekranının plan ve kullanım kartı (Mac'teki Ayarlar › Hesap kullanım kartının iPhone karşılığı). Kart hak
// durumuyla (`GET /v1/me`) değişir: abonede plan, bu ayın saatleri ve toplantı dışı yapay zekâ payı; denemede kalan
// toplantılar ve bitiş; sona ermiş ya da ödemesi alınamamış abonelikte nedeni ve yapılacak iş. Ölçerin olağan dolgusu
// kullanıcının vurgu rengidir; uyarı renkleri yalnızca gerçek durumda gelir. Görünüm durağandır (hareketli gradyan yok).

/// Ölçerin yanındaki metnin rengi: olağan durumda soluk; dikkat ve dolu durumunda uyarılarla aynı renk. Saf fonksiyondur.
@MainActor
func phoneUsageLevelColor(level: HostedUsageLevel) -> Color {
    switch level {
    case .normal: Theme.muted
    case .warning: NoticeSeverity.attention.tint
    case .full: NoticeSeverity.error.tint
    }
}

/// Ölçerin dolgusu: olağan durumda vurgu rengi, dikkat ve dolu durumunda uyarı rengi. Saf fonksiyondur.
@MainActor
func phoneMeterFillColor(level: HostedUsageLevel, accent: PanelAccent) -> Color {
    switch level {
    case .normal: accent.color
    case .warning: NoticeSeverity.attention.tint
    case .full: NoticeSeverity.error.tint
    }
}

/// Yüzde metni, ör. "%25". Saf fonksiyondur.
func phonePercentText(fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale()))
}

/// Planın kısa etiketi, ör. "Aylık plan · App Store", Pro'da "Pro · Aylık plan · App Store"; plan bilinmiyorsa yalnız
/// kaynak, ücretsiz erişimde "Ücretsiz tam erişim". Fiyat yazılmaz: App Store aboneliğinin fiyatı kullanıcının bölgesindeki
/// App Store fiyatıdır. Saf fonksiyondur.
func phonePlanBadgeText(subscription: HostedSubscription) -> String {
    if subscription.complimentary {
        return String(localized: "Ücretsiz tam erişim")
    }
    let source: String = subscription.paymentSource == .appStore ? String(localized: "App Store") : String(localized: "Web")
    switch (subscription.subscriptionTier == .pro, subscription.billingPlan) {
    case (false, .monthly): return String(localized: "Aylık plan · \(source)")
    case (false, .yearly): return String(localized: "Yıllık plan · \(source)")
    case (true, .monthly): return String(localized: "Pro · Aylık plan · \(source)")
    case (true, .yearly): return String(localized: "Pro · Yıllık plan · \(source)")
    case (false, nil): return source
    case (true, nil): return String(localized: "Pro · \(source)")
    }
}

/// Yuvarlak uçlu kullanım ölçeri: sakin zemin üstünde vurgu renginde dolgu; %80'de dikkat, %100'de hata rengi.
struct PhoneUsageMeter: View {
    let fraction: Double
    let height: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.soft)
                Capsule().strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5)
                if fraction > 0 {
                    Capsule()
                        .fill(phoneMeterFillColor(level: hostedUsageLevel(fraction: fraction), accent: appearance.accent))
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("Kullanım"))
        .accessibilityValue(Text(verbatim: phonePercentText(fraction: fraction)))
    }
}

/// Deneme toplantıları: her toplantı bir parça; kalanlar vurgu renginde dolu, kullanılanlar boş.
struct PhoneTrialSegments: View {
    let left: Int
    let total: Int
    let height: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(spacing: height) {
            ForEach(0..<max(total, 1), id: \.self) { (index: Int) in
                Capsule()
                    .fill(index < left ? phoneMeterFillColor(level: hostedTrialLevel(left: left), accent: appearance.accent) : Theme.soft)
                    .overlay(Capsule().strokeBorder(left == 0 ? NoticeSeverity.error.tint.opacity(0.6) : Theme.line.opacity(0.6), lineWidth: 0.5))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: hostedTrialLeftText(left: left)))
    }
}

/// Hesap ekranındaki plan ve kullanım kartı (bkz. dosya başı).
struct PhoneUsageCard: View {
    let account: HostedAccount
    let entitlements: HostedEntitlements

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch hostedPlanStatus(entitlements: entitlements, now: Date()) {
            case .trial(let trialState):
                trial(left: trialState.meetingsLeft, total: trialState.meetingsTotal)
            case .subscribed, .complimentary, .ending, .grace:
                subscriber
            case .expired(let endedAt):
                expired(endedAt: endedAt)
            case .paymentOverdue:
                paymentOverdue
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 20)
    }

    @ViewBuilder
    private var subscriber: some View {
        let fraction: Double = hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
        if let subscription = entitlements.subscription {
            Text(verbatim: phonePlanBadgeText(subscription: subscription))
                .appFont(size: 12, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .textCase(.uppercase)
                .foregroundStyle(.tint)
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: hostedMonthlyUsageText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap))
                    .appFont(size: 19, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(verbatim: phonePercentText(fraction: fraction))
                    .appFont(size: 14, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(phoneUsageLevelColor(level: hostedUsageLevel(fraction: fraction)))
            }
            PhoneUsageMeter(fraction: fraction, height: 10)
            Text("Sıfırlanma: \(hostedResetDayText(now: Date()))")
                .appFont(size: 12, weight: .regular)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            if fraction >= 1 {
                Text("Bu ayki sınır doldu: yeni kayıt başlatılamaz. Notların ve toplantıların erişilebilir kalır.")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(NoticeSeverity.error.tint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Adil kullanım sınırı: bu ay kaydedilen toplantıların toplam süresi.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let used = entitlements.accountTokensUsed, let cap = entitlements.accountTokensCap {
            let aiFraction: Double = hostedUsageFraction(used: Double(used), cap: Double(cap))
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Toplantı dışı yapay zekâ")
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text(verbatim: phonePercentText(fraction: aiFraction))
                        .appFont(size: 12, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(phoneUsageLevelColor(level: hostedUsageLevel(fraction: aiFraction)))
                }
                PhoneUsageMeter(fraction: aiFraction, height: 6)
                Text("Sor, notu değiştirme ve notu yenileme bu paydan düşer; toplantı sırasındakiler düşmez.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func trial(left: Int, total: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Ücretsiz deneme")
                .appFont(size: 19, weight: .medium)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Text(verbatim: hostedTrialLeftText(left: left))
                .appFont(size: 14, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(phoneUsageLevelColor(level: hostedTrialLevel(left: left)))
        }
        PhoneTrialSegments(left: left, total: total, height: 8)
        Group {
            if left == 0 && account.isTrialRefusedOnThisMac {
                Text("Bu iPhone'da ücretsiz deneme başka bir hesapla kullanıldı; devam etmek için abone ol. Toplantıların ve notların bu iPhone'da kalır.")
            } else if left == 0 {
                Text("Deneme bitti; yeni toplantılar için abone ol. Toplantıların ve notların bu iPhone'da kalır.")
            } else if let endsAt = entitlements.trialEndsAt {
                Text("Bitiş: \(endsAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))")
                    .monospacedDigit()
            } else {
                Text("Deneme ilk toplantınla başlar: \(hostedTrialTermsText(entitlements: entitlements)), hangisi önce dolarsa.")
            }
        }
        .appFont(size: 13, weight: .regular)
        .foregroundStyle(Theme.muted)
        .fixedSize(horizontal: false, vertical: true)
        Button { account.showPlans() } label: {
            PhonePrimaryButtonLabel(title: "Abone ol")
        }
        .buttonStyle(.plain)
        .disabled(account.isWorking)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func expired(endedAt: Date) -> some View {
        Text("Abonelik sona erdi")
            .appFont(size: 19, weight: .medium)
            .foregroundStyle(Theme.ink)
        Text("Aboneliğin \(hostedDayText(date: endedAt)) tarihinde sona erdi. Toplantıların ve notların bu iPhone'da; yeni kayıt için yeniden abone ol.")
            .appFont(size: 13, weight: .regular)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        Button { account.showPlans() } label: {
            PhonePrimaryButtonLabel(title: "Yeniden abone ol")
        }
        .buttonStyle(.plain)
        .disabled(account.isWorking)
    }

    @ViewBuilder
    private var paymentOverdue: some View {
        Text("Ödeme alınamadı")
            .appFont(size: 19, weight: .medium)
            .foregroundStyle(NoticeSeverity.error.tint)
        Text("Yenileme ödemesi alınamadı ve ek süre bitti. Toplantıların ve notların bu iPhone'da; yeni kayıt için ödeme yöntemini güncelle.")
            .appFont(size: 13, weight: .regular)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
