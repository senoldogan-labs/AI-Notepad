import Foundation
import Testing
@testable import AINotepadCore

/// States that used to be spread over parallel optionals and flags and are now one value: each test checks that the
/// combination the old fields allowed but never meant cannot be built, and that the derived fields still read the same.
@Suite struct StateInvariantTests {
    // A final pass that stopped half-way always carries its reason; a complete one has no covered-until time.
    @Test func finalPassCoverageKeepsTheNoticeWithAPartialPass() {
        let complete: FinalPassResult = FinalPassResult(segments: [], language: nil, coverage: .complete(notice: "speakers"))
        #expect(complete.notice == "speakers")
        #expect(complete.coveredUntilSec == nil)
        let partial: FinalPassResult = FinalPassResult(segments: [], language: nil, coverage: .partial(coveredUntilSec: 3_600, notice: "limit"))
        #expect(partial.notice == "limit")
        #expect(partial.coveredUntilSec == 3_600)
    }

    // The server sends a code only with a pending number; a verified number never carries one, and a code without its
    // expiry is rejected instead of being read as "verified".
    @Test func phoneVerificationDecodesIntoOneCase() throws {
        let decoder: JSONDecoder = JSONDecoder()
        let pending: HostedPhoneVerification = try decoder.decode(
            HostedPhoneVerification.self, from: Data(#"{"e164":"+14155550100","status":"pending","validationCode":"123456","expiresAt":1793000000000}"#.utf8)
        )
        #expect(pending == .awaitingCall(e164: "+14155550100", code: "123456", expiresAt: 1_793_000_000_000))
        let verified: HostedPhoneVerification = try decoder.decode(HostedPhoneVerification.self, from: Data(#"{"e164":"+14155550100","status":"verified"}"#.utf8))
        #expect(verified == .verified(e164: "+14155550100"))
        #expect(throws: DecodingError.self) {
            try decoder.decode(HostedPhoneVerification.self, from: Data(#"{"e164":"+14155550100","status":"pending","validationCode":"123456"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(HostedPhoneVerification.self, from: Data(#"{"e164":"+14155550100","status":"failed"}"#.utf8))
        }
    }

    // A token without a lifetime has no made-up expiry: it is never refreshed ahead of time and survives the Keychain
    // round trip as "unknown".
    @Test func tokenWithoutExpiryIsNotRefreshedAhead() throws {
        let now: Date = Date(timeIntervalSince1970: 1_793_000_000)
        let open: OAuthTokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: nil)
        #expect(!needsRefresh(tokens: open, now: now))
        let encoded: Data = try JSONEncoder().encode(open)
        #expect(try JSONDecoder().decode(OAuthTokens.self, from: encoded) == open)
        #expect(needsRefresh(tokens: OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(60)), now: now))
    }

    // The callback wait is idle, waiting or finished, never "waiting" with a result parked next to it: the first result
    // wins, a result before the wait is handed to it, and a second waiter is refused instead of replacing the first.
    @Test func loopbackWaitHandsTheFirstResultOnce() throws {
        let url: URL = try #require(URL(string: "http://127.0.0.1:1/callback?code=c&state=s"))
        let waiting: LoopbackWaitStep<Int> = loopbackWaitBegin(wait: LoopbackWait<Int>.idle, waiter: 1)
        #expect(waiting.resume == nil)
        let second: LoopbackWaitStep<Int> = loopbackWaitBegin(wait: waiting.wait, waiter: 2)
        #expect(second.resume?.waiter == 2)
        #expect(throws: LoopbackRedirectError.alreadyWaiting) { try second.resume?.result.get() }
        let finished: LoopbackWaitStep<Int> = loopbackWaitFinish(wait: second.wait, result: .success(url))
        #expect(finished.resume?.waiter == 1)
        #expect(try finished.resume?.result.get() == url)
        // A late timeout or cancel after the callback changes nothing and resumes no one.
        let late: LoopbackWaitStep<Int> = loopbackWaitFinish(wait: finished.wait, result: .failure(CancellationError()))
        #expect(late.resume == nil)
        #expect(try loopbackWaitBegin(wait: late.wait, waiter: 3).resume?.result.get() == url)
        // The callback arrived before anyone waited: the waiter gets it at once.
        let early: LoopbackWaitStep<Int> = loopbackWaitFinish(wait: LoopbackWait<Int>.idle, result: .success(url))
        #expect(early.resume == nil)
        #expect(try loopbackWaitBegin(wait: early.wait, waiter: 4).resume?.result.get() == url)
    }

    // A failure kind is written only together with the failed status; any later status change clears it.
    @Test func failureKindExistsOnlyOnAFailedMeeting() {
        let record: MeetingRecord = MeetingRecord(
            id: "m", title: "", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, language: nil, status: .processing,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
            engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let failed: MeetingRecord = record.failed(message: "Note: offline", kind: .transient)
        #expect(failed.status == .failed)
        #expect(failed.failureMessage == "Note: offline")
        #expect(failed.failureKind == .transient)
        let retried: MeetingRecord = failed.with(status: .processing, failureMessage: nil)
        #expect(retried.failureKind == nil)
    }

    // An update relaunch waits while the offline queue prepares a meeting on the server, like it waits for recording,
    // processing and note delivery.
    @Test func offlineQueueBlocksTheUpdateRelaunch() {
        #expect(blocksUpdateRelaunch(recorderBusy: false, autoSendRunning: false, autoDeliveriesInFlight: 0, offlineQueueRunning: true))
        #expect(blocksUpdateRelaunch(recorderBusy: true, autoSendRunning: false, autoDeliveriesInFlight: 0, offlineQueueRunning: false))
        #expect(blocksUpdateRelaunch(recorderBusy: false, autoSendRunning: false, autoDeliveriesInFlight: 1, offlineQueueRunning: false))
        #expect(!blocksUpdateRelaunch(recorderBusy: false, autoSendRunning: false, autoDeliveriesInFlight: 0, offlineQueueRunning: false))
    }

    // The on-device preview failing, recovering and failing again in one recording counts once; a cloud track's stop
    // never counts.
    @Test func onDeviceFailureCountsOncePerRecording() {
        let choice: AppleSpeechChoice = AppleSpeechChoice(kind: .speech, localeIdentifier: "en-US")
        let start: LiveTextState = LiveTextState(
            routes: HostedLiveRoutes(me: .cloud, others: .onDevice(choice)), liveSpeakers: [.me, .others], stopped: [:], onDeviceFailureCounted: false
        )
        #expect(!liveTextCountsOnDeviceFailure(state: start, speaker: .me))
        #expect(liveTextCountsOnDeviceFailure(state: start, speaker: .others))
        let cloudStopped: LiveTextState = liveTextStep(state: start, event: .streamFailed(speaker: .me, message: "x"))
        #expect(liveTextCountsOnDeviceFailure(state: cloudStopped, speaker: .others))
        let firstStop: LiveTextState = liveTextStep(state: cloudStopped, event: .streamFailed(speaker: .others, message: "model"))
        let recovered: LiveTextState = liveTextStep(state: firstStop, event: .streamRecovered(speaker: .others))
        #expect(!liveTextCountsOnDeviceFailure(state: recovered, speaker: .others))
        #expect(liveTextOnDevice(state: recovered))
    }
}
