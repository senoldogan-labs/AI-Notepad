import Foundation
import os

private let setupLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SyncSetup")

// Turning sync on and off and bringing the account key to another device (doc §8.3, plan 1B). The first device that
// turns sync on makes the account key and a link code (`SyncRecoveryCode`); the server keeps only the key sealed with
// the code (recovery envelope). Another device of the same account joins by typing that code, which this device shows
// in Settings; the same code restores the key if every device is lost. Neither the key nor the code reaches the server.

/// This device's copy of the account sync key and the link code that brings it to the account's other devices.
public struct SyncDeviceKey: Sendable, Equatable {
    public let accountKey: SyncAccountKey
    /// The link code in display form (`ABCD-EFGH-…`); shown in Settings so another device can join.
    public let code: String

    public init(accountKey: SyncAccountKey, code: String) {
        self.accountKey = accountKey
        self.code = code
    }
}

/// Where a device keeps its `SyncDeviceKey` (the apps: the account's Keychain item on this device only; tests: memory).
public protocol SyncKeyStore: Sendable {
    /// The stored key; nil when this device has none.
    func load() throws -> SyncDeviceKey?
    /// Stores the key, replacing any earlier one.
    func save(key: SyncDeviceKey) throws
    /// Removes the key; no error when there is none.
    func delete() throws
}

/// Sync setup failures with their own message in the apps.
public enum SyncSetupError: Error, Sendable, Equatable {
    /// The account has no link code on the server (sync was turned on by a device that did not finish setup).
    case noLinkCode
    /// The code opened an older key: sync was turned off and on again since; the current code is on the other device.
    case staleLinkCode
    /// The stored key text is not a key this app wrote.
    case unreadableStoredKey
}

/// Stored form of a `SyncDeviceKey` (Keychain item value).
private struct StoredSyncDeviceKey: Codable {
    let key: String
    let code: String
}

/// The Keychain text of a device key (raw key in base64 and the link code). Pure function.
public func encodedSyncDeviceKey(key: SyncDeviceKey) throws -> String {
    let data: Data = try JSONEncoder().encode(StoredSyncDeviceKey(key: key.accountKey.rawKey.base64EncodedString(), code: key.code))
    return String(decoding: data, as: UTF8.self)
}

/// Reads the Keychain text written by `encodedSyncDeviceKey`; anything else is `unreadableStoredKey`. Pure function.
public func decodedSyncDeviceKey(text: String) throws -> SyncDeviceKey {
    guard let stored = try? JSONDecoder().decode(StoredSyncDeviceKey.self, from: Data(text.utf8)), let raw = Data(base64Encoded: stored.key) else {
        throw SyncSetupError.unreadableStoredKey
    }
    return SyncDeviceKey(accountKey: try SyncAccountKey(rawKey: raw), code: stored.code)
}

/// What starting sync on this device found.
public enum SyncStartOutcome: Sendable, Equatable {
    /// Sync runs with this key. `createdAccountKey`: this device turned sync on for the account just now (everything
    /// local goes up).
    case ready(key: SyncDeviceKey, createdAccountKey: Bool)
    /// Another device turned sync on with its key: the user types the link code shown there (`joinSync`).
    case needsLinkCode
}

/// Starts sync for the signed-in account: with the stored key when the account's sync uses it; otherwise, when sync is
/// off for the account, it is turned on with a new key and link code (key stored on this device first, then the server
/// is told, then the sealed key is stored for other devices; a run interrupted midway finishes on the next start). When
/// another key is on the account (also when two devices turn sync on at once), the user must type that device's code.
public func startSync(client: HostedSyncClient, keyStore: any SyncKeyStore, userID: String) async throws -> SyncStartOutcome {
    let account: HostedSyncAccount = try await client.account()
    let stored: SyncDeviceKey? = try keyStore.load()
    if account.enabled, let accountKeyID = account.keyId {
        guard let stored, stored.accountKey.keyID == accountKeyID else {
            setupLogger.notice("Sync is on for the account with another key, link code needed")
            return .needsLinkCode
        }
        try await ensureLinkCodeEnvelope(client: client, key: stored, userID: userID)
        return .ready(key: stored, createdAccountKey: false)
    }
    // Sync is off for the account. A key stored here belongs to an earlier, wiped copy: a fresh key and code.
    let fresh: SyncDeviceKey = SyncDeviceKey(accountKey: newSyncAccountKey(), code: newSyncRecoveryCode().formatted)
    try keyStore.save(key: fresh)
    do {
        _ = try await client.enable(keyID: fresh.accountKey.keyID)
    } catch HostedSyncError.keyMismatch {
        // Another device turned sync on in the meantime.
        try keyStore.delete()
        setupLogger.notice("Another device turned sync on meanwhile, link code needed")
        return .needsLinkCode
    }
    try await ensureLinkCodeEnvelope(client: client, key: fresh, userID: userID)
    setupLogger.info("Sync turned on with a new account key")
    return .ready(key: fresh, createdAccountKey: true)
}

