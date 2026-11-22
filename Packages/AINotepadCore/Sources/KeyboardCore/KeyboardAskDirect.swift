import Foundation
import Security

/// "Ask Gistsmith" from the keyboard without opening Gistsmith: with Full Access the keyboard asks the server itself
/// (`POST /v1/keyboard/ask`, `server/src/keyboardAsk.ts`) with its own token. Gistsmith mints the token with its session
/// (`POST /v1/keyboard/token`) and keeps it in the keychain item `KeyboardAskTokenKeychain` shares through the App Group;
/// the account's own session never reaches the keyboard. Only the question and (without the server's assistant copy) a
/// budgeted copy of recent meeting notes are sent; the question and answer are never logged.
public struct KeyboardAskToken: Sendable, Hashable, Codable {
    /// The keyboard token (only `/v1/keyboard/ask` accepts it).
    public let token: String
    public let expiresAt: Date
    /// The server answers from the account's AI assistant copy (all meetings): the keyboard need not send its own copy.
    public let serverContext: Bool
    /// Gistsmith's server (Debug and Release differ).
    public let baseURL: URL

    public init(token: String, expiresAt: Date, serverContext: Bool, baseURL: URL) {
        self.token = token
        self.expiresAt = expiresAt
        self.serverContext = serverContext
        self.baseURL = baseURL
    }
}

/// The server's keyboard token lifetime (`keyboardTokenTtlSeconds`).
public let keyboardAskTokenLifetime: TimeInterval = 7 * 24 * 60 * 60
/// Gistsmith renews a token older than this when it comes to the front.
public let keyboardAskTokenRenewalAge: TimeInterval = 24 * 60 * 60
/// A token this close to expiry is not used: the question would fail on the way.
public let keyboardAskTokenExpiryMargin: TimeInterval = 60
/// How long the keyboard waits for an answer (one model call of up to ~10k input tokens, not streamed).
public let keyboardAskDirectTimeout: TimeInterval = 45
/// The budget of the meeting copy the keyboard sends (the server accepts 32 KB bodies).
public let keyboardAskContextBudgetBytes: Int = 20 * 1024
/// Longest summary of one meeting in that copy (characters).
public let keyboardAskSummaryMaxChars: Int = 1500
/// Most meetings in that copy (the server's `keyboardAskMaxMeetings`).
public let keyboardAskMaxMeetings: Int = 20

/// How a question from the keyboard is answered.
public enum KeyboardAskRoute: Sendable, Hashable {
    /// Gistsmith's microphone session runs: Gistsmith is alive and answers with the full Ask, nothing opens.
    case appSession
    /// The keyboard asks the server itself.
    case direct
    /// Gistsmith opens and answers.
    case openApp
}

/// The route of a question: a live session first (the app's full Ask over every meeting), then the server directly
/// when the keyboard has Full Access, a token that is not about to expire and notes to answer from (the server's
/// assistant copy or the keyboard's meeting copy; the keyboard sends its copy whenever it has one, since the server's
/// may have been turned off after the token was minted), otherwise Gistsmith opens. Pure function.
public func keyboardAskRoute(sessionIsLive: Bool, hasFullAccess: Bool, token: KeyboardAskToken?, hasLocalContext: Bool, now: Date) -> KeyboardAskRoute {
    if sessionIsLive {
        return .appSession
    }
    guard hasFullAccess, let token, token.expiresAt.timeIntervalSince(now) > keyboardAskTokenExpiryMargin else {
        return .openApp
    }
    return token.serverContext || hasLocalContext ? .direct : .openApp
}

/// Whether Gistsmith should mint a new token: none yet, or the current one is older than `keyboardAskTokenRenewalAge`
/// (its expiry is closer than the lifetime minus that age). Pure function.
public func keyboardAskTokenNeedsRenewal(token: KeyboardAskToken?, now: Date) -> Bool {
    guard let token else {
        return true
    }
    return token.expiresAt.timeIntervalSince(now) < keyboardAskTokenLifetime - keyboardAskTokenRenewalAge
}

/// One meeting of the copy the keyboard sends (`/v1/keyboard/ask` `meetings`).
public struct KeyboardAskMeeting: Sendable, Hashable, Codable {
    public let title: String
    public let date: Date
    public let summary: String
    public let decisions: [String]
    public let openQuestions: [String]
    public let myTasks: [String]
    public let actionItems: [String]

    public init(title: String, date: Date, summary: String, decisions: [String], openQuestions: [String], myTasks: [String], actionItems: [String]) {
        self.title = title
        self.date = date
        self.summary = summary
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.myTasks = myTasks
        self.actionItems = actionItems
    }
}

/// Body of `/v1/keyboard/ask`.
public struct KeyboardAskRequestBody: Sendable, Hashable, Codable {
    public let question: String
    public let meetings: [KeyboardAskMeeting]

    public init(question: String, meetings: [KeyboardAskMeeting]) {
        self.question = question
        self.meetings = meetings
    }
}

/// Answer of `/v1/keyboard/ask`.
public struct KeyboardAskResponseBody: Sendable, Hashable, Codable {
    public let answer: String
}

/// A text cut to `maxChars` characters (an ellipsis marks the cut). Pure function.
func keyboardAskTrimmed(_ text: String, maxChars: Int) -> String {
    let clean: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.count <= maxChars ? clean : String(clean.prefix(maxChars - 1)) + "…"
}

/// UTF-8 size of a meeting as the copy sends it, plus JSON field names and punctuation. Pure function.
func keyboardAskMeetingBytes(_ meeting: KeyboardAskMeeting) -> Int {
    let texts: [String] = [meeting.title, meeting.summary] + meeting.decisions + meeting.openQuestions + meeting.myTasks + meeting.actionItems
    return texts.reduce(160) { (sum: Int, text: String) -> Int in sum + text.utf8.count + 8 }
}

