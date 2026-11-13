import SwiftUI

/// Bir özelliği ya da öbür uygulamayı tanıtan sayfa: üst yarıda durgun pastel film gradyanı ve önünde uygulamanın
/// gerçek bir görüntüsü (ör. Mac penceresi, iPhone), altında ortalı başlık ve tek cümle, iri eylem kutuları ve en altta
/// "Bitti". Görsel kısım her temada açık çizilir (pastel zemin; bkz. `GradientBanner`) ve VoiceOver'da atlanır: anlamı
/// başlık taşır. Büyük yazıda sayfa kayar, "Bitti" altta sabit kalır. iPhone'da ve Mac'te aynı bileşen.
public struct HeroSheet<Artwork: View, Actions: View>: View {
    let palette: FilmPalette
    let seed: String
    let heroHeight: CGFloat
    let title: Text
    let subtitle: Text
    let doneTitle: Text
    let onDone: () -> Void
    let artwork: (CGSize) -> Artwork
    let actions: Actions

    /// - Parameters:
    ///   - heroHeight: Görsel kısmın yüksekliği (çağıran ekrana göre seçer).
    ///   - artwork: Görsel kısmın boyutunu alıp gradyanın önüne çizilecek görüntü (taşan kısmı kırpılır).
    ///   - actions: Başlığın altındaki eylemler (çoğunlukla `HeroTileRow`).
    public init(
        palette: FilmPalette, seed: String, heroHeight: CGFloat, title: Text, subtitle: Text, doneTitle: Text, onDone: @escaping () -> Void,
        @ViewBuilder artwork: @escaping (CGSize) -> Artwork, @ViewBuilder actions: () -> Actions
    ) {
        self.palette = palette
        self.seed = seed
        self.heroHeight = heroHeight
        self.title = title
        self.subtitle = subtitle
        self.doneTitle = doneTitle
        self.onDone = onDone
        self.artwork = artwork
        self.actions = actions()
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                GeometryReader { (geometry: GeometryProxy) in
                    ZStack(alignment: .topLeading) {
                        FilmGradient(seed: seed, palette: palette)
                        artwork(geometry.size)
                    }
                    // Görüntü taşarsa sol üstten yerleşir, sağdan ve alttan kırpılır.
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                }
                .frame(height: heroHeight)
                .environment(\.colorScheme, .light)
                .accessibilityHidden(true)
                VStack(spacing: 10) {
                    title
                        .appTitleFont(size: 28, weight: .semibold)
                        .tracking(-0.5)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .appFont(size: 16, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                actions
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onDone) {
                doneTitle
                    .appFont(size: 16, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.soft, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(HeroTileButtonStyle())
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
        }
        .background(Theme.background)
    }
}

/// Tanıtım sayfasının eylem kutuları yan yana; erişilebilirlik yazı boyutlarında (yazı sığmaz) alt alta. Kutular aynı
/// boyda kalır.
public struct HeroTileRow<Content: View>: View {
    let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        layout { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Eylem kutusunun içi: vurgu renginin soluk dairesinde simge, altında kısa ad ve varsa tek satırlık durum (ör.
/// "Kopyalandı"). Kart yüzeyinde, satırın payını dolduracak genişlikte.
public struct HeroTileLabel: View {
    let systemImage: String
    let title: Text
    let detail: Text?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(systemImage: String, title: Text, detail: Text?) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .appFont(size: 18, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                .frame(width: 46, height: 46)
                .background(appearance.accent.softFill(tintOpacity: 0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                title
                    .appFont(size: 16, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                if let detail {
                    detail
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardSurface(cornerRadius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Tanıtım sayfasındaki dokunulan kutu ve düğmeler: basılınca hafifçe küçülür, Mac'te el imleci; devre dışıyken soluk.
public struct HeroTileButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HeroTileButtonBody(configuration: configuration)
    }
}

private struct HeroTileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled: Bool

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .linkPointer(isEnabled: isEnabled)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Tanıtım görselindeki Mac penceresi: açık pencere zemini, üstte trafik ışıkları, altında uygulamanın gerçek ekran
/// görüntüsü (genişliğe sığar); yuvarlak köşe, ince çerçeve ve yumuşak gölge. Görüntünün zemini pencereninkiyle aynı
/// (`macWindowSurface`) olmalı ki kenar görünmesin.
public struct HeroMacWindow: View {
    let screenshot: Image

    public init(screenshot: Image) {
        self.screenshot = screenshot
    }

    public var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { (hex: UInt32) in
                    Circle()
                        .fill(Color(hex: hex))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            screenshot
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
        .background(Color(hex: macWindowSurface), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.16), radius: 28, y: 14)
    }
}

/// Mac ekran görüntülerinin (açık tema) pencere zemini; `HeroMacWindow` aynı renkte çizilir.
public let macWindowSurface: UInt32 = 0xFDFDFD
