import Foundation
import os
import Security

private let folderServiceLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SharedFolders")

// The steps of shared folders, tying the cryptography (`SharedFolderCrypto`), the pure plans (`SharedFolderModel`) and
// the HTTP adapter (`HostedSharedFolderClient`) together. Both apps and the hosted end-to-end tests run these same
// steps; the apps add only state, caching and screens.

// MARK: - Identity storage

/// Keychain account name of the sharing identity seed (inside the account's own Keychain service).
public let sharingIdentityKeychainAccount: String = "sharingIdentitySeed"

/// Where a device keeps its sharing identity seed.
public protocol SharingIdentityStore: Sendable {
    func load() throws -> Data?
    func save(seed: Data) throws
    func delete() throws
}

/// `SharingIdentityStore` over one Keychain item of the account's own service, on this device only (never iCloud
/// Keychain); on iPhone readable after the first unlock. Signing out removes the account's service with it.
public struct SharingIdentityKeychainStore: SharingIdentityStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: sharingIdentityKeychainAccount]
    }

    public func load() throws -> Data? {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(operation: "SecItemCopyMatching(sharingIdentity)", status: status)
        }
        return data
    }

    public func save(seed: Data) throws {
        let updateStatus: OSStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: seed] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(operation: "SecItemUpdate(sharingIdentity)", status: updateStatus)
        }
        var attributes: [String: Any] = baseQuery
        attributes[kSecValueData as String] = seed
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let addStatus: OSStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(operation: "SecItemAdd(sharingIdentity)", status: addStatus)
        }
    }

    public func delete() throws {
        let status: OSStatus = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(operation: "SecItemDelete(sharingIdentity)", status: status)
        }
    }
}

/// Setting up the identity on this device failed in a way the user must act on.
public enum SharedFolderSetupError: Error, Sendable, Equatable {
    /// The account's identity was set up on another device and this one cannot open it (sync is off here, or the
    /// sealed seed is under an older sync key). Open Gistsmith on that device, or reset shared folders.
    case identityOnAnotherDevice
    /// The folder's local name is not a folder on this device.
    case folderNotFound
    /// The folder is waiting for an owner device to add this account.
    case waitingForOwner
}

// MARK: - Opened folder

/// A listed folder after its signatures were checked and its sealed parts opened with this account's identity.
public struct OpenedSharedFolder: Sendable, Equatable {
    public let remote: HostedSharedFolder
    public let roster: SharedFolderRoster
    public let ownerKeys: SharingPublicKeys
    /// Nil while a member waits for activation.
    public let keyring: FolderKeyring?
    public let meta: SharedFolderMeta?
    public let folderName: String
    public let ownerName: String
    /// The version pin to store after this folder was accepted.
    public let pin: SharedFolderVersionPin

    public var folderID: String { remote.folderId }
    public var isOwner: Bool { remote.isOwner }
    public var isWaitingForOwner: Bool { keyring == nil }
}

private func decodedBase64(_ text: String) throws -> Data {
    guard let data = Data(base64Encoded: text) else {
        throw SharedFolderCryptoError.malformedBlob(byteCount: text.utf8.count)
    }
    return data
}

private func ownerKeys(remote: HostedSharedFolder) throws -> SharingPublicKeys {
    let agreement: Data = try decodedBase64(remote.ownerAgreementKey)
    let signing: Data = try decodedBase64(remote.ownerSigningKey)
    guard agreement.count == 32, signing.count == 32 else {
        throw SharedFolderCryptoError.invalidKeyLength(byteCount: agreement.count)
    }
    return SharingPublicKeys(agreementKey: agreement, signingKey: signing)
}

