import Foundation
import Testing
@testable import AINotepadCore

// Shared folders against the local server (`wrangler dev`, `AINOTEPAD_HOSTED_E2E=1`, `AINOTEPAD_HOSTED_BASE`), with two
// real accounts and the real cryptography: the owner shares a folder, invites, the member accepts, the owner's device
// verifies and activates, the member reads the note, the owner removes the member (rotation), the removed member is
// refused and cannot open a note sealed after the removal, and stopping sharing removes everything. macOS only (the
// helpers prepare the local D1 with `Process`).
#if os(macOS)

/// In-memory identity store for the tests.
final class MemorySharingIdentityStore: SharingIdentityStore, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var seed: Data?

    func load() throws -> Data? {
        lock.withLock { seed }
    }

    func save(seed: Data) throws {
        lock.withLock { self.seed = seed }
    }

    func delete() throws {
        lock.withLock { seed = nil }
    }
}

/// A signed-in local account with its shared-folder service.
private struct FolderAccount {
    let userID: String
    let service: SharedFolderService
    let identity: SharingIdentity
}

private func folderAccount(baseURL: URL, trial: Bool) async throws -> FolderAccount {
    let refresh: String = randomToken()
    let userID: String = try insertSession(refreshToken: refresh)
    if trial {
        try executeLocalD1(sql: "UPDATE users SET trial_started_at = \(nowMs()) WHERE id = '\(userID)';")
    }
    let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(accessToken: "gecersiz", refreshToken: refresh, accessExpiresAt: Date.distantPast, userId: userID))
    let session: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: storage) { () async -> Void in }
    _ = try await awaitingAuthLimit { try await session.validAccessToken() }
    let service: SharedFolderService = SharedFolderService(client: HostedSharedFolderClient(baseURL: baseURL, credentials: session), userID: userID)
    let identity: SharingIdentity = try await service.setUpIdentity(store: MemorySharingIdentityStore(), syncKey: nil)
    return FolderAccount(userID: userID, service: service, identity: identity)
}

private func opened(_ account: FolderAccount, folderID: String) async throws -> OpenedSharedFolder {
    let list: HostedSharedFolderList = try await account.service.client.folders()
    let remote: HostedSharedFolder = try #require(list.folders.first { $0.folderId == folderID })
    return try openSharedFolder(remote: remote, identity: account.identity, storedPin: nil)
}

extension HostedE2ETests {
    @Test func sharedFolderInviteReadRemoveAndRotateAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let owner: FolderAccount = try await folderAccount(baseURL: baseURL, trial: true)
        let member: FolderAccount = try await folderAccount(baseURL: baseURL, trial: false)
        let device: String = UUID().uuidString.lowercased()
        let marker: String = "Secret-\(UUID().uuidString)"

