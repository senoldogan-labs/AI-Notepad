import CryptoKit
import Foundation
import Testing
@testable import AINotepadCore

private let userID: String = "6b1f0f5e-6a3e-4d2c-9a57-0d1f2c3b4a59"
private let objectID: String = "0c9e8a52-7a8b-4d3e-8f1a-2b3c4d5e6f70"

/// Blob with one byte flipped at `index`.
private func flipped(_ data: Data, at index: Int) -> Data {
    var bytes: [UInt8] = Array(data)
    bytes[index] ^= 0x01
    return Data(bytes)
}

@Suite struct SyncCryptoTests {
    @Test func objectRoundTripAndHeader() throws {
        let key: SyncAccountKey = newSyncAccountKey()
        let payload: Data = Data("{\"schema\":1}".utf8)
        let blob: Data = try sealSyncObject(payload: payload, accountKey: key, userID: userID, objectID: objectID, kind: .meetingState, baseRevision: 7)
        let header: SyncBlobHeader = try syncBlobHeader(blob: blob)
        #expect(header == SyncBlobHeader(keyID: key.keyID, baseRevision: 7))
        #expect(blob.prefix(4) == Data("GSY1".utf8))
        #expect(blob.count == 28 + 12 + payload.count + 16)
        #expect(try openSyncObject(blob: blob, accountKey: key, userID: userID, objectID: objectID, kind: .meetingState, servedRevision: 8) == payload)
        // The plaintext never appears in the blob.
        #expect(blob.range(of: payload) == nil)
        // A fresh nonce every time: sealing twice gives different blobs.
        #expect(try sealSyncObject(payload: payload, accountKey: key, userID: userID, objectID: objectID, kind: .meetingState, baseRevision: 7) != blob)
    }

