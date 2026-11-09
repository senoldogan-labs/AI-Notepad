import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

// Abonelik planları: abone olma teklifi (plan seçimi, davet kodu, deneme sonu özeti) ve Ayarlar › Hesap'taki plan ve
// davet bölümü. Görünüm sakin ve durağandır: tek durağan film gradyanı, sürekli animasyon yok.

/// Planın adı, ör. "Yıllık". Saf fonksiyondur.
func hostedPlanName(plan: HostedBillingPlan) -> String {
    switch plan {
    case .monthly: String(localized: "Aylık")
    case .yearly: String(localized: "Yıllık")
    }
}

/// Katmanın adı, ör. "Pro". Saf fonksiyondur.
func hostedTierName(tier: HostedTier) -> String {
    switch tier {
    case .personal: String(localized: "Kişisel")
    case .pro: String(localized: "Pro")
    }
}

/// Saat sayısı arayüz dilinde, en çok bir ondalıkla, ör. "30" ya da "2,5". Saf fonksiyondur.
func hostedHoursNumberText(hours: Double) -> String {
    hours.formatted(.number.precision(.fractionLength(0...1)).locale(interfaceLocale()))
}

/// Katmanın planının fiyatı dönemiyle, ör. "$49/yıl". Saf fonksiyondur.
func hostedPlanPriceText(tier: HostedTier, plan: HostedBillingPlan) -> String {
    let price: String = hostedUSDText(cents: hostedPlanPriceCents(tier: tier, plan: plan))
    switch plan {
    case .monthly: return String(localized: "\(price)/ay")
    case .yearly: return String(localized: "\(price)/yıl")
    }
}

/// Ayarlar › Hesap'taki plan satırı, ör. "Yıllık plan · $49/yıl"; Pro'da başta katman: "Pro · Yıllık plan · $109/yıl".
/// Saf fonksiyondur.
func hostedPlanLineText(tier: HostedTier, plan: HostedBillingPlan) -> String {
    let price: String = hostedPlanPriceText(tier: tier, plan: plan)
    switch (tier, plan) {
    case (.personal, .monthly): return String(localized: "Aylık plan · \(price)")
    case (.personal, .yearly): return String(localized: "Yıllık plan · \(price)")
    case (.pro, .monthly): return String(localized: "Pro · Aylık plan · \(price)")
    case (.pro, .yearly): return String(localized: "Pro · Yıllık plan · \(price)")
    }
}

/// Davet kodunun seçilen katman ve plandaki etkisi: Kişisel aylıkta ilk ay ücretsiz; Kişisel yıllıkta ve Pro'da bir
/// Kişisel aylık ücret bir kez düşülür. Saf fonksiyondur.
func hostedReferralDiscountText(tier: HostedTier, plan: HostedBillingPlan) -> String {
    let first: String = hostedUSDText(cents: hostedReferralFirstPaymentCents(tier: tier, plan: plan))
    let discount: String = hostedUSDText(cents: hostedMonthlyPriceCents)
    switch (tier, plan) {
    case (.personal, .monthly):
        return String(localized: "Davet uygulandı: ilk ayın ücretsiz.")
    case (.pro, .monthly):
        return String(localized: "Davet uygulandı: ilk ayın \(first) (\(discount) indirim).")
    case (.personal, .yearly), (.pro, .yearly):
        return String(localized: "Davet uygulandı: ilk yılın \(first) (\(discount) indirim).")
    }
}

