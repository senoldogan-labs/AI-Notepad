import AVFoundation
import Foundation
import os
import Synchronization
#if os(iOS)
import UIKit
#endif

/// Captures the microphone as 16 kHz mono Float chunks ("You" stream; on iPhone everyone in the room).
///
/// The lifecycle is one explicit state machine (`MicrophoneCaptureState`, `nextMicrophoneState`): this class is its
/// thin adapter. It turns notifications (route and device changes, the user's input choice, engine configuration
/// changes, iOS interruptions, media services resets, app activation), its one-second watchdog and the results of its
/// own async work into events, and executes the effects the machine returns. Every piece of async work carries the
/// generation it was started with, so a stale completion (an older input choice, a rebuild overtaken by an
/// interruption) changes nothing.
///
/// Which microphone is used is decided on every build by asking `input` and calling `selectAudioInput`: on iPhone the
/// session's preferred input (`setPreferredInput`; choosing a Bluetooth headset turns on HFP and, on iOS 26, AirPods
/// high-quality recording), on Mac the engine's input device (`AUAudioUnit.setDeviceID`). Every build uses a fresh
/// `AVAudioEngine`, and the tap is installed only after the engine's format matches the hardware sample rate
/// (`isCaptureFormatReady`): a tap installed with the previous device's format right after a device change crashes the
/// app with an exception AVFoundation does not let us catch. On iPhone the route is first given up to a second to
/// switch to the target input. On Mac, when the target device cannot be built the system default input is used
/// (`audioInputAttempts`) and the choice is reported as unavailable. If no engine can be built the stream does not end
/// (on Mac either): the status stays `.reconnecting` and the watchdog retries; the gap is filled with silence by clock
/// alignment. The recording never stops because of a route change; the input in use is reported through `activeInput`
/// and `onInputChange` once the route has really switched.
@MainActor
public final class MicrophoneCapture {
    private nonisolated static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MicrophoneCapture")
    /// iOS: this long after an interruption begins the session is reopened once: if a call is running iOS rejects it
    /// with `insufficientPriority` and the recording screen can say why the recording paused.
    private static let interruptionProbeDelaySec: Double = 1.5
    /// iOS: after the preferred input is set, the route is given at most this long to switch to it.
    private static let routeSettleTimeoutSec: Double = 1
    private static let routeSettlePollSec: Double = 0.05

    /// Replaced on every build (`replaceEngine`): after a device change the old engine's format cannot be trusted.
    private var engine: AVAudioEngine = AVAudioEngine()
    private var tapInstalled: Bool = false
    /// The open stream; set from the moment permission is granted until the capture stops.
    private var continuation: AsyncStream<[Float]>.Continuation?
    /// The lifecycle (see `nextMicrophoneState`).
    private var machine: MicrophoneCaptureState = MicrophoneCaptureState(phase: .idle, generation: 0)
    /// Origin of the monotonic time the machine sees.
    private let clockOrigin: ContinuousClock.Instant = .now
    private var configurationObserver: (any NSObjectProtocol)?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?
    private var mediaResetObserver: (any NSObjectProtocol)?
    private var choiceObserver: (any NSObjectProtocol)?
    /// Sends `tick` every second.
    private var watchdog: Task<Void, Never>?
    /// iOS: sends `probeFired` shortly after an interruption began.
    private var interruptionProbe: Task<Void, Never>?
    /// Time of the last audio chunk, written from the audio thread.
    private let heartbeat: AudioHeartbeat = AudioHeartbeat()
    /// The capture's status (interruption, reconnecting), derived from the machine's phase; the UI shows it.
    public private(set) var status: MicrophoneStatus = .running
    /// Called when the status changes (the iPhone recording screen shows "Microphone interrupted" / "reconnecting").
    public var onStatusChange: (@MainActor (MicrophoneStatus) -> Void)?
    /// The user's microphone choice and context; read on every build (the setting can change during a recording).
    private let input: @MainActor () -> AudioInputRequest
    /// The input in use (nil when unknown, e.g. the Mac device list could not be read and the engine uses the system's).
    public private(set) var activeInput: ActiveAudioInput?
    /// Called when the input in use changes (the recording screen shows its name and a notice).
    public var onInputChange: (@MainActor (ActiveAudioInput) -> Void)?
    #if os(iOS)
    private var routeChangeObserver: (any NSObjectProtocol)?
    /// iOS: whether the last built session had the Bluetooth microphone (HFP) on; a choice that changes this rebuilds.
    private var appliedBluetoothInput: Bool = false
    #else
    /// Mac: a device was plugged in or removed, or the default input changed.
    private var hardwareObserver: MacAudioHardwareObserver?
    #endif

    /// `input`: the user's microphone choice and context (see `AudioInputRequest`); asked on every build.
    public init(input: @escaping @MainActor () -> AudioInputRequest) {
        self.input = input
    }

    /// The user changed the microphone choice: the capture is rebuilt with the new input when the input in use changes,
    /// otherwise only the reported input is refreshed (the recording never stops). Returns once this change has been
    /// applied, or replaced by a newer choice made meanwhile (which then applies). During an interruption nothing
    /// happens (the rebuild after it reads the new choice); during a rebuild it is queued and applied after it.
    public func inputChoiceChanged() async {
        await send(event: .routeChanged(.choiceChanged))
    }

