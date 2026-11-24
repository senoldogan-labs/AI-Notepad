import CoreGraphics
import Foundation
import Testing

@testable import KeyboardCore

@Suite struct KeyboardAdaptiveTouchTests {
    private let layoutID: String = keyboardTouchLayoutID(language: .turkish, layout: .qwerty, isLandscape: false)
    private let options: KeyboardLayoutOptions = KeyboardLayoutOptions(
        showsGlobe: true, showsMicrophone: true, showsLanguage: false, field: .text, microphoneSide: .left
    )

    private func turkishFrames() -> [KeyboardKeyFrame] {
        let metrics: KeyboardMetrics = keyboardMetrics(width: 402, height: 216, rows: 4, style: keyboardPortraitKeyStyle)
        return keyboardKeyFrames(rows: keyboardRows(language: .turkish, page: .letters, options: options), metrics: metrics)
    }

    private func frame(_ letter: String, in frames: [KeyboardKeyFrame]) -> KeyboardKeyFrame {
        frames.first { $0.key.kind == .character(letter) }!
    }

    private func sample(_ key: String, dx: Double, dy: Double) -> KeyboardTouchSample {
        KeyboardTouchSample(layoutID: layoutID, key: key, dx: dx, dy: dy)
    }

    /// A model that is active and has `count` samples of `key` at the offset.
    private func learned(_ key: String, dx: Double, dy: Double, count: Int, others: Int) -> KeyboardTouchModel {
        var model: KeyboardTouchModel = .empty
        for _ in 0 ..< count {
            model = keyboardTouchLearning(model: model, sample: sample(key, dx: dx, dy: dy))
        }
        for index in 0 ..< others {
            model = keyboardTouchLearning(model: model, sample: sample("z", dx: 0, dy: Double(index % 2) * 0.01))
        }
        return model
    }

    @Test func firstSamplesAverageAndCountsGrow() {
        var model: KeyboardTouchModel = .empty
        for dx in [0.1, 0.2, 0.3] {
            model = keyboardTouchLearning(model: model, sample: sample("a", dx: dx, dy: 0.05))
        }
        let stat: KeyboardTouchStat? = model.stats[layoutID + "/a"]
        #expect(stat?.count == 3)
        #expect(abs((stat?.dx ?? 0) - 0.2) < 0.001)
        #expect(abs((stat?.dy ?? 0) - 0.05) < 0.001)
        #expect(model.totalSamples == 3)
    }

    @Test func offsetsAreClampedToAFractionOfTheKey() {
        var model: KeyboardTouchModel = .empty
        for _ in 0 ..< 20 {
            model = keyboardTouchLearning(model: model, sample: sample("a", dx: 0.9, dy: -0.9))
        }
        let stat: KeyboardTouchStat? = model.stats[layoutID + "/a"]
        #expect(stat?.dx == keyboardTouchMaximumShiftX)
        #expect(stat?.dy == -keyboardTouchMaximumShiftY)
    }

    @Test func oldTapsFadeBecauseTheWeightStopsShrinking() {
        let steady: KeyboardTouchModel = learned("a", dx: 0.2, dy: 0, count: keyboardTouchDecayWindow, others: 0)
        #expect(steady.stats[layoutID + "/a"]?.count == keyboardTouchDecayWindow)
        var model: KeyboardTouchModel = steady
        for _ in 0 ..< keyboardTouchDecayWindow {
            model = keyboardTouchLearning(model: model, sample: sample("a", dx: -0.1, dy: 0))
        }
        // After one window of new taps the mean has moved most of the way (1 - 1/e = 63 %) to the new habit.
        let dx: Double = model.stats[layoutID + "/a"]?.dx ?? 0
        #expect(dx < 0.2 - 0.3 * 0.6)
        #expect(model.stats[layoutID + "/a"]?.count == keyboardTouchDecayWindow)
    }

