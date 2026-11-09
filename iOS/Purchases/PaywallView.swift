import AINotepadCore
import AINotepadUI
import SwiftUI

// Abonelik ekranı (App Store aboneliği): durağan pastel film gradyanlı kapak, neler dahil, iki paket (fiyatlar App
// Store'dan, kullanıcının bölgesinde), satın alma, geri yükleme, otomatik yenileme koşulları ve Kullanım Koşulları
// (Apple'ın standart EULA'sı), Gizlilik ve Koşullar bağlantıları (App Store 3.1.2). Uygulama dışı satın alma yolu yok.

/// Kullanım Koşulları (site), Gizlilik ve Apple'ın standart son kullanıcı sözleşmesi: App Review için sabit üretim
/// adresleri (Debug'daki yerel site değil).
private let paywallTermsURL: URL = URL(string: "https://gistsmith.com/terms")!
private let paywallPrivacyURL: URL = URL(string: "https://gistsmith.com/privacy")!
private let paywallAppleEULAURL: URL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

/// Abonelik ekranı. `reason`: neden açıldı (deneme bitti, abonelik gerekli; kullanıcı açtıysa `planChoice`).
struct PhonePaywall: View {
    let account: HostedAccount
    let reason: HostedUpsellMoment
    let onClose: () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @State private var model: PaywallModel

    init(account: HostedAccount, reason: HostedUpsellMoment, onClose: @escaping () -> Void) {
        self.account = account
        self.reason = reason
        self.onClose = onClose
        _model = State(initialValue: PaywallModel(account: account, purchases: AppStorePurchases.shared))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaywallCover(onClose: onClose, isCloseEnabled: !isPaywallBusy(phase: model.phase))
                if model.phase == .completed {
                    PaywallCompleted(onClose: onClose)
                } else {
                    if let reasonText = paywallReasonText(reason: reason) {
                        Text(reasonText)
                            .appFont(size: 15, weight: .medium)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PaywallIncluded(monthlyHours: monthlyHours)
                    PaywallPackages(model: model)
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

    /// Aylık kayıt saati sunucunun hak durumundan; hesap okunmadıysa nil (satır sayısız yazılır).
    private var monthlyHours: Double? {
        if case .signedIn(let entitlements) = account.state {
            return entitlements.monthlyHoursCap
        }
        return nil
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
    case .trialNoteReady, .planChoice:
        nil
    }
}

/// Kapak: durağan film gradyanı üstünde başlık; sağ üstte kapatma düğmesi. Yükseklik sabit değil: küçük ekranda
/// kısalır (satın alma düğmeleri görünür kalsın), büyük yazıda başlığa göre uzar.
private struct PaywallCover: View {
    let onClose: () -> Void
    let isCloseEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PastelChip(text: appName, systemImage: "sparkles")
            Text("Her toplantın için tam erişim")
                .appFont(size: 28, weight: .regular)
                .tracking(-0.5)
                .foregroundStyle(Color.black.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .containerRelativeFrame(.vertical, alignment: .bottomLeading) { (length: CGFloat, _: Axis) -> CGFloat in
            min(230, max(150, length * 0.26))
        }
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
    let monthlyHours: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(systemImage: "clock", text: hoursText)
            row(systemImage: "laptopcomputer.and.iphone", text: String(localized: "Mac ve iPhone'da tek abonelik"))
            row(systemImage: "waveform", text: String(localized: "Canlı yazıya dökme ve çeviri"))
            row(systemImage: "doc.text", text: String(localized: "Yapay zekâ notları: özet, kararlar, görevler"))
            row(systemImage: "sparkle.magnifyingglass", text: String(localized: "Sor: toplantılarına sor, kaynağıyla cevap al"))
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
        return String(localized: "Ayda \(monthlyHours.formatted(style)) saat kayıt")
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
                ForEach(model.packages) { (package: PaywallPackage) in
                    PaywallPackageCard(
                        package: package, savings: package.plan == .yearly ? model.yearlySavings : nil,
                        isSelected: model.selectedPlan == package.plan
                    ) {
                        model.selectedPlan = package.plan
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
    let onSelect: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        // Erişilebilirlik boyutlarında fiyat ve tasarruf alta iner (yan yana sığmayınca kelimeler harf harf bölünüyordu).
        let isLarge: Bool = dynamicTypeSize.isAccessibilitySize
        let rowLayout: AnyLayout = isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        let titleLayout: AnyLayout = isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        Button(action: onSelect) {
            rowLayout {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .appFont(size: 22, weight: .regular)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    titleLayout {
                        // App Store'daki ürün adı (3.1.2: aboneliğin adı görünmeli); boş gelirse planın adı.
                        Text(verbatim: package.title.isEmpty ? planTitle : package.title)
                            .appFont(size: 16, weight: .semibold)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let savings {
                            Text("\(savingsText(percent: savings)) tasarruf")
                                .appFont(size: 11, weight: .semibold)
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.tint, in: Capsule())
                        }
                    }
                    if let monthly = package.monthlyEquivalentText {
                        Text("Aylık \(monthly) karşılığı, yılda bir ödenir")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    } else {
                        Text("Her ay ödenir")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                }
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
            }
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

    private var planTitle: String {
        switch package.plan {
        case .monthly: String(localized: "Aylık")
        case .yearly: String(localized: "Yıllık")
        }
    }

    private var periodText: String {
        switch package.plan {
        case .monthly: String(localized: "aylık")
        case .yearly: String(localized: "yıllık")
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
    let model: PaywallModel

    var body: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.purchase() }
            } label: {
                HStack(spacing: 10) {
                    if case .purchasing = model.phase {
                        ProgressView().tint(.white)
                    }
                    Text("Abone ol")
                        .appFont(size: 17, weight: .semibold)
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.tint.opacity(canChoosePaywallPackage(phase: model.phase, packagesLoaded: !model.packages.isEmpty) ? 1 : 0.45), in: Capsule())
            }
            .buttonStyle(PressableCardStyle())
            .disabled(!canChoosePaywallPackage(phase: model.phase, packagesLoaded: !model.packages.isEmpty))
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

/// Satın alma tamamlandı: abonelik etkin.
private struct PaywallCompleted: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Aboneliğin etkin", systemImage: "checkmark.circle.fill")
                .appFont(size: 20, weight: .semibold)
                .foregroundStyle(.tint)
            Text("Mac'te ve iPhone'da aynı hesapla giriş yaptığın her yerde tam erişimin var.")
                .appFont(size: 15, weight: .regular)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onClose) {
                Text("Bitti")
                    .appFont(size: 17, weight: .semibold)
                    .foregroundStyle(Color.white)
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
