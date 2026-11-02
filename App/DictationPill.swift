import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Hap penceresinin boyutu: içerik altta ortalanır, kalan alan saydamdır (tıklamalar alttaki pencereye geçer).
private let pillWindowSize: NSSize = NSSize(width: 480, height: 150)

/// Hapın ekranın altından (Dock'un üstünden) uzaklığı.
private let pillBottomMargin: CGFloat = 28

/// Sesle yazma hapının penceresi: kenarlıksız, uygulamayı öne getirmeyen ve hiçbir zaman anahtar olmayan panel; yazının
/// gideceği uygulama odağı kaybetmez. Farenin bulunduğu ekranın altında ortalanır; tüm masaüstlerinde ve tam ekran
/// uygulamaların üstünde görünür.
@MainActor
final class DictationPillWindow {
    private let panel: NSPanel

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

    /// Hapı farenin bulunduğu ekranın altında gösterir; tıklanabilir değilse fare olaylarını hiç almaz.
    func show(isClickable: Bool) {
        panel.ignoresMouseEvents = !isClickable
        panel.sharingType = sharingType(hideFromCapture: UserDefaults.standard.bool(forKey: SettingsKey.hideFromScreenCapture))
        let mouse: NSPoint = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first {
            panel.setFrameOrigin(pillOrigin(visibleFrame: screen.visibleFrame, size: pillWindowSize, bottomMargin: pillBottomMargin))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// Hap penceresinin konumu: görünür alanın altında, yatayda ortada. Saf fonksiyondur.
func pillOrigin(visibleFrame: CGRect, size: NSSize, bottomMargin: CGFloat) -> NSPoint {
    NSPoint(x: (visibleFrame.midX - size.width / 2).rounded(), y: visibleFrame.minY + bottomMargin)
}

/// Pencerenin içeriği: hap altta ortada.
private struct DictationPillHost: View {
    let controller: DictationController

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if controller.pill != .hidden {
                DictationPillView(state: controller.pill, levels: controller.levels, onTap: { controller.pillTapped() })
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 16)
        .frame(width: pillWindowSize.width, height: pillWindowSize.height)
    }
}

/// Sakin, beyaz hap: dinlerken vurgu renginde mikrofon ve ses çubukları; yazıya dökerken küçük gösterge; mesajlarda kısa
/// metin (amber yalnız eksik izin ve engellerde, kırmızı yalnız hatada).
private struct DictationPillView: View {
    let state: DictationPillState
    let levels: AudioLevels
    let onTap: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .appFont(size: 13, weight: .medium)
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 40)
        .background(Capsule(style: .continuous).fill(Theme.card))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .frame(maxWidth: 440)
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
            Image(systemName: "mic.fill")
                .foregroundStyle(appearance.accent.color)
            LevelMeter(levels: levels)
            if handsFree, canEscape {
                Text("Dinliyorum · bitirmek için \(shortcut) ya da Esc")
            } else if handsFree {
                Text("Dinliyorum · bitirmek için \(shortcut)")
            } else {
                Text("Dinliyorum · bırakınca yazılır")
            }
        case .preparing(let progress):
            ProgressView().controlSize(.small)
            if let progress {
                Text("Dikte modeli indiriliyor… %\(Int((progress * 100).rounded()))")
            } else {
                Text("Dikte modeli hazırlanıyor…")
            }
        case .transcribing:
            ProgressView().controlSize(.small)
            Text("Yazıya dökülüyor…")
        case .message(let text, let severity, _):
            Image(systemName: severity.symbol)
                .foregroundStyle(severity == .info ? appearance.accent.color : severity.tint)
            Text(text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
