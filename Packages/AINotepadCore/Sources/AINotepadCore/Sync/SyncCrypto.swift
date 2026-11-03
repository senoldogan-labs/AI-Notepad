import CryptoKit
import Foundation

// End-to-end encryption of sync (doc §8.3). The account sync key (ASK, 256 bits) is made on the first device that
// turns sync on and never reaches the server. Each object is sealed with AES-256-GCM under its own key
// (HKDF-SHA256(ASK, object id)); the associated data binds the account, object id, kind, key id and base revision, so
// the server can neither read an object nor pass one off as another. The key reaches other devices through the iCloud
// Keychain (app code, 1B), an "add a device" pairing (`SyncPairing…`, X25519) or the optional recovery code.

/// A sync key, envelope or blob could not be used.
public enum SyncCryptoError: Error, Sendable, Equatable {
    /// Raw key material is not 32 bytes.
    case invalidKeyLength(byteCount: Int)
    /// The blob or envelope is too short or does not start with the expected format marker.
    case malformedBlob(byteCount: Int)
    /// Sealed with another account key (the account was reset, or the key on this device is stale).
    case keyMismatch(expected: String, found: String)
    /// The server served a blob whose base revision is not older than the revision it claims (replay of an old copy).
    case staleRevision(baseRevision: UInt64, servedRevision: UInt64)
    /// Authentication failed: tampered ciphertext, wrong key, wrong recovery code or a blob moved to another object.
    case authenticationFailed
    /// The recovery code is not 32 characters of the code alphabet.
    case invalidRecoveryCode
    /// A public key is not a valid X25519 key.
    case invalidPublicKey(byteCount: Int)
    /// The pairing reveal does not match the commitment sent first (someone in the middle swapped keys).
    case pairingCommitmentMismatch
    /// The key envelope came from another device than the one the user compared codes with.
    case unexpectedPairingSender
}

/// Domain-separation labels; changing one makes every existing object unreadable.
private enum SyncLabel {
    static let format: String = "gistsmith.sync.v1"
    static let keyID: String = "gistsmith.sync.v1.key-id"
    static let objectKey: String = "gistsmith.sync.v1.object"
    static let objectID: String = "gistsmith.sync.v1.object-id"
    static let recovery: String = "gistsmith.sync.v1.recovery"
    static let pairing: String = "gistsmith.sync.v1.pairing"
    static let commitment: String = "gistsmith.sync.v1.pairing-commitment"
    static let pairingCode: String = "gistsmith.sync.v1.pairing-code"
}

/// Blob format marker (`GSY1`); the server checks it (`server/src/sync.ts` `syncBlobMagic`).
public let syncBlobMagic: String = "GSY1"
/// Magic (4) + key id (16) + base revision (8, big-endian).
let syncBlobHeaderBytes: Int = 28
/// Version byte of recovery and device envelopes.
private let syncEnvelopeVersion: UInt8 = 1

/// The account sync key. Its `keyID` (a keyed hash, not the key) tells devices and the server which key sealed a blob.
public struct SyncAccountKey: Sendable, Equatable {
    let key: SymmetricKey
    /// 16 bytes, lowercase hex (32 characters); the server's `sync_accounts.key_id`.
    public let keyID: String

    /// Wraps raw key material (32 bytes, e.g. read back from the Keychain); other lengths are `invalidKeyLength`.
    public init(rawKey: Data) throws {
        guard rawKey.count == 32 else {
            throw SyncCryptoError.invalidKeyLength(byteCount: rawKey.count)
        }
        self.init(key: SymmetricKey(data: rawKey))
    }

    /// Wraps a 256-bit key.
    private init(key: SymmetricKey) {
        self.key = key
        keyID = syncKeyIDBytes(key: key).hexString
    }

    /// A new random key.
    static func random() -> SyncAccountKey {
        SyncAccountKey(key: SymmetricKey(size: .bits256))
    }

    /// The raw key for the Keychain. Never log it or send it to the server.
    public var rawKey: Data {
        key.withUnsafeBytes { Data($0) }
    }

    public static func == (left: SyncAccountKey, right: SyncAccountKey) -> Bool {
        left.key == right.key
    }
}

/// A new random account sync key.
public func newSyncAccountKey() -> SyncAccountKey {
    SyncAccountKey.random()
}

