import SwiftUI

// Boş durumlar tek ailede (Mac ve iPhone): büyük sahne (hiç veri yokken: durgun pastel gradyanlı kart, başlık, tek satır,
// eylemler), sakin yer tutucu (seçim ya da sonuç yokken: vurgu renkli simge, kısa metin) ve satır içi kart. Simgeler ve
// ana düğme kullanıcının Görünüm'deki vurgu rengini alır; gri yalnızca ikincil yazıda. Hiçbir şey sürekli kıpırdamaz.

// MARK: Büyük sahne

/// Boş sayfanın sahnesi: üstte durgun film gradyanlı kart ve içinde örnek bir not kartı çizimi; altında başlık, tek satır
/// açıklama ve eylemler. Sahne açılışta bir kez yumuşakça belirir ("Hareketi azalt" açıksa hemen); sonra durgundur.
public struct EmptyScene<Actions: View>: View {
    let symbol: String
    let palette: FilmPalette
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actions: Actions
    @State private var isShown: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    public init(symbol: String, palette: FilmPalette, title: LocalizedStringKey, message: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.palette = palette
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 26) {
            EmptySceneArt(symbol: symbol, palette: palette)
                .scaleEffect(isShown ? 1 : 0.97)
            VStack(spacing: 8) {
                Text(title)
                    .appTitleFont(size: 26, weight: .semibold)
                    .tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(message)
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            actions
        }
        .frame(maxWidth: 600)
        .opacity(isShown ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.4)) { isShown = true }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Sahnenin çizimi: pastel film gradyanı (koyu temada kısılır) üstünde iki soluk kâğıt ve önde örnek bir not kartı
/// (vurgu renkli simge, iskelet satırlar, işaretlenmemiş bir görev). Her temada açık görünümle çizilir.
private struct EmptySceneArt: View {
    let symbol: String
    let palette: FilmPalette
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        ZStack {
            FilmGradient(seed: "bos-sahne-\(symbol)", palette: palette)
                .dimmedInDarkTheme()
            paper
                .rotationEffect(.degrees(-8))
                .offset(x: -46, y: 14)
                .opacity(0.45)
            paper
                .rotationEffect(.degrees(7))
                .offset(x: 48, y: 8)
                .opacity(0.6)
            noteCard
        }
        .environment(\.colorScheme, .light)
        .frame(maxWidth: 560)
        .frame(height: 188)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private var paper: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white)
            .frame(width: 200, height: 118)
    }

    private var noteCard: some View {
        let accent: Color = appearance.accent.color
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .appFont(size: 15, weight: .semibold)
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    skeleton(width: 104, height: 7, opacity: 0.22)
                    skeleton(width: 64, height: 6, opacity: 0.1)
                }
            }
            skeleton(width: 178, height: 6, opacity: 0.09)
            skeleton(width: 146, height: 6, opacity: 0.09)
            HStack(spacing: 7) {
                Circle()
                    .strokeBorder(accent, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
                skeleton(width: 112, height: 6, opacity: 0.12)
            }
        }
        .padding(16)
        .frame(width: 226, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    private func skeleton(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(Color.black.opacity(opacity))
            .frame(width: width, height: height)
    }
}

// MARK: Sakin yer tutucu

/// Alanın ortasında sakin boş durum (seçim yok, eşleşen sonuç yok): vurgu renkli simge kutusu, kısa başlık, en çok bir
/// satır açıklama ve (varsa) eylemler.
public struct QuietEmptyState<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let actions: Actions

    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey?, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 52)
            VStack(spacing: 4) {
                Text(title)
                    .appFont(size: 15, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300)
                }
            }
            actions
        }
        .padding(DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Sayfa içindeki boş bölüm kartı (not yok, tamamlanan görev yok…): solda vurgu renkli simge kutusu, yanında başlık ve
/// (varsa) açıklama. Gerçek uyarılar için değil (onlar `NoticeText`).
public struct QuietEmptyCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?

    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey?) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Vurgu renginde simge, aynı rengin soluk zemininde yuvarlatılmış kare içinde.
public struct AccentSymbolTile: View {
    let symbol: String
    let size: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(symbol: String, size: CGFloat) {
        self.symbol = symbol
        self.size = size
    }

    public var body: some View {
        Image(systemName: symbol)
            .appFont(size: size * 0.4, weight: .medium)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(appearance.accent.color)
            .frame(width: size, height: size)
            .background(appearance.accent.softFill(tintOpacity: 0.11), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Vurgu düğmesi

/// Boş durumun ana eylemi: vurgu renginde dolu kapsül, beyaz yazı (ölçüler denetim boyutuna göre hap düğmeyle aynı). Fare üstündeyken hafif
/// açılır, basılınca küçülür; etkin değilse soluk zemin.
public struct AccentPillButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        AccentPillBody(configuration: configuration)
    }
}

private struct AccentPillBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.controlSize) private var controlSize: ControlSize
    @State private var isHovering: Bool = false

    var body: some View {
        let accent: Color = appearance.accent.fillColor
        let metrics: AccentPillMetrics = accentPillMetrics(controlSize: controlSize)
        configuration.label
            .appFont(size: metrics.size, weight: .medium)
            .lineLimit(1)
            // The palette's text on the accent fill: white in Classic, dark ink on Ember's light dark-mode accents
            // (white on Ember dark "Kor" was about 2:1).
            .foregroundStyle(isEnabled ? appearance.accent.onFillColor : Theme.muted)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .background(isEnabled ? accent.opacity(isHovering ? 0.86 : 1) : Theme.soft, in: Capsule())
            .shadow(color: accent.opacity(isEnabled ? 0.28 : 0), radius: 10, y: 4)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .linkPointer(isEnabled: isEnabled)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Vurgu düğmesinin dolgu ve yazı ölçüsü.
private struct AccentPillMetrics {
    let horizontal: CGFloat
    let vertical: CGFloat
    let size: CGFloat
}

/// Denetim boyutunun ölçüleri (`.pill` ile aynı: yan yana duran iki düğme aynı boyda). Saf fonksiyondur.
private func accentPillMetrics(controlSize: ControlSize) -> AccentPillMetrics {
    switch controlSize {
    case .mini, .small: AccentPillMetrics(horizontal: 11, vertical: 5, size: 12)
    case .large, .extraLarge: AccentPillMetrics(horizontal: 18, vertical: 10, size: 15)
    default: AccentPillMetrics(horizontal: 14, vertical: 7, size: 13)
    }
}

public extension ButtonStyle where Self == AccentPillButtonStyle {
    static var accentPill: AccentPillButtonStyle { AccentPillButtonStyle() }
}
