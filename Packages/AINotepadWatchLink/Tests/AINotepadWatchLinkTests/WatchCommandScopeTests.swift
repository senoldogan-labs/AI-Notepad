import Foundation
import Testing
@testable import AINotepadWatchLink

/// Mutating Watch commands carry the account they were made for (P16): the iPhone's decision for a matching, another
/// and a missing tag, the Watch's done-mark outbox, request-bound send state, and both directions of wire compatibility.
@Suite struct WatchCommandScopeTests {
    // MARK: iPhone decision

    @Test func matchingTagExecutes() {
        let requests: [WatchRequest] = [
            .startPhoneRecording(accountTag: "a"), .pausePhoneRecording(recordingID: "r", accountTag: "a"),
            .resumePhoneRecording(recordingID: "r", accountTag: "a"), .stopPhoneRecording(recordingID: "r", accountTag: "a"),
            .completeTask(meetingID: "m", taskKey: "k", accountTag: "a"), .retryImport(recordingID: "r", accountTag: "a"),
            .deleteImport(recordingID: "r", accountTag: "a"), .refresh,
        ]
        for request in requests {
            #expect(watchCommandDecision(request: request, loadedAccountTag: "a", importAccountTag: "a") == .execute)
        }
    }

    @Test func otherAccountTagIsRefused() {
        let requests: [WatchRequest] = [
            .startPhoneRecording(accountTag: "b"), .pausePhoneRecording(recordingID: "r", accountTag: "b"),
            .resumePhoneRecording(recordingID: "r", accountTag: "b"), .stopPhoneRecording(recordingID: "r", accountTag: "b"),
            .completeTask(meetingID: "m", taskKey: "k", accountTag: "b"), .retryImport(recordingID: "r", accountTag: "b"),
            .deleteImport(recordingID: "r", accountTag: "b"),
        ]
        for request in requests {
            #expect(watchCommandDecision(request: request, loadedAccountTag: "a", importAccountTag: "a") == .refuseOtherAccount)
        }
    }