/// First 16 bytes of HMAC-SHA256(key, label). Pure function.
private func syncKeyIDBytes(key: SymmetricKey) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(SyncLabel.keyID.utf8), using: key).prefix(16))
}

extension Data {
    /// Lowercase hex.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes of a hex string; nil if it is not hex.
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes: [UInt8] = []
        var index: String.Index = hexString.startIndex
        while index < hexString.endIndex {
            let next: String.Index = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

/// Length-prefixed concatenation (4-byte big-endian length + bytes per field): unambiguous associated data. Pure
/// function.
private func framed(_ fields: [Data]) -> Data {
    fields.reduce(into: Data()) { (result: inout Data, field: Data) -> Void in
        withUnsafeBytes(of: UInt32(field.count).bigEndian) { result.append(contentsOf: $0) }
        result.append(field)
    }
}

private func bigEndianBytes(_ value: UInt64) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

/// Object key: HKDF-SHA256 of the account key with the object id as info. Pure function.
private func objectKey(accountKey: SyncAccountKey, objectID: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: accountKey.key, salt: Data(SyncLabel.objectKey.utf8), info: Data(objectID.utf8), outputByteCount: 32)
}

/// Associated data of an object blob. Pure function.
private func objectAAD(userID: String, objectID: String, kind: SyncObjectKind, keyID: String, baseRevision: UInt64) -> Data {
    framed([
        Data(SyncLabel.format.utf8), Data(userID.utf8), Data(objectID.utf8), Data(kind.rawValue.utf8), Data(keyID.utf8), bigEndianBytes(baseRevision),
    ])
}

/// Seals a payload (`encodeSyncPayload`) for upload: `GSY1`, key id, base revision (the revision the upload replaces,
/// 0 for a new object), then AES-GCM nonce, ciphertext and tag. The object id must be the lowercase UUID the server
/// stores it under.
public func sealSyncObject(payload: Data, accountKey: SyncAccountKey, userID: String, objectID: String, kind: SyncObjectKind, baseRevision: UInt64) throws -> Data {
    let sealed: AES.GCM.SealedBox = try AES.GCM.seal(
        payload, using: objectKey(accountKey: accountKey, objectID: objectID),
        authenticating: objectAAD(userID: userID, objectID: objectID, kind: kind, keyID: accountKey.keyID, baseRevision: baseRevision)
    )
    guard let combined = sealed.combined, let keyID = Data(hexString: accountKey.keyID) else {
        throw SyncCryptoError.malformedBlob(byteCount: 0)
    }
    return Data(syncBlobMagic.utf8) + keyID + bigEndianBytes(baseRevision) + combined
}

/// Header of a sealed blob.
public struct SyncBlobHeader: Sendable, Equatable {
    public let keyID: String
    public let baseRevision: UInt64
}

/// Reads a blob's header without decrypting. Pure function.
public func syncBlobHeader(blob: Data) throws -> SyncBlobHeader {
    let bytes: [UInt8] = Array(blob)
    guard bytes.count >= syncBlobHeaderBytes + 12 + 16, Data(bytes[0..<4]) == Data(syncBlobMagic.utf8) else {
        throw SyncCryptoError.malformedBlob(byteCount: bytes.count)
    }
    let revision: UInt64 = bytes[20..<28].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    return SyncBlobHeader(keyID: Data(bytes[4..<20]).hexString, baseRevision: revision)
}

/// Opens a downloaded blob served as `servedRevision` of `objectID`: checks the key id, that the blob's base revision
/// is older than the served one, and the AES-GCM tag over the associated data. Returns the payload (still compressed;
/// see `decodeSyncPayload`).
///
/// Known limit: the server could still serve an older genuine blob of the same object under a newer revision (the
/// check only proves the blob is older than what is claimed, not that it is the latest). That is a rollback, not a
/// disclosure or forgery; the merge then treats it like a stale remote version. Accepted for phase 1.
public func openSyncObject(
    blob: Data, accountKey: SyncAccountKey, userID: String, objectID: String, kind: SyncObjectKind, servedRevision: UInt64
) throws -> Data {
    let header: SyncBlobHeader = try syncBlobHeader(blob: blob)
    guard header.keyID == accountKey.keyID else {
        throw SyncCryptoError.keyMismatch(expected: accountKey.keyID, found: header.keyID)
    }
    guard header.baseRevision < servedRevision else {
        throw SyncCryptoError.staleRevision(baseRevision: header.baseRevision, servedRevision: servedRevision)
    }
    let box: AES.GCM.SealedBox = try AES.GCM.SealedBox(combined: blob.dropFirst(syncBlobHeaderBytes))
    do {
        return try AES.GCM.open(
            box, using: objectKey(accountKey: accountKey, objectID: objectID),
            authenticating: objectAAD(userID: userID, objectID: objectID, kind: kind, keyID: header.keyID, baseRevision: header.baseRevision)
        )
    } catch CryptoKitError.authenticationFailure {
        throw SyncCryptoError.authenticationFailed
    }
}

/// Stable object id for objects both devices must agree on without talking (people, prefs, one per Ask chat): a keyed
/// hash of kind and local id, shaped as a lowercase UUID (version 8). The server cannot link it to the local id.
/// Meetings use random ids instead (`newSyncObjectID`): two devices may name different meetings alike. Pure function.
public func derivedSyncObjectID(accountKey: SyncAccountKey, kind: SyncObjectKind, localID: String) -> String {
    let digest: [UInt8] = Array(HMAC<SHA256>.authenticationCode(for: framed([Data(SyncLabel.objectID.utf8), Data(kind.rawValue.utf8), Data(localID.utf8)]), using: accountKey.key))
    var bytes: [UInt8] = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x80
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return uuidString(bytes: bytes)
}

/// A new random object id (lowercase UUID, the server's form).
public func newSyncObjectID() -> String {
    UUID().uuidString.lowercased()
}

private func uuidString(bytes: [UInt8]) -> String {
    let hex: String = Data(bytes).hexString
    let parts: [Range<Int>] = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
    return parts.map { (range: Range<Int>) -> String in
        String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
    }.joined(separator: "-")
}

// MARK: Recovery code

/// Crockford base32 alphabet (no I, L, O, U: fewer misreadings).
private let recoveryAlphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

/// The optional recovery code: 160 random bits shown as 32 characters in groups of four
/// (`ABCD-EFGH-…`). It never leaves the device except as the user writes it down; the server keeps only the account key
/// sealed with a key derived from it (`sealRecoveryEnvelope`). 160 bits make guessing it from the envelope infeasible.
public struct SyncRecoveryCode: Sendable, Equatable {
    let bytes: Data