/// Stripe abonesinin Ayarlar › Hesap'tan geçebileceği katman: Kişisel abone ve sunucu Pro'yu satıyorsa Pro; Pro abone
/// ise Kişisel. Yalnızca erişimi süren, iptal edilmemiş, planı bilinen Stripe aboneliğinde (ücretsiz erişim ve App Store
/// aboneliği değişmez; iptal edilmiş abonelik önce sürdürülür); yoksa nil. Saf fonksiyondur.
func hostedStripeTierSwitchTarget(entitlements: HostedEntitlements) -> HostedTier? {
    guard let subscription = entitlements.subscription, subscription.paymentSource == .stripe, !subscription.complimentary,
          subscription.access == .active, subscription.cancelAt == nil, subscription.billingPlan != nil,
          let current = hostedAccountTier(entitlements: entitlements)
    else {
        return nil
    }
    switch current {
    case .personal:
        return hostedProOffer(entitlements: entitlements) == nil ? nil : .pro
    case .pro:
        return .personal
    }
}

/// Teklifin başlığı (tam teklif ve alttaki şerit).
func hostedUpsellTitle(moment: HostedUpsellMoment) -> LocalizedStringKey {
    switch moment {
    case .trialNoteReady: "Notun hazır"
    case .trialEnding: "Denemen bitmek üzere"
    case .trialEnded: "Ücretsiz denemen bitti"
    case .subscriptionRequired: "Devam etmek için abone ol"
    case .planChoice: "Planını seç"
    case .winBack: "Notların seni bekliyor"
    }
}

/// Teklifin açıklaması (tam teklif ve alttaki şerit); hesabın hak durumuna göre.
@MainActor
func hostedUpsellSubtitle(moment: HostedUpsellMoment, account: HostedAccount) -> String {
    switch moment {
    case .trialNoteReady:
        guard case .signedIn(let entitlements) = account.state, case .trial(let trialState) = hostedPlanStatus(entitlements: entitlements, now: Date()) else {
            return String(localized: "Abone olunca her toplantının notu böyle kendiliğinden hazırlanır.")
        }
        return String(localized: "Ücretsiz deneme: \(hostedTrialLeftText(left: trialState.meetingsLeft)). Abone olunca her toplantının notu böyle kendiliğinden hazırlanır.")
    case .trialEnding:
        guard case .signedIn(let entitlements) = account.state, let detail = hostedTrialEndingDetail(entitlements: entitlements, now: Date()) else {
            return String(localized: "Kesintisiz devam etmek için bir plan seç. Otomatik ücret alınmaz.")
        }
        return hostedTrialEndingText(detail: detail, now: Date())
    case .winBack:
        return hostedWinBackText()
    case .trialEnded:
        return String(localized: "Toplantıların ve notların bu Mac'te kalır. Yeni toplantıları kaydetmek için abone ol.")
    case .subscriptionRequired:
        return hostedSubscriptionRequiredReason(account: account)
    case .planChoice:
        // Saat sınırı sunucudan gelir; hak durumu bilinmiyorsa sayı yazılmaz.
        // Pro sunuluyorsa saatler katman kartlarında yazar.
        guard case .signedIn(let entitlements) = account.state, hostedProOffer(entitlements: entitlements) == nil else {
            return String(localized: "Canlı metin, hazır not ve görevler. İstediğin zaman iptal edebilirsin.")
        }
        let hours: String = hostedHoursNumberText(hours: entitlements.monthlyHoursCap)
        return String(localized: "Canlı metin, hazır not ve görevler; ayda \(hours) saate kadar kayıt. İstediğin zaman iptal edebilirsin.")
    }
}

/// Neden abone olmak gerektiği: bu Mac'te deneme kullanıldı, abonelik sona erdi ya da deneme bitti.
@MainActor
private func hostedSubscriptionRequiredReason(account: HostedAccount) -> String {
    if account.isTrialRefusedOnThisMac {
        return String(localized: "Bu Mac'te ücretsiz deneme başka bir hesapla kullanıldı. Kaydetmeye ve not almaya devam etmek için abone ol.")
    }
    if case .signedIn(let entitlements) = account.state, case .expired = hostedPlanStatus(entitlements: entitlements, now: Date()), entitlements.subscription != nil {
        return String(localized: "Aboneliğin sona erdi. Toplantıların ve notların bu Mac'te kalır; yeniden abone olunca kaldığın yerden devam edersin.")
    }
    return String(localized: "Ücretsiz denemen bitti. Toplantıların ve notların bu Mac'te kalır; yeni toplantılar için abone ol.")
}

