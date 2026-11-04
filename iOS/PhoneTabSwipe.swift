import AINotepadUI
import SwiftUI
import UIKit

/// Sekme çubuğundaki sıradaki sekme; sonuncudaysa nil. Saf fonksiyondur.
func phoneTab(after tab: PhoneTab) -> PhoneTab? {
    let tabs: [PhoneTab] = PhoneTab.allCases
    guard let index = tabs.firstIndex(of: tab), tabs.indices.contains(index + 1) else {
        return nil
    }
    return tabs[index + 1]
}

/// Sekme çubuğundaki önceki sekme; ilkindeyse nil. Saf fonksiyondur.
func phoneTab(before tab: PhoneTab) -> PhoneTab? {
    let tabs: [PhoneTab] = PhoneTab.allCases
    guard let index = tabs.firstIndex(of: tab), tabs.indices.contains(index - 1) else {
        return nil
    }
    return tabs[index - 1]
}

/// Kaydırmayla açılan sekme: kimlik her kaydırmada artar (giriş canlandırması bir kez oynar); `fromTrailing` sekme
/// sağdan mı (sonraki sekme) soldan mı (önceki) girer.
struct PhoneTabSwipeEntry: Equatable {
    let id: Int
    let tab: PhoneTab
    let fromTrailing: Bool
}

/// Sekmenin kök ekranında yatay kaydırma: parmak sola sonraki, sağa önceki sekmeye geçer (sekme çubuğu sırası). Yalnız
/// belirgin yatay hareket başlatır (dikey kaydırma, çapraz hareket listeyi kaydırır); bırakınca yeterince uzun ya da hızlı
/// değilse ekran yerine döner. Yatay kayan çip şeridi, metin alanları, anahtarlar ve liste satırı kaydırma eylemleri
/// kendi hareketlerini korur; üstüne sayfa açılmışsa (geri kaydırması onundur) çalışmaz. Hareketi azalt açıkken ekran
/// parmakla kaymaz, sekme yerinde belirir.
struct PhoneTabSwipeGesture: ViewModifier {
    let router: PhoneRouter
    /// Kapalıyken (ör. Seç modu, kayıt) yatay kaydırma sekme değiştirmez.
    let isEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    func body(content: Content) -> some View {
        content.gesture(TabSwipeRecognizer(isEnabled: isEnabled) { (translation: CGFloat) -> Void in
            follow(translation: translation)
        } onEnd: { (translation: CGFloat, velocity: CGFloat) -> Void in
            finish(step: pageSwipeStep(translation: translation, velocity: velocity))
        } onCancel: {
            settle()
        })
    }

    /// Ekran parmağı yarı hızla izler; o yönde sekme yoksa direnerek az kayar.
    private func follow(translation: CGFloat) {
        guard !reduceMotion else {
            return
        }
        let neighbor: PhoneTab? = translation < 0 ? phoneTab(after: router.tab) : phoneTab(before: router.tab)
        router.tabSwipeDrag = translation * (neighbor == nil ? 0.12 : 0.4)
    }

    private func finish(step: PageSwipeStep) {
        let target: PhoneTab?
        switch step {
        case .next: target = phoneTab(after: router.tab)
        case .previous: target = phoneTab(before: router.tab)
        case .stay: target = nil
        }
        guard let target else {
            settle()
            return
        }
        // Sekme ve giriş aynı güncellemede, canlandırmasız: açılan sekme giriş canlandırmasıyla gelir.
        var transaction: Transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.tabSwipeEntry = PhoneTabSwipeEntry(id: (router.tabSwipeEntry?.id ?? 0) + 1, tab: target, fromTrailing: step == .next)
            router.tabSwipeDrag = 0
            router.tab = target
        }
    }

    /// Bırakılan ya da kesilen kaydırmada ekran yerine döner.
    private func settle() {
        guard router.tabSwipeDrag != 0 else {
            return
        }
        withAnimation(.snappy(duration: 0.28)) {
            router.tabSwipeDrag = 0
        }
    }
}

/// Sekme içeriğinin kaydırma görünümü: seçili sekme parmakla kayar (biraz soluklaşarak); kaydırmayla açılan sekme
/// geldiği yandan genişliğinin beşte biri kadar kayıp belirerek yerine oturur. Hareketi azalt açıkken yalnız belirir.
/// Arkadaki zemin yerinde kalır (kayan ekranın açtığı kenar boşluğu zemin renginde).
struct PhoneTabSwipeTransition: ViewModifier {
    let tab: PhoneTab
    let router: PhoneRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    /// Bu sekmede oynatılan son girişin kimliği; değişince giriş canlandırması oynar.
    @State private var playedEntryID: Int = 0

