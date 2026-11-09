import AINotepadCore
import AINotepadUI
import SwiftUI

// Abonelik ekranı (App Store aboneliği): durağan pastel film gradyanlı kapak, neler dahil, sunucu Pro'yu satıyorsa ve
// Pro paketleri teklifteyse katman seçimi (Kişisel, Pro), seçilen katmanın iki paketi (fiyatlar App Store'dan, kullanıcının
// bölgesinde), satın alma, geri yükleme, otomatik yenileme koşulları ve Kullanım Koşulları
// (Apple'ın standart EULA'sı), Gizlilik ve Koşullar bağlantıları (App Store 3.1.2). Uygulama dışı satın alma yolu yok.

/// Kullanım Koşulları (site), Gizlilik ve Apple'ın standart son kullanıcı sözleşmesi: App Review için sabit üretim
/// adresleri (Debug'daki yerel site değil).
private let paywallTermsURL: URL = URL(string: "https://gistsmith.com/terms")!
private let paywallPrivacyURL: URL = URL(string: "https://gistsmith.com/privacy")!
private let paywallAppleEULAURL: URL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

/// Abonelik ekranı. `reason`: neden açıldı (deneme bitti, abonelik gerekli; kullanıcı açtıysa `planChoice`); `trigger`:
/// huni nedeni (başlık ve telemetri); `meetings`: başlıktaki deneme sonucu için toplantılar.
struct PhonePaywall: View {
    let account: HostedAccount
    let reason: HostedUpsellMoment
    let meetings: [MeetingRecord]
    let onConnectCalendar: () -> Void
    let onClose: () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @State private var model: PaywallModel

