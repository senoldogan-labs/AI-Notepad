import AINotepadCore
import Foundation
import Testing

struct PhoneCallKitStateTests {
    private let first: UUID = UUID()
    private let second: UUID = UUID()

    private func run(_ events: [PhoneCallKitEvent]) -> PhoneCallKitState {
        events.reduce(PhoneCallKitState.idle) { (state: PhoneCallKitState, event: PhoneCallKitEvent) -> PhoneCallKitState in
            phoneCallKitTransition(state: state, event: event)
        }
    }

    // The user hangs up and CallKit performs the end: the end is not reported again.
    @Test func endPerformedByCallKitIsNotReportedAgain() {
        let state: PhoneCallKitState = run([.startRequested(uuid: first, accessToken: "t", callID: "c"), .startPerformed(uuid: first), .endPerformed(uuid: first)])
        #expect(state == .endedByCallKit(uuid: first))
        #expect(!phoneCallKitReportsEnd(state: state, uuid: first))
    }

    // The end request failed (CallKit never performed it): the remote end later is still reported, no ghost call.
    @Test func failedEndRequestStillReportsRemoteEnd() {
        let state: PhoneCallKitState = run([.startRequested(uuid: first, accessToken: "t", callID: "c"), .startPerformed(uuid: first)])
        #expect(state == .active(uuid: first))
        #expect(phoneCallKitReportsEnd(state: state, uuid: first))
    }

    // A late end action for an earlier call doesn't mark the next call as ended.
    @Test func anotherCallsEventsChangeNothing() {
        let state: PhoneCallKitState = run([
            .startRequested(uuid: first, accessToken: "t", callID: "a"), .startPerformed(uuid: first), .finished,
            .startRequested(uuid: second, accessToken: "u", callID: "b"), .startPerformed(uuid: second), .endPerformed(uuid: first),
        ])
        #expect(state == .active(uuid: second))
        #expect(phoneCallKitReportsEnd(state: state, uuid: second))
        #expect(phoneCallKitTransition(state: .starting(uuid: second, accessToken: "u", callID: "b"), event: .startPerformed(uuid: first))
            == .starting(uuid: second, accessToken: "u", callID: "b"))
    }

    @Test func failedStartRequestReturnsToIdle() {
        #expect(run([.startRequested(uuid: first, accessToken: "t", callID: "c"), .startRequestFailed(uuid: first)]) == .idle)
        #expect(run([.startRequested(uuid: first, accessToken: "t", callID: "c"), .startPerformed(uuid: first), .finished]) == .idle)
    }

    // Call B's ended panel never shows call A's import result.
    @Test func endedPanelShowsOnlyItsOwnCallsImport() {
        let imports: [String: PhoneRecordingImport] = ["call-a": .imported]
        #expect(phoneRecordingImport(callID: "call-b", imports: imports) == .waiting)
        #expect(phoneRecordingImport(callID: "call-a", imports: imports) == .imported)
    }
}
