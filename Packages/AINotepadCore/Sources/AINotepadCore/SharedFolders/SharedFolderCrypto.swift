import CryptoKit
import Foundation

// End-to-end encryption of shared folders (design and threat model: docs/superpowers/specs/2026-11-08-shared-folders.md).
//
// Every account that uses shared folders has a sharing identity: a random 32-byte seed from which an X25519 key
// (receives folder keyrings), an Ed25519 key (the owner signs notes, metadata, rosters and keyrings) and an owner-private
// AES key (invite labels and secrets) are derived. A folder has a keyring, one AES-256 key per epoch; notes are sealed
// under the newest epoch and signed by the owner, so a member who holds the keyring still cannot forge a note. The
// keyring reaches a member wrapped with HPKE (RFC 9180) to the member's X25519 key and signed by the owner; the owner
// wraps it to the keys in a roster they signed, never to a list the server hands them. An invite's secret lives only in
// the link's fragment: it authenticates the owner's keys to the invitee and the invitee's keys to the owner (HMAC
// proofs), so a server that swaps keys is caught on both sides. The server (`server/src/sharedFolders.ts`) checks only
// the formats and stores what it cannot open.

/// A shared-folder key, envelope, proof or blob could not be used.
public enum SharedFolderCryptoError: Error, Sendable, Equatable {
    /// Raw key material has the wrong length.
    case invalidKeyLength(byteCount: Int)
    /// The blob or envelope is too short or does not start with the expected format marker.
    case malformedBlob(byteCount: Int)
    /// The owner's signature does not verify: the server, a member or someone else changed or forged it.
    case badSignature
    /// Authentication of the ciphertext failed: wrong key, tampered or moved to another folder, item or member.
    case authenticationFailed
    /// The keyring has no key for the epoch the blob was sealed with.
    case unknownEpoch(epoch: Int)
    /// A proof made with the invite secret does not match: the keys were swapped or the secret is wrong.
    case proofMismatch
    /// The opened identity's public keys are not the registered ones.
    case identityMismatch
    /// The keyring or roster belongs to another folder.
    case wrongFolder
    /// The roster or keyring is older than one this device already saw (rollback).
    case staleVersion(seen: Int, served: Int)
    /// The link is not a shared-folder invite or its secret is missing.
    case invalidInviteLink
    /// A sealed note is larger than the server accepts.
    case tooLarge(byteCount: Int)
}

/// Domain-separation labels; changing one makes every existing shared folder unreadable.
private enum FolderLabel {
    static let agreement: String = "gistsmith.folder.v1.agreement"
    static let signing: String = "gistsmith.folder.v1.signing"
    static let ownerPrivate: String = "gistsmith.folder.v1.owner-private"
    static let pin: String = "gistsmith.folder.v1.pin"
    static let seed: String = "gistsmith.folder.v1.seed"
    static let item: String = "gistsmith.folder.v1.item"
    static let itemSignature: String = "gistsmith.folder.v1.item-signature"
    static let itemID: String = "gistsmith.folder.v1.item-id"
    static let itemTag: String = "gistsmith.folder.v1.item-tag"
    static let envelope: String = "gistsmith.folder.v1.envelope"
    static let envelopeSignature: String = "gistsmith.folder.v1.envelope-signature"
    static let roster: String = "gistsmith.folder.v1.roster"
    static let inviteMAC: String = "gistsmith.folder.v1.invite-mac"
    static let invitePreview: String = "gistsmith.folder.v1.invite-preview"
    static let memberName: String = "gistsmith.folder.v1.member-name"
    static let inviteLabel: String = "gistsmith.folder.v1.invite-label"
    static let inviteSecret: String = "gistsmith.folder.v1.invite-secret"
    static let ownerProof: String = "owner"
    static let memberProof: String = "member"
}

/// Item blob marker (`server/src/sharedFolders.ts` `sharedFolderItemMagic`).
public let sharedFolderItemMagic: String = "GSF1"
/// Keyring envelope marker.
public let sharedFolderEnvelopeMagic: String = "GSK1"
/// Largest sealed item the server accepts (`sharedFolderItemMaxBytes`).
public let sharedFolderItemMaxBytes: Int = 1_048_576
/// Item id of the folder metadata blob.
let sharedFolderMetaItemID: String = "meta"
/// Member id of the owner's own keyring envelope.
public let sharedFolderOwnerMemberID: String = "owner"
private let boxVersion: UInt8 = 1
private let signatureBytes: Int = 64

