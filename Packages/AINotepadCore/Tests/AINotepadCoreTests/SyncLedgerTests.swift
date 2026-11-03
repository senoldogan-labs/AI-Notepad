import Foundation
import Testing
@testable import AINotepadCore

private func change(_ id: String, _ kind: SyncObjectKind, rev: UInt64, deleted: Bool) -> HostedSyncChange {
    HostedSyncChange(objectId: id, kind: kind, rev: rev, size: deleted ? 0 : 100, deleted: deleted, updatedAt: 0)
}

@Suite struct SyncLedgerTests {
    @Test func changePagesBecomeDownloadsDeletesAndEchoes() {
        let meeting: SyncLedgerEntry = SyncLedgerEntry(objectID: "m", kind: .meetingState, localID: "20261103-101500", baseRevision: 4)
        let chat: SyncLedgerEntry = SyncLedgerEntry(objectID: "c", kind: .askChat, localID: "chat-1", baseRevision: 2)
        let ledger: SyncLedger = SyncLedger(epoch: 7, cursor: 4, entries: ["m": meeting, "c": chat])
        let page: [HostedSyncChange] = [
            change("m", .meetingState, rev: 5, deleted: false),   // edited on the other device
            change("c", .askChat, rev: 6, deleted: true),         // chat deleted there
            change("n", .meetingContent, rev: 7, deleted: false), // new object
            change("x", .people, rev: 8, deleted: true),          // created and deleted before this device saw it
        ]
        let result = applyingChanges(ledger: ledger, changes: page, epoch: 7, cursor: 8)
        #expect(result.actions == [
            .download(objectID: "m", kind: .meetingState, revision: 5), .deleteLocal(entry: chat),
            .download(objectID: "n", kind: .meetingContent, revision: 7), .forget(objectID: "x"),
        ])
        #expect(result.ledger.cursor == 8 && result.ledger.epoch == 7 && result.ledger.entries["c"] == nil)
        // This device's own write coming back in the feed is not downloaded again.
        let written: SyncLedger = recordingRevision(ledger: result.ledger, entry: SyncLedgerEntry(objectID: "m", kind: .meetingState, localID: "20261103-101500", baseRevision: 9))
        #expect(applyingChanges(ledger: written, changes: [change("m", .meetingState, rev: 9, deleted: false)], epoch: 7, cursor: 9).actions.isEmpty)
        // A new epoch (sync was reset) takes the page's cursor even when it is lower.
        #expect(applyingChanges(ledger: written, changes: [], epoch: 8, cursor: 1).ledger.cursor == 1)
    }

    // After `sync_cursor_expired` the full listing lacks objects whose tombstones were purged: they were deleted.
    @Test func fullListingRevealsPurgedDeletes() {
        let kept: SyncLedgerEntry = SyncLedgerEntry(objectID: "a", kind: .meetingState, localID: "m1", baseRevision: 3)
        let gone: SyncLedgerEntry = SyncLedgerEntry(objectID: "b", kind: .meetingState, localID: "m2", baseRevision: 5)
        let pending: SyncLedgerEntry = SyncLedgerEntry(objectID: "c", kind: .meetingState, localID: "m3", baseRevision: 0)
        let ledger: SyncLedger = SyncLedger(epoch: 1, cursor: 2, entries: ["a": kept, "b": gone, "c": pending])
        #expect(missingFromFullListing(ledger: ledger, listedObjectIDs: ["a"]) == [gone])
    }
}