    init(
        account: HostedAccount, reason: HostedUpsellMoment, trigger: ConversionTrigger, meetings: [MeetingRecord],
        onConnectCalendar: @escaping () -> Void, onClose: @escaping () -> Void
    ) {
        self.account = account
        self.reason = reason
        self.meetings = meetings
        self.onConnectCalendar = onConnectCalendar
        self.onClose = onClose
        _model = State(initialValue: PaywallModel(account: account, purchases: AppStorePurchases.shared, trigger: trigger))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaywallCover(onClose: close, isCloseEnabled: !isPaywallBusy(phase: model.phase))
                if model.phase == .completed {
                    PaywallCompleted(change: model.completedChange, onConnectCalendar: onConnectCalendar, onClose: onClose)
                } else {
                    // Kullanıcının kendi deneme sonucu ya da anın cümlesi (uydurma sayı yok; bkz. `hostedPaywallHeadline`).
                    Text(verbatim: model.headline(meetings: meetings))
                        .appFont(size: 20, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    // Kayıt başlatma anında başlık nedeni zaten söyler; ikinci cümle seçimi ekranın altına itmesin.
                    if model.trigger != .meetingStart, let reasonText = paywallReasonText(reason: reason) {
                        Text(reasonText)
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Katman kartları saatleri gösteriyorsa saat satırı tekrarlanmaz.
                    PaywallIncluded(monthlyHours: model.tierOffers.count > 1 ? nil : model.monthlyHours)
                    if model.tierOffers.count > 1 {
                        PaywallTierPicker(model: model)
                    }
                    PaywallPackages(model: model)
                    PaywallChangeNote(model: model)
                    PaywallStatus(model: model)
                    PaywallTerms()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        // "Abone ol" ve "Geri Yükle" altta sabit: küçük ekranda (iPhone SE) ve büyük yazıda da kaydırmadan görünür.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.phase != .completed {
                PaywallActions(model: model)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Theme.background)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .tint(appearance.accent.color)
        .interactiveDismissDisabled(isPaywallBusy(phase: model.phase))
        .task { await model.loadPackages() }
    }

    /// Kapat (✕): satın almadan kapatıldıysa huniye yazılır.
    private func close() {
        if model.phase != .completed {
            model.recordClosed()
        }
        onClose()
    }
}

/// Ekranın açılma nedeninin metni; kullanıcı kendisi açtıysa nil. Saf fonksiyondur.
func paywallReasonText(reason: HostedUpsellMoment) -> String? {
    switch reason {
    case .trialEnded:
        String(localized: "Ücretsiz denemen bitti. Kayda devam etmek için bir plan seç.")
    case .subscriptionRequired:
        String(localized: "Bunun için abonelik gerekiyor. Bir plan seç, hemen devam et.")
    case .trialEnding:
        String(localized: "Ücretsiz denemen bitmek üzere.")
    case .trialNoteReady, .planChoice, .winBack:
        nil
    }
}

/// Kapak: durağan film gradyanı üstünde başlık; sağ üstte kapatma düğmesi. Yükseklik sabit değil: küçük ekranda
/// kısalır (satın alma düğmeleri görünür kalsın), büyük yazıda başlığa göre uzar.
private struct PaywallCover: View {
    let onClose: () -> Void
    let isCloseEnabled: Bool

    var body: some View {
        // Ekrana göre yükseklik en az değerdir: büyük yazıda kapak başlığa göre uzar (başlığın üstü kırpılmaz).
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .containerRelativeFrame(.vertical) { (length: CGFloat, _: Axis) -> CGFloat in
                    min(230, max(150, length * 0.26))
                }
            VStack(alignment: .leading, spacing: 8) {
                PastelChip(text: appName, systemImage: "sparkles")
                Text("Her toplantın için tam erişim")
                    .appFont(size: 28, weight: .regular)
                    .tracking(-0.5)
                    .foregroundStyle(Color.black.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .background { FilmGradient(seed: "gistsmith-abonelik", palette: .ocean) }
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(Color.black.opacity(0.75))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.85), in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isCloseEnabled)
                .accessibilityLabel(Text("Kapat"))
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .environment(\.colorScheme, .light)
    }
}

/// Aboneliğe neler dahil.
private struct PaywallIncluded: View {
    /// Aylık saat; katman kartları saatleri gösterdiğinde nil (satır yazılmaz, toplantı başına süre kalır).
    let monthlyHours: Double?

    var body: some View {
        // Üç satır: ekran küçük telefonda ve büyük yazıda da kaydırmadan seçim ve düğmeye insin.
        VStack(alignment: .leading, spacing: 12) {
            row(systemImage: "clock", text: monthlyHours == nil ? String(localized: "Toplantı başına en çok 4 saat kayıt") : hoursText)
            row(systemImage: "doc.text", text: String(localized: "Canlı metin ve yapay zekâ notu: özet, kararlar, görevler"))
            row(systemImage: "laptopcomputer.and.iphone", text: String(localized: "Mac ve iPhone'da tek abonelik"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line))
    }

    private var hoursText: String {
        guard let monthlyHours else {
            return String(localized: "Her ay yenilenen kayıt saatleri")
        }
        let style: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0...1))
        return String(localized: "Ayda \(monthlyHours.formatted(style)) saat kayıt, toplantı başına en çok 4 saat")
    }

    private func row(systemImage: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .appFont(size: 15, weight: .medium)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .appFont(size: 15, weight: .regular)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Katman seçimi (Kişisel, Pro) yan yana: adı, sunucunun aylık saati ve toplantı başına en uzun süresi; seçilen vurgu
/// renginde çerçeveli (paket kartlarıyla aynı).
private struct PaywallTierPicker: View {
    @Bindable var model: PaywallModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        // Erişilebilirlik boyutlarında kartlar alt alta: yan yana katman adı harf harf bölünüyordu ("Kişise" / "l").
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            ForEach(model.tierOffers, id: \.tier) { (offer: HostedTierOffer) in
                card(offer: offer)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(!canChoosePaywallPackage(phase: model.phase, packagesLoaded: !model.packages.isEmpty))
    }

    private func card(offer: HostedTierOffer) -> some View {
        let isSelected: Bool = model.selectedTier == offer.tier
        let style: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0...1))
        return Button {
            model.select(tier: offer.tier)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: offer.tier == .pro ? String(localized: "Pro") : String(localized: "Kişisel"))
                        .appFont(size: 16, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .appFont(size: 18, weight: .regular)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
                        .accessibilityHidden(true)
                }
                // Own line under the name: next to it the name broke mid-word ("Persona" / "l") on a half-width card.
                if model.currentAppStoreSubscription?.subscriptionTier == offer.tier {
                    Text("Şimdiki")
                        .appFont(size: 11, weight: .semibold)
                        .foregroundStyle(.tint)
                }
                Text(verbatim: String(localized: "Ayda \(offer.monthlyHours.formatted(style)) saat kayıt"))
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // Seçili dönemin fiyatı (tek seçim, tek fiyat): katmanlar fiyatıyla karşılaştırılabilir.
                if let price = model.priceText(tier: offer.tier, plan: model.selectedPlan) {
                    Text(verbatim: model.selectedPlan == .yearly ? String(localized: "\(price)/yıl") : String(localized: "\(price)/ay"))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.line), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// İki paket: seçilen vurgulu çerçeveyle; fiyatlar App Store'dan.
private struct PaywallPackages: View {
    @Bindable var model: PaywallModel

    var body: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .loadingProducts:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 150)
            case .productsUnavailable(let message):
                VStack(alignment: .leading, spacing: 10) {
                    NoticeText(message as String, severity: .error)
                    Button("Yeniden dene") { Task { await model.loadPackages() } }
                        .appFont(size: 15, weight: .semibold)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                ForEach(model.visiblePackages) { (package: PaywallPackage) in
                    PaywallPackageCard(
                        package: package, savings: package.plan == .yearly ? model.yearlySavings : nil,
                        isSelected: model.selectedPlan == package.plan,
                        isCurrent: model.currentAppStoreSubscription?.productId == package.productID
                    ) {
                        model.select(plan: package.plan)
                    }
                    .disabled(!canChoosePaywallPackage(phase: model.phase, packagesLoaded: !model.packages.isEmpty))
                }
            }
        }
    }
}