// MARK: - Identity

/// An account's public sharing keys (32 bytes each; base64 in JSON, like the server stores them).
public struct SharingPublicKeys: Sendable, Equatable, Hashable, Codable {
    public let agreementKey: Data
    public let signingKey: Data

    public init(agreementKey: Data, signingKey: Data) {
        self.agreementKey = agreementKey
        self.signingKey = signingKey
    }
}

/// An account's sharing identity: the seed and the keys derived from it. Never log it or send the seed in the clear.
public struct SharingIdentity: Sendable {
    let seed: Data
    let agreementKey: Curve25519.KeyAgreement.PrivateKey
    let signingKey: Curve25519.Signing.PrivateKey
    let ownerPrivateKey: SymmetricKey
    let pinKey: SymmetricKey
    public let publicKeys: SharingPublicKeys

    /// The seed for the Keychain.
    public var seedData: Data { seed }
}

private func derivedBytes(seed: Data, label: String) -> Data {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: seed), salt: Data(label.utf8), info: Data(), outputByteCount: 32).withUnsafeBytes { Data($0) }
}

/// The identity of a stored seed (32 bytes); other lengths are `invalidKeyLength`. Pure function.
public func sharingIdentity(seed: Data) throws -> SharingIdentity {
    guard seed.count == 32 else {
        throw SharedFolderCryptoError.invalidKeyLength(byteCount: seed.count)
    }
    let agreement: Curve25519.KeyAgreement.PrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: derivedBytes(seed: seed, label: FolderLabel.agreement))
    let signing: Curve25519.Signing.PrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: derivedBytes(seed: seed, label: FolderLabel.signing))
    return SharingIdentity(
        seed: seed, agreementKey: agreement, signingKey: signing,
        ownerPrivateKey: SymmetricKey(data: derivedBytes(seed: seed, label: FolderLabel.ownerPrivate)),
        pinKey: SymmetricKey(data: derivedBytes(seed: seed, label: FolderLabel.pin)),
        publicKeys: SharingPublicKeys(agreementKey: agreement.publicKey.rawRepresentation, signingKey: signing.publicKey.rawRepresentation)
    )
}

/// A new random identity.
public func newSharingIdentity() throws -> SharingIdentity {
    try sharingIdentity(seed: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
}

private func seedAAD(userID: String, keys: SharingPublicKeys, keyID: String) -> Data {
    framed([Data(FolderLabel.seed.utf8), Data(userID.utf8), keys.agreementKey, keys.signingKey, Data(keyID.utf8)])
}

private func seedWrappingKey(accountKey: SyncAccountKey, userID: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: accountKey.key, salt: Data(FolderLabel.seed.utf8), info: Data(userID.utf8), outputByteCount: 32)
}

/// The seed sealed with the account sync key for the account's other devices (`sharing_identities.sealed_seed`).
public func sealSharingSeed(identity: SharingIdentity, accountKey: SyncAccountKey, userID: String) throws -> Data {
    try sealBox(
        plaintext: identity.seed, key: seedWrappingKey(accountKey: accountKey, userID: userID),
        aad: seedAAD(userID: userID, keys: identity.publicKeys, keyID: accountKey.keyID)
    )
}

/// Opens the sealed seed with this device's sync key; the derived keys must equal the registered ones (`expected`),
/// otherwise `identityMismatch`. Pure function.
public func openSharingSeed(sealed: Data, accountKey: SyncAccountKey, userID: String, expected: SharingPublicKeys) throws -> SharingIdentity {
    let seed: Data = try openBox(
        sealed: sealed, key: seedWrappingKey(accountKey: accountKey, userID: userID), aad: seedAAD(userID: userID, keys: expected, keyID: accountKey.keyID)
    )
    let identity: SharingIdentity = try sharingIdentity(seed: seed)
    guard identity.publicKeys == expected else {
        throw SharedFolderCryptoError.identityMismatch
    }
    return identity
}

// MARK: - Boxes and signatures

/// Version byte + AES-GCM combined (nonce, ciphertext, tag). Pure apart from the random nonce.
private func sealBox(plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
    guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else {
        throw SharedFolderCryptoError.malformedBlob(byteCount: 0)
    }
    return Data([boxVersion]) + combined
}

