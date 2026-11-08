import Foundation

/// The in-app dialer's CallKit call as the call controller tracks it (one call at a time). The Voice SDK's call object
/// stays in the controller; this value says which CallKit call it belongs to and whether CallKit already knows it ended.
public enum PhoneCallKitState: Sendable, Equatable {
    case idle
    /// A start was requested; CallKit has not performed it yet. Carries what connecting the Voice SDK leg needs.
    case starting(uuid: UUID, accessToken: String, callID: String)
    /// CallKit performed the start; the Voice SDK leg is connecting or connected.
    case active(uuid: UUID)
    /// CallKit performed an end action for this call (the user hung up here, on the lock screen or in the car): CallKit
    /// already knows it ended, so the end is not reported again.
    case endedByCallKit(uuid: UUID)
}

/// What happened to the dialer's CallKit call.
public enum PhoneCallKitEvent: Sendable, Equatable {
    case startRequested(uuid: UUID, accessToken: String, callID: String)
    /// CallKit's start request failed (nothing to connect).
    case startRequestFailed(uuid: UUID)
    /// CallKit performed the start action.
    case startPerformed(uuid: UUID)
    /// CallKit performed an end action.
    case endPerformed(uuid: UUID)
    /// The Voice SDK leg ended (disconnected, failed to connect) or CallKit reset the provider.
    case finished
}

/// The controller's next state. Only an end action CallKit actually performed marks the call as ended by CallKit: a
/// failed end request leaves the call active, so its later remote end is still reported (no ghost call in CallKit).
/// Events for another call's uuid change nothing. Pure function.
public func phoneCallKitTransition(state: PhoneCallKitState, event: PhoneCallKitEvent) -> PhoneCallKitState {
    switch (state, event) {
    case (_, .startRequested(let uuid, let accessToken, let callID)):
        return .starting(uuid: uuid, accessToken: accessToken, callID: callID)
    case (.starting(let current, _, _), .startRequestFailed(let uuid)) where current == uuid:
        return .idle
    case (.starting(let current, _, _), .startPerformed(let uuid)) where current == uuid:
        return .active(uuid: uuid)
    case (.starting(let current, _, _), .endPerformed(let uuid)) where current == uuid,
         (.active(let current), .endPerformed(let uuid)) where current == uuid:
        return .endedByCallKit(uuid: uuid)
    case (_, .finished):
        return .idle
    default:
        return state
    }
}

/// Whether the controller reports the end of call `uuid` to CallKit when it finishes: yes unless CallKit performed its
/// end action itself. Pure function.
public func phoneCallKitReportsEnd(state: PhoneCallKitState, uuid: UUID) -> Bool {
    state != .endedByCallKit(uuid: uuid)
}

/// The finished call's recording on its way to a meeting.
public enum PhoneRecordingImport: Sendable, Equatable {
    /// The call ended; waiting for the provider's recording.
    case waiting
    case importing
    case imported
    /// The call has no recording (never answered, no audio).
    case noRecording
    case failed(String)
}

/// The import state the ended-call panel shows for call `callID`: its own entry, or waiting when its import has not
/// reported yet. Another call's import never shows here. Pure function.
public func phoneRecordingImport(callID: String, imports: [String: PhoneRecordingImport]) -> PhoneRecordingImport {
    imports[callID] ?? .waiting
}