/// Tek paket kartı: plan adı, fiyat ve dönemi; yıllıkta aylık karşılığı ve tasarruf.
private struct PaywallPackageCard: View {
    let package: PaywallPackage
    let savings: Int?
    let isSelected: Bool
    /// App Store abonesinin şimdiki ürünü.
    let isCurrent: Bool
    let onSelect: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        // Erişilebilirlik boyutlarında fiyat ve tasarruf alta iner (yan yana sığmayınca kelimeler harf harf bölünüyordu).
        let isLarge: Bool = dynamicTypeSize.isAccessibilitySize
        let rowLayout: AnyLayout = isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        // Tasarruf rozeti adın altına iner: ad ve rozet yan yana sığmayınca ad küçülüyordu ("Gistsmith Yearly",
        // "Monthly"den küçük görünüyordu).
        let stacksTitle: Bool = isLarge || savings != nil
        let titleLayout: AnyLayout = stacksTitle ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        Button(action: onSelect) {
            rowLayout {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .appFont(size: 22, weight: .regular)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    titleLayout { titleAndSavings }
                    if isCurrent {
                        Text("Şimdiki planın")
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(.tint)
                    } else if let monthly = package.monthlyEquivalentText {
                        Text("Aylık \(monthly) karşılığı, yılda bir ödenir")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    } else {
                        Text("Her ay ödenir")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                }
                // Ad sütunu yeri Spacer'dan önce alır; yoksa paylaşılan genişlik ürün adını gereksiz yere küçültür.
                .layoutPriority(1)
                if !isLarge {
                    Spacer(minLength: 8)
                }
                VStack(alignment: isLarge ? .leading : .trailing, spacing: 2) {
                    Text(verbatim: package.priceText)
                        .appFont(size: 17, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                    Text(verbatim: periodText)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                // Fiyat hiç bölünmez ("$49" / ".00"); ad sütunu kalan yeri alır.
                .fixedSize()
            }
            // Erişilebilirlik boyutlarındaki dikey düzende de kart tam genişlikte (diğer kartlarla hizalı).
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.line), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Aboneliğin adı arayüz dilinde (3.1.2: aboneliğin adı görünmeli; App Store'un İngilizce ürün adı değil) ve yıllıkta
    /// tasarruf (dolgulu rozet değil, düz metin).
    @ViewBuilder
    private var titleAndSavings: some View {
        Text(verbatim: planTitle)
            .appFont(size: 16, weight: .semibold)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
        if let savings {
            Text(verbatim: hostedYearlySavingsText(percent: savings))
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(.tint)
        }
    }

    private var planTitle: String {
        switch (package.tier, package.plan) {
        case (.personal, .monthly): String(localized: "Gistsmith Kişisel · Aylık")
        case (.personal, .yearly): String(localized: "Gistsmith Kişisel · Yıllık")
        case (.pro, .monthly): String(localized: "Gistsmith Pro · Aylık")
        case (.pro, .yearly): String(localized: "Gistsmith Pro · Yıllık")
        }
    }

    private var periodText: String {
        switch package.plan {
        case .monthly: String(localized: "aylık")
        case .yearly: String(localized: "yıllık")
        }
    }
}

/// App Store abonesine seçili pakete geçişin ne zaman geçerli olacağı (Apple'ın kuralı); abone değilse boş.
private struct PaywallChangeNote: View {
    let model: PaywallModel

    var body: some View {
        if model.isCurrentSelection {
            Text("Bu zaten şimdiki planın.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
        } else {
            switch model.selectedChangeTiming {
            case .immediate:
                Text("Hemen geçerli olur; Apple şimdiki planının kalan süresini orantılı iade eder.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .atRenewal:
                Text("Şimdiki dönemin sonunda başlar; o zamana dek şimdiki planın sürer.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
    }
}

/// İşin durumu: satın alma tamamlanıyor, geri yüklenecek abonelik yok ya da hata.
private struct PaywallStatus: View {
    let model: PaywallModel

    var body: some View {
        switch model.phase {
        case .finishing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Satın alman tamamlanıyor…")
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
            }
        case .nothingToRestore:
            NoticeText("Bu Apple Hesabı'nda geri yüklenecek etkin abonelik yok.", severity: .attention)
                .appFont(size: 13, weight: .regular)
        case .purchaseFailed(let message):
            NoticeText(message as String, severity: .error)
                .appFont(size: 13, weight: .regular)
        case .finishingFailed(let message):
            VStack(alignment: .leading, spacing: 10) {
                NoticeText(message as String, severity: .error)
                    .appFont(size: 13, weight: .regular)
                Button("Yeniden dene") { Task { await model.retryFinishing() } }
                    .appFont(size: 15, weight: .semibold)
            }
        case .loadingProducts, .productsUnavailable, .choosing, .purchasing, .restoring, .completed:
            EmptyView()
        }
    }
}

/// Abone ol (vurgu renginde) ve Satın Alımları Geri Yükle.
private struct PaywallActions: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    let model: PaywallModel

    var body: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.purchase() }
            } label: {
                HStack(spacing: 10) {
                    if case .purchasing = model.phase {
                        ProgressView().tint(appearance.accent.onColor)
                    }
                    Text(verbatim: actionTitle)
                        .appFont(size: 17, weight: .semibold)
                }
                // The palette's text on the accent fill (dark ink on Ember's dark-mode accent; white was about 2:1).
                .foregroundStyle(appearance.accent.onColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.tint.opacity(isPurchaseEnabled ? 1 : 0.45), in: Capsule())
            }
            .buttonStyle(PressableCardStyle())
            .disabled(!isPurchaseEnabled)
            if let package = model.selectedPackage, model.currentAppStoreSubscription == nil {
                Text(verbatim: hostedAppStoreRenewalLine(priceText: package.priceText, plan: package.plan))
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await model.restore() }
            } label: {
                HStack(spacing: 8) {
                    if model.phase == .restoring {
                        ProgressView()
                    }
                    Text("Satın Alımları Geri Yükle")
                        .appFont(size: 15, weight: .medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(isPaywallBusy(phase: model.phase) || model.phase == .loadingProducts)
        }
    }

    /// Düğmenin metni: fiyatıyla "Abone ol" (aboneye "Planı değiştir").
    private var actionTitle: String {
        guard model.currentAppStoreSubscription == nil else {
            return String(localized: "Planı değiştir")
        }
        guard let price = model.selectedPackage?.priceText else {
            return String(localized: "Abone ol")
        }
        return String(localized: "Abone ol · \(price)")
    }

    /// Satın alınabilir mi: paket seçilebiliyor ve seçili paket şimdiki plan değil.
    private var isPurchaseEnabled: Bool {
        canChoosePaywallPackage(phase: model.phase, packagesLoaded: !model.packages.isEmpty) && !model.isCurrentSelection
    }
}

/// Otomatik yenileme koşulları ve yasal bağlantılar (App Store 3.1.2).
private struct PaywallTerms: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ödeme, satın almayı onayladığında Apple Hesabı'ndan alınır. Abonelik, dönem bitmeden en az 24 saat önce iptal edilmezse aynı fiyat ve süreyle kendiliğinden yenilenir; yenileme ücreti dönemin son 24 saatinde alınır. Aboneliğini iPhone'da Ayarlar › adın › Abonelikler'den yönetebilir ya da iptal edebilirsin.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Kullanım Koşulları (EULA)", destination: paywallAppleEULAURL)
                Link("Gizlilik", destination: paywallPrivacyURL)
                Link("Koşullar", destination: paywallTermsURL)
            }
            .appFont(size: 12, weight: .medium)
            .foregroundStyle(.tint)
        }
    }
}

