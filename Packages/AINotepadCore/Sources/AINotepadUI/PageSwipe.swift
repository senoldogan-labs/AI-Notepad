import CoreGraphics

/// Bırakılan yatay kaydırmanın sonucu: sonraki sayfa (parmak sola), önceki sayfa (parmak sağa) ya da yerinde kal.
public enum PageSwipeStep: Equatable, Sendable {
    case next
    case previous
    case stay
}

/// Sayfa değiştiren en kısa kaydırma (nokta).
public let pageSwipeDistance: CGFloat = 90
/// Kısa ama hızlı fiske sayfa değiştiren en düşük hız (nokta/saniye).
public let pageSwipeVelocity: CGFloat = 550
/// Fiskenin bile en az bu kadar kayması gerekir (dokunuştaki titreme sayfa değiştirmesin).
public let pageSwipeMinimumFlickDistance: CGFloat = 24

/// Kaydırma yatay sayfa kaydırması olarak başlar mı: yatay hız dikeyin en az 1,6 katı (dikey kaydırma ve çapraz hareket
/// listeyi kaydırır). Saf fonksiyondur.
public func isHorizontalPageSwipe(velocityX: CGFloat, velocityY: CGFloat) -> Bool {
    abs(velocityX) > abs(velocityY) * 1.6
}

/// Bırakılan yatay kaydırmanın sonucu: yeterince uzun ya da yeterince hızlı (en az `pageSwipeMinimumFlickDistance`) ve
/// bırakırken geri dönmüyorsa sayfa değişir. Saf fonksiyondur.
public func pageSwipeStep(translation: CGFloat, velocity: CGFloat) -> PageSwipeStep {
    guard abs(translation) >= pageSwipeMinimumFlickDistance else {
        return .stay
    }
    // Parmak bırakırken geri dönüyorsa vazgeçilmiş sayılır.
    let isReturning: Bool = translation * velocity < 0 && abs(velocity) > 150
    let isFarEnough: Bool = abs(translation) >= pageSwipeDistance
    let isFlick: Bool = translation * velocity > 0 && abs(velocity) >= pageSwipeVelocity
    guard !isReturning, isFarEnough || isFlick else {
        return .stay
    }
    return translation < 0 ? .next : .previous
}