/// Kendiliğinden gelen teklif (not hazır, deneme bitiyor ya da bitti; bkz. `hostedUpsellPresentation`): sayfayı
/// kapatmayan, pencerenin altında ince şerit. Not ve arşiv okunur kalır; "Planları gör" tam teklifi açar, "×" kapatır.
struct HostedUpsellStrip: View {
    let account: HostedAccount
    let moment: HostedUpsellMoment

    var body: some View {
        HStack(spacing: 12) {
            FilmGradient(seed: "gistsmith-abone", palette: .sunset)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "sparkles")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(Color.black.opacity(0.75))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hostedUpsellTitle(moment: moment))
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text(verbatim: hostedUpsellSubtitle(moment: moment, account: account))
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if offersReminder {
                Button("Bir gün önce hatırlat") {
                    Task { await turnOnReminder() }
                }
                .buttonStyle(.pill)
                .fixedSize()
            }
            Button("Planları gör") {
                if moment == .trialEnding {
                    account.recordConversion(.trialReminderTapped(channel: .inApp))
                } else {
                    account.recordConversion(.upsellTapped(trigger: conversionTrigger(moment: moment)))
                }
                account.expandUpsell()
            }
            .buttonStyle(.pillPrimary)
            .fixedSize()
            Button("Kapat", systemImage: "xmark") { account.dismissUpsell() }
                .labelStyle(.iconOnly)
                .buttonStyle(.hoverPlain)
                .foregroundStyle(Theme.muted)
                .accessibilityLabel("Teklifi kapat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardSurface(cornerRadius: 16)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .onAppear {
            if moment == .trialEnding {
                account.recordConversion(.trialReminderShown(channel: .inApp))
            } else if moment != .winBack {
                account.recordConversion(.upsellShown(trigger: conversionTrigger(moment: moment)))
            }
        }
    }

    @State private var reminderOn: Bool = UserDefaults.standard.bool(forKey: EngagementSettingKey.trialReminder)

    /// "Bir gün önce hatırlat" sunulur mu: deneme bitmek üzere, hatırlatma kapalı ve bitişe bir günden çok var.
    private var offersReminder: Bool {
        guard moment == .trialEnding, !reminderOn, case .signedIn(let entitlements) = account.state else {
            return false
        }
        return hostedTrialReminderOfferable(entitlements: entitlements, now: Date())
    }

    /// Hatırlatmayı açar: bildirim izni burada istenir; izin verilirse ayar açılır ve bildirim planı yeniden kurulur.
    private func turnOnReminder() async {
        guard await EngagementNotifier.shared.requestAuthorizationForReminder() else {
            return
        }
        UserDefaults.standard.set(true, forKey: EngagementSettingKey.trialReminder)
        reminderOn = true
        account.recordConversion(.trialReminderOptIn)
        EngagementNotifier.shared.scheduleRefresh()
    }
}

/// Abone olma teklifi (ana pencerede açılan kart): üstte durağan film gradyanı, uygulama simgesi ve "Gistsmith" rozeti;
/// başlık ve kısa açıklama; deneme bitmek üzereyse ya da bittiyse bu Mac'te o ana dek yapılanların özeti (toplantı,
/// görev, saat), değilse simgeli üç fayda; iki plan (yıllık seçili), isteğe bağlı davet kodu, seçilen planın ödeme
/// sayfasını açan düğme ve "Şimdi değil". Deneme notu hazır olunca (günde en çok bir), deneme bitmek üzereyken ve
/// bitince birer kez (bkz. `HostedAccount.meetingNoteReady`), abonelik gerektiren bir şey denenince (bkz.
/// `HostedAccount.requestSubscription`) ve "Abone ol"a basılınca (`HostedAccount.showPlans`) açılır; kayıt ve işleme
/// sürerken açılmaz. Ödeme sayfası açılamazsa teklif açık kalır, nedeni altında yazar.
struct HostedUpsellSheet: View {
    let account: HostedAccount
    let moment: HostedUpsellMoment
    /// Bu Mac'teki toplantılardan deneme özeti (deneme sonu anlarında gösterilir).
    let trialValue: HostedTrialValue

