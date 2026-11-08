import Foundation
import os

private let folderClientLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SharedFolders")

/// Timeout of shared-folder requests (an item is at most `sharedFolderItemMaxBytes`).
private let folderRequestTimeoutSec: Double = 60

/// The account's registered sharing keys (`GET /v1/sharing/identity`).
public struct HostedSharingIdentity: Sendable, Equatable, Codable {
    public let agreementKey: String
    public let signingKey: String
    public let sealedSeed: String?
    public let seedKeyId: String?

    public init(agreementKey: String, signingKey: String, sealedSeed: String?, seedKeyId: String?) {
        self.agreementKey = agreementKey
        self.signingKey = signingKey
        self.sealedSeed = sealedSeed
        self.seedKeyId = seedKeyId
    }

    /// The public keys; nil when the server sent something that is not two 32-byte keys.
    public var publicKeys: SharingPublicKeys? {
        guard let agreement = Data(base64Encoded: agreementKey), let signing = Data(base64Encoded: signingKey), agreement.count == 32, signing.count == 32 else {
            return nil
        }
        return SharingPublicKeys(agreementKey: agreement, signingKey: signing)
    }
}

private struct IdentityBody: Codable {
    let identity: HostedSharingIdentity?
}

/// A folder as `GET /v1/shared-folders` lists it (everything sealed on the devices).
public struct HostedSharedFolder: Sendable, Equatable, Decodable {
    public let folderId: String
    /// `owner` or `member`.
    public let role: String
    public let ownerAgreementKey: String
    public let ownerSigningKey: String
    public let sealedMeta: String
    public let keyEpoch: Int
    public let roster: String
    public let rosterSignature: String
    public let rosterVersion: Int
    public let membersVersion: Int
    public let itemsRev: Int
    public let needsRotation: Bool
    public let envelope: String?
    public let envelopeEpoch: Int?
    public let memberId: String?
    /// `accepted` (waiting for an owner device) or `active`; nil for the owner.
    public let memberStatus: String?
    public let sealedPin: String?
    public let publisherDevice: String?
    public let publisherSeenAt: Int64?

    public var isOwner: Bool { role == "owner" }
}

/// `GET /v1/shared-folders`.
public struct HostedSharedFolderList: Sendable, Equatable, Decodable {
    /// False while the server switch is off: the apps hide the feature (and keep their caches).
    public let available: Bool
    public let folders: [HostedSharedFolder]
}

/// An invite or member as the owner lists them (`GET /v1/shared-folders/:id/members`).
public struct HostedSharedFolderMember: Sendable, Equatable, Decodable {
    public let memberId: String
    /// `invited`, `accepted` or `active`.
    public let status: String
    public let userId: String?
    public let sealedLabel: String
    public let sealedSecret: String
    public let sealedName: String?
    public let memberProof: String?
    public let agreementKey: String?
    public let signingKey: String?
    public let envelopeEpoch: Int?
    public let createdAt: Int64
    public let expiresAt: Int64
}

private struct MemberList: Decodable {
    let members: [HostedSharedFolderMember]
}

/// An invite as the person holding the link sees it.
public struct HostedSharedFolderInvite: Sendable, Equatable, Decodable {
    public let folderId: String
    /// `open`, `own`, `accepted`, `used` or `expired`.
    public let state: String
    public let ownerAgreementKey: String
    public let ownerSigningKey: String
    public let ownerProof: String
    public let sealedPreview: String
    public let expiresAt: Int64
}

private struct ItemList: Decodable {
    let itemsRev: Int
    let items: [SharedFolderRemoteItem]
}

private struct PublisherBody: Decodable {
    let publisherDevice: String
}

/// A keyring envelope for one member in a roster change.
public struct HostedEnvelopeUpload: Sendable, Equatable, Encodable {
    public let memberId: String
    public let envelope: String

    public init(memberId: String, envelope: Data) {
        self.memberId = memberId
        self.envelope = envelope.base64EncodedString()
    }
}

/// `PUT /v1/shared-folders/:id/roster`.
public struct HostedRosterChange: Sendable, Equatable, Encodable {
    public let keyEpoch: Int
    public let expectedMembersVersion: Int
    public let roster: String
    public let rosterSignature: String
    public let sealedMeta: String?
    public let ownerEnvelope: String?
    public let envelopes: [HostedEnvelopeUpload]

