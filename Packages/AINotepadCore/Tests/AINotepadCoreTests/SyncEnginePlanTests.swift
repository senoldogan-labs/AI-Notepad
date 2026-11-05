import Foundation
import Testing
@testable import AINotepadCore

@Suite struct SyncEnginePlanTests {
    private let now: Date = Date(timeIntervalSince1970: 1_800_000_000)

    // A meeting arriving from another device keeps its folder name unless a different local meeting has it (§8.5).
    @Test func incomingMeetingFolderGetsASuffixOnCollision() {
        #expect(incomingMeetingFolder(meetingID: "20261103-101500", taken: ["20261103-101501"]) == "20261103-101500")
        #expect(incomingMeetingFolder(meetingID: "20261103-101500", taken: ["20261103-101500"]) == "20261103-101500-2")
        #expect(incomingMeetingFolder(meetingID: "20261103-101500", taken: ["20261103-101500", "20261103-101500-2"]) == "20261103-101500-3")
    }

    // No local edits since the base: the server version is taken as is. Local edits: merged, uploaded only if the merge
    // adds something to the server's version.
    @Test func incomingVersionMeetsLocalEdits() {
        let union: ([String]?, [String], [String]) -> [String] = { (_: [String]?, local: [String], remote: [String]) -> [String] in
            Array(Set(local + remote)).sorted()
        }
        #expect(resolvingIncoming(base: nil, local: nil, remote: ["a"], merge: union) == SyncResolution(local: ["a"], needsUpload: false))
        #expect(resolvingIncoming(base: ["a"], local: ["a"], remote: ["a", "b"], merge: union) == SyncResolution(local: ["a", "b"], needsUpload: false))
        #expect(resolvingIncoming(base: ["a"], local: ["a", "c"], remote: ["a", "b"], merge: union) == SyncResolution(local: ["a", "b", "c"], needsUpload: true))
        #expect(resolvingIncoming(base: ["a"], local: ["a", "b"], remote: ["a", "b", "c"], merge: { (_: [String]?, _: [String], remote: [String]) -> [String] in remote })
            == SyncResolution(local: ["a", "b", "c"], needsUpload: false))
    }

    // An unchanged meeting gives back exactly its base (nothing to upload); a change is stamped with the pass time, and
    // a meeting stored here as "<id>-2" still uploads under the recording device's folder name.
    @Test func uploadStateKeepsIdentityAndStampsChanges() throws {
        let record: MeetingRecord = syncSampleRecord()
        let base: MeetingSyncState = try newMeetingState(record: record, contentObjectID: "c-1", originDeviceID: "mac", now: now.addingTimeInterval(-60))
        #expect(base.fieldClocks[MeetingSyncField.title] == now.addingTimeInterval(-60))
        let local: MeetingRecord = localMeetingRecord(state: base, content: meetingSyncContent(record: record), localID: "20261103-101500-2", voiceprints: nil)
        #expect(local.id == "20261103-101500-2")
        #expect(try uploadMeetingState(record: local, base: base, now: now) == base)
        let edited: MeetingSyncState = try uploadMeetingState(record: local.with(title: "Renamed"), base: base, now: now)
        #expect(edited.meetingID == "20261103-101500" && edited.contentObjectID == "c-1" && edited.originDeviceID == "mac")
        #expect(edited.title == "Renamed" && edited.fieldClocks[MeetingSyncField.title] == now)
        #expect(edited.fieldClocks[MeetingSyncField.folder] == base.fieldClocks[MeetingSyncField.folder])
    }

    // What the engine writes to `meeting.json` reads back as the same synced state: dates are whole seconds, so no
    // device keeps re-uploading a value the disk rounded.
    @Test func meetingWrittenToDiskReadsBackAsTheSameState() throws {
        let directory: URL = FileManager.default.temporaryDirectory.appending(path: "sync-plan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record: MeetingRecord = syncSampleRecord()
        let base: MeetingSyncState = try newMeetingState(record: record, contentObjectID: "c-1", originDeviceID: "mac", now: syncWholeSecond(date: Date()))
        let merged: MeetingStateMerge = mergeMeetingState(
            base: base, local: try uploadMeetingState(record: record.with(title: "Mac title"), base: base, now: syncWholeSecond(date: Date().addingTimeInterval(1))),
            remote: try uploadMeetingState(record: record.with(title: "Phone title"), base: base, now: syncWholeSecond(date: Date().addingTimeInterval(2))),
            localDeviceID: "mac", conflictReason: "Changed on another device", myNotesSeparator: "---"
        )
        try saveMeeting(record: localMeetingRecord(state: merged.state, content: meetingSyncContent(record: record), localID: record.id, voiceprints: nil), directory: directory)
        let loaded: MeetingRecord = try loadMeeting(directory: directory)
        #expect(try uploadMeetingState(record: loaded, base: merged.state, now: Date()) == merged.state)
        #expect(syncWholeSecond(date: Date(timeIntervalSince1970: 12.75)) == Date(timeIntervalSince1970: 12))
    }

    // Without a base (bookkeeping reset), the same meeting found locally merges with the server copy: differing fields
    // follow the server (no local clocks), sets are united.
    @Test func adoptedMeetingFollowsTheServerAndUnitesSets() throws {
        let record: MeetingRecord = syncSampleRecord()
        let tasks: [NoteTask] = try #require(record.note?.tasks)
        let remote: MeetingSyncState = try newMeetingState(record: record.with(title: "Server title"), contentObjectID: "c-9", originDeviceID: "phone", now: now)
        let local: MeetingSyncState = adoptedMeetingState(record: togglingTask(record: record.with(title: "Local title"), task: tasks[0]), remote: remote)
        #expect(local.contentObjectID == "c-9" && local.originDeviceID == "phone" && local.fieldClocks.isEmpty)
        let merged: MeetingSyncState = mergeMeetingState(
            base: nil, local: local, remote: remote, localDeviceID: "mac", conflictReason: "Changed on another device", myNotesSeparator: "---"
        ).state
        #expect(merged.title == "Server title")
        #expect(Set(merged.completedTasks ?? []) == Set(tasks.map { taskKey(task: $0) }))
    }

    // Another device's processing result replaces the transcript; what people edited stays.
    @Test func replacingContentKeepsEdits() {
        let record: MeetingRecord = syncSampleRecord().with(title: "Edited")
        let content: MeetingSyncContent = MeetingSyncContent(
            schema: syncPayloadSchema, language: .english, fixedLanguage: nil, engine: .cloud, meNeedsFinalPass: nil, liveSegments: [], finalSegments: [],
            translations: [:]
        )
        let replaced: MeetingRecord = replacingContent(record: record, content: content)
        #expect(replaced.title == "Edited" && replaced.finalSegments.isEmpty && replaced.voiceprints == record.voiceprints && replaced.id == record.id)
    }

    // An upload pass checks the queued items, meetings and chats new or gone here, and the two account objects.
    @Test func pushItemsFindNewAndDeletedItems() {
        let chatKept: UUID = UUID()
        let chatGone: UUID = UUID()
        let chatNew: UUID = UUID()
        let ledger: SyncLedger = SyncLedger(epoch: 1, cursor: 9, entries: [
            "s1": SyncLedgerEntry(objectID: "s1", kind: .meetingState, localID: "m-kept", baseRevision: 3),
            "c1": SyncLedgerEntry(objectID: "c1", kind: .meetingContent, localID: "m-kept", baseRevision: 2),
            "s2": SyncLedgerEntry(objectID: "s2", kind: .meetingState, localID: "m-gone", baseRevision: 4),
            "a1": SyncLedgerEntry(objectID: "a1", kind: .askChat, localID: chatKept.uuidString, baseRevision: 5),
            "a2": SyncLedgerEntry(objectID: "a2", kind: .askChat, localID: chatGone.uuidString, baseRevision: 6),
        ])
        let items: [SyncLocalItem] = syncPushItems(
            pending: [.meeting(id: "m-kept"), .people], ledger: ledger, localMeetingIDs: ["m-kept", "m-new"], localChatIDs: [chatKept, chatNew]
        )
        let chats: [SyncLocalItem] = [chatGone, chatNew].sorted { $0.uuidString < $1.uuidString }.map { SyncLocalItem.askChat(id: $0) }
        #expect(items == [.meeting(id: "m-kept"), .people, .meeting(id: "m-gone"), .meeting(id: "m-new")] + chats + [.prefs])
    }

    @Test func pendingListKeepsOrderWithoutRepeats() {
        let pending: SyncPending = addingPendingItems(pending: .empty, added: [.people, .meeting(id: "a"), .people])
        #expect(pending.items == [.people, .meeting(id: "a")])
        #expect(removingPendingItem(pending: pending, item: .people).items == [.meeting(id: "a")])
        let deferred: SyncPending = settingDeferred(pending: pending, objectID: "x", kind: .meetingState)
        #expect(deferred.deferred == ["x": .meetingState] && settingDeferred(pending: deferred, objectID: "x", kind: nil).deferred.isEmpty)
    }

    // One object's failure is recorded and the pass goes on; account and connection failures stop the pass.
    @Test func itemErrorsAreToldApartFromAccountErrors() {
        #expect(isItemSyncError(error: HostedSyncError.objectTooLarge(objectID: "x", byteCount: 3_000_000)))
        #expect(isItemSyncError(error: SyncPayloadError.unsupportedSchema(found: 2, supported: 1)))
        #expect(isItemSyncError(error: SyncCryptoError.authenticationFailed))
        #expect(isItemSyncError(error: SyncEngineError.conflictRoundsExhausted(objectID: "x", rounds: 5)))
        #expect(isItemSyncError(error: StorageError.readFailed(path: "meeting.json", reason: "corrupt")))
        #expect(!isItemSyncError(error: HostedSyncError.keyMismatch))
        #expect(!isItemSyncError(error: HostedSyncError.quotaExceeded))
        #expect(!isItemSyncError(error: SyncCryptoError.keyMismatch(expected: "a", found: "b")))
        #expect(!isItemSyncError(error: URLError(.notConnectedToInternet)))
    }

    // Server ids become file names and meeting ids folder names: anything else is refused.
    @Test func serverIdsAndFolderNamesAreValidated() {
        #expect(isSyncObjectID(value: newSyncObjectID()))
        #expect(!isSyncObjectID(value: "../../People"))
        #expect(!isSyncObjectID(value: UUID().uuidString))
        #expect(isSafeMeetingFolderName(value: "20261103-101500-2"))
        #expect(!isSafeMeetingFolderName(value: "../Sessions"))
        #expect(!isSafeMeetingFolderName(value: ".sync"))
        #expect(!isSafeMeetingFolderName(value: ""))
    }

    @Test func emptyPrefsAreNotUploaded() {
        #expect(isEmptySyncPrefs(prefs: SyncPrefs(schema: syncPayloadSchema, folders: [], recipes: [], settings: nil)))
        #expect(isEmptySyncPrefs(prefs: SyncPrefs(schema: syncPayloadSchema, folders: [], recipes: [], settings: [:])))
        #expect(!isEmptySyncPrefs(prefs: SyncPrefs(schema: syncPayloadSchema, folders: ["Board"], recipes: [], settings: nil)))
        #expect(!isEmptySyncPrefs(prefs: SyncPrefs(
            schema: syncPayloadSchema, folders: [], recipes: [], settings: ["displayMode": SyncedSetting(value: .string("bilingual"), changedAt: nil)]
        )))
    }
}
