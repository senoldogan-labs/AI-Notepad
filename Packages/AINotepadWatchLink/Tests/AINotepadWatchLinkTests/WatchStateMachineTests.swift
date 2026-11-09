import Foundation
import Testing
@testable import AINotepadWatchLink

/// The two Watch recording state machines, every transition: the iPhone's import (`watchImportNext`) and the Watch's
/// transfer (`watchTransferNext`), plus what the adapters derive from them.
@Suite struct WatchStateMachineTests {
    private let now: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private func info(id: String, tag: String, title: String) -> WatchRecordingInfo {
        WatchRecordingInfo(id: id, title: title, startedAt: now, durationSec: 60, accountTag: tag, interrupted: false)
    }

    // MARK: iPhone: import stage

    // Every stage × every event. Columns: stored, storeFailed, checked importNow, checked wait, checked duplicate,
    // importSucceeded, importFailed, importNeedsSignIn, retryRequested, deleteRequested.
    @Test func importStageTransitions() {
        let failedOld: WatchImportStage = .failed(reason: "old")
        let failedNew: WatchImportStage = .failed(reason: "new")
        let notStoredOld: WatchImportStage = .notStored(transferToken: "t0", reason: "r0")
        let notStoredNew: WatchImportStage = .notStored(transferToken: "t1", reason: "r1")
        let events: [WatchImportEvent] = [
            .stored, .storeFailed(transferToken: "t1", reason: "r1"), .checked(.importNow), .checked(.wait), .checked(.duplicate),
            .importSucceeded, .importFailed(reason: "new"), .importNeedsSignIn, .retryRequested, .deleteRequested,
        ]
        let table: [(WatchImportStage, [WatchImportStage])] = [
            (.received, [.received, notStoredNew, .importing, .waitingForAccount, .imported, .received, .received, .received, .received, .received]),
            (.waitingForAccount, [
                .received, notStoredNew, .importing, .waitingForAccount, .imported, .waitingForAccount, .waitingForAccount, .waitingForAccount,
                .waitingForAccount, .waitingForAccount,
            ]),
            // A pass never starts a second import; only the import's own outcome moves it on.
            (.importing, [.importing, .importing, .importing, .importing, .importing, .imported, failedNew, .waitingForAccount, .importing, .importing]),
            // A failure stays until "Try again" or "Delete"; a duplicate (imported meanwhile) clears it.
            (failedOld, [failedOld, failedOld, failedOld, failedOld, .imported, failedOld, failedOld, failedOld, .received, .deleted]),
            (.imported, Array(repeating: .imported, count: 10)),
            (.deleted, [.received, notStoredNew, .deleted, .deleted, .deleted, .deleted, .deleted, .deleted, .deleted, .deleted]),
            // A transfer that could not be stored is cleared by the next one that is; an inbox pass that finds an earlier
            // copy imports it (or waits) instead of stranding it.
            (notStoredOld, [.received, notStoredNew, .importing, .waitingForAccount, .imported, notStoredOld, notStoredOld, notStoredOld, notStoredOld, notStoredOld]),
        ]
        for (stage, expected) in table {
            for (event, next) in zip(events, expected) {
                #expect(watchImportNext(stage: stage, event: event) == next, "\(stage) + \(event)")
            }
        }
    }

    // A sign-out during the import waits for the account instead of showing a failure; the next pass with the account
    // loaded imports it.
    @Test func signOutDuringImportWaitsForTheAccount() {
        var records: [WatchImportRecord] = []
        for event: WatchImportEvent in [.stored, .checked(.importNow), .importNeedsSignIn] {
            records = watchImportRecords(records: records, id: "r", event: event)
        }
        #expect(watchImportStage(records: records, id: "r") == .waitingForAccount)
        records = watchImportRecords(records: records, id: "r", event: .checked(.importNow))
        records = watchImportRecords(records: records, id: "r", event: .importSucceeded)
        #expect(records.isEmpty)
    }

