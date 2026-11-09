import Foundation
import Testing
@testable import KeyboardCore

/// Klavyeden Gistsmith'e soru: komut doğrulama, şerit durumu, eski cevabın silinmesi.
@Suite struct KeyboardAskTests {
    private let now: Date = Date(timeIntervalSince1970: 2_000_000)
    private let request: UUID = UUID()

    private func command(_ action: KeyboardAskCommand.Action, question: String, age: TimeInterval) -> KeyboardAskCommand {
        KeyboardAskCommand(requestID: request, action: action, question: question, documentID: UUID(), issuedAt: now.addingTimeInterval(-age))
    }

    private func answer(_ phase: KeyboardAskAnswer.Phase, text: String?, age: TimeInterval) -> KeyboardAskAnswer {
        KeyboardAskAnswer(requestID: request, phase: phase, answer: text, failureReason: phase == .failed ? "Abonelik gerekiyor" : nil, updatedAt: now.addingTimeInterval(-age))
    }

    // Bağlantı yalnız klavyenin az önce yazdığı, boş olmayan, sınırı aşmayan soruyu sorar.
    @Test func linkAsksOnlyAFreshMatchingQuestion() {
        #expect(keyboardAskCommandIsValid(command: command(.ask, question: "What did we decide?", age: 2), requestID: request, now: now))
        #expect(!keyboardAskCommandIsValid(command: command(.ask, question: "  ", age: 2), requestID: request, now: now))
        #expect(!keyboardAskCommandIsValid(command: command(.ask, question: "x", age: 60), requestID: request, now: now))
        #expect(!keyboardAskCommandIsValid(command: command(.ask, question: "x", age: 2), requestID: UUID(), now: now))
        #expect(!keyboardAskCommandIsValid(command: command(.release, question: "x", age: 2), requestID: request, now: now))
        let long: String = String(repeating: "a", count: keyboardAskQuestionLimit + 1)
        #expect(!keyboardAskCommandIsValid(command: command(.ask, question: long, age: 2), requestID: request, now: now))
        #expect(!keyboardAskCommandIsValid(command: nil, requestID: request, now: now))
    }

    @Test func stripFollowsTheLastQuestion() {
        let asked: KeyboardAskCommand = command(.ask, question: "Q", age: 5)
        #expect(keyboardAskState(command: nil, answer: nil, now: now) == .idle)
        #expect(keyboardAskState(command: asked, answer: nil, now: now) == .answering)
        #expect(keyboardAskState(command: asked, answer: answer(.answering, text: nil, age: 3), now: now) == .answering)
        #expect(keyboardAskState(command: asked, answer: answer(.answered, text: " Pricing stays at $14. ", age: 1), now: now) == .answered("Pricing stays at $14."))
        #expect(keyboardAskState(command: asked, answer: answer(.failed, text: nil, age: 1), now: now) == .failed("Abonelik gerekiyor"))
        // Eklenen ya da bırakılan cevap şeritte kalmaz.
        #expect(keyboardAskState(command: command(.release, question: "Q", age: 0), answer: answer(.answered, text: "A", age: 1), now: now) == .idle)
    }

    // Uygulama kapandıysa "cevaplanıyor" sonsuza dek sürmez; eski cevap gösterilmez.
    @Test func timeoutsAndExpiry() {
        #expect(keyboardAskState(command: command(.ask, question: "Q", age: 200), answer: nil, now: now) == .failed(nil))
        #expect(keyboardAskState(command: command(.ask, question: "Q", age: 300), answer: answer(.answering, text: nil, age: 200), now: now) == .failed(nil))
        #expect(keyboardAskState(command: command(.ask, question: "Q", age: 900), answer: answer(.answered, text: "A", age: 700), now: now) == .idle)
        #expect(keyboardAskState(command: command(.ask, question: "Q", age: 5), answer: answer(.answered, text: "  ", age: 1), now: now) == .failed(nil))
    }

    @Test func staleAnswersAreDeleted() {
        let asked: KeyboardAskCommand = command(.ask, question: "Q", age: 5)
        #expect(!keyboardAskAnswerIsStale(answer: nil, command: asked, now: now))
        #expect(!keyboardAskAnswerIsStale(answer: answer(.answered, text: "A", age: 10), command: asked, now: now))
        #expect(keyboardAskAnswerIsStale(answer: answer(.answered, text: "A", age: 700), command: asked, now: now))
        #expect(keyboardAskAnswerIsStale(answer: answer(.answered, text: "A", age: 10), command: command(.release, question: "Q", age: 0), now: now))
        #expect(keyboardAskAnswerIsStale(answer: answer(.answered, text: "A", age: 10), command: nil, now: now))
    }

    @Test func questionFieldIsCapped() {
        let full: String = String(repeating: "a", count: keyboardAskQuestionLimit)
        #expect(keyboardAskQuestionAppending(question: full, text: "b") == full)
        #expect(keyboardAskQuestionAppending(question: "Wh", text: "at") == "What")
    }

    // Ten rengi yalnız alabilen emojiye ve ilk karakterin ardına eklenir.
    @Test func skinTonesApplyOnlyWhereUnicodeDefinesThem() {
        #expect(keyboardEmojiApplyingTone(emoji: "👍", tone: .medium) == "👍🏽")
        #expect(keyboardEmojiApplyingTone(emoji: "✌️", tone: .dark) == "✌🏿")
        #expect(keyboardEmojiApplyingTone(emoji: "🧑‍💻", tone: .light) == "🧑🏻‍💻")
        #expect(keyboardEmojiApplyingTone(emoji: "😀", tone: .dark) == "😀")
        #expect(keyboardEmojiApplyingTone(emoji: "👍", tone: .none) == "👍")
    }

    @Test func askLinkRoundTrips() {
        #expect(keyboardLinkRoute(url: keyboardAskURL(requestID: request)) == .ask(requestID: request))
    }
}
