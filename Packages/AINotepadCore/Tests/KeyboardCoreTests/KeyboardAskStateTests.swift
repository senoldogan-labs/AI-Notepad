import Foundation
import Testing
@testable import KeyboardCore

/// The keyboard Ask lifecycle: the keyboard's strip (from the shared files), the app's sheet (events), the app picking up
/// a question it was not opened for, and a stale microphone failure.
@Suite struct KeyboardAskStateTests {
    private let now: Date = Date(timeIntervalSince1970: 3_000_000)
    private let request: UUID = UUID()
    private let other: UUID = UUID()

    private func asked(age: TimeInterval) -> KeyboardAskCommand {
        KeyboardAskCommand(requestID: request, action: .ask, question: "What did we decide?", documentID: nil, issuedAt: now.addingTimeInterval(-age))
    }

    private func answer(_ phase: KeyboardAskAnswer.Phase, text: String?, age: TimeInterval) -> KeyboardAskAnswer {
        KeyboardAskAnswer(requestID: request, phase: phase, answer: text, failureReason: phase == .failed ? "No access" : nil, updatedAt: now.addingTimeInterval(-age))
    }

    // MARK: Keyboard strip

    // K1: an answer that expired unused leaves the strip empty, whichever side deleted the answer file first. Before,
    // the keyboard deleting it first showed "couldn't get an answer" and hid the microphone strip.
    @Test func expiredAnswerDisappears() {
        let old: KeyboardAskCommand = asked(age: keyboardAskAnswerLifetime + 60)
        #expect(keyboardAskState(command: old, answer: nil, now: now) == .idle)
        #expect(keyboardAskState(command: old, answer: answer(.answered, text: "A", age: keyboardAskAnswerLifetime + 30), now: now) == .idle)
        #expect(keyboardAskState(command: old, answer: answer(.failed, text: nil, age: keyboardAskAnswerLifetime + 30), now: now) == .idle)
    }

    // K2: a question the app has not picked up waits (not "answering", so it does not lock asking) while the app can
    // still take it, then says it never reached Gistsmith.
    @Test func undeliveredQuestionIsShownAsSuch() {
        #expect(keyboardAskState(command: asked(age: 1), answer: nil, now: now) == .awaitingApp)
        #expect(keyboardAskState(command: asked(age: keyboardAskDeliveryWindow), answer: nil, now: now) == .awaitingApp)
        #expect(keyboardAskState(command: asked(age: keyboardAskDeliveryWindow + 1), answer: nil, now: now) == .notDelivered)
        #expect(!keyboardAskState(command: asked(age: 1), answer: nil, now: now).locksAsking)
        #expect(!KeyboardAskState.notDelivered.locksAsking)
        #expect(KeyboardAskState.answering.locksAsking)
        // An answer file of another question means this one was not picked up either.
        let foreign: KeyboardAskAnswer = KeyboardAskAnswer(requestID: other, phase: .answered, answer: "B", failureReason: nil, updatedAt: now)
        #expect(keyboardAskState(command: asked(age: 1), answer: foreign, now: now) == .awaitingApp)
    }

    @Test func pickedUpQuestionFollowsTheApp() {
        #expect(keyboardAskState(command: asked(age: 5), answer: answer(.answering, text: nil, age: 3), now: now) == .answering)
        #expect(keyboardAskState(command: asked(age: 200), answer: answer(.answering, text: nil, age: keyboardAskAnsweringTimeout + 1), now: now) == .failed(nil))
        #expect(keyboardAskState(command: asked(age: 5), answer: answer(.answered, text: " A ", age: 1), now: now) == .answered("A"))
        #expect(keyboardAskState(command: asked(age: 5), answer: answer(.answered, text: " ", age: 1), now: now) == .failed(nil))
        #expect(keyboardAskState(command: asked(age: 5), answer: answer(.failed, text: nil, age: 1), now: now) == .failed("No access"))
        let released: KeyboardAskCommand = KeyboardAskCommand(requestID: request, action: .release, question: "", documentID: nil, issuedAt: now)
        #expect(keyboardAskState(command: released, answer: answer(.answered, text: "A", age: 1), now: now) == .idle)
        #expect(keyboardAskState(command: nil, answer: nil, now: now) == .idle)
    }

    // MARK: App picks up a question

    // K2: opening Gistsmith by hand (the link could not open it) picks up the waiting question; the same question is
    // never asked twice, and an old or released one is never asked.
    @Test func appAdoptsOnlyAWaitingQuestion() {
        #expect(keyboardAskHostShouldAdopt(command: asked(age: 20), answer: nil, runningRequest: nil, now: now))
        #expect(keyboardAskHostShouldAdopt(command: asked(age: keyboardAskDeliveryWindow), answer: nil, runningRequest: nil, now: now))
        #expect(!keyboardAskHostShouldAdopt(command: asked(age: keyboardAskDeliveryWindow + 1), answer: nil, runningRequest: nil, now: now))
        #expect(!keyboardAskHostShouldAdopt(command: asked(age: 20), answer: answer(.answering, text: nil, age: 19), runningRequest: nil, now: now))
        #expect(!keyboardAskHostShouldAdopt(command: asked(age: 20), answer: nil, runningRequest: request, now: now))
        let foreign: KeyboardAskAnswer = KeyboardAskAnswer(requestID: other, phase: .answered, answer: "B", failureReason: nil, updatedAt: now)
        #expect(keyboardAskHostShouldAdopt(command: asked(age: 20), answer: foreign, runningRequest: nil, now: now))
        let released: KeyboardAskCommand = KeyboardAskCommand(requestID: request, action: .release, question: "Q", documentID: nil, issuedAt: now)
        #expect(!keyboardAskHostShouldAdopt(command: released, answer: nil, runningRequest: nil, now: now))
        let empty: KeyboardAskCommand = KeyboardAskCommand(requestID: request, action: .ask, question: "  ", documentID: nil, issuedAt: now)
        #expect(!keyboardAskHostShouldAdopt(command: empty, answer: nil, runningRequest: nil, now: now))
        #expect(!keyboardAskHostShouldAdopt(command: nil, answer: nil, runningRequest: nil, now: now))
    }

