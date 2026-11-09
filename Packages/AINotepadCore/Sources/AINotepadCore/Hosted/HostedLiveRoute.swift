import Foundation

// On-device live preview (Gistsmith): where each recorded track's live transcript is written. The saved transcript of a
// track the final pass re-transcribes ("Diğerleri") comes from the server, so its live text is only a preview and can
// be written on the device for free; a track whose live text is saved as is (Mac "Sen") stays on the cloud stream.
// Design: docs/superpowers/specs/2026-11-08-on-device-live-preview.md.

/// Whether this device can write the meeting language's live transcript on the device right now.
public enum OnDeviceLiveSupport: Sendable, Equatable {
    /// The system has `SpeechAnalyzer`, Apple supports the language and its model is installed.
    case ready(AppleSpeechChoice)
    /// Supported, but the language's model is not installed yet (it is installed in the background for the next meeting).
    case modelNotInstalled(AppleSpeechChoice)
    /// Apple's on-device recognition does not support the meeting language.
    case unsupportedLanguage
    /// The system is older than macOS 26 or iOS 26 (no `SpeechAnalyzer`).
    case requiresNewerSystem
}

/// Where one track's live transcript is written.
public enum HostedTrackRoute: Sendable, Equatable {
    /// Apple's on-device recognition (free; nothing leaves the device for the live text).
    case onDevice(AppleSpeechChoice)
    /// The server's cloud stream (Deepgram); if it stops, the session falls back to the local engine as before.
    case cloud
    /// The server offers no cloud stream (policy off or budget used up): the local engine, as before this change.
    case local
}

/// The routes of a recording's two tracks.
public struct HostedLiveRoutes: Sendable, Equatable {
    public let me: HostedTrackRoute
    public let others: HostedTrackRoute

    public init(me: HostedTrackRoute, others: HostedTrackRoute) {
        self.me = me
        self.others = others
    }
}

/// The on-device support from the facts the device reports: system, the language's Apple module choice (nil when
/// unsupported) and whether its model is installed. Pure function.
public func onDeviceLiveSupport(systemSupported: Bool, choice: AppleSpeechChoice?, installed: Bool) -> OnDeviceLiveSupport {
    guard systemSupported else {
        return .requiresNewerSystem
    }
    guard let choice else {
        return .unsupportedLanguage
    }
    return installed ? .ready(choice) : .modelNotInstalled(choice)
}

/// A track's route when its live text is only a preview (the final pass re-transcribes it): on the device when the
/// user is in the rollout and the device is ready; otherwise what the server offers (cloud, or local when it offers no
/// cloud stream). Pure function.
public func previewTrackRoute(serverEngine: HostedLiveEngine, inRollout: Bool, support: OnDeviceLiveSupport) -> HostedTrackRoute {
    if inRollout, case .ready(let choice) = support {
        return .onDevice(choice)
    }
    return serverTrackRoute(serverEngine: serverEngine)
}

/// A track's route when its live text is saved as the transcript (Mac "Sen"): what the server offers, never the on-device
/// preview, so the saved transcript keeps its quality. Pure function.
public func serverTrackRoute(serverEngine: HostedLiveEngine) -> HostedTrackRoute {
    switch serverEngine {
    case .deepgram: .cloud
    case .whisperKit: .local
    }
}

/// The routes of a recording's tracks: "Diğerleri" (Mac system audio; the microphone in in-person mode and on iPhone)
/// is always re-transcribed by the final pass, so its live text is a preview; Mac "Sen" is saved as its live text, so it
/// follows the server. A track that is not recorded (iPhone and in-person "Sen") keeps a route that is never used.
/// Pure function.
public func hostedLiveRoutes(serverEngine: HostedLiveEngine, inRollout: Bool, support: OnDeviceLiveSupport) -> HostedLiveRoutes {
    HostedLiveRoutes(
        me: serverTrackRoute(serverEngine: serverEngine),
        others: previewTrackRoute(serverEngine: serverEngine, inRollout: inRollout, support: support)
    )
}

/// A track's route. Pure function.
public func trackRoute(routes: HostedLiveRoutes, speaker: Speaker) -> HostedTrackRoute {
    switch speaker {
    case .me: routes.me
    case .others: routes.others
    }
}

/// The live tracks whose route is the cloud stream (one Deepgram stream each). Pure function.
public func cloudSpeakers(routes: HostedLiveRoutes, liveSpeakers: Set<Speaker>) -> Set<Speaker> {
    liveSpeakers.filter { (speaker: Speaker) -> Bool in trackRoute(routes: routes, speaker: speaker) == .cloud }
}

/// The live tracks written on the device from the start (on-device preview). Pure function.
public func onDeviceSpeakers(routes: HostedLiveRoutes, liveSpeakers: Set<Speaker>) -> Set<Speaker> {
    liveSpeakers.filter { (speaker: Speaker) -> Bool in
        if case .onDevice = trackRoute(routes: routes, speaker: speaker) {
            return true
        }
        return false
    }
}