private func openBox(sealed: Data, key: SymmetricKey, aad: Data) throws -> Data {
    guard sealed.count > 1 + 12 + 16, sealed.first == boxVersion else {
        throw SharedFolderCryptoError.malformedBlob(byteCount: sealed.count)
    }
    do {
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed.dropFirst()), using: key, authenticating: aad)
    } catch {
        throw SharedFolderCryptoError.authenticationFailed
    }
}

private func verifySignature(signature: Data, message: Data, signingKey: Data) throws {
    let key: Curve25519.Signing.PublicKey
    do {
        key = try Curve25519.Signing.PublicKey(rawRepresentation: signingKey)
    } catch {
        throw SharedFolderCryptoError.invalidKeyLength(byteCount: signingKey.count)
    }
    guard key.isValidSignature(signature, for: message) else {
        throw SharedFolderCryptoError.badSignature
    }
}

private func uint32Bytes(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(clamping: value).bigEndian) { Data($0) }
}

private func readUInt32(_ bytes: Data, at offset: Int) -> Int {
    Int(bytes.dropFirst(offset).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
}

// MARK: - Keyring

/// A folder's keys, one per epoch. The newest epoch seals new notes.
public struct FolderKeyring: Sendable, Equatable {
    public let folderID: String
    /// Epoch → 32-byte key.
    let keys: [Int: Data]

    /// The newest epoch.
    public var currentEpoch: Int { keys.keys.max() ?? 0 }
}

/// A new keyring at epoch 1.
public func newFolderKeyring(folderID: String) -> FolderKeyring {
    FolderKeyring(folderID: folderID, keys: [1: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }])
}

/// The keyring with one more epoch (rotation): earlier notes stay readable, new ones use the new key.
public func rotatedFolderKeyring(keyring: FolderKeyring) -> FolderKeyring {
    var keys: [Int: Data] = keyring.keys
    keys[keyring.currentEpoch + 1] = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    return FolderKeyring(folderID: keyring.folderID, keys: keys)
}

private func epochKey(keyring: FolderKeyring, epoch: Int) throws -> SymmetricKey {
    guard let key = keyring.keys[epoch] else {
        throw SharedFolderCryptoError.unknownEpoch(epoch: epoch)
    }
    return SymmetricKey(data: key)
}

/// Key of the item ids and content tags: from epoch 1, so every owner device computes the same values forever.
private func itemIDKey(keyring: FolderKeyring) throws -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: try epochKey(keyring: keyring, epoch: 1), salt: Data(FolderLabel.itemID.utf8), info: Data(keyring.folderID.utf8), outputByteCount: 32)
}

/// The item id of a meeting: a keyed hash of its local id shaped as a lowercase UUID (version 8); the server cannot link
/// it to the meeting. Pure function.
public func sharedFolderItemID(keyring: FolderKeyring, meetingID: String) throws -> String {
    var bytes: [UInt8] = Array(HMAC<SHA256>.authenticationCode(for: Data(meetingID.utf8), using: try itemIDKey(keyring: keyring)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x80
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let hex: String = Data(bytes).hexString
    let cuts: [Int] = [0, 8, 12, 16, 20, 32]
    return zip(cuts, cuts.dropFirst()).map { (start: Int, end: Int) -> String in
        String(hex[hex.index(hex.startIndex, offsetBy: start)..<hex.index(hex.startIndex, offsetBy: end)])
    }.joined(separator: "-")
}

/// A keyed hash of the plaintext (16 bytes, hex): the publisher skips uploads whose tag the server already has. Pure.
public func sharedFolderContentTag(keyring: FolderKeyring, plaintext: Data) throws -> String {
    let key: SymmetricKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: try itemIDKey(keyring: keyring), salt: Data(FolderLabel.itemTag.utf8), info: Data(), outputByteCount: 32)
    return Data(HMAC<SHA256>.authenticationCode(for: plaintext, using: key).prefix(16)).hexString
}

// MARK: - Items

private func itemKey(keyring: FolderKeyring, epoch: Int, itemID: String) throws -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: try epochKey(keyring: keyring, epoch: epoch), salt: Data(FolderLabel.item.utf8), info: Data(itemID.utf8), outputByteCount: 32)
}

