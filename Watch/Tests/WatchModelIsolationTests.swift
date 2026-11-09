import AINotepadWatchLink
import Foundation
import Testing
import WatchConnectivity
@testable import AINotepadWatch

/// WatchConnectivity calls its reply, error and delegate blocks on its own background queue. A block that Swift 6
/// infers as main-actor isolated traps there (`_dispatch_assert_queue_fail`; it crashed the app in the paired Simulator
/// on the first iPhone command). These tests call every such entry point from a background queue, as WatchConnectivity
/// does: a trap would crash the test host.
@MainActor
@Suite(.serialized) struct WatchModelIsolationTests {
    private let model: WatchAppModel = WatchAppModel.shared

    /// Runs `body` on a background queue and waits for it.
    private func onBackgroundQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                body()
                continuation.resume()
            }
        }
    }

    /// Lets the main actor run the hops the blocks scheduled.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func replyAndErrorBlocksRunOffTheMainQueue() async throws {
        model.problem = nil
        let reply: @Sendable ([String: Any]) -> Void = WatchAppModel.replyHandler(model: model)
        let payload: [String: Data] = try watchPayload(value: WatchReply.phoneAppNotOpen)
        await onBackgroundQueue {
            reply(payload)
        }
        try await settle()
        #expect(model.problem != nil)

        model.problem = nil
        let failure: @Sendable (any Error) -> Void = WatchAppModel.errorHandler(model: model)
        await onBackgroundQueue {
            failure(WatchLinkError.missingPayload)
        }
        try await settle()
        #expect(model.problem != nil)
        #expect(!model.isSending)
        model.problem = nil
    }

    @Test func delegateCallbacksRunOffTheMainQueue() async throws {
        let snapshot: WatchSnapshot = WatchSnapshot(
            signedIn: true, accountTag: "isolation-test", recording: nil, meetings: [], calendarOn: false, tasks: [], maxMeetingMinutes: 60,
            phoneAppOpen: false, imports: [], watchRecordingEnabled: true
        )
        let context: [String: Data] = try watchPayload(value: snapshot)
        let model: WatchAppModel = model
        await onBackgroundQueue {
            model.session(WCSession.default, didReceiveApplicationContext: context)
            model.session(WCSession.default, didReceiveUserInfo: context)
            model.sessionReachabilityDidChange(WCSession.default)
        }
        try await settle()
        #expect(model.snapshot.accountTag == "isolation-test")
        #expect(model.snapshot.watchRecordingEnabled == true)
        // Leave the shared model signed out for the other tests.
        let signedOut: [String: Data] = try watchPayload(value: WatchSnapshot.signedOut)
        await onBackgroundQueue {
            model.session(WCSession.default, didReceiveApplicationContext: signedOut)
        }
        try await settle()
        #expect(!model.snapshot.signedIn)
    }
}
