import CoreGraphics
import Foundation

// Adaptive touch: the keyboard learns where this person's finger actually lands on each letter key and shifts the keys'
// hit areas accordingly. The model stores only offsets (a mean of where taps landed relative to a key's centre, as a
// fraction of the key's size) and counts, never text or the order keys were typed in. Everything here is pure; the
// keyboard extension owns the persistence (`KeyboardTouchLearner`) and the touch wiring.

/// Taps needed (all layouts together) before learned offsets are applied: below this the keys stay where they are drawn.
public let keyboardTouchActivationSamples: Int = 300
/// Samples one key needs before its own offset is used.
public let keyboardTouchMinimumKeySamples: Int = 8
/// A key's mean follows roughly its last this-many taps (exponential moving average), so it adapts when the grip changes.
public let keyboardTouchDecayWindow: Int = 150
/// Largest learned shift, as a fraction of the key's width and height.
public let keyboardTouchMaximumShiftX: Double = 0.35
public let keyboardTouchMaximumShiftY: Double = 0.30
/// A touch inside this central share of a visible key (per axis) always stays that key.
public let keyboardTouchSafeZoneShare: CGFloat = 0.6
/// The model keeps at most this many (layout, key) entries; the least-sampled ones go first.
public let keyboardTouchKeyLimit: Int = 240
/// Samples of one word waiting to be accepted.
public let keyboardTouchPendingLimit: Int = 32

/// The learned mean tap offset of one key: `dx` and `dy` are fractions of the key's width and height (right and down
/// positive), rounded to a thousandth; `count` is the number of samples behind them (at most `keyboardTouchDecayWindow`).
public struct KeyboardTouchStat: Sendable, Hashable, Codable {
    public let dx: Double
    public let dy: Double
    public let count: Int

    public init(dx: Double, dy: Double, count: Int) {
        self.dx = dx
        self.dy = dy
        self.count = count
    }
}

/// One tap on a letter key that the typed word later confirmed.
public struct KeyboardTouchSample: Sendable, Hashable {
    /// `keyboardTouchLayoutID`.
    public let layoutID: String
    /// The key's lowercased letter.
    public let key: String
    public let dx: Double
    public let dy: Double

    public init(layoutID: String, key: String, dx: Double, dy: Double) {
        self.layoutID = layoutID
        self.key = key
        self.dx = dx
        self.dy = dy
    }
}

/// What the keyboard has learned on this iPhone: a stat per layout and key, and how many taps were learned in all.
public struct KeyboardTouchModel: Sendable, Hashable, Codable {
    /// Keyed by `layoutID + "/" + letter`.
    public let stats: [String: KeyboardTouchStat]
    /// Taps learned in all (saturates at `Int.max / 2`); the progress the app shows and the activation gate.
    public let totalSamples: Int

    public init(stats: [String: KeyboardTouchStat], totalSamples: Int) {
        self.stats = stats
        self.totalSamples = totalSamples
    }

    public static let empty: KeyboardTouchModel = KeyboardTouchModel(stats: [:], totalSamples: 0)

    /// Whether learned offsets are applied yet.
    public var isActive: Bool {
        totalSamples >= keyboardTouchActivationSamples
    }
}

/// The identity of a letter arrangement: language, letter layout and orientation (offsets differ between portrait and
/// landscape keys). Pure function.
public func keyboardTouchLayoutID(language: KeyboardLanguage, layout: KeyboardLetterLayout, isLandscape: Bool) -> String {
    language.rawValue + "." + layout.rawValue + (isLandscape ? ".l" : ".p")
}

/// Where `point` fell on `frame` as fractions of the frame's size from its centre (right and down positive). Pure function.
public func keyboardTouchOffset(point: CGPoint, frame: CGRect) -> (dx: Double, dy: Double) {
    guard frame.width > 0, frame.height > 0 else {
        return (0, 0)
    }
    return (Double((point.x - frame.midX) / frame.width), Double((point.y - frame.midY) / frame.height))
}

private func keyboardTouchRounded(_ value: Double) -> Double {
    (value * 1000).rounded() / 1000
}

