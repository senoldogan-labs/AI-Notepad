import Foundation
import Testing
@testable import KeyboardCore

/// The guided keyboard setup's page and the Settings hub's state, from observed facts.
@Suite struct KeyboardSetupTests {
    private let start: Date = Date(timeIntervalSince1970: 5_000_000)

    /// One observation; fields left out keep a plain "enabled, nothing seen yet" run a minute after it started.
    private struct Observed {
        var introDone: Bool = true
        var isEnabled: Bool? = true
        var seenAgo: TimeInterval?
        var dictatedAgo: TimeInterval?
        var activeAgo: TimeInterval?
        var voice: Bool = true
        var skipped: Bool = false
    }

    private func step(_ observed: Observed) -> KeyboardSetupStep {
        let now: Date = start.addingTimeInterval(60)
        return keyboardSetupStep(facts: KeyboardSetupFacts(
            introDone: observed.introDone, isEnabled: observed.isEnabled, lastKeyboardSeenAt: observed.seenAgo.map { now.addingTimeInterval(-$0) },
            lastDictationSucceededAt: observed.dictatedAgo.map { now.addingTimeInterval(-$0) },
            keyboardActiveInFieldSince: observed.activeAgo.map { now.addingTimeInterval(-$0) }, voiceTypingAvailable: observed.voice,
            tryVoiceSkipped: observed.skipped, flowStartedAt: start, now: now
        ))
    }

    @Test func introComesFirstEvenWhenEverythingIsDone() {
        #expect(step(Observed(introDone: false, seenAgo: 1, dictatedAgo: 1)) == .intro)
    }

    @Test func notEnabledAsksToTurnItOn() {
        #expect(step(Observed(isEnabled: false)) == .turnOn)
        // A report from before this run does not prove anything now (the keyboard may have been removed since).
        #expect(step(Observed(isEnabled: false, seenAgo: 120)) == .turnOn)
    }

    @Test func enabledOrUnknownGoesToTheSwitchStep() {
        #expect(step(Observed(isEnabled: true)) == .switchKeyboard)
        #expect(step(Observed(isEnabled: nil)) == .switchKeyboard)
    }

    @Test func reportFromThisRunProvesEnabledEvenIfTheListSaysNo() {
        #expect(step(Observed(isEnabled: false, seenAgo: 1, activeAgo: 2)) == .tryVoice)
    }

    @Test func keyboardUpWithoutReportMeansFullAccessIsOff() {
        // Just switched: wait for the report.
        #expect(step(Observed(activeAgo: keyboardFullAccessReportWait - 1)) == .switchKeyboard)
        #expect(step(Observed(activeAgo: keyboardFullAccessReportWait)) == .fullAccess)
        // Only a report from an earlier run: still Full Access off.
        #expect(step(Observed(seenAgo: 120, activeAgo: 10)) == .fullAccess)
    }

    @Test func reportInThisRunMovesToTryIt() {
        #expect(step(Observed(seenAgo: 1, activeAgo: 2)) == .tryVoice)
        // Keyboard switched away again: back to the switch step.
        #expect(step(Observed(seenAgo: 1, activeAgo: nil)) == .switchKeyboard)
    }

    @Test func dictationInThisRunIsReady() {
        #expect(step(Observed(seenAgo: 5, dictatedAgo: 1, activeAgo: nil)) == .ready)
        // A dictation from before this run does not count.
        #expect(step(Observed(seenAgo: 5, dictatedAgo: 120, activeAgo: 10)) == .tryVoice)
    }

    @Test func withoutVoiceTypingOrWhenSkippedTheReportIsEnough() {
        #expect(step(Observed(seenAgo: 1, activeAgo: 2, voice: false)) == .ready)
        #expect(step(Observed(seenAgo: 1, activeAgo: 2, skipped: true)) == .ready)
        // Skipping does not jump over Full Access.
        #expect(step(Observed(activeAgo: 10, skipped: true)) == .fullAccess)
    }

    // MARK: Hub

    private let now: Date = Date(timeIntervalSince1970: 9_000_000)