    public init(keyEpoch: Int, expectedMembersVersion: Int, roster: SignedSharedFolderRoster, sealedMeta: Data?, ownerEnvelope: Data?, envelopes: [HostedEnvelopeUpload]) {
        self.keyEpoch = keyEpoch
        self.expectedMembersVersion = expectedMembersVersion
        self.roster = roster.text
        rosterSignature = roster.signature.base64EncodedString()
        self.sealedMeta = sealedMeta?.base64EncodedString()
        self.ownerEnvelope = ownerEnvelope?.base64EncodedString()
        self.envelopes = envelopes
    }

    // Absent optionals go as JSON null (the server's schema requires the keys).
    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyEpoch, forKey: .keyEpoch)
        try container.encode(expectedMembersVersion, forKey: .expectedMembersVersion)
        try container.encode(roster, forKey: .roster)
        try container.encode(rosterSignature, forKey: .rosterSignature)
        try container.encode(sealedMeta, forKey: .sealedMeta)
        try container.encode(ownerEnvelope, forKey: .ownerEnvelope)
        try container.encode(envelopes, forKey: .envelopes)
    }

    private enum CodingKeys: String, CodingKey {
        case keyEpoch, expectedMembersVersion, roster, rosterSignature, sealedMeta, ownerEnvelope, envelopes
    }
}

/// `POST /v1/shared-folders`.
public struct HostedFolderCreation: Sendable, Equatable, Encodable {
    public let folderId: String
    public let sealedMeta: String
    public let ownerEnvelope: String
    public let roster: String
    public let rosterSignature: String
    public let publisherDevice: String

    public init(folderId: String, sealedMeta: Data, ownerEnvelope: Data, roster: SignedSharedFolderRoster, publisherDevice: String) {
        self.folderId = folderId
        self.sealedMeta = sealedMeta.base64EncodedString()
        self.ownerEnvelope = ownerEnvelope.base64EncodedString()
        self.roster = roster.text
        rosterSignature = roster.signature.base64EncodedString()
        self.publisherDevice = publisherDevice
    }
}

/// `POST /v1/shared-folders/:id/invites`.
public struct HostedInviteCreation: Sendable, Equatable, Encodable {
    public let memberId: String
    public let sealedLabel: String
    public let sealedSecret: String
    public let ownerProof: String
    public let sealedPreview: String

    public init(memberId: String, sealedLabel: Data, sealedSecret: Data, ownerProof: Data, sealedPreview: Data) {
        self.memberId = memberId
        self.sealedLabel = sealedLabel.base64EncodedString()
        self.sealedSecret = sealedSecret.base64EncodedString()
        self.ownerProof = ownerProof.base64EncodedString()
        self.sealedPreview = sealedPreview.base64EncodedString()
    }
}

/// `POST /v1/shared-invites/:id/accept`.
public struct HostedInviteAcceptance: Sendable, Equatable, Encodable {
    public let memberProof: String
    public let sealedName: String
    public let sealedPin: String

    public init(memberProof: Data, sealedName: Data, sealedPin: Data) {
        self.memberProof = memberProof.base64EncodedString()
        self.sealedName = sealedName.base64EncodedString()
        self.sealedPin = sealedPin.base64EncodedString()
    }
}

private struct IdentityUpload: Encodable {
    let agreementKey: String
    let signingKey: String
    let sealedSeed: String?
    let seedKeyId: String?

    func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agreementKey, forKey: .agreementKey)
        try container.encode(signingKey, forKey: .signingKey)
        try container.encode(sealedSeed, forKey: .sealedSeed)
        try container.encode(seedKeyId, forKey: .seedKeyId)
    }

    private enum CodingKeys: String, CodingKey {
        case agreementKey, signingKey, sealedSeed, seedKeyId
    }
}

private struct DeviceBody: Encodable {
    let device: String
}