        // A second device of the owner without the seed and without sync cannot replace the identity.
        await #expect(throws: SharedFolderSetupError.identityOnAnotherDevice) {
            try await owner.service.setUpIdentity(store: MemorySharingIdentityStore(), syncKey: nil)
        }

        let folderID: String = try await owner.service.createFolder(
            identity: owner.identity, meta: SharedFolderMeta(name: "Sales weekly", ownerName: "Ayşe", includeTranscript: false), deviceID: device
        )
        let ownerFolder: OpenedSharedFolder = try await opened(owner, folderID: folderID)
        #expect(ownerFolder.folderName == "Sales weekly" && ownerFolder.keyring?.currentEpoch == 1)
        let link: URL = try await owner.service.invite(folder: ownerFolder, identity: owner.identity, label: "mehmet@example.com", siteOrigin: try #require(URL(string: "http://localhost:8788")))

        // The member looks the invite up (owner proof checked), accepts and waits for the owner's device.
        let lookup: SharedFolderInviteLookup = try await member.service.lookUpInvite(link: link.absoluteString)
        #expect(lookup.preview == SharedFolderInvitePreview(folderName: "Sales weekly", ownerName: "Ayşe") && lookup.state == "open")
        try await member.service.accept(lookup: lookup, identity: member.identity, displayName: "Mehmet")
        let waiting: OpenedSharedFolder = try await opened(member, folderID: folderID)
        #expect(waiting.isWaitingForOwner && waiting.folderName == "Sales weekly")
        // Until confirmed, the member sees neither the roster nor the sealed metadata.
        #expect(waiting.roster == nil && waiting.remote.roster == nil && waiting.remote.sealedMeta == nil)

        // The owner's device verifies the proof and adds the member to the signed roster.
        let views: [SharedFolderMemberView] = try sharedFolderMemberViews(members: try await owner.service.client.members(folderID: folderID), identity: owner.identity, folderID: folderID)
        #expect(views.map(\.state) == [.accepted] && views.first?.label == "mehmet@example.com" && views.first?.displayName == "Mehmet")
        #expect(try await owner.service.reconcileRoster(folder: try await opened(owner, folderID: folderID), identity: owner.identity, removing: []))
        #expect(try await owner.service.reconcileRoster(folder: try await opened(owner, folderID: folderID), identity: owner.identity, removing: []) == false)

        // The owner publishes a note (the publisher path seals it); the member reads it.
        let keyring: FolderKeyring = try #require(try await opened(owner, folderID: folderID).keyring)
        let payload: SharedFolderItemPayload = sampleSharedFolderPayload(marker: marker)
        let plaintext: Data = try canonicalJSON(payload)
        let itemID: String = try sharedFolderItemID(keyring: keyring, meetingID: "20261108-100000")
        try await owner.service.client.putItem(
            folderID: folderID, itemID: itemID, blob: try sealFolderBlob(plaintext: plaintext, keyring: keyring, itemID: itemID, owner: owner.identity),
            epoch: 1, tag: try sharedFolderContentTag(keyring: keyring, plaintext: plaintext), deviceID: device
        )
        let memberFolder: OpenedSharedFolder = try await opened(member, folderID: folderID)
        let notes: [SharedFolderCachedItem] = try await member.service.readNotes(folder: memberFolder, cached: [])
        #expect(notes.map(\.payload) == [payload])
        // The server's copy never holds the plaintext.
        let stored: [StoredFolderRow] = try localD1Rows(sql: "SELECT sealed_meta AS sealed FROM shared_folders WHERE folder_id = '\(folderID)';", as: StoredFolderRow.self)
        #expect(stored.count == 1 && stored.first?.sealed.contains("Sales") == false)

        // Removal: rotation to epoch 2 without the member; the member is refused at once.
        let memberID: String = try #require(views.first?.memberID)
        #expect(try await owner.service.reconcileRoster(folder: try await opened(owner, folderID: folderID), identity: owner.identity, removing: [memberID]))
        let rotated: OpenedSharedFolder = try await opened(owner, folderID: folderID)
        #expect(rotated.keyring?.currentEpoch == 2 && rotated.roster?.members.isEmpty == true)
        #expect(try await member.service.client.folders().folders.isEmpty)
        await #expect(throws: HostedAPIError.self) { try await member.service.client.items(folderID: folderID) }
        // A note sealed after the removal does not open with the keyring the member had.
        let later: Data = try sealFolderBlob(plaintext: plaintext, keyring: try #require(rotated.keyring), itemID: itemID, owner: owner.identity)
        let oldKeyring: FolderKeyring = try #require(memberFolder.keyring)
        #expect(throws: SharedFolderCryptoError.unknownEpoch(epoch: 2)) {
            try openFolderBlob(blob: later, keyring: oldKeyring, itemID: itemID, ownerSigningKey: owner.identity.publicKeys.signingKey)
        }

        try await owner.service.client.stopSharing(folderID: folderID)
        #expect(try await owner.service.client.folders().folders.isEmpty)
    }
}

/// A sealed column as stored.
private struct StoredFolderRow: Decodable {
    let sealed: String
}

#endif
