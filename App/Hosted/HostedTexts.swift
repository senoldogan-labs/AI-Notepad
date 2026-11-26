import AINotepadCore
import AINotepadUI
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

/// Duraklatma bildirimlerinin kayıt ekranındaki uyarısı; hepsi onaylandıysa nil. Onaylanmayan duraklatma süre sınırını
/// ileri itmez (sunucu bitişin tek kaynağıdır).
func pauseConfirmationText(confirmation: PauseConfirmation) -> String? {
    switch confirmation {
    case .confirmed:
        nil
    case .unconfirmed:
        String(localized: "Duraklatma henüz sunucuya bildirilemedi; bağlantı gelince yeniden denenecek. Onaylanana dek bu duraklatma süre sınırına sayılabilir.")
    case .refused:
        String(localized: "Bir duraklatma sunucuda kaydedilemedi; o duraklatma toplantının süre sınırına sayılıyor.")
    }
}

/// Uyarının olası bütün metinleri (değişince eskisi kaldırılır).
func pauseConfirmationTexts() -> [String] {
    [PauseConfirmation.unconfirmed, .refused].compactMap { pauseConfirmationText(confirmation: $0) }
}

/// Plan durumunun tek cümlesi (Ayarlar'ın üstündeki plan kartı, iPhone'daki hesap ekranı). Saf fonksiyondur.
func hostedPlanStatusText(status: HostedPlanStatus) -> String {
    switch status {
    case .trial(.ended):
        String(localized: "Ücretsiz denemen bitti.")
    case .trial(let trialState):
        String(localized: "Ücretsiz deneme: \(hostedTrialLeftText(left: trialState.meetingsLeft)).")
    case .subscribed(let renewsAt):
        String(localized: "Abonelik etkin; dönem \(hostedDayText(date: renewsAt)) tarihinde yenilenir.")
    case .complimentary:
        String(localized: "Ücretsiz tam erişim.")
    case .ending(let endsAt):
        String(localized: "Abonelik \(hostedDayText(date: endsAt)) tarihine kadar etkin, yenilenmeyecek.")
    case .grace(let endsAt):
        String(localized: "Ödeme alınamadı; erişimin \(hostedDayText(date: endsAt)) tarihine kadar sürer.")
    case .paymentOverdue:
        String(localized: "Ödeme alınamadığı için yeni toplantı başlatılamıyor.")
    case .expired(let endedAt):
        String(localized: "Planın \(hostedDayText(date: endedAt)) tarihinde sona erdi.")
    case .free(let allowance):
        String(localized: "Ücretsiz plan: \(hostedFreeNotesLeftText(allowance: allowance)).")
    }
}

/// The free plan's notes left this month, e.g. "3 of 4 AI notes left this month". Pure function.
func hostedFreeNotesLeftText(allowance: HostedFreeAllowance) -> String {
    String(localized: "bu ay \(allowance.notesLeft)/\(allowance.notesTotal) yapay zekâ notu kaldı")
}

/// The free plan's questions left this month. Pure function.
func hostedFreeAsksLeftText(allowance: HostedFreeAllowance) -> String {
    String(localized: "bu ay \(allowance.asksLeft)/\(allowance.asksTotal) soru kaldı")
}

/// What the free plan includes, in one sentence (plan card, offers, the free plan strip): limits from the server, never
/// called a trial. Pure function.
func hostedFreePlanTermsText(allowance: HostedFreeAllowance) -> String {
    String(localized: "Ücretsiz plan: cihazda sınırsız transkript, ayda \(allowance.notesTotal) yapay zekâ notu (en çok \(allowance.maxMeetingMinutes) dakikalık toplantılar) ve \(allowance.asksTotal) soru.")
}

/// What a paid plan adds to the free plan, in one sentence. Pure function.
func hostedFreePlanUpgradeText() -> String {
    String(localized: "Kişisel plan her toplantının notunu yazar; konuşmacılar, adlar, canlı çeviri ve Mac ile iPhone arasında eşitleme ekler.")
}

/// When the free plan's counters reset (the start of the next UTC month), as a day. Pure function.
func hostedFreeResetText(allowance: HostedFreeAllowance) -> String {
    String(localized: "Sıfırlanma: \(hostedDayText(date: allowance.resetsAt))")
}

/// Hesabın tek cümlesi: plan durumu ya da hesabın okunamama nedeni (hesap satırı, plan kartı). Saf fonksiyondur.
func hostedAccountSummary(state: HostedAccountState) -> String {
    switch state {
    case .loading:
        String(localized: "Hesap okunuyor…")
    case .signedOut:
        String(localized: "Giriş yapılmadı")
    case .signedIn(let entitlements):
        hostedPlanStatusText(status: hostedPlanStatus(entitlements: entitlements, now: Date()))
    case .signedInStatusUnknown:
        String(localized: "Hesap durumu şu an okunamıyor.")
    case .unavailable(let message):
        message
    }
}