/// HTTP adapter of the shared-folder endpoints (`server/src/sharedFolders.ts`). It moves sealed values only; every
/// request has a bounded timeout and is retried with backoff on network and temporary server errors with a warning per
/// attempt (`sendHostedRequest`); a rejected access token is refreshed once. Every write is idempotent on the server (the
/// same request again answers as the first time), so a retried write is safe. Nothing about content, keys or tokens is logged.
public struct HostedSharedFolderClient: Sendable {
    public let baseURL: URL
    let credentials: any HostedAccessTokenSource

    public init(baseURL: URL, credentials: any HostedAccessTokenSource) {
        self.baseURL = baseURL
        self.credentials = credentials
    }

    public func identity() async throws -> HostedSharingIdentity? {
        try decode(IdentityBody.self, data: try await send(path: "/v1/sharing/identity", method: "GET", body: nil, headers: [:])).identity
    }

    /// Registers the keys (the first registration wins) or refreshes the sealed seed.
    public func putIdentity(keys: SharingPublicKeys, sealedSeed: Data?, seedKeyID: String?) async throws -> HostedSharingIdentity? {
        let upload: IdentityUpload = IdentityUpload(
            agreementKey: keys.agreementKey.base64EncodedString(), signingKey: keys.signingKey.base64EncodedString(),
            sealedSeed: sealedSeed?.base64EncodedString(), seedKeyId: seedKeyID
        )
        return try decode(IdentityBody.self, data: try await sendJSON(path: "/v1/sharing/identity", method: "PUT", value: upload)).identity
    }

    /// Stops sharing every owned folder, leaves every joined one and deletes the identity.
    public func resetIdentity() async throws {
        _ = try await send(path: "/v1/sharing/identity", method: "DELETE", body: nil, headers: [:])
        folderClientLogger.info("Shared folders reset")
    }

    public func folders() async throws -> HostedSharedFolderList {
        try decode(HostedSharedFolderList.self, data: try await send(path: "/v1/shared-folders", method: "GET", body: nil, headers: [:]))
    }

    public func createFolder(_ creation: HostedFolderCreation) async throws {
        _ = try await sendJSON(path: "/v1/shared-folders", method: "POST", value: creation)
        folderClientLogger.info("Shared folder created")
    }

    public func stopSharing(folderID: String) async throws {
        _ = try await send(path: "/v1/shared-folders/\(folderID)", method: "DELETE", body: nil, headers: [:])
        folderClientLogger.info("Shared folder stopped")
    }

    public func changeRoster(folderID: String, change: HostedRosterChange) async throws {
        _ = try await sendJSON(path: "/v1/shared-folders/\(folderID)/roster", method: "PUT", value: change)
        folderClientLogger.info("Shared folder roster changed, members: \(change.envelopes.count, privacy: .public)")
    }

    /// Claims publishing for this device when it already publishes or the lease ran out; returns the publisher.
    public func claimPublisher(folderID: String, deviceID: String) async throws -> String {
        try decode(PublisherBody.self, data: try await sendJSON(path: "/v1/shared-folders/\(folderID)/publisher", method: "POST", value: DeviceBody(device: deviceID))).publisherDevice
    }

    /// Takes over publishing for this device at once ("Publish from this device").
    public func takeOverPublisher(folderID: String, deviceID: String) async throws -> String {
        try decode(PublisherBody.self, data: try await sendJSON(path: "/v1/shared-folders/\(folderID)/publisher", method: "PUT", value: DeviceBody(device: deviceID))).publisherDevice
    }

    public func members(folderID: String) async throws -> [HostedSharedFolderMember] {
        try decode(MemberList.self, data: try await send(path: "/v1/shared-folders/\(folderID)/members", method: "GET", body: nil, headers: [:])).members
    }

    public func createInvite(folderID: String, invite: HostedInviteCreation) async throws {
        _ = try await sendJSON(path: "/v1/shared-folders/\(folderID)/invites", method: "POST", value: invite)
        folderClientLogger.info("Shared folder invite created")
    }

    public func revokeInvite(folderID: String, memberID: String) async throws {
        _ = try await send(path: "/v1/shared-folders/\(folderID)/invites/\(memberID)", method: "DELETE", body: nil, headers: [:])
    }

