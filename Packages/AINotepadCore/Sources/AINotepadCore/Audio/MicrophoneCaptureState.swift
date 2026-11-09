import Foundation

// The microphone capture lifecycle as one explicit state machine (Mac and iPhone). `MicrophoneCapture` is the thin
// adapter: it turns system notifications, its watchdog and the results of its own async work into
// `MicrophoneCaptureEvent`s, feeds them to `nextMicrophoneState`, and executes the returned effects. Every piece of
// async work (start, rebuild, route check, session resume, interruption probe) carries the generation it was started
// with; its result is a no-op once the state has moved on to a newer generation, so a stale completion can never
// overwrite a newer decision. The recording itself never ends here: only `stopRequested` (and a failed start) stops it.
//
//     idle ──startRequested──▶ starting ──startSucceeded──▶ running ◀──────────────────────────┐
//       ▲                         │startFailed                │ route/engine change             │ keep
//       └──────── stopRequested (any state) ──────────────────┤                                │
//                                                             ▼                                │
//                     ┌──────────── rebuild ◀──────────── checking ──── checkFinished ─────────┘
//                     ▼                                       ▲ (queued checks run next)
//   waitingRetry ◀─failed── rebuilding ──succeeded────────────┘ or running
//        └──tick (5 s) / app active──▶ rebuilding
//   running/checking/rebuilding/waitingRetry/interrupted/resuming ──interruptionBegan──▶ interrupted
//   interrupted ──ended / probe / tick (call 10 s, system 10→60 s) / app active──▶ resuming ──resumed──▶ rebuilding
//                                                            └──failed──▶ interrupted (call or system)
//   starting / checking / rebuilding / waitingRetry: route and engine changes queue and are checked once afterwards

/// Retry interval after a rebuild failed (the recording keeps running with silence in between).
public let microphoneRetryIntervalSec: Double = 5
/// Retry interval while a call holds the microphone (and the first retry of any interruption): call apps (and VoIP
/// apps) do not always post the end of the interruption; the attempt is rejected harmlessly while the call lasts.
public let microphoneInterruptionRetryIntervalSec: Double = 10
/// Longest wait between retries of a system interruption (see `microphoneInterruptionRetryDelaySec`).
public let microphoneInterruptionMaxRetryDelaySec: Double = 60
/// No audio for this long while running means the engine stalled (a buffer arrives about every 85 ms).
public let microphoneStallThresholdSec: Double = 3

/// Why the microphone is interrupted.
public enum MicrophoneInterruptionCause: Sendable, Equatable {
    /// The system interrupted the audio session (phone call, alarm, Siri).
    case system
    /// A call on this iPhone holds the microphone (`insufficientPriority`); shown as `.heldByCall`.
    case call
}

/// Why an attempt to reopen the session or rebuild the engine failed.
public enum MicrophoneFailureCause: Sendable, Equatable {
    /// A call on this iPhone holds the microphone.
    case callHoldsMicrophone
    /// Anything else (device not ready, engine did not start, session error).
    case other
}

/// Checks waiting to run against the live capture: a route or device change (merged with `mergedRouteChange`) and/or
/// an engine configuration change (the engine's format may no longer match the hardware).
public struct MicrophoneChecks: Sendable, Equatable {
    public let route: AudioRouteChange?
    public let engineConfiguration: Bool

    public init(route: AudioRouteChange?, engineConfiguration: Bool) {
        self.route = route
        self.engineConfiguration = engineConfiguration
    }

    public static let none: MicrophoneChecks = MicrophoneChecks(route: nil, engineConfiguration: false)

    public var isEmpty: Bool {
        route == nil && !engineConfiguration
    }
}

/// The adapter's verdict after checking a route or engine change.
public enum MicrophoneCheckResult: Sendable, Equatable {
    /// The engine keeps running; the input in use is reported when known.
    case keep(ActiveAudioInput?)
    /// The engine must be rebuilt (another input, a changed session or a stale format).
    case rebuild(MicrophoneRecoveryReason)
}