/// Opens a listed folder: the owner keys must be this account's (owner) or the pinned ones (member); the roster's
/// signature, its epoch and the version pin are checked; then the keyring and metadata are opened. Pure function.
public func openSharedFolder(remote: HostedSharedFolder, identity: SharingIdentity, storedPin: SharedFolderVersionPin?) throws -> OpenedSharedFolder {
    let keys: SharingPublicKeys = try ownerKeys(remote: remote)
    var memberPin: SharedFolderPin?
    if remote.isOwner {
        guard keys == identity.publicKeys else {
            throw SharedFolderCryptoError.identityMismatch
        }
    } else {
        guard let sealedPin = remote.sealedPin else {
            throw SharedFolderCryptoError.malformedBlob(byteCount: 0)
        }
        let pin: SharedFolderPin = try openSharedFolderPin(sealed: try decodedBase64(sealedPin), member: identity, folderID: remote.folderId)
        guard pin.ownerKeys == keys else {
            throw SharedFolderCryptoError.proofMismatch
        }
        memberPin = pin
    }
    let roster: SharedFolderRoster = try verifySharedFolderRoster(
        text: remote.roster, signature: try decodedBase64(remote.rosterSignature), ownerSigningKey: keys.signingKey, folderID: remote.folderId
    )
    guard roster.epoch == remote.keyEpoch, roster.version == remote.rosterVersion else {
        throw SharedFolderCryptoError.staleVersion(seen: remote.rosterVersion, served: roster.version)
    }
    let pin: SharedFolderVersionPin = try advancedSharedFolderPin(stored: storedPin, epoch: remote.keyEpoch, rosterVersion: roster.version)
    let memberID: String = remote.isOwner ? sharedFolderOwnerMemberID : (remote.memberId ?? "")
    let keyring: FolderKeyring? = try remote.envelope.map { (envelope: String) -> FolderKeyring in
        try openKeyringEnvelope(envelope: try decodedBase64(envelope), recipient: identity, folderID: remote.folderId, memberID: memberID, ownerSigningKey: keys.signingKey)
    }
    // A member whose envelope is older than the folder's epoch was rotated out (or is mid-rotation): no access.
    let current: FolderKeyring? = keyring.flatMap { $0.currentEpoch == remote.keyEpoch ? $0 : nil }
    let meta: SharedFolderMeta? = try current.map { (ring: FolderKeyring) -> SharedFolderMeta in
        try JSONDecoder().decode(
            SharedFolderMeta.self,
            from: try openFolderBlob(blob: try decodedBase64(remote.sealedMeta), keyring: ring, itemID: sharedFolderMetaItemID, ownerSigningKey: keys.signingKey)
        )
    }
    return OpenedSharedFolder(
        remote: remote, roster: roster, ownerKeys: keys, keyring: current, meta: meta,
        folderName: meta?.name ?? memberPin?.folderName ?? "", ownerName: meta?.ownerName ?? memberPin?.ownerName ?? "", pin: pin
    )
}

// MARK: - Members as the owner sees them

/// An invite or member with its sealed parts opened.
public struct SharedFolderMemberView: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// The link was made, nobody used it yet.
        case invited
        /// Someone accepted and the proof verified; an owner device adds them on its next pass.
        case accepted
        /// The proof did not verify: never added; the owner should remove it.
        case unverified
        case active
    }

    public let memberID: String
    public let state: State
    /// What the owner typed when inviting.
    public let label: String
    /// The name the member chose when accepting.
    public let displayName: String?
    public let expiresAt: Date

    public var id: String { memberID }
}

/// An acceptance's verification: the proof against the user id and keys the server reports. Pure function.
func verifiedAcceptance(member: HostedSharedFolderMember, identity: SharingIdentity, folderID: String) -> SharedFolderAcceptance? {
    guard member.status == "accepted", let userID = member.userId, let proofText = member.memberProof, let proof = Data(base64Encoded: proofText),
          let agreementText = member.agreementKey, let signingText = member.signingKey,
          let agreement = Data(base64Encoded: agreementText), let signing = Data(base64Encoded: signingText),
          let sealedSecret = Data(base64Encoded: member.sealedSecret) else {
        return nil
    }
    let keys: SharingPublicKeys = SharingPublicKeys(agreementKey: agreement, signingKey: signing)
    do {
        let invite: SharedFolderInvite = try openSharedFolderInviteSecret(sealed: sealedSecret, owner: identity, folderID: folderID, inviteID: member.memberId)
        try verifySharedFolderMemberProof(proof: proof, invite: invite, folderID: folderID, memberUserID: userID, member: keys)
    } catch {
        folderServiceLogger.warning("Shared-folder acceptance did not verify, error: \(String(describing: error), privacy: .public)")
        return nil
    }
    return SharedFolderAcceptance(member: SharedFolderRosterMember(memberId: member.memberId, userId: userID, keys: keys))
}

