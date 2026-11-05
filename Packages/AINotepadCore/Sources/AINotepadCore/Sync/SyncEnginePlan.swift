import CryptoKit
import Foundation

// Pure decisions of the sync engine (`SyncEngine` only sequences the I/O): which local items to check for upload, how a
// meeting's local copy becomes a `meeting.state` payload (and back), where an incoming meeting lands, and how an
// incoming version meets unsynced local edits. Design: docs/superpowers/specs/2026-11-03-mac-iphone-sync-options.md §8.

/// Name of the account's sync bookkeeping folder (`Accounts/<key>/.sync`): ledger, pending queue and merge bases.
public let syncFolderName: String = ".sync"

public extension AppPaths {
    /// The account's sync bookkeeping folder: `<data folder>/Accounts/<key>/.sync`. Pure function.
    static func accountSyncDirectory(dataRoot: URL, accountKey: String) -> URL {
        accountDataDirectory(dataRoot: dataRoot, accountKey: accountKey).appending(path: syncFolderName, directoryHint: .isDirectory)
    }
}

/// Something local that may need uploading (or deleting on the server).
public enum SyncLocalItem: Sendable, Hashable, Codable {
    /// A meeting by folder name (`MeetingRecord.id`).
    case meeting(id: String)
    /// An Ask conversation by id.
    case askChat(id: UUID)
    /// The people book.
    case people
    /// Saved folders and the user's Ask recipes.
    case prefs
}

/// The engine's persisted to-do list (`.sync/pending.json`): local items changed since their last upload, and server
/// objects whose download waits (a long note job runs on the meeting, or the app wrote it meanwhile).
public struct SyncPending: Sendable, Equatable, Codable {
    /// Items to check for upload, oldest first, without repeats.
    public let items: [SyncLocalItem]
    /// Object id → kind of downloads to retry on the next pass.
    public let deferred: [String: SyncObjectKind]

    public init(items: [SyncLocalItem], deferred: [String: SyncObjectKind]) {
        self.items = items
        self.deferred = deferred
    }

    public static let empty: SyncPending = SyncPending(items: [], deferred: [:])
}

/// The pending list with `added` appended (items already queued keep their place). Pure function.
public func addingPendingItems(pending: SyncPending, added: [SyncLocalItem]) -> SyncPending {
    let items: [SyncLocalItem] = added.reduce(pending.items) { (result: [SyncLocalItem], item: SyncLocalItem) -> [SyncLocalItem] in
        result.contains(item) ? result : result + [item]
    }
    return SyncPending(items: items, deferred: pending.deferred)
}

/// The pending list without `item`. Pure function.
public func removingPendingItem(pending: SyncPending, item: SyncLocalItem) -> SyncPending {
    SyncPending(items: pending.items.filter { $0 != item }, deferred: pending.deferred)
}

/// The pending list with a download to retry (`kind` nil removes it). Pure function.
public func settingDeferred(pending: SyncPending, objectID: String, kind: SyncObjectKind?) -> SyncPending {
    var deferred: [String: SyncObjectKind] = pending.deferred
    deferred[objectID] = kind
    return SyncPending(items: pending.items, deferred: deferred)
}

/// Merge base of a `meeting.content` object: only its digest (content is last-writer-wins, so no three-way merge needs
/// the text, and a second copy of the transcript would double the disk use).
public struct SyncContentBase: Sendable, Equatable, Codable {
    public let digest: String

    public init(digest: String) {
        self.digest = digest
    }
}

/// Hex SHA-256 of a payload's canonical JSON: equal values give equal digests. Pure function.
public func syncDigest<Value: Encodable>(value: Value) throws -> String {
    SHA256.hash(data: try canonicalSyncJSON(value: value)).map { String(format: "%02x", $0) }.joined()
}

/// A date cut to whole seconds: meeting files store dates as ISO 8601 seconds, so a field clock or a "kept from the other
/// device" note time written to disk reads back unchanged (no endless re-upload of a rounded value). Pure function.
public func syncWholeSecond(date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
}

/// The `meeting.content` of a local meeting. Pure function.
public func meetingSyncContent(record: MeetingRecord) -> MeetingSyncContent {
    meetingSyncParts(record: record, contentObjectID: "", originDeviceID: "", clocks: [:]).content
}

