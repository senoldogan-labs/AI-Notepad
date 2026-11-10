import Foundation

// Consent to send personal data to third-party AI services (App Review 5.1.1(i) / 5.1.2(i)). Before the first AI request
// the app shows a disclosure that names what is sent (meeting audio, transcripts, notes, questions, photos and screen
// images used for notes) and to whom (Anthropic, ElevenLabs, Deepgram) and asks "Agree" / "Not now". The answer is kept
// per account on the device and recorded on the server (`PUT /v1/me/ai-consent`, see `server/src/aiConsent.ts`). Without
// it `HostedClient` refuses every AI request (`HostedClientError.aiConsentRequired`) and the server refuses this app's
// AI requests too.

/// Version of the disclosure the app shows; same as the server's `aiConsentVersion`. Version 1 was the earlier disclosure
/// that did not name the providers: agreeing to it does not count, so every user sees this one once.
public let hostedAIConsentVersion: Int = 2

/// The user's answer on this device.
public enum HostedAIConsentStatus: String, Codable, Sendable, Equatable {
    /// "Agree": AI features are on.
    case granted
    /// "Not now" on the disclosure: AI features stay off until the user agrees (no prompt at launch).
    case declined
    /// Agreed earlier, then withdrew in Settings (or on another device): AI features are off.
    case withdrawn
}

/// The answer as stored on the device (per account).
public struct HostedAIConsentRecord: Codable, Sendable, Equatable {
    public let status: HostedAIConsentStatus
    /// Disclosure version the answer was given to.
    public let version: Int
    public let decidedAt: Date
    /// The server has recorded this answer (`PUT /v1/me/ai-consent` succeeded). A declined answer is never sent.
    public let syncedToServer: Bool
    /// When the server recorded this answer (its own clock, from the `PUT` reply); nil until then and in records stored
    /// by earlier builds. Compared with the server's withdrawal time, so device clock skew does not matter.
    public let serverDecidedAt: Date?

    public init(status: HostedAIConsentStatus, version: Int, decidedAt: Date, syncedToServer: Bool, serverDecidedAt: Date?) {
        self.status = status
        self.version = version
        self.decidedAt = decidedAt
        self.syncedToServer = syncedToServer
        self.serverDecidedAt = serverDecidedAt
    }
}

/// The answer the server recorded for the account (`GET /v1/me` `aiConsent`, `PUT /v1/me/ai-consent`).
public struct HostedAIConsentServerState: Decodable, Sendable, Equatable {
    /// Disclosure version the user agreed to; nil when never agreed or withdrawn.
    public let version: Int?
    /// When the last answer reached the server; nil when no app ever sent one.
    public let decidedAt: Date?

    public init(version: Int?, decidedAt: Date?) {
        self.version = version
        self.decidedAt = decidedAt
    }
}

/// AI requests are allowed: the user agreed to the current disclosure. Pure function.
public func hostedAIConsentAllows(record: HostedAIConsentRecord?) -> Bool {
    guard let record else {
        return false
    }
    return record.status == .granted && record.version >= hostedAIConsentVersion
}

/// The disclosure is shown on its own (after sign-in, before the app): the user never answered, or agreed only to an
/// older disclosure. After "Not now" or a withdrawal it is shown only when the user reaches for an AI feature. Pure function.
public func hostedAIConsentNeedsPrompt(record: HostedAIConsentRecord?) -> Bool {
    guard let record else {
        return true
    }
    return record.status == .granted && record.version < hostedAIConsentVersion
}

/// What to do after reading the server's answer (`hostedAIConsentSync`).
public enum HostedAIConsentSyncAction: Sendable, Equatable {
    case none
    /// The device's answer has not reached the server: send it (agree or withdraw).
    case upload(granted: Bool)
    /// The user withdrew on another device after agreeing here: AI features turn off here too.
    case adoptWithdrawal
}

/// Reconciles the device's answer with the server's. An answer the server has not recorded is sent (a declined one never
/// is: it must not withdraw an agreement given on another device). An agreement the server has recorded and that the
/// server shows withdrawn later than it was given here was withdrawn elsewhere, so the device follows; an older
/// withdrawal is a stale read (an entitlements request that crossed the agreement) and is ignored. An older server
/// without the field (`server == nil`) only gets unsent answers. Pure function.
public func hostedAIConsentSync(local: HostedAIConsentRecord?, server: HostedAIConsentServerState?) -> HostedAIConsentSyncAction {
    guard let local, local.status != .declined else {
        return .none
    }
    guard local.syncedToServer else {
        return .upload(granted: local.status == .granted)
    }
    guard let server, local.status == .granted, local.version >= hostedAIConsentVersion else {
        return .none
    }
    let serverAgrees: Bool = (server.version ?? 0) >= hostedAIConsentVersion
    if serverAgrees {
        return .none
    }
    // The server has no answer at all (e.g. restored database): send the agreement again.
    guard let withdrawnAt = server.decidedAt else {
        return .upload(granted: true)
    }
    return withdrawnAt > (local.serverDecidedAt ?? local.decidedAt) ? .adoptWithdrawal : .none
}

/// Why an AI feature does nothing without consent (client gate and the server's `ai_consent_required`).
public func hostedAIConsentRequiredMessage() -> String {
    String(localized: "Yapay zekâ özellikleri kapalı. Toplantılarının hangi yapay zekâ hizmetlerine gönderildiğini okuyup onaylayınca açılır; Ayarlar'dan da açabilirsin.")
}

/// `PUT /v1/me/ai-consent` body.
struct HostedAIConsentBody: Encodable {
    let granted: Bool
    let version: Int
}
