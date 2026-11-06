import Foundation
import os

private let assistantClientLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Assistant")

/// Timeout of the assistant requests (an upload is at most `assistantUploadMaxBytes`).
private let assistantRequestTimeoutSec: Double = 60

/// AI assistant access failures the apps handle themselves (other server errors stay `HostedAPIError`).
public enum HostedAssistantError: Error, Sendable, Equatable {
    /// The server has the feature turned off (`ASSISTANT_POLICY=off`): the apps hide it.
    case unavailable
    /// The feature is off for the account.
    case notEnabled
    /// The upload names an old epoch: the feature was turned off (and maybe on again) meanwhile.
    case epochMismatch
    /// The account's copy is full (meetings or bytes).
    case quotaExceeded
    /// A meeting's copy is over `assistantUploadMaxBytes`; refused before sending.
    case copyTooLarge(meetingID: String, byteCount: Int)
}

/// `GET`/`PUT /v1/assistant/settings`.
public struct HostedAssistantSettings: Sendable, Equatable, Codable {
    public let enabled: Bool
    /// Uploads name this epoch; it changes whenever the feature is turned off.
    public let epoch: Int64
    /// Meetings in the account's copy (from every device).
    public let meetings: Int
    public let maxMeetings: Int

    public init(enabled: Bool, epoch: Int64, meetings: Int, maxMeetings: Int) {
        self.enabled = enabled
        self.epoch = epoch
        self.meetings = meetings
        self.maxMeetings = maxMeetings
    }
}

/// A connected assistant (`GET /v1/assistant/grants`).
public struct HostedAssistantGrant: Sendable, Equatable, Codable, Identifiable {
    public let grantId: String
    /// The client's registered name (unverified clients choose it themselves).
    public let clientName: String
    /// Host of the client's redirect URI (e.g. `claude.ai`).
    public let redirectHost: String
    /// An allowlisted product (Claude, ChatGPT, Cursor…).
    public let verified: Bool
    public let createdAt: Date
    public let lastUsedAt: Date?
    /// When the connection read more than 100 meetings within an hour; nil otherwise.
    public let heavyReadAt: Date?

    public var id: String { grantId }

    public init(grantId: String, clientName: String, redirectHost: String, verified: Bool, createdAt: Date, lastUsedAt: Date?, heavyReadAt: Date?) {
        self.grantId = grantId
        self.clientName = clientName
        self.redirectHost = redirectHost
        self.verified = verified
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.heavyReadAt = heavyReadAt
    }
}

/// The calls the uploader and the settings make (a protocol so tests can stand in for the server).
public protocol HostedAssistantAPI: Sendable {
    func settings() async throws -> HostedAssistantSettings
    func setEnabled(enabled: Bool) async throws -> HostedAssistantSettings
    func putMeeting(meetingID: String, upload: AssistantMeetingUpload) async throws
    func deleteMeeting(meetingID: String) async throws
    func grants() async throws -> [HostedAssistantGrant]
    func deleteGrant(grantID: String) async throws
    /// Removes every meeting this device uploaded; returns how many.
    func deleteDevice(deviceID: String) async throws -> Int
}

/// Maps the assistant error codes to `HostedAssistantError`; other errors pass through. Pure function.
func hostedAssistantError(error: any Error) -> any Error {
    guard let apiError = error as? HostedAPIError else {
        return error
    }
    switch apiError.code {
    case .assistantUnavailable:
        return HostedAssistantError.unavailable
    case .assistantNotEnabled:
        return HostedAssistantError.notEnabled
    case .assistantEpochMismatch:
        return HostedAssistantError.epochMismatch
    case .assistantQuotaExceeded:
        return HostedAssistantError.quotaExceeded
    default:
        return apiError
    }
}

private struct EnabledBody: Encodable {
    let enabled: Bool
}

private struct GrantList: Decodable {
    let grants: [GrantBody]
}

/// Server grant body: timestamps are `toISOString()` (with milliseconds).
private struct GrantBody: Decodable {
    let grantId: String
    let clientName: String
    let redirectHost: String
    let verified: Bool
    let createdAt: String
    let lastUsedAt: String?
    let heavyReadAt: String?
}

private struct DeviceDeleteBody: Decodable {
    let deletedMeetings: Int
}

/// ISO 8601 with or without fractional seconds. Pure function.
func assistantDate(text: String) -> Date? {
    if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
        return date
    }
    return try? Date(text, strategy: .iso8601)
}

/// HTTP adapter of `/v1/assistant/…` on the API Worker (`server/src/assistant/api.ts`), with the session's app token.
/// Requests have a bounded timeout and are retried with backoff on network and temporary server errors, logging a
/// warning per attempt (`sendHostedRequest`); a rejected access token is refreshed once. Uploads are idempotent (the
/// server replaces the meeting's copy), so retrying them is safe. Nothing about content or tokens is logged.
public struct HostedAssistantClient: HostedAssistantAPI {
    public let baseURL: URL
    let credentials: any HostedAccessTokenSource