    // The server (or anyone on the way) cannot alter a blob, move it to another object, kind or account, replay an old
    // copy as newer, or pass off a blob sealed with another key.
    @Test func tamperingIsDetected() throws {
        let key: SyncAccountKey = newSyncAccountKey()
        let blob: Data = try sealSyncObject(payload: Data(repeating: 65, count: 100), accountKey: key, userID: userID, objectID: objectID, kind: .meetingState, baseRevision: 3)
        let open: (Data, String, SyncObjectKind, String, UInt64) throws -> Data = { (data: Data, object: String, kind: SyncObjectKind, user: String, served: UInt64) throws -> Data in
            try openSyncObject(blob: data, accountKey: key, userID: user, objectID: object, kind: kind, servedRevision: served)
        }
        #expect(throws: SyncCryptoError.authenticationFailed) { try open(flipped(blob, at: blob.count - 1), objectID, .meetingState, userID, 4) }
        #expect(throws: SyncCryptoError.authenticationFailed) { try open(flipped(blob, at: 50), objectID, .meetingState, userID, 4) }
        #expect(throws: SyncCryptoError.authenticationFailed) { try open(blob, "11111111-2222-4333-8444-555555555555", .meetingState, userID, 4) }
        #expect(throws: SyncCryptoError.authenticationFailed) { try open(blob, objectID, .meetingContent, userID, 4) }
        #expect(throws: SyncCryptoError.authenticationFailed) { try open(blob, objectID, .meetingState, "someone-else", 4) }
        // Lowering the base revision in the header (to serve it after a newer one) breaks the tag.
        #expect(throws: SyncCryptoError.authenticationFailed) { try open(flipped(blob, at: 27), objectID, .meetingState, userID, 4) }
        #expect(throws: SyncCryptoError.staleRevision(baseRevision: 3, servedRevision: 3)) { try open(blob, objectID, .meetingState, userID, 3) }
        let other: SyncAccountKey = newSyncAccountKey()
        #expect(throws: SyncCryptoError.keyMismatch(expected: other.keyID, found: key.keyID)) {
            try openSyncObject(blob: blob, accountKey: other, userID: userID, objectID: objectID, kind: .meetingState, servedRevision: 4)
        }
        #expect(throws: SyncCryptoError.malformedBlob(byteCount: 10)) { try open(blob.prefix(10), objectID, .meetingState, userID, 4) }
        #expect(throws: SyncCryptoError.malformedBlob(byteCount: blob.count)) { try open(flipped(blob, at: 0), objectID, .meetingState, userID, 4) }
    }

    @Test func accountKeyRoundTripAndKeyID() throws {
        let key: SyncAccountKey = newSyncAccountKey()
        let restored: SyncAccountKey = try SyncAccountKey(rawKey: key.rawKey)
        #expect(restored == key && restored.keyID == key.keyID)
        #expect(key.keyID.count == 32 && key.keyID.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(newSyncAccountKey().keyID != key.keyID)
        #expect(throws: SyncCryptoError.invalidKeyLength(byteCount: 16)) { try SyncAccountKey(rawKey: Data(count: 16)) }
        // Fixed key → fixed id (the id is part of every blob and of the server's account row).
        let fixed: SyncAccountKey = try SyncAccountKey(rawKey: Data(0..<32))
        #expect(fixed.keyID == Data(HMAC<SHA256>.authenticationCode(for: Data("gistsmith.sync.v1.key-id".utf8), using: SymmetricKey(data: Data(0..<32))).prefix(16)).map { String(format: "%02x", $0) }.joined())
    }

    @Test func derivedObjectIDsAreStableUUIDsPerKindAndKey() throws {
        let key: SyncAccountKey = try SyncAccountKey(rawKey: Data(0..<32))
        let people: String = derivedSyncObjectID(accountKey: key, kind: .people, localID: "")
        #expect(people == derivedSyncObjectID(accountKey: key, kind: .people, localID: ""))
        #expect(people != derivedSyncObjectID(accountKey: key, kind: .prefs, localID: ""))
        #expect(people != derivedSyncObjectID(accountKey: newSyncAccountKey(), kind: .people, localID: ""))
        let chat: String = derivedSyncObjectID(accountKey: key, kind: .askChat, localID: "A0C1E2F3-0000-4000-8000-000000000001")
        // The server accepts lowercase RFC 9562 UUIDs only (version 1-8, variant 10).
        for id in [people, chat, newSyncObjectID()] {
            #expect(id.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil, "\(id)")
        }
    }

    @Test func recoveryCodeFormatsParsesAndUnlocksTheKey() throws {
        let key: SyncAccountKey = newSyncAccountKey()
        let code: SyncRecoveryCode = newSyncRecoveryCode()
        #expect(code.formatted.wholeMatch(of: /([0-9A-HJKMNP-TV-Z]{4}-){7}[0-9A-HJKMNP-TV-Z]{4}/) != nil, "\(code.formatted)")
        #expect(try parseSyncRecoveryCode(text: code.formatted) == code)
        // Typed loosely: lowercase, spaces, O for 0 and I/L for 1.
        let loose: String = code.formatted.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")
        #expect(try parseSyncRecoveryCode(text: loose) == code)
        #expect(throws: SyncCryptoError.invalidRecoveryCode) { try parseSyncRecoveryCode(text: "ABCD-EFGH") }
        #expect(throws: SyncCryptoError.invalidRecoveryCode) { try parseSyncRecoveryCode(text: String(repeating: "U", count: 32)) }

        let envelope: Data = try sealRecoveryEnvelope(accountKey: key, code: code, userID: userID)
        #expect(envelope.range(of: key.rawKey) == nil)
        #expect(envelope.base64EncodedString().count <= SyncLimits.envelopeMaxChars)
        #expect(try openRecoveryEnvelope(envelope: envelope, code: code, userID: userID) == key)
        #expect(throws: SyncCryptoError.authenticationFailed) { try openRecoveryEnvelope(envelope: envelope, code: newSyncRecoveryCode(), userID: userID) }
        #expect(throws: SyncCryptoError.authenticationFailed) { try openRecoveryEnvelope(envelope: envelope, code: code, userID: "another-account") }
        #expect(throws: SyncCryptoError.authenticationFailed) { try openRecoveryEnvelope(envelope: flipped(envelope, at: 5), code: code, userID: userID) }
    }

    // The whole "add a device" exchange, then a relay that swaps the new device's key: the commitment or the code
    // gives it away, and an envelope from another sender is refused.
    @Test func pairingDeliversTheKeyAndDetectsAKeySwap() throws {
        let accountKey: SyncAccountKey = newSyncAccountKey()
        let pairingID: String = newSyncObjectID()
        let newDevice: SyncPairingKey = newSyncPairingKey()
        let holder: SyncPairingKey = newSyncPairingKey()
        let commitment: Data = syncPairingCommitment(publicKey: newDevice.publicKey, nonce: newDevice.nonce)
        try verifySyncPairingCommitment(commitment: commitment, publicKey: newDevice.publicKey, nonce: newDevice.nonce)
        let codeOnHolder: String = syncPairingCode(newDevicePublicKey: newDevice.publicKey, newDeviceNonce: newDevice.nonce, keyHolderPublicKey: holder.publicKey, keyHolderNonce: holder.nonce)
        let codeOnNewDevice: String = syncPairingCode(newDevicePublicKey: newDevice.publicKey, newDeviceNonce: newDevice.nonce, keyHolderPublicKey: holder.publicKey, keyHolderNonce: holder.nonce)
        #expect(codeOnHolder == codeOnNewDevice && codeOnHolder.wholeMatch(of: /[0-9]{6}/) != nil)
        let envelope: Data = try sealDeviceEnvelope(accountKey: accountKey, sender: holder, recipientPublicKey: newDevice.publicKey, userID: userID, pairingID: pairingID)
        #expect(envelope.range(of: accountKey.rawKey) == nil)
        #expect(try openDeviceEnvelope(envelope: envelope, recipient: newDevice, expectedSenderPublicKey: holder.publicKey, userID: userID, pairingID: pairingID) == accountKey)

        // A relay revealing its own key instead of the committed one fails the commitment check.
        let relay: SyncPairingKey = newSyncPairingKey()
        #expect(throws: SyncCryptoError.pairingCommitmentMismatch) {
            try verifySyncPairingCommitment(commitment: commitment, publicKey: relay.publicKey, nonce: relay.nonce)
        }
        // A relay that also replaced the commitment shows a different code on the key holder than on the new device.
        let codeWithRelay: String = syncPairingCode(newDevicePublicKey: relay.publicKey, newDeviceNonce: relay.nonce, keyHolderPublicKey: holder.publicKey, keyHolderNonce: holder.nonce)
        #expect(codeWithRelay != codeOnNewDevice)
        // An envelope sealed by anyone but the compared key holder is refused; the wrong recipient cannot open it.
        let forged: Data = try sealDeviceEnvelope(accountKey: newSyncAccountKey(), sender: relay, recipientPublicKey: newDevice.publicKey, userID: userID, pairingID: pairingID)
        #expect(throws: SyncCryptoError.unexpectedPairingSender) {
            try openDeviceEnvelope(envelope: forged, recipient: newDevice, expectedSenderPublicKey: holder.publicKey, userID: userID, pairingID: pairingID)
        }
        #expect(throws: SyncCryptoError.authenticationFailed) {
            try openDeviceEnvelope(envelope: envelope, recipient: relay, expectedSenderPublicKey: holder.publicKey, userID: userID, pairingID: pairingID)
        }
        #expect(throws: SyncCryptoError.authenticationFailed) {
            try openDeviceEnvelope(envelope: envelope, recipient: newDevice, expectedSenderPublicKey: holder.publicKey, userID: userID, pairingID: newSyncObjectID())
        }
        #expect(throws: SyncCryptoError.invalidPublicKey(byteCount: 5)) {
            try sealDeviceEnvelope(accountKey: accountKey, sender: holder, recipientPublicKey: Data(count: 5), userID: userID, pairingID: pairingID)
        }
    }
}
