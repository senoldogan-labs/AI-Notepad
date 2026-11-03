import Foundation
import os

private let syncLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Sync")

/// Timeout of the small JSON sync requests.
private let syncJSONTimeoutSec: Double = 30
/// Timeout of object uploads and downloads (up to `SyncLimits.objectMaxBytes`).
private let syncObjectTimeoutSec: Double = 60

/// The signed-in session's access token (`HostedClient`); sync requests use it like every other account request.
public protocol HostedAccessTokenSource: AnyObject, Sendable {
    /// Version headers added to every request.
    nonisolated var clientInfo: HostedClientInfo { get }
    /// A valid (refreshed if needed) access token; `notSignedIn` without a session.
    func validAccessToken() async throws -> String
    /// Refreshes the access token regardless of its expiry (the server rejected it with 401).
    func refreshAccessToken() async throws
}

extension HostedClient: HostedAccessTokenSource {}

/// Sync failures the sync engine handles itself (other server errors stay `HostedAPIError`).
public enum HostedSyncError: Error, Sendable, Equatable {
    /// The object changed on another device since `baseRevision`: download, merge, retry.
    case conflict(objectID: String)
    /// The change cursor is stale (sync was reset, or deletes past it were purged): sync again from 0.
    case cursorExpired
    /// This device's key is not the account's key: get it by pairing or with the recovery code.
    case keyMismatch
    /// Sync is off for the account.
    case notEnabled
    /// The account's server copy is full.
    case quotaExceeded
    /// The server has sync turned off (`SYNC_POLICY=off`).
    case unavailable
    /// The object does not exist (or is deleted) on the server.
    case objectNotFound(objectID: String)
    /// The upload is over `SyncLimits.objectMaxBytes`; refused before sending.
    case objectTooLarge(objectID: String, byteCount: Int)
}

/// `GET`/`POST /v1/sync/account`.
public struct HostedSyncAccount: Sendable, Equatable, Decodable {
    public let enabled: Bool
    public let keyId: String?
    /// Changes whenever sync is turned on again; a cursor from another epoch is stale.
    public let epoch: Int64?
    public let lastRev: UInt64
    public let objects: Int
    public let storedBytes: Int
    public let maxObjects: Int
    public let maxBytes: Int
}

/// One entry of the change feed.
public struct HostedSyncChange: Sendable, Equatable, Decodable {
    public let objectId: String
    public let kind: SyncObjectKind
    public let rev: UInt64
    public let size: Int
    public let deleted: Bool
    /// Milliseconds since 1970 (server time).
    public let updatedAt: Int64
}

/// A page of the change feed.
public struct HostedSyncChanges: Sendable, Equatable, Decodable {
    public let keyId: String
    public let epoch: Int64
    public let changes: [HostedSyncChange]
    /// Pass as `since` for the next page.
    public let cursor: UInt64
    public let hasMore: Bool
}

/// A downloaded object: the sealed blob and the revision and kind the server stores it as.
public struct HostedSyncObject: Sendable, Equatable {
    public let objectID: String
    public let kind: SyncObjectKind
    public let revision: UInt64
    public let blob: Data
}

/// Result of a write or delete.
public struct HostedSyncWrite: Sendable, Equatable, Decodable {
    public let objectId: String
    public let rev: UInt64
}

/// A key envelope kind (server `syncEnvelopeKinds`).
public enum SyncEnvelopeKind: String, Sendable, Codable, CaseIterable {
    /// The account key sealed with the recovery code.
    case recovery
    /// An "add a device" message (10-minute lifetime).
    case pairing
}

/// A stored key envelope (base64 `ciphertext`).
public struct HostedSyncEnvelope: Sendable, Equatable, Decodable {
    public let envelopeId: String
    public let kind: SyncEnvelopeKind
    public let ciphertext: String
    public let createdAt: Int64
    public let expiresAt: Int64?
}

private struct EnableBody: Encodable {
    let keyId: String
}