private func itemSignedMessage(folderID: String, itemID: String, epoch: Int, sealedPart: Data) -> Data {
    framed([Data(FolderLabel.itemSignature.utf8), Data(folderID.utf8), Data(itemID.utf8), uint32Bytes(epoch), Data(SHA256.hash(data: sealedPart))])
}

/// Seals and signs bytes as an item of the folder under its newest epoch: `GSF1 ‖ epoch ‖ nonce ‖ ciphertext ‖ tag ‖
/// signature`. Larger than the server accepts is `tooLarge`.
public func sealFolderBlob(plaintext: Data, keyring: FolderKeyring, itemID: String, owner: SharingIdentity) throws -> Data {
    let epoch: Int = keyring.currentEpoch
    let aad: Data = framed([Data(FolderLabel.item.utf8), Data(keyring.folderID.utf8), Data(itemID.utf8), uint32Bytes(epoch)])
    guard let combined = try AES.GCM.seal(plaintext, using: try itemKey(keyring: keyring, epoch: epoch, itemID: itemID), authenticating: aad).combined else {
        throw SharedFolderCryptoError.malformedBlob(byteCount: 0)
    }
    let sealedPart: Data = Data(sharedFolderItemMagic.utf8) + uint32Bytes(epoch) + combined
    let signature: Data = try owner.signingKey.signature(for: itemSignedMessage(folderID: keyring.folderID, itemID: itemID, epoch: epoch, sealedPart: sealedPart))
    let blob: Data = sealedPart + signature
    guard blob.count <= sharedFolderItemMaxBytes else {
        throw SharedFolderCryptoError.tooLarge(byteCount: blob.count)
    }
    return blob
}

/// The epoch an item was sealed with (its header). Pure function.
public func folderBlobEpoch(blob: Data) throws -> Int {
    guard blob.count >= 8 + 12 + 16 + signatureBytes, blob.prefix(4) == Data(sharedFolderItemMagic.utf8) else {
        throw SharedFolderCryptoError.malformedBlob(byteCount: blob.count)
    }
    return readUInt32(blob, at: 4)
}

/// Checks the owner's signature, then opens the item. A note forged by a member or changed by the server is
/// `badSignature`; one moved to another folder or item is `badSignature` or `authenticationFailed`. Pure function.
public func openFolderBlob(blob: Data, keyring: FolderKeyring, itemID: String, ownerSigningKey: Data) throws -> Data {
    let epoch: Int = try folderBlobEpoch(blob: blob)
    let sealedPart: Data = blob.dropLast(signatureBytes)
    try verifySignature(
        signature: blob.suffix(signatureBytes), message: itemSignedMessage(folderID: keyring.folderID, itemID: itemID, epoch: epoch, sealedPart: Data(sealedPart)),
        signingKey: ownerSigningKey
    )
    let aad: Data = framed([Data(FolderLabel.item.utf8), Data(keyring.folderID.utf8), Data(itemID.utf8), uint32Bytes(epoch)])
    do {
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: sealedPart.dropFirst(8)), using: try itemKey(keyring: keyring, epoch: epoch, itemID: itemID), authenticating: aad)
    } catch let error as SharedFolderCryptoError {
        throw error
    } catch {
        throw SharedFolderCryptoError.authenticationFailed
    }
}

// MARK: - Keyring envelopes (HPKE)

private let hpkeSuite: HPKE.Ciphersuite = .Curve25519_SHA256_ChachaPoly

/// Keyring as it travels inside an envelope.
private struct KeyringWire: Codable {
    let folderId: String
    let epochs: [EpochWire]
}

private struct EpochWire: Codable {
    let epoch: Int
    let key: Data
}

private func envelopeInfo(folderID: String, memberID: String, epoch: Int) -> Data {
    framed([Data(FolderLabel.envelope.utf8), Data(folderID.utf8), Data(memberID.utf8), uint32Bytes(epoch)])
}

private func envelopeSignedMessage(folderID: String, memberID: String, epoch: Int, sealedPart: Data) -> Data {
    framed([Data(FolderLabel.envelopeSignature.utf8), Data(folderID.utf8), Data(memberID.utf8), uint32Bytes(epoch), Data(SHA256.hash(data: sealedPart))])
}