    // MARK: App sheet

    private var answering: KeyboardAskSheetState { .answering(requestID: request, question: "Q") }
    private var answered: KeyboardAskSheetState { .answered(requestID: request, question: "Q", answer: "A", at: now) }
    private var failed: KeyboardAskSheetState { .failed(requestID: request, question: "Q", reason: "R", at: now) }

    @Test func sheetAsksAnswersAndFails() {
        #expect(keyboardAskSheetTransition(state: .idle, event: .asked(requestID: request, question: "Q")) == answering)
        // A newer question replaces whatever was shown.
        #expect(keyboardAskSheetTransition(state: answered, event: .asked(requestID: other, question: "Q2")) == .answering(requestID: other, question: "Q2"))
        #expect(keyboardAskSheetTransition(state: answering, event: .answered(requestID: request, answer: "A", at: now)) == answered)
        #expect(keyboardAskSheetTransition(state: answering, event: .failed(requestID: request, reason: "R", at: now)) == failed)
    }

    // A late answer or failure of a replaced, released or cleared question changes nothing.
    @Test func sheetIgnoresLateResults() {
        let replaced: KeyboardAskSheetState = .answering(requestID: other, question: "Q2")
        #expect(keyboardAskSheetTransition(state: replaced, event: .answered(requestID: request, answer: "A", at: now)) == replaced)
        #expect(keyboardAskSheetTransition(state: replaced, event: .failed(requestID: request, reason: "R", at: now)) == replaced)
        #expect(keyboardAskSheetTransition(state: .idle, event: .answered(requestID: request, answer: "A", at: now)) == .idle)
        #expect(keyboardAskSheetTransition(state: .idle, event: .failed(requestID: request, reason: "R", at: now)) == .idle)
        #expect(keyboardAskSheetTransition(state: answered, event: .answered(requestID: request, answer: "B", at: now)) == answered)
        #expect(keyboardAskSheetTransition(state: failed, event: .answered(requestID: request, answer: "B", at: now)) == failed)
    }

    // K3: the keyboard inserted or dismissed the answer: the sheet drops it, but only for its own question.
    @Test func sheetDropsReleasedAnswer() {
        #expect(keyboardAskSheetTransition(state: answered, event: .released(requestID: request)) == .idle)
        #expect(keyboardAskSheetTransition(state: failed, event: .released(requestID: request)) == .idle)
        #expect(keyboardAskSheetTransition(state: answering, event: .released(requestID: request)) == .idle)
        #expect(keyboardAskSheetTransition(state: answered, event: .released(requestID: other)) == answered)
        #expect(keyboardAskSheetTransition(state: .idle, event: .released(requestID: request)) == .idle)
    }

    // K3: an answer or failure older than the answer's lifetime disappears; a question still being answered stays.
    @Test func sheetExpiresOldResults() {
        let later: Date = now.addingTimeInterval(keyboardAskAnswerLifetime + 1)
        #expect(keyboardAskSheetTransition(state: answered, event: .tick(now: later)) == .idle)
        #expect(keyboardAskSheetTransition(state: failed, event: .tick(now: later)) == .idle)
        #expect(keyboardAskSheetTransition(state: answered, event: .tick(now: now.addingTimeInterval(60))) == answered)
        #expect(keyboardAskSheetTransition(state: answering, event: .tick(now: later)) == answering)
        #expect(keyboardAskSheetTransition(state: .idle, event: .tick(now: later)) == .idle)
    }

    @Test func sheetClears() {
        for state in [KeyboardAskSheetState.idle, answering, answered, failed] {
            #expect(keyboardAskSheetTransition(state: state, event: .cleared) == .idle)
        }
        #expect(answered.question == "Q" && answered.requestID == request)
        #expect(KeyboardAskSheetState.idle.question == nil && KeyboardAskSheetState.idle.requestID == nil)
    }

    // MARK: Microphone session

    // K4: a microphone start that fails after its session ended (cancelled during the permission prompt, then a new
    // session opened) must not fail the newer session.
    @Test func staleMicrophoneFailureIsDropped() {
        let first: UUID = UUID()
        let second: UUID = UUID()
        #expect(keyboardMicrophoneFailureApplies(failedSession: first, currentSession: first, error: URLError(.unknown)))
        #expect(!keyboardMicrophoneFailureApplies(failedSession: first, currentSession: second, error: URLError(.unknown)))
        #expect(!keyboardMicrophoneFailureApplies(failedSession: first, currentSession: nil, error: URLError(.unknown)))
        #expect(!keyboardMicrophoneFailureApplies(failedSession: first, currentSession: first, error: CancellationError()))
    }
}