    @Test func hubStates() {
        let recent: Date = now.addingTimeInterval(-60)
        let old: Date = now.addingTimeInterval(-keyboardReportFreshness - 1)
        #expect(keyboardReadiness(isEnabled: false, lastKeyboardSeenAt: recent, lastDictationSucceededAt: recent, voiceTypingAvailable: true, now: now) == .notAdded)
        #expect(keyboardReadiness(isEnabled: nil, lastKeyboardSeenAt: nil, lastDictationSucceededAt: nil, voiceTypingAvailable: true, now: now) == .notAdded)
        #expect(keyboardReadiness(isEnabled: true, lastKeyboardSeenAt: nil, lastDictationSucceededAt: nil, voiceTypingAvailable: true, now: now) == .needsFullAccess)
        #expect(keyboardReadiness(isEnabled: true, lastKeyboardSeenAt: old, lastDictationSucceededAt: recent, voiceTypingAvailable: true, now: now) == .needsFullAccess)
        #expect(keyboardReadiness(isEnabled: true, lastKeyboardSeenAt: recent, lastDictationSucceededAt: nil, voiceTypingAvailable: true, now: now) == .voiceUntested)
        #expect(keyboardReadiness(isEnabled: nil, lastKeyboardSeenAt: recent, lastDictationSucceededAt: nil, voiceTypingAvailable: false, now: now) == .ready)
        #expect(keyboardReadiness(isEnabled: true, lastKeyboardSeenAt: recent, lastDictationSucceededAt: old, voiceTypingAvailable: true, now: now) == .ready)
    }

    @Test func inputModeMatching() {
        let ours: String = keyboardExtensionBundleIdentifier(appBundleIdentifier: "com.senoldogan.AINotepad.hosted")
        #expect(ours == "com.senoldogan.AINotepad.hosted.Keyboard")
        #expect(keyboardInputModesContainOurs(identifiers: ["tr_TR@sw=QWERTY-Turkish", "emoji@sw=Emoji", ours], extensionBundleIdentifier: ours))
        #expect(!keyboardInputModesContainOurs(identifiers: ["en_US@sw=QWERTY", "com.other.Keyboard"], extensionBundleIdentifier: ours))
    }
}

/// The in-place dictation handoff: which start commands start a dictation, and the keyboard after a warm-up tap.
@Suite struct KeyboardWarmSessionTests {
    private let now: Date = Date(timeIntervalSince1970: 7_000_000)
    private let request: UUID = UUID()

    private func start(age: TimeInterval) -> KeyboardDictationCommand {
        KeyboardDictationCommand(requestID: request, action: .start, documentID: nil, languageCode: "en", issuedAt: now.addingTimeInterval(-age))
    }

    // Root cause of "No speech heard" on device: the link and the Darwin notification both started the same request; the
    // second start cancelled the first and the first's empty result failed the second.
    @Test func oneRequestStartsOneDictation() {
        #expect(keyboardCommandStartsDictation(command: start(age: 1), isSessionActive: true, currentRequestID: nil, warmedRequestID: nil, now: now))
        #expect(!keyboardCommandStartsDictation(command: start(age: 1), isSessionActive: true, currentRequestID: request, warmedRequestID: nil, now: now))
    }

    @Test func theWarmUpTapDoesNotDictate() {
        #expect(!keyboardCommandStartsDictation(command: start(age: 1), isSessionActive: true, currentRequestID: nil, warmedRequestID: request, now: now))
    }

    @Test func noSessionOrStaleOrOtherActionDoesNotDictate() {
        #expect(!keyboardCommandStartsDictation(command: start(age: 1), isSessionActive: false, currentRequestID: nil, warmedRequestID: nil, now: now))
        #expect(!keyboardCommandStartsDictation(
            command: start(age: keyboardCommandLifetime + 1), isSessionActive: true, currentRequestID: nil, warmedRequestID: nil, now: now
        ))
        let stop: KeyboardDictationCommand = KeyboardDictationCommand(requestID: request, action: .stop, documentID: nil, languageCode: "en", issuedAt: now)
        #expect(!keyboardCommandStartsDictation(command: stop, isSessionActive: true, currentRequestID: nil, warmedRequestID: nil, now: now))
    }

    // After the warm-up the keyboard is ready (tap to speak), not "starting"; a tap after the session opened is starting.
    @Test func keyboardIsReadyAfterTheWarmUp() {
        let session: KeyboardSession = KeyboardSession(startedAt: now.addingTimeInterval(-2), expiresAt: now.addingTimeInterval(298), heartbeatAt: now)
        let status: KeyboardDictationStatus = KeyboardDictationStatus(session: session, dictation: nil)
        #expect(keyboardMicState(hasFullAccess: true, status: status, lastCommand: start(age: 3), documentID: nil, now: now) == .idle(sessionRemaining: 298))
        #expect(keyboardMicState(hasFullAccess: true, status: status, lastCommand: start(age: 1), documentID: nil, now: now) == .starting)
    }
}