/// The routes after the cloud stream became unavailable (no grant at start, or the stream stopped): cloud tracks move to
/// the local engine, on-device tracks stay. Pure function.
public func routesAfterCloudFallback(routes: HostedLiveRoutes) -> HostedLiveRoutes {
    HostedLiveRoutes(me: routes.me == .cloud ? .local : routes.me, others: routes.others == .cloud ? .local : routes.others)
}

/// Where a recording's live transcript runs, for diagnostics.
public enum HostedLivePlace: Sendable, Equatable {
    /// Every live track on this device (on-device preview or the local engine).
    case device
    /// Every live track in the cloud.
    case cloud
    /// Some tracks on this device, some in the cloud (Mac: "Diğerleri" on the device, "Sen" in the cloud).
    case deviceAndCloud
}

/// Where the live tracks run; with no live track, where "Diğerleri" would run. Pure function.
public func hostedLivePlace(routes: HostedLiveRoutes, liveSpeakers: Set<Speaker>) -> HostedLivePlace {
    let speakers: Set<Speaker> = liveSpeakers.isEmpty ? [.others] : liveSpeakers
    let cloud: Int = cloudSpeakers(routes: routes, liveSpeakers: speakers).count
    if cloud == 0 {
        return .device
    }
    return cloud == speakers.count ? .cloud : .deviceAndCloud
}

/// The user is in the rollout but this device could not use the on-device preview for the meeting (language, system,
/// model not installed): the reason goes to telemetry (`onDeviceLiveUnavailable`), whatever the server offers instead
/// (cloud, or the local engine when it offers no cloud stream). Nil when it was used or not wanted. Pure function.
public func onDeviceLiveUnavailable(inRollout: Bool, support: OnDeviceLiveSupport) -> OnDeviceLiveSupport? {
    guard inRollout else {
        return nil
    }
    if case .ready = support {
        return nil
    }
    return support
}

/// The language model to install in the background so the next meeting can use the on-device preview: only for a user
/// in the rollout whose device supports the language but lacks its model. Pure function.
public func onDeviceModelToInstall(inRollout: Bool, support: OnDeviceLiveSupport) -> AppleSpeechChoice? {
    guard inRollout, case .modelNotInstalled(let choice) = support else {
        return nil
    }
    return choice
}

/// The user is in the on-device live preview rollout (`/v1/me` → `liveOnDevice`); an older server without the field
/// says no. Pure function.
public func hostedLiveOnDevice(entitlements: HostedEntitlements) -> Bool {
    entitlements.liveOnDevice ?? false
}

// MARK: Live text during a recording

/// A recording's live text as the record screen and diagnostics show it: each track's route (cloud tracks move to the
/// local engine on fallback) and the tracks whose live text stopped, with the reason shown in the error line. One value
/// replaces the separate route and "written on this device" flags, which drifted apart.
public struct LiveTextState: Sendable, Equatable {
    public let routes: HostedLiveRoutes
    public let liveSpeakers: Set<Speaker>
    /// Tracks whose live text stopped (`.streamFailed`) and has not come back, with the stop's message.
    public let stopped: [Speaker: String]

    public init(routes: HostedLiveRoutes, liveSpeakers: Set<Speaker>, stopped: [Speaker: String]) {
        self.routes = routes
        self.liveSpeakers = liveSpeakers
        self.stopped = stopped
    }
}

/// What changes a recording's live text.
public enum LiveTextEvent: Sendable, Equatable {
    /// The cloud stream stopped and its tracks moved to the local engine (`.liveEngineFellBack`).
    case cloudFellBack
    /// A track's live text stopped (`.streamFailed`).
    case streamFailed(speaker: Speaker, message: String)
    /// A stopped track's live text is written again (`.streamRecovered`).
    case streamRecovered(speaker: Speaker)
}

/// The live text after `event`. Pure function.
public func liveTextStep(state: LiveTextState, event: LiveTextEvent) -> LiveTextState {
    switch event {
    case .cloudFellBack:
        return LiveTextState(routes: routesAfterCloudFallback(routes: state.routes), liveSpeakers: state.liveSpeakers, stopped: state.stopped)
    case .streamFailed(let speaker, let message):
        return LiveTextState(
            routes: state.routes, liveSpeakers: state.liveSpeakers,
            stopped: state.stopped.merging([speaker: message]) { (_: String, new: String) -> String in new }
        )
    case .streamRecovered(let speaker):
        return LiveTextState(routes: state.routes, liveSpeakers: state.liveSpeakers, stopped: state.stopped.filter { $0.key != speaker })
    }
}

/// Some live track is written on this device by the on-device preview right now (its live text has not stopped): the
/// empty live screen says so. Pure function.
public func liveTextOnDevice(state: LiveTextState) -> Bool {
    !onDeviceSpeakers(routes: state.routes, liveSpeakers: state.liveSpeakers.subtracting(state.stopped.keys)).isEmpty
}

/// The track's live text is on the on-device preview route (whether or not it stopped). Pure function.
public func liveTextIsOnDevice(state: LiveTextState, speaker: Speaker) -> Bool {
    if case .onDevice = trackRoute(routes: state.routes, speaker: speaker) {
        return true
    }
    return false
}
