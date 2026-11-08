import Foundation

// Abonelik planlarının fiyatları ve deneme sonu özetinin hesapları. Fiyatlar Stripe'taki fiyatlarla elle aynı tutulur
// (vergiler dahil, USD); ödeme sayfası Stripe'ın kendi tutarını gösterir.

/// Kişisel aylık planın fiyatı (sent, vergiler dahil).
public let hostedMonthlyPriceCents: Int = 599

/// Kişisel yıllık planın fiyatı (sent, vergiler dahil).
public let hostedYearlyPriceCents: Int = 4900

/// Pro aylık planın fiyatı (sent, vergiler dahil).
public let hostedProMonthlyPriceCents: Int = 1299

/// Pro yıllık planın fiyatı (sent, vergiler dahil).
public let hostedProYearlyPriceCents: Int = 10900

/// Katmanın planının fiyatı (sent). Saf fonksiyondur.
public func hostedPlanPriceCents(tier: HostedTier, plan: HostedBillingPlan) -> Int {
    switch (tier, plan) {
    case (.personal, .monthly): hostedMonthlyPriceCents
    case (.personal, .yearly): hostedYearlyPriceCents
    case (.pro, .monthly): hostedProMonthlyPriceCents
    case (.pro, .yearly): hostedProYearlyPriceCents
    }
}

/// Katmanın yıllık planının aylık karşılığı (sent, aşağı yuvarlanır: Kişisel 4900 / 12 = 408,3 → 408; Pro 10900 / 12
/// = 908,3 → 908). Saf fonksiyondur.
public func hostedYearlyMonthlyEquivalentCents(tier: HostedTier) -> Int {
    hostedPlanPriceCents(tier: tier, plan: .yearly) / 12
}

/// Katmanın yıllık planının 12 aylık ödemeye göre tasarrufu (yüzde, en yakın tam sayı: Kişisel 1 − 49 / 71,88 ≈ %32,
/// Pro 1 − 109 / 155,88 ≈ %30). Saf fonksiyondur.
public func hostedYearlySavingsPercent(tier: HostedTier) -> Int {
    let twelveMonths: Double = Double(hostedPlanPriceCents(tier: tier, plan: .monthly) * 12)
    return Int(((1 - Double(hostedPlanPriceCents(tier: tier, plan: .yearly)) / twelveMonths) * 100).rounded())
}

/// Davet koduyla ilk ödemenin tutarı (sent): Kişisel aylıkta ilk ay ücretsiz (0); Kişisel yıllıkta ve iki Pro planında
/// bir Kişisel aylık ücret (5,99 $) bir kez düşülür (sunucunun davet kuponuyla aynı). Saf fonksiyondur.
public func hostedReferralFirstPaymentCents(tier: HostedTier, plan: HostedBillingPlan) -> Int {
    switch (tier, plan) {
    case (.personal, .monthly): 0
    case (.personal, .yearly), (.pro, .monthly), (.pro, .yearly): hostedPlanPriceCents(tier: tier, plan: plan) - hostedMonthlyPriceCents
    }
}

/// Denemenin bu Mac'teki özeti: kaydedilen toplantılar, notlardan çıkan görevler ve yazıya dökülen saat.
public struct HostedTrialValue: Sendable, Equatable {
    public let meetings: Int
    public let tasks: Int
    public let hours: Double

    public init(meetings: Int, tasks: Int, hours: Double) {
        self.meetings = meetings
        self.tasks = tasks
        self.hours = hours
    }
}

/// Yerel toplantılardan deneme özeti: biten (kaydı tamamlanmış) toplantılar, notlarındaki tüm görevler ve sürelerinin
/// toplamı (saat). Süren kayıt sayılmaz. Saf fonksiyondur.
public func hostedTrialValue(meetings: [MeetingRecord]) -> HostedTrialValue {
    let finished: [MeetingRecord] = meetings.filter { (record: MeetingRecord) -> Bool in record.endedAt != nil }
    let tasks: Int = finished.reduce(0) { (total: Int, record: MeetingRecord) -> Int in total + (record.note?.tasks.count ?? 0) }
    let seconds: Double = finished.reduce(0) { (total: Double, record: MeetingRecord) -> Double in
        total + max(0, (record.endedAt ?? record.startedAt).timeIntervalSince(record.startedAt))
    }
    return HostedTrialValue(meetings: finished.count, tasks: tasks, hours: seconds / 3600)
}
