import AINotepadCore
import Foundation
import Testing

/// The microphone capture lifecycle (`nextMicrophoneState`): every (phase, event) pair is either a row of the table
/// below or leaves the state untouched with no effects. Results of async work are tested both current (generation 7)
/// and stale (generation 6). The scenario tests replay the races from the 2026-11-09 audit (A1, A2).
@Suite struct MicrophoneCaptureStateTests {
    private static let now: Double = 100
    private static let generation: Int = 7
    private static let builtIn: ActiveAudioInput = ActiveAudioInput(
        device: AudioInputDevice(id: "built-in", name: "iPhone Microphone", kind: .builtIn), unavailableChoice: nil
    )
    private static let wired: ActiveAudioInput = ActiveAudioInput(
        device: AudioInputDevice(id: "headset", name: "Headset Microphone", kind: .wired), unavailableChoice: nil
    )

    private static func route(_ change: AudioRouteChange) -> MicrophoneChecks {
        MicrophoneChecks(route: change, engineConfiguration: false)
    }

    private static let engineCheck: MicrophoneChecks = MicrophoneChecks(route: nil, engineConfiguration: true)

    private static let phases: [(String, MicrophoneCapturePhase)] = [
        ("idle", .idle),
        ("starting", .starting),
        ("running", .running),
        ("checking", .checking(inFlight: route(.deviceAdded), pending: .none)),
        ("rebuilding", .rebuilding(reason: .configurationChange, pending: .none)),
        ("waitingRetryDue", .waitingRetry(reason: .configurationChange, lastAttemptAt: 90, pending: .none)),
        ("waitingRetryRecent", .waitingRetry(reason: .configurationChange, lastAttemptAt: 98, pending: .none)),
        ("interruptedSystemDue", .interrupted(cause: .system, lastAttemptAt: 85, failedAttempts: 1)),
        ("interruptedSystemRecent", .interrupted(cause: .system, lastAttemptAt: 99, failedAttempts: 1)),
        // Three failures: the next retry waits 40 s (15 s have passed).
        ("interruptedSystemBackedOff", .interrupted(cause: .system, lastAttemptAt: 85, failedAttempts: 3)),
        ("interruptedCallDue", .interrupted(cause: .call, lastAttemptAt: 85, failedAttempts: 3)),
        ("interruptedCallRecent", .interrupted(cause: .call, lastAttemptAt: 99, failedAttempts: 3)),
        ("resumingSystem", .resuming(cause: .system, failedAttempts: 1)),
        ("resumingCall", .resuming(cause: .call, failedAttempts: 3)),
    ]

    private static let healthy: MicrophoneHealthSample = MicrophoneHealthSample(silentForSec: 0.1, engineRunning: true)
    private static let stalled: MicrophoneHealthSample = MicrophoneHealthSample(silentForSec: 4, engineRunning: true)

    private static func events(generation: Int) -> [(String, MicrophoneCaptureEvent)] {
        [
            ("startSucceeded", .startSucceeded(generation: generation, input: builtIn)),
            ("startFailed", .startFailed(generation: generation)),
            ("checkKeep", .checkFinished(generation: generation, result: .keep(wired))),
            ("checkRebuild", .checkFinished(generation: generation, result: .rebuild(.inputSelected))),
            ("rebuildSucceeded", .rebuildSucceeded(generation: generation, input: wired)),
            ("rebuildFailed", .rebuildFailed(generation: generation, cause: .other)),
            ("rebuildFailedCall", .rebuildFailed(generation: generation, cause: .callHoldsMicrophone)),
            ("probe", .probeFired(generation: generation)),
            ("resumed", .sessionResumed(generation: generation)),
            ("resumeFailed", .sessionResumeFailed(generation: generation, cause: .other)),
            ("resumeFailedCall", .sessionResumeFailed(generation: generation, cause: .callHoldsMicrophone)),
        ]
    }