    // Imported and deleted records leave the list; the changed record moves to the end; unknown IDs are new inbox entries.
    @Test func importRecordsDropFinishedOnes() {
        let start: [WatchImportRecord] = [WatchImportRecord(id: "a", stage: .failed(reason: "x")), WatchImportRecord(id: "b", stage: .waitingForAccount)]
        #expect(watchImportStage(records: start, id: "new") == .received)
        #expect(watchImportRecords(records: start, id: "a", event: .deleteRequested) == [WatchImportRecord(id: "b", stage: .waitingForAccount)])
        #expect(watchImportRecords(records: start, id: "a", event: .retryRequested) == [
            WatchImportRecord(id: "b", stage: .waitingForAccount), WatchImportRecord(id: "a", stage: .received),
        ])
        #expect(watchImportRecords(records: start, id: "b", event: .checked(.duplicate)) == [WatchImportRecord(id: "a", stage: .failed(reason: "x"))])
    }

    // An import cut off by the app being stopped starts again at launch; other stages stay.
    @Test func cutOffImportStartsAgainAtLaunch() {
        let records: [WatchImportRecord] = [WatchImportRecord(id: "a", stage: .importing), WatchImportRecord(id: "b", stage: .failed(reason: "x"))]
        #expect(watchImportRecordsAtLaunch(records: records) == [WatchImportRecord(id: "a", stage: .received), WatchImportRecord(id: "b", stage: .failed(reason: "x"))])
    }

    // Stages of recordings that left the inbox are dropped (no leak); the newest transfers that could not be stored stay.
    @Test func pruningKeepsTheInboxAndTheNewestNotStored() {
        let records: [WatchImportRecord] = [
            WatchImportRecord(id: "gone", stage: .failed(reason: "x")),
            WatchImportRecord(id: "n1", stage: .notStored(transferToken: "1", reason: "r")),
            WatchImportRecord(id: "in", stage: .waitingForAccount),
            WatchImportRecord(id: "n2", stage: .notStored(transferToken: "2", reason: "r")),
            WatchImportRecord(id: "n3", stage: .notStored(transferToken: "3", reason: "r")),
        ]
        #expect(watchImportRecordsPruned(records: records, inboxIDs: ["in"], notStoredLimit: 2).map(\.id) == ["in", "n2", "n3"])
    }

    // The Watch hears about every inbox entry (held, or failed for the loaded account with title and reason), the last
    // imported IDs, and transfers the iPhone could not keep.
    @Test func reportsComeFromTheInboxAndTheRecords() {
        let inbox: [WatchRecordingInfo] = [info(id: "f", tag: "a", title: "Sync"), info(id: "w", tag: "b", title: "Other"), info(id: "otherFailed", tag: "b", title: "B")]
        let records: [WatchImportRecord] = [
            WatchImportRecord(id: "f", stage: .failed(reason: "too long")),
            WatchImportRecord(id: "otherFailed", stage: .failed(reason: "x")),
            WatchImportRecord(id: "n", stage: .notStored(transferToken: "t", reason: "full")),
        ]
        let reports: [WatchImportReport] = watchImportReports(inbox: inbox, records: records, importedIDs: ["i", "f"], accountTag: "a")
        #expect(reports == [
            WatchImportReport(id: "f", status: .failed(title: "Sync", reason: "too long")),
            WatchImportReport(id: "w", status: .held),
            WatchImportReport(id: "otherFailed", status: .held),
            WatchImportReport(id: "i", status: .held),
            WatchImportReport(id: "n", status: .notReceived(transferToken: "t", reason: "full")),
        ])
    }

    // MARK: Watch: transfer state

    // Every state × every event. Columns: compressionStarted, queued b, preparationFailed, finished a, finished b,
    // failed a, failed b, rejected a, rejected b.
    @Test func transferStateTransitions() {
        let events: [WatchTransferEvent] = [
            .compressionStarted, .queued(transferToken: "b"), .preparationFailed,
            .transferFinished(transferToken: "a"), .transferFinished(transferToken: "b"),
            .transferFailed(transferToken: "a"), .transferFailed(transferToken: "b"),
            .phoneRejected(transferToken: "a", reason: "full"), .phoneRejected(transferToken: "b", reason: "full"),
        ]
        let queuedA: WatchTransferState = .queued(transferToken: "a")
        let queuedB: WatchTransferState = .queued(transferToken: "b")
        let deliveredA: WatchTransferState = .delivered(transferToken: "a")
        let rejectedOld: WatchTransferState = .rejected(reason: "old")
        let rejectedNew: WatchTransferState = .rejected(reason: "full")
        let table: [(WatchTransferState, [WatchTransferState])] = [
            (.compressing, [.compressing, queuedB, .failed, .compressing, .compressing, .compressing, .compressing, .compressing, .compressing]),
            (queuedA, [.compressing, queuedB, .failed, deliveredA, queuedA, .failed, queuedA, rejectedNew, queuedA]),
            (deliveredA, [.compressing, queuedB, .failed, deliveredA, deliveredA, deliveredA, deliveredA, rejectedNew, deliveredA]),
            (.failed, [.compressing, queuedB, .failed, .failed, .failed, .failed, .failed, .failed, .failed]),
            (rejectedOld, [.compressing, queuedB, .failed, rejectedOld, rejectedOld, rejectedOld, rejectedOld, rejectedOld, rejectedOld]),
        ]
        for (state, expected) in table {
            for (event, next) in zip(events, expected) {
                #expect(watchTransferNext(state: state, event: event) == next, "\(state) + \(event)")
            }
        }
    }

    // A retry cancels transfer "a" and queues "b": the cancelled one's late failure changes nothing, "b"'s end delivers.
    @Test func lateEndOfACancelledTransferIsDropped() {
        var state: WatchTransferState = .queued(transferToken: "a")
        for event: WatchTransferEvent in [.queued(transferToken: "b"), .transferFailed(transferToken: "a"), .transferFinished(transferToken: "b"), .transferFailed(transferToken: "a")] {
            state = watchTransferNext(state: state, event: event)
        }
        #expect(state == .delivered(transferToken: "b"))
    }

    // The iPhone could not keep the delivered transfer: the Watch shows its reason instead of "Sent"; a report about an
    // older transfer is ignored.
    @Test func phoneRejectionReachesTheWatch() {
        let recording: WatchLocalRecording = WatchLocalRecording(info: info(id: "1", tag: "a", title: ""), state: .delivered(transferToken: "b"))
        let stale: [WatchImportReport] = [WatchImportReport(id: "1", status: .notReceived(transferToken: "a", reason: "full"))]
        #expect(watchRecordingsAfterReports(recordings: [recording], reports: stale) == [recording])
        let current: [WatchImportReport] = [WatchImportReport(id: "1", status: .notReceived(transferToken: "b", reason: "full"))]
        #expect(watchRecordingsAfterReports(recordings: [recording], reports: current).map(\.state) == [.rejected(reason: "full")])
    }

    @Test func sendAgainOnlyWhenNothingIsUnderway() {
        #expect(watchCanSendAgain(state: .delivered(transferToken: "a")))
        #expect(watchCanSendAgain(state: .failed))
        #expect(watchCanSendAgain(state: .rejected(reason: "x")))
        #expect(!watchCanSendAgain(state: .queued(transferToken: "a")))
        #expect(!watchCanSendAgain(state: .compressing))
    }

    // A list stored by the first Watch build (plain string states) still reads, so waiting recordings survive the update.
    @Test func legacyStoredRecordingsStillRead() throws {
        let recording: WatchRecordingInfo = info(id: "1", tag: "a", title: "T")
        let infoData: Data = try #require(try watchPayload(value: recording)[watchPayloadKey])
        let infoJSON: String = try #require(String(data: infoData, encoding: .utf8))
        for (legacy, expected) in [("preparing", WatchTransferState.compressing), ("waiting", .failed), ("failed", .failed), ("sent", .delivered(transferToken: ""))] {
            let json: String = #"[{"info":"# + infoJSON + #","state":""# + legacy + #""}]"#
            let decoded: [WatchLocalRecording] = try watchValue(type: [WatchLocalRecording].self, data: Data(json.utf8))
            #expect(decoded == [WatchLocalRecording(info: recording, state: expected)])
        }
        #expect(throws: WatchLocalRecordingError.unknownLegacyState("lost")) {
            try watchTransferState(legacy: "lost")
        }
        let current: [WatchLocalRecording] = [WatchLocalRecording(info: recording, state: .queued(transferToken: "t"))]
        #expect(try watchValue(type: [WatchLocalRecording].self, data: try watchPayload(value: current)[watchPayloadKey]) == current)
    }

    // MARK: "Start on iPhone"

    // A refused start reaches the Watch with its reason; a start that begins, or a recording already running (even when a
    // new start would now be refused mid-meeting), is done.
    @Test func startReplyReflectsTheRefusal() {
        #expect(watchStartReply(recorderIdle: true, refusal: "trial ended") == .failed(reason: "trial ended"))
        #expect(watchStartReply(recorderIdle: true, refusal: nil) == .done)
        #expect(watchStartReply(recorderIdle: false, refusal: "disk full") == .done)
        #expect(watchStartReply(recorderIdle: false, refusal: nil) == .done)
    }
}
