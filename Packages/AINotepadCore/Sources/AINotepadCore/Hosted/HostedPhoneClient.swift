import Foundation
import os

private let phoneLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneDialer")

/// Timeout of the dialer's JSON requests.
private let phoneRequestTimeoutSec: Double = 30
/// Timeout of a recording download (an hour of two-channel MP3 is ~60 MB).
private let phoneRecordingTimeoutSec: Double = 300

/// The current disclosure version the app shows (`phoneConsentVersion` in `server/src/phone/calls.ts`).
public let phoneDialerConsentVersion: Int = 1

/// Why the server hides the dialer.
public enum HostedPhoneUnavailableReason: String, Sendable, Decodable, Equatable {
    case policyOff = "policy_off"
    case countryNotAllowed = "country_not_allowed"
    case subscriptionRequired = "subscription_required"
}

/// The user's own number as caller ID.
public struct HostedPhoneNumber: Sendable, Decodable, Equatable {
    public enum Status: String, Sendable, Decodable, Equatable {
        case pending
        case verified
        case failed
    }

    public let e164: String
    public let status: Status

    public init(e164: String, status: Status) {
        self.e164 = e164
        self.status = status
    }
}

/// `GET /v1/phone`: whether the app shows the dialer, and the user's setup.
public struct HostedPhoneStatus: Sendable, Decodable, Equatable {
    public let available: Bool
    public let reason: HostedPhoneUnavailableReason?
    /// Allowed countries; unknown codes from a newer server are dropped.
    public let countries: [PhoneDialCountry]
    /// The voice provider named in the disclosure (`Twilio`); `nil` while off.
    public let provider: String?
    public let consentVersion: Int
    public let consentAccepted: Bool
    public let number: HostedPhoneNumber?
    public let maxCallMinutes: Int
    public let monthlyMinutes: Int
    public let usedMinutes: Int

    public init(
        available: Bool, reason: HostedPhoneUnavailableReason?, countries: [PhoneDialCountry], provider: String?, consentVersion: Int, consentAccepted: Bool,
        number: HostedPhoneNumber?, maxCallMinutes: Int, monthlyMinutes: Int, usedMinutes: Int
    ) {
        self.available = available
        self.reason = reason
        self.countries = countries
        self.provider = provider
        self.consentVersion = consentVersion
        self.consentAccepted = consentAccepted
        self.number = number
        self.maxCallMinutes = maxCallMinutes
        self.monthlyMinutes = monthlyMinutes
        self.usedMinutes = usedMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case available, reason, countries, provider, consentVersion, consentAccepted, number, maxCallMinutes, monthlyMinutes, usedMinutes
    }

    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            available: try container.decode(Bool.self, forKey: .available),
            reason: try container.decodeIfPresent(HostedPhoneUnavailableReason.self, forKey: .reason),
            countries: try container.decode([String].self, forKey: .countries).compactMap(PhoneDialCountry.init(rawValue:)),
            provider: try container.decodeIfPresent(String.self, forKey: .provider),
            consentVersion: try container.decode(Int.self, forKey: .consentVersion),
            consentAccepted: try container.decode(Bool.self, forKey: .consentAccepted),
            number: try container.decodeIfPresent(HostedPhoneNumber.self, forKey: .number),
            maxCallMinutes: try container.decode(Int.self, forKey: .maxCallMinutes),
            monthlyMinutes: try container.decode(Int.self, forKey: .monthlyMinutes),
            usedMinutes: try container.decode(Int.self, forKey: .usedMinutes)
        )
    }

    /// Call minutes left this month. Pure.
    public var remainingMinutes: Int {
        max(0, monthlyMinutes - usedMinutes)
    }
}

/// `POST /v1/phone/number`: a verification call is coming (`validationCode` is typed on its keypad), or the number is
/// already verified (no code).
public struct HostedPhoneVerification: Sendable, Decodable, Equatable {
    public let e164: String
    public let status: HostedPhoneNumber.Status
    public let validationCode: String?
    /// Milliseconds since 1970; `nil` when already verified.
    public let expiresAt: Int64?
}

