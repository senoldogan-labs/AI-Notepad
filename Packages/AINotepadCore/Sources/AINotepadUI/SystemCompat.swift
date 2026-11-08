import SwiftUI
#if os(macOS)
import AppKit
#endif

// macOS 14 karşılıkları: Mac uygulaması macOS 14.2'den itibaren çalışır (sistem sesi için Core Audio işlem dinleyicisi
// 14.2 ister); macOS 15'in yeni SwiftUI API'leri burada tek yerde koşullanır. macOS 15+ sistemin API'sini olduğu gibi
// kullanır; macOS 14'te aynı işi gören karşılığı çalışır. iPhone'un en düşük sürümü (iOS 18) bunların hepsini taşır.

public extension Color {
    /// Bu rengi `other` ile `fraction` oranında karıştırır (0: bu renk, 1: `other`). macOS 15+ `mix(with:by:)`
    /// (algısal karışım); macOS 14'te AppKit'in sRGB karışımı (`NSColor.blended`), açık/koyu görünüme göre her çizimde
    /// yeniden hesaplanır.
    func mixed(with other: Color, by fraction: Double) -> Color {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            return mix(with: other, by: fraction)
        }
        return Color(nsColor: blendedNSColor(base: NSColor(self), other: NSColor(other), fraction: CGFloat(fraction)))
        #else
        return mix(with: other, by: fraction)
        #endif
    }
}

#if os(macOS)
/// macOS 14 için iki rengin dinamik karışımı: çizildiği görünümde (açık/koyu) iki renk çözülüp sRGB'de karıştırılır.
private func blendedNSColor(base: NSColor, other: NSColor, fraction: CGFloat) -> NSColor {
    NSColor(name: nil) { (_: NSAppearance) -> NSColor in
        guard let start = base.usingColorSpace(.sRGB),
              let end = other.usingColorSpace(.sRGB),
              let blended = start.blended(withFraction: fraction, of: end)
        else {
            preconditionFailure("Renkler sRGB'ye çevrilemedi: \(base) / \(other)")
        }
        return blended
    }
}

/// macOS 14'te el imleci: `pointerStyle(.link)` yok; üstüne gelince `NSCursor.pointingHand` itilir, çıkınca (ya da
/// kapatılınca, görünüm kaybolunca) geri alınır. İtme/geri alma her zaman eşlenir.
private struct LegacyLinkPointer: ViewModifier {
    let isEnabled: Bool
    @State private var isHovering: Bool = false
    @State private var isPushed: Bool = false

    func body(content: Content) -> some View {
        content
            .onHover { (hovering: Bool) -> Void in
                isHovering = hovering
                sync()
            }
            .onChange(of: isEnabled) { (_: Bool, _: Bool) in sync() }
            .onDisappear {
                if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
    }

    private func sync() {
        let wanted: Bool = isHovering && isEnabled
        if wanted, !isPushed {
            NSCursor.pointingHand.push()
            isPushed = true
        } else if !wanted, isPushed {
            NSCursor.pop()
            isPushed = false
        }
    }
}
#endif

public extension View {
    /// Simge değişirken "sihirli" geçiş (ör. daireden onay işaretine çizgiler akar): macOS 15+
    /// `.replace.magic(fallback: .replace)`; macOS 14'te sihirli geçiş yok, sistemin kendi yedeği olan `.replace`.
    @ViewBuilder
    func magicReplaceSymbolTransition() -> some View {
        if #available(macOS 15.0, *) {
            contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
        } else {
            contentTransition(.symbolEffect(.replace))
        }
    }

    /// Mac'te tıklanabilir öğede el imleci (iPhone'da imleç yok, değişmez). macOS 15+ `pointerStyle(.link)`, macOS
    /// 14'te `NSCursor.pointingHand`.
    @ViewBuilder
    func linkPointer(isEnabled: Bool) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            pointerStyle(isEnabled ? .link : nil)
        } else {
            modifier(LegacyLinkPointer(isEnabled: isEnabled))
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
public extension View {
    /// Ana pencerenin zemini (`WindowBackdrop`): macOS 15+ pencerenin kendi zemini (`containerBackground(for: .window)`);
    /// macOS 14'te aynı görünüm içeriğin arkasında, pencerenin tamamını (gizli başlık çubuğu dahil) kaplar.
    @ViewBuilder
    func windowBackdrop() -> some View {
        if #available(macOS 15.0, *) {
            containerBackground(for: .window) { WindowBackdrop() }
        } else {
            background { WindowBackdrop() }
        }
    }
}
#endif