    public func leave(folderID: String) async throws {
        _ = try await send(path: "/v1/shared-folders/\(folderID)/membership", method: "DELETE", body: nil, headers: [:])
        folderClientLogger.info("Left a shared folder")
    }

    public func invite(inviteID: String) async throws -> HostedSharedFolderInvite {
        try decode(HostedSharedFolderInvite.self, data: try await send(path: "/v1/shared-invites/\(inviteID)", method: "GET", body: nil, headers: [:]))
    }

    public func acceptInvite(inviteID: String, acceptance: HostedInviteAcceptance) async throws {
        _ = try await sendJSON(path: "/v1/shared-invites/\(inviteID)/accept", method: "POST", value: acceptance)
        folderClientLogger.info("Shared folder invite accepted")
    }

    public func items(folderID: String) async throws -> (itemsRev: Int, items: [SharedFolderRemoteItem]) {
        let list: ItemList = try decode(ItemList.self, data: try await send(path: "/v1/shared-folders/\(folderID)/items", method: "GET", body: nil, headers: [:]))
        return (list.itemsRev, list.items)
    }

    public func item(folderID: String, itemID: String) async throws -> Data {
        try await send(path: "/v1/shared-folders/\(folderID)/items/\(itemID)", method: "GET", body: nil, headers: [:])
    }

    /// Uploads a sealed item from the publisher device; larger than the server accepts is refused before sending.
    public func putItem(folderID: String, itemID: String, blob: Data, epoch: Int, tag: String, deviceID: String) async throws {
        guard blob.count <= sharedFolderItemMaxBytes else {
            throw SharedFolderCryptoError.tooLarge(byteCount: blob.count)
        }
        let headers: [String: String] = [
            "content-type": "application/octet-stream", "x-item-epoch": String(epoch), "x-item-tag": tag, "x-publisher-device": deviceID,
        ]
        _ = try await send(path: "/v1/shared-folders/\(folderID)/items/\(itemID)", method: "PUT", body: blob, headers: headers)
    }

    public func deleteItem(folderID: String, itemID: String) async throws {
        _ = try await send(path: "/v1/shared-folders/\(folderID)/items/\(itemID)", method: "DELETE", body: nil, headers: [:])
    }

    private func sendJSON<Value: Encodable>(path: String, method: String, value: Value) async throws -> Data {
        try await send(path: path, method: method, body: try JSONEncoder().encode(value), headers: ["content-type": "application/json"])
    }

    /// Sends with the session's token; a 401 refreshes the token once and repeats.
    private func send(path: String, method: String, body: Data?, headers: [String: String]) async throws -> Data {
        do {
            return try await attempt(path: path, method: method, body: body, headers: headers, accessToken: try await credentials.validAccessToken())
        } catch let error as HostedAPIError where error.status == 401 {
            folderClientLogger.warning("Shared-folder request token rejected, refreshing, code: \(error.rawCode, privacy: .public)")
            try await credentials.refreshAccessToken()
            return try await attempt(path: path, method: method, body: body, headers: headers, accessToken: try await credentials.validAccessToken())
        }
    }

    private func attempt(path: String, method: String, body: Data?, headers: [String: String], accessToken: String) async throws -> Data {
        var request: URLRequest = URLRequest(url: baseURL.appending(path: String(path.drop { $0 == "/" })))
        request.httpMethod = method
        request.timeoutInterval = folderRequestTimeoutSec
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let prepared: URLRequest = withHostedClientHeaders(request: request, info: credentials.clientInfo)
        return try await sendHostedRequest(path: sharedFolderLogPath(path: path), isRetryable: isRetryableRepeatableRequest) {
            try await URLSession.shared.data(for: prepared)
        }.data
    }

    private func decode<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw HostedClientError.malformedResponse(path: "/v1/shared-folders", status: 200, body: String(describing: error))
        }
    }
}

/// The path without ids for logs. Pure function.
func sharedFolderLogPath(path: String) -> String {
    path.replacing(#/[0-9a-f-]{36}/#, with: ":id").replacing(#/shared-invites/[A-Za-z0-9_-]{22}/#, with: "shared-invites/:id")
        .replacing(#/invites/[A-Za-z0-9_-]{22}/#, with: "invites/:id")
}