/// `POST /v1/phone/calls`: what the Voice SDK connects with.
public struct HostedPhoneCallReservation: Sendable, Decodable, Equatable {
    public let callId: String
    public let accessToken: String
    public let maxSeconds: Int
    public let country: String
    public let provider: String
}

/// `GET /v1/phone/calls/:id`.
public struct HostedPhoneCallState: Sendable, Decodable, Equatable {
    public enum Status: String, Sendable, Decodable, Equatable {
        case reserved
        case dialing
        case completed
        case failed
        case expired
    }

    public enum Recording: String, Sendable, Decodable, Equatable {
        case pending
        case ready
        case absent
        case deleted
    }

    public let callId: String
    public let status: Status
    public let billedSeconds: Int?
    public let recording: Recording

    public init(callId: String, status: Status, billedSeconds: Int?, recording: Recording) {
        self.callId = callId
        self.status = status
        self.billedSeconds = billedSeconds
        self.recording = recording
    }
}

private struct ConsentBody: Encodable {
    let version: Int
}

private struct NumberBody: Encodable {
    let number: String
}

private struct CallBody: Encodable {
    let to: String
}

private struct NumberEnvelope: Decodable {
    let number: HostedPhoneNumber?
}

private struct ConsentResponse: Decodable {
    let consentAccepted: Bool
}

private struct RemovedResponse: Decodable {
    let removed: Bool
}

/// HTTP adapter of the dialer's endpoints (`server/src/phone/calls.ts`). Every request has a bounded timeout and is
/// retried with backoff on network and temporary server errors, logging a warning per attempt (`sendHostedRequest`);
/// placing a verification call and reserving a call are one-shot (a retry would ring a phone twice or reserve twice);
/// a rejected access token is refreshed once. Numbers and tokens are not logged.
public struct HostedPhoneClient: Sendable {
    public let baseURL: URL
    let credentials: any HostedAccessTokenSource

    public init(baseURL: URL, credentials: any HostedAccessTokenSource) {
        self.baseURL = baseURL
        self.credentials = credentials
    }

    /// Whether the dialer is available to this account and its setup.
    public func status() async throws -> HostedPhoneStatus {
        try decode(HostedPhoneStatus.self, data: try await send(path: "/v1/phone", method: "GET", body: nil, oneShot: false, timeoutSec: phoneRequestTimeoutSec), path: "/v1/phone")
    }

    /// Records the user's opt-in to the current disclosure.
    public func acceptConsent(version: Int) async throws {
        let data: Data = try await send(path: "/v1/phone/consent", method: "POST", body: try JSONEncoder().encode(ConsentBody(version: version)), oneShot: false, timeoutSec: phoneRequestTimeoutSec)
        _ = try decode(ConsentResponse.self, data: data, path: "/v1/phone/consent")
        phoneLogger.info("Dialer disclosure accepted, version: \(version, privacy: .public)")
    }

    /// Starts verifying the user's own number (E.164): the provider calls it.
    public func startVerification(e164: String) async throws -> HostedPhoneVerification {
        let data: Data = try await send(path: "/v1/phone/number", method: "POST", body: try JSONEncoder().encode(NumberBody(number: e164)), oneShot: true, timeoutSec: phoneRequestTimeoutSec)
        return try decode(HostedPhoneVerification.self, data: data, path: "/v1/phone/number")
    }

    /// The number's verification state; `nil` when no number is set.
    public func number() async throws -> HostedPhoneNumber? {
        try decode(NumberEnvelope.self, data: try await send(path: "/v1/phone/number", method: "GET", body: nil, oneShot: false, timeoutSec: phoneRequestTimeoutSec), path: "/v1/phone/number").number
    }

    /// Forgets the number.
    public func removeNumber() async throws {
        _ = try decode(RemovedResponse.self, data: try await send(path: "/v1/phone/number", method: "DELETE", body: nil, oneShot: false, timeoutSec: phoneRequestTimeoutSec), path: "/v1/phone/number")
    }