/// `meeting.state` of a meeting this device already synced: identity (folder name on the recording device, content
/// object, recording device) and clocks from the last synced version `base`, fields changed since then stamped `now`.
/// Equal to `base` when nothing changed. Pure function.
public func uploadMeetingState(record: MeetingRecord, base: MeetingSyncState, now: Date) throws -> MeetingSyncState {
    let state: MeetingSyncState = meetingSyncParts(record: record, contentObjectID: base.contentObjectID, originDeviceID: base.originDeviceID, clocks: base.fieldClocks)
        .state
        .with(meetingID: base.meetingID, contentObjectID: base.contentObjectID, originDeviceID: base.originDeviceID)
    return try stampingChanges(previous: base, updated: state, now: now)
}

/// `meeting.state` of a meeting never synced (recorded here): every present field stamped `now`. Pure function.
public func newMeetingState(record: MeetingRecord, contentObjectID: String, originDeviceID: String, now: Date) throws -> MeetingSyncState {
    try stampingChanges(
        previous: nil, updated: meetingSyncParts(record: record, contentObjectID: contentObjectID, originDeviceID: originDeviceID, clocks: [:]).state, now: now
    )
}

/// A local meeting found to be the same as an incoming one without a merge base (this device's sync bookkeeping was
/// reset): the remote identity, no field clocks, so a field both versions set differently follows the server copy other
/// devices already show; sets are united by the merge. Pure function.
public func adoptedMeetingState(record: MeetingRecord, remote: MeetingSyncState) -> MeetingSyncState {
    meetingSyncParts(record: record, contentObjectID: remote.contentObjectID, originDeviceID: remote.originDeviceID, clocks: [:])
        .state
        .with(meetingID: remote.meetingID, contentObjectID: remote.contentObjectID, originDeviceID: remote.originDeviceID)
}

/// The local meeting of a synced state and content in folder `localID` (which may differ from the state's folder name;
/// see `incomingMeetingFolder`). `voiceprints` are this device's own. Pure function.
public func localMeetingRecord(state: MeetingSyncState, content: MeetingSyncContent, localID: String, voiceprints: [Int: Voiceprint]?) -> MeetingRecord {
    joinedMeetingRecord(
        state: state.with(meetingID: localID, contentObjectID: state.contentObjectID, originDeviceID: state.originDeviceID), content: content,
        voiceprints: voiceprints
    )
}

/// A local meeting with another device's processing result (`meeting.content`); what people edit stays. Pure function.
public func replacingContent(record: MeetingRecord, content: MeetingSyncContent) -> MeetingRecord {
    localMeetingRecord(
        state: meetingSyncParts(record: record, contentObjectID: "", originDeviceID: "", clocks: [:]).state, content: content, localID: record.id,
        voiceprints: record.voiceprints
    )
}

/// Folder for a meeting arriving from another device: its own name, or with `-2`, `-3`… when a different local meeting
/// already uses it (two devices started recording in the same second; doc §8.5). Pure function.
public func incomingMeetingFolder(meetingID: String, taken: Set<String>) -> String {
    guard taken.contains(meetingID) else {
        return meetingID
    }
    var suffix: Int = 2
    while taken.contains("\(meetingID)-\(suffix)") {
        suffix += 1
    }
    return "\(meetingID)-\(suffix)"
}

/// What a local copy becomes when a newer server version arrives.
public struct SyncResolution<Value: Sendable & Equatable>: Sendable, Equatable {
    /// The new local copy.
    public let local: Value
    /// The local copy kept unsynced edits the server version lacks: upload it next.
    public let needsUpload: Bool
}

/// Incoming server version against the local copy: no local copy or no local edits since `base` → the server version;
/// otherwise both are merged (`merge(base, local, remote)`) and the result is uploaded if it differs from the server's.
/// Pure function.
public func resolvingIncoming<Value: Sendable & Equatable>(
    base: Value?, local: Value?, remote: Value, merge: (Value?, Value, Value) -> Value
) -> SyncResolution<Value> {
    guard let local, local != remote else {
        return SyncResolution(local: remote, needsUpload: false)
    }
    if let base, local == base {
        return SyncResolution(local: remote, needsUpload: false)
    }
    let merged: Value = merge(base, local, remote)
    return SyncResolution(local: merged, needsUpload: merged != remote)
}

/// The ledger entry of a local item of `kind` (meetings have a state and a content entry with the same folder). Pure
/// function.
public func ledgerEntry(ledger: SyncLedger, kind: SyncObjectKind, localID: String) -> SyncLedgerEntry? {
    ledger.entries.values.filter { $0.kind == kind && $0.localID == localID }.min { $0.objectID < $1.objectID }
}

/// The ledger without an object. Pure function.
public func removingEntry(ledger: SyncLedger, objectID: String) -> SyncLedger {
    var entries: [String: SyncLedgerEntry] = ledger.entries
    entries[objectID] = nil
    return SyncLedger(epoch: ledger.epoch, cursor: ledger.cursor, entries: entries)
}