/// Satın alma tamamlandı: abonelik etkin ya da (yenilemede başlayan geçişte) plan değişikliği planlandı.
private struct PaywallCompleted: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// App Store abonesinin geçişi; yeni abonelikte nil.
    let change: HostedAppStoreChangeTiming?
    let onConnectCalendar: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if change == .atRenewal {
                Label("Plan değişikliğin planlandı", systemImage: "calendar.badge.checkmark")
                    .appFont(size: 20, weight: .semibold)
                    .foregroundStyle(.tint)
                Text("Yeni planın şimdiki dönemin sonunda başlar; o zamana dek şimdiki planın sürer.")
                    .appFont(size: 15, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Aboneliğin etkin", systemImage: "checkmark.circle.fill")
                    .appFont(size: 20, weight: .semibold)
                    .foregroundStyle(.tint)
                Text("Mac'te ve iPhone'da aynı hesapla giriş yaptığın her yerde tam erişimin var.")
                    .appFont(size: 15, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // Tek sonraki adım: toplantılar takvimden gelince kayıt bir dokunuşla başlar.
                Button(action: onConnectCalendar) {
                    Label("Takvimini bağla", systemImage: "calendar")
                        .appFont(size: 15, weight: .semibold)
                }
                .foregroundStyle(.tint)
            }
            Button(action: onClose) {
                Text("Bitti")
                    .appFont(size: 17, weight: .semibold)
                    .foregroundStyle(appearance.accent.onColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.tint, in: Capsule())
            }
            .buttonStyle(PressableCardStyle())
        }
    }
}

/// Tasarruf yüzdesi arayüz dilinin biçiminde ("31%", "%31"); bölge biçimi (ör. "31 %") değil, dil. Saf fonksiyondur.
func savingsText(percent: Int) -> String {
    let language: Locale = Locale(identifier: interfaceLocale().language.languageCode?.identifier ?? "en")
    return (Double(percent) / 100).formatted(.percent.locale(language))
}