// MARK: Kaydırma

/// Kaydırılan içeriğin alt kenarı görünen alanın altına en çok `threshold` pt uzaklıkta mı (sona yakın mı). Saf
/// fonksiyondur. `contentBottom`: içeriğin alt kenarının görünen alanın üstüne göre konumu.
public func isScrollContentNearBottom(contentBottom: CGFloat, visibleHeight: CGFloat, threshold: CGFloat) -> Bool {
    contentBottom <= visibleHeight + threshold
}

#if os(macOS)
/// macOS 14: kaydırılan içeriğin alt kenarının kaydırma alanına göre konumu.
private struct ScrollContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// macOS 14: kaydırma alanının görünen yüksekliği.
private struct ScrollVisibleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// `scrollBottomProbe` ile `onScrollNearBottom`'un ortak koordinat alanı.
private let scrollBottomSpace: String = "AINotepadUI.scrollBottom"

/// macOS 14: `onScrollGeometryChange` yerine içeriğin ve alanın ölçüsünden "sona yakın mı"yı hesaplar; değer
/// değişince `action`'ı çağırır (macOS 15'teki gibi ilk değer bildirilmez).
private struct LegacyScrollNearBottom: ViewModifier {
    let threshold: CGFloat
    let action: @MainActor (Bool) -> Void
    @State private var contentBottom: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    @State private var isNear: Bool?

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(scrollBottomSpace))
            .background {
                GeometryReader { (proxy: GeometryProxy) in
                    Color.clear.preference(key: ScrollVisibleHeightKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(ScrollContentBottomKey.self) { (value: CGFloat) in
                contentBottom = value
                update()
            }
            .onPreferenceChange(ScrollVisibleHeightKey.self) { (value: CGFloat) in
                visibleHeight = value
                update()
            }
    }

    private func update() {
        let near: Bool = isScrollContentNearBottom(contentBottom: contentBottom, visibleHeight: visibleHeight, threshold: threshold)
        guard let previous = isNear else {
            isNear = near
            return
        }
        if previous != near {
            isNear = near
            action(near)
        }
    }
}

/// macOS 14: `onScrollPhaseChange` yerine kullanıcının kaydırıp kaydırmadığı, bu görünümün penceresine gelen kaydırma
/// tekerleği ve iz dörtgeni olaylarından (parmak ya da ivme sürerken kaydırıyor). Görünüm görünürken izlenir.
private struct LegacyUserScrollMonitor: ViewModifier {
    let action: @MainActor (Bool) -> Void
    @State private var monitor: ScrollWheelMonitor = ScrollWheelMonitor()

    func body(content: Content) -> some View {
        content
            .background(HostWindowReader { (window: NSWindow?) -> Void in monitor.window = window })
            .onAppear { monitor.start(action: action) }
            .onDisappear { monitor.stop() }
    }
}

/// Görünümün içinde durduğu pencereyi bildirir (pencereye girince ve çıkınca).
private struct HostWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view: WindowReportingView = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowReportingView, context: Context) {
        nsView.onWindow = onWindow
    }
}

private final class WindowReportingView: NSView {
    var onWindow: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}

/// Kaydırma tekerleği olaylarını dinleyen yerel izleyicinin kaydı (macOS 14). Yalnız `window`'a gelen olaylar sayılır
/// (başka penceredeki kaydırma bu görünümün izlemesini bozmasın). İz dörtgeni olayı evresini taşır (parmak ya da ivme
/// sürerken kaydırıyor); fare tekerleğinde evre yoktur, son olaydan 0,3 sn sonra kaydırma biter.
@MainActor
private final class ScrollWheelMonitor {
    /// Görünümün penceresi; bilinmezken hiçbir olay sayılmaz.
    weak var window: NSWindow?
    private var token: Any?
    private var isScrolling: Bool = false
    private var wheelIdle: Task<Void, Never>?

