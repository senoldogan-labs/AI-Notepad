import Foundation

// Revision and tombstone bookkeeping on the device (pure; the 1B sync engine persists the ledger and runs the actions).
// The ledger remembers, per synced object, what it is locally and which server revision the local copy is based on.
// Applying a page of the change feed yields what to do: download a newer version, delete the local copy for a
// tombstone, or nothing (an echo of this device's own write). After `sync_cursor_expired` the device lists everything
// from 0; tombstones older than 90 days are gone from that listing, so a ledger entry the full listing lacks was
// deleted on another device (`missingFromFullListing`).

/** One synced object as this device knows it. */
public struct SyncLedgerEntry: Sendable, Equatable, Codable {
    public let objectID: String
    public let kind: SyncObjectKind
    /// The local identity: meeting folder name, Ask chat id; empty for the account singletons (people, prefs).
    public let localID: String
    /// Server revision the local copy (and the stored merge base) is based on; 0 before the first upload.
    public let baseRevision: UInt64

    public init(objectID: String, kind: SyncObjectKind, localID: String, baseRevision: UInt64) {
        self.objectID = objectID
        self.kind = kind
        self.localID = localID
        self.baseRevision = baseRevision
    }
}

/** The device's view of the account's synced objects and its position in the change feed. */
public struct SyncLedger: Sendable, Equatable, Codable {
    /// Account epoch the cursor belongs to (`HostedSyncChanges.epoch`); nil before the first listing.
    public let epoch: Int64?
    /// Last change revision applied.
    public let cursor: UInt64
    /// Object id → entry.
    public let entries: [String: SyncLedgerEntry]

    public init(epoch: Int64?, cursor: UInt64, entries: [String: SyncLedgerEntry]) {
        self.epoch = epoch
        self.cursor = cursor
        self.entries = entries
    }

    public static let empty: SyncLedger = SyncLedger(epoch: nil, cursor: 0, entries: [:])
}

/** What a change means for this device. */
public enum SyncAction: Sendable, Equatable {
    /// A newer server version: download it and apply it (merging when the local copy has unsynced edits).
    case download(objectID: String, kind: SyncObjectKind, revision: UInt64)
    /// Deleted on another device: remove the local copy (`entry` says which one).
    case deleteLocal(entry: SyncLedgerEntry)
    /// Deleted on the server but never seen here: just record that it is gone.
    case forget(objectID: String)
}

/** Actions of one change page and the ledger after it (cursor moved, tombstones dropped). Pure function. */
public func applyingChanges(ledger: SyncLedger, changes: [HostedSyncChange], epoch: Int64, cursor: UInt64) -> (ledger: SyncLedger, actions: [SyncAction]) {
    var entries: [String: SyncLedgerEntry] = ledger.entries
    var actions: [SyncAction] = []
    for change in changes {
        let known: SyncLedgerEntry? = entries[change.objectId]
        if change.deleted {
            entries[change.objectId] = nil
            actions.append(known.map { SyncAction.deleteLocal(entry: $0) } ?? .forget(objectID: change.objectId))
        } else if known.map({ $0.baseRevision < change.rev }) ?? true {
            // Unknown, or newer than the local base. A change equal to the base is this device's own write coming back.
            actions.append(.download(objectID: change.objectId, kind: change.kind, revision: change.rev))
        }
    }
    return (SyncLedger(epoch: epoch, cursor: max(ledger.epoch == epoch ? ledger.cursor : 0, cursor), entries: entries), actions)
}

/** The ledger after this device wrote (or downloaded and applied) `revision` of an object. Pure function. */
public func recordingRevision(ledger: SyncLedger, entry: SyncLedgerEntry) -> SyncLedger {
    var entries: [String: SyncLedgerEntry] = ledger.entries
    entries[entry.objectID] = entry
    return SyncLedger(epoch: ledger.epoch, cursor: ledger.cursor, entries: entries)
}

/**
 * Entries a full listing from revision 0 (after `sync_cursor_expired`) does not contain: deleted on another device
 * while this device's cursor was older than the purged tombstones. Entries never uploaded (base 0) are not missing,
 * they are waiting to be uploaded. Pure function.
 */
public func missingFromFullListing(ledger: SyncLedger, listedObjectIDs: Set<String>) -> [SyncLedgerEntry] {
    ledger.entries.values
        .filter { $0.baseRevision > 0 && !listedObjectIDs.contains($0.objectID) }
        .sorted { $0.objectID < $1.objectID }
}
