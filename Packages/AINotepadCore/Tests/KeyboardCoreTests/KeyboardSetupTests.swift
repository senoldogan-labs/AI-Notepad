import Foundation
import Testing
@testable import KeyboardCore

/// The guided keyboard setup's page and the Settings hub's state, from documented facts only: the keyboard's own report,
/// the setup's field and what the user did.
@Suite struct KeyboardSetupTests {
    private let start: Date = Date(timeIntervalSince1970: 5_000_000)

    /// One observation; fields left out keep a run a minute old, back from Settings, with nothing reported yet.
    private struct Observed {
        var introDone: Bool = true
        var returned: Bool = true
        var reportedAgo: TimeInterval?
        var dictatedAgo: TimeInterval?
        var focusedAgo: TimeInterval?
        var hintShown: Bool = false
        var voice: Bool = true
        var skipped: Bool = false
    }

    private func step(_ observed: Observed) -> KeyboardSetupStep {
        let now: Date = start.addingTimeInterval(60)
        return keyboardSetupStep(facts: KeyboardSetupFacts(
            introDone: observed.introDone, returnedFromSettings: observed.returned,
            lastFullAccessReportAt: observed.reportedAgo.map { now.addingTimeInterval(-$0) },
            lastDictationSucceededAt: observed.dictatedAgo.map { now.addingTimeInterval(-$0) },
            fieldFocusedSince: observed.focusedAgo.map { now.addingTimeInterval(-$0) }, fullAccessHintShown: observed.hintShown,
            voiceTypingAvailable: observed.voice,
            tryVoiceSkipped: observed.skipped, flowStartedAt: start, now: now
        ))
    }

    @Test func introComesFirstEvenWhenEverythingIsDone() {
        #expect(step(Observed(introDone: false, reportedAgo: 1, dictatedAgo: 1)) == .intro)
    }

    @Test func numberedStepsUntilBackFromSettings() {
        #expect(step(Observed(returned: false)) == .turnOn)
        // A report from before this run proves nothing now (the keyboard may have been removed since).
        #expect(step(Observed(returned: false, reportedAgo: 120)) == .turnOn)
    }

    @Test func aReportInThisRunSkipsAheadEvenBeforeSettings() {
        #expect(step(Observed(returned: false, reportedAgo: 1)) == .tryVoice)
    }

    @Test func backFromSettingsAsksToSwitchInTheField() {
        #expect(step(Observed()) == .switchKeyboard)
        #expect(step(Observed(focusedAgo: keyboardFullAccessHintWait - 1)) == .switchKeyboard)
    }

    @Test func focusedLongWithoutReportPointsAtFullAccess() {
        #expect(step(Observed(focusedAgo: keyboardFullAccessHintWait)) == .fullAccess)
        // Only a report from an earlier run: still no proof.
        #expect(step(Observed(reportedAgo: 120, focusedAgo: 30)) == .fullAccess)
        // Skipping the try-out does not jump over Full Access.
        #expect(step(Observed(focusedAgo: 30, skipped: true)) == .fullAccess)
    }

    // The hint page has its own field: its focus restarts the clock, and the page must not flip back every 15 s.
    @Test func theHintStaysOnceShownUntilAReport() {
        #expect(step(Observed(focusedAgo: 0, hintShown: true)) == .fullAccess)
        #expect(step(Observed(focusedAgo: nil, hintShown: true)) == .fullAccess)
        #expect(step(Observed(reportedAgo: 1, hintShown: true)) == .tryVoice)
    }

    @Test func reportInThisRunMovesToTryItThenReady() {
        #expect(step(Observed(reportedAgo: 1)) == .tryVoice)
        #expect(step(Observed(reportedAgo: 5, dictatedAgo: 1)) == .ready)
        // A dictation from before this run does not count.
        #expect(step(Observed(reportedAgo: 5, dictatedAgo: 120)) == .tryVoice)
    }

    @Test func withoutVoiceTypingOrWhenSkippedTheReportIsEnough() {
        #expect(step(Observed(reportedAgo: 1, voice: false)) == .ready)
        #expect(step(Observed(reportedAgo: 1, skipped: true)) == .ready)
    }

    @Test func fullAccessComesFromTheReport() {
        let now: Date = Date(timeIntervalSince1970: 9_000_000)
        #expect(keyboardFullAccessSeenAt(report: KeyboardReport(lastSeenAt: now, hasFullAccess: true)) == now)
        #expect(keyboardFullAccessSeenAt(report: KeyboardReport(lastSeenAt: now, hasFullAccess: false)) == nil)
        #expect(keyboardFullAccessSeenAt(report: nil) == nil)
    }

    // Reports from keyboards before `hasFullAccess` existed were only writable with Full Access.
    @Test func olderReportsCountAsFullAccess() throws {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let old: KeyboardReport = try decoder.decode(KeyboardReport.self, from: Data(#"{"lastSeenAt":9000000000}"#.utf8))
        #expect(old.hasFullAccess == nil)
        #expect(keyboardFullAccessSeenAt(report: old) == old.lastSeenAt)
    }

    // MARK: Hub

    @Test func hubStates() {
        let now: Date = Date(timeIntervalSince1970: 9_000_000)
        let recent: Date = now.addingTimeInterval(-60)
        let old: Date = now.addingTimeInterval(-keyboardReportFreshness - 1)
        #expect(keyboardReadiness(lastFullAccessReportAt: nil, lastDictationSucceededAt: recent, voiceTypingAvailable: true, now: now) == .notSetUp)
        #expect(keyboardReadiness(lastFullAccessReportAt: old, lastDictationSucceededAt: recent, voiceTypingAvailable: true, now: now) == .notSetUp)
        #expect(keyboardReadiness(lastFullAccessReportAt: recent, lastDictationSucceededAt: nil, voiceTypingAvailable: true, now: now) == .voiceUntested)
        #expect(keyboardReadiness(lastFullAccessReportAt: recent, lastDictationSucceededAt: nil, voiceTypingAvailable: false, now: now) == .ready)
        #expect(keyboardReadiness(lastFullAccessReportAt: recent, lastDictationSucceededAt: old, voiceTypingAvailable: true, now: now) == .ready)
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