    func body(content: Content) -> some View {
        let drag: CGFloat = router.tab == tab ? router.tabSwipeDrag : 0
        // Genişliğin oranı: sonraki sekme sağdan (+), önceki soldan (-) girer.
        let startShift: CGFloat = reduceMotion ? 0 : ((router.tabSwipeEntry?.fromTrailing ?? true) ? 0.2 : -0.2)
        content
            .offset(x: drag)
            .opacity(1 - min(abs(drag) / 500, 0.2))
            // Yer tutucunun türü (`PlaceholderContentView<…>`) yazılamayacak kadar iç içe: çıkarıma bırakıldı.
            .keyframeAnimator(initialValue: TabEntryFrame(shift: 0, opacity: 1), trigger: playedEntryID) { (view, frame: TabEntryFrame) in
                view
                    .visualEffect { (effect: EmptyVisualEffect, proxy: GeometryProxy) in
                        effect.offset(x: frame.shift * proxy.size.width)
                    }
                    .opacity(frame.opacity)
            } keyframes: { (_: TabEntryFrame) in
                KeyframeTrack(\TabEntryFrame.shift) {
                    MoveKeyframe(startShift)
                    SpringKeyframe(0, duration: 0.4, spring: .smooth)
                }
                KeyframeTrack(\TabEntryFrame.opacity) {
                    MoveKeyframe(0)
                    CubicKeyframe(1, duration: reduceMotion ? 0.2 : 0.28)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            // Sekme ilk kez kaydırmayla açıldıysa da (görünürken oluşur) giriş oynar.
            .onChange(of: router.tabSwipeEntry, initial: true) { (_: PhoneTabSwipeEntry?, entry: PhoneTabSwipeEntry?) in
                if let entry, entry.tab == tab, entry.id != playedEntryID {
                    playedEntryID = entry.id
                }
            }
    }
}

/// Giriş canlandırmasının bir karesi: genişliğe oranla yatay kayma ve görünürlük.
struct TabEntryFrame {
    var shift: CGFloat
    var opacity: Double
}

/// Kök ekrana eklenen UIKit kaydırma tanıyıcısı: SwiftUI'nin sürükleme hareketi dikey kaydırmayla, yatay çip şeridiyle
/// ve liste satırı kaydırmalarıyla yarışıyordu; UIKit'te hangi dokunuşta başlayacağı ve kimi bekleyeceği seçilebilir.
private struct TabSwipeRecognizer: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChange: @MainActor (CGFloat) -> Void
    let onEnd: @MainActor (CGFloat, CGFloat) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> TabSwipeRecognizerDelegate {
        TabSwipeRecognizerDelegate()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer: UIPanGestureRecognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation: CGFloat = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChange(translation)
        case .ended:
            onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed, .possible:
            onCancel()
        @unknown default:
            onCancel()
        }
    }
}

/// Tanıyıcının UIKit temsilcisi: hangi dokunuşta ve ne zaman başlayacağına karar verir.
private final class TabSwipeRecognizerDelegate: NSObject, UIGestureRecognizerDelegate {
    /// Yalnız belirgin yatay hareket ve kök ekran (üstüne sayfa açılmamış) başlatır.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else {
            return false
        }
        let velocity: CGPoint = pan.velocity(in: view)
        return isHorizontalPageSwipe(velocityX: velocity.x, velocityY: velocity.y) && isNavigationRoot(view: view)
    }

    /// Kendi yatay hareketi olan yerde başlayan dokunuş alınmaz: yatay kayan şerit, metin alanı ve seçimi, denetimler.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else {
            return true
        }
        return !hasOwnHorizontalInteraction(view: view)
    }

    /// Dikey kaydırma birlikte sürer (yatay kaydırma başlarken liste yerinde kalır, ama dikey hareket kesilmez).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let scrollView = otherGestureRecognizer.view as? UIScrollView else {
            return false
        }
        return scrollView.panGestureRecognizer === otherGestureRecognizer
    }

    /// Liste satırının kaydırma eylemleri (sola kaydırıp sil…) önce: satırda eylem yoksa onların tanıyıcısı hemen düşer.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard otherGestureRecognizer is UIPanGestureRecognizer,
              let list = otherGestureRecognizer.view as? UIScrollView, list is UICollectionView || list is UITableView else {
            return false
        }
        return list.panGestureRecognizer !== otherGestureRecognizer
    }

    /// Dokunulan görünüm ya da üstlerinden biri kendi yatay hareketini taşıyor: yatay kayan kaydırma görünümü, metin
    /// girişi (alan, düzenleyici, seçim) ya da denetim (anahtar, kaydırıcı).
    private func hasOwnHorizontalInteraction(view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current, !(candidate is UIWindow) {
            if let scrollView = candidate as? UIScrollView, scrollView.contentSize.width > scrollView.bounds.width + 1 {
                return true
            }
            if candidate is UIControl || candidate is UITextInput {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    /// Görünüm gezinme yığınının kökünde: yığında tek sayfa var (üstüne açılan sayfanın geri kaydırması bozulmasın).
    /// Gezinme yığınında değilse kök sayılır.
    private func isNavigationRoot(view: UIView) -> Bool {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController {
                return navigation.viewControllers.count <= 1
            }
            responder = current.next
        }
        return true
    }
}

extension View {
    /// Sekmenin kök ekranında yatay kaydırmayla komşu sekmeye geçiş (bkz. `PhoneTabSwipeGesture`).
    func phoneTabSwipe(router: PhoneRouter, isEnabled: Bool) -> some View {
        modifier(PhoneTabSwipeGesture(router: router, isEnabled: isEnabled))
    }
}