/// The whole keyring wrapped to a member's (or the owner's own) X25519 key with HPKE and signed by the owner:
/// `GSK1 ‖ epoch ‖ encapsulated key (32) ‖ ciphertext ‖ signature`.
public func sealKeyringEnvelope(keyring: FolderKeyring, recipient: SharingPublicKeys, memberID: String, owner: SharingIdentity) throws -> Data {
    let epoch: Int = keyring.currentEpoch
    let publicKey: Curve25519.KeyAgreement.PublicKey
    do {
        publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.agreementKey)
    } catch {
        throw SharedFolderCryptoError.invalidKeyLength(byteCount: recipient.agreementKey.count)
    }
    var sender: HPKE.Sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: hpkeSuite, info: envelopeInfo(folderID: keyring.folderID, memberID: memberID, epoch: epoch))
    let wire: KeyringWire = KeyringWire(
        folderId: keyring.folderID,
        epochs: keyring.keys.keys.sorted().compactMap { (epoch: Int) -> EpochWire? in keyring.keys[epoch].map { EpochWire(epoch: epoch, key: $0) } }
    )
    let ciphertext: Data = try sender.seal(try JSONEncoder().encode(wire))
    let sealedPart: Data = Data(sharedFolderEnvelopeMagic.utf8) + uint32Bytes(epoch) + sender.encapsulatedKey + ciphertext
    let signature: Data = try owner.signingKey.signature(for: envelopeSignedMessage(folderID: keyring.folderID, memberID: memberID, epoch: epoch, sealedPart: sealedPart))
    return sealedPart + signature
}

/// Opens a keyring envelope with this account's identity after checking the owner's signature; the keyring must be for
/// `folderID` and reach exactly the envelope's epoch. Pure function.
public func openKeyringEnvelope(envelope: Data, recipient: SharingIdentity, folderID: String, memberID: String, ownerSigningKey: Data) throws -> FolderKeyring {
    guard envelope.count > 8 + 32 + 16 + signatureBytes, envelope.prefix(4) == Data(sharedFolderEnvelopeMagic.utf8) else {
        throw SharedFolderCryptoError.malformedBlob(byteCount: envelope.count)
    }
    let epoch: Int = readUInt32(envelope, at: 4)
    let sealedPart: Data = Data(envelope.dropLast(signatureBytes))
    try verifySignature(
        signature: envelope.suffix(signatureBytes), message: envelopeSignedMessage(folderID: folderID, memberID: memberID, epoch: epoch, sealedPart: sealedPart),
        signingKey: ownerSigningKey
    )
    let encapsulated: Data = Data(sealedPart.dropFirst(8).prefix(32))
    let wireData: Data
    do {
        var receiver: HPKE.Recipient = try HPKE.Recipient(
            privateKey: recipient.agreementKey, ciphersuite: hpkeSuite, info: envelopeInfo(folderID: folderID, memberID: memberID, epoch: epoch), encapsulatedKey: encapsulated
        )
        wireData = try receiver.open(Data(sealedPart.dropFirst(40)))
    } catch {
        throw SharedFolderCryptoError.authenticationFailed
    }
    let wire: KeyringWire = try JSONDecoder().decode(KeyringWire.self, from: wireData)
    guard wire.folderId == folderID else {
        throw SharedFolderCryptoError.wrongFolder
    }
    let keys: [Int: Data] = Dictionary(wire.epochs.map { ($0.epoch, $0.key) }, uniquingKeysWith: { (first: Data, _: Data) -> Data in first })
    guard keys.values.allSatisfy({ $0.count == 32 }), keys.keys.max() == epoch, keys[1] != nil else {
        throw SharedFolderCryptoError.malformedBlob(byteCount: envelope.count)
    }
    return FolderKeyring(folderID: folderID, keys: keys)
}

// MARK: - Roster

/// An active member as the owner signs it (base64 keys, like the server compares them).
public struct SharedFolderRosterMember: Sendable, Equatable, Codable {
    public let memberId: String
    public let userId: String
    public let agreementKey: String
    public let signingKey: String

    public init(memberId: String, userId: String, keys: SharingPublicKeys) {
        self.memberId = memberId
        self.userId = userId
        agreementKey = keys.agreementKey.base64EncodedString()
        signingKey = keys.signingKey.base64EncodedString()
    }