/// Where the capture is in its lifecycle.
public enum MicrophoneCapturePhase: Sendable, Equatable {
    /// Not capturing (never started, stopped, or the start failed).
    case idle
    /// `start()` is waiting for permission, the session or the first engine. Route and engine configuration changes
    /// (e.g. the first engine's format moving under it) wait in `pending` and are checked right after the start.
    case starting(pending: MicrophoneChecks)
    /// Audio is flowing.
    case running
    /// Audio is flowing while the adapter checks `inFlight` (route settle, session read, format check). Changes that
    /// arrive meanwhile wait in `pending`; a new input choice replaces the check in flight.
    case checking(inFlight: MicrophoneChecks, pending: MicrophoneChecks)
    /// A fresh engine is being built; changes that arrive meanwhile wait in `pending`.
    case rebuilding(reason: MicrophoneRecoveryReason, pending: MicrophoneChecks)
    /// The last rebuild failed; the watchdog retries every `microphoneRetryIntervalSec`.
    case waitingRetry(reason: MicrophoneRecoveryReason, lastAttemptAt: Double, pending: MicrophoneChecks)
    /// The session is interrupted; the recording pauses. Retried after `microphoneInterruptionRetryDelaySec`
    /// (`failedAttempts` reopen attempts of this interruption failed so far). Route and engine changes are ignored: the
    /// rebuild after the interruption reads the new route anyway.
    case interrupted(cause: MicrophoneInterruptionCause, lastAttemptAt: Double, failedAttempts: Int)
    /// The session is being reopened after an interruption; the recording stays paused until the engine is rebuilt.
    case resuming(cause: MicrophoneInterruptionCause, failedAttempts: Int)
}

/// The lifecycle phase and the generation of the newest async work. Work started with an older generation is stale.
public struct MicrophoneCaptureState: Sendable, Equatable {
    public let phase: MicrophoneCapturePhase
    public let generation: Int

    public init(phase: MicrophoneCapturePhase, generation: Int) {
        self.phase = phase
        self.generation = generation
    }
}

/// What the engine's watchdog saw on one tick.
public struct MicrophoneHealthSample: Sendable, Equatable {
    public let silentForSec: Double
    public let engineRunning: Bool

    public init(silentForSec: Double, engineRunning: Bool) {
        self.silentForSec = silentForSec
        self.engineRunning = engineRunning
    }
}

/// Something that happened to the capture: a request, a system notification, a tick, or the result of async work
/// (carrying the generation it was started with).
public enum MicrophoneCaptureEvent: Sendable, Equatable {
    case startRequested
    case startSucceeded(generation: Int, input: ActiveAudioInput?)
    case startFailed(generation: Int)
    case stopRequested
    /// The route, the device list or the user's input choice changed.
    case routeChanged(AudioRouteChange)
    /// The engine posted a configuration change.
    case engineConfigurationChanged
    case checkFinished(generation: Int, result: MicrophoneCheckResult)
    case rebuildSucceeded(generation: Int, input: ActiveAudioInput?)
    case rebuildFailed(generation: Int, cause: MicrophoneFailureCause)
    /// iOS: the audio session was interrupted.
    case interruptionBegan
    /// iOS: the interruption ended.
    case interruptionEnded
    /// iOS: the one-off probe shortly after an interruption began (finds out whether a call holds the microphone).
    case probeFired(generation: Int)
    case sessionResumed(generation: Int)
    case sessionResumeFailed(generation: Int, cause: MicrophoneFailureCause)
    /// iOS: the app came to the foreground.
    case appBecameActive
    /// iOS: the system's media services were reset.
    case mediaServicesReset
    /// The watchdog's one-second tick.
    case tick(MicrophoneHealthSample)
}

/// Work the adapter executes after a transition. `publishInput` and `markAudioFlowing` run before the new status is
/// published (the recorder shows an input notice instead of "reconnected" when both change at once); the rest after.
public enum MicrophoneCaptureEffect: Sendable, Equatable {
    /// Report the input in use (`onInputChange`, only when it changed).
    case publishInput(ActiveAudioInput)
    /// Reset the stall watchdog's clock: a fresh engine is running.
    case markAudioFlowing
    /// Start watching notifications and the watchdog (after the first engine runs).
    case beginMonitoring
    /// Tear everything down: observers, watchdog, probe, engine, stream, session.
    case stopCapture
    /// iOS: after `interruptionProbeDelaySec` send `probeFired(generation)`.
    case scheduleProbe(generation: Int)
    /// Check the change and send `checkFinished(generation, …)`.
    case check(generation: Int, checks: MicrophoneChecks)
    /// Build a fresh engine (with retries) and send `rebuildSucceeded` / `rebuildFailed`.
    case rebuild(generation: Int, reason: MicrophoneRecoveryReason)
    /// iOS: reopen the audio session and send `sessionResumed` / `sessionResumeFailed`.
    case resumeSession(generation: Int)
}

/// The next state and the effects to execute.
public struct MicrophoneTransition: Sendable, Equatable {
    public let state: MicrophoneCaptureState
    public let effects: [MicrophoneCaptureEffect]