    /// Asks for permission, starts capturing and returns the stream of chunks. If `stop()` is called while the
    /// permission prompt (first use) or the session is pending, no engine is built and `CancellationError` is thrown:
    /// the microphone never stays on after the recording stopped.
    public func start() async throws -> AsyncStream<[Float]> {
        guard machine.phase == .idle else {
            throw AudioCaptureError.alreadyRunning(source: "MicrophoneCapture")
        }
        await send(event: .startRequested)
        let generation: Int = machine.generation
        guard await AVAudioApplication.requestRecordPermission() else {
            if isCurrent(generation: generation) {
                await send(event: .startFailed(generation: generation))
            }
            throw AudioCaptureError.microphonePermissionDenied
        }
        guard isCurrent(generation: generation) else {
            Self.logger.info("Microphone capture stopped while waiting for permission; no engine built")
            throw CancellationError()
        }
        let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        let builtInput: ActiveAudioInput?
        do {
            #if os(iOS)
            try await activateRecordingSessionForStart(request: input())
            #endif
            // A newly selected device's format may not be ready on the first try (`inputFormatNotReady`).
            builtInput = try await buildWithRetries(generation: generation, continuation: continuation, attempts: 3, delaySec: 0.2)
        } catch {
            if isCurrent(generation: generation) {
                await send(event: .startFailed(generation: generation))
            }
            throw error
        }
        guard isCurrent(generation: generation) else {
            Self.logger.info("Microphone capture stopped while starting; no engine kept")
            throw CancellationError()
        }
        // A change queued during the start is checked in the background: `start()` returns as soon as audio flows.
        for effect in apply(event: .startSucceeded(generation: generation, input: builtInput)) {
            Task { [weak self] in
                await self?.perform(asyncEffect: effect)
            }
        }
        return stream
    }

    /// Stops capturing and ends the stream.
    public func stop() {
        // `stopRequested` only yields synchronous effects; anything else would still run.
        for effect in apply(event: .stopRequested) {
            Task { [weak self] in
                await self?.perform(asyncEffect: effect)
            }
        }
    }

    // MARK: - State machine adapter

    private func isCurrent(generation: Int) -> Bool {
        machine.generation == generation
    }

    private func monotonicNow() -> Double {
        seconds(of: ContinuousClock.now - clockOrigin)
    }

    /// Feeds `event` to the machine and executes every effect, awaiting the async work (and what follows from it).
    private func send(event: MicrophoneCaptureEvent) async {
        for effect in apply(event: event) {
            await perform(asyncEffect: effect)
        }
    }

    /// Applies one transition: the input is reported first, then the derived status, then the other synchronous
    /// effects. Returns the async effects still to run.
    private func apply(event: MicrophoneCaptureEvent) -> [MicrophoneCaptureEffect] {
        let transition: MicrophoneTransition = nextMicrophoneState(state: machine, event: event, now: monotonicNow())
        if transition.state.phase != machine.phase {
            Self.logger.info("Microphone capture phase changed, phase: \(String(describing: transition.state.phase), privacy: .public), generation: \(transition.state.generation, privacy: .public)")
        }
        machine = transition.state
        for effect in transition.effects {
            switch effect {
            case .publishInput(let newInput):
                setActiveInput(newInput)
            case .markAudioFlowing:
                heartbeat.beat()
            case .beginMonitoring, .stopCapture, .scheduleProbe, .check, .rebuild, .resumeSession:
                continue
            }
        }
        setStatus(microphoneStatus(phase: machine.phase))
        // A status listener may have changed the machine (e.g. the keyboard host stops the capture on an interruption):
        // the rest of this transition's effects belong to a state that no longer exists.
        guard machine == transition.state else {
            Self.logger.info("Microphone capture changed during the status callback; skipping the older transition's remaining effects")
            return []
        }
        var asyncEffects: [MicrophoneCaptureEffect] = []
        for effect in transition.effects {
            switch effect {
            case .publishInput, .markAudioFlowing:
                continue
            case .beginMonitoring:
                beginMonitoring()
            case .stopCapture:
                tearDown()
            case .scheduleProbe(let generation):
                scheduleProbe(generation: generation)
            case .check, .rebuild, .resumeSession:
                asyncEffects.append(effect)
            }
        }
        return asyncEffects
    }

    private func perform(asyncEffect: MicrophoneCaptureEffect) async {
        switch asyncEffect {
        case .check(let generation, let checks):
            let result: MicrophoneCheckResult = await checkCapture(checks: checks)
            await send(event: .checkFinished(generation: generation, result: result))
        case .rebuild(let generation, let reason):
            await rebuild(generation: generation, reason: reason)
        case .resumeSession(let generation):
            await resumeSession(generation: generation)
        case .publishInput, .markAudioFlowing, .beginMonitoring, .stopCapture, .scheduleProbe:
            preconditionFailure("Synchronous microphone effect reached the async executor: \(asyncEffect)")
        }
    }

    /// The input in use: reported to the listener when it changed.
    private func setActiveInput(_ newInput: ActiveAudioInput) {
        guard newInput != activeInput else {
            return
        }
        activeInput = newInput
        Self.logger.info("Microphone input, kind: \(newInput.device.kind.rawValue, privacy: .public), choice unavailable: \(newInput.unavailableChoice != nil, privacy: .public)")
        onInputChange?(newInput)
    }

    private func setStatus(_ newStatus: MicrophoneStatus) {
        guard status != newStatus else {
            return
        }
        status = newStatus
        Self.logger.info("Microphone status changed, status: \(String(describing: newStatus), privacy: .public)")
        onStatusChange?(newStatus)
    }

