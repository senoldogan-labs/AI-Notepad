import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Hap penceresinin boyutu: içerik altta ortalanır, kalan alan saydamdır (tıklamalar alttaki pencereye geçer).
private let pillWindowSize: NSSize = NSSize(width: 520, height: 150)

/// Hapın ekranın altından (Dock'un üstünden) uzaklığı.
private let pillBottomMargin: CGFloat = 28

/// Hap gizlenirken pencerenin kapanmadan önce beklediği süre: kapanış yayı (ölçek + saydamlık) görünsün.
private let pillHideDelay: Duration = .milliseconds(260)

/// Hapın görünme ve durum geçişi yayı (hafif sekme; durum seyrek değişir, sürekli animasyon yok).
private let pillSpring: Animation = .spring(duration: 0.34, bounce: 0.28)

/// Sesle yazma hapının penceresi: kenarlıksız, uygulamayı öne getirmeyen ve hiçbir zaman anahtar olmayan panel; yazının
/// gideceği uygulama odağı kaybetmez. Farenin bulunduğu ekranın altında ortalanır; tüm masaüstlerinde ve tam ekran
/// uygulamaların üstünde görünür.
@MainActor
final class DictationPillWindow {
    private let panel: NSPanel
    /// Gizlenirken kapanış yayı bitince pencereyi kapatır; yeniden gösterilirse iptal edilir.
    private var pendingHide: Task<Void, Never>?

    init(controller: DictationController) {
        let panel: NSPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: pillWindowSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Gölgeyi SwiftUI çizer (pencere gölgesi saydam alanın çevresine düşerdi).
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = sharingType(hideFromCapture: UserDefaults.standard.bool(forKey: SettingsKey.hideFromScreenCapture))
        panel.contentView = NSHostingView(rootView: DictationPillHost(controller: controller).modifier(AppearanceEnvironment()))
        self.panel = panel
    }

    /// Hapı farenin bulunduğu ekranın altında gösterir; tıklanabilir değilse fare olaylarını hiç almaz. Pencere zaten
    /// görünürse yerinde kalır (durum değişiminde hap ekran değiştirip sıçramaz).
    func show(isClickable: Bool) {
        pendingHide?.cancel()
        pendingHide = nil
        panel.ignoresMouseEvents = !isClickable
        panel.sharingType = sharingType(hideFromCapture: UserDefaults.standard.bool(forKey: SettingsKey.hideFromScreenCapture))
        guard !panel.isVisible else {
            return
        }
        let mouse: NSPoint = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first {
            panel.setFrameOrigin(pillOrigin(visibleFrame: screen.visibleFrame, size: pillWindowSize, bottomMargin: pillBottomMargin))
        }
        panel.orderFrontRegardless()
    }

    /// Hap içerikten kalkar (kapanış yayı), kısa süre sonra pencere kapanır: gizliyken hiçbir şey çizilmez.
    func hide() {
        panel.ignoresMouseEvents = true
        pendingHide?.cancel()
        pendingHide = Task { [weak self] in
            do {
                try await Task.sleep(for: pillHideDelay)
            } catch {
                return
            }
            self?.panel.orderOut(nil)
        }
    }
}

/// Hap penceresinin konumu: görünür alanın altında, yatayda ortada. Saf fonksiyondur.
func pillOrigin(visibleFrame: CGRect, size: NSSize, bottomMargin: CGFloat) -> NSPoint {
    NSPoint(x: (visibleFrame.midX - size.width / 2).rounded(), y: visibleFrame.minY + bottomMargin)
}

/// Pencerenin içeriği: hap altta ortada; alttan yaylanarak belirir, küçülüp solarak kalkar.
private struct DictationPillHost: View {
    let controller: DictationController

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if controller.pill != .hidden {
                // Seviyeler yalnız dinlerken okunur: başka durumda saniyede 10 kez yeniden çizim yok.
                let levels: [Float] = { if case .listening = controller.pill { controller.levels.values } else { [] } }()
                DictationPillView(state: controller.pill, partialText: controller.partialText, levels: levels, onTap: { controller.pillTapped() })
                    .transition(.scale(scale: 0.86, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 6)))
            }
        }
        .animation(pillSpring, value: controller.pill)
        .padding(.bottom, 16)
        .frame(width: pillWindowSize.width, height: pillWindowSize.height)
    }
}