    @Test func valuesAreRoundedAndTheModelStaysSmall() throws {
        var model: KeyboardTouchModel = .empty
        for index in 0 ..< 600 {
            let key: String = "k\(index % 400)"
            model = keyboardTouchLearning(model: model, sample: KeyboardTouchSample(layoutID: "l\(index % 7)", key: key, dx: 0.123456, dy: 0.0654321))
        }
        #expect(model.stats.count <= keyboardTouchKeyLimit)
        let stat: KeyboardTouchStat? = model.stats.values.first
        #expect(stat?.dx == 0.123)
        let data: Data = try JSONEncoder().encode(model)
        #expect(data.count < 24_000)
        #expect(try JSONDecoder().decode(KeyboardTouchModel.self, from: data) == model)
    }

    @Test func targetsNeedActivationAndMinimumSamplesPerKey() {
        let frames: [KeyboardKeyFrame] = turkishFrames()
        let few: KeyboardTouchModel = learned("a", dx: 0.2, dy: 0, count: 20, others: 0)
        #expect(!few.isActive)
        #expect(keyboardTouchTargets(frames: frames, model: few, layoutID: layoutID) == nil)
        let enough: KeyboardTouchModel = learned("a", dx: 0.2, dy: 0, count: keyboardTouchMinimumKeySamples, others: keyboardTouchActivationSamples)
        let targets: [CGPoint?]? = keyboardTouchTargets(frames: frames, model: enough, layoutID: layoutID)
        let aIndex: Int = frames.firstIndex { $0.key.kind == .character("a") }!
        let a: CGRect = frames[aIndex].frame
        #expect(abs((targets?[aIndex]?.x ?? 0) - (a.midX + 0.2 * a.width)) < 0.01)
        // "e" has no samples of its own: nil, so it keeps its drawn centre.
        let eIndex: Int = frames.firstIndex { $0.key.kind == .character("e") }!
        #expect(targets?[eIndex] == nil)
        // Fewer samples than the minimum: not used.
        let thin: KeyboardTouchModel = learned("a", dx: 0.2, dy: 0, count: keyboardTouchMinimumKeySamples - 1, others: keyboardTouchActivationSamples)
        let thinTargets: [CGPoint?]? = keyboardTouchTargets(frames: frames, model: thin, layoutID: layoutID)
        #expect(thinTargets?[aIndex] == nil)
        // Another layout's samples do not apply.
        let other: String = keyboardTouchLayoutID(language: .english, layout: .qwerty, isLandscape: false)
        #expect(keyboardTouchTargets(frames: frames, model: enough, layoutID: other) == nil)
    }

    /// A touch at the right edge of "a" goes to "s" once the finger is known to land far left of where it aims at "s"; the
    /// same point stays "a" without learning.
    @Test func learnedShiftMovesAnEdgeTouchToTheNeighbour() {
        let frames: [KeyboardKeyFrame] = turkishFrames()
        let a: KeyboardKeyFrame = frame("a", in: frames)
        let model: KeyboardTouchModel = learned("s", dx: -0.35, dy: 0, count: 30, others: keyboardTouchActivationSamples)
        let targets: [CGPoint?]? = keyboardTouchTargets(frames: frames, model: model, layoutID: layoutID)
        let edge: CGPoint = CGPoint(x: a.frame.maxX, y: a.frame.midY)
        #expect(keyboardKeyFrame(at: edge, frames: frames)?.key.kind == .character("a"))
        #expect(keyboardAdaptiveKeyFrame(at: edge, frames: frames, targets: targets)?.key.kind == .character("s"))
        // The middle of "a" stays "a".
        let middle: CGPoint = CGPoint(x: a.frame.midX + 2, y: a.frame.midY)
        #expect(keyboardAdaptiveKeyFrame(at: middle, frames: frames, targets: targets)?.key.kind == .character("a"))
    }

