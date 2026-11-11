import Foundation
import Testing
@testable import AINotepadCore

private let reportTask: NoteTask = NoteTask(owner: "Aino", description: "Send the report", dueDate: nil, isMine: false)
private let budgetTask: NoteTask = NoteTask(owner: "Senol", description: "Prepare the budget", dueDate: "Friday", isMine: true)

private func linearTracker() -> TaskTracker {
    TaskTracker(
        id: "tracker-1", service: .linear,
        connection: MCPConnection(
            serverURL: URL(string: "https://mcp.linear.app/mcp")!, clientID: "client-1", tokenEndpoint: URL(string: "https://mcp.linear.app/token")!,
            tokens: OAuthTokens(accessToken: "access-test", refreshToken: "refresh-test", expiresAt: Date(timeIntervalSince1970: 0))
        ),
        target: "", identity: nil
    )
}

private func notedMeeting(id: String) -> MeetingRecord {
    record(id: id, startedAt: Date(timeIntervalSince1970: 1_800_000_000), status: .done, audioDeleted: false)
        .with(note: MeetingNote(title: "Budget", summary: "Summary", decisions: [], tasks: [reportTask, budgetTask], glossary: []))
}

/// Marks held while a job had the meeting locked: a note sent to a destination, tasks created in a tracker and a
/// Reminders entry.
private func heldMarks() -> PendingMeetingMarks {
    PendingMeetingMarks.none
        .adding(id: UUID(), mark: .sent(keys: ["destination-1", "send-key-1"]))
        .adding(id: UUID(), mark: .tasksSent(tracker: linearTracker(), tasks: [reportTask]))
        .adding(id: UUID(), mark: .reminded(task: budgetTask))
}

