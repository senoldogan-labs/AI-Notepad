import Foundation
import Testing
@testable import KeyboardCore

/// The dictation panel's voice field: particle motion, its speed and the levels Gistsmith publishes.
@Suite struct KeyboardParticleTests {
    @Test func particlesStayInsideTheCapsule() {
        for index in 0..<keyboardParticleCount {
            for travel in stride(from: 0.0, through: 3.0, by: 0.37) {
                let particle: KeyboardParticle = keyboardParticle(index: index, count: keyboardParticleCount, travel: travel, level: 1, time: travel)
                #expect((0...1).contains(particle.x))
                #expect((0...1).contains(particle.y))
                #expect((0...1).contains(particle.opacity))
                #expect((0...1).contains(particle.tailX))
                #expect((0...1).contains(particle.tailY))
                #expect(particle.tailX <= particle.x)
                #expect(particle.radius > 0)
            }
        }
    }

    @Test func particlesMoveRightAsTheFieldTravels() {
        let before: KeyboardParticle = keyboardParticle(index: 3, count: keyboardParticleCount, travel: 0, level: 0.5, time: 0)
        let after: KeyboardParticle = keyboardParticle(index: 3, count: keyboardParticleCount, travel: 0.01, level: 0.5, time: 0)
        // Unless it just wrapped around to the left edge.
        #expect(after.x > before.x || after.x < 0.05)
    }

    @Test func louderVoicesShowMoreParticles() {
        let shown: (Double) -> Int = { (level: Double) -> Int in
            (0..<keyboardParticleCount).filter { (index: Int) -> Bool in
                keyboardParticle(index: index, count: keyboardParticleCount, travel: 0.4, level: level, time: 0).opacity > 0
            }.count
        }
        #expect(shown(1) > shown(0))
        #expect(shown(0) > 0)
    }

    @Test func speakingStretchesSomeParticlesIntoStreaks() {
        let streaks: (Double) -> Int = { (level: Double) -> Int in
            (0..<keyboardParticleCount).filter { (index: Int) -> Bool in
                let particle: KeyboardParticle = keyboardParticle(index: index, count: keyboardParticleCount, travel: 0.7, level: level, time: 0)
                return particle.opacity > 0 && particle.isStreak
            }.count
        }
        #expect(streaks(0) == 0)
        #expect(streaks(0.5) > 0)
        #expect(streaks(1) < keyboardParticleCount)
    }

    @Test func normalSpeechAlreadyFeelsStrong() {
        #expect(keyboardParticleEnergy(level: 0.4) > 0.5)
        #expect(keyboardParticleEnergy(level: 0) == 0)
        #expect(keyboardParticleEnergy(level: 2) == 1)
    }

    @Test func louderVoicesTravelFasterAndLongGapsAreCapped() {
        #expect(keyboardParticleSpeed(motion: .listening, level: 1) > keyboardParticleSpeed(motion: .listening, level: 0))
        #expect(keyboardParticleSpeed(motion: .processing, level: 1) < keyboardParticleSpeed(motion: .listening, level: 0))
        let hidden: Double = keyboardParticleTravel(previous: 0, elapsed: 30, motion: .listening, level: 0)
        #expect(hidden == keyboardParticleTravel(previous: 0, elapsed: 0.25, motion: .listening, level: 0))
        #expect(keyboardParticleTravel(previous: 0, elapsed: -1, motion: .listening, level: 0) == 0)
    }

    @Test func levelEasesTheNewestChunk() {
        #expect(keyboardParticleLevel(levels: []) == 0)
        #expect(keyboardParticleLevel(levels: [0.4]) == 0.4)
        #expect(abs(keyboardParticleLevel(levels: [0, 1]) - 0.65) < 1e-9)
    }

    @Test func levelsArePublishedAboutTwelveTimesASecond() {
        let start: Date = Date(timeIntervalSince1970: 1_000)
        #expect(keyboardShouldPublishVoiceLevel(lastPublishedAt: nil, now: start))
        #expect(!keyboardShouldPublishVoiceLevel(lastPublishedAt: start, now: start.addingTimeInterval(0.05)))
        #expect(keyboardShouldPublishVoiceLevel(lastPublishedAt: start, now: start.addingTimeInterval(0.08)))
    }
}