/// The meeting copy the keyboard sends: newest meetings first, each summary cut to `summaryMaxChars`, with decisions,
/// open questions, the user's tasks and the action items, at most `maxMeetings` and `budgetBytes` in all (a meeting that
/// does not fit ends the copy). Pure function.
public func keyboardAskContext(meetings: [KeyboardMeetingItem], budgetBytes: Int, summaryMaxChars: Int, maxMeetings: Int) -> [KeyboardAskMeeting] {
    var picked: [KeyboardAskMeeting] = []
    var used: Int = 0
    for item in meetings.sorted(by: { $0.date > $1.date }).prefix(maxMeetings) {
        let meeting: KeyboardAskMeeting = KeyboardAskMeeting(
            title: keyboardAskTrimmed(item.title, maxChars: 280), date: item.date,
            summary: keyboardAskTrimmed(item.summary, maxChars: summaryMaxChars),
            decisions: (item.decisions ?? []).prefix(10).map { keyboardAskTrimmed($0, maxChars: 300) },
            openQuestions: (item.openQuestions ?? []).prefix(10).map { keyboardAskTrimmed($0, maxChars: 300) },
            myTasks: item.myTasks.prefix(15).map { keyboardAskTrimmed($0, maxChars: 300) },
            actionItems: item.actionItems.prefix(15).map { keyboardAskTrimmed($0, maxChars: 300) }
        )
        let size: Int = keyboardAskMeetingBytes(meeting)
        guard used + size <= budgetBytes else {
            break
        }
        picked.append(meeting)
        used += size
    }
    return picked
}

/// How one attempt of a direct question failed.
public enum KeyboardAskAttemptFailure: Error, Sendable, Hashable {
    /// The request never reached the server (offline, host not found, connection refused).
    case notConnected
    /// The request was sent but no answer came back in time, or the connection broke on the way: the server may still
    /// answer and charge it.
    case noResponse
    /// The server answered with this HTTP status.
    case status(Int)
    /// The server answered (and charged) but the answer could not be read.
    case unreadableAnswer
}

/// Whether a failed attempt is tried once more: only when the request never reached the server. A timeout or a lost
/// connection is not retried (the server finishes and charges the call even when the keyboard stops waiting), and no
/// HTTP error is (a 429 limit holds for a while; on a 5xx the server may already have charged the call). Pure function.
public func keyboardAskShouldRetry(failure: KeyboardAskAttemptFailure) -> Bool {
    failure == .notConnected
}

/// What the keyboard tells the user after a direct question failed.
public enum KeyboardAskDirectProblem: Sendable, Hashable {
    /// The server could not be reached (offline).
    case unreachable
    /// No answer in time: the server may still answer (and charge it), so the keyboard offers no way to ask it again.
    case slow
    /// The keyboard's token was refused (expired, signed out): opening Gistsmith renews it.
    case renewToken
    /// The plan, trial, consent or a limit refuses the question: asking again won't help.
    case notAvailable
    /// Anything else: asking again may work.
    case failed
}

/// The problem of a failed direct question. Pure function.
public func keyboardAskDirectProblem(failure: KeyboardAskAttemptFailure) -> KeyboardAskDirectProblem {
    switch failure {
    case .notConnected:
        return .unreachable
    case .noResponse:
        return .slow
    case .status(401):
        return .renewToken
    case .status(402), .status(403), .status(429):
        return .notAvailable
    case .status, .unreadableAnswer:
        return .failed
    }
}

/// Whether the keyboard offers to ask a failed question again in Gistsmith: not when the server may already have
/// charged it (no answer in time, an answer that couldn't be read), so one tap never charges a question twice.
/// Pure function.
public func keyboardAskCanAskAgain(failure: KeyboardAskAttemptFailure) -> Bool {
    failure != .noResponse && failure != .unreadableAnswer
}

/// Whether the blinking caret of the question field is drawn `elapsed` seconds after it appeared: on for 0.53 s, off for
/// 0.53 s, like UIKit's; always on under Reduce Motion. Pure function.
public func keyboardAskCaretIsVisible(elapsed: TimeInterval, reduceMotion: Bool) -> Bool {
    reduceMotion || Int((max(0, elapsed) / 0.53).rounded(.down)) % 2 == 0
}

/// A keychain operation on the keyboard token failed.
public enum KeyboardAskTokenError: Error, Equatable {
    case keychain(operation: String, status: Int32)
}

/// The keyboard token in the keychain, in the App Group's access group (iOS treats App Groups as keychain access
/// groups): Gistsmith writes it, the keyboard (with Full Access) reads it. Only this item uses that group; the app's
/// own session and sync key stay in its default group. Readable after the first unlock, on this device only (not in
/// backups, not synced).
public struct KeyboardAskTokenKeychain: Sendable {
    let accessGroup: String
    private let service: String = "com.senoldogan.AINotepad.keyboard-ask"
    private let account: String = "keyboard-token"

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The stored token; nil when there is none.
    public func read() throws -> KeyboardAskToken? {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyboardAskTokenError.keychain(operation: "read", status: status)
        }
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KeyboardAskToken.self, from: data)
    }

    /// Replaces the stored token.
    public func save(_ token: KeyboardAskToken) throws {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data = try encoder.encode(token)
        try delete()
        var item: [String: Any] = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status: OSStatus = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyboardAskTokenError.keychain(operation: "save", status: status)
        }
    }

    /// Removes the stored token (nothing to remove is fine).
    public func delete() throws {
        let status: OSStatus = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyboardAskTokenError.keychain(operation: "delete", status: status)
        }
    }
}