    /// The member's public keys; nil if the base64 is not two 32-byte keys.
    public var publicKeys: SharingPublicKeys? {
        guard let agreement = Data(base64Encoded: agreementKey), let signing = Data(base64Encoded: signingKey), agreement.count == 32, signing.count == 32 else {
            return nil
        }
        return SharingPublicKeys(agreementKey: agreement, signingKey: signing)
    }
}

/// The owner-signed list of a folder's active members at a version and key epoch.
public struct SharedFolderRoster: Sendable, Equatable, Codable {
    public let folderId: String
    public let version: Int
    public let epoch: Int
    public let members: [SharedFolderRosterMember]

    public init(folderId: String, version: Int, epoch: Int, members: [SharedFolderRosterMember]) {
        self.folderId = folderId
        self.version = version
        self.epoch = epoch
        self.members = members
    }
}

/// A roster's canonical JSON text and the owner's signature over it.
public struct SignedSharedFolderRoster: Sendable, Equatable {
    public let text: String
    public let signature: Data
}

private func rosterMessage(text: String) -> Data {
    framed([Data(FolderLabel.roster.utf8), Data(text.utf8)])
}

/// Signs a roster (canonical JSON, sorted keys).
public func signSharedFolderRoster(roster: SharedFolderRoster, owner: SharingIdentity) throws -> SignedSharedFolderRoster {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text: String = String(decoding: try encoder.encode(roster), as: UTF8.self)
    return SignedSharedFolderRoster(text: text, signature: try owner.signingKey.signature(for: rosterMessage(text: text)))
}

/// Checks the owner's signature over a roster text and that it is this folder's. Pure function.
public func verifySharedFolderRoster(text: String, signature: Data, ownerSigningKey: Data, folderID: String) throws -> SharedFolderRoster {
    try verifySignature(signature: signature, message: rosterMessage(text: text), signingKey: ownerSigningKey)
    let roster: SharedFolderRoster = try JSONDecoder().decode(SharedFolderRoster.self, from: Data(text.utf8))
    guard roster.folderId == folderID else {
        throw SharedFolderCryptoError.wrongFolder
    }
    return roster
}

// MARK: - Invites

/// An invite: a random id (the server's member id) and a secret that exists only in the link's fragment.
public struct SharedFolderInvite: Sendable, Equatable {
    /// 16 random bytes, base64url (22 characters).
    public let inviteID: String
    let secret: Data
}

/// A new invite (random id and 256-bit secret).
public func newSharedFolderInvite() -> SharedFolderInvite {
    let id: Data = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    return SharedFolderInvite(inviteID: base64URLEncoded(id), secret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
}

/// The invite link: `<site>/j#<inviteId>.<secret>`; the fragment never reaches a server. Pure function.
public func sharedFolderInviteLink(siteOrigin: URL, invite: SharedFolderInvite) -> URL {
    var components: URLComponents = URLComponents()
    components.scheme = siteOrigin.scheme
    components.host = siteOrigin.host()
    components.port = siteOrigin.port
    components.path = "/j"
    components.fragment = "\(invite.inviteID).\(base64URLEncoded(invite.secret))"
    guard let url = components.url else {
        preconditionFailure("Invite link could not be built: \(siteOrigin.absoluteString)")
    }
    return url
}

/// Reads an invite from a pasted text or an opened link: `https://…/j#<id>.<secret>` or `gistsmith://join#<id>.<secret>`;
/// anything else is `invalidInviteLink`. Pure function.
public func sharedFolderInvite(text: String) throws -> SharedFolderInvite {
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let fragment = url.fragment() else {
        throw SharedFolderCryptoError.invalidInviteLink
    }
    let isWebLink: Bool = (url.scheme == "https" || url.scheme == "http") && url.path() == "/j"
    let isAppLink: Bool = url.scheme == "gistsmith" && url.host() == "join"
    let parts: [Substring] = fragment.split(separator: ".", omittingEmptySubsequences: false)
    guard isWebLink || isAppLink, parts.count == 2, isNoteShareID(String(parts[0])), let secret = base64URLDecoded(String(parts[1])), secret.count == 32 else {
        throw SharedFolderCryptoError.invalidInviteLink
    }
    return SharedFolderInvite(inviteID: String(parts[0]), secret: secret)
}

private func inviteKey(secret: Data, label: String, folderID: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(label.utf8), info: Data(folderID.utf8), outputByteCount: 32)
}