    @State private var plan: HostedBillingPlan = .yearly
    @State private var tier: HostedTier = .personal
    /// Önceden seçimi yazıldı (katman ve dönem bir kez, açılışta).
    @State private var didPreselect: Bool = false
    @State private var isInviteOpen: Bool = false
    @State private var inviteInput: String = ""
    @State private var invite: HostedInviteState = .none
    /// Height of the whole offer; the sheet asks for it and scrolls when the window is shorter (larger interface text,
    /// long languages, the trial summary), so "Not now" and the invite code never fall off the bottom.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            offer
                .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in proxy.size.height } action: { (height: CGFloat) -> Void in
                    contentHeight = height
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 460)
        .frame(idealHeight: contentHeight)
        // Sayfa zemini uygulamanınki: koyu temada sistemin gri sayfa zemini uygulamanın siyahıyla uyuşmuyordu.
        .presentationBackground(Theme.background)
        .onAppear {
            guard !didPreselect else {
                return
            }
            didPreselect = true
            tier = account.upsellPreselectedTier
            if tier == .pro, case .signedIn(let entitlements) = account.state, let current = hostedCurrentBillingPlan(entitlements: entitlements) {
                plan = current
            }
            account.recordConversion(.paywallShown(surface: .sheet, trigger: account.upsellTrigger, tiersOffered: tierOffers.count > 1 ? .personalPro : .personal))
        }
        .onChange(of: tier) { (_: HostedTier, selected: HostedTier) in
            account.recordConversion(.planSelected(surface: .sheet, trigger: account.upsellTrigger, tier: selected, plan: plan))
        }
        .onChange(of: plan) { (_: HostedBillingPlan, selected: HostedBillingPlan) in
            account.recordConversion(.planSelected(surface: .sheet, trigger: account.upsellTrigger, tier: tier, plan: selected))
        }
    }

    /// The offer itself: header, title, benefits, tier and plan pickers, subscribe button, "Not now" and the invite code.
    private var offer: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text(title)
                        .appFont(size: 24, weight: .medium)
                        .tracking(-0.4)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.ink)
                    Text(verbatim: subtitle)
                        .appFont(size: 13, weight: .regular)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                // Sayılar başlıkta (kullanıcının kendi deneme sonucu); altta tekrarlanmaz, faydalar yazar.
                benefits
                // Sunucu Pro'yu satıyorsa önce katman (Kişisel, Pro) seçilir; satmıyorsa teklif bugünkü gibi iki plandır.
                if tierOffers.count > 1 {
                    HostedTierPicker(offers: tierOffers, plan: plan, selection: $tier)
                }
                HostedPlanPicker(tier: tier, selection: $plan)
                VStack(spacing: 8) {
                    Button {
                        // A press while a checkout is opening or open is dropped synchronously: no second checkout
                        // (see `HostedCheckoutState`).
                        guard account.beginCheckoutAttempt() else {
                            return
                        }
                        Task {
                            // Yazılıp uygulanmamış ya da reddedilmiş kod sessizce düşmez (davet yalnızca ilk abonelikte
                            // geçer, sonradan eklenemez): önce doğrulanır; geçersizse ödeme açılmaz, neden kod alanında.
                            let referralCode: String?
                            if isInviteOpen, invite.code == nil, !inviteInput.trimmingCharacters(in: .whitespaces).isEmpty {
                                guard case .valid(let code) = await checkInvite() else {
                                    account.abandonCheckoutAttempt()
                                    return
                                }
                                referralCode = code
                            } else {
                                referralCode = invite.code
                            }
                            if await account.subscribe(tier: tier, plan: plan, referralCode: referralCode) {
                                account.dismissUpsell()
                            }
                        }
                    } label: {
                        Label(subscribeTitle, systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pillPrimary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostedCheckoutLocked(state: account.checkout) || invite == .checking)
                    // Yenileme koşulları düğmenin hemen altında (fiyat, dönem, iptal, dönem sonuna dek erişim, satıcı).
                    Text(verbatim: hostedStripeRenewalText(tier: tier, plan: plan))
                        .appFont(size: 11, weight: .regular)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if account.checkout == .awaitingReturn {
                        Text("Ödeme sayfası tarayıcıda açık; ödemeyi bitirince burası kendiliğinden güncellenir.")
                            .appFont(size: 12, weight: .regular)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .failed(let message) = account.checkout {
                        NoticeText(message as String, severity: .error)
                            .appFont(size: 12, weight: .regular)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Şimdi değil") {
                        account.recordConversion(.paywallClosed(surface: .sheet, trigger: account.upsellTrigger))
                        account.dismissUpsell()
                    }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.muted)
                    .keyboardShortcut(.cancelAction)
                    // Davet kodu en altta: kodu olmayan kullanıcı ödeme düğmesinin önünde aramaya başlamasın.
                    inviteSection
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
    }

    /// Üstteki durağan film gradyanı, uygulama simgesi ve rozet.
    private var header: some View {
        FilmGradient(seed: "gistsmith-abone", palette: .sunset)
            .frame(height: 132)
            .overlay {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .shadow(color: Color.black.opacity(0.2), radius: 14, y: 8)
                        .accessibilityHidden(true)
                    // Büyük harf elle yazılır: Türkçe yerel ayarda büyük harfe çevirme "GİSTSMİTH" yapıyordu.
                    Text(verbatim: "GISTSMITH")
                        .appFont(size: 11, weight: .semibold)
                        .tracking(1.2)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.22), in: Capsule())
                }
            }
    }

    /// Fayda listesi (deneme sonu özeti gösterilmeyen anlarda).
    private var benefits: some View {
        VStack(alignment: .leading, spacing: 10) {
            benefit(symbol: "waveform", text: "Canlı metin, konuşulurken")
            benefit(symbol: "checklist", text: "Toplantı bitince not hazır, görevler en üstte")
            benefit(symbol: "text.magnifyingglass", text: "Tüm toplantılarına soru sor")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// "Davet kodun var mı?" bağlantısı; açılınca kod alanı ve "Uygula" (kod ödemeden önce sunucuya doğrulatılır).
    @ViewBuilder
    private var inviteSection: some View {
        if case .valid = invite {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
                Text(verbatim: hostedReferralDiscountText(tier: tier, plan: plan))
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Kaldır") {
                    invite = .none
                    inviteInput = ""
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(Theme.muted)
            }
            .appFont(size: 12, weight: .regular)
        } else if isInviteOpen {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Davet kodu", text: $inviteInput)
                        .textFieldStyle(.roundedBorder)
                        .appMonoFont(size: 13, weight: .medium)
                        .onSubmit { applyInvite() }
                    Button("Uygula") { applyInvite() }
                        .disabled(inviteInput.trimmingCharacters(in: .whitespaces).isEmpty || invite == .checking)
                    if invite == .checking {
                        ProgressView().controlSize(.small)
                    }
                }
                if case .invalid(let message) = invite {
                    NoticeText(message as String, severity: .error)
                        .appFont(size: 12, weight: .regular)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Button("Davet kodun var mı?") { isInviteOpen = true }
                .buttonStyle(.hoverPlain)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
    }

    /// "Uygula": girilen kodu sunucuya doğrulatır.
    private func applyInvite() {
        Task { await checkInvite() }
    }

    /// Girilen kodu sunucuya doğrulatır; sonuç hem gösterilir hem döner (abone olmadan önce de kullanılır).
    @discardableResult
    private func checkInvite() async -> HostedInviteState {
        let input: String = inviteInput
        invite = .checking
        let result: HostedInviteState
        switch await account.validateReferral(input: input) {
        case .valid(let code):
            result = .valid(code: code)
        case .invalid(let message):
            result = .invalid(message: message)
        }
        invite = result
        return result
    }

    /// Düğmenin metni fiyatıyla, ör. "Abone ol · $49/yıl".
    private var subscribeTitle: String {
        String(localized: "Abone ol · \(hostedPlanPriceText(tier: tier, plan: plan))")
    }

    /// Sunucunun sattığı katmanlar (Pro sunulmuyorsa yalnızca Kişisel; eski sunucuda boş).
    private var tierOffers: [HostedTierOffer] {
        guard case .signedIn(let entitlements) = account.state else {
            return []
        }
        return hostedOfferedTiers(entitlements: entitlements)
    }

    /// Başlık: kullanıcının kendi deneme sonucu ya da anın cümlesi (bkz. `hostedPaywallHeadline`).
    private var title: String {
        let entitlements: HostedEntitlements? = {
            if case .signedIn(let value) = account.state {
                return value
            }
            return nil
        }()
        return hostedPaywallHeadlineText(headline: hostedPaywallHeadline(value: trialValue, entitlements: entitlements, trigger: account.upsellTrigger, now: Date()))
    }

    private var subtitle: String {
        hostedUpsellSubtitle(moment: moment, account: account)
    }

    private func benefit(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(Theme.ink)
                .frame(width: 26, height: 26)
                .background(Theme.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.line))
                .accessibilityHidden(true)
            Text(text)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Satın almadan sonraki onay (bir kez): abonelik etkin ve tek sonraki adım (takvimi bağla: toplantılar kendiliğinden
/// gelir, kayıt bir tıkla başlar).
struct HostedPurchaseConfirmationSheet: View {
    let tier: HostedTier
    let onConnectCalendar: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .appFont(size: 28, weight: .medium)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(verbatim: hostedPurchaseConfirmationText(tier: tier))
                .appFont(size: 17, weight: .medium)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Sıradaki adım: takvimini bağla. Toplantıların listede hazır bekler, kayıt tek tıkla başlar.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Sonra") { onClose() }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.muted)
                    .keyboardShortcut(.cancelAction)
                Button("Takvimini bağla") { onConnectCalendar() }
                    .buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 420)
        .presentationBackground(Theme.background)
    }
}

/// Teklifteki davet kodunun durumu.
enum HostedInviteState: Equatable {
    case none
    case checking
    case valid(code: String)
    case invalid(message: String)

    /// Ödeme sayfasına gönderilecek kod; doğrulanmadıysa nil.
    var code: String? {
        if case .valid(let code) = self {
            return code
        }
        return nil
    }
}

/// Katmanlar yan yana (Kişisel, Pro): adı, sunucunun aylık saati ve toplantı başına en uzun süresi. Seçili kart koyu
/// çerçeveli (plan kartlarıyla aynı).
struct HostedTierPicker: View {
    let offers: [HostedTierOffer]
    /// Seçili plan dönemi: kartta o dönemin fiyatı yazar (tek seçim, tek fiyat).
    let plan: HostedBillingPlan
    @Binding var selection: HostedTier

    var body: some View {
        HStack(spacing: 10) {
            ForEach(offers, id: \.tier) { (offer: HostedTierOffer) in
                card(offer: offer)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(offer: HostedTierOffer) -> some View {
        let isSelected: Bool = selection == offer.tier
        return Button {
            selection = offer.tier
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
                        .accessibilityHidden(true)
                    Text(verbatim: hostedTierName(tier: offer.tier))
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    Text(verbatim: hostedPlanPriceText(tier: offer.tier, plan: plan))
                        .appFont(size: 11, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Text(verbatim: String(localized: "Ayda \(hostedHoursNumberText(hours: offer.monthlyHours)) saat kayıt"))
                    .appFont(size: 15, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 2)
                Text(verbatim: String(localized: "Toplantı başına en çok \(hostedHoursNumberText(hours: Double(offer.meetingMaxMinutes) / 60)) saat"))
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.line), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// İki plan yan yana: aylık ve yıllık (yıllıkta tasarruf rozeti ve aylık karşılığı), seçilen katmanın fiyatlarıyla.
/// Seçili kart koyu çerçeveli.
struct HostedPlanPicker: View {
    let tier: HostedTier
    @Binding var selection: HostedBillingPlan

    var body: some View {
        HStack(spacing: 10) {
            card(plan: .monthly)
            card(plan: .yearly)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(plan: HostedBillingPlan) -> some View {
        let isSelected: Bool = selection == plan
        return Button {
            selection = plan
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
                        .accessibilityHidden(true)
                    Text(verbatim: hostedPlanName(plan: plan))
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                }
                Text(verbatim: hostedPlanPriceText(tier: tier, plan: plan))
                    .appFont(size: 18, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 2)
                Text(verbatim: caption(plan: plan))
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if plan == .yearly {
                    // Tasarruf düz metin (dolgulu rozet değil), her yüzeyde aynı aşağı yuvarlanmış rakam.
                    Text(verbatim: hostedYearlySavingsText(percent: hostedYearlySavingsPercent(tier: tier)))
                        .appFont(size: 11, weight: .semibold)
                        .foregroundStyle(.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.line), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func caption(plan: HostedBillingPlan) -> String {
        switch plan {
        case .monthly:
            String(localized: "Her ay yenilenir")
        case .yearly:
            String(localized: "Aylık yaklaşık \(hostedUSDText(cents: hostedYearlyMonthlyEquivalentCents(tier: tier)))")
        }
    }
}

/// Deneme sonu özeti: bu Mac'te kaydedilen toplantılar, notlardan çıkan görevler ve yazıya dökülen saat.
struct HostedTrialValueTiles: View {
    let value: HostedTrialValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bu Mac'te şimdiye dek")
                .appFont(size: 11, weight: .semibold)
                .foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                tile(number: value.meetings.formatted(.number.locale(interfaceLocale())), label: "Kaydedilen toplantı")
                tile(number: value.tasks.formatted(.number.locale(interfaceLocale())), label: "Çıkan görev")
                tile(number: value.hours.formatted(.number.precision(.fractionLength(0...1)).locale(interfaceLocale())), label: "Yazıya dökülen saat")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tile(number: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: number)
                .appFont(size: 24, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text(label)
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// Ayarlar › Hesap'taki davet bölümü (yalnızca abonede ve program açıkken): kod, kopyalanabilir davet metni, kaç
/// arkadaşın katıldığı ve bekleyen ödülün tahmini tarihi. Ücretsiz erişimli hesapta ödülün uygulanmadığı yazar. Davet
/// bilgisi Ayarlar › Hesap açılınca okunur (`HostedAccount.loadReferral`); okunamazsa bölüm görünmez.
struct HostedReferralRow: View {
    let account: HostedAccount
    @State private var copied: Bool = false

    var body: some View {
        Group {
            if let referral = account.referral, referral.enabled, let code = referral.code, let inviteURL = referral.inviteUrl {
                SettingsRow(icon: "gift", title: Text("Arkadaşını davet et")) {
                    Text(verbatim: hostedReferralRewardText(referral: referral))
                    Text(verbatim: code)
                        .appMonoFont(size: 17, weight: .semibold)
                        .tracking(2)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                    Text(verbatim: hostedReferralStatsText(referral: referral))
                } control: {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hostedInviteText(inviteURL: inviteURL), forType: .string)
                        copied = true
                    } label: {
                        Text(copied ? LocalizedStringKey("Kopyalandı") : LocalizedStringKey("Davet metnini kopyala"))
                    }
                }
            }
        }
    }
}