    private static let requestsAndNotifications: [(String, MicrophoneCaptureEvent)] = [
        ("start", .startRequested),
        ("stop", .stopRequested),
        ("deviceRemoved", .routeChanged(.deviceRemoved)),
        ("choice", .routeChanged(.choiceChanged)),
        ("other", .routeChanged(.other)),
        ("engine", .engineConfigurationChanged),
        ("began", .interruptionBegan),
        ("ended", .interruptionEnded),
        ("active", .appBecameActive),
        ("mediaReset", .mediaServicesReset),
        ("tickHealthy", .tick(healthy)),
        ("tickStalled", .tick(stalled)),
    ]

    private static func expected(_ phase: MicrophoneCapturePhase, _ generation: Int, _ effects: [MicrophoneCaptureEffect]) -> MicrophoneTransition {
        MicrophoneTransition(state: MicrophoneCaptureState(phase: phase, generation: generation), effects: effects)
    }

    /// Every transition that changes something. Generation 7 is current; 8 means new work started.
    private static func table() -> [String: MicrophoneTransition] {
        let same: Int = generation
        let new: Int = generation + 1
        let interrupted: MicrophoneTransition = expected(
            .interrupted(cause: .system, lastAttemptAt: now, failedAttempts: 0), new, [.scheduleProbe(generation: new)]
        )
        let resumeSystem: MicrophoneTransition = expected(.resuming(cause: .system, failedAttempts: 1), new, [.resumeSession(generation: new)])
        let resumeSystemBackedOff: MicrophoneTransition = expected(.resuming(cause: .system, failedAttempts: 3), new, [.resumeSession(generation: new)])
        let resumeCall: MicrophoneTransition = expected(.resuming(cause: .call, failedAttempts: 3), new, [.resumeSession(generation: new)])
        func rebuild(_ reason: MicrophoneRecoveryReason, _ pending: MicrophoneChecks) -> MicrophoneTransition {
            expected(.rebuilding(reason: reason, pending: pending), new, [.rebuild(generation: new, reason: reason)])
        }
        func check(_ checks: MicrophoneChecks) -> MicrophoneTransition {
            expected(.checking(inFlight: checks, pending: .none), new, [.check(generation: new, checks: checks)])
        }
        let checkingDeviceAdded: (MicrophoneChecks) -> MicrophoneTransition = { (pending: MicrophoneChecks) -> MicrophoneTransition in
            expected(.checking(inFlight: route(.deviceAdded), pending: pending), same, [])
        }
        let rebuildingWith: (MicrophoneChecks) -> MicrophoneTransition = { (pending: MicrophoneChecks) -> MicrophoneTransition in
            expected(.rebuilding(reason: .configurationChange, pending: pending), same, [])
        }
        var rows: [String: MicrophoneTransition] = [
            "idle/start": expected(.starting, new, []),
            "starting/startSucceeded": expected(.running, same, [.publishInput(builtIn), .markAudioFlowing, .beginMonitoring]),
            "starting/startFailed": expected(.idle, same, [.stopCapture]),

            "running/deviceRemoved": check(route(.deviceRemoved)),
            "running/choice": check(route(.choiceChanged)),
            "running/other": check(route(.other)),
            "running/engine": check(engineCheck),
            "running/began": interrupted,
            "running/mediaReset": rebuild(.mediaServicesReset, .none),
            "running/tickStalled": rebuild(.stalled, .none),

            "checking/deviceRemoved": checkingDeviceAdded(route(.deviceRemoved)),
            // A2: a newer choice replaces the check in flight (its result becomes stale).
            "checking/choice": check(route(.choiceChanged)),
            "checking/other": checkingDeviceAdded(route(.other)),
            "checking/engine": checkingDeviceAdded(engineCheck),
            "checking/checkKeep": expected(.running, same, [.publishInput(wired)]),
            "checking/checkRebuild": rebuild(.inputSelected, .none),
            "checking/began": interrupted,
            "checking/mediaReset": rebuild(.mediaServicesReset, route(.deviceAdded)),
            "checking/tickStalled": rebuild(.stalled, route(.deviceAdded)),

            "rebuilding/deviceRemoved": rebuildingWith(route(.deviceRemoved)),
            "rebuilding/choice": rebuildingWith(route(.choiceChanged)),
            "rebuilding/other": rebuildingWith(route(.other)),
            "rebuilding/engine": rebuildingWith(engineCheck),
            "rebuilding/rebuildSucceeded": expected(.running, same, [.publishInput(wired), .markAudioFlowing]),
            "rebuilding/rebuildFailed": expected(.waitingRetry(reason: .configurationChange, lastAttemptAt: now, pending: .none), same, []),
            "rebuilding/rebuildFailedCall": expected(.interrupted(cause: .call, lastAttemptAt: now, failedAttempts: 0), same, []),
            // A1 scenario 1: an interruption during a rebuild wins.
            "rebuilding/began": interrupted,
            "rebuilding/mediaReset": rebuild(.mediaServicesReset, .none),
        ]
        for (name, lastAttemptAt) in [("waitingRetryDue", 90.0), ("waitingRetryRecent", 98.0)] {
            let waiting: (MicrophoneChecks) -> MicrophoneTransition = { (pending: MicrophoneChecks) -> MicrophoneTransition in
                expected(.waitingRetry(reason: .configurationChange, lastAttemptAt: lastAttemptAt, pending: pending), same, [])
            }
            rows["\(name)/deviceRemoved"] = waiting(route(.deviceRemoved))
            rows["\(name)/choice"] = waiting(route(.choiceChanged))
            rows["\(name)/other"] = waiting(route(.other))
            rows["\(name)/engine"] = waiting(engineCheck)
            rows["\(name)/active"] = rebuild(.configurationChange, .none)
            rows["\(name)/began"] = interrupted
            rows["\(name)/mediaReset"] = rebuild(.mediaServicesReset, .none)
        }
        rows["waitingRetryDue/tickHealthy"] = rebuild(.configurationChange, .none)
        rows["waitingRetryDue/tickStalled"] = rebuild(.configurationChange, .none)

        for name in ["interruptedSystemDue", "interruptedSystemRecent"] {
            rows["\(name)/began"] = interrupted
            rows["\(name)/ended"] = resumeSystem
            rows["\(name)/active"] = resumeSystem
            rows["\(name)/probe"] = resumeSystem
        }
        // A1 scenario 2: a system interruption whose end never arrives is retried, like a call.
        rows["interruptedSystemDue/tickHealthy"] = resumeSystem
        rows["interruptedSystemDue/tickStalled"] = resumeSystem
        rows["interruptedSystemBackedOff/began"] = interrupted
        rows["interruptedSystemBackedOff/ended"] = resumeSystemBackedOff
        rows["interruptedSystemBackedOff/active"] = resumeSystemBackedOff
        rows["interruptedSystemBackedOff/probe"] = resumeSystemBackedOff
        for name in ["interruptedCallDue", "interruptedCallRecent"] {
            rows["\(name)/began"] = interrupted
            rows["\(name)/ended"] = resumeCall
            rows["\(name)/active"] = resumeCall
        }
        rows["interruptedCallDue/tickHealthy"] = resumeCall
        rows["interruptedCallDue/tickStalled"] = resumeCall

        for (name, cause, failed, resume) in [
            ("resumingSystem", MicrophoneInterruptionCause.system, 1, resumeSystem), ("resumingCall", .call, 3, resumeCall),
        ] {
            rows["\(name)/began"] = interrupted
            rows["\(name)/ended"] = resume
            rows["\(name)/resumed"] = rebuild(.interruptionEnded, .none)
            rows["\(name)/resumeFailed"] = expected(.interrupted(cause: cause, lastAttemptAt: now, failedAttempts: failed + 1), same, [])
            rows["\(name)/resumeFailedCall"] = expected(.interrupted(cause: .call, lastAttemptAt: now, failedAttempts: failed + 1), same, [])
        }
        for (name, _) in phases {
            rows["\(name)/stop"] = expected(.idle, new, [.stopCapture])
        }
        return rows
    }

