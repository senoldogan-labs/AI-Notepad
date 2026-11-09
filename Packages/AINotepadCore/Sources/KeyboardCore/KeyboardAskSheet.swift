import Foundation

/// What Gistsmith's "Ask from the keyboard" sheet shows: the question the keyboard asked and how far its answer got. One
/// value instead of separate question, phase, answer and reason fields, so the sheet can never show an answer the
/// keyboard already inserted or that expired.
public enum KeyboardAskSheetState: Sendable, Hashable {
    /// No question (none asked, inserted, dismissed, expired or cleared).
    case idle
    /// The app is asking `question`.
    case answering(requestID: UUID, question: String)
    /// The answer is ready in the keyboard; it lasts `keyboardAskAnswerLifetime` from `at`.
    case answered(requestID: UUID, question: String, answer: String, at: Date)
    /// The question could not be answered; the keyboard shows `reason` too.
    case failed(requestID: UUID, question: String, reason: String, at: Date)

    /// The question being shown, nil when idle.
    public var question: String? {
        switch self {
        case .idle: nil
        case .answering(_, let question), .answered(_, let question, _, _), .failed(_, let question, _, _): question
        }
    }

    /// The request the sheet belongs to, nil when idle.
    public var requestID: UUID? {
        switch self {
        case .idle: nil
        case .answering(let id, _), .answered(let id, _, _, _), .failed(let id, _, _, _): id
        }
    }
}

/// What happened to the keyboard's question in the app.
public enum KeyboardAskSheetEvent: Sendable, Hashable {
    /// The app started answering a question from the keyboard (a newer question replaces the older one).
    case asked(requestID: UUID, question: String)
    /// The answer was written for the keyboard.
    case answered(requestID: UUID, answer: String, at: Date)
    /// The question failed (the reason was written for the keyboard).
    case failed(requestID: UUID, reason: String, at: Date)
    /// The keyboard inserted or dismissed the answer of `requestID`.
    case released(requestID: UUID)
    /// Time passed (the app came to the front, or the expiry timer fired).
    case tick(now: Date)
    /// Signed out, account deleted or switched: nothing of the old question stays.
    case cleared
}

/// The sheet after `event`. Answers and failures only land on the question still being answered, a release only clears
/// its own question, and an answer or failure older than `keyboardAskAnswerLifetime` disappears. Pure function.
public func keyboardAskSheetTransition(state: KeyboardAskSheetState, event: KeyboardAskSheetEvent) -> KeyboardAskSheetState {
    switch (state, event) {
    case (_, .asked(let id, let question)):
        return .answering(requestID: id, question: question)
    case (.answering(let current, let question), .answered(let id, let answer, let at)) where current == id:
        return .answered(requestID: id, question: question, answer: answer, at: at)
    case (.answering(let current, let question), .failed(let id, let reason, let at)) where current == id:
        return .failed(requestID: id, question: question, reason: reason, at: at)
    case (_, .released(let id)) where state.requestID == id:
        return .idle
    case (.answered(_, _, _, let at), .tick(let now)), (.failed(_, _, _, let at), .tick(let now)):
        return now.timeIntervalSince(at) > keyboardAskAnswerLifetime ? .idle : state
    case (_, .cleared):
        return .idle
    case (_, .answered), (_, .failed), (_, .released), (_, .tick):
        return state
    }
}