/// Stores the key sealed with the link code on the server when it is not there yet (a start interrupted after turning
/// sync on).
private func ensureLinkCodeEnvelope(client: HostedSyncClient, key: SyncDeviceKey, userID: String) async throws {
    let envelopes: [HostedSyncEnvelope] = try await client.envelopes()
    guard !envelopes.contains(where: { $0.kind == .recovery }) else {
        return
    }
    let code: SyncRecoveryCode = try parseSyncRecoveryCode(text: key.code)
    try await client.putEnvelope(envelopeID: newSyncObjectID(), kind: .recovery, ciphertext: try sealRecoveryEnvelope(accountKey: key.accountKey, code: code, userID: userID))
    setupLogger.info("Link code envelope stored")
}

/// Joins the account's sync with the link code typed from another device: the sealed key is downloaded, opened with the
/// code (a wrong code is `SyncCryptoError.authenticationFailed`, a mistyped one `invalidRecoveryCode`) and stored here.
/// Sync off for the account is `HostedSyncError.notEnabled`.
public func joinSync(client: HostedSyncClient, keyStore: any SyncKeyStore, userID: String, codeText: String) async throws -> SyncDeviceKey {
    let code: SyncRecoveryCode = try parseSyncRecoveryCode(text: codeText)
    let account: HostedSyncAccount = try await client.account()
    guard account.enabled, let accountKeyID = account.keyId else {
        throw HostedSyncError.notEnabled
    }
    let envelopes: [HostedSyncEnvelope] = try await client.envelopes()
    guard let envelope = envelopes.first(where: { $0.kind == .recovery }), let sealed = Data(base64Encoded: envelope.ciphertext) else {
        throw SyncSetupError.noLinkCode
    }
    let accountKey: SyncAccountKey = try openRecoveryEnvelope(envelope: sealed, code: code, userID: userID)
    guard accountKey.keyID == accountKeyID else {
        throw SyncSetupError.staleLinkCode
    }
    let key: SyncDeviceKey = SyncDeviceKey(accountKey: accountKey, code: code.formatted)
    try keyStore.save(key: key)
    setupLogger.info("Joined the account's sync with the link code")
    return key
}

/// Turns sync off for the account: the server copy is deleted (every device stops syncing; meetings on the devices
/// stay), then this device forgets its key and bookkeeping. The engine must be stopped first.
public func stopSync(client: HostedSyncClient, keyStore: any SyncKeyStore, metadataDirectory: URL) async throws {
    _ = try await client.disableAndWipe()
    try forgetSyncOnDevice(keyStore: keyStore, metadataDirectory: metadataDirectory)
}

/// Forgets sync on this device only (sync was turned off on another device, or the account's key changed): the key and
/// the `.sync` bookkeeping go; meetings and everything else stay. The engine must be stopped first.
public func forgetSyncOnDevice(keyStore: any SyncKeyStore, metadataDirectory: URL) throws {
    try keyStore.delete()
    guard FileManager.default.fileExists(atPath: metadataDirectory.path) else {
        return
    }
    do {
        try FileManager.default.removeItem(at: metadataDirectory)
    } catch {
        throw StorageError.deleteFailed(path: metadataDirectory.path, reason: error.localizedDescription)
    }
}

/// How a failed sync pass or setup step is handled by the apps.
public enum SyncFailureKind: Sendable, Equatable {
    /// Network or a temporary server error: retried with backoff.
    case transient
    /// Sync was turned off for the account (on another device): this device stops and forgets its key.
    case turnedOffElsewhere
    /// The account's key is not this device's (sync was reset elsewhere): the link code is needed again.
    case needsLinkCode
    /// The server has sync turned off (`SYNC_POLICY=off`): nothing to do until it comes back.
    case unavailable
    /// The account's server copy is full: retried later, the user is told.
    case quotaExceeded
    /// Uploads need an active subscription or trial; downloads still work.
    case subscriptionRequired
    /// Anything else (local file errors, a malformed object): retried with backoff, shown to the user.
    case other
}

/// Classifies a sync error. Pure function.
public func syncFailureKind(error: any Error) -> SyncFailureKind {
    switch error {
    case HostedSyncError.notEnabled:
        return .turnedOffElsewhere
    case HostedSyncError.keyMismatch:
        return .needsLinkCode
    case HostedSyncError.unavailable:
        return .unavailable
    case HostedSyncError.quotaExceeded:
        return .quotaExceeded
    case let apiError as HostedAPIError where apiError.code == .subscriptionRequired:
        return .subscriptionRequired
    case let apiError as HostedAPIError where apiError.status >= 500 || apiError.status == 429:
        return .transient
    case HostedClientError.network:
        return .transient
    case is URLError:
        return .transient
    default:
        return .other
    }
}

/// Wait before retrying after `failures` failed passes in a row (1 = the first failure): 30 s, doubling, at most 15
/// minutes. Pure function.
public func syncRetryDelaySeconds(failures: Int) -> Double {
    let exponent: Int = max(0, min(failures - 1, 5))
    return min(30 * Double(1 << exponent), 900)
}

/// Items that changed between two snapshots of a list keyed by id (added, removed or different). Pure function.
public func changedSyncIDs<ID: Hashable, Value: Equatable>(old: [ID: Value], new: [ID: Value]) -> Set<ID> {
    let removed: Set<ID> = Set(old.keys).subtracting(new.keys)
    let changed: [ID] = new.compactMap { (id: ID, value: Value) -> ID? in old[id] == value ? nil : id }
    return removed.union(changed)
}