/// Local ids the ledger knows for a kind. Pure function.
private func syncedLocalIDs(ledger: SyncLedger, kind: SyncObjectKind) -> Set<String> {
    Set(ledger.entries.values.filter { $0.kind == kind }.map(\.localID))
}

/// Items one upload pass checks: the queued ones, meetings and chats that are new here (not in the ledger) or gone here
/// (in the ledger, no longer on disk: deleted, so their server copy is deleted too), and the two small account objects
/// (people, prefs; cheap to compare every time). Pure function.
public func syncPushItems(pending: [SyncLocalItem], ledger: SyncLedger, localMeetingIDs: Set<String>, localChatIDs: Set<UUID>) -> [SyncLocalItem] {
    let syncedMeetings: Set<String> = syncedLocalIDs(ledger: ledger, kind: .meetingState)
    let syncedChats: Set<UUID> = Set(syncedLocalIDs(ledger: ledger, kind: .askChat).compactMap { UUID(uuidString: $0) })
    let meetings: [SyncLocalItem] = localMeetingIDs.symmetricDifference(syncedMeetings).sorted().map { SyncLocalItem.meeting(id: $0) }
    let chats: [SyncLocalItem] = localChatIDs.symmetricDifference(syncedChats).sorted { $0.uuidString < $1.uuidString }.map { SyncLocalItem.askChat(id: $0) }
    return addingPendingItems(pending: SyncPending(items: pending, deferred: [:]), added: meetings + chats + [.people, .prefs]).items
}

/// Object id of an Ask conversation: derived from the account key and the chat id, so every device names it alike.
/// Pure function.
public func askChatSyncObjectID(accountKey: SyncAccountKey, chatID: UUID) -> String {
    derivedSyncObjectID(accountKey: accountKey, kind: .askChat, localID: chatID.uuidString)
}

/// Object id of an account singleton (people, prefs). Pure function.
public func singletonSyncObjectID(accountKey: SyncAccountKey, kind: SyncObjectKind) -> String {
    derivedSyncObjectID(accountKey: accountKey, kind: kind, localID: "")
}

/// Preferences with nothing to share (a fresh device does not upload an empty copy). Pure function.
public func isEmptySyncPrefs(prefs: SyncPrefs) -> Bool {
    prefs.folders.isEmpty && prefs.recipes.isEmpty && (prefs.settings ?? [:]).isEmpty
}

/// Whether a server object id is the lowercase UUID the server stores (ids become file names under `.sync/bases`, so a
/// malformed one is refused). Pure function.
public func isSyncObjectID(value: String) -> Bool {
    value.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil
}

/// Whether a meeting folder name from another device is safe to create under `Sessions` (one visible path component).
/// Pure function.
public func isSafeMeetingFolderName(value: String) -> Bool {
    !value.isEmpty && value.count <= 200 && !value.hasPrefix(".") && !value.contains("/") && !value.contains(":") && !value.contains("\0")
}

/// Errors of the sync engine itself.
public enum SyncEngineError: Error, Sendable, Equatable {
    /// The object kept changing on other devices during `rounds` merge-and-retry rounds; tried again next pass.
    case conflictRoundsExhausted(objectID: String, rounds: Int)
    /// The server sent an object id that is not a lowercase UUID.
    case invalidObjectID(value: String)
    /// A synced meeting's folder name is not a safe folder name.
    case invalidMeetingFolder(objectID: String)
    /// The server stores the object as another kind than expected.
    case kindMismatch(objectID: String, expected: SyncObjectKind, found: SyncObjectKind)
    /// An account object (people, prefs) is deleted on the server; only turning sync off and on again restores it.
    case singletonDeleted(kind: SyncObjectKind)
}

/// Whether a failure concerns one object only (record it, keep syncing the rest, retry next pass) rather than the whole
/// account or the connection (stop the pass). Pure function.
public func isItemSyncError(error: any Error) -> Bool {
    switch error {
    case let syncError as HostedSyncError:
        switch syncError {
        case .objectTooLarge, .objectNotFound, .conflict:
            return true
        case .cursorExpired, .keyMismatch, .notEnabled, .quotaExceeded, .unavailable:
            return false
        }
    case let cryptoError as SyncCryptoError:
        if case .keyMismatch = cryptoError {
            return false
        }
        return true
    case is SyncPayloadError, is SyncEngineError, is StorageError, is SyncedSettingsError:
        return true
    default:
        return false
    }
}
