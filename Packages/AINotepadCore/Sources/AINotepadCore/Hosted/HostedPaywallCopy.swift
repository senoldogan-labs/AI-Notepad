import Foundation

// Abonelik teklifinin saf kuralları (Mac'teki planlar sayfası, iPhone'un abonelik ekranı, teklif şeritleri): kullanıcının
// kendi deneme sonucundan başlık, kendiliğinden gelen tekliflerin sıklığı, deneme bitmek üzereyken söylenecekler,
// deneme bittikten sonraki geri çağırma günleri ve aylık sınırda Pro önerisi. Hiçbiri sahte aciliyet ya da uydurma sayı
// üretmez: sayılar yalnızca kullanıcının kendi toplantılarından ve sunucunun hak durumundan gelir.

/// Teklifin başlığı.
public enum HostedPaywallHeadline: Sendable, Equatable {
    /// "3 toplantı. 7 görev yakalandı. Hepsi senin için yazıldı."
    case meetingsAndTasks(meetings: Int, tasks: Int)
    /// "2 saatlik toplantın senin için yazıldı." (`minutes` 60 ve üstündeyse saat, altındaysa dakika yazılır.)
    case meetingsAndTime(meetings: Int, minutes: Int)
    /// Veri yok: "Her toplantın, senin için yazılı."
    case outcomeOnly
    /// Kullanıcı kaydı başlatmak istedi ama hakkı yok: "Toplantın başlıyor. Abone ol, bunun da notu çıksın."
    case meetingStarting
    /// Kullanıcı planları kendisi açtı ya da aylık sınırdan geldi: "Planını seç".
    case choosePlan
}

/// Başlığı seçer. Kaydı başlatma anında (`meetingStart`) o anın başlığı; kullanıcının kendi açtığı planlarda ve aylık
/// sınır tekliflerinde "Planını seç". Deneme sonucu yalnızca denemedeki (ya da denemesi bitmiş, hiç abone olmamış)
/// hesaba gösterilir: görev varsa toplantı ve görev, yoksa süre (aşağı yuvarlanmış dakika); sıfır bir sayı hiçbir zaman
/// olumlu bir cümlenin yanında yazmaz. Abone ve eski abone sonuçsuz başlık görür. Saf fonksiyondur.
public func hostedPaywallHeadline(value: HostedTrialValue, entitlements: HostedEntitlements?, trigger: ConversionTrigger, now: Date) -> HostedPaywallHeadline {
    switch trigger {
    case .meetingStart:
        return .meetingStarting
    case .planChoice, .monthlyWarning, .monthlyFull:
        return .choosePlan
    case .trialNoteReady, .trialEnding, .trialEnded, .subscriptionRequired, .winBack, .trialReminder:
        break
    }
    guard let entitlements, case .trial = hostedPlanStatus(entitlements: entitlements, now: now), value.meetings > 0 else {
        return .outcomeOnly
    }
    if value.tasks > 0 {
        return .meetingsAndTasks(meetings: value.meetings, tasks: value.tasks)
    }
    let minutes: Int = Int((value.hours * 60).rounded(.down))
    return minutes > 0 ? .meetingsAndTime(meetings: value.meetings, minutes: minutes) : .outcomeOnly
}

// MARK: Kendiliğinden gelen teklifler

/// Kendiliğinden gelen (kullanıcının istemediği) teklifler arasında en az bu kadar (saniye) geçer: günde bir; bütün
/// tetikler (not hazır, deneme bitiyor ya da bitti, geri çağırma, iPhone'un kendiliğinden açılan abonelik ekranı) tek
/// sayaçtadır. Kullanıcının istediği planlar (Abone ol, Başlat) her zaman açılır.
public let hostedAutoPromptIntervalSec: Double = 24 * 60 * 60

/// Uygulamanın o anki işi (kendiliğinden teklif yalnızca boştayken).
public enum HostedAppActivity: Sendable, Equatable {
    case idle
    /// Kayıt ya da işleme sürüyor.
    case meetingInProgress
    /// İlk açılış karşılaması sürüyor.
    case onboarding
}