    /// A touch in the central 60 % of a visible key never leaves it, however large the learned shifts are.
    @Test func safeZoneAlwaysKeepsItsKey() {
        let frames: [KeyboardKeyFrame] = turkishFrames()
        var model: KeyboardTouchModel = .empty
        for letter in "qwertyuıopğüasdfghjklşizxcvbnmöç" {
            for _ in 0 ..< 40 {
                model = keyboardTouchLearning(model: model, sample: sample(String(letter), dx: -0.35, dy: 0.3))
            }
        }
        let targets: [CGPoint?]? = keyboardTouchTargets(frames: frames, model: model, layoutID: layoutID)
        #expect(targets != nil)
        for key in frames {
            guard case .character = key.key.kind else {
                continue
            }
            let safe: CGRect = key.frame.insetBy(dx: key.frame.width * 0.2, dy: key.frame.height * 0.2)
            for x in stride(from: safe.minX, through: safe.maxX, by: 1) {
                for y in stride(from: safe.minY, through: safe.maxY, by: 1) {
                    #expect(keyboardAdaptiveKeyFrame(at: CGPoint(x: x, y: y), frames: frames, targets: targets) == key)
                }
            }
        }
    }

    /// Only letter keys trade touches: a learned shift never takes a touch from Delete, Shift or Space.
    @Test func nonLetterKeysKeepTheirTouches() {
        let frames: [KeyboardKeyFrame] = turkishFrames()
        let model: KeyboardTouchModel = learned("m", dx: 0.35, dy: 0.3, count: 40, others: keyboardTouchActivationSamples)
        let targets: [CGPoint?]? = keyboardTouchTargets(frames: frames, model: model, layoutID: layoutID)
        for key in frames where key.key.kind == .delete || key.key.kind == .space || key.key.kind == .shift {
            let point: CGPoint = CGPoint(x: key.frame.minX + 1, y: key.frame.midY)
            #expect(keyboardAdaptiveKeyFrame(at: point, frames: frames, targets: targets)?.key.kind == key.key.kind)
        }
    }

    @Test func withoutTargetsTheHitTestIsThePlainOne() {
        let frames: [KeyboardKeyFrame] = turkishFrames()
        for x in stride(from: CGFloat(0), to: 402, by: 3) {
            for y in stride(from: CGFloat(0), to: 216, by: 3) {
                let point: CGPoint = CGPoint(x: x, y: y)
                #expect(keyboardAdaptiveKeyFrame(at: point, frames: frames, targets: nil) == keyboardKeyFrame(at: point, frames: frames))
            }
        }
    }

    /// With small learned shifts every touch lands on a letter key neighbouring the plain hit test's key (no jumps).
    @Test func aTouchMovesAtMostToANeighbour() {
        let frames: [KeyboardKeyFrame] = turkishFrames()
        var model: KeyboardTouchModel = .empty
        for letter in "qwertyuıopğüasdfghjklşizxcvbnmöç" {
            for _ in 0 ..< 40 {
                model = keyboardTouchLearning(model: model, sample: sample(String(letter), dx: 0.3, dy: -0.25))
            }
        }
        let targets: [CGPoint?]? = keyboardTouchTargets(frames: frames, model: model, layoutID: layoutID)
        for x in stride(from: CGFloat(0), to: 402, by: 2) {
            for y in stride(from: CGFloat(0), to: 216, by: 2) {
                let point: CGPoint = CGPoint(x: x, y: y)
                guard let plain = keyboardKeyFrame(at: point, frames: frames), let adaptive = keyboardAdaptiveKeyFrame(at: point, frames: frames, targets: targets) else {
                    continue
                }
                #expect(adaptive == plain || adaptive.hitFrame.intersects(plain.hitFrame.insetBy(dx: -1, dy: -1)))
            }
        }
    }

    @Test func offsetIsAFractionOfTheKeyFromItsCentre() {
        let frame: CGRect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let offset: (dx: Double, dy: Double) = keyboardTouchOffset(point: CGPoint(x: 40, y: 20), frame: frame)
        #expect(abs(offset.dx - 0.5) < 0.0001)
        #expect(abs(offset.dy + 0.5) < 0.0001)
    }