    @Test func everyTransitionMatchesTheTable() {
        let rows: [String: MicrophoneTransition] = Self.table()
        var used: Set<String> = []
        for (phaseName, phase) in Self.phases {
            let state: MicrophoneCaptureState = MicrophoneCaptureState(phase: phase, generation: Self.generation)
            for (eventName, event) in Self.requestsAndNotifications + Self.events(generation: Self.generation) {
                let key: String = "\(phaseName)/\(eventName)"
                let result: MicrophoneTransition = nextMicrophoneState(state: state, event: event, now: Self.now)
                let want: MicrophoneTransition = rows[key] ?? MicrophoneTransition(state: state, effects: [])
                #expect(result == want, "\(key)")
                if rows[key] != nil {
                    used.insert(key)
                }
            }
        }
        // Every row names a real pair (no typo hides a missing transition).
        #expect(used == Set(rows.keys))
    }

    // Async work started for an older generation never changes anything, whatever the phase.
    @Test func staleResultsAreIgnored() {
        for (phaseName, phase) in Self.phases {
            let state: MicrophoneCaptureState = MicrophoneCaptureState(phase: phase, generation: Self.generation)
            for (eventName, event) in Self.events(generation: Self.generation - 1) {
                let result: MicrophoneTransition = nextMicrophoneState(state: state, event: event, now: Self.now)
                #expect(result == MicrophoneTransition(state: state, effects: []), "\(phaseName)/\(eventName) stale")
            }
        }
    }

