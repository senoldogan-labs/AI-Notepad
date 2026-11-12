import Foundation
import Testing
@testable import AINotepadWatchLink

@Suite struct WatchLinkTests {
    private let now: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private func info(id: String, tag: String) -> WatchRecordingInfo {
        WatchRecordingInfo(id: id, title: "Sync", startedAt: now, durationSec: 60, accountTag: tag, interrupted: false)
    }

    private func snapshot(recording: WatchPhoneRecording?, meetings: [WatchMeeting], phoneAppOpen: Bool) -> WatchSnapshot {
        WatchSnapshot(
            signedIn: true, accountTag: "a", recording: recording, meetings: meetings, calendarOn: true, tasks: [], maxMeetingMinutes: 180,
            phoneAppOpen: phoneAppOpen, imports: [], watchRecordingEnabled: true
        )
    }

    // Every message type survives the trip through a WatchConnectivity payload.
    @Test func payloadsRoundTrip() throws {
        let requests: [WatchRequest] = [
            .startPhoneRecording(accountTag: "a"), .pausePhoneRecording(recordingID: "r", accountTag: "a"),
            .resumePhoneRecording(recordingID: "r", accountTag: nil), .stopPhoneRecording(recordingID: "r", accountTag: "a"),
            .completeTask(meetingID: "m", taskKey: "you|send deck", accountTag: "a"), .retryImport(recordingID: "r", accountTag: "a"),
            .deleteImport(recordingID: "r", accountTag: "a"), .refresh,
        ]
        for request in requests {
            let payload: [String: Data] = try watchPayload(value: request)
            #expect(try watchValue(type: WatchRequest.self, data: payload[watchPayloadKey]) == request)
        }
        let replies: [WatchReply] = [.done, .phoneAppNotOpen, .signedOut, .recordingChanged, .accountChanged, .failed(reason: "x")]
        for reply in replies {
            #expect(try watchValue(type: WatchReply.self, data: try watchPayload(value: reply)[watchPayloadKey]) == reply)
        }
        let full: WatchSnapshot = WatchSnapshot(
            signedIn: true, accountTag: "a",
            recording: WatchPhoneRecording(recordingID: "r", phase: .paused, title: "T", timerStart: now, timerStoppedAt: now + 5),
            meetings: [WatchMeeting(id: "e", title: "E", start: now, end: now + 60)], calendarOn: true,
            tasks: [WatchTask(meetingID: "m", taskKey: "k", text: "t", meetingTitle: "M", due: nil)], maxMeetingMinutes: 120, phoneAppOpen: true,
            imports: [
                WatchImportReport(id: "x", status: .held), WatchImportReport(id: "y", status: .failed(title: "Y", reason: "too long")),
                WatchImportReport(id: "z", status: .notReceived(transferToken: "t", reason: "full")),
            ],
            watchRecordingEnabled: true
        )
        #expect(try watchValue(type: WatchSnapshot.self, data: try watchPayload(value: full)[watchPayloadKey]) == full)
        let recording: WatchRecordingInfo = info(id: "x", tag: "a")
        #expect(try watchValue(type: WatchRecordingInfo.self, data: try watchPayload(value: recording)[watchPayloadKey]) == recording)
    }