private func ownerProofMessage(folderID: String, inviteID: String, owner: SharingPublicKeys) -> Data {
    framed([Data(FolderLabel.ownerProof.utf8), Data(folderID.utf8), Data(inviteID.utf8), owner.agreementKey, owner.signingKey])
}

private func memberProofMessage(folderID: String, inviteID: String, memberUserID: String, member: SharingPublicKeys) -> Data {
    framed([Data(FolderLabel.memberProof.utf8), Data(folderID.utf8), Data(inviteID.utf8), Data(memberUserID.utf8), member.agreementKey, member.signingKey])
}

/// Proof that the owner's keys are the ones the invite was made with. Pure function.
public func sharedFolderOwnerProof(invite: SharedFolderInvite, folderID: String, owner: SharingPublicKeys) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: ownerProofMessage(folderID: folderID, inviteID: invite.inviteID, owner: owner), using: inviteKey(secret: invite.secret, label: FolderLabel.inviteMAC, folderID: folderID)))
}

/// The invitee's check of the owner keys the server returned; a swapped key is `proofMismatch`. Pure function.
public func verifySharedFolderOwnerProof(proof: Data, invite: SharedFolderInvite, folderID: String, owner: SharingPublicKeys) throws {
    guard HMAC<SHA256>.isValidAuthenticationCode(
        proof, authenticating: ownerProofMessage(folderID: folderID, inviteID: invite.inviteID, owner: owner),
        using: inviteKey(secret: invite.secret, label: FolderLabel.inviteMAC, folderID: folderID)
    ) else {
        throw SharedFolderCryptoError.proofMismatch
    }
}

/// Proof that the accepting account knew the invite secret, bound to its user id and keys. Pure function.
public func sharedFolderMemberProof(invite: SharedFolderInvite, folderID: String, memberUserID: String, member: SharingPublicKeys) -> Data {
    Data(HMAC<SHA256>.authenticationCode(
        for: memberProofMessage(folderID: folderID, inviteID: invite.inviteID, memberUserID: memberUserID, member: member),
        using: inviteKey(secret: invite.secret, label: FolderLabel.inviteMAC, folderID: folderID)
    ))
}

/// The owner device's check before adding the account to the roster; anything swapped is `proofMismatch`. Pure.
public func verifySharedFolderMemberProof(proof: Data, invite: SharedFolderInvite, folderID: String, memberUserID: String, member: SharingPublicKeys) throws {
    guard HMAC<SHA256>.isValidAuthenticationCode(
        proof, authenticating: memberProofMessage(folderID: folderID, inviteID: invite.inviteID, memberUserID: memberUserID, member: member),
        using: inviteKey(secret: invite.secret, label: FolderLabel.inviteMAC, folderID: folderID)
    ) else {
        throw SharedFolderCryptoError.proofMismatch
    }
}

/// What the invitee sees before joining.
public struct SharedFolderInvitePreview: Sendable, Equatable, Codable {
    public let folderName: String
    public let ownerName: String

    public init(folderName: String, ownerName: String) {
        self.folderName = folderName
        self.ownerName = ownerName
    }
}

/// The preview sealed with a key from the invite secret.
public func sealSharedFolderInvitePreview(preview: SharedFolderInvitePreview, invite: SharedFolderInvite, folderID: String) throws -> Data {
    try sealBox(
        plaintext: try JSONEncoder().encode(preview), key: inviteKey(secret: invite.secret, label: FolderLabel.invitePreview, folderID: folderID),
        aad: framed([Data(FolderLabel.invitePreview.utf8), Data(folderID.utf8), Data(invite.inviteID.utf8)])
    )
}

/// Opens the preview. Pure function.
public func openSharedFolderInvitePreview(sealed: Data, invite: SharedFolderInvite, folderID: String) throws -> SharedFolderInvitePreview {
    let data: Data = try openBox(
        sealed: sealed, key: inviteKey(secret: invite.secret, label: FolderLabel.invitePreview, folderID: folderID),
        aad: framed([Data(FolderLabel.invitePreview.utf8), Data(folderID.utf8), Data(invite.inviteID.utf8)])
    )
    return try JSONDecoder().decode(SharedFolderInvitePreview.self, from: data)
}