/// Kendiliğinden teklif şimdi gösterilebilir mi: uygulama boşta ve son kendiliğinden tekliften bu yana en az
/// `hostedAutoPromptIntervalSec` geçti. Saf fonksiyondur.
public func hostedAutoPromptAllowed(lastAutoPromptAt: Date?, now: Date, activity: HostedAppActivity) -> Bool {
    guard activity == .idle else {
        return false
    }
    guard let lastAutoPromptAt else {
        return true
    }
    return now.timeIntervalSince(lastAutoPromptAt) >= hostedAutoPromptIntervalSec
}

/// Son kendiliğinden teklifin anının UserDefaults anahtarı (hesap başına). Saf fonksiyondur.
public func hostedAutoPromptKey(userId: String) -> String {
    "hosted.upsell.lastAutoShownAt.\(userId)"
}

// MARK: Deneme bitmek üzere

/// Deneme bitmek üzereyken söylenecek: son toplantı kaldı ya da süresi yakında doluyor.
public enum HostedTrialEndingDetail: Sendable, Equatable {
    case lastMeeting
    case endsSoon(endsAt: Date, meetingsLeft: Int)
}

/// Bitmek üzere olan denemenin ayrıntısı (bkz. `isHostedTrialEnding`); deneme bitmek üzere değilse nil. Saf fonksiyondur.
public func hostedTrialEndingDetail(entitlements: HostedEntitlements, now: Date) -> HostedTrialEndingDetail? {
    guard case .trial(let trial) = hostedPlanStatus(entitlements: entitlements, now: now), case let left = trial.meetingsLeft,
          isHostedTrialEnding(trial: trial, now: now) else {
        return nil
    }
    if left == 1 {
        return .lastMeeting
    }
    guard let endsAt = entitlements.trialEndsAt else {
        return nil
    }
    return .endsSoon(endsAt: endsAt, meetingsLeft: left)
}

/// Bir anın bugüne göre günü (metinde "bugün", "yarın" ya da haftanın günü).
public enum HostedRelativeDay: Sendable, Equatable {
    case today
    case tomorrow
    /// Daha sonra: o günün haftanın günü adıyla yazılır.
    case later(Date)
}

/// `date`'in `now`'a göre günü (yerel takvimde). Saf fonksiyondur.
public func hostedRelativeDay(date: Date, now: Date, calendar: Calendar) -> HostedRelativeDay {
    let days: Int = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    switch days {
    case ...0: return .today
    case 1: return .tomorrow
    default: return .later(date)
    }
}

/// "Bir gün önce hatırlat" sunulabilir mi: deneme süreyle sınırlı, en az bir toplantı kaldı ve bitişe 24 saatten çok var
/// (hatırlatma bitişten 24 saat önce gelir). Ayarın zaten açık olması ve bildirim izninin reddedilmesi uygulamada
/// denetlenir. Saf fonksiyondur.
public func hostedTrialReminderOfferable(entitlements: HostedEntitlements, now: Date) -> Bool {
    guard case .trial(let trial) = hostedPlanStatus(entitlements: entitlements, now: now), trial.meetingsLeft > 0, let endsAt = entitlements.trialEndsAt else {
        return false
    }
    return endsAt.timeIntervalSince(now) > 24 * 60 * 60
}

// MARK: Geri çağırma

/// Deneme bittikten sonra (hiç abone olmamış hesapta) geri çağırma şeridinin gösterildiği günler.
public let hostedWinBackDays: [Int] = [3, 14]
/// Bu günden sonra geri çağırma gösterilmez.
public let hostedWinBackLastDay: Int = 45

/// Geri çağırma bu hesaba uygun mu: deneme bitti ve hesap hiç abone olmadı (eski abonelerin "abonelik sona erdi"
/// teklifi ayrıdır). Saf fonksiyondur.
public func hostedWinBackEligible(entitlements: HostedEntitlements, now: Date) -> Bool {
    guard entitlements.subscription == nil, entitlements.appStoreSubscription == nil, case .trial(let trial) = hostedPlanStatus(entitlements: entitlements, now: now) else {
        return false
    }
    return trial.meetingsLeft == 0
}