/// Plan kartının gösterdiği plan durumu: giriş yapılmış ve hak durumu okunmuşsa; yoksa nil (kart hesabın durumunu
/// yazar). Saf fonksiyondur.
func hostedBannerPlanStatus(state: HostedAccountState) -> HostedPlanStatus? {
    guard case .signedIn(let entitlements) = state else {
        return nil
    }
    return hostedPlanStatus(entitlements: entitlements, now: Date())
}

/// Plan kartının gösterdiği katman: giriş yapılmış ve ücretli erişim varsa; yoksa nil. Saf fonksiyondur.
func hostedBannerTier(state: HostedAccountState) -> HostedTier? {
    guard case .signedIn(let entitlements) = state else {
        return nil
    }
    return hostedAccountTier(entitlements: entitlements)
}

/// Ayarlar'ın üstündeki plan kartının başlığı: planın tek bakışta adı; Pro abonede "Pro abonelik". Saf fonksiyondur.
func hostedPlanHeadline(status: HostedPlanStatus, tier: HostedTier?) -> String {
    switch status {
    case .trial(.ended):
        String(localized: "Deneme bitti")
    case .trial:
        String(localized: "Ücretsiz deneme")
    case .subscribed, .ending:
        tier == .pro ? String(localized: "Pro abonelik") : String(localized: "Abonelik")
    case .complimentary:
        String(localized: "Ücretsiz tam erişim")
    case .grace, .paymentOverdue:
        String(localized: "Ödeme alınamadı")
    case .expired:
        String(localized: "Abonelik sona erdi")
    case .free:
        String(localized: "Ücretsiz plan")
    }
}

/// Plan kartının başlığın altındaki cümlesi: denemede kalan toplantı (başlık zaten "Ücretsiz deneme" der), bitmiş
/// denemede ne yapılacağı; başka durumda planın cümlesi. Saf fonksiyondur.
func hostedPlanBannerDetail(status: HostedPlanStatus) -> String {
    switch status {
    case .trial(.ended):
        String(localized: "Yeni toplantılar için abone ol; toplantıların ve notların kalır.")
    case .trial(let trialState):
        hostedTrialLeftText(left: trialState.meetingsLeft)
    case .subscribed, .complimentary, .ending, .grace, .paymentOverdue, .expired:
        hostedPlanStatusText(status: status)
    case .free(let allowance):
        String(localized: "Transkriptler bu cihazda; \(hostedFreeNotesLeftText(allowance: allowance)).")
    }
}

/// Plan kartı "Abone ol" sunar mı: abonelik yok (deneme ya da sona ermiş). Ödemesi alınamamış abonelikte yeni abonelik
/// açılamaz (kart güncellenir). Saf fonksiyondur.
func hostedPlanOffersSubscription(status: HostedPlanStatus) -> Bool {
    switch status {
    case .trial, .expired, .free:
        true
    case .subscribed, .complimentary, .ending, .grace, .paymentOverdue:
        false
    }
}

/// Plan kartının durgun pastel gradyanı: etkin plan yeşil, deneme mavi, biten plan mor, ödeme sorunu sıcak ton (uyarıyı
/// renk değil cümle söyler). Saf fonksiyondur.
func hostedPlanBannerPalette(status: HostedPlanStatus) -> FilmPalette {
    switch status {
    case .subscribed, .complimentary:
        .mint
    case .trial, .free:
        .ocean
    case .ending, .expired:
        .violet
    case .grace, .paymentOverdue:
        .coral
    }
}

// MARK: Abonelik teklifi (Mac'teki planlar sayfası ve iPhone'un abonelik ekranı)

/// Teklifin başlığı (bkz. `hostedPaywallHeadline`): kullanıcının kendi deneme sonucu ya da anın cümlesi. Saf fonksiyondur.
func hostedPaywallHeadlineText(headline: HostedPaywallHeadline) -> String {
    switch headline {
    case .meetingsAndTasks(let meetings, let tasks):
        return String(localized: "\(meetings) toplantı. \(tasks) görev yakalandı. Hepsi senin için yazıldı.")
    case .meetingsAndTime(let meetings, let minutes):
        return minutes >= 60
            ? String(localized: "\(meetings) toplantı, \(minutes / 60) saatlik konuşma. Hepsi senin için yazıldı.")
            : String(localized: "\(meetings) toplantı, \(minutes) dakikalık konuşma. Hepsi senin için yazıldı.")
    case .outcomeOnly:
        return String(localized: "Her toplantın, senin için yazılı.")
    case .meetingStarting:
        return String(localized: "Toplantın başlıyor. Abone ol, bunun da notu çıksın.")
    case .choosePlan:
        return String(localized: "Planını seç")
    }
}