/// The display name the member chose, sealed with a key from the invite secret (the owner opens it with the secret).
public func sealSharedFolderMemberName(name: String, invite: SharedFolderInvite, folderID: String) throws -> Data {
    try sealBox(
        plaintext: Data(name.utf8), key: inviteKey(secret: invite.secret, label: FolderLabel.memberName, folderID: folderID),
        aad: framed([Data(FolderLabel.memberName.utf8), Data(folderID.utf8), Data(invite.inviteID.utf8)])
    )
}

/// Opens the member's display name. Pure function.
public func openSharedFolderMemberName(sealed: Data, invite: SharedFolderInvite, folderID: String) throws -> String {
    String(decoding: try openBox(
        sealed: sealed, key: inviteKey(secret: invite.secret, label: FolderLabel.memberName, folderID: folderID),
        aad: framed([Data(FolderLabel.memberName.utf8), Data(folderID.utf8), Data(invite.inviteID.utf8)])
    ), as: UTF8.self)
}

private func ownerPrivateAAD(label: String, folderID: String, inviteID: String) -> Data {
    framed([Data(label.utf8), Data(folderID.utf8), Data(inviteID.utf8)])
}

/// The owner's label for an invite (a name or e-mail address), sealed so only the owner's devices can read it.
public func sealSharedFolderInviteLabel(label: String, owner: SharingIdentity, folderID: String, inviteID: String) throws -> Data {
    try sealBox(plaintext: Data(label.utf8), key: owner.ownerPrivateKey, aad: ownerPrivateAAD(label: FolderLabel.inviteLabel, folderID: folderID, inviteID: inviteID))
}

/// Opens an invite label. Pure function.
public func openSharedFolderInviteLabel(sealed: Data, owner: SharingIdentity, folderID: String, inviteID: String) throws -> String {
    String(decoding: try openBox(sealed: sealed, key: owner.ownerPrivateKey, aad: ownerPrivateAAD(label: FolderLabel.inviteLabel, folderID: folderID, inviteID: inviteID)), as: UTF8.self)
}

/// The invite secret sealed for the owner's devices (any of them can verify the acceptance later).
public func sealSharedFolderInviteSecret(invite: SharedFolderInvite, owner: SharingIdentity, folderID: String) throws -> Data {
    try sealBox(plaintext: invite.secret, key: owner.ownerPrivateKey, aad: ownerPrivateAAD(label: FolderLabel.inviteSecret, folderID: folderID, inviteID: invite.inviteID))
}

/// Opens the sealed invite secret. Pure function.
public func openSharedFolderInviteSecret(sealed: Data, owner: SharingIdentity, folderID: String, inviteID: String) throws -> SharedFolderInvite {
    let secret: Data = try openBox(sealed: sealed, key: owner.ownerPrivateKey, aad: ownerPrivateAAD(label: FolderLabel.inviteSecret, folderID: folderID, inviteID: inviteID))
    guard secret.count == 32 else {
        throw SharedFolderCryptoError.invalidKeyLength(byteCount: secret.count)
    }
    return SharedFolderInvite(inviteID: inviteID, secret: secret)
}

// MARK: - Member pin

/// What a member's devices remember about a folder they joined: the owner keys the invite proved, and the names.
public struct SharedFolderPin: Sendable, Equatable, Codable {
    public let ownerKeys: SharingPublicKeys
    public let folderName: String
    public let ownerName: String

    public init(ownerKeys: SharingPublicKeys, folderName: String, ownerName: String) {
        self.ownerKeys = ownerKeys
        self.folderName = folderName
        self.ownerName = ownerName
    }
}

/// The pin sealed with a key from the member's own seed (`sealed_pin`; every device of the member opens it).
public func sealSharedFolderPin(pin: SharedFolderPin, member: SharingIdentity, folderID: String) throws -> Data {
    try sealBox(plaintext: try JSONEncoder().encode(pin), key: member.pinKey, aad: framed([Data(FolderLabel.pin.utf8), Data(folderID.utf8)]))
}

/// Opens the member's pin. Pure function.
public func openSharedFolderPin(sealed: Data, member: SharingIdentity, folderID: String) throws -> SharedFolderPin {
    try JSONDecoder().decode(SharedFolderPin.self, from: try openBox(sealed: sealed, key: member.pinKey, aad: framed([Data(FolderLabel.pin.utf8), Data(folderID.utf8)])))
}