    // An old Watch sends no tag. A command whose owner the payload cannot prove is refused, never run under the
    // current account; a recording ID proves it (the iPhone checks it names its running recording, or an import of
    // the loaded account). Read-only `refresh` is unchanged.
    @Test func missingTagExecutesOnlyWhenTheOwnerIsProved() {
        #expect(watchCommandDecision(request: .completeTask(meetingID: "m", taskKey: "k", accountTag: nil), loadedAccountTag: "a", importAccountTag: nil)
            == .refuseUnscoped)
        #expect(watchCommandDecision(request: .startPhoneRecording(accountTag: nil), loadedAccountTag: "a", importAccountTag: nil) == .refuseUnscoped)
        for request in [
            WatchRequest.pausePhoneRecording(recordingID: "r", accountTag: nil), .resumePhoneRecording(recordingID: "r", accountTag: nil),
            .stopPhoneRecording(recordingID: "r", accountTag: nil), .refresh,
        ] {
            #expect(watchCommandDecision(request: request, loadedAccountTag: "a", importAccountTag: nil) == .execute)
        }
        for request in [WatchRequest.retryImport(recordingID: "r", accountTag: nil), .deleteImport(recordingID: "r", accountTag: nil)] {
            #expect(watchCommandDecision(request: request, loadedAccountTag: "a", importAccountTag: "a") == .execute)
            #expect(watchCommandDecision(request: request, loadedAccountTag: "a", importAccountTag: "b") == .refuseUnscoped)
            #expect(watchCommandDecision(request: request, loadedAccountTag: "a", importAccountTag: nil) == .refuseUnscoped)
        }
    }

    // MARK: Wire compatibility

    // Payloads of the Watch build before the tag (exact JSON it encodes) still decode, as untagged commands.
    @Test func oldPayloadsDecodeWithoutTag() throws {
        let fixtures: [(String, WatchRequest)] = [
            (#"{"startPhoneRecording":{}}"#, .startPhoneRecording(accountTag: nil)),
            (#"{"pausePhoneRecording":{"recordingID":"r"}}"#, .pausePhoneRecording(recordingID: "r", accountTag: nil)),
            (#"{"resumePhoneRecording":{"recordingID":"r"}}"#, .resumePhoneRecording(recordingID: "r", accountTag: nil)),
            (#"{"stopPhoneRecording":{"recordingID":"r"}}"#, .stopPhoneRecording(recordingID: "r", accountTag: nil)),
            (#"{"completeTask":{"meetingID":"m","taskKey":"you|send deck"}}"#, .completeTask(meetingID: "m", taskKey: "you|send deck", accountTag: nil)),
            (#"{"retryImport":{"recordingID":"r"}}"#, .retryImport(recordingID: "r", accountTag: nil)),
            (#"{"deleteImport":{"recordingID":"r"}}"#, .deleteImport(recordingID: "r", accountTag: nil)),
            (#"{"refresh":{}}"#, .refresh),
        ]
        for (json, request) in fixtures {
            #expect(try watchValue(type: WatchRequest.self, data: Data(json.utf8)) == request)
        }
    }

    // An iPhone build before the tag decodes the tagged commands as the commands it knows (unknown keys are ignored).
    @Test func taggedPayloadsDecodeOnAnOldPhone() throws {
        let pairs: [(WatchRequest, LegacyWatchRequest)] = [
            (.startPhoneRecording(accountTag: "a"), .startPhoneRecording),
            (.pausePhoneRecording(recordingID: "r", accountTag: "a"), .pausePhoneRecording(recordingID: "r")),
            (.resumePhoneRecording(recordingID: "r", accountTag: "a"), .resumePhoneRecording(recordingID: "r")),
            (.stopPhoneRecording(recordingID: "r", accountTag: "a"), .stopPhoneRecording(recordingID: "r")),
            (.completeTask(meetingID: "m", taskKey: "k", accountTag: "a"), .completeTask(meetingID: "m", taskKey: "k")),
            (.retryImport(recordingID: "r", accountTag: "a"), .retryImport(recordingID: "r")),
            (.deleteImport(recordingID: "r", accountTag: "a"), .deleteImport(recordingID: "r")),
            (.refresh, .refresh),
        ]
        for (request, legacy) in pairs {
            let data: Data? = try watchPayload(value: request)[watchPayloadKey]
            #expect(try watchValue(type: LegacyWatchRequest.self, data: data) == legacy)
            #expect(try watchValue(type: WatchRequest.self, data: data) == request)
        }
        #expect(try watchValue(type: WatchReply.self, data: try watchPayload(value: WatchReply.accountChanged)[watchPayloadKey]) == .accountChanged)
        let mark: WatchDoneMark = WatchDoneMark(meetingID: "m", taskKey: "k", accountTag: "a")
        #expect(try watchValue(type: [WatchDoneMark].self, data: try watchPayload(value: [mark])[watchPayloadKey]) == [mark])
    }

    // MARK: Watch: done-mark outbox

    private func task(meetingID: String, key: String) -> WatchTask {
        WatchTask(meetingID: meetingID, taskKey: key, text: "t", meetingTitle: "M", due: nil)
    }

    private func snapshot(tag: String?, tasks: [WatchTask]) -> WatchSnapshot {
        WatchSnapshot(
            signedIn: tag != nil, accountTag: tag, recording: nil, meetings: [], calendarOn: false, tasks: tasks, maxMeetingMinutes: nil,
            phoneAppOpen: false, imports: [], watchRecordingEnabled: nil
        )
    }

    // A mark saved while the session was inactive is sent once it is active, only while the iPhone shows its account,
    // and not while the same mark is still queued.
    @Test func outboxSendsMarksOfTheShownAccountNotQueued() {
        let a1: WatchDoneMark = WatchDoneMark(meetingID: "m1", taskKey: "k", accountTag: "a")
        let a2: WatchDoneMark = WatchDoneMark(meetingID: "m2", taskKey: "k", accountTag: "a")
        let b1: WatchDoneMark = WatchDoneMark(meetingID: "m3", taskKey: "k", accountTag: "b")
        #expect(watchDoneMarksToSend(outbox: [a1, a2, b1], snapshotAccountTag: "a", queued: [a2]) == [a1])
        #expect(watchDoneMarksToSend(outbox: [a1, a2, b1], snapshotAccountTag: "b", queued: []) == [b1])
        #expect(watchDoneMarksToSend(outbox: [a1, b1], snapshotAccountTag: nil, queued: []).isEmpty)
    }

    // Only a snapshot of the mark's own account acknowledges it (the task is gone from that account's list); another
    // account's snapshot or a signed-out one keeps it for when its account is back.
    @Test func onlyTheMarksAccountAcknowledgesIt() {
        let mark: WatchDoneMark = WatchDoneMark(meetingID: "m1", taskKey: "k", accountTag: "a")
        let open: WatchTask = task(meetingID: "m1", key: "k")
        #expect(watchDoneMarksAfterSnapshot(outbox: [mark], snapshot: snapshot(tag: "a", tasks: [open])) == [mark])
        #expect(watchDoneMarksAfterSnapshot(outbox: [mark], snapshot: snapshot(tag: "a", tasks: [])).isEmpty)
        #expect(watchDoneMarksAfterSnapshot(outbox: [mark], snapshot: snapshot(tag: "b", tasks: [])) == [mark])
        #expect(watchDoneMarksAfterSnapshot(outbox: [mark], snapshot: snapshot(tag: nil, tasks: [])) == [mark])
        #expect(watchHiddenTaskIDs(markedDone: ["x"], outbox: [mark], snapshotAccountTag: "a") == ["x", open.id])
        #expect(watchHiddenTaskIDs(markedDone: ["x"], outbox: [mark], snapshotAccountTag: "b") == ["x"])
    }

    @Test func addingAMarkIsIdempotentAndBounded() {
        let first: WatchDoneMark = WatchDoneMark(meetingID: "m1", taskKey: "k", accountTag: "a")
        let second: WatchDoneMark = WatchDoneMark(meetingID: "m2", taskKey: "k", accountTag: "a")
        let third: WatchDoneMark = WatchDoneMark(meetingID: "m3", taskKey: "k", accountTag: "a")
        #expect(watchDoneMarksAdding(outbox: [first], mark: first, limit: 2) == [first])
        #expect(watchDoneMarksAdding(outbox: [first, second], mark: third, limit: 2) == [second, third])
    }

    // MARK: Watch: request-bound send state

    // A late reply (or error) of an older request neither clears a newer request's sending state nor shows its result.
    @Test func lateReplyOfAnOldRequestIsIgnored() {
        let old: UUID = UUID()
        let new: UUID = UUID()
        #expect(watchSendAfterAnswer(sendingRequestID: new, answeredRequestID: old) == WatchSendTransition(sendingRequestID: new, publishes: false))
        #expect(watchSendAfterAnswer(sendingRequestID: nil, answeredRequestID: old) == WatchSendTransition(sendingRequestID: nil, publishes: false))
        #expect(watchSendAfterAnswer(sendingRequestID: new, answeredRequestID: new) == WatchSendTransition(sendingRequestID: nil, publishes: true))
    }
}

/// `WatchRequest` exactly as the iPhone build before the account tag declared it (wire fixture for compatibility).
private enum LegacyWatchRequest: Codable, Equatable {
    case startPhoneRecording
    case pausePhoneRecording(recordingID: String)
    case resumePhoneRecording(recordingID: String)
    case stopPhoneRecording(recordingID: String)
    case completeTask(meetingID: String, taskKey: String)
    case retryImport(recordingID: String)
    case deleteImport(recordingID: String)
    case refresh
}