    /// After the first engine runs: watch the input choice, the session or hardware, and start the watchdog.
    private func beginMonitoring() {
        choiceObserver = NotificationCenter.default.addObserver(forName: audioInputChoiceDidChange, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                await self?.inputChoiceChanged()
            }
        }
        #if os(iOS)
        observeAudioSession()
        #else
        observeAudioHardware()
        #endif
        startWatchdog()
    }

    /// Stops everything and ends the stream; the next start reports its input afresh.
    private func tearDown() {
        removeObservers()
        watchdog?.cancel()
        watchdog = nil
        interruptionProbe?.cancel()
        interruptionProbe = nil
        #if os(iOS)
        let hadStream: Bool = continuation != nil
        #endif
        stopEngine()
        continuation?.finish()
        continuation = nil
        activeInput = nil
        #if os(iOS)
        appliedBluetoothInput = false
        // The session is released so other apps' audio (music) resumes.
        if hadStream {
            deactivateRecordingSession()
        }
        #endif
    }

    /// The watchdog: every second it tells the machine whether audio still arrives; the machine decides on a rebuild
    /// (stall) or a retry (failed rebuild, interruption).
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // Cancelled: the capture stopped.
                    return
                }
                guard let self else {
                    return
                }
                let sample: MicrophoneHealthSample = MicrophoneHealthSample(
                    silentForSec: self.heartbeat.silentForSec(now: .now), engineRunning: self.engine.isRunning
                )
                await self.send(event: .tick(sample))
            }
        }
    }

    private func scheduleProbe(generation: Int) {
        interruptionProbe?.cancel()
        interruptionProbe = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.interruptionProbeDelaySec))
            } catch {
                // Cancelled: the capture stopped or a newer interruption scheduled its own probe.
                return
            }
            await self?.send(event: .probeFired(generation: generation))
        }
    }

    /// Builds a fresh engine for `generation`, retrying with backoff; returns the input in use (nil when unknown or
    /// when the generation went stale and nothing was built).
    private func buildWithRetries(
        generation: Int,
        continuation: AsyncStream<[Float]>.Continuation,
        attempts: Int,
        delaySec: Double
    ) async throws -> ActiveAudioInput? {
        var built: ActiveAudioInput?
        try await retryWithBackoff(
            attempts: attempts,
            delaySec: delaySec,
            isolation: #isolation,
            operation: {
                guard self.isCurrent(generation: generation) else {
                    return
                }
                built = try await self.buildCapture(continuation: continuation, generation: generation)
            },
            onFailure: { (attempt: Int, error: any Error) -> Void in
                #if os(iOS)
                Self.logger.warning("Microphone engine could not be built, attempt: \(attempt, privacy: .public), code: \(audioSessionErrorCode(error: error), privacy: .public), app: \(applicationStateName(), privacy: .public), error: \(String(describing: error), privacy: .private)")
                #else
                Self.logger.warning("Microphone engine could not be built, attempt: \(attempt, privacy: .public), error: \(String(describing: error), privacy: .private)")
                #endif
            }
        )
        return built
    }

    /// The `rebuild` effect: a fresh engine (new format, possibly another input); the result goes back to the machine.
    private func rebuild(generation: Int, reason: MicrophoneRecoveryReason) async {
        guard let continuation else {
            return
        }
        Self.logger.warning("Rebuilding the microphone engine, reason: \(reason.rawValue, privacy: .public), silent: \(self.heartbeat.silentForSec(now: .now), privacy: .public) s, engine running: \(self.engine.isRunning, privacy: .public)")
        do {
            let built: ActiveAudioInput? = try await buildWithRetries(generation: generation, continuation: continuation, attempts: 4, delaySec: 0.25)
            if isCurrent(generation: generation) {
                Self.logger.info("Microphone engine rebuilt, reason: \(reason.rawValue, privacy: .public)")
            }
            await send(event: .rebuildSucceeded(generation: generation, input: built))
        } catch {
            let cause: MicrophoneFailureCause = failureCause(error: error)
            if isCurrent(generation: generation) {
                Self.logger.error("Microphone engine could not be rebuilt, retrying later, reason: \(reason.rawValue, privacy: .public), call holds microphone: \(cause == .callHoldsMicrophone, privacy: .public), error: \(String(describing: error), privacy: .private)")
            }
            await send(event: .rebuildFailed(generation: generation, cause: cause))
        }
    }

    private func failureCause(error: any Error) -> MicrophoneFailureCause {
        if case AudioCaptureError.microphoneHeldByCall = error {
            return .callHoldsMicrophone
        }
        return .other
    }

    /// The `check` effect: whether the change needs a rebuild. A route change is checked first; a pending engine
    /// configuration change then needs the engine running with a format that still matches the hardware.
    private func checkCapture(checks: MicrophoneChecks) async -> MicrophoneCheckResult {
        if let route = checks.route {
            #if os(iOS)
            let result: MicrophoneCheckResult = await phoneRouteChanged(change: route)
            #else
            let result: MicrophoneCheckResult = macHardwareChanged(change: route)
            #endif
            guard case .keep = result, checks.engineConfiguration else {
                return result
            }
            return await engineIsHealthy() ? result : .rebuild(.configurationChange)
        }
        guard checks.engineConfiguration else {
            return .keep(nil)
        }
        guard await engineIsHealthy() else {
            return .rebuild(.configurationChange)
        }
        Self.logger.info("Engine configuration changed but the engine runs with the same format; not rebuilt")
        return .keep(nil)
    }

    private func engineIsHealthy() async -> Bool {
        guard engine.isRunning else {
            return false
        }
        return await captureFormatIsCurrent()
    }

    /// Watches the current engine's configuration changes; every build has a new engine, so the new one is watched.
    private func observeEngineConfiguration() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                await self?.send(event: .engineConfigurationChanged)
            }
        }
    }

    private func removeObservers() {
        let observers: [(any NSObjectProtocol)?] = [configurationObserver, interruptionObserver, activationObserver, mediaResetObserver, choiceObserver]
        for case let observer? in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        choiceObserver = nil
        configurationObserver = nil
        interruptionObserver = nil
        activationObserver = nil
        mediaResetObserver = nil
        #if os(iOS)
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
        #else
        hardwareObserver?.stop()
        hardwareObserver = nil
        #endif
    }

    /// Stops the old engine and creates and watches a new one (the tap is not installed yet).
    private func replaceEngine() {
        stopEngine()
        engine = AVAudioEngine()
        tapInstalled = false
        observeEngineConfiguration()
    }

    #if os(macOS)
    /// Mac: device list and default input changes go to the machine. If the listener cannot start it is logged: the
    /// recording goes on and the engine's own configuration change (the device in use was removed) still arrives.
    private func observeAudioHardware() {
        let observer: MacAudioHardwareObserver = MacAudioHardwareObserver { [weak self] (change: AudioRouteChange) -> Void in
            Task { @MainActor in
                await self?.send(event: .routeChanged(change))
            }
        }
        do {
            try observer.start()
            hardwareObserver = observer
        } catch {
            Self.logger.error("Cannot watch audio device changes, error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Mac: the target input is recomputed after a device or choice change; a rebuild only when it differs from the
    /// input in use. A changed choice that keeps the same device only refreshes the reported input.
    private func macHardwareChanged(change: AudioRouteChange) -> MicrophoneCheckResult {
        let plan: MacInputPlan
        do {
            plan = try macInputPlan(request: input())
        } catch {
            Self.logger.error("Input devices could not be read after a device change, error: \(String(describing: error), privacy: .public)")
            return .keep(nil)
        }
        let target: ActiveAudioInput? = plan.attempts.first
        if change == .choiceChanged, let target, !needsCaptureRebuild(current: activeInput, target: target.device, sessionOptionsChanged: false) {
            return .keep(target)
        }
        guard shouldReselectInput(change: change, target: target?.device, current: activeInput?.device) else {
            return .keep(nil)
        }
        Self.logger.info("Audio devices or the choice changed, rebuilding the microphone with the new input")
        return .rebuild(change == .choiceChanged ? .inputSelected : .configurationChange)
    }

    /// Mac: the inputs to try in order and the devices' Core Audio ids.
    private struct MacInputPlan {
        let attempts: [ActiveAudioInput]
        let objectIDs: [String: AudioObjectID]
    }

    private func macInputPlan(request: AudioInputRequest) throws -> MacInputPlan {
        let available: [MacAudioInput] = try macInputDevices()
        let systemDefault: MacAudioInput? = try macDefaultInput()
        let selection: AudioInputSelection = selectAudioInput(request: request, available: available.map(\.device), systemDefault: systemDefault?.device)
        let objectIDs: [String: AudioObjectID] = Dictionary(
            (available + [systemDefault].compactMap { $0 }).map { ($0.device.id, $0.objectID) },
            uniquingKeysWith: { (first: AudioObjectID, _: AudioObjectID) -> AudioObjectID in first }
        )
        return MacInputPlan(attempts: audioInputAttempts(request: request, selection: selection, systemDefault: systemDefault?.device), objectIDs: objectIDs)
    }

    /// Mac: builds the target input with a new engine; if that fails (device did not open, engine did not start, format
    /// did not hold) the system default input is built and the choice is reported unavailable. If the device list
    /// cannot be read or there is no input device, the engine uses the system's input. If nothing can be built the last
    /// error is thrown (retried). Returns the input in use.
    private func buildMacCapture(continuation: AsyncStream<[Float]>.Continuation) throws -> ActiveAudioInput? {
        let request: AudioInputRequest = input()
        let plan: MacInputPlan?
        do {
            plan = try macInputPlan(request: request)
        } catch {
            Self.logger.error("Input devices could not be read, building with the system's input, error: \(String(describing: error), privacy: .public)")
            plan = nil
        }
        guard let plan, !plan.attempts.isEmpty else {
            replaceEngine()
            try startEngine(continuation: continuation)
            return nil
        }
        var lastError: any Error = AudioCaptureError.microphoneStartFailed(code: 0)
        for attempt in plan.attempts {
            guard let objectID = plan.objectIDs[attempt.device.id] else {
                continue
            }
            do {
                try startMacEngine(objectID: objectID, continuation: continuation)
                return attempt
            } catch {
                Self.logger.error("Microphone device could not be built, trying the next, kind: \(attempt.device.kind.rawValue, privacy: .public), error: \(String(describing: error), privacy: .public)")
                stopEngine()
                lastError = error
            }
        }
        throw lastError
    }

    /// Builds the new engine with the given device. After `setDeviceID` the input node's output (client) format keeps
    /// the previous device's sample rate: on this Mac choosing a 44.1 kHz BlackHole left the node at 48 kHz and the
    /// engine looked "running" while the tap got no audio. So the client format is set to the device's hardware rate,
    /// and if it does not hold the tap is not installed (`inputFormatNotReady`, the next input is tried).
    private func startMacEngine(objectID: AudioObjectID, continuation: AsyncStream<[Float]>.Continuation) throws {
        replaceEngine()
        let input: AVAudioInputNode = engine.inputNode
        try input.auAudioUnit.setDeviceID(objectID)
        let hardwareRate: Double = try macNominalSampleRate(deviceID: objectID)
        let channels: AVAudioChannelCount = max(1, input.inputFormat(forBus: 0).channelCount)
        guard let clientFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: channels) else {
            throw AudioCaptureError.inputFormatNotReady(nodeSampleRate: input.outputFormat(forBus: 0).sampleRate, hardwareSampleRate: hardwareRate)
        }
        // The input node's client side is AUHAL's output bus 1 (input).
        try input.auAudioUnit.outputBusses[1].setFormat(clientFormat)
        let nodeRate: Double = input.outputFormat(forBus: 0).sampleRate
        guard isCaptureFormatReady(nodeSampleRate: nodeRate, hardwareSampleRate: hardwareRate) else {
            throw AudioCaptureError.inputFormatNotReady(nodeSampleRate: nodeRate, hardwareSampleRate: hardwareRate)
        }
        try startEngine(continuation: continuation)
    }

    /// Whether the running engine's format still matches the device's (the configuration change was harmless).
    private func captureFormatIsCurrent() async -> Bool {
        do {
            let hardwareRate: Double = try macNominalSampleRate(deviceID: engine.inputNode.auAudioUnit.deviceID)
            return isCaptureFormatReady(nodeSampleRate: engine.inputNode.outputFormat(forBus: 0).sampleRate, hardwareSampleRate: hardwareRate)
        } catch {
            Self.logger.warning("Input device sample rate could not be read, error: \(String(describing: error), privacy: .public)")
            return false
        }
    }
    #endif

    #if os(iOS)
    private func observeAudioSession() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] (notification: Notification) -> Void in
            let rawType: UInt? = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type: AVAudioSession.InterruptionType? = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let rawReason: UInt = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
            let rawOptions: UInt = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                // Diagnostics: the interruption's type and reason and the app state (a recording interrupted in the
                // background can only be reopened there with a mixable session).
                Self.logger.info("Audio session interruption, type: \(rawType.map(String.init) ?? "none", privacy: .public), reason: \(rawReason, privacy: .public), should resume: \(rawOptions & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0, privacy: .public), app: \(applicationStateName(), privacy: .public)")
                switch type {
                case .began:
                    await self?.send(event: .interruptionBegan)
                case .ended:
                    await self?.send(event: .interruptionEnded)
                default:
                    return
                }
            }
        }
        // VoIP apps do not always post the end of an interruption: coming to the foreground retries at once.
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                await self?.send(event: .appBecameActive)
            }
        }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                Self.logger.warning("Media services were reset")
                await self?.send(event: .mediaServicesReset)
            }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] (notification: Notification) -> Void in
            let rawReason: UInt = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor in
                Self.logger.info("Audio route changed, reason: \(rawReason, privacy: .public)")
                await self?.send(event: .routeChanged(audioRouteChange(reason: AVAudioSession.RouteChangeReason(rawValue: rawReason))))
            }
        }
    }

    /// iPhone: checks a route or choice change.
    /// - Choice changed: see `phoneChoiceChanged`.
    /// - A device was plugged in or removed and the target input differs from the one in use (e.g. "Wired / USB" is
    ///   chosen and a headset is plugged in: `defaultToSpeaker` keeps the system on the built-in microphone): rebuild.
    /// - Otherwise: if the route's input did not change only the reported input is refreshed; if it did, the engine's
    ///   configuration change triggers the rebuild.
    private func phoneRouteChanged(change: AudioRouteChange) async -> MicrophoneCheckResult {
        let request: AudioInputRequest = input()
        if change == .choiceChanged {
            return await phoneChoiceChanged(request: request)
        }
        let snapshot: PhoneInputSnapshot
        do {
            snapshot = try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> PhoneInputSnapshot in
                phoneInputSnapshot(session: session)
            }
        } catch {
            Self.logger.error("Audio route could not be read, error: \(String(describing: error), privacy: .private)")
            return .keep(nil)
        }
        let selection: AudioInputSelection = selectAudioInput(request: request, available: snapshot.available, systemDefault: snapshot.current)
        if shouldReselectInput(change: change, target: selection.device, current: snapshot.current) {
            Self.logger.info("Audio route changed, rebuilding the microphone for the choice, input: \(snapshot.current?.kind.rawValue ?? "none", privacy: .public)")
            return .rebuild(.configurationChange)
        }
        guard let current = snapshot.current, current.id == activeInput?.device.id || engine.isRunning else {
            return .keep(nil)
        }
        return .keep(settledActiveInput(request: request, selection: selection, current: current))
    }

    /// iPhone, choice changed: if the session options change (Bluetooth microphone on/off) rebuild; otherwise set only
    /// the preferred input, let the route settle, and rebuild once if the input really changed (or the engine stopped
    /// while the route switched); else refresh the reported input. A newer choice made meanwhile makes this result
    /// stale (the machine ignores it).
    private func phoneChoiceChanged(request: AudioInputRequest) async -> MicrophoneCheckResult {
        guard needsBluetoothInput(choice: request.choice) == appliedBluetoothInput else {
            return .rebuild(.inputSelected)
        }
        let current: AudioInputDevice?
        let preference: PhoneInputPreference
        do {
            preference = try await activateRecordingSession(request: request)
            current = await settleRoute(preference: preference)
        } catch {
            Self.logger.error("Microphone choice could not be applied, rebuilding, error: \(String(describing: error), privacy: .private)")
            return .rebuild(.inputSelected)
        }
        guard let current, !needsCaptureRebuild(current: activeInput, target: current, sessionOptionsChanged: false), engine.isRunning else {
            return .rebuild(.inputSelected)
        }
        return .keep(settledActiveInput(request: request, selection: preference.selection, current: current))
    }

    /// When a preferred input was set, waits at most `routeSettleTimeoutSec` for the route to switch to it; returns the
    /// input in use (the real one if it did not switch).
    private func settleRoute(preference: PhoneInputPreference) async -> AudioInputDevice? {
        let deadline: ContinuousClock.Instant = .now + .seconds(Self.routeSettleTimeoutSec)
        while true {
            let current: AudioInputDevice?
            do {
                current = try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> AudioInputDevice? in
                    session.currentRoute.inputs.first.map(phoneInputDevice(port:))
                }
            } catch {
                Self.logger.error("Audio route could not be read, error: \(String(describing: error), privacy: .private)")
                return nil
            }
            guard preference.applied, let target = preference.selection.device, current?.id != target.id, ContinuousClock.now < deadline else {
                return current
            }
            do {
                try await Task.sleep(for: .seconds(Self.routeSettlePollSec))
            } catch {
                return current
            }
        }
    }

    /// iPhone: opens the session for the choice, waits for the route to settle and builds a new engine; if the
    /// engine's format has not switched to the session's sample rate the tap is not installed (retried). Returns the
    /// input in use once the engine runs (nil when the generation went stale and nothing was built).
    private func buildPhoneCapture(continuation: AsyncStream<[Float]>.Continuation, generation: Int) async throws -> ActiveAudioInput? {
        let request: AudioInputRequest = input()
        let preference: PhoneInputPreference = try await activateRecordingSession(request: request)
        let current: AudioInputDevice? = await settleRoute(preference: preference)
        let hardwareRate: Double = try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> Double in
            session.sampleRate
        }
        // A newer build, an interruption or a stop happened while waiting: no engine. Two builds would install a second
        // tap on the same input; a stopped recording would keep the microphone on.
        guard isCurrent(generation: generation) else {
            return nil
        }
        replaceEngine()
        let nodeRate: Double = engine.inputNode.outputFormat(forBus: 0).sampleRate
        guard isCaptureFormatReady(nodeSampleRate: nodeRate, hardwareSampleRate: hardwareRate) else {
            throw AudioCaptureError.inputFormatNotReady(nodeSampleRate: nodeRate, hardwareSampleRate: hardwareRate)
        }
        try startEngine(continuation: continuation)
        appliedBluetoothInput = needsBluetoothInput(choice: request.choice)
        return settledActiveInput(request: request, selection: preference.selection, current: current)
    }

    /// Whether the running engine's format still matches the session's (the configuration change was harmless).
    private func captureFormatIsCurrent() async -> Bool {
        do {
            let hardwareRate: Double = try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> Double in
                session.sampleRate
            }
            return isCaptureFormatReady(nodeSampleRate: engine.inputNode.outputFormat(forBus: 0).sampleRate, hardwareSampleRate: hardwareRate)
        } catch {
            Self.logger.warning("Audio session sample rate could not be read, error: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// The `resumeSession` effect: reopens the audio session after an interruption (the interruption closed it). If a
    /// call on this iPhone holds the microphone the machine shows `.heldByCall` and retries until the call ends.
    private func resumeSession(generation: Int) async {
        guard continuation != nil else {
            return
        }
        Self.logger.info("Reopening the audio session after an interruption, app: \(applicationStateName(), privacy: .public)")
        do {
            // The input in use is reported once the engine is rebuilt; this only reopens the session.
            _ = try await activateRecordingSession(request: input())
        } catch {
            let cause: MicrophoneFailureCause = failureCause(error: error)
            Self.logger.info("Audio session could not be reopened, interruption continues, call holds microphone: \(cause == .callHoldsMicrophone, privacy: .public), code: \(audioSessionErrorCode(error: error), privacy: .public), app: \(applicationStateName(), privacy: .public)")
            await send(event: .sessionResumeFailed(generation: generation, cause: cause))
            return
        }
        await send(event: .sessionResumed(generation: generation))
    }

    /// The audio session when a recording starts: picks up the room with the built-in microphone; recording goes on in
    /// the background and with the screen locked (`audio` background mode). Bluetooth headsets are used only for
    /// playback (A2DP); the headset microphone (HFP) is turned on only when the user chooses "Bluetooth headset" (see
    /// `recordingSessionOptions`). The preferred input is set on every build (`activateRecordingSession`).
    ///
    /// A non-mixable session is opened first so playing music or a podcast stops instead of mixing into the
    /// recording. Then the session is made mixable (`recordingSessionOptions`): another app's sound (a video, a voice
    /// message) does not interrupt the recording and the session can be reopened in the background after an
    /// interruption (iOS rejects a non-mixable session in the background with `cannotInterruptOthers`). An incoming
    /// call's ringtone does not interrupt the recording; only accepting it does.
    /// Session changes run on `AudioSessionQueue`, not the main thread (the UI does not freeze waiting on the system).
    private func activateRecordingSessionForStart(request: AudioInputRequest) async throws {
        let options: AVAudioSession.CategoryOptions = recordingSessionOptions(choice: request.choice)
        do {
            try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> Void in
                try session.setCategory(.playAndRecord, mode: .default, options: options.subtracting(.mixWithOthers))
                try session.setActive(true)
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                do {
                    try session.setPrefersNoInterruptionsFromSystemAlerts(true)
                } catch {
                    // Only a preference: without it an incoming call's ringtone interrupts; the recording resumes after.
                    Self.logger.warning("System alert preference could not be set on the audio session, code: \(audioSessionErrorCode(error: error), privacy: .public)")
                }
            }
        } catch {
            Self.logger.error("Recording audio session could not be opened, code: \(audioSessionErrorCode(error: error), privacy: .public), app: \(applicationStateName(), privacy: .public)")
            throw sessionActivationError(error: error)
        }
    }

    /// On every build, after an interruption and when the choice changes the session is (re)opened for the choice: a
    /// mixable session (see `activateRecordingSessionForStart`) can be opened in the background too; reopening an open
    /// session is harmless. The preferred input follows the choice.
    private func activateRecordingSession(request: AudioInputRequest) async throws -> PhoneInputPreference {
        let options: AVAudioSession.CategoryOptions = recordingSessionOptions(choice: request.choice)
        do {
            return try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> PhoneInputPreference in
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                try session.setActive(true)
                return applyPreferredInput(session: session, request: request)
            }
        } catch {
            throw sessionActivationError(error: error)
        }
    }

    /// When the recording ends the session is released; other apps' audio (music) continues.
    /// Enqueued without waiting: the UI does not wait at stop; the next "activate" runs after it on the queue.
    private func deactivateRecordingSession() {
        AudioSessionQueue.enqueue(
            { (session: AVAudioSession) throws -> Void in
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            },
            onError: { (error: any Error) -> Void in
                Self.logger.error("Audio session could not be released, error: \(String(describing: error), privacy: .private)")
            }
        )
    }
    #else
    /// Mac has no audio session to reopen: the machine moves straight on to the rebuild (never reached; no interruptions
    /// on Mac).
    private func resumeSession(generation: Int) async {
        await send(event: .sessionResumed(generation: generation))
    }
    #endif

    /// Finds the input for the choice and builds the capture with a new engine (see `buildPhoneCapture`,
    /// `buildMacCapture`). Returns the input in use.
    private func buildCapture(continuation: AsyncStream<[Float]>.Continuation, generation: Int) async throws -> ActiveAudioInput? {
        #if os(iOS)
        try await buildPhoneCapture(continuation: continuation, generation: generation)
        #else
        try buildMacCapture(continuation: continuation)
        #endif
    }

    /// Installs the tap for the input format and starts the engine. An installed tap is removed first: a second tap on
    /// the same input crashes the app with an exception AVFoundation does not let us catch.
    private func startEngine(continuation: AsyncStream<[Float]>.Continuation) throws {
        if tapInstalled {
            Self.logger.warning("An old tap was still installed while building the microphone engine; removing it")
            stopEngine()
        }
        let input: AVAudioInputNode = engine.inputNode
        let format: AVAudioFormat = input.outputFormat(forBus: 0)
        let resampler: AudioResampler = try AudioResampler(inputFormat: format)
        input.installTap(
            onBus: 0, bufferSize: 4096, format: format,
            block: Self.makeTapBlock(resampler: resampler, continuation: continuation, heartbeat: heartbeat, throttle: LogThrottle(intervalSec: 60))
        )
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AudioCaptureError.microphoneStartFailed(code: Int32((error as NSError).code))
        }
    }

    private func stopEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    /// The tap block that runs on the audio thread; built `nonisolated` so it is not bound to the main actor.
    private nonisolated static func makeTapBlock(
        resampler: AudioResampler,
        continuation: AsyncStream<[Float]>.Continuation,
        heartbeat: AudioHeartbeat,
        throttle: LogThrottle
    ) -> AVAudioNodeTapBlock {
        { (buffer: AVAudioPCMBuffer, _: AVAudioTime) -> Void in
            heartbeat.beat()
            do {
                let samples: [Float] = try resampler.convert(buffer: buffer)
                if !samples.isEmpty {
                    continuation.yield(samples)
                }
            } catch {
                // Repeats on every buffer: logged once a minute.
                if throttle.allow() {
                    logger.error("Microphone audio could not be converted, error: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }
}

/// Time of the last audio chunk from the audio thread; the watchdog reads it from the main actor. Thread-safe.
final class AudioHeartbeat: Sendable {
    private let last: Mutex<ContinuousClock.Instant> = Mutex(ContinuousClock.now)

    func beat() {
        let now: ContinuousClock.Instant = .now
        last.withLock { (value: inout ContinuousClock.Instant) -> Void in value = now }
    }

    func silentForSec(now: ContinuousClock.Instant) -> Double {
        let lastBeat: ContinuousClock.Instant = last.withLock { (value: inout ContinuousClock.Instant) -> ContinuousClock.Instant in value }
        return seconds(of: now - lastBeat)
    }
}

#if os(iOS)
/// Kayıt sürerken ses oturumunun seçenekleri: hoparlör, yalnız çalma için Bluetooth ve karışabilirlik (bkz.
/// `MicrophoneCapture.activateRecordingSessionForStart`). Kullanıcı "Bluetooth kulaklık"ı seçtiyse kulaklık mikrofonu
/// (HFP) da açılır; iOS 26'da AirPods'un yüksek kaliteli kaydı (destekleyen modelde tam bant; desteklemeyende HFP'ye
/// düşer). Seçilmediyse HFP kapalı kalır: aynı cihazda HFP açıkken iOS onu öncelikle seçer ve AirPods sesini dar banda
/// düşürür (Apple: `AVAudioSessionCategoryOptionAllowBluetoothA2DP` belgesi).
private func recordingSessionOptions(choice: AudioInputChoice) -> AVAudioSession.CategoryOptions {
    let base: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
    guard needsBluetoothInput(choice: choice) else {
        return base
    }
    if #available(iOS 26.0, *) {
        return base.union([.allowBluetoothHFP, .bluetoothHighQualityRecording])
    }
    return base.union(.allowBluetoothHFP)
}

/// Ses yolundaki girişler ve kullanılan giriş.
private struct PhoneInputSnapshot: Sendable {
    let available: [AudioInputDevice]
    let current: AudioInputDevice?
}

/// Tercih edilen girişin sonucu: seçim ve tercih verilebildi mi (verilemediyse ses yolu beklenmez).
private struct PhoneInputPreference: Sendable {
    let selection: AudioInputSelection
    let applied: Bool
}

private func phoneInputSnapshot(session: AVAudioSession) -> PhoneInputSnapshot {
    PhoneInputSnapshot(
        available: (session.availableInputs ?? []).map(phoneInputDevice(port:)),
        current: session.currentRoute.inputs.first.map(phoneInputDevice(port:))
    )
}

/// Seçime göre tercih edilen girişi verir (oturum kuyruğunda, oturum açıkken; Apple: tercih edilen giriş kategori ve
/// mod ayarlanıp oturum açıldıktan sonra verilmeli). "Otomatik"te tercih kaldırılır (nil): ses yolu sistemindir.
/// Tercih verilemezse loglanır; kayıt sistemin girişiyle sürer ve seçim "kullanılamıyor" sayılır
/// (`settledActiveInput`).
private func applyPreferredInput(session: AVAudioSession, request: AudioInputRequest) -> PhoneInputPreference {
    let ports: [AVAudioSessionPortDescription] = session.availableInputs ?? []
    let snapshot: PhoneInputSnapshot = phoneInputSnapshot(session: session)
    let selection: AudioInputSelection = selectAudioInput(request: request, available: snapshot.available, systemDefault: snapshot.current)
    let port: AVAudioSessionPortDescription? = selection.device.flatMap { (device: AudioInputDevice) -> AVAudioSessionPortDescription? in
        ports.first { $0.uid == device.id }
    }
    do {
        try session.setPreferredInput(port)
        return PhoneInputPreference(selection: selection, applied: true)
    } catch {
        phoneInputLogger.error("Tercih edilen mikrofon verilemedi, kayıt sistemin girişiyle sürüyor, tür: \(selection.device?.kind.rawValue ?? "otomatik", privacy: .public), kod: \((error as NSError).code, privacy: .public)")
        return PhoneInputPreference(selection: selection, applied: false)
    }
}

/// iOS ses yolu girişini uygulamanın giriş türüne çevirir.
private func phoneInputDevice(port: AVAudioSessionPortDescription) -> AudioInputDevice {
    AudioInputDevice(id: port.uid, name: port.portName, kind: phoneInputKind(portType: port.portType))
}

private func phoneInputKind(portType: AVAudioSession.Port) -> AudioInputKind {
    switch portType {
    case .builtInMic:
        .builtIn
    case .bluetoothHFP, .bluetoothLE:
        .bluetooth
    case .headsetMic, .lineIn:
        .wired
    case .usbAudio:
        .usb
    case .continuityMicrophone:
        .continuity
    default:
        .other
    }
}

/// iOS ses yolu değişikliğinin nedeni uygulamanın türüne: yalnız takma/çıkarma girişi yeniden seçtirir.
private func audioRouteChange(reason: AVAudioSession.RouteChangeReason?) -> AudioRouteChange {
    switch reason {
    case .newDeviceAvailable:
        .deviceAdded
    case .oldDeviceUnavailable, .noSuitableRouteForCategory:
        .deviceRemoved
    default:
        .other
    }
}

private let phoneInputLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MicrophoneCapture")

/// Ses oturumu hatasının kodu (ör. 560557684 `!int`: karışmayan oturum arka planda açılamaz); içerik taşımaz.
private func audioSessionErrorCode(error: any Error) -> Int {
    switch error {
    case AudioCaptureError.microphoneStartFailed(let code):
        Int(code)
    case AudioCaptureError.microphoneHeldByCall:
        audioSessionInsufficientPriorityCode
    default:
        (error as NSError).code
    }
}

/// Ses oturumu açılamadı: bu iPhone'daki bir görüşme mikrofonu tutuyorsa (`insufficientPriority`) ayrı hata (kullanıcıya
/// nedeni ve çaresi söylenir), değilse kodlu genel hata.
private func sessionActivationError(error: any Error) -> AudioCaptureError {
    let code: Int = (error as NSError).code
    guard !isCallHoldingMicrophone(code: code) else {
        return .microphoneHeldByCall
    }
    return .microphoneStartFailed(code: Int32(code))
}

/// Uygulamanın durumu (loglar için): "active", "inactive" ya da "background".
@MainActor
private func applicationStateName() -> String {
    switch UIApplication.shared.applicationState {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
}
#endif

/// Süreyi saniyeye çevirir. Saf fonksiyondur.
private func seconds(of duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