    /// Display form, eight groups of four characters.
    public var formatted: String {
        let characters: [Character] = base32(bytes: bytes)
        return stride(from: 0, to: characters.count, by: 4).map { String(characters[$0..<min($0 + 4, characters.count)]) }.joined(separator: "-")
    }
}

/// A new random recovery code.
public func newSyncRecoveryCode() -> SyncRecoveryCode {
    SyncRecoveryCode(bytes: SymmetricKey(size: SymmetricKeySize(bitCount: 160)).withUnsafeBytes { Data($0) })
}

private func base32(bytes: Data) -> [Character] {
    var output: [Character] = []
    var buffer: UInt32 = 0
    var bits: Int = 0
    for byte in bytes {
        buffer = (buffer << 8) | UInt32(byte)
        bits += 8
        while bits >= 5 {
            output.append(recoveryAlphabet[Int((buffer >> UInt32(bits - 5)) & 0x1F)])
            bits -= 5
        }
    }
    if bits > 0 {
        output.append(recoveryAlphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
    }
    return output
}

/// Reads a typed recovery code: case, spaces and dashes are ignored, O reads as 0 and I/L as 1. Anything else that is
/// not 32 code characters is `invalidRecoveryCode`. Pure function.
public func parseSyncRecoveryCode(text: String) throws -> SyncRecoveryCode {
    let cleaned: [Character] = text.uppercased().compactMap { (character: Character) -> Character? in
        switch character {
        case " ", "-", "\n", "\t": nil
        case "O": "0"
        case "I", "L": "1"
        default: character
        }
    }
    guard cleaned.count == 32 else {
        throw SyncCryptoError.invalidRecoveryCode
    }
    var bytes: [UInt8] = []
    var buffer: UInt32 = 0
    var bits: Int = 0
    for character in cleaned {
        guard let value = recoveryAlphabet.firstIndex(of: character) else {
            throw SyncCryptoError.invalidRecoveryCode
        }
        buffer = (buffer << 5) | UInt32(value)
        bits += 5
        if bits >= 8 {
            bytes.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
            bits -= 8
        }
    }
    return SyncRecoveryCode(bytes: Data(bytes))
}

private func recoveryWrappingKey(code: SyncRecoveryCode, userID: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: code.bytes), salt: Data(SyncLabel.recovery.utf8), info: Data(userID.utf8), outputByteCount: 32)
}

