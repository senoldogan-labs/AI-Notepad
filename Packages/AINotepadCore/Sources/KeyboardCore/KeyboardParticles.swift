import Foundation

/// How many particles the voice field draws. Bounded so a frame stays cheap in the keyboard extension.
public let keyboardParticleCount: Int = 84

/// One particle of the dictation's voice field at a moment, in unit coordinates (0…1 across and down the capsule).
/// A streak's tail trails behind its head along its path; a dot's tail is its head.
public struct KeyboardParticle: Sendable, Hashable {
    public let x: Double
    public let y: Double
    public let tailX: Double
    public let tailY: Double
    /// Radius relative to the capsule's height.
    public let radius: Double
    /// 0…1.
    public let opacity: Double

    public init(x: Double, y: Double, tailX: Double, tailY: Double, radius: Double, opacity: Double) {
        self.x = x
        self.y = y
        self.tailX = tailX
        self.tailY = tailY
        self.radius = radius
        self.opacity = opacity
    }

    /// Whether the particle is drawn as a streak (its tail is visibly behind its head).
    public var isStreak: Bool {
        abs(x - tailX) > 0.004
    }
}

/// How fast the field moves: a gentle drift without a voice, faster and brighter as the voice gets louder; slow and
/// calm while the words are being written out.
public enum KeyboardParticleMotion: Sendable, Hashable {
    case listening
    case processing
}

/// The voice level as the field feels it: normal speech (levels around 0.3–0.6) already reads as strong. Pure function.
public func keyboardParticleEnergy(level: Double) -> Double {
    pow(min(1, max(0, level)), 0.7)
}

/// How far the field travels per second (in particle cycles) for a voice level 0…1. Pure function.
public func keyboardParticleSpeed(motion: KeyboardParticleMotion, level: Double) -> Double {
    switch motion {
    case .listening:
        0.08 + 1.5 * keyboardParticleEnergy(level: level)
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
    // dictation lasts at most five minutes, far inside Double's precision.
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

/// Where a particle is at `progress` (0…1) along its fall: pulled toward the singularity at the right edge's middle,
/// slow where it enters and accelerating as it nears it, its lane narrowing with a slight swirl. Pure function.
func keyboardParticlePath(progress: Double, startY: Double, swirl: Double) -> (x: Double, y: Double) {
    let x: Double = pow(progress, 1.9)
    let closeness: Double = pow(1 - x, 1.3)
    let y: Double = 0.5 + (startY - 0.5) * closeness + 0.05 * closeness * sin(progress * 9 + swirl * 6.283)
    return (x, y)
}

/// Particle `index` at `travel` (the running total of `keyboardParticleTravel`), `level` and `time` (for the twinkle).
/// Each particle enters at the left and falls toward the right edge as if drawn in by a black hole: accelerating, its
/// lane closing toward the middle, fading as it is swallowed; then it starts again. A louder voice brings more
/// particles in, larger and brighter, and stretches about a third of them into arrow-like streaks. Deterministic per
/// index. Pure function.
public func keyboardParticle(index: Int, count: Int, travel: Double, level: Double, time: TimeInterval) -> KeyboardParticle {
    let seedX: Double = keyboardParticleNoise(index: index, salt: 1)
    let seedY: Double = keyboardParticleNoise(index: index, salt: 2)
    let seedSpeed: Double = keyboardParticleNoise(index: index, salt: 3)
    let seedSize: Double = keyboardParticleNoise(index: index, salt: 4)
    let seedTwinkle: Double = keyboardParticleNoise(index: index, salt: 5)
    let seedKind: Double = keyboardParticleNoise(index: index, salt: 6)
    let energy: Double = keyboardParticleEnergy(level: level)
    let cycle: Double = (seedX + travel * (0.6 + 0.8 * seedSpeed)).truncatingRemainder(dividingBy: 1)
    let progress: Double = cycle < 0 ? cycle + 1 : cycle
    let startY: Double = 0.1 + 0.8 * seedY
    let head: (x: Double, y: Double) = keyboardParticlePath(progress: progress, startY: startY, swirl: seedTwinkle)
    // Streaks: about a third of the particles, stretched by the voice; quiet, they are dots.
    let isStreakKind: Bool = seedKind > 0.66
    let lag: Double = isStreakKind ? (0.02 + 0.11 * energy) * energy * (0.7 + 0.6 * seedSpeed) : 0
    let tail: (x: Double, y: Double) = lag > 0 ? keyboardParticlePath(progress: max(0, progress - lag), startY: startY, swirl: seedTwinkle) : head
    let envelope: Double = sin(Double.pi * progress)
    let twinkle: Double = 0.7 + 0.3 * sin(time * (1.6 + 2.4 * seedTwinkle) + seedTwinkle * 6.283)
    // Quiet: about a third of the particles; a full voice: all of them.
    let shownShare: Double = 0.35 + 0.65 * energy
    let isShown: Bool = Double(index) < Double(count) * shownShare
    let opacity: Double = isShown ? envelope * twinkle * (0.4 + 0.6 * energy) : 0
    let radius: Double = (0.025 + 0.04 * seedSize) * (0.85 + 0.55 * energy)
    return KeyboardParticle(x: head.x, y: head.y, tailX: tail.x, tailY: tail.y, radius: radius, opacity: min(1, max(0, opacity)))
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
