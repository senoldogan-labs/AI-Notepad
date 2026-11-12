import Foundation
import Testing
@testable import AINotepadCore

private let now: Date = Date(timeIntervalSince1970: 2_000_000_000)

private func notedRecord(id: String, title: String) -> MeetingRecord {
    MeetingRecord(
        id: id, title: title, startedAt: now.addingTimeInterval(-660), endedAt: now.addingTimeInterval(-60), language: nil, status: .done,
        failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
        note: MeetingNote(title: title, summary: "Summary", decisions: [], tasks: [], glossary: []), audioDeleted: false, engine: .cloud,
        notice: nil, meNeedsFinalPass: nil
    )
}

private func autoSendDestination(id: String) -> NoteDestination {
    NoteDestination(
        id: id, target: .webhook(URL(string: "https://hooks.zapier.com/x")!), autoSend: true, createdAt: now.addingTimeInterval(-86_400),
        autoSendSince: nil, needsReconnect: false
    )
}

private func receipt(meetingID: String, destinationID: String, launchID: UUID) -> PendingDeliveryReceipt {
    PendingDeliveryReceipt(
        meetingID: meetingID, destinationID: destinationID, markKeys: [destinationID, "send-key-\(destinationID)"], destinationName: "Zapier",
        meetingTitle: "Budget", launchID: launchID, startedAt: now
    )
}

