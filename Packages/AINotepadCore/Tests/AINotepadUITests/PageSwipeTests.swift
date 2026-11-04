import CoreGraphics
import Testing
@testable import AINotepadUI

@Suite struct PageSwipeTests {
    @Test func longSwipeChangesPage() {
        #expect(pageSwipeStep(translation: -120, velocity: -80) == .next)
        #expect(pageSwipeStep(translation: 120, velocity: 80) == .previous)
    }

    @Test func shortFastFlickChangesPage() {
        #expect(pageSwipeStep(translation: -40, velocity: -900) == .next)
        #expect(pageSwipeStep(translation: 40, velocity: 900) == .previous)
    }

    @Test func shortSlowDragStays() {
        #expect(pageSwipeStep(translation: -60, velocity: -100) == .stay)
    }

    @Test func tinyJitterStaysEvenWhenFast() {
        #expect(pageSwipeStep(translation: -10, velocity: -1500) == .stay)
    }

    @Test func returningFingerCancels() {
        #expect(pageSwipeStep(translation: -150, velocity: 400) == .stay)
    }

    @Test func onlyMostlyHorizontalMovementStarts() {
        #expect(isHorizontalPageSwipe(velocityX: 400, velocityY: 100))
        #expect(!isHorizontalPageSwipe(velocityX: 300, velocityY: 250))
        #expect(!isHorizontalPageSwipe(velocityX: 0, velocityY: 0))
    }
}