/// The owner's label and the member's chosen name; an invite sealed by another identity or tampered shows without them
/// (and is never activated). Pure function apart from the warning log.
private func openedInviteNames(member: HostedSharedFolderMember, identity: SharingIdentity, folderID: String) throws -> (label: String, name: String?) {
    do {
        let label: String = try openSharedFolderInviteLabel(sealed: try decodedBase64(member.sealedLabel), owner: identity, folderID: folderID, inviteID: member.memberId)
        let invite: SharedFolderInvite = try openSharedFolderInviteSecret(
            sealed: try decodedBase64(member.sealedSecret), owner: identity, folderID: folderID, inviteID: member.memberId
        )
        let name: String? = try member.sealedName.map { try openSharedFolderMemberName(sealed: try decodedBase64($0), invite: invite, folderID: folderID) }
        return (label, name)
    } catch let error as SharedFolderCryptoError {
        folderServiceLogger.warning("Shared-folder invite could not be opened, error: \(String(describing: error), privacy: .public)")
        return ("", nil)
    }
}

/// The members list with labels and names opened (labels the owner cannot open show as empty). Pure function.
public func sharedFolderMemberViews(members: [HostedSharedFolderMember], identity: SharingIdentity, folderID: String) throws -> [SharedFolderMemberView] {
    try members.map { (member: HostedSharedFolderMember) -> SharedFolderMemberView in
        let opened: (label: String, name: String?) = try openedInviteNames(member: member, identity: identity, folderID: folderID)
        let state: SharedFolderMemberView.State = switch member.status {
        case "active": .active
        case "accepted": verifiedAcceptance(member: member, identity: identity, folderID: folderID) == nil ? .unverified : .accepted
        default: .invited
        }
        return SharedFolderMemberView(
            memberID: member.memberId, state: state, label: opened.label, displayName: opened.name, expiresAt: Date(timeIntervalSince1970: Double(member.expiresAt) / 1000)
        )
    }
}

// MARK: - Invites as the invitee sees them

/// An invite after the owner proof checked out.
public struct SharedFolderInviteLookup: Sendable, Equatable {
    public let invite: SharedFolderInvite
    public let folderID: String
    /// `open`, `own`, `accepted`, `used` or `expired`.
    public let state: String
    public let preview: SharedFolderInvitePreview
    public let ownerKeys: SharingPublicKeys
}

/// A shared note cached on a member device.
public struct SharedFolderCachedItem: Sendable, Equatable, Codable {
    public let itemID: String
    public let tag: String
    public let payload: SharedFolderItemPayload

    public init(itemID: String, tag: String, payload: SharedFolderItemPayload) {
        self.itemID = itemID
        self.tag = tag
        self.payload = payload
    }
}

// MARK: - Service

/// The shared-folder steps for one signed-in account.
public struct SharedFolderService: Sendable {
    public let client: HostedSharedFolderClient
    public let userID: String