private func meetingFolder(sessions: URL, id: String) throws -> URL {
    let folder: URL = sessions.appending(path: id, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Whether the record carries every mark of `heldMarks()`.
private func carriesHeldMarks(record: MeetingRecord) -> Bool {
    Set(record.sentDestinationIDs ?? []).isSuperset(of: ["destination-1", "send-key-1"])
        && isTaskSent(record: record, tracker: linearTracker(), task: reportTask)
        && (record.remindedTasks ?? []).contains(taskKey(task: budgetTask))
}

@Suite struct MeetingCommitTests {
    // The merge writes the marks exactly as the app's former inline fold did: sorted sent keys, tracker marks in
    // arrival order, Reminders last (the meeting.json written for the same marks stays byte-for-byte the same).
    @Test func mergeMatchesFormerMarkOrder() {
        let marks: PendingMeetingMarks = heldMarks()
        let start: MeetingRecord = notedMeeting(id: "20261111-100000")
        let former: MeetingRecord = markingReminded(
            record: markingTasksSent(
                record: start.markingSent(destinationID: "destination-1").markingSent(destinationID: "send-key-1"),
                tracker: linearTracker(), tasks: [reportTask]
            ),
            task: budgetTask
        )
        #expect(mergingPendingMeetingMarks(record: start, marks: marks) == former)
        // A retained snapshot can be applied again: nothing is duplicated.
        let merged: MeetingRecord = mergingPendingMeetingMarks(record: start, marks: marks)
        #expect(mergingPendingMeetingMarks(record: merged, marks: marks) == merged)
        #expect(marks.sentDestinationKeys == ["destination-1", "send-key-1"])
    }

    // P01a: the final save fails after the pending marks were read. Nothing is acknowledged, so the marks are still
    // pending and the next successful write carries them to disk; until then the file keeps its earlier content.
    @Test func failedFinalSaveRetainsPendingMarksAndRecovery() throws {
        let sessions: URL = try temporaryDirectory()
        let id: String = "20261111-100000"
        let folder: URL = try meetingFolder(sessions: sessions, id: id)
        let before: MeetingRecord = notedMeeting(id: id).with(status: .processing, failureMessage: nil)
        try saveMeeting(record: before, directory: folder)
        let pending: PendingMeetingMarks = heldMarks()
        let snapshot: PendingMeetingMarks = pending
        let merged: MeetingRecord = mergingPendingMeetingMarks(record: notedMeeting(id: id), marks: snapshot)
        // A destination that cannot be written: the folder does not exist.
        let missing: URL = sessions.appending(path: "missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(throws: StorageError.self) {
            try commitMeetingWork(request: MeetingCommitRequest(
                record: merged, marks: snapshot, directory: missing, workID: UUID(), ticket: claimMeetingWrite(directory: missing)
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try loadMeeting(directory: folder) == before)

        // The retry writes the same snapshot; only its receipt acknowledges the marks.
        let workID: UUID = UUID()
        let outcome: MeetingCommitOutcome = try commitMeetingWork(request: MeetingCommitRequest(
            record: merged, marks: snapshot, directory: folder, workID: workID, ticket: claimMeetingWrite(directory: folder)
        ))
        guard case .persisted(let receipt) = outcome else {
            Issue.record("expected a persisted commit, got \(outcome)")
            return
        }
        #expect(receipt == MeetingCommitReceipt(meetingID: id, workID: workID, persistedMarks: snapshot))
        let onDisk: MeetingRecord = try loadMeeting(directory: folder)
        #expect(onDisk == merged)
        #expect(carriesHeldMarks(record: onDisk))
        #expect(acknowledgingPersistedMeetingMarks(pending: pending, persisted: receipt.persistedMarks).isEmpty)
    }

    // A commit whose ticket was claimed before a newer write of the same file is not written and returns no receipt:
    // its marks stay pending and the newer content stays on disk.
    @Test func supersededCommitCannotAcknowledgeMarks() throws {
        let sessions: URL = try temporaryDirectory()
        let id: String = "20261111-110000"
        let folder: URL = try meetingFolder(sessions: sessions, id: id)
        let older: MeetingWriteTicket = claimMeetingWrite(directory: folder)
        let newer: MeetingWriteTicket = claimMeetingWrite(directory: folder)
        let newerRecord: MeetingRecord = notedMeeting(id: id).with(myNotes: "written by the newer snapshot")
        #expect(try saveMeeting(record: newerRecord, directory: folder, ticket: newer))
        let pending: PendingMeetingMarks = heldMarks()
        let outcome: MeetingCommitOutcome = try commitMeetingWork(request: MeetingCommitRequest(
            record: mergingPendingMeetingMarks(record: notedMeeting(id: id), marks: pending), marks: pending, directory: folder,
            workID: UUID(), ticket: older
        ))
        #expect(outcome == .superseded)
        #expect(try loadMeeting(directory: folder) == newerRecord)
        // Without a receipt there is nothing to acknowledge with: the caller keeps `pending` as it is.
        #expect(!pending.isEmpty)
    }

    // A mark that arrives after the snapshot was taken is not acknowledged by the save of that snapshot.
    @Test func newMarksSurviveOlderCommitAcknowledgement() throws {
        let sessions: URL = try temporaryDirectory()
        let id: String = "20261111-120000"
        let folder: URL = try meetingFolder(sessions: sessions, id: id)
        let snapshot: PendingMeetingMarks = heldMarks()
        let lateID: UUID = UUID()
        let pending: PendingMeetingMarks = snapshot.adding(id: lateID, mark: .sent(keys: ["destination-2"]))
        let outcome: MeetingCommitOutcome = try commitMeetingWork(request: MeetingCommitRequest(
            record: mergingPendingMeetingMarks(record: notedMeeting(id: id), marks: snapshot), marks: snapshot, directory: folder,
            workID: UUID(), ticket: claimMeetingWrite(directory: folder)
        ))
        guard case .persisted(let receipt) = outcome else {
            Issue.record("expected a persisted commit, got \(outcome)")
            return
        }
        let left: PendingMeetingMarks = acknowledgingPersistedMeetingMarks(pending: pending, persisted: receipt.persistedMarks)
        #expect(left.entries.map(\.id) == [lateID])
        #expect(left.sentDestinationKeys == ["destination-2"])
        #expect(!((try loadMeeting(directory: folder)).sentDestinationIDs ?? []).contains("destination-2"))
    }
}