private func keyboardTouchClamped(_ value: Double, limit: Double) -> Double {
    min(limit, max(-limit, value))
}

/// The model after one more confirmed tap: the key's mean moves toward the sample by `1 / (count + 1)` (so the first
/// samples average), and by `1 / keyboardTouchDecayWindow` once the key has that many (so old taps fade). The mean is
/// clamped and rounded; past `keyboardTouchKeyLimit` entries the least-sampled go. Pure function.
public func keyboardTouchLearning(model: KeyboardTouchModel, sample: KeyboardTouchSample) -> KeyboardTouchModel {
    let id: String = sample.layoutID + "/" + sample.key
    let old: KeyboardTouchStat = model.stats[id] ?? KeyboardTouchStat(dx: 0, dy: 0, count: 0)
    let weight: Double = 1 / Double(min(old.count + 1, keyboardTouchDecayWindow))
    let dx: Double = keyboardTouchClamped(old.dx + (sample.dx - old.dx) * weight, limit: keyboardTouchMaximumShiftX)
    let dy: Double = keyboardTouchClamped(old.dy + (sample.dy - old.dy) * weight, limit: keyboardTouchMaximumShiftY)
    var stats: [String: KeyboardTouchStat] = model.stats
    stats[id] = KeyboardTouchStat(dx: keyboardTouchRounded(dx), dy: keyboardTouchRounded(dy), count: min(old.count + 1, keyboardTouchDecayWindow))
    if stats.count > keyboardTouchKeyLimit {
        let drop: [String] = stats.sorted { (lhs: (key: String, value: KeyboardTouchStat), rhs: (key: String, value: KeyboardTouchStat)) -> Bool in
            lhs.value.count != rhs.value.count ? lhs.value.count < rhs.value.count : lhs.key < rhs.key
        }.prefix(stats.count - keyboardTouchKeyLimit).map(\.key)
        for key in drop {
            stats[key] = nil
        }
    }
    return KeyboardTouchModel(stats: stats, totalSamples: min(model.totalSamples, Int.max / 2) + 1)
}

/// The model after all `samples`, in order. Pure function.
public func keyboardTouchLearning(model: KeyboardTouchModel, samples: [KeyboardTouchSample]) -> KeyboardTouchModel {
    samples.reduce(model) { (current: KeyboardTouchModel, sample: KeyboardTouchSample) -> KeyboardTouchModel in
        keyboardTouchLearning(model: current, sample: sample)
    }
}

/// The samples of the word being typed after a tap on a letter key (the oldest go past `keyboardTouchPendingLimit`).
/// Pure function.
public func keyboardTouchPendingAdding(pending: [KeyboardTouchSample], sample: KeyboardTouchSample) -> [KeyboardTouchSample] {
    Array((pending + [sample]).suffix(keyboardTouchPendingLimit))
}

/// Per key (aligned with `frames`), the point its hit area is centred on: the key's centre moved by the learned offset,
/// or nil for keys without enough samples of their own. Nil as a whole while the model is not active yet or `layoutID`
/// is not the letters. Pure function; computed when the keys or the model change, not per touch.
public func keyboardTouchTargets(frames: [KeyboardKeyFrame], model: KeyboardTouchModel, layoutID: String) -> [CGPoint?]? {
    guard model.isActive else {
        return nil
    }
    var any: Bool = false
    let targets: [CGPoint?] = frames.map { (frame: KeyboardKeyFrame) -> CGPoint? in
        guard case .character(let letter) = frame.key.kind, let stat = model.stats[layoutID + "/" + letter.lowercased()],
              stat.count >= keyboardTouchMinimumKeySamples
        else {
            return nil
        }
        any = true
        return CGPoint(x: frame.frame.midX + CGFloat(stat.dx) * frame.frame.width, y: frame.frame.midY + CGFloat(stat.dy) * frame.frame.height)
    }
    return any ? targets : nil
}