    // No route change, interruption or failure ever ends the recording: only a stop (or a failed start) tears the
    // capture down, and an active capture stays active through every other event.
    @Test func onlyStopEndsTheRecording() {
        for (phaseName, phase) in Self.phases {
            let state: MicrophoneCaptureState = MicrophoneCaptureState(phase: phase, generation: Self.generation)
            for (eventName, event) in Self.requestsAndNotifications + Self.events(generation: Self.generation) where eventName != "stop" {
                let result: MicrophoneTransition = nextMicrophoneState(state: state, event: event, now: Self.now)
                if eventName != "startFailed" {
                    #expect(!result.effects.contains(.stopCapture), "\(phaseName)/\(eventName)")
                }
                if isMicrophoneCaptureActive(phase: phase) {
                    #expect(isMicrophoneCaptureActive(phase: result.state.phase), "\(phaseName)/\(eventName)")
                }
            }
        }
    }

    @Test func statusIsDerivedFromThePhase() {
        #expect(microphoneStatus(phase: .idle) == .running)
        #expect(microphoneStatus(phase: .starting) == .running)
        #expect(microphoneStatus(phase: .running) == .running)
        #expect(microphoneStatus(phase: .checking(inFlight: Self.route(.choiceChanged), pending: .none)) == .running)
        #expect(microphoneStatus(phase: .rebuilding(reason: .stalled, pending: .none)) == .reconnecting(reason: .stalled))
        #expect(microphoneStatus(phase: .waitingRetry(reason: .inputSelected, lastAttemptAt: 0, pending: .none)) == .reconnecting(reason: .inputSelected))
        #expect(microphoneStatus(phase: .interrupted(cause: .system, lastAttemptAt: 0, failedAttempts: 0)) == .interrupted)
        #expect(microphoneStatus(phase: .resuming(cause: .system, failedAttempts: 0)) == .interrupted)
        #expect(microphoneStatus(phase: .interrupted(cause: .call, lastAttemptAt: 0, failedAttempts: 0)) == .heldByCall)
        #expect(microphoneStatus(phase: .resuming(cause: .call, failedAttempts: 0)) == .heldByCall)
    }

    /// Replays events from `start`, returning every transition.
    private func replay(_ start: MicrophoneCaptureState, _ steps: [(MicrophoneCaptureEvent, Double)]) -> [MicrophoneTransition] {
        var state: MicrophoneCaptureState = start
        var transitions: [MicrophoneTransition] = []
        for (event, now) in steps {
            let transition: MicrophoneTransition = nextMicrophoneState(state: state, event: event, now: now)
            transitions.append(transition)
            state = transition.state
        }
        return transitions
    }

    // A1 scenario 1: an interruption arrives while a rebuild is in flight and the engine still starts. The rebuild's
    // success is stale: the recording stays paused instead of recording silence as if it were running.
    @Test func interruptionDuringRebuildIsNotLost() {
        let steps: [MicrophoneTransition] = replay(MicrophoneCaptureState(phase: .running, generation: 3), [
            (.routeChanged(.deviceRemoved), 10),
            (.checkFinished(generation: 4, result: .rebuild(.configurationChange)), 10.1),
            (.interruptionBegan, 10.2),
            (.rebuildSucceeded(generation: 5, input: Self.wired), 10.5),
        ])
        #expect(steps[1].effects == [.rebuild(generation: 5, reason: .configurationChange)])
        #expect(steps[3].state.phase == .interrupted(cause: .system, lastAttemptAt: 10.2, failedAttempts: 0))
        #expect(steps[3].effects.isEmpty)
        #expect(microphoneStatus(phase: steps[3].state.phase) == .interrupted)
    }