    public init(client: HostedSharedFolderClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    /// This device's identity: the stored seed, else the registered one opened with the sync key, else a new one when
    /// the account has none yet. The first registration wins; a device never replaces a registered identity. When sync
    /// is on (`syncKey`), the seed is (re)sealed under the current sync key for the account's other devices.
    public func setUpIdentity(store: any SharingIdentityStore, syncKey: SyncAccountKey?) async throws -> SharingIdentity {
        let remote: HostedSharingIdentity? = try await client.identity()
        if let seed = try store.load() {
            let identity: SharingIdentity = try sharingIdentity(seed: seed)
            if remote == nil || remote?.publicKeys == identity.publicKeys {
                try await register(identity: identity, remote: remote, syncKey: syncKey)
                return identity
            }
            folderServiceLogger.notice("Stored sharing identity differs from the account's, opening the registered one")
            try store.delete()
        }
        if let remote {
            return try openRegistered(remote: remote, store: store, syncKey: syncKey)
        }
        let fresh: SharingIdentity = try newSharingIdentity()
        try store.save(seed: fresh.seedData)
        do {
            try await register(identity: fresh, remote: nil, syncKey: syncKey)
        } catch let error as HostedAPIError where error.code == .sharedFolderConflict {
            // Another device registered first: use its identity.
            try store.delete()
            guard let registered = try await client.identity() else {
                throw error
            }
            return try openRegistered(remote: registered, store: store, syncKey: syncKey)
        }
        folderServiceLogger.info("Sharing identity created")
        return fresh
    }

    private func register(identity: SharingIdentity, remote: HostedSharingIdentity?, syncKey: SyncAccountKey?) async throws {
        let needsSeal: Bool = syncKey.map { remote?.seedKeyId != $0.keyID } ?? false
        guard remote == nil || needsSeal else {
            return
        }
        let sealed: Data? = try syncKey.map { try sealSharingSeed(identity: identity, accountKey: $0, userID: userID) }
        _ = try await client.putIdentity(keys: identity.publicKeys, sealedSeed: sealed, seedKeyID: syncKey?.keyID)
    }

    private func openRegistered(remote: HostedSharingIdentity, store: any SharingIdentityStore, syncKey: SyncAccountKey?) throws -> SharingIdentity {
        guard let syncKey, let sealedText = remote.sealedSeed, remote.seedKeyId == syncKey.keyID, let sealed = Data(base64Encoded: sealedText),
              let keys = remote.publicKeys else {
            throw SharedFolderSetupError.identityOnAnotherDevice
        }
        let identity: SharingIdentity = try openSharingSeed(sealed: sealed, accountKey: syncKey, userID: userID, expected: keys)
        try store.save(seed: identity.seedData)
        folderServiceLogger.info("Sharing identity opened from the account's sealed copy")
        return identity
    }

    /// Shares a local folder: a new keyring, sealed metadata, the owner's own envelope and an empty roster (version 1).
    public func createFolder(identity: SharingIdentity, meta: SharedFolderMeta, deviceID: String) async throws -> String {
        let folderID: String = UUID().uuidString.lowercased()
        let keyring: FolderKeyring = newFolderKeyring(folderID: folderID)
        let roster: SignedSharedFolderRoster = try signSharedFolderRoster(roster: SharedFolderRoster(folderId: folderID, version: 1, epoch: 1, members: []), owner: identity)
        try await client.createFolder(HostedFolderCreation(
            folderId: folderID, sealedMeta: try sealFolderBlob(plaintext: try canonicalJSON(meta), keyring: keyring, itemID: sharedFolderMetaItemID, owner: identity),
            ownerEnvelope: try sealKeyringEnvelope(keyring: keyring, recipient: identity.publicKeys, memberID: sharedFolderOwnerMemberID, owner: identity),
            roster: roster, publisherDevice: deviceID
        ))
        return folderID
    }

    /// Creates an invite and returns its link (the secret only in the fragment).
    public func invite(folder: OpenedSharedFolder, identity: SharingIdentity, label: String, siteOrigin: URL) async throws -> URL {
        let invite: SharedFolderInvite = newSharedFolderInvite()
        let folderID: String = folder.folderID
        try await client.createInvite(folderID: folderID, invite: HostedInviteCreation(
            memberId: invite.inviteID,
            sealedLabel: try sealSharedFolderInviteLabel(label: label, owner: identity, folderID: folderID, inviteID: invite.inviteID),
            sealedSecret: try sealSharedFolderInviteSecret(invite: invite, owner: identity, folderID: folderID),
            ownerProof: sharedFolderOwnerProof(invite: invite, folderID: folderID, owner: identity.publicKeys),
            sealedPreview: try sealSharedFolderInvitePreview(
                preview: SharedFolderInvitePreview(folderName: folder.folderName, ownerName: folder.ownerName), invite: invite, folderID: folderID
            )
        ))
        return sharedFolderInviteLink(siteOrigin: siteOrigin, invite: invite)
    }

    /// Looks up an invite link; the owner keys the server returns must match the link's proof (`proofMismatch`).
    public func lookUpInvite(link: String) async throws -> SharedFolderInviteLookup {
        let invite: SharedFolderInvite = try sharedFolderInvite(text: link)
        let remote: HostedSharedFolderInvite = try await client.invite(inviteID: invite.inviteID)
        let keys: SharingPublicKeys = try ownerKeys(agreement: remote.ownerAgreementKey, signing: remote.ownerSigningKey)
        try verifySharedFolderOwnerProof(proof: try decodedBase64(remote.ownerProof), invite: invite, folderID: remote.folderId, owner: keys)
        let preview: SharedFolderInvitePreview = try openSharedFolderInvitePreview(sealed: try decodedBase64(remote.sealedPreview), invite: invite, folderID: remote.folderId)
        return SharedFolderInviteLookup(invite: invite, folderID: remote.folderId, state: remote.state, preview: preview, ownerKeys: keys)
    }

    private func ownerKeys(agreement: String, signing: String) throws -> SharingPublicKeys {
        let agreementKey: Data = try decodedBase64(agreement)
        let signingKey: Data = try decodedBase64(signing)
        guard agreementKey.count == 32, signingKey.count == 32 else {
            throw SharedFolderCryptoError.invalidKeyLength(byteCount: agreementKey.count)
        }
        return SharingPublicKeys(agreementKey: agreementKey, signingKey: signingKey)
    }

    /// Accepts an invite: proof over this account's id and keys, the chosen name and this account's pin of the owner.
    public func accept(lookup: SharedFolderInviteLookup, identity: SharingIdentity, displayName: String) async throws {
        let pin: SharedFolderPin = SharedFolderPin(ownerKeys: lookup.ownerKeys, folderName: lookup.preview.folderName, ownerName: lookup.preview.ownerName)
        try await client.acceptInvite(inviteID: lookup.invite.inviteID, acceptance: HostedInviteAcceptance(
            memberProof: sharedFolderMemberProof(invite: lookup.invite, folderID: lookup.folderID, memberUserID: userID, member: identity.publicKeys),
            sealedName: try sealSharedFolderMemberName(name: displayName, invite: lookup.invite, folderID: lookup.folderID),
            sealedPin: try sealSharedFolderPin(pin: pin, member: identity, folderID: lookup.folderID)
        ))
    }

    /// Brings the owner-signed roster up to date: verified acceptances are added; members who left, were deleted or are
    /// in `removing` are rotated out with a new epoch. Returns whether the roster changed.
    @discardableResult
    public func reconcileRoster(folder: OpenedSharedFolder, identity: SharingIdentity, removing: Set<String>) async throws -> Bool {
        guard folder.isOwner, let keyring = folder.keyring, let meta = folder.meta else {
            return false
        }
        let members: [HostedSharedFolderMember] = try await client.members(folderID: folder.folderID)
        let acceptances: [SharedFolderAcceptance] = members.compactMap { verifiedAcceptance(member: $0, identity: identity, folderID: folder.folderID) }
        let active: Set<String> = Set(members.filter { $0.status == "active" }.map(\.memberId))
        let action: SharedFolderRosterAction = sharedFolderRosterAction(
            roster: folder.roster, serverActiveIDs: active, needsRotation: folder.remote.needsRotation, removing: removing, acceptances: acceptances
        )
        switch action {
        case .none:
            return false
        case .activate(let rosterMembers, let added):
            let roster: SignedSharedFolderRoster = try signSharedFolderRoster(
                roster: SharedFolderRoster(folderId: folder.folderID, version: folder.roster.version + 1, epoch: keyring.currentEpoch, members: rosterMembers), owner: identity
            )
            let envelopes: [HostedEnvelopeUpload] = try envelopes(keyring: keyring, members: rosterMembers.filter { added.contains($0.memberId) }, identity: identity)
            try await client.changeRoster(folderID: folder.folderID, change: HostedRosterChange(
                keyEpoch: keyring.currentEpoch, expectedMembersVersion: folder.remote.membersVersion, roster: roster, sealedMeta: nil, ownerEnvelope: nil, envelopes: envelopes
            ))
        case .rotate(let rosterMembers):
            let rotated: FolderKeyring = rotatedFolderKeyring(keyring: keyring)
            let roster: SignedSharedFolderRoster = try signSharedFolderRoster(
                roster: SharedFolderRoster(folderId: folder.folderID, version: folder.roster.version + 1, epoch: rotated.currentEpoch, members: rosterMembers), owner: identity
            )
            try await client.changeRoster(folderID: folder.folderID, change: HostedRosterChange(
                keyEpoch: rotated.currentEpoch, expectedMembersVersion: folder.remote.membersVersion, roster: roster,
                sealedMeta: try sealFolderBlob(plaintext: try canonicalJSON(meta), keyring: rotated, itemID: sharedFolderMetaItemID, owner: identity),
                ownerEnvelope: try sealKeyringEnvelope(keyring: rotated, recipient: identity.publicKeys, memberID: sharedFolderOwnerMemberID, owner: identity),
                envelopes: try envelopes(keyring: rotated, members: rosterMembers, identity: identity)
            ))
            folderServiceLogger.info("Shared folder key rotated, epoch: \(rotated.currentEpoch, privacy: .public)")
        }
        return true
    }

    private func envelopes(keyring: FolderKeyring, members: [SharedFolderRosterMember], identity: SharingIdentity) throws -> [HostedEnvelopeUpload] {
        try members.map { (member: SharedFolderRosterMember) -> HostedEnvelopeUpload in
            guard let keys = member.publicKeys else {
                throw SharedFolderCryptoError.invalidKeyLength(byteCount: 0)
            }
            return HostedEnvelopeUpload(memberId: member.memberId, envelope: try sealKeyringEnvelope(keyring: keyring, recipient: keys, memberID: member.memberId, owner: identity))
        }
    }

    /// Publishes the folder's notes from this device if it is (or may become) the publisher. Returns the ledger of item
    /// ids this device published. Does nothing while a rotation is pending or when the local folder does not exist.
    public func publish(
        folder: OpenedSharedFolder, identity: SharingIdentity, deviceID: String, records: [MeetingRecord], savedFolders: [String], ledger: Set<String>
    ) async throws -> Set<String> {
        guard folder.isOwner, let keyring = folder.keyring, let meta = folder.meta, !folder.remote.needsRotation else {
            return ledger
        }
        guard meetingFolders(records: records, saved: savedFolders).contains(where: { $0.name.caseInsensitiveCompare(meta.name) == .orderedSame }) else {
            folderServiceLogger.notice("Shared folder has no local folder on this device, not publishing")
            return ledger
        }
        guard try await client.claimPublisher(folderID: folder.folderID, deviceID: deviceID) == deviceID else {
            return ledger
        }
        let notes: [(itemID: String, payload: SharedFolderItemPayload)] = try meetingsInFolder(records: records, folder: meta.name).compactMap { (record: MeetingRecord) in
            guard let payload = sharedFolderItemPayload(record: record, includeTranscript: meta.includeTranscript) else {
                return nil
            }
            return (try sharedFolderItemID(keyring: keyring, meetingID: record.id), payload)
        }
        let plaintexts: [String: Data] = try Dictionary(notes.map { ($0.itemID, try canonicalJSON($0.payload)) }, uniquingKeysWith: { (first: Data, _: Data) -> Data in first })
        let local: [SharedFolderLocalItem] = try plaintexts.map { SharedFolderLocalItem(itemID: $0.key, tag: try sharedFolderContentTag(keyring: keyring, plaintext: $0.value)) }
        let remote: [SharedFolderRemoteItem] = try await client.items(folderID: folder.folderID).items
        let plan: SharedFolderPublishPlan = sharedFolderPublishPlan(local: local, remote: remote, ledger: ledger)
        var published: Set<String> = ledger
        for itemID in plan.uploads {
            guard let plaintext = plaintexts[itemID] else {
                continue
            }
            let blob: Data = try sealFolderBlob(plaintext: plaintext, keyring: keyring, itemID: itemID, owner: identity)
            try await client.putItem(
                folderID: folder.folderID, itemID: itemID, blob: blob, epoch: keyring.currentEpoch, tag: try sharedFolderContentTag(keyring: keyring, plaintext: plaintext), deviceID: deviceID
            )
            published.insert(itemID)
        }
        for itemID in plan.deletes {
            try await client.deleteItem(folderID: folder.folderID, itemID: itemID)
            published.remove(itemID)
        }
        folderServiceLogger.info("Shared folder published, uploads: \(plan.uploads.count, privacy: .public), deletes: \(plan.deletes.count, privacy: .public)")
        return published
    }

    /// Reads the folder's notes: changed items (by tag) are downloaded, their signatures checked and opened; unchanged
    /// cached ones are kept; items gone from the server are dropped. A member waiting for activation is `waitingForOwner`.
    public func readNotes(folder: OpenedSharedFolder, cached: [SharedFolderCachedItem]) async throws -> [SharedFolderCachedItem] {
        guard let keyring = folder.keyring else {
            throw SharedFolderSetupError.waitingForOwner
        }
        let known: [String: SharedFolderCachedItem] = Dictionary(cached.map { ($0.itemID, $0) }, uniquingKeysWith: { (first: SharedFolderCachedItem, _: SharedFolderCachedItem) -> SharedFolderCachedItem in first })
        var result: [SharedFolderCachedItem] = []
        for item in try await client.items(folderID: folder.folderID).items {
            if let hit = known[item.itemId], hit.tag == item.tag {
                result.append(hit)
                continue
            }
            let blob: Data = try await client.item(folderID: folder.folderID, itemID: item.itemId)
            let plaintext: Data = try openFolderBlob(blob: blob, keyring: keyring, itemID: item.itemId, ownerSigningKey: folder.ownerKeys.signingKey)
            result.append(SharedFolderCachedItem(itemID: item.itemId, tag: item.tag, payload: try JSONDecoder().decode(SharedFolderItemPayload.self, from: plaintext)))
        }
        return result.sorted { $0.payload.startedAtMs > $1.payload.startedAtMs }
    }
}