/// Sesle yazma hapı: küçük, beyaz (koyu temada koyu) kapsül. Dinlerken vurgu renginde mikrofon rozeti ve mikrofonun
/// gerçek seviyesiyle oynayan dalga, konuştukça yazılan metnin son kısmı (tek satır); eller serbestte bitirme tuşları.
/// Yazıya dökerken ve model hazırlanırken küçük gösterge; mesajlarda kısa metin (amber yalnız eksik izin ve engellerde,
/// kırmızı yalnız hatada). Bulanıklık ya da sürekli animasyon yok: dalga yalnız seviye geldikçe (100 ms) yeniden çizilir.
struct DictationPillView: View {
    let state: DictationPillState
    /// Dinlerken yazıya dökülen metin; boşsa ipucu gösterilir.
    let partialText: String
    /// Soldan sağa son seviyeler (0...1); dinlemiyorken boş.
    let levels: [Float]
    let onTap: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .appFont(size: 13, weight: .medium)
        .foregroundStyle(Theme.ink)
        .padding(.leading, 7)
        .padding(.trailing, 16)
        .padding(.vertical, 7)
        .frame(minHeight: 42)
        // Gölge yalnızca sabit zemine: içerik (dalga, metin) değiştikçe yeniden hesaplanmaz.
        .background {
            Capsule(style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        }
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.line))
        .frame(maxWidth: 480)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .listening(let handsFree, let canEscape, let shortcut):
            PillBadge(systemImage: "mic.fill", isActive: true)
            DictationWaveform(levels: levels, barCount: 18, maxHeight: 20)
            if !partialText.isEmpty {
                partial
            } else if handsFree {
                Text("Dinliyorum")
            } else {
                Text("Dinliyorum · bırakınca yazılır")
            }
            // Eller serbestte bitirme tuşları her zaman görünür.
            if handsFree {
                HStack(spacing: 4) {
                    KeyCaps(caps: [shortcut], size: .small, isLit: false)
                    if canEscape {
                        KeyCaps(caps: ["esc"], size: .small, isLit: false)
                    }
                }
                .accessibilityLabel(canEscape ? Text("Bitirmek için \(shortcut) ya da Esc") : Text("Bitirmek için \(shortcut)"))
            }
        case .preparing(let progress):
            PillBadge(systemImage: "arrow.down", isActive: false)
            VStack(alignment: .leading, spacing: 4) {
                if let progress {
                    Text("Dikte modeli indiriliyor… %\(Int((progress * 100).rounded()))")
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .frame(width: 160)
                } else {
                    Text("Dikte modeli hazırlanıyor…")
                }
            }
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
            if partialText.isEmpty {
                Text("Yazıya dökülüyor…")
            } else {
                partial
            }
        case .message(let text, let severity, _):
            Image(systemName: severity.symbol)
                .appFont(size: 15, weight: .semibold)
                .foregroundStyle(severity == .info ? appearance.accent.color : severity.tint)
                .frame(width: 28, height: 28)
            Text(text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Yazılan metnin sonu: tek satır, sığmazsa baştan kısaltılır (son söylenen görünür).
    private var partial: some View {
        Text(verbatim: partialText)
            .lineLimit(1)
            .truncationMode(.head)
    }
}

/// Hapın solundaki yuvarlak rozet: dinlerken vurgu renginde dolu, beklerken soluk.
private struct PillBadge: View {
    let systemImage: String
    let isActive: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Image(systemName: systemImage)
            .appFont(size: 12, weight: .bold)
            .foregroundStyle(isActive ? appearance.accent.onColor : appearance.accent.color)
            .frame(width: 28, height: 28)
            .background(Circle().fill(isActive ? appearance.accent.color : appearance.accent.softFill(tintOpacity: 0.14)))
    }
}