    public init(baseURL: URL, credentials: any HostedAccessTokenSource) {
        self.baseURL = baseURL
        self.credentials = credentials
    }

    public func settings() async throws -> HostedAssistantSettings {
        try decode(HostedAssistantSettings.self, data: try await send(path: "/v1/assistant/settings", method: "GET", body: nil))
    }

    public func setEnabled(enabled: Bool) async throws -> HostedAssistantSettings {
        let body: Data = try JSONEncoder().encode(EnabledBody(enabled: enabled))
        let settings: HostedAssistantSettings = try decode(HostedAssistantSettings.self, data: try await send(path: "/v1/assistant/settings", method: "PUT", body: body))
        assistantClientLogger.info("Assistant access changed, enabled: \(settings.enabled, privacy: .public), epoch: \(settings.epoch, privacy: .public)")
        return settings
    }

    public func putMeeting(meetingID: String, upload: AssistantMeetingUpload) async throws {
        let body: Data = try JSONEncoder().encode(upload)
        guard body.count <= assistantUploadMaxBytes else {
            throw HostedAssistantError.copyTooLarge(meetingID: meetingID, byteCount: body.count)
        }
        _ = try await send(path: "/v1/assistant/meetings/\(meetingID)", method: "PUT", body: body)
    }

    public func deleteMeeting(meetingID: String) async throws {
        _ = try await send(path: "/v1/assistant/meetings/\(meetingID)", method: "DELETE", body: nil)
    }

    public func grants() async throws -> [HostedAssistantGrant] {
        let list: GrantList = try decode(GrantList.self, data: try await send(path: "/v1/assistant/grants", method: "GET", body: nil))
        return try list.grants.map { (body: GrantBody) -> HostedAssistantGrant in
            guard let createdAt = assistantDate(text: body.createdAt) else {
                throw HostedClientError.malformedResponse(path: "/v1/assistant/grants", status: 200, body: "createdAt is not ISO 8601: \(body.createdAt)")
            }
            return HostedAssistantGrant(
                grantId: body.grantId, clientName: body.clientName, redirectHost: body.redirectHost, verified: body.verified, createdAt: createdAt,
                lastUsedAt: body.lastUsedAt.flatMap(assistantDate), heavyReadAt: body.heavyReadAt.flatMap(assistantDate)
            )
        }
    }

    public func deleteGrant(grantID: String) async throws {
        _ = try await send(path: "/v1/assistant/grants/\(grantID)", method: "DELETE", body: nil)
    }

    public func deleteDevice(deviceID: String) async throws -> Int {
        try decode(DeviceDeleteBody.self, data: try await send(path: "/v1/assistant/devices/\(deviceID)", method: "DELETE", body: nil)).deletedMeetings
    }

    // MARK: Requests

    /// Sends with the session's token; a 401 refreshes the token once and repeats. Assistant error codes become
    /// `HostedAssistantError`.
    private func send(path: String, method: String, body: Data?) async throws -> Data {
        do {
            return try await attempt(path: path, method: method, body: body, accessToken: try await credentials.validAccessToken())
        } catch let error as HostedAPIError where error.status == 401 {
            assistantClientLogger.warning("Assistant request token rejected, refreshing, path: \(Self.logPath(path), privacy: .public), code: \(error.rawCode, privacy: .public)")
            try await credentials.refreshAccessToken()
            do {
                return try await attempt(path: path, method: method, body: body, accessToken: try await credentials.validAccessToken())
            } catch {
                throw hostedAssistantError(error: error)
            }
        } catch {
            throw hostedAssistantError(error: error)
        }
    }

    private func attempt(path: String, method: String, body: Data?, accessToken: String) async throws -> Data {
        var request: URLRequest = URLRequest(url: baseURL.appending(path: String(path.drop { $0 == "/" })))
        request.httpMethod = method
        request.timeoutInterval = assistantRequestTimeoutSec
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let prepared: URLRequest = withHostedClientHeaders(request: request, info: credentials.clientInfo)
        return try await sendHostedRequest(path: Self.logPath(path), isRetryable: isRetryableRepeatableRequest) {
            try await URLSession.shared.data(for: prepared)
        }.data
    }

    /// Log form of a path: meeting, device and grant ids are left out.
    private static func logPath(_ path: String) -> String {
        let parts: [Substring] = path.split(separator: "/")
        guard parts.count > 3 else {
            return path
        }
        return "/" + parts.prefix(3).joined(separator: "/") + "/:id"
    }

    private func decode<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw HostedClientError.malformedResponse(path: "/v1/assistant", status: 200, body: String(describing: error))
        }
    }
}