/// Denemenin bittiği an: süresi dolarak bittiyse o an; toplantılar biterek bittiyse uygulamanın bunu ilk gördüğü an
/// (`observedAt`, cihazda saklanır); bilinmiyorsa nil. Saf fonksiyondur.
public func hostedTrialEndedAt(trialEndsAt: Date?, observedAt: Date?, now: Date) -> Date? {
    if let trialEndsAt, trialEndsAt <= now {
        return trialEndsAt
    }
    return observedAt
}

/// Geri çağırma şeridi şimdi gösterilmeli mi: deneme bitişinden sonra sıradaki gün (`hostedWinBackDays[shownCount]`)
/// geldi, gösterim sayısı dolmadı ve `hostedWinBackLastDay` geçmedi. Kapatmak da gösterim sayılır. Saf fonksiyondur.
public func hostedWinBackDue(trialEndedAt: Date, shownCount: Int, now: Date) -> Bool {
    guard shownCount >= 0, shownCount < hostedWinBackDays.count else {
        return false
    }
    let elapsed: Double = now.timeIntervalSince(trialEndedAt)
    let day: Double = 24 * 60 * 60
    return elapsed >= Double(hostedWinBackDays[shownCount]) * day && elapsed <= Double(hostedWinBackLastDay) * day
}

// MARK: Aylık sınırda Pro

/// Aylık sınıra yaklaşan ya da ulaşan aboneye önerilecek Pro: hesabın erişimi sürüyor (ücretsiz erişim değil), katmanı
/// Kişisel ve sunucu Pro'yu satıyor. Pro abonede, denemede ve ücretsiz erişimde nil. Saf fonksiyondur.
public func hostedProUpsell(entitlements: HostedEntitlements, now: Date) -> HostedTierOffer? {
    switch hostedPlanStatus(entitlements: entitlements, now: now) {
    case .subscribed, .ending, .grace:
        break
    case .trial, .expired, .paymentOverdue, .complimentary:
        return nil
    }
    guard hostedAccountTier(entitlements: entitlements) == .personal else {
        return nil
    }
    return hostedProOffer(entitlements: entitlements)
}

/// Pro önerisinde seçili gelecek plan dönemi: abonenin şimdiki dönemi (aylık aboneye kendiliğinden yıllık ücret
/// seçtirilmez); bilinmiyorsa nil. Saf fonksiyondur.
public func hostedCurrentBillingPlan(entitlements: HostedEntitlements) -> HostedBillingPlan? {
    if let plan = entitlements.subscription?.billingPlan {
        return plan
    }
    return entitlements.appStoreSubscription?.plan.flatMap { HostedBillingPlan(rawValue: $0) }
}

/// Teklifin açılma anının huni nedeni (adlar birebir). Saf fonksiyondur.
public func conversionTrigger(moment: HostedUpsellMoment) -> ConversionTrigger {
    switch moment {
    case .trialNoteReady: .trialNoteReady
    case .trialEnding: .trialEnding
    case .trialEnded: .trialEnded
    case .subscriptionRequired: .subscriptionRequired
    case .planChoice: .planChoice
    case .winBack: .winBack
    }
}

/// Teklifin seçili gelecek katmanı: aylık sınırdan gelen Kişisel aboneye Pro (sınırı kendisi doldurdu), başka her yerde
/// Kişisel (denemede Pro hiçbir zaman önceden seçilmez). Saf fonksiyondur.
public func hostedPreselectedTier(trigger: ConversionTrigger, entitlements: HostedEntitlements?, now: Date) -> HostedTier {
    switch trigger {
    case .monthlyWarning, .monthlyFull:
        guard let entitlements, hostedProUpsell(entitlements: entitlements, now: now) != nil else {
            return .personal
        }
        return .pro
    case .trialNoteReady, .trialEnding, .trialEnded, .subscriptionRequired, .planChoice, .winBack, .trialReminder, .meetingStart:
        return .personal
    }
}
