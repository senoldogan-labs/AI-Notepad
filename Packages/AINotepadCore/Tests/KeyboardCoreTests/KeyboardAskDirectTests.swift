import Foundation
import Testing
@testable import KeyboardCore

/// Ask from the keyboard without opening Gistsmith: the route, token renewal, the meeting copy and retries.
@Suite struct KeyboardAskDirectTests {
    let now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    let base: URL = URL(string: "https://api.gistsmith.com")!

    func token(expiresIn: TimeInterval, serverContext: Bool) -> KeyboardAskToken {
        KeyboardAskToken(token: "t", expiresAt: now.addingTimeInterval(expiresIn), serverContext: serverContext, baseURL: base)
    }

    @Test func liveSessionFirstThenDirectThenOpenApp() {
        let fresh: KeyboardAskToken = token(expiresIn: 3600, serverContext: false)
        #expect(keyboardAskRoute(sessionIsLive: true, hasFullAccess: true, token: fresh, hasLocalContext: true, now: now) == .appSession)
        #expect(keyboardAskRoute(sessionIsLive: false, hasFullAccess: true, token: fresh, hasLocalContext: true, now: now) == .direct)
        #expect(keyboardAskRoute(sessionIsLive: false, hasFullAccess: true, token: token(expiresIn: 3600, serverContext: true), hasLocalContext: false, now: now) == .direct)
    }

    @Test func opensTheAppWithoutAccessTokenOrNotes() {
        let fresh: KeyboardAskToken = token(expiresIn: 3600, serverContext: false)
        #expect(keyboardAskRoute(sessionIsLive: false, hasFullAccess: false, token: fresh, hasLocalContext: true, now: now) == .openApp)
        #expect(keyboardAskRoute(sessionIsLive: false, hasFullAccess: true, token: nil, hasLocalContext: true, now: now) == .openApp)
        #expect(keyboardAskRoute(sessionIsLive: false, hasFullAccess: true, token: fresh, hasLocalContext: false, now: now) == .openApp)
        #expect(keyboardAskRoute(sessionIsLive: false, hasFullAccess: true, token: token(expiresIn: 30, serverContext: true), hasLocalContext: true, now: now) == .openApp)
        #expect(keyboardAskRoute(sessionIsLive: false, hasFullAccess: true, token: token(expiresIn: -10, serverContext: true), hasLocalContext: true, now: now) == .openApp)
    }

    @Test func renewsAMissingOrDayOldToken() {
        #expect(keyboardAskTokenNeedsRenewal(token: nil, now: now))
        #expect(!keyboardAskTokenNeedsRenewal(token: token(expiresIn: keyboardAskTokenLifetime - 3600, serverContext: false), now: now))
        #expect(keyboardAskTokenNeedsRenewal(token: token(expiresIn: keyboardAskTokenLifetime - keyboardAskTokenRenewalAge - 1, serverContext: false), now: now))
        #expect(keyboardAskTokenNeedsRenewal(token: token(expiresIn: -1, serverContext: false), now: now))
    }

    func item(_ id: Int, summary: String) -> KeyboardMeetingItem {
        KeyboardMeetingItem(
            id: "\(id)", title: "Meeting \(id)", date: now.addingTimeInterval(TimeInterval(id) * 86_400), summary: summary,
            actionItems: ["Ada: ship"], myTasks: ["Write memo"], decisions: ["Keep price"], openQuestions: ["Discount?"]
        )
    }

    @Test func contextIsNewestFirstTrimmedAndWithinBudget() {
        let long: String = String(repeating: "word ", count: 2000)
        let meetings: [KeyboardMeetingItem] = (1...20).map { item($0, summary: long) }
        let context: [KeyboardAskMeeting] = keyboardAskContext(
            meetings: meetings, budgetBytes: keyboardAskContextBudgetBytes, summaryMaxChars: keyboardAskSummaryMaxChars, maxMeetings: keyboardAskMaxMeetings
        )
        #expect(!context.isEmpty)
        #expect(context.first?.title == "Meeting 20")
        #expect(context.allSatisfy { $0.summary.count <= keyboardAskSummaryMaxChars })
        #expect(context.first?.decisions == ["Keep price"])
        #expect(context.first?.openQuestions == ["Discount?"])
        let encoded: Data = try! JSONEncoder().encode(KeyboardAskRequestBody(question: String(repeating: "q", count: 500), meetings: context))
        #expect(encoded.count < 32 * 1024)
        #expect(context.count < 20)
    }

    @Test func contextKeepsEverythingSmallAndOldSnapshots() throws {
        let old: Data = Data(#"{"id":"1","title":"T","date":0,"summary":"S","actionItems":[],"myTasks":[]}"#.utf8)
        let decoded: KeyboardMeetingItem = try JSONDecoder().decode(KeyboardMeetingItem.self, from: old)
        #expect(decoded.decisions == nil)
        let context: [KeyboardAskMeeting] = keyboardAskContext(meetings: [decoded, item(1, summary: "Short")], budgetBytes: 20_000, summaryMaxChars: 100, maxMeetings: 20)
        #expect(context.map(\.title) == ["Meeting 1", "T"])
        #expect(context.last?.decisions == [])
    }

    @Test func retriesOnlyWhenTheRequestNeverLeft() {
        #expect(keyboardAskShouldRetry(failure: .notConnected))
        #expect(!keyboardAskShouldRetry(failure: .noResponse))
        #expect(!keyboardAskShouldRetry(failure: .status(502)))
        #expect(!keyboardAskShouldRetry(failure: .status(503)))
        #expect(!keyboardAskShouldRetry(failure: .status(429)))
        #expect(!keyboardAskShouldRetry(failure: .status(401)))
    }

    @Test func failuresTellWhatHelps() {
        #expect(keyboardAskDirectProblem(failure: .notConnected) == .unreachable)
        #expect(keyboardAskDirectProblem(failure: .noResponse) == .slow)
        #expect(keyboardAskDirectProblem(failure: .status(401)) == .renewToken)
        #expect(keyboardAskDirectProblem(failure: .status(402)) == .notAvailable)
        #expect(keyboardAskDirectProblem(failure: .status(403)) == .notAvailable)
        #expect(keyboardAskDirectProblem(failure: .status(429)) == .notAvailable)
        #expect(keyboardAskDirectProblem(failure: .status(500)) == .failed)
        #expect(keyboardAskDirectProblem(failure: .status(400)) == .failed)
    }

    @Test func caretBlinksUnlessReduceMotion() {
        #expect(keyboardAskCaretIsVisible(elapsed: 0.1, reduceMotion: false))
        #expect(!keyboardAskCaretIsVisible(elapsed: 0.6, reduceMotion: false))
        #expect(keyboardAskCaretIsVisible(elapsed: 1.1, reduceMotion: false))
        #expect(keyboardAskCaretIsVisible(elapsed: 0.6, reduceMotion: true))
    }
}