    func start(action: @escaping @MainActor (Bool) -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] (event: NSEvent) -> NSEvent? in
            let phase: NSEvent.Phase = event.phase
            let momentum: NSEvent.Phase = event.momentumPhase
            let eventWindow: NSWindow? = event.window
            MainActor.assumeIsolated {
                guard let self, let window = self.window, eventWindow === window else {
                    return
                }
                self.handle(phase: phase, momentum: momentum, action: action)
            }
            return event
        }
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
        wheelIdle?.cancel()
        wheelIdle = nil
        isScrolling = false
    }

    private func handle(phase: NSEvent.Phase, momentum: NSEvent.Phase, action: @escaping @MainActor (Bool) -> Void) {
        wheelIdle?.cancel()
        wheelIdle = nil
        guard phase.isEmpty, momentum.isEmpty else {
            let active: NSEvent.Phase = [.began, .changed, .mayBegin]
            report(scrolling: !phase.intersection(active).isEmpty || !momentum.intersection(active).isEmpty, action: action)
            return
        }
        report(scrolling: true, action: action)
        wheelIdle = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return // Yeni olay geldi; izleme sürüyor.
            }
            self?.report(scrolling: false, action: action)
        }
    }

    private func report(scrolling: Bool, action: @MainActor (Bool) -> Void) {
        guard isScrolling != scrolling else {
            return
        }
        isScrolling = scrolling
        action(scrolling)
    }
}
#endif

public extension View {
    /// Kaydırılan içeriğe (ScrollView'un içindeki yığına) eklenir: macOS 14'te içeriğin alt kenarını
    /// `onScrollNearBottom`'a bildirir. macOS 15+ ve iPhone'da bir şey yapmaz (sistem kaydırma ölçüsünü verir).
    @ViewBuilder
    func scrollBottomProbe() -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            self
        } else {
            background {
                GeometryReader { (proxy: GeometryProxy) in
                    Color.clear.preference(key: ScrollContentBottomKey.self, value: proxy.frame(in: .named(scrollBottomSpace)).maxY)
                }
            }
        }
        #else
        self
        #endif
    }

    /// ScrollView'a eklenir: içeriğin sonu görünen alanın altına en çok `threshold` pt uzaklıktayken true; değer
    /// değişince `action`. macOS 15+ ve iPhone'da `onScrollGeometryChange`; macOS 14'te içerikteki `scrollBottomProbe`
    /// ölçüsüyle aynı hesap.
    @ViewBuilder
    func onScrollNearBottom(threshold: CGFloat, action: @escaping @MainActor (Bool) -> Void) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            nearBottomBySystem(threshold: threshold, action: action)
        } else {
            modifier(LegacyScrollNearBottom(threshold: threshold, action: action))
        }
        #else
        nearBottomBySystem(threshold: threshold, action: action)
        #endif
    }

    /// ScrollView'a eklenir: kullanıcı kaydırırken (parmak, sürükleme ya da ivme) true. macOS 15+ ve iPhone'da
    /// `onScrollPhaseChange`; macOS 14'te kaydırma tekerleği/iz dörtgeni olayları.
    @ViewBuilder
    func onUserScrollingChange(action: @escaping @MainActor (Bool) -> Void) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            userScrollingBySystem(action: action)
        } else {
            modifier(LegacyUserScrollMonitor(action: action))
        }
        #else
        userScrollingBySystem(action: action)
        #endif
    }
}

@available(macOS 15.0, *)
private extension View {
    func nearBottomBySystem(threshold: CGFloat, action: @escaping @MainActor (Bool) -> Void) -> some View {
        onScrollGeometryChange(for: Bool.self) { (geometry: ScrollGeometry) -> Bool in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - threshold
        } action: { (_: Bool, near: Bool) in
            action(near)
        }
    }

    func userScrollingBySystem(action: @escaping @MainActor (Bool) -> Void) -> some View {
        onScrollPhaseChange { (_: ScrollPhase, phase: ScrollPhase) in
            action(phase == .tracking || phase == .interacting || phase == .decelerating)
        }
    }
}