/// The recovery envelope stored on the server (`kind: recovery`): version, key id, then the account key sealed with
/// AES-GCM under a key derived from the code (HKDF-SHA256, the account as info). Base64 it for the server.
public func sealRecoveryEnvelope(accountKey: SyncAccountKey, code: SyncRecoveryCode, userID: String) throws -> Data {
    guard let keyID = Data(hexString: accountKey.keyID) else {
        throw SyncCryptoError.malformedBlob(byteCount: 0)
    }
    let sealed: AES.GCM.SealedBox = try AES.GCM.seal(
        accountKey.rawKey, using: recoveryWrappingKey(code: code, userID: userID), authenticating: framed([Data(SyncLabel.recovery.utf8), Data(userID.utf8), keyID])
    )
    guard let combined = sealed.combined else {
        throw SyncCryptoError.malformedBlob(byteCount: 0)
    }
    return Data([syncEnvelopeVersion]) + keyID + combined
}

/// Opens the recovery envelope with the typed code; a wrong code is `authenticationFailed`.
public func openRecoveryEnvelope(envelope: Data, code: SyncRecoveryCode, userID: String) throws -> SyncAccountKey {
    let bytes: [UInt8] = Array(envelope)
    guard bytes.count > 1 + 16 + 12 + 16, bytes[0] == syncEnvelopeVersion else {
        throw SyncCryptoError.malformedBlob(byteCount: bytes.count)
    }
    let keyID: Data = Data(bytes[1..<17])
    let box: AES.GCM.SealedBox = try AES.GCM.SealedBox(combined: Data(bytes[17...]))
    let raw: Data
    do {
        raw = try AES.GCM.open(box, using: recoveryWrappingKey(code: code, userID: userID), authenticating: framed([Data(SyncLabel.recovery.utf8), Data(userID.utf8), keyID]))
    } catch CryptoKitError.authenticationFailure {
        throw SyncCryptoError.authenticationFailed
    }
    let key: SyncAccountKey = try SyncAccountKey(rawKey: raw)
    guard key.keyID == keyID.hexString else {
        throw SyncCryptoError.keyMismatch(expected: keyID.hexString, found: key.keyID)
    }
    return key
}

// MARK: Add a device (pairing)

/// "Add a device" with a short code the user compares on both screens (numeric comparison with a commitment, as in
/// Bluetooth pairing). The server only relays the messages (`pairing` envelopes, 10-minute lifetime):
/// 1. New device: fresh X25519 key and nonce; sends `commitment` = hash(public key, nonce).
/// 2. Device holding the key: fresh X25519 key and nonce; sends its public key and nonce.
/// 3. New device: reveals its public key and nonce; the key holder checks them against the commitment.
/// 4. Both show `syncPairingCode(…)`; the user confirms the codes match on the key holder.
/// 5. Key holder sends `sealDeviceEnvelope` (account key sealed to the new device's key with its own key).
/// 6. New device opens it, checking the sender is the key from step 2.
/// A relay that swaps keys must commit before seeing the other nonce, so it matches the 6-digit code with chance 1 in
/// a million per attempt; each attempt is visible to the user as a mismatch.
public struct SyncPairingKey: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    /// 32 random bytes sent with the public key.
    public let nonce: Data

    /// The public key to send (32 bytes).
    public var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }
}

/// A fresh pairing key and nonce (one per pairing attempt).
public func newSyncPairingKey() -> SyncPairingKey {
    SyncPairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey(), nonce: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
}

/// Step 1: the new device's commitment to its public key and nonce. Pure function.
public func syncPairingCommitment(publicKey: Data, nonce: Data) -> Data {
    Data(SHA256.hash(data: framed([Data(SyncLabel.commitment.utf8), publicKey, nonce])))
}

/// Step 3 check on the key holder; a mismatch is `pairingCommitmentMismatch`. Pure function.
public func verifySyncPairingCommitment(commitment: Data, publicKey: Data, nonce: Data) throws {
    guard syncPairingCommitment(publicKey: publicKey, nonce: nonce) == commitment else {
        throw SyncCryptoError.pairingCommitmentMismatch
    }
}

