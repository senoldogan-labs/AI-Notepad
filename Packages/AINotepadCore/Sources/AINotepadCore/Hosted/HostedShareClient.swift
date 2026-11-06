import Foundation
import os

private let shareLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "NoteShare")

/// Timeout of the share requests (the upload is at most `noteShareMaxBytes`).
private let shareRequestTimeoutSec: Double = 60

/// A live link as the server lists it (no content: the server only has the sealed note).
public struct HostedNoteShare: Sendable, Equatable, Decodable {
    public let shareId: String
    public let size: Int
    /// Milliseconds since 1970 (server time).
    public let createdAt: Int64
    public let expiresAt: Int64
}

private struct ShareList: Decodable {
    let shares: [HostedNoteShare]
    let maxActive: Int
}

private struct ShareDeleteResponse: Decodable {
    let deleted: Bool
}

/// HTTP adapter of the share endpoints (`server/src/shares.ts`). It moves sealed blobs only: the note is sealed before
/// (`sealNoteShare`) and the key never leaves the device except inside the link. Every request has a bounded timeout and
/// is retried with backoff on network and temporary server errors, logging a warning per attempt (`sendHostedRequest`);
/// a rejected access token is refreshed once. Repeating an upload whose response was lost returns the stored link (the
/// server matches the random id). Nothing about content, keys or tokens is logged.
public struct HostedShareClient: Sendable {
    public let baseURL: URL
    let credentials: any HostedAccessTokenSource

    public init(baseURL: URL, credentials: any HostedAccessTokenSource) {
        self.baseURL = baseURL
        self.credentials = credentials
    }

    /// Uploads a sealed note under `shareID` for `expiry`. Blobs over `noteShareMaxBytes` are refused before sending.
    public func create(shareID: String, blob: Data, expiry: NoteShareExpiry) async throws -> HostedNoteShare {
        guard blob.count <= noteShareMaxBytes else {
            throw NoteShareError.tooLarge(byteCount: blob.count)
        }
        let headers: [String: String] = [
            "content-type": "application/octet-stream", "x-share-id": shareID, "x-share-expires-days": String(expiry.rawValue),
        ]
        let data: Data = try await send(path: "/v1/shares", method: "POST", body: blob, headers: headers)
        shareLogger.info("Note shared with a link, bytes: \(blob.count, privacy: .public), days: \(expiry.rawValue, privacy: .public)")
        return try decode(HostedNoteShare.self, data: data, path: "/v1/shares")
    }

    /// The account's live links, newest first.
    public func list() async throws -> [HostedNoteShare] {
        try decode(ShareList.self, data: try await send(path: "/v1/shares", method: "GET", body: nil, headers: [:]), path: "/v1/shares").shares
    }

    /// Removes a link at once (readers get "removed"); an unknown or already removed link is `not_found`.
    public func delete(shareID: String) async throws {
        let data: Data = try await send(path: "/v1/shares/\(shareID)", method: "DELETE", body: nil, headers: [:])
        _ = try decode(ShareDeleteResponse.self, data: data, path: "/v1/shares/:id")
        shareLogger.info("Shared link removed")
    }

    /// Sends with the session's token; a 401 refreshes the token once and repeats.
    private func send(path: String, method: String, body: Data?, headers: [String: String]) async throws -> Data {
        do {
            return try await attempt(path: path, method: method, body: body, headers: headers, accessToken: try await credentials.validAccessToken())
        } catch let error as HostedAPIError where error.status == 401 {
            shareLogger.warning("Share request token rejected, refreshing, code: \(error.rawCode, privacy: .public)")
            try await credentials.refreshAccessToken()
            return try await attempt(path: path, method: method, body: body, headers: headers, accessToken: try await credentials.validAccessToken())
        }
    }

    private func attempt(path: String, method: String, body: Data?, headers: [String: String], accessToken: String) async throws -> Data {
        var request: URLRequest = URLRequest(url: baseURL.appending(path: String(path.drop { $0 == "/" })))
        request.httpMethod = method
        request.timeoutInterval = shareRequestTimeoutSec
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let prepared: URLRequest = withHostedClientHeaders(request: request, info: credentials.clientInfo)
        let logPath: String = path.hasPrefix("/v1/shares/") ? "/v1/shares/:id" : path
        return try await sendHostedRequest(path: logPath, isRetryable: isRetryableRepeatableRequest) {
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
