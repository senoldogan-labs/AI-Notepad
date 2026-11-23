import CoreGraphics
import Foundation

/// Where a streak's picture goes in the voice field (`keyboardParticle`'s streaks, drawn as Core Animation layers): an
/// arrow-like sliver from a sharp tail to a pointed head `width` wide whose tip runs 0.6 × `width` past the head, laid
/// along the tail → head line. `center` and `angle` (radians from the x axis) place a `length` × `width` picture drawn
/// tail-left, tip-right.
public struct KeyboardStreakPlacement: Sendable, Hashable {
    public let center: CGPoint
    public let length: CGFloat
    public let angle: CGFloat

    public init(center: CGPoint, length: CGFloat, angle: CGFloat) {
        self.center = center
        self.length = length
        self.angle = angle
    }
}

/// The placement of a streak from `tail` to `head` (points). Pure function.
public func keyboardStreakPlacement(tail: CGPoint, head: CGPoint, width: CGFloat) -> KeyboardStreakPlacement {
    let dx: CGFloat = head.x - tail.x
    let dy: CGFloat = head.y - tail.y
    let distance: CGFloat = max(0.001, (dx * dx + dy * dy).squareRoot())
    let length: CGFloat = distance + width * 0.6
    let center: CGPoint = CGPoint(x: tail.x + dx / distance * length / 2, y: tail.y + dy / distance * length / 2)
    return KeyboardStreakPlacement(center: center, length: length, angle: atan2(dy, dx))
}