/// Step 4: the six-digit code both screens show, from both public keys and nonces. Pure function.
public func syncPairingCode(newDevicePublicKey: Data, newDeviceNonce: Data, keyHolderPublicKey: Data, keyHolderNonce: Data) -> String {
    let digest: [UInt8] = Array(SHA256.hash(data: framed([Data(SyncLabel.pairingCode.utf8), newDevicePublicKey, newDeviceNonce, keyHolderPublicKey, keyHolderNonce])))
    let value: UInt32 = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    return String(format: "%06u", value % 1_000_000)
}

private func pairingWrappingKey(shared: SharedSecret, userID: String, pairingID: String, sender: Data, recipient: Data) -> SymmetricKey {
    shared.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: Data(SyncLabel.pairing.utf8), sharedInfo: framed([Data(userID.utf8), Data(pairingID.utf8), sender, recipient]),
        outputByteCount: 32
    )
}

/// Step 5: the account key sealed to the new device: X25519 between the key holder's pairing key and the new device's
/// public key, HKDF-SHA256 bound to the account, pairing id and both public keys, then AES-GCM. Layout: version,
/// sender public key (32), key id (16), sealed key.
public func sealDeviceEnvelope(accountKey: SyncAccountKey, sender: SyncPairingKey, recipientPublicKey: Data, userID: String, pairingID: String) throws -> Data {
    guard recipientPublicKey.count == 32 else {
        throw SyncCryptoError.invalidPublicKey(byteCount: recipientPublicKey.count)
    }
    let recipient: Curve25519.KeyAgreement.PublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
    guard let keyID = Data(hexString: accountKey.keyID) else {
        throw SyncCryptoError.malformedBlob(byteCount: 0)
    }
    let shared: SharedSecret = try sender.privateKey.sharedSecretFromKeyAgreement(with: recipient)
    let wrapping: SymmetricKey = pairingWrappingKey(shared: shared, userID: userID, pairingID: pairingID, sender: sender.publicKey, recipient: recipientPublicKey)
    let sealed: AES.GCM.SealedBox = try AES.GCM.seal(accountKey.rawKey, using: wrapping, authenticating: framed([Data(SyncLabel.pairing.utf8), keyID]))
    guard let combined = sealed.combined else {
        throw SyncCryptoError.malformedBlob(byteCount: 0)
    }
    return Data([syncEnvelopeVersion]) + sender.publicKey + keyID + combined
}

/// Step 6: opens the envelope with the new device's pairing key; the sender must be `expectedSenderPublicKey` (the key
/// whose code the user compared), otherwise `unexpectedPairingSender`.
public func openDeviceEnvelope(envelope: Data, recipient: SyncPairingKey, expectedSenderPublicKey: Data, userID: String, pairingID: String) throws -> SyncAccountKey {
    let bytes: [UInt8] = Array(envelope)
    guard bytes.count > 1 + 32 + 16 + 12 + 16, bytes[0] == syncEnvelopeVersion else {
        throw SyncCryptoError.malformedBlob(byteCount: bytes.count)
    }
    let senderKey: Data = Data(bytes[1..<33])
    guard senderKey == expectedSenderPublicKey else {
        throw SyncCryptoError.unexpectedPairingSender
    }
    let keyID: Data = Data(bytes[33..<49])
    let sender: Curve25519.KeyAgreement.PublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderKey)
    let shared: SharedSecret = try recipient.privateKey.sharedSecretFromKeyAgreement(with: sender)
    let wrapping: SymmetricKey = pairingWrappingKey(shared: shared, userID: userID, pairingID: pairingID, sender: senderKey, recipient: recipient.publicKey)
    let box: AES.GCM.SealedBox = try AES.GCM.SealedBox(combined: Data(bytes[49...]))
    let raw: Data
    do {
        raw = try AES.GCM.open(box, using: wrapping, authenticating: framed([Data(SyncLabel.pairing.utf8), keyID]))
    } catch CryptoKitError.authenticationFailure {
        throw SyncCryptoError.authenticationFailed
    }
    let key: SyncAccountKey = try SyncAccountKey(rawKey: raw)
    guard key.keyID == keyID.hexString else {
        throw SyncCryptoError.keyMismatch(expected: keyID.hexString, found: key.keyID)
    }
    return key
}