    // A1 scenario 2: the probe's reopen fails with something other than a call and the end of the interruption never
    // arrives (VoIP apps). The machine keeps retrying every 10 s instead of staying paused until the app is opened.
    @Test func interruptionWithoutEndIsRetried() {
        let steps: [MicrophoneTransition] = replay(MicrophoneCaptureState(phase: .running, generation: 1), [
            (.interruptionBegan, 0),
            (.probeFired(generation: 2), 1.5),
            (.sessionResumeFailed(generation: 3, cause: .other), 1.6),
            (.tick(Self.healthy), 11.5),
            (.tick(Self.healthy), 12),
            (.sessionResumed(generation: 4), 12.1),
            (.rebuildSucceeded(generation: 5, input: Self.builtIn), 12.5),
        ])
        #expect(steps[2].state.phase == .interrupted(cause: .system, lastAttemptAt: 1.6, failedAttempts: 1))
        #expect(steps[3].effects.isEmpty)
        #expect(steps[4].effects == [.resumeSession(generation: 4)])
        #expect(steps[5].effects == [.rebuild(generation: 5, reason: .interruptionEnded)])
        #expect(steps[6].state.phase == .running)
    }

    // A1 scenario 3: a media services reset while a call holds the microphone keeps the recording paused (the rebuild
    // after the call uses a fresh engine anyway).
    @Test func mediaServicesResetDuringACallKeepsThePause() {
        let paused: [MicrophoneCapturePhase] = [
            .interrupted(cause: .call, lastAttemptAt: 5, failedAttempts: 1), .resuming(cause: .call, failedAttempts: 1),
            .interrupted(cause: .system, lastAttemptAt: 5, failedAttempts: 0),
        ]
        for phase in paused {
            let state: MicrophoneCaptureState = MicrophoneCaptureState(phase: phase, generation: 4)
            let result: MicrophoneTransition = nextMicrophoneState(state: state, event: .mediaServicesReset, now: 6)
            #expect(result == MicrophoneTransition(state: state, effects: []))
            #expect(isMicrophoneInterrupted(status: microphoneStatus(phase: result.state.phase)))
        }
    }

    // A2: two input choices within a second. The first choice's route settle finishes last and would report "iPhone
    // microphone unavailable"; it is stale, and only the newer choice's input is published.
    @Test func olderInputChoiceNeverOverwritesANewerOne() {
        let unavailableBuiltIn: ActiveAudioInput = ActiveAudioInput(device: Self.wired.device, unavailableChoice: .builtIn)
        let steps: [MicrophoneTransition] = replay(MicrophoneCaptureState(phase: .running, generation: 1), [
            (.routeChanged(.choiceChanged), 0),
            (.routeChanged(.choiceChanged), 0.3),
            (.checkFinished(generation: 3, result: .rebuild(.inputSelected)), 0.4),
            (.checkFinished(generation: 2, result: .keep(unavailableBuiltIn)), 1),
            (.rebuildSucceeded(generation: 4, input: Self.wired), 1.2),
        ])
        #expect(steps[0].effects == [.check(generation: 2, checks: Self.route(.choiceChanged))])
        #expect(steps[1].effects == [.check(generation: 3, checks: Self.route(.choiceChanged))])
        #expect(steps[3].effects.isEmpty)
        #expect(steps[4].state.phase == .running)
        #expect(steps.flatMap(\.effects).filter { if case .publishInput = $0 { true } else { false } } == [.publishInput(Self.wired)])
    }

