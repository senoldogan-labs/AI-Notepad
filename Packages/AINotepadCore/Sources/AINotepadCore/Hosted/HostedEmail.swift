import Foundation

// Opt-in tips and reminder emails (`server/src/email/subscriptions.ts`; spec
// docs/superpowers/specs/2026-11-26-lifecycle-email.md). Off by default: the user types an address in Settings › Account
// (or the one-time card after sign-in), the server sends a confirmation link and only after it is clicked sends the
// emails. The app never reads an address from the sign-in.

/// Version of the opt-in wording the apps show; same as the server's `emailConsentVersion`.
public let hostedEmailConsentVersion: Int = 1

/// Where the subscription stands.
public enum HostedEmailStatus: String, Decodable, Sendable, Equatable {
    case off
    case pending
    case confirmed
}

/// `GET /v1/me/email` (and the answer of `PUT` and `DELETE`).
public struct HostedEmailState: Decodable, Sendable, Equatable {
    /// The opt-in is offered to this account (the server's switch); the apps hide it otherwise.
    public let available: Bool
    public let status: HostedEmailStatus
    /// The confirmed address; nil until one is confirmed.
    public let address: String?
    /// An address waiting for its confirmation link.
    public let pendingAddress: String?

    public init(available: Bool, status: HostedEmailStatus, address: String?, pendingAddress: String?) {
        self.available = available
        self.status = status
        self.address = address
        self.pendingAddress = pendingAddress
    }
}

/// `PUT /v1/me/email` body.
struct HostedEmailOptInBody: Encodable {
    let address: String
    let locale: String
    let consentVersion: Int
}

/// `PUT /v1/me/email` is retried only when the request surely never reached the server: each attempt can send an email,
/// and the server's `rate_limited` here is the per-recipient limit, not a busy server. Pure function.
public func isRetryableEmailOptIn(failure: HostedAttemptFailure) -> Bool {
    if case .network(let code) = failure {
        return isSafeToRetryPost(code: code)
    }
    return false
}

/// The language the emails are written in: the app's own language (`Bundle.preferredLocalizations.first`, e.g. "de",
/// "pt-BR"); the server falls back to English for one it doesn't write. Pure function.
public func hostedEmailLocale(preferredLocalizations: [String]) -> String {
    preferredLocalizations.first ?? "en"
}

/// The address as typed, trimmed, looks like one (`name@domain.tld`, no spaces); the server checks it fully. Pure function.
public func hostedEmailAddressLooksValid(_ text: String) -> Bool {
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count <= 254, !trimmed.contains(where: { (character: Character) -> Bool in character.isWhitespace }) else {
        return false
    }
    let parts: [Substring] = trimmed.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, let local = parts.first, let domain = parts.last, !local.isEmpty else {
        return false
    }
    let labels: [Substring] = domain.split(separator: ".", omittingEmptySubsequences: false)
    return labels.count >= 2 && labels.allSatisfy { (label: Substring) -> Bool in !label.isEmpty } && (labels.last?.count ?? 0) >= 2
}

/// The one-time card after sign-in shows: the account is in its trial (the card offers a reminder before it ends; a paying
/// account would only get the welcome), the feature is offered, the user hasn't opted in, and hasn't closed the card on
/// this device. Pure function.
public func hostedEmailPromptVisible(state: HostedEmailState?, dismissed: Bool, onTrial: Bool) -> Bool {
    guard let state, !dismissed, onTrial else {
        return false
    }
    return state.available && state.status == .off
}