    public init(state: MicrophoneCaptureState, effects: [MicrophoneCaptureEffect]) {
        self.state = state
        self.effects = effects
    }
}

/// The capture's next state for `event` at monotonic time `now` (seconds). Rules:
/// - Results of async work are applied only when their generation is the current one (stale ones change nothing).
/// - Starting new async work, an interruption and a stop advance the generation, so the work they replace is stale.
/// - An interruption wins over every rebuild and check in flight; a media services reset while interrupted waits for
///   the end of the interruption (whose rebuild uses a fresh engine) instead of un-pausing the recording.
/// - Changes during a start, check or rebuild are queued and checked once afterwards; a new input choice replaces a
///   check in flight (the older choice's result is stale).
/// - Nothing but `stopRequested` and a failed start ends the capture.
/// Pure function.
public func nextMicrophoneState(state: MicrophoneCaptureState, event: MicrophoneCaptureEvent, now: Double) -> MicrophoneTransition {
    let unchanged: MicrophoneTransition = MicrophoneTransition(state: state, effects: [])
    let next: Int = state.generation + 1
    switch (state.phase, event) {
    case (_, .stopRequested):
        return MicrophoneTransition(state: MicrophoneCaptureState(phase: .idle, generation: next), effects: [.stopCapture])

    case (.idle, .startRequested):
        return MicrophoneTransition(state: MicrophoneCaptureState(phase: .starting(pending: .none), generation: next), effects: [])
    case (.starting(let pending), .startSucceeded(let generation, let input)) where generation == state.generation:
        return settled(input: input, pending: pending, generation: generation, extraEffects: [.markAudioFlowing, .beginMonitoring])
    case (.starting, .startFailed(let generation)) where generation == state.generation:
        return MicrophoneTransition(state: MicrophoneCaptureState(phase: .idle, generation: generation), effects: [.stopCapture])

    // Interruptions win over everything that is in flight.
    case (.running, .interruptionBegan), (.checking, .interruptionBegan), (.rebuilding, .interruptionBegan),
         (.waitingRetry, .interruptionBegan), (.interrupted, .interruptionBegan), (.resuming, .interruptionBegan):
        return MicrophoneTransition(
            state: MicrophoneCaptureState(phase: .interrupted(cause: .system, lastAttemptAt: now, failedAttempts: 0), generation: next),
            effects: [.scheduleProbe(generation: next)]
        )
    case (.interrupted(let cause, _, let failedAttempts), .interruptionEnded), (.resuming(let cause, let failedAttempts), .interruptionEnded),
         (.interrupted(let cause, _, let failedAttempts), .appBecameActive):
        return resume(cause: cause, failedAttempts: failedAttempts, generation: next)
    case (.interrupted(.system, _, let failedAttempts), .probeFired(let generation)) where generation == state.generation:
        return resume(cause: .system, failedAttempts: failedAttempts, generation: next)
    case (.interrupted(let cause, let lastAttemptAt, let failedAttempts), .tick)
        where now - lastAttemptAt >= microphoneInterruptionRetryDelaySec(cause: cause, failedAttempts: failedAttempts):
        return resume(cause: cause, failedAttempts: failedAttempts, generation: next)
    case (.resuming, .sessionResumed(let generation)) where generation == state.generation:
        return rebuild(reason: .interruptionEnded, pending: .none, generation: next)
    case (.resuming(let cause, let failedAttempts), .sessionResumeFailed(let generation, let failure)) where generation == state.generation:
        let newCause: MicrophoneInterruptionCause = failure == .callHoldsMicrophone ? .call : cause
        return MicrophoneTransition(
            state: MicrophoneCaptureState(
                phase: .interrupted(cause: newCause, lastAttemptAt: now, failedAttempts: failedAttempts + 1), generation: generation
            ),
            effects: []
        )

    // Changes while audio flows are checked; during a check or rebuild they wait.
    case (.running, .routeChanged(let change)):
        return check(checks: MicrophoneChecks(route: change, engineConfiguration: false), pending: .none, generation: next)
    case (.running, .engineConfigurationChanged):
        return check(checks: MicrophoneChecks(route: nil, engineConfiguration: true), pending: .none, generation: next)
    case (.starting(let pending), .routeChanged(let change)):
        return MicrophoneTransition(state: MicrophoneCaptureState(phase: .starting(pending: queued(pending: pending, route: change)), generation: state.generation), effects: [])
    case (.starting(let pending), .engineConfigurationChanged):
        return MicrophoneTransition(state: MicrophoneCaptureState(phase: .starting(pending: queuedEngineCheck(pending: pending)), generation: state.generation), effects: [])
    case (.checking(let inFlight, let pending), .routeChanged(.choiceChanged)):
        let replacing: MicrophoneChecks = MicrophoneChecks(
            route: .choiceChanged, engineConfiguration: inFlight.engineConfiguration || pending.engineConfiguration
        )
        return check(checks: replacing, pending: .none, generation: next)
    case (.checking(let inFlight, let pending), .routeChanged(let change)):
        return MicrophoneTransition(
            state: MicrophoneCaptureState(phase: .checking(inFlight: inFlight, pending: queued(pending: pending, route: change)), generation: state.generation),
            effects: []
        )
    case (.checking(let inFlight, let pending), .engineConfigurationChanged):
        return MicrophoneTransition(
            state: MicrophoneCaptureState(phase: .checking(inFlight: inFlight, pending: queuedEngineCheck(pending: pending)), generation: state.generation),
            effects: []
        )
    case (.rebuilding(let reason, let pending), .routeChanged(let change)):
        return MicrophoneTransition(
            state: MicrophoneCaptureState(phase: .rebuilding(reason: reason, pending: queued(pending: pending, route: change)), generation: state.generation),
            effects: []
        )
    case (.rebuilding(let reason, let pending), .engineConfigurationChanged):
        return MicrophoneTransition(
            state: MicrophoneCaptureState(phase: .rebuilding(reason: reason, pending: queuedEngineCheck(pending: pending)), generation: state.generation),
            effects: []
        )
    case (.waitingRetry(let reason, let lastAttemptAt, let pending), .routeChanged(let change)):
        return MicrophoneTransition(
            state: MicrophoneCaptureState(
                phase: .waitingRetry(reason: reason, lastAttemptAt: lastAttemptAt, pending: queued(pending: pending, route: change)),
                generation: state.generation
            ),
            effects: []
        )
    case (.waitingRetry(let reason, let lastAttemptAt, let pending), .engineConfigurationChanged):
        return MicrophoneTransition(
            state: MicrophoneCaptureState(
                phase: .waitingRetry(reason: reason, lastAttemptAt: lastAttemptAt, pending: queuedEngineCheck(pending: pending)),
                generation: state.generation
            ),
            effects: []
        )

    case (.checking(_, let pending), .checkFinished(let generation, .keep(let input))) where generation == state.generation:
        return settled(input: input, pending: pending, generation: generation, extraEffects: [])
    case (.checking(_, let pending), .checkFinished(let generation, .rebuild(let reason))) where generation == state.generation:
        return rebuild(reason: reason, pending: pending, generation: next)
    case (.rebuilding(_, let pending), .rebuildSucceeded(let generation, let input)) where generation == state.generation:
        return settled(input: input, pending: pending, generation: generation, extraEffects: [.markAudioFlowing])
    case (.rebuilding(let reason, let pending), .rebuildFailed(let generation, let failure)) where generation == state.generation:
        let phase: MicrophoneCapturePhase = failure == .callHoldsMicrophone
            ? .interrupted(cause: .call, lastAttemptAt: now, failedAttempts: 0)
            : .waitingRetry(reason: reason, lastAttemptAt: now, pending: pending)
        return MicrophoneTransition(state: MicrophoneCaptureState(phase: phase, generation: generation), effects: [])
    case (.waitingRetry(let reason, let lastAttemptAt, let pending), .tick) where now - lastAttemptAt >= microphoneRetryIntervalSec:
        return rebuild(reason: reason, pending: pending, generation: next)
    case (.waitingRetry(let reason, _, let pending), .appBecameActive):
        return rebuild(reason: reason, pending: pending, generation: next)

    // A stalled engine and a media services reset replace whatever is in flight with a rebuild.
    case (.running, .tick(let sample)), (.checking, .tick(let sample)):
        guard isMicrophoneStalled(status: .running, engineRunning: sample.engineRunning, silentForSec: sample.silentForSec, thresholdSec: microphoneStallThresholdSec) else {
            return unchanged
        }
        return rebuild(reason: .stalled, pending: abandonedChecks(phase: state.phase), generation: next)
    case (.running, .mediaServicesReset), (.checking, .mediaServicesReset), (.rebuilding, .mediaServicesReset),
         (.waitingRetry, .mediaServicesReset):
        return rebuild(reason: .mediaServicesReset, pending: abandonedChecks(phase: state.phase), generation: next)

    default:
        return unchanged
    }
}