private struct EnvelopeBody: Encodable {
    let kind: SyncEnvelopeKind
    let ciphertext: String
}

private struct EnvelopeList: Decodable {
    let envelopes: [HostedSyncEnvelope]
}

private struct WipeResponse: Decodable {
    let deleted: Bool
    let objects: Int
}

private struct EnvelopeDeleteResponse: Decodable {
    let deleted: Bool
}

/// Maps the sync error codes to `HostedSyncError`; other errors pass through. Pure function.
func hostedSyncError(error: any Error, objectID: String?) -> any Error {
    guard let apiError = error as? HostedAPIError else {
        return error
    }
    switch apiError.code {
    case .syncConflict:
        return HostedSyncError.conflict(objectID: objectID ?? "")
    case .syncCursorExpired:
        return HostedSyncError.cursorExpired
    case .syncKeyMismatch:
        return HostedSyncError.keyMismatch
    case .syncNotEnabled:
        return HostedSyncError.notEnabled
    case .syncQuotaExceeded:
        return HostedSyncError.quotaExceeded
    case .syncUnavailable:
        return HostedSyncError.unavailable
    case .notFound where objectID != nil:
        return HostedSyncError.objectNotFound(objectID: objectID ?? "")
    default:
        return apiError
    }
}

/// HTTP adapter of the sync endpoints (`server/src/sync.ts`). It moves sealed blobs and envelopes only: encryption
/// happens before (`SyncCrypto`), merging after (`SyncMerge`). Every request has a bounded timeout and is retried with
/// backoff on network and temporary server errors, logging a warning per attempt (`sendHostedRequest`); a rejected
/// access token is refreshed once. Writes carry `If-Match`, so retrying a write whose response was lost answers
/// `conflict` instead of writing twice. Nothing about content, keys or tokens is logged.
public struct HostedSyncClient: Sendable {
    public let baseURL: URL
    let credentials: any HostedAccessTokenSource
    /// This device's random sync id (`x-sync-device`; the server stores it as the uploader).
    public let deviceID: String