    // Changes during a rebuild are queued and checked once afterwards (not dropped); a stale check never runs them.
    @Test func changesDuringARebuildAreCheckedAfterIt() {
        let steps: [MicrophoneTransition] = replay(MicrophoneCaptureState(phase: .running, generation: 1), [
            (.mediaServicesReset, 0),
            (.routeChanged(.deviceAdded), 0.1),
            (.routeChanged(.other), 0.2),
            (.engineConfigurationChanged, 0.3),
            (.rebuildSucceeded(generation: 2, input: Self.builtIn), 0.5),
            (.checkFinished(generation: 3, result: .keep(nil)), 0.6),
        ])
        let queued: MicrophoneChecks = MicrophoneChecks(route: .deviceAdded, engineConfiguration: true)
        #expect(steps[4].effects == [.publishInput(Self.builtIn), .markAudioFlowing, .check(generation: 3, checks: queued)])
        #expect(steps[5] == MicrophoneTransition(state: MicrophoneCaptureState(phase: .running, generation: 3), effects: []))
    }

    // A stop while the start waits for permission or the session: the start's late success is stale, nothing runs.
    @Test func stopDuringStartWins() {
        let steps: [MicrophoneTransition] = replay(MicrophoneCaptureState(phase: .idle, generation: 0), [
            (.startRequested, 0),
            (.stopRequested, 0.5),
            (.startSucceeded(generation: 1, input: Self.builtIn), 1),
        ])
        #expect(steps[1].effects == [.stopCapture])
        #expect(steps[2] == MicrophoneTransition(state: MicrophoneCaptureState(phase: .idle, generation: 2), effects: []))
    }

    // A call starts while the engine is being rebuilt: shown as held by the call and retried until it ends.
    @Test func callDuringRebuildPausesAndRetries() {
        let steps: [MicrophoneTransition] = replay(MicrophoneCaptureState(phase: .rebuilding(reason: .stalled, pending: .none), generation: 6), [
            (.rebuildFailed(generation: 6, cause: .callHoldsMicrophone), 20),
            (.tick(Self.healthy), 29),
            (.tick(Self.healthy), 30),
            (.sessionResumeFailed(generation: 7, cause: .callHoldsMicrophone), 30.1),
            (.interruptionEnded, 45),
        ])
        #expect(microphoneStatus(phase: steps[0].state.phase) == .heldByCall)
        #expect(steps[1].effects.isEmpty)
        #expect(steps[2].effects == [.resumeSession(generation: 7)])
        #expect(microphoneStatus(phase: steps[3].state.phase) == .heldByCall)
        #expect(steps[4].effects == [.resumeSession(generation: 8)])
    }

    // A system interruption whose end never arrives backs off (10, 20, 40, then every 60 s); a call is retried every
    // 10 s so the recording comes back soon after it ends.
    @Test func systemInterruptionRetriesBackOff() {
        #expect(microphoneInterruptionRetryDelaySec(cause: .system, failedAttempts: 0) == 10)
        #expect(microphoneInterruptionRetryDelaySec(cause: .system, failedAttempts: 1) == 10)
        #expect(microphoneInterruptionRetryDelaySec(cause: .system, failedAttempts: 2) == 20)
        #expect(microphoneInterruptionRetryDelaySec(cause: .system, failedAttempts: 3) == 40)
        #expect(microphoneInterruptionRetryDelaySec(cause: .system, failedAttempts: 4) == 60)
        #expect(microphoneInterruptionRetryDelaySec(cause: .system, failedAttempts: 50) == 60)
        #expect(microphoneInterruptionRetryDelaySec(cause: .call, failedAttempts: 50) == 10)

        let steps: [MicrophoneTransition] = replay(MicrophoneCaptureState(phase: .interrupted(cause: .system, lastAttemptAt: 0, failedAttempts: 2), generation: 1), [
            (.tick(Self.healthy), 19),
            (.tick(Self.healthy), 20),
            (.sessionResumeFailed(generation: 2, cause: .other), 20.1),
            (.tick(Self.healthy), 59),
            (.tick(Self.healthy), 60.2),
        ])
        #expect(steps[0].effects.isEmpty)
        #expect(steps[1].effects == [.resumeSession(generation: 2)])
        #expect(steps[2].state.phase == .interrupted(cause: .system, lastAttemptAt: 20.1, failedAttempts: 3))
        #expect(steps[3].effects.isEmpty)
        #expect(steps[4].effects == [.resumeSession(generation: 3)])
    }
}