/// The status the recorder shows for a phase. Not capturing reads as `.running` (the next recording starts clean). Pure
/// function.
public func microphoneStatus(phase: MicrophoneCapturePhase) -> MicrophoneStatus {
    switch phase {
    case .idle, .starting, .running, .checking:
        .running
    case .rebuilding(let reason, _), .waitingRetry(let reason, _, _):
        .reconnecting(reason: reason)
    case .interrupted(.system, _, _), .resuming(.system, _):
        .interrupted
    case .interrupted(.call, _, _), .resuming(.call, _):
        .heldByCall
    }
}

/// How long an interruption waits before the next reopen attempt. A call is retried every
/// `microphoneInterruptionRetryIntervalSec` (it ends soon and the user expects the recording back at once). A system
/// interruption whose end never arrived backs off (10, 20, 40, then every 60 s): each attempt reopens our session while
/// another app (a VoIP or recording app outside CallKit) may still be using the audio route. Pure function.
public func microphoneInterruptionRetryDelaySec(cause: MicrophoneInterruptionCause, failedAttempts: Int) -> Double {
    switch cause {
    case .call:
        return microphoneInterruptionRetryIntervalSec
    case .system:
        let doublings: Int = min(max(0, failedAttempts - 1), 3)
        return min(microphoneInterruptionRetryIntervalSec * pow(2, Double(doublings)), microphoneInterruptionMaxRetryDelaySec)
    }
}