    public init(baseURL: URL, credentials: any HostedAccessTokenSource, deviceID: String) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.deviceID = deviceID
    }

    // MARK: Account

    /// Whether sync is on for the account, with its key id, epoch and usage.
    public func account() async throws -> HostedSyncAccount {
        try decode(HostedSyncAccount.self, data: try await send(path: "/v1/sync/account", method: "GET", body: nil, headers: [:], objectID: nil, timeoutSec: syncJSONTimeoutSec).data)
    }

    /// Turns sync on with this device's key id (harmless to repeat); another key on the account is `keyMismatch`.
    public func enable(keyID: String) async throws -> HostedSyncAccount {
        let body: Data = try JSONEncoder().encode(EnableBody(keyId: keyID))
        let response = try await send(path: "/v1/sync/account", method: "POST", body: body, headers: ["content-type": "application/json"], objectID: nil, timeoutSec: syncJSONTimeoutSec)
        syncLogger.info("Sync turned on")
        return try decode(HostedSyncAccount.self, data: response.data)
    }

    /// Turns sync off and deletes the account's whole server copy (local meetings stay). Returns how many objects
    /// were deleted.
    public func disableAndWipe() async throws -> Int {
        let response = try await send(path: "/v1/sync/account", method: "DELETE", body: nil, headers: [:], objectID: nil, timeoutSec: syncJSONTimeoutSec)
        let wiped: WipeResponse = try decode(WipeResponse.self, data: response.data)
        syncLogger.info("Sync turned off, server copy deleted, objects: \(wiped.objects, privacy: .public)")
        return wiped.objects
    }

    // MARK: Objects

    /// One page of changes after `since` (0 for everything). `epoch` is the account epoch the cursor belongs to (nil
    /// with `since` 0). A stale cursor is `cursorExpired`.
    public func changes(since: UInt64, epoch: Int64?, limit: Int) async throws -> HostedSyncChanges {
        var query: String = "since=\(since)&limit=\(min(max(limit, 1), SyncLimits.changesMaxLimit))"
        if let epoch {
            query += "&epoch=\(epoch)"
        }
        let response = try await send(path: "/v1/sync/changes?\(query)", method: "GET", body: nil, headers: [:], objectID: nil, timeoutSec: syncJSONTimeoutSec)
        return try decode(HostedSyncChanges.self, data: response.data)
    }

    /// Downloads an object's current blob with its revision and kind; deleted or unknown is `objectNotFound`.
    public func object(objectID: String) async throws -> HostedSyncObject {
        let path: String = "/v1/sync/objects/\(objectID)"
        let response = try await send(path: path, method: "GET", body: nil, headers: [:], objectID: objectID, timeoutSec: syncObjectTimeoutSec)
        guard let revisionText = response.headers["x-sync-rev"], let revision = UInt64(revisionText),
              let kindText = response.headers["x-sync-kind"], let kind = SyncObjectKind(rawValue: kindText) else {
            throw HostedClientError.malformedResponse(path: path, status: response.status, body: "x-sync-rev or x-sync-kind missing")
        }
        return HostedSyncObject(objectID: objectID, kind: kind, revision: revision, blob: response.data)
    }

    /// Uploads a sealed blob replacing `baseRevision` (0 creates). Returns the new revision; a newer server version is
    /// `conflict`. Blobs over `SyncLimits.objectMaxBytes` are refused here (`objectTooLarge`).
    public func put(objectID: String, kind: SyncObjectKind, baseRevision: UInt64, blob: Data) async throws -> UInt64 {
        guard blob.count <= SyncLimits.objectMaxBytes else {
            throw HostedSyncError.objectTooLarge(objectID: objectID, byteCount: blob.count)
        }
        let headers: [String: String] = [
            "content-type": "application/octet-stream", "if-match": String(baseRevision), "x-sync-kind": kind.rawValue, "x-sync-device": deviceID,
        ]
        let response = try await send(path: "/v1/sync/objects/\(objectID)", method: "PUT", body: blob, headers: headers, objectID: objectID, timeoutSec: syncObjectTimeoutSec)
        return try decode(HostedSyncWrite.self, data: response.data).rev
    }

    /// Deletes an object at `baseRevision` (it becomes a tombstone other devices see). Returns the tombstone's
    /// revision; a newer server version is `conflict`.
    public func delete(objectID: String, baseRevision: UInt64) async throws -> UInt64 {
        let headers: [String: String] = ["if-match": String(baseRevision), "x-sync-device": deviceID]
        let response = try await send(path: "/v1/sync/objects/\(objectID)", method: "DELETE", body: nil, headers: headers, objectID: objectID, timeoutSec: syncJSONTimeoutSec)
        return try decode(HostedSyncWrite.self, data: response.data).rev
    }

    // MARK: Key envelopes

    /// The account's key envelopes (expired pairing messages excluded).
    public func envelopes() async throws -> [HostedSyncEnvelope] {
        try decode(EnvelopeList.self, data: try await send(path: "/v1/sync/envelopes", method: "GET", body: nil, headers: [:], objectID: nil, timeoutSec: syncJSONTimeoutSec).data).envelopes
    }

    /// Stores an envelope (`ciphertext` as raw bytes; sent base64). A new recovery envelope replaces the old one.
    public func putEnvelope(envelopeID: String, kind: SyncEnvelopeKind, ciphertext: Data) async throws {
        let body: Data = try JSONEncoder().encode(EnvelopeBody(kind: kind, ciphertext: ciphertext.base64EncodedString()))
        _ = try await send(
            path: "/v1/sync/envelopes/\(envelopeID)", method: "PUT", body: body, headers: ["content-type": "application/json"], objectID: nil,
            timeoutSec: syncJSONTimeoutSec
        )
    }

    /// Deletes an envelope; false if it was already gone.
    public func deleteEnvelope(envelopeID: String) async throws -> Bool {
        let response = try await send(path: "/v1/sync/envelopes/\(envelopeID)", method: "DELETE", body: nil, headers: [:], objectID: nil, timeoutSec: syncJSONTimeoutSec)
        return try decode(EnvelopeDeleteResponse.self, data: response.data).deleted
    }

    // MARK: Requests

    /// Response bytes, status and the headers sync reads.
    private struct SyncResponse: Sendable {
        let data: Data
        let status: Int
        let headers: [String: String]
    }

    /// Sends with the session's token; a 401 refreshes the token once and repeats. Sync error codes become
    /// `HostedSyncError`.
    private func send(path: String, method: String, body: Data?, headers: [String: String], objectID: String?, timeoutSec: Double) async throws -> SyncResponse {
        do {
            return try await attempt(path: path, method: method, body: body, headers: headers, accessToken: try await credentials.validAccessToken(), timeoutSec: timeoutSec)
        } catch let error as HostedAPIError where error.status == 401 {
            syncLogger.warning("Sync request token rejected, refreshing, path: \(Self.logPath(path), privacy: .public), code: \(error.rawCode, privacy: .public)")
            try await credentials.refreshAccessToken()
            do {
                return try await attempt(path: path, method: method, body: body, headers: headers, accessToken: try await credentials.validAccessToken(), timeoutSec: timeoutSec)
            } catch {
                throw hostedSyncError(error: error, objectID: objectID)
            }
        } catch {
            throw hostedSyncError(error: error, objectID: objectID)
        }
    }

    private func attempt(path: String, method: String, body: Data?, headers: [String: String], accessToken: String, timeoutSec: Double) async throws -> SyncResponse {
        var request: URLRequest = URLRequest(url: try requestURL(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeoutSec
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let prepared: URLRequest = withHostedClientHeaders(request: request, info: credentials.clientInfo)
        let headerBox: HeaderBox = HeaderBox()
        let result: (data: Data, status: Int) = try await sendHostedRequest(path: Self.logPath(path), isRetryable: isRetryableRepeatableRequest) {
            let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: prepared)
            if let http = response as? HTTPURLResponse {
                headerBox.store(headers: [
                    "x-sync-rev": http.value(forHTTPHeaderField: "x-sync-rev"), "x-sync-kind": http.value(forHTTPHeaderField: "x-sync-kind"),
                ].compactMapValues { $0 })
            }
            return (data, response)
        }
        return SyncResponse(data: result.data, status: result.status, headers: headerBox.headers())
    }

    /// The URL of a path that may carry a query string.
    private func requestURL(path: String) throws -> URL {
        let parts: [Substring] = path.split(separator: "?", maxSplits: 1)
        var components: URLComponents? = URLComponents(url: baseURL.appending(path: String(parts[0].drop { $0 == "/" })), resolvingAgainstBaseURL: false)
        if parts.count == 2 {
            components?.percentEncodedQuery = String(parts[1])
        }
        guard let url = components?.url else {
            throw HostedClientError.invalidBaseURL(value: baseURL.absoluteString)
        }
        return url
    }

    /// Log form of a path: object and envelope ids are random, but logs stay generic (no query either).
    private static func logPath(_ path: String) -> String {
        let withoutQuery: String = String(path.split(separator: "?").first ?? "")
        return withoutQuery.replacing(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, with: ":id")
    }

    private func decode<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw HostedClientError.malformedResponse(path: "/v1/sync", status: 200, body: String(describing: error))
        }
    }
}

/// Response headers of the last attempt, written inside the retry closure.
private final class HeaderBox: Sendable {
    private let stored: OSAllocatedUnfairLock<[String: String]> = OSAllocatedUnfairLock(initialState: [:])

    func store(headers: [String: String]) {
        stored.withLock { $0 = headers }
    }

    func headers() -> [String: String] {
        stored.withLock { $0 }
    }
}