    /// Reserves a call to `e164` and returns the Voice SDK token.
    public func reserveCall(to e164: String) async throws -> HostedPhoneCallReservation {
        let data: Data = try await send(path: "/v1/phone/calls", method: "POST", body: try JSONEncoder().encode(CallBody(to: e164)), oneShot: true, timeoutSec: phoneRequestTimeoutSec)
        return try decode(HostedPhoneCallReservation.self, data: data, path: "/v1/phone/calls")
    }

    /// A call's state.
    public func callState(callID: String) async throws -> HostedPhoneCallState {
        try decode(HostedPhoneCallState.self, data: try await send(path: "/v1/phone/calls/\(callID)", method: "GET", body: nil, oneShot: false, timeoutSec: phoneRequestTimeoutSec), path: "/v1/phone/calls/:id")
    }

    /// Downloads the call's recording (two-channel MP3) to `destination`.
    public func downloadRecording(callID: String, destination: URL) async throws {
        let data: Data = try await send(path: "/v1/phone/calls/\(callID)/recording", method: "GET", body: nil, oneShot: false, timeoutSec: phoneRecordingTimeoutSec)
        try data.write(to: destination, options: .atomic)
        phoneLogger.info("Call recording downloaded, bytes: \(data.count, privacy: .public)")
    }

    /// Deletes the call's recording at the provider.
    public func deleteRecording(callID: String) async throws -> HostedPhoneCallState {
        let data: Data = try await send(path: "/v1/phone/calls/\(callID)/recording", method: "DELETE", body: nil, oneShot: false, timeoutSec: phoneRequestTimeoutSec)
        return try decode(HostedPhoneCallState.self, data: data, path: "/v1/phone/calls/:id/recording")
    }

    /// Sends with the session's token; a 401 refreshes the token once and repeats.
    private func send(path: String, method: String, body: Data?, oneShot: Bool, timeoutSec: Double) async throws -> Data {
        do {
            return try await attempt(path: path, method: method, body: body, oneShot: oneShot, timeoutSec: timeoutSec, accessToken: try await credentials.validAccessToken())
        } catch let error as HostedAPIError where error.status == 401 {
            phoneLogger.warning("Dialer request token rejected, refreshing, code: \(error.rawCode, privacy: .public)")
            try await credentials.refreshAccessToken()
            return try await attempt(path: path, method: method, body: body, oneShot: oneShot, timeoutSec: timeoutSec, accessToken: try await credentials.validAccessToken())
        }
    }

    private func attempt(path: String, method: String, body: Data?, oneShot: Bool, timeoutSec: Double, accessToken: String) async throws -> Data {
        var request: URLRequest = URLRequest(url: baseURL.appending(path: String(path.drop { $0 == "/" })))
        request.httpMethod = method
        request.timeoutInterval = timeoutSec
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let prepared: URLRequest = withHostedClientHeaders(request: request, info: credentials.clientInfo)
        let logPath: String = path.hasPrefix("/v1/phone/calls/") ? "/v1/phone/calls/:id" : path
        let isRetryable: @Sendable (HostedAttemptFailure) -> Bool = oneShot ? isRetryableOneShotRequest : isRetryableRepeatableRequest
        return try await sendHostedRequest(path: logPath, isRetryable: isRetryable) {
            try await URLSession.shared.data(for: prepared)
        }.data
    }

    private func decode<Value: Decodable>(_ type: Value.Type, data: Data, path: String) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw HostedClientError.malformedResponse(path: path, status: 200, body: String(describing: error))
        }
    }
}

/// What the app does next with a finished call's recording.
public enum PhoneRecordingStep: Sendable, Equatable {
    /// Ask again shortly (the provider sends the recording a few seconds after the call ends).
    case wait
    /// Download, import as a meeting, then delete it at the provider.
    case download
    /// Nothing to import (never connected, no audio, or already deleted).
    case none
}

/// The next step for a call's recording. Pure function.
public func phoneRecordingStep(state: HostedPhoneCallState) -> PhoneRecordingStep {
    switch state.recording {
    case .ready:
        .download
    case .absent, .deleted:
        .none
    case .pending:
        // Unanswered (`failed`) and lost (`expired`) calls have no recording: it starts when the callee answers.
        state.status == .expired || state.status == .failed ? .none : .wait
    }
}