/// The key a touch at `point` lands on with learned `targets` (from `keyboardTouchTargets`, aligned with `frames`): the
/// plain hit test's key, unless the touch is outside that key's central `keyboardTouchSafeZoneShare` and a letter key
/// touching it has its learned target nearer. Only letter keys trade touches; a touch well inside a visible key stays on
/// it, so no key becomes unreachable. O(keys), no allocation. Pure function.
public func keyboardAdaptiveKeyFrame(at point: CGPoint, frames: [KeyboardKeyFrame], targets: [CGPoint?]?) -> KeyboardKeyFrame? {
    guard let base = keyboardKeyFrame(at: point, frames: frames) else {
        return nil
    }
    guard let targets, targets.count == frames.count, case .character = base.key.kind else {
        return base
    }
    let safe: CGRect = base.frame.insetBy(dx: base.frame.width * (1 - keyboardTouchSafeZoneShare) / 2, dy: base.frame.height * (1 - keyboardTouchSafeZoneShare) / 2)
    if safe.contains(point) {
        return base
    }
    var best: KeyboardKeyFrame = base
    var bestDistance: CGFloat = .infinity
    let reach: CGRect = base.hitFrame.insetBy(dx: -1, dy: -1)
    for (index, frame) in frames.enumerated() {
        guard case .character = frame.key.kind, frame == base || frame.hitFrame.intersects(reach) else {
            continue
        }
        let target: CGPoint = targets[index] ?? CGPoint(x: frame.frame.midX, y: frame.frame.midY)
        let dx: CGFloat = target.x - point.x
        let dy: CGFloat = target.y - point.y
        let distance: CGFloat = dx * dx + dy * dy
        if distance < bestDistance {
            bestDistance = distance
            best = frame
        }
    }
    return best
}

/// The letter taps of the word being typed (`pending`) and of the word just finished (`awaiting`). A word's taps are
/// learned only once the typing went on without deleting back into it: a word finished by a space or punctuation waits
/// for the next tap, and a delete before that (undoing the space, or a correction) throws it away. Taps of a word the
/// keyboard autocorrected are never learned (the word was not what the finger aimed at).
public struct KeyboardTouchWord: Sendable, Hashable {
    public let pending: [KeyboardTouchSample]
    public let awaiting: [KeyboardTouchSample]

    public init(pending: [KeyboardTouchSample], awaiting: [KeyboardTouchSample]) {
        self.pending = pending
        self.awaiting = awaiting
    }

    public static let empty: KeyboardTouchWord = KeyboardTouchWord(pending: [], awaiting: [])
}

/// A tap on a letter key: the finished word before it (if any) is confirmed, the tap joins the new word. Returns the
/// samples to learn. Pure function.
public func keyboardTouchWordAfterTap(word: KeyboardTouchWord, sample: KeyboardTouchSample) -> (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) {
    (KeyboardTouchWord(pending: keyboardTouchPendingAdding(pending: word.pending, sample: sample), awaiting: []), word.awaiting)
}

/// A delete (any backspace, including a long press): both the word being typed and the one just finished are dropped.
/// Pure function.
public func keyboardTouchWordAfterDelete(word: KeyboardTouchWord) -> KeyboardTouchWord {
    .empty
}

/// A word ended (space, return, punctuation): the previous finished word is confirmed, this one waits (`accepted`:
/// the keyboard did not autocorrect it) or is dropped. Returns the samples to learn. Pure function.
public func keyboardTouchWordAfterBoundary(word: KeyboardTouchWord, accepted: Bool) -> (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) {
    (KeyboardTouchWord(pending: [], awaiting: accepted ? word.pending : []), word.awaiting)
}

/// The keyboard closing (or another change of context): the finished word is confirmed, a half typed one is dropped.
/// Returns the samples to learn. Pure function.
public func keyboardTouchWordAfterClose(word: KeyboardTouchWord) -> (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) {
    (.empty, word.awaiting)
}

/// What the app shows for the learning: the taps learned toward the activation count. Pure function.
public func keyboardTouchProgress(totalSamples: Int) -> (learned: Int, isActive: Bool) {
    (min(max(totalSamples, 0), keyboardTouchActivationSamples), totalSamples >= keyboardTouchActivationSamples)
}
