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
            phoneAppOpen: phoneAppOpen, receivedRecordingIDs: [], failedImports: [], watchRecordingEnabled: true
        )
    }

    // Every message type survives the trip through a WatchConnectivity payload.
    @Test func payloadsRoundTrip() throws {
        let requests: [WatchRequest] = [
            .startPhoneRecording, .pausePhoneRecording(recordingID: "r"), .resumePhoneRecording(recordingID: "r"), .stopPhoneRecording(recordingID: "r"),
            .completeTask(meetingID: "m", taskKey: "you|send deck"), .retryImport(recordingID: "r"), .deleteImport(recordingID: "r"), .refresh,
        ]
        for request in requests {
            let payload: [String: Data] = try watchPayload(value: request)
            #expect(try watchValue(type: WatchRequest.self, data: payload[watchPayloadKey]) == request)
        }
        let replies: [WatchReply] = [.done, .phoneAppNotOpen, .signedOut, .recordingChanged, .failed(reason: "x")]
        for reply in replies {
            #expect(try watchValue(type: WatchReply.self, data: try watchPayload(value: reply)[watchPayloadKey]) == reply)
        }
        let full: WatchSnapshot = WatchSnapshot(
            signedIn: true, accountTag: "a",
            recording: WatchPhoneRecording(recordingID: "r", phase: .paused, title: "T", timerStart: now, timerStoppedAt: now + 5),
            meetings: [WatchMeeting(id: "e", title: "E", start: now, end: now + 60)], calendarOn: true,
            tasks: [WatchTask(meetingID: "m", taskKey: "k", text: "t", meetingTitle: "M", due: nil)], maxMeetingMinutes: 120, phoneAppOpen: true,
            receivedRecordingIDs: ["x"], failedImports: [WatchFailedImport(id: "y", title: "Y", reason: "too long")],
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

    // The Watch deletes its copy only for recordings the iPhone's snapshot says it holds.
    @Test func onlyConfirmedRecordingsAreDeleted() {
        let sent: WatchLocalRecording = WatchLocalRecording(info: info(id: "1", tag: "a"), state: .sent)
        let waiting: WatchLocalRecording = WatchLocalRecording(info: info(id: "2", tag: "a"), state: .waiting)
        let confirming: WatchSnapshot = WatchSnapshot(
            signedIn: true, accountTag: "a", recording: nil, meetings: [], calendarOn: false, tasks: [], maxMeetingMinutes: nil, phoneAppOpen: false,
            receivedRecordingIDs: ["1", "other"], failedImports: [], watchRecordingEnabled: false
        )
        #expect(watchRecordingsConfirmedByPhone(recordings: [sent, waiting], snapshot: confirming) == ["1"])
        #expect(watchRecordingsConfirmedByPhone(recordings: [sent, waiting], snapshot: .signedOut).isEmpty)
    }

    // Waiting and failed recordings no longer queued go again; sent ones wait for the iPhone's confirmation.
    @Test func lostAndFailedTransfersAreRequeued() {
        let sent: WatchLocalRecording = WatchLocalRecording(info: info(id: "1", tag: "a"), state: .sent)
        let waitingQueued: WatchLocalRecording = WatchLocalRecording(info: info(id: "2", tag: "a"), state: .waiting)
        let waitingLost: WatchLocalRecording = WatchLocalRecording(info: info(id: "3", tag: "a"), state: .waiting)
        let failed: WatchLocalRecording = WatchLocalRecording(info: info(id: "4", tag: "a"), state: .failed)
        let preparing: WatchLocalRecording = WatchLocalRecording(info: info(id: "5", tag: "a"), state: .preparing)
        let requeued: [WatchRecordingInfo] = watchRecordingsToRequeue(
            recordings: [sent, waitingQueued, waitingLost, failed, preparing], queuedFileNames: [watchRecordingFileName(id: "2")]
        )
        #expect(requeued.map(\.id) == ["3", "4", "5"])
    }

    // The iPhone sends nil for the switch and the limit until it has read the account: the Watch keeps what it knew for
    // the same account, and drops it for another account or after sign-out.
    @Test func unknownSwitchKeepsTheLastKnownValue() {
        let known: WatchSnapshot = snapshot(recording: nil, meetings: [], phoneAppOpen: false)
        let unknown: WatchSnapshot = WatchSnapshot(
            signedIn: true, accountTag: "a", recording: nil, meetings: [], calendarOn: true, tasks: [], maxMeetingMinutes: nil, phoneAppOpen: true,
            receivedRecordingIDs: ["r"], failedImports: [], watchRecordingEnabled: nil
        )
        let merged: WatchSnapshot = watchMergedSnapshot(previous: known, incoming: unknown)
        #expect(merged.watchRecordingEnabled == true)
        #expect(merged.maxMeetingMinutes == 180)
        #expect(merged.receivedRecordingIDs == ["r"])
        #expect(merged.phoneAppOpen)
        #expect(watchCanRecord(snapshot: merged))
        let otherAccount: WatchSnapshot = WatchSnapshot(
            signedIn: true, accountTag: "b", recording: nil, meetings: [], calendarOn: true, tasks: [], maxMeetingMinutes: nil, phoneAppOpen: true,
            receivedRecordingIDs: [], failedImports: [], watchRecordingEnabled: nil
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
}