/// Whether the capture is between a successful start and a stop (its stream is open). Pure function.
public func isMicrophoneCaptureActive(phase: MicrophoneCapturePhase) -> Bool {
    switch phase {
    case .idle, .starting:
        false
    case .running, .checking, .rebuilding, .waitingRetry, .interrupted, .resuming:
        true
    }
}

private func inputEffects(input: ActiveAudioInput?) -> [MicrophoneCaptureEffect] {
    input.map { [.publishInput($0)] } ?? []
}

private func resume(cause: MicrophoneInterruptionCause, failedAttempts: Int, generation: Int) -> MicrophoneTransition {
    MicrophoneTransition(
        state: MicrophoneCaptureState(phase: .resuming(cause: cause, failedAttempts: failedAttempts), generation: generation),
        effects: [.resumeSession(generation: generation)]
    )
}

private func rebuild(reason: MicrophoneRecoveryReason, pending: MicrophoneChecks, generation: Int) -> MicrophoneTransition {
    MicrophoneTransition(
        state: MicrophoneCaptureState(phase: .rebuilding(reason: reason, pending: pending), generation: generation),
        effects: [.rebuild(generation: generation, reason: reason)]
    )
}

private func check(checks: MicrophoneChecks, pending: MicrophoneChecks, generation: Int) -> MicrophoneTransition {
    MicrophoneTransition(
        state: MicrophoneCaptureState(phase: .checking(inFlight: checks, pending: pending), generation: generation),
        effects: [.check(generation: generation, checks: checks)]
    )
}

/// Audio flows again after a check or a rebuild (`generation` is the finished work's): queued changes are checked next
/// as new work, otherwise the capture runs.
private func settled(input: ActiveAudioInput?, pending: MicrophoneChecks, generation: Int, extraEffects: [MicrophoneCaptureEffect]) -> MicrophoneTransition {
    let effects: [MicrophoneCaptureEffect] = inputEffects(input: input) + extraEffects
    guard !pending.isEmpty else {
        return MicrophoneTransition(state: MicrophoneCaptureState(phase: .running, generation: generation), effects: effects)
    }
    let next: MicrophoneTransition = check(checks: pending, pending: .none, generation: generation + 1)
    return MicrophoneTransition(state: next.state, effects: effects + next.effects)
}

private func queued(pending: MicrophoneChecks, route: AudioRouteChange) -> MicrophoneChecks {
    MicrophoneChecks(route: mergedRouteChange(pending: pending.route, new: route), engineConfiguration: pending.engineConfiguration)
}

private func queuedEngineCheck(pending: MicrophoneChecks) -> MicrophoneChecks {
    MicrophoneChecks(route: pending.route, engineConfiguration: true)
}

/// Checks that were in flight or waiting when a rebuild replaced them: they still run after it.
private func abandonedChecks(phase: MicrophoneCapturePhase) -> MicrophoneChecks {
    switch phase {
    case .checking(let inFlight, let pending):
        MicrophoneChecks(
            route: pending.route.map { mergedRouteChange(pending: inFlight.route, new: $0) } ?? inFlight.route,
            engineConfiguration: inFlight.engineConfiguration || pending.engineConfiguration
        )
    case .rebuilding(_, let pending), .waitingRetry(_, _, let pending):
        pending
    case .idle, .starting, .running, .interrupted, .resuming:
        .none
    }
}