/// Mikrofon seviyesinin dalgası: ortadan aşağı ve yukarı büyüyen yuvarlak çubuklar, eskiler (solda) soluk. Tek `Canvas`:
/// seviye 100 ms'de bir değişince bir kez çizilir; animasyon yok. Sessizlikte ince noktalar kalır.
struct DictationWaveform: View {
    /// Soldan sağa seviyeler (0...1); az ya da boşsa soldan sessizlikle dolar.
    let levels: [Float]
    let barCount: Int
    let maxHeight: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2

    var body: some View {
        let values: [Float] = waveformBars(levels: levels, count: barCount)
        let color: Color = appearance.accent.color
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            let midY: CGFloat = size.height / 2
            for (index, value) in values.enumerated() {
                let height: CGFloat = max(barWidth, CGFloat(value) * maxHeight)
                let x: CGFloat = CGFloat(index) * (barWidth + spacing)
                let rect: CGRect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                // Eski çubuklar soluk: dalga sağdan akıyor gibi okunur.
                let age: Double = Double(index + 1) / Double(values.count)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(0.3 + 0.7 * age)))
            }
        }
        .frame(width: CGFloat(barCount) * (barWidth + spacing) - spacing, height: maxHeight)
        .accessibilityHidden(true)
    }
}

/// Dalganın çubukları: son `count` seviye, eksikse soldan sıfırla dolar; seviyeler kök alınarak yükseltilir (konuşma
/// sesi 0,1–0,4 arasında kalır, çubuklar yine görünür oynasın) ve 0...1'e sıkıştırılır. Saf fonksiyondur.
func waveformBars(levels: [Float], count: Int) -> [Float] {
    let recent: [Float] = Array(levels.suffix(count))
    let padded: [Float] = [Float](repeating: 0, count: max(0, count - recent.count)) + recent
    return padded.map { (level: Float) -> Float in min(1, max(0, level)).squareRoot() }
}

/// Tuş kapağı boyutu.
enum KeyCapSize {
    case small
    case regular
    case large

    var fontSize: CGFloat {
        switch self {
        case .small: 11
        case .regular: 13
        case .large: 22
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .small: 20
        case .regular: 26
        case .large: 52
        }
    }

    var height: CGFloat {
        switch self {
        case .small: 20
        case .regular: 26
        case .large: 52
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .small: 5
        case .regular: 6
        case .large: 11
        }
    }
}

/// Kısayolun tuş kapakları (⌃ ⌥ D): kart renginde, alt kenarı kalın ince çerçeveli küçük tuşlar. `isLit` iken (tuş
/// basılı) vurgu renginde dolar ve hafifçe çöker.
struct KeyCaps: View {
    let caps: [String]
    let size: KeyCapSize
    let isLit: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private var depth: CGFloat { size == .large ? 3 : 1.5 }

    var body: some View {
        HStack(spacing: size == .large ? 8 : 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                let shape: RoundedRectangle = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                Text(verbatim: item.element)
                    .appFont(size: size.fontSize, weight: .medium)
                    .foregroundStyle(isLit ? appearance.accent.onColor : Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, size == .large ? 14 : 6)
                    .frame(minWidth: size.minWidth, minHeight: size.height)
                    .background {
                        shape.fill(isLit ? appearance.accent.color : Theme.card)
                    }
                    .overlay {
                        shape.strokeBorder(isLit ? appearance.accent.color : Theme.line)
                    }
                    // Tuşun tabanı altından görünür (kalkık tuş); basılınca tuş tabanına iner.
                    .background {
                        shape.fill(Theme.line).offset(y: isLit ? 0 : depth)
                    }
                    .offset(y: isLit ? depth : 0)
            }
        }
        .animation(.spring(duration: 0.18, bounce: 0.2), value: isLit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: caps.joined()))
    }
}