/// Writes `record` into `<sessions>/<id>/meeting.json` and returns the folder.
private func savedMeeting(sessions: URL, record: MeetingRecord) throws -> URL {
    let folder: URL = sessions.appending(path: record.id, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try saveMeeting(record: record, directory: folder)
    return folder
}

/// The launch reconciliation exactly as the apps run it: the record state of each receipt's meeting is read from disk.
private func reconcileFromDisk(file: URL, sessions: URL, currentLaunch: UUID) throws -> PendingReceiptReconciliation {
    let receipts: [PendingDeliveryReceipt] = try loadPendingDeliveryReceipts(file: file)
    var states: [String: PendingReceiptRecordState] = [:]
    for meetingID in Set(receipts.map(\.meetingID)) {
        do {
            states[meetingID] = try pendingReceiptRecordState(directory: sessions.appending(path: meetingID, directoryHint: .isDirectory))
        } catch {
            states[meetingID] = .unreadable
        }
    }
    let result: PendingReceiptReconciliation = reconcilingPendingDeliveryReceipts(receipts: receipts, currentLaunch: currentLaunch, records: states)
    try savePendingDeliveryReceipts(receipts: result.remaining, file: file)
    return result
}

@Suite struct PendingDeliveryReceiptsTests {
    // P13: the destination accepted the note, then writing its sent mark failed and the process ended. After the
    // restart the planner would queue the same note again; the receipt written before the delivery turns it into an
    // uncertain send instead, so the automatic send skips it.
    @Test func remoteSuccessAndLocalSaveFailureDoNotAutoResend() throws {
        let data: URL = try temporaryDirectory()
        let sessions: URL = data.appending(path: "Sessions", directoryHint: .isDirectory)
        let file: URL = pendingDeliveryReceiptsFile(userDataDirectory: data)
        let record: MeetingRecord = notedRecord(id: "20261112-090000", title: "Budget")
        _ = try savedMeeting(sessions: sessions, record: record)
        let destinations: [NoteDestination] = [autoSendDestination(id: "d")]

        // Launch A: the receipt is on disk before the note leaves.
        let launchA: UUID = UUID()
        try savePendingDeliveryReceipts(receipts: addingPendingDeliveryReceipt(receipts: [], receipt: receipt(meetingID: record.id, destinationID: "d", launchID: launchA)), file: file)
        // The destination accepted it (remote success); the mark's write fails: its folder cannot be written.
        let unwritable: URL = sessions.appending(path: "missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        let marks: PendingMeetingMarks = PendingMeetingMarks.none.adding(id: UUID(), mark: .sent(keys: ["d", "send-key-d"]))
        #expect(throws: StorageError.self) {
            try commitMeetingWork(request: MeetingCommitRequest(
                record: mergingPendingMeetingMarks(record: record, marks: marks), marks: marks, directory: unwritable, workID: UUID(),
                ticket: claimMeetingWrite(directory: unwritable)
            ))
        }

        // Launch B: the held mark is gone with the process. Without the receipt the planner would send the note again.
        let reloaded: [MeetingRecord] = [try loadMeeting(directory: sessions.appending(path: record.id, directoryHint: .isDirectory))]
        let unguarded: [(meetingID: String, destinationID: String)] = autoSendQueue(
            records: reloaded, destinations: destinations, now: now, pendingMarks: [:], locked: [], uncertain: [], rejected: []
        )
        #expect(unguarded.map(\.meetingID) == [record.id])

        let result: PendingReceiptReconciliation = try reconcileFromDisk(file: file, sessions: sessions, currentLaunch: UUID())
        #expect(result.uncertain.map(\.destinationID) == ["d"])
        #expect(result.remaining.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let guarded: [(meetingID: String, destinationID: String)] = autoSendQueue(
            records: reloaded, destinations: destinations, now: now, pendingMarks: [:], locked: [],
            uncertain: pendingDeliveryReceiptKeys(receipts: result.uncertain), rejected: []
        )
        #expect(guarded.isEmpty)
    }

    // Launch reconciliation: a mark on disk (destination ID or device-independent key) or a deleted meeting clears the
    // entry; a meeting without the mark makes it uncertain; a send of this launch and an unreadable meeting stay.
    @Test func launchReconciliationClearsMarkedAndSurfacesUnmarked() throws {
        let data: URL = try temporaryDirectory()
        let sessions: URL = data.appending(path: "Sessions", directoryHint: .isDirectory)
        let file: URL = pendingDeliveryReceiptsFile(userDataDirectory: data)
        let earlier: UUID = UUID()
        let current: UUID = UUID()
        _ = try savedMeeting(sessions: sessions, record: notedRecord(id: "marked", title: "A").markingSent(destinationID: "d"))
        _ = try savedMeeting(sessions: sessions, record: notedRecord(id: "keyed", title: "B").markingSent(destinationID: "send-key-d"))
        _ = try savedMeeting(sessions: sessions, record: notedRecord(id: "unmarked", title: "C"))
        _ = try savedMeeting(sessions: sessions, record: notedRecord(id: "running", title: "D"))
        let corrupt: URL = sessions.appending(path: "corrupt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: corrupt.appending(path: meetingFileName))
        let receipts: [PendingDeliveryReceipt] = [
            receipt(meetingID: "marked", destinationID: "d", launchID: earlier),
            receipt(meetingID: "keyed", destinationID: "d", launchID: earlier),
            receipt(meetingID: "unmarked", destinationID: "d", launchID: earlier),
            receipt(meetingID: "deleted", destinationID: "d", launchID: earlier),
            receipt(meetingID: "corrupt", destinationID: "d", launchID: earlier),
            receipt(meetingID: "running", destinationID: "d", launchID: current),
        ]
        try savePendingDeliveryReceipts(receipts: receipts, file: file)

        let result: PendingReceiptReconciliation = try reconcileFromDisk(file: file, sessions: sessions, currentLaunch: current)
        #expect(result.uncertain.map(\.meetingID) == ["unmarked"])
        #expect(result.remaining.map(\.meetingID) == ["corrupt", "running"])
        #expect(try loadPendingDeliveryReceipts(file: file) == result.remaining)
    }

    // The process ends after the receipt was written but before (or while) the note left: whether it arrived is
    // unknown. After the restart it is an uncertain send with a notice naming the destination and the meeting, never a
    // silent drop from the automatic send.
    @Test func processEndingBeforeDeliveryBecomesVisibleUncertainSend() throws {
        let data: URL = try temporaryDirectory()
        let sessions: URL = data.appending(path: "Sessions", directoryHint: .isDirectory)
        let file: URL = pendingDeliveryReceiptsFile(userDataDirectory: data)
        let record: MeetingRecord = notedRecord(id: "20261112-100000", title: "Budget")
        _ = try savedMeeting(sessions: sessions, record: record)
        let written: PendingDeliveryReceipt = receipt(meetingID: record.id, destinationID: "d", launchID: UUID())
        try savePendingDeliveryReceipts(receipts: [written], file: file)
        #expect(try loadPendingDeliveryReceipts(file: file) == [written])

        let result: PendingReceiptReconciliation = try reconcileFromDisk(file: file, sessions: sessions, currentLaunch: UUID())
        #expect(result.uncertain == [written])
        let message: String = interruptedDeliveryMessage(receipt: written)
        #expect(message.contains("Zapier") && message.contains("Budget"))
    }

    // During a run: a confirmed save that wrote the sent mark clears only that meeting's entry for that destination;
    // a new send of the same pair replaces its entry; a failed send removes it.
    @Test func persistedSentMarkClearsOnlyItsReceipt() {
        let launch: UUID = UUID()
        let receipts: [PendingDeliveryReceipt] = [
            receipt(meetingID: "m1", destinationID: "d", launchID: launch),
            receipt(meetingID: "m1", destinationID: "e", launchID: launch),
            receipt(meetingID: "m2", destinationID: "d", launchID: launch),
        ]
        let persisted: PendingMeetingMarks = PendingMeetingMarks.none.adding(id: UUID(), mark: .sent(keys: ["d", "send-key-d"]))
        let left: [PendingDeliveryReceipt] = removingPersistedDeliveryReceipts(receipts: receipts, meetingID: "m1", persisted: persisted)
        #expect(left.map { "\($0.meetingID)>\($0.destinationID)" } == ["m1>e", "m2>d"])
        #expect(addingPendingDeliveryReceipt(receipts: left, receipt: receipt(meetingID: "m1", destinationID: "e", launchID: launch)).count == 2)
        #expect(removingPendingDeliveryReceipt(receipts: left, meetingID: "m2", destinationID: "d").map(\.meetingID) == ["m1"])
        #expect(pendingDeliveryReceiptKeys(receipts: left) == ["m1|e", "m2|d"])
    }
}