    @Test func missingPayloadIsAnError() {
        #expect(throws: WatchLinkError.missingPayload) {
            try watchValue(type: WatchRequest.self, data: nil)
        }
    }

    // A recording goes only into the account it was made for, and only once.
    @Test func importDecisionBindsTheAccount() {
        #expect(watchImportDecision(info: info(id: "1", tag: "a"), loadedAccountTag: "a", importedIDs: []) == .importNow)
        #expect(watchImportDecision(info: info(id: "1", tag: "a"), loadedAccountTag: "b", importedIDs: []) == .wait)
        #expect(watchImportDecision(info: info(id: "1", tag: "a"), loadedAccountTag: nil, importedIDs: []) == .wait)
        #expect(watchImportDecision(info: info(id: "1", tag: "a"), loadedAccountTag: "a", importedIDs: ["1"]) == .duplicate)
        #expect(watchImportDecision(info: info(id: "1", tag: "a"), loadedAccountTag: "b", importedIDs: ["1"]) == .duplicate)
    }

    @Test func recordingLimitComesFromTheAccount() {
        #expect(watchRecordingLimitSec(maxMeetingMinutes: 90) == 5400)
        #expect(watchRecordingLimitSec(maxMeetingMinutes: nil) == nil)
    }

    // "Start on iPhone" only when it can work.
    @Test func startOnPhoneNeedsTheAppOpenAndNoRecording() {
        let running: WatchPhoneRecording = WatchPhoneRecording(recordingID: "r", phase: .recording, title: "", timerStart: now, timerStoppedAt: nil)
        #expect(watchCanStartOnPhone(snapshot: snapshot(recording: nil, meetings: [], phoneAppOpen: true)))
        #expect(!watchCanStartOnPhone(snapshot: snapshot(recording: nil, meetings: [], phoneAppOpen: false)))
        #expect(!watchCanStartOnPhone(snapshot: snapshot(recording: running, meetings: [], phoneAppOpen: true)))
        #expect(!watchCanStartOnPhone(snapshot: .signedOut))
    }

    // Tasks marked done on the Watch hide at once; the mark is forgotten once the iPhone's list no longer has the task.
    @Test func doneMarksHideTasksUntilThePhoneCatchesUp() {
        let first: WatchTask = WatchTask(meetingID: "m", taskKey: "1", text: "a", meetingTitle: "M", due: nil)
        let second: WatchTask = WatchTask(meetingID: "m", taskKey: "2", text: "b", meetingTitle: "M", due: nil)
        #expect(watchVisibleTasks(tasks: [first, second], markedDone: [first.id]) == [second])
        #expect(watchPendingDoneMarks(markedDone: [first.id, "gone|x"], snapshotTasks: [first, second]) == [first.id])
        #expect(watchPendingDoneMarks(markedDone: [first.id], snapshotTasks: [second]).isEmpty)
    }

    // The glance: Watch recording, then the iPhone's recording, then the next meeting that has not ended.
    @Test func glancePriority() {
        let ended: WatchMeeting = WatchMeeting(id: "old", title: "Old", start: now - 7200, end: now - 3600)
        let next: WatchMeeting = WatchMeeting(id: "next", title: "Next", start: now + 600, end: now + 4200)
        let phone: WatchPhoneRecording = WatchPhoneRecording(recordingID: "r", phase: .recording, title: "", timerStart: now, timerStoppedAt: nil)
        let watch: WatchGlanceRecording = WatchGlanceRecording(timerStart: now - 60, pausedAt: nil)
        let state: (WatchGlanceRecording?, WatchPhoneRecording?) -> WatchGlanceState = { (watchRecording: WatchGlanceRecording?, phoneRecording: WatchPhoneRecording?) in
            watchGlanceState(snapshot: snapshot(recording: phoneRecording, meetings: [ended, next], phoneAppOpen: false), watchRecording: watchRecording)
        }
        #expect(watchGlanceContent(state: state(watch, phone), now: now) == .watchRecording(timerStart: now - 60, pausedAt: nil))
        #expect(watchGlanceContent(state: state(nil, phone), now: now) == .phoneRecording(phone))
        #expect(watchGlanceContent(state: state(nil, nil), now: now) == .nextMeeting(next))
        #expect(watchGlanceContent(state: .empty, now: now) == .idle)
    }

    @Test func upcomingMeetingsDropEndedOnes() {
        let ended: WatchMeeting = WatchMeeting(id: "old", title: "Old", start: now - 7200, end: now - 3600)
        let later: WatchMeeting = WatchMeeting(id: "later", title: "Later", start: now + 7200, end: now + 9000)
        let running: WatchMeeting = WatchMeeting(id: "now", title: "Now", start: now - 60, end: now + 60)
        #expect(watchUpcomingMeetings(meetings: [later, ended, running], now: now).map(\.id) == ["now", "later"])
    }

    @Test func fileNameIsTheRecordingID() {
        #expect(watchRecordingFileName(id: "ABC") == "ABC.m4a")
    }

    // IDs from the other device become file names: only UUIDs pass (no path tricks).
    @Test func recordingIDsMustBeUUIDs() {
        #expect(isValidWatchRecordingID(id: UUID().uuidString))
        #expect(!isValidWatchRecordingID(id: "../Library/x"))
        #expect(!isValidWatchRecordingID(id: ""))
    }

    // The Watch deletes its copy only for recordings the iPhone reports held (in its inbox, imported or failed there),
    // never for one it could not keep.
    @Test func onlyHeldRecordingsAreDeleted() {
        let delivered: WatchLocalRecording = WatchLocalRecording(info: info(id: "1", tag: "a"), state: .delivered(transferToken: "t1"))
        let queued: WatchLocalRecording = WatchLocalRecording(info: info(id: "2", tag: "a"), state: .queued(transferToken: "t2"))
        let failedThere: WatchLocalRecording = WatchLocalRecording(info: info(id: "3", tag: "a"), state: .delivered(transferToken: "t3"))
        let rejected: WatchLocalRecording = WatchLocalRecording(info: info(id: "4", tag: "a"), state: .delivered(transferToken: "t4"))
        let reports: [WatchImportReport] = [
            WatchImportReport(id: "1", status: .held), WatchImportReport(id: "other", status: .held),
            WatchImportReport(id: "3", status: .failed(title: "", reason: "x")), WatchImportReport(id: "4", status: .notReceived(transferToken: "t4", reason: "full")),
        ]
        #expect(watchRecordingsHeldByPhone(recordings: [delivered, queued, failedThere, rejected], reports: reports) == ["1", "3"])
        #expect(watchRecordingsHeldByPhone(recordings: [delivered, queued], reports: []).isEmpty)
        #expect(watchFailedImports(reports: reports) == [WatchFailedImport(id: "3", title: "", reason: "x")])
    }

    // Compressing, failed and lost queued transfers go again; delivered ones wait for the iPhone, rejected ones for
    // "Send again".
    @Test func lostAndFailedTransfersAreRequeued() {
        let delivered: WatchLocalRecording = WatchLocalRecording(info: info(id: "1", tag: "a"), state: .delivered(transferToken: "a"))
        let queued: WatchLocalRecording = WatchLocalRecording(info: info(id: "2", tag: "a"), state: .queued(transferToken: "live"))
        let lost: WatchLocalRecording = WatchLocalRecording(info: info(id: "3", tag: "a"), state: .queued(transferToken: "gone"))
        let failed: WatchLocalRecording = WatchLocalRecording(info: info(id: "4", tag: "a"), state: .failed)
        let compressing: WatchLocalRecording = WatchLocalRecording(info: info(id: "5", tag: "a"), state: .compressing)
        let rejected: WatchLocalRecording = WatchLocalRecording(info: info(id: "6", tag: "a"), state: .rejected(reason: "full"))
        let requeued: [WatchRecordingInfo] = watchRecordingsToRequeue(
            recordings: [delivered, queued, lost, failed, compressing, rejected], queuedTokens: ["live"]
        )
        #expect(requeued.map(\.id) == ["3", "4", "5"])
    }

    // The iPhone sends nil for the switch and the limit until it has read the account: the Watch keeps what it knew for
    // the same account, and drops it for another account or after sign-out.
    @Test func unknownSwitchKeepsTheLastKnownValue() {
        let known: WatchSnapshot = snapshot(recording: nil, meetings: [], phoneAppOpen: false)
        let unknown: WatchSnapshot = WatchSnapshot(
            signedIn: true, accountTag: "a", recording: nil, meetings: [], calendarOn: true, tasks: [], maxMeetingMinutes: nil, phoneAppOpen: true,
            imports: [WatchImportReport(id: "r", status: .held)], watchRecordingEnabled: nil
        )
        let merged: WatchSnapshot = watchMergedSnapshot(previous: known, incoming: unknown)
        #expect(merged.watchRecordingEnabled == true)
        #expect(merged.maxMeetingMinutes == 180)
        #expect(merged.imports == [WatchImportReport(id: "r", status: .held)])
        #expect(merged.phoneAppOpen)
        #expect(watchCanRecord(snapshot: merged))
        let otherAccount: WatchSnapshot = WatchSnapshot(
            signedIn: true, accountTag: "b", recording: nil, meetings: [], calendarOn: true, tasks: [], maxMeetingMinutes: nil, phoneAppOpen: true,
            imports: [], watchRecordingEnabled: nil
        )
        #expect(watchMergedSnapshot(previous: known, incoming: otherAccount).watchRecordingEnabled == nil)
        #expect(!watchCanRecord(snapshot: otherAccount))
        #expect(watchMergedSnapshot(previous: known, incoming: .signedOut) == .signedOut)
    }

    @Test func batteryAndSpaceLimits() {
        #expect(watchShouldEndForBattery(battery: .discharging(level: 0.05)))
        #expect(watchShouldEndForBattery(battery: .discharging(level: 0.01)))
        #expect(!watchShouldEndForBattery(battery: .discharging(level: 0.06)))
        #expect(!watchShouldEndForBattery(battery: .charging))
        #expect(!watchShouldEndForBattery(battery: .unknown))
        #expect(watchHasRoomToRecord(availableBytes: 520_000_000))
        #expect(!watchHasRoomToRecord(availableBytes: 519_999_999))
        #expect(watchAllowanceTooShort(maxMeetingMinutes: 1))
        #expect(!watchAllowanceTooShort(maxMeetingMinutes: 2))
        #expect(!watchAllowanceTooShort(maxMeetingMinutes: nil))
    }

    // A failed meeting save keeps the Watch recording: nothing enters the import ledger (the Watch keeps its copy) and
    // the inbox audio stays. Only a save that succeeds marks the recording imported.
    @MainActor
    @Test func failedSaveKeepsWatchRecording() async throws {
        let root: URL = FileManager.default.temporaryDirectory.appending(path: "watch-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }  // Temporary folder: a failed cleanup does not change the result.
        let inbox: URL = root.appending(path: "inbox")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transferred: URL = root.appending(path: "transfer.m4a")
        try Data([1, 2, 3]).write(to: transferred)
        let stored: WatchRecordingInfo = try storeWatchRecording(
            file: transferred, payload: try watchPayload(value: info(id: UUID().uuidString, tag: "a"))[watchPayloadKey], inbox: inbox
        )
        // The meeting folder's path runs through a regular file, so writing meeting.json fails like a full or locked disk.
        let blocker: URL = root.appending(path: "not-a-folder")
        try Data().write(to: blocker)
        var ledger: [String] = []
        await #expect(throws: (any Error).self) {
            try await importWatchInboxEntry(
                inbox: inbox, id: stored.id,
                importAudio: { (_: URL) async throws -> Void in
                    try Data("{}".utf8).write(to: blocker.appending(path: "meeting.json"))
                },
                markImported: { (id: String) -> Void in ledger.append(id) }
            )
        }
        #expect(ledger.isEmpty)
        #expect(FileManager.default.fileExists(atPath: watchInboxAudioURL(inbox: inbox, id: stored.id).path))
        #expect(try readWatchInbox(inbox: inbox).entries.map(\.id) == [stored.id])

        let meeting: URL = root.appending(path: "meeting")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try await importWatchInboxEntry(
            inbox: inbox, id: stored.id,
            importAudio: { (audio: URL) async throws -> Void in
                try FileManager.default.copyItem(at: audio, to: meeting.appending(path: "others.m4a"))
                try Data("{}".utf8).write(to: meeting.appending(path: "meeting.json"))
            },
            markImported: { (id: String) -> Void in ledger.append(id) }
        )
        #expect(ledger == [stored.id])
    }
}