    @Test func aWordIsLearnedOnlyWhenTypingWentOnWithoutDeleting() {
        let first: KeyboardTouchSample = sample("a", dx: 0.1, dy: 0)
        let second: KeyboardTouchSample = sample("b", dx: 0.1, dy: 0)
        var word: KeyboardTouchWord = .empty
        word = keyboardTouchWordAfterTap(word: word, sample: first).word
        word = keyboardTouchWordAfterTap(word: word, sample: second).word
        #expect(word.pending.count == 2)
        // Space: the word waits; nothing is learned yet.
        let ended: (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) = keyboardTouchWordAfterBoundary(word: word, accepted: true)
        #expect(ended.learn.isEmpty && ended.word.awaiting.count == 2)
        // The next tap confirms it.
        let next: (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) = keyboardTouchWordAfterTap(word: ended.word, sample: first)
        #expect(next.learn == [first, second])
        #expect(next.word.pending == [first] && next.word.awaiting.isEmpty)
    }

    @Test func deletingThrowsTheWordAway() {
        let tap: KeyboardTouchSample = sample("a", dx: 0.1, dy: 0)
        var word: KeyboardTouchWord = keyboardTouchWordAfterTap(word: .empty, sample: tap).word
        #expect(keyboardTouchWordAfterDelete(word: word) == .empty)
        word = keyboardTouchWordAfterBoundary(word: word, accepted: true).word
        // Delete right after the space (undoing it, or a correction): the word is dropped.
        let afterDelete: KeyboardTouchWord = keyboardTouchWordAfterDelete(word: word)
        #expect(keyboardTouchWordAfterTap(word: afterDelete, sample: tap).learn.isEmpty)
    }

    @Test func anAutocorrectedWordIsNotLearned() {
        let tap: KeyboardTouchSample = sample("a", dx: 0.1, dy: 0)
        let word: KeyboardTouchWord = keyboardTouchWordAfterTap(word: .empty, sample: tap).word
        let ended: (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) = keyboardTouchWordAfterBoundary(word: word, accepted: false)
        #expect(ended.word == .empty)
    }

    @Test func closingConfirmsAFinishedWordAndDropsAHalfTypedOne() {
        let tap: KeyboardTouchSample = sample("a", dx: 0.1, dy: 0)
        var word: KeyboardTouchWord = keyboardTouchWordAfterTap(word: .empty, sample: tap).word
        word = keyboardTouchWordAfterBoundary(word: word, accepted: true).word
        word = keyboardTouchWordAfterTap(word: word, sample: sample("b", dx: 0, dy: 0)).word
        let closed: (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) = keyboardTouchWordAfterClose(word: KeyboardTouchWord(pending: word.pending, awaiting: [tap]))
        #expect(closed.learn == [tap] && closed.word == .empty)
    }

    @Test func pendingSamplesAreCapped() {
        var pending: [KeyboardTouchSample] = []
        for _ in 0 ..< 100 {
            pending = keyboardTouchPendingAdding(pending: pending, sample: sample("a", dx: 0, dy: 0))
        }
        #expect(pending.count == keyboardTouchPendingLimit)
    }

    @Test func progressSaturatesAtActivation() {
        #expect(keyboardTouchProgress(totalSamples: 40).learned == 40)
        #expect(!keyboardTouchProgress(totalSamples: 40).isActive)
        #expect(keyboardTouchProgress(totalSamples: 5000).learned == keyboardTouchActivationSamples)
        #expect(keyboardTouchProgress(totalSamples: 5000).isActive)
    }

    @Test func oldConfigsAndReportsDecodeAndDefaultToOn() throws {
        let extras: KeyboardTypingExtras = try JSONDecoder().decode(
            KeyboardTypingExtras.self, from: Data(#"{"layouts":{},"emojiSuggestions":true,"learnsWords":true}"#.utf8)
        )
        #expect(extras.adaptsTouch)
        #expect(extras.touchLearningClearedAt == nil)
        let report: KeyboardReport = try JSONDecoder().decode(KeyboardReport.self, from: Data(#"{"lastSeenAt":0,"hasFullAccess":true}"#.utf8))
        #expect(report.touchSamples == nil)
    }
}