/// Yıllık planın tasarrufu metin olarak (dolgulu rozet değil), ör. "Aylığa göre %31 tasarruf". Saf fonksiyondur.
func hostedYearlySavingsText(percent: Int) -> String {
    let language: Locale = Locale(identifier: interfaceLocale().language.languageCode?.identifier ?? "en")
    let value: String = (Double(percent) / 100).formatted(.percent.locale(language))
    return String(localized: "Aylığa göre \(value) tasarruf")
}

/// Bitmek üzere olan denemenin cümlesi (şerit ve iPhone'daki kart): kalan son toplantı ya da bitiş günü; ücret
/// alınmadığını da söyler. Saf fonksiyondur.
func hostedTrialEndingText(detail: HostedTrialEndingDetail, now: Date) -> String {
    switch detail {
    case .lastMeeting:
        return String(localized: "Denemende son bir toplantı kaldı. Otomatik ücret alınmaz.")
    case .endsSoon(let endsAt, let meetingsLeft):
        switch hostedRelativeDay(date: endsAt, now: now, calendar: .current) {
        case .today:
            return String(localized: "Denemen bugün bitiyor; \(meetingsLeft) toplantın kaldı. Otomatik ücret alınmaz.")
        case .tomorrow:
            return String(localized: "Denemen yarın bitiyor; \(meetingsLeft) toplantın kaldı. Otomatik ücret alınmaz.")
        case .later(let date):
            let day: String = date.formatted(Date.FormatStyle().weekday(.wide).locale(interfaceLocale()))
            return String(localized: "Denemen \(day) bitiyor; \(meetingsLeft) toplantın kaldı. Otomatik ücret alınmaz.")
        }
    }
}

/// Mac'teki (Stripe) ödemenin koşulları, abone ol düğmesinin hemen altında: fiyat ve dönem, iptal edilene dek yenilenme,
/// nasıl iptal edileceği, dönem sonuna dek erişim ve satıcı (Link). Saf fonksiyondur.
func hostedStripeRenewalText(tier: HostedTier, plan: HostedBillingPlan) -> String {
    let price: String = hostedUSDText(cents: hostedPlanPriceCents(tier: tier, plan: plan))
    switch plan {
    case .monthly:
        return String(localized: "\(price) her ay, vergiler dahil; iptal edene dek kendiliğinden yenilenir. İstediğin zaman Ayarlar › Plan ve faturalandırma'dan iptal edersin; ödenen dönemin sonuna dek erişimin sürer. Satıcı Link'tir (Stripe); ödeme tarayıcında güvenli bir sayfada açılır.")
    case .yearly:
        return String(localized: "\(price) her yıl, vergiler dahil; iptal edene dek kendiliğinden yenilenir. İstediğin zaman Ayarlar › Plan ve faturalandırma'dan iptal edersin; ödenen dönemin sonuna dek erişimin sürer. Satıcı Link'tir (Stripe); ödeme tarayıcında güvenli bir sayfada açılır.")
    }
}

/// iPhone'daki abone ol düğmesinin altındaki kısa yenileme satırı (ayrıntılı koşullar aşağıda). Saf fonksiyondur.
func hostedAppStoreRenewalLine(priceText: String, plan: HostedBillingPlan) -> String {
    switch plan {
    case .monthly: String(localized: "\(priceText) her ay. İptal edene dek yenilenir; istediğin zaman iptal edebilirsin.")
    case .yearly: String(localized: "\(priceText) her yıl. İptal edene dek yenilenir; istediğin zaman iptal edebilirsin.")
    }
}

/// Geri çağırma şeridinin açıklaması (deneme bitti, hiç abone olunmadı). Saf fonksiyondur.
func hostedWinBackText() -> String {
    String(localized: "Denemende yazılan notların duruyor. Yeni toplantıları kaydetmek için bir plan seç; istediğin zaman iptal edebilirsin.")
}

/// Satın almadan sonraki onayın açıklaması. Saf fonksiyondur.
func hostedPurchaseConfirmationText(tier: HostedTier) -> String {
    switch tier {
    case .personal: String(localized: "Aboneliğin etkin. Aynı hesapla Mac'te ve iPhone'da her toplantının notu kendiliğinden hazır.")
    case .pro: String(localized: "Pro aboneliğin etkin. Daha çok kayıt saati hemen hesabında.")
    }
}

// MARK: Free plan offers (Mac strip and plans, iPhone card and paywall)

