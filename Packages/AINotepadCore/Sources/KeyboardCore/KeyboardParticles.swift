import Foundation

/// How many particles the voice field draws. Bounded so a frame stays cheap in the keyboard extension.
public let keyboardParticleCount: Int = 56

/// One particle of the dictation's voice field at a moment, in unit coordinates (0…1 across and down the capsule).
public struct KeyboardParticle: Sendable, Hashable {
    public let x: Double
    public let y: Double
    /// Radius relative to the capsule's height.
    public let radius: Double
    /// 0…1.
    public let opacity: Double

    public init(x: Double, y: Double, radius: Double, opacity: Double) {
        self.x = x
        self.y = y
        self.radius = radius
        self.opacity = opacity
    }
}

/// How fast the field moves: a gentle drift without a voice, faster and brighter as the voice gets louder; slow and
/// calm while the words are being written out.
public enum KeyboardParticleMotion: Sendable, Hashable {
    case listening
    case processing
}

/// How far the field travels per second (in particle cycles) for a voice level 0…1. Pure function.
public func keyboardParticleSpeed(motion: KeyboardParticleMotion, level: Double) -> Double {
    switch motion {
    case .listening:
        0.09 + 0.55 * min(1, max(0, level))
    case .processing:
        0.035
    }
}

/// The field's travel after `elapsed` seconds more at `level`: the caller keeps the running total, so a change of
/// level changes the speed without making the particles jump. A frame gap longer than a quarter second (the keyboard
/// was hidden) counts as a quarter second. Pure function.
public func keyboardParticleTravel(previous: Double, elapsed: TimeInterval, motion: KeyboardParticleMotion, level: Double) -> Double {
    let step: Double = min(0.25, max(0, elapsed))
    // Not wrapped: each particle's cycle uses its own multiple of the travel, so a wrap would make them jump. A
    // dictation lasts at most five minutes (well under 200), far inside Double's precision.
    return previous + step * keyboardParticleSpeed(motion: motion, level: level)
}

/// The voice level the field shows: the newest level, eased toward the one before so a single loud chunk does not
/// flash. 0 without levels. Pure function.
public func keyboardParticleLevel(levels: [Double]) -> Double {
    guard let last = levels.last else {
        return 0
    }
    let previous: Double = levels.count > 1 ? levels[levels.count - 2] : last
    return min(1, max(0, last * 0.65 + previous * 0.35))
}

/// Particle `index` at `travel` (the running total of `keyboardParticleTravel`), `level` and `time` (for the twinkle).
/// Each particle enters at the left, is pulled toward the right edge (slow at first, faster near the end, drawn toward
/// the middle line) and fades out there; then it starts again. Louder voices show more particles, larger and brighter.
/// Deterministic per index. Pure function.
public func keyboardParticle(index: Int, count: Int, travel: Double, level: Double, time: TimeInterval) -> KeyboardParticle {
    let seedX: Double = keyboardParticleNoise(index: index, salt: 1)
    let seedY: Double = keyboardParticleNoise(index: index, salt: 2)
    let seedSpeed: Double = keyboardParticleNoise(index: index, salt: 3)
    let seedSize: Double = keyboardParticleNoise(index: index, salt: 4)
    let seedTwinkle: Double = keyboardParticleNoise(index: index, salt: 5)
    let clamped: Double = min(1, max(0, level))
    let cycle: Double = (seedX + travel * (0.6 + 0.8 * seedSpeed)).truncatingRemainder(dividingBy: 1)
    let progress: Double = cycle < 0 ? cycle + 1 : cycle
    // Pulled: slow where it enters, faster toward the right edge.
    let x: Double = pow(progress, 1.45)
    let startY: Double = 0.12 + 0.76 * seedY
    let y: Double = 0.5 + (startY - 0.5) * (1 - 0.55 * x)
    let envelope: Double = sin(Double.pi * progress)
    let twinkle: Double = 0.7 + 0.3 * sin(time * (1.6 + 2.4 * seedTwinkle) + seedTwinkle * 6.283)
    // Quiet: about half the particles; a full voice: all of them.
    let shownShare: Double = 0.5 + 0.5 * clamped
    let isShown: Bool = Double(index) < Double(count) * shownShare
    let opacity: Double = isShown ? envelope * twinkle * (0.45 + 0.55 * clamped) : 0
    let radius: Double = (0.03 + 0.045 * seedSize) * (0.85 + 0.5 * clamped)
    return KeyboardParticle(x: x, y: y, radius: radius, opacity: min(1, max(0, opacity)))
}

/// A stable pseudo-random value in 0..<1 for a particle and a purpose. Pure function.
func keyboardParticleNoise(index: Int, salt: Int) -> Double {
    let value: Double = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43_758.5453
    return value - value.rounded(.down)
}

/// How loud the voice is while Gistsmith listens for the keyboard (`voice-level.json`): one number per short interval,
/// for the dictation panel's motion. Never audio or words.
public struct KeyboardVoiceLevelSample: Sendable, Hashable, Codable {
    /// The dictation the level belongs to: the keyboard ignores a level of an older one.
    public let requestID: UUID
    /// 0…1 (`keyboardVoiceLevel`).
    public let level: Double

    public init(requestID: UUID, level: Double) {
        self.requestID = requestID
        self.level = level
    }
}

/// The shortest gap between two levels Gistsmith publishes to the keyboard (about 12 a second).
public let keyboardVoiceLevelInterval: TimeInterval = 0.08

/// Whether Gistsmith publishes a level now: the first of a dictation, then at most one per
/// `keyboardVoiceLevelInterval`. Pure function.
public func keyboardShouldPublishVoiceLevel(lastPublishedAt: Date?, now: Date) -> Bool {
    guard let lastPublishedAt else {
        return true
    }
    return now.timeIntervalSince(lastPublishedAt) >= keyboardVoiceLevelInterval
}
