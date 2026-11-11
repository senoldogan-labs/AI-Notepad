import AINotepadCore
import SwiftUI

/// Our own drawing of a watch (no Apple product imagery): a rounded body in dark Ember ink with a copper crown, bands in
/// the Ember copper tones of the accent, and a small Gistsmith recording face (accent dot, timer, waveform, pause and
/// finish). Static; hidden from VoiceOver (the page's headline carries the meaning).
public struct WatchMockup: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init() {}

    public var body: some View {
        let stops: EmberBandStops = emberBandStops(accent: appearance.accent)
        let accent: Color = Color(hex: emberTinted(hex: 0xE07A4A, accent: appearance.accent))
        VStack(spacing: -10) {
            band(top: stops.e500, bottom: stops.e700, isUpper: true)
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x3A2A21), Color(hex: 0x17110D)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color(hex: stops.e300).opacity(0.45), lineWidth: 1.2))
                    .frame(width: 104, height: 124)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(hex: 0x0B0807))
                    .frame(width: 90, height: 110)
                face(accent: accent, sand: Color(hex: stops.e100))
            }
            .overlay(alignment: .trailing) {
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: stops.e300), Color(hex: stops.e600)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 6, height: 22)
                    .offset(x: 3, y: -18)
            }
            .zIndex(1)
            band(top: stops.e700, bottom: stops.e500, isUpper: false)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 14, y: 8)
        .accessibilityHidden(true)
        .accessibilityIdentifier("decorative")
    }

    private func band(top: UInt32, bottom: UInt32, isUpper: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isUpper ? 14 : 4, bottomLeadingRadius: isUpper ? 4 : 14, bottomTrailingRadius: isUpper ? 4 : 14,
            topTrailingRadius: isUpper ? 14 : 4, style: .continuous
        )
        .fill(LinearGradient(colors: [Color(hex: top), Color(hex: bottom)], startPoint: .top, endPoint: .bottom))
        .frame(width: 70, height: 46)
    }

    /// The recording face: accent dot and timer, a waveform, pause and finish.
    private func face(accent: Color, sand: Color) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(verbatim: "07:26")
                    .appFont(size: 17, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(sand)
            }
            HStack(alignment: .center, spacing: 2.5) {
                let heights: [Double] = [5, 9, 14, 8, 17, 11, 6, 13, 9, 5]
                ForEach(heights.indices, id: \.self) { (index: Int) in
                    Capsule().fill(accent.opacity(index.isMultiple(of: 3) ? 0.6 : 1)).frame(width: 3, height: heights[index])
                }
            }
            .frame(height: 18)
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 24, height: 24)
                    .overlay {
                        HStack(spacing: 3) {
                            Capsule().fill(sand).frame(width: 2.5, height: 9)
                            Capsule().fill(sand).frame(width: 2.5, height: 9)
                        }
                    }
                Circle()
                    .fill(accent)
                    .frame(width: 24, height: 24)
                    .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.white).frame(width: 8, height: 8) }
            }
        }
    }
}

/// The Settings › Apple Watch page's content for a state: the watch mockup on an Ember disc, a headline and one line,
/// then a card that says what to do next (pair, install, update) or what the Watch app does. Plain views: the iPhone
/// screen wraps them in its scroll view.
public struct WatchSetupPanel: View {
    let state: WatchSetupState

    public init(state: WatchSetupState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                ZStack {
                    EmberBand(contourSeed: "apple-watch", contourCount: 0)
                        .clipShape(Circle())
                        .frame(width: 176, height: 176)
                    WatchMockup()
                        .scaleEffect(0.86)
                }
                .frame(height: 196)
                VStack(spacing: 6) {
                    headline
                        .appFont(size: 20, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            card
            if state != .needsNewerSystem(requiredMajorVersion: watchAppMinimumPhoneSystemMajorVersion) && state != .unsupported {
                Text("Apple Watch uygulaması watchOS 26 ve iOS \(watchAppMinimumPhoneSystemMajorVersion) ya da sonrasını ister.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var headline: Text {
        switch state {
        case .unsupported: Text("Apple Watch kullanılamıyor")
        case .needsNewerSystem(let version): Text("iOS \(version) gerekiyor")
        case .checking: Text("Apple Watch aranıyor…")
        case .noWatchPaired: Text("Apple Watch bulunamadı")
        case .appNotInstalled: Text("Gistsmith saatinde yok")
        case .ready: Text("Gistsmith saatinde hazır")
        }
    }

    private var subtitle: Text {
        switch state {
        case .unsupported: Text("Bu cihaz bir Apple Watch'a bağlanamıyor.")
        case .needsNewerSystem: Text("Önce bu iPhone'u güncelle.")
        case .checking: Text("Eşleşmiş saat denetleniyor.")
        case .noWatchPaired: Text("Devam etmek için bir saat eşleştir.")
        case .appNotInstalled: Text("Saatine birkaç adımda kur.")
        case .ready: Text("Toplantını bileğinden yönet.")
        }
    }

    @ViewBuilder private var card: some View {
        switch state {
        case .unsupported, .checking:
            EmptyView()
        case .needsNewerSystem(let version):
            WatchSetupCard {
                Text("Gistsmith'in Apple Watch uygulaması iOS \(version) ya da sonrası olan bir iPhone ister. iPhone Ayarları › Genel › Yazılım Güncelleme'den güncelle.")
                    .multilineTextAlignment(.center)
            }
        case .noWatchPaired:
            WatchSetupCard {
                Text("Gistsmith'i bileğinden kullanmak için bu iPhone'la bir Apple Watch eşleştir.")
                    .multilineTextAlignment(.center)
            }
        case .appNotInstalled:
            WatchSetupCard {
                VStack(alignment: .leading, spacing: 14) {
                    WatchSetupStep(number: 1, text: Text("iPhone'da Watch uygulamasını aç."))
                    WatchSetupStep(number: 2, text: Text("Saatim sekmesinde Kullanılabilir Uygulamalar'a in."))
                    WatchSetupStep(number: 3, text: Text("Gistsmith'in yanındaki Yükle'ye dokun."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ready:
            WatchSetupCard {
                VStack(alignment: .leading, spacing: 14) {
                    WatchSetupFeature(icon: "pause.circle", text: Text("iPhone'daki kaydı duraklat, sürdür ya da bitir."))
                    WatchSetupFeature(icon: "calendar", text: Text("Bugünün toplantılarını gör."))
                    WatchSetupFeature(icon: "checkmark.circle", text: Text("Görevlerini gör ve tamamla."))
                    WatchSetupFeature(icon: "applewatch.watchface", text: Text("Kadrana Gistsmith komplikasyonunu ekle."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The page's rounded info card.
private struct WatchSetupCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .appFont(size: 16, weight: .regular)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// A numbered install step in the accent colour.
private struct WatchSetupStep: View {
    let number: Int
    let text: Text
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                .frame(width: 24, height: 24)
                .background(appearance.accent.color.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            text
        }
    }
}

/// What the Watch app does: an accent icon and one line.
private struct WatchSetupFeature: View {
    let icon: String
    let text: Text
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(appearance.accent.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            text
        }
    }
}