/// The free plan moment's title (`origin`: what ended before the free plan); nil for the trial's and the plans' moments
/// (their own copy). Pure function.
func hostedFreeMomentTitle(moment: HostedUpsellMoment, origin: HostedFreePlanOrigin) -> String? {
    switch moment {
    case .freePlanStarted where origin == .subscriptionEnded: String(localized: "Aboneliğin bitti; ücretsiz plandasın")
    case .freePlanStarted: String(localized: "Denemen bitti; ücretsiz plandasın")
    case .freeNotesUsed: String(localized: "Bu ayki ücretsiz notların bitti")
    case .freeMeetingTooLong: String(localized: "Bu toplantı ücretsiz not için uzun")
    case .freeAsksUsed: String(localized: "Bu ayki ücretsiz soruların bitti")
    case .freeNeedsSync: String(localized: "Eşitleme Kişisel planla")
    case .trialNoteReady, .trialEnding, .trialEnded, .subscriptionRequired, .planChoice, .winBack: nil
    }
}

/// The free plan moment's detail: what happened, what is kept, what a paid plan adds; `allowance` is the free plan's
/// (nil when unknown: the sentence is written without numbers). Nil for the other moments. Pure function.
func hostedFreeMomentDetail(moment: HostedUpsellMoment, allowance: HostedFreeAllowance?) -> String? {
    switch moment {
    case .freePlanStarted:
        guard let allowance else {
            return hostedFreePlanUpgradeText()
        }
        #if os(macOS)
        return String(localized: "\(hostedFreePlanTermsText(allowance: allowance)) Toplantıların ve notların bu Mac'te kalır.")
        #else
        return String(localized: "\(hostedFreePlanTermsText(allowance: allowance)) Toplantıların ve notların bu iPhone'da kalır.")
        #endif
    case .freeNotesUsed:
        guard let allowance else {
            return hostedFreePlanMessage(reason: .freeNotesUsed)
        }
        return String(localized: "Transkript kaydedildi. Ücretsiz notlar \(hostedDayText(date: allowance.resetsAt)) tarihinde yenilenir; Kişisel plan her toplantının notunu yazar.")
    case .freeMeetingTooLong:
        guard let allowance else {
            return hostedFreePlanMessage(reason: .freeMeetingTooLong)
        }
        return String(localized: "Transkript kaydedildi. Ücretsiz notlar en çok \(allowance.maxMeetingMinutes) dakikalık toplantıları kapsar; Kişisel plan uzun toplantıların da notunu yazar.")
    case .freeAsksUsed:
        guard let allowance else {
            return hostedFreePlanMessage(reason: .freeAsksUsed)
        }
        return String(localized: "Ücretsiz sorular \(hostedDayText(date: allowance.resetsAt)) tarihinde yenilenir. Kişisel planla toplantılarına çok daha fazla soru sorabilirsin.")
    case .freeNeedsSync:
        #if os(macOS)
        return String(localized: "Ücretsiz planda toplantıların yalnız bu Mac'te kalır. Kişisel plan toplantılarını Mac ile iPhone arasında uçtan uca şifreli eşitler.")
        #else
        return String(localized: "Ücretsiz planda toplantıların yalnız bu iPhone'da kalır. Kişisel plan toplantılarını Mac ile iPhone arasında uçtan uca şifreli eşitler.")
        #endif
    case .trialNoteReady, .trialEnding, .trialEnded, .subscriptionRequired, .planChoice, .winBack:
        return nil
    }
}

/// The text of the card in place of a meeting's missing note on the free plan: how many free notes are left when one can
/// be written; else what a paid plan adds when the meeting's own notice (shown above the note) already says why it has
/// none, or the limit itself. Pure function.
func hostedFreeNoteCardText(action: HostedFreeNoteAction, notice: String?, allowance: HostedFreeAllowance) -> String {
    switch action {
    case .write:
        return String(localized: "Ücretsiz plan: \(hostedFreeNotesLeftText(allowance: allowance)). Bu toplantının notunu yazmak birini kullanır.")
    case .upgrade(let moment):
        if notice != nil {
            return hostedFreePlanUpgradeText()
        }
        return moment == .freeMeetingTooLong
            ? hostedFreeNoteNotice(decision: .tooLong(maxMinutes: allowance.maxMeetingMinutes)) ?? hostedFreePlanMessage(reason: .freeMeetingTooLong)
            : hostedFreeNoteNotice(decision: .notesUsed(total: allowance.notesTotal, resetsAt: allowance.resetsAt)) ?? hostedFreePlanMessage(reason: .freeNotesUsed)
    }
}

/// How the signed-in account came to the free plan (unknown: the trial).
@MainActor
func hostedFreePlanOrigin(account: HostedAccount) -> HostedFreePlanOrigin {
    guard case .signedIn(let entitlements) = account.state else {
        return .trialEnded
    }
    return hostedFreePlanOrigin(entitlements: entitlements)
}
