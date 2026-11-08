import Foundation
import Synchronization
import Testing
@testable import AINotepadCore

// State machines of the sync engine's lifecycle, the assistant upload schedule, the assistant ledger writes and the
// account stamp of asynchronous work, with the bad orderings found in the state machine audit.

@Suite struct AssistantPassScheduleTests {
    private func step(_ phase: AssistantPassPhase, _ event: AssistantPassEvent) -> AssistantPassStep {
        assistantPassStep(phase: phase, event: event)
    }

    // A change waits the debounce, the timer starts the pass, success with nothing new goes idle.
    @Test func debounceThenPass() {
        #expect(step(.idle, .requested(delaySeconds: 3)) == AssistantPassStep(phase: .waiting, effect: .startTimer(seconds: 3)))
        #expect(step(.waiting, .requested(delaySeconds: 3)) == AssistantPassStep(phase: .waiting, effect: .startTimer(seconds: 3)))
        #expect(step(.waiting, .timerFired) == AssistantPassStep(phase: .running(needsAnother: false), effect: .startPass))
        #expect(step(.running(needsAnother: false), .passSucceeded) == AssistantPassStep(phase: .idle, effect: .none))
        #expect(step(.idle, .requested(delaySeconds: 0)) == AssistantPassStep(phase: .running(needsAnother: false), effect: .startPass))
        // "Retry now" while waiting to retry starts the pass at once.
        #expect(step(.waiting, .requested(delaySeconds: 0)) == AssistantPassStep(phase: .running(needsAnother: false), effect: .startPass))
    }

    // Never two passes: a change during a pass marks one more pass, which starts when this one succeeds.
    @Test func changeDuringPassRunsOneMore() {
        let marked: AssistantPassStep = step(.running(needsAnother: false), .requested(delaySeconds: 3))
        #expect(marked == AssistantPassStep(phase: .running(needsAnother: true), effect: .none))
        #expect(step(marked.phase, .requested(delaySeconds: 0)) == marked)
        #expect(step(marked.phase, .passSucceeded) == AssistantPassStep(phase: .running(needsAnother: false), effect: .startPass))
    }

    // A failed pass waits to retry (also when a change was marked: the retry pass covers it); a stopped one is not retried.
    @Test func failureWaitsAndStopGoesIdle() {
        #expect(step(.running(needsAnother: true), .passFailed(retryDelaySeconds: 30)) == AssistantPassStep(phase: .waiting, effect: .startTimer(seconds: 30)))
        #expect(step(.running(needsAnother: true), .passStopped) == AssistantPassStep(phase: .idle, effect: .none))
    }

    // Reset cancels whatever runs; results and timers that arrive after it change nothing.
    @Test func lateEventsAfterResetAreIgnored() {
        for phase in [AssistantPassPhase.idle, .waiting, .running(needsAnother: true)] {
            #expect(step(phase, .reset) == AssistantPassStep(phase: .idle, effect: .cancelWork))
        }
        for event in [AssistantPassEvent.timerFired, .passSucceeded, .passFailed(retryDelaySeconds: 30), .passStopped] {
            #expect(step(.idle, event) == AssistantPassStep(phase: .idle, effect: .none))
        }
        #expect(step(.running(needsAnother: false), .timerFired) == AssistantPassStep(phase: .running(needsAnother: false), effect: .none))
        #expect(step(.waiting, .passSucceeded) == AssistantPassStep(phase: .waiting, effect: .none))
    }
}

@Suite struct AssistantLedgerWriteTests {
    private let ledger: AssistantUploadLedger = AssistantUploadLedger(epoch: 2, uploaded: ["a": "f1"], rejected: ["b": "f2"], rejectionReasons: ["b": .tooLarge])

    @Test func writeFollowsResets() {
        let seen: AssistantLedgerResets = AssistantLedgerResets(forgets: 1, retries: 1)
        #expect(assistantLedgerWrite(ledger: ledger, seen: seen, current: seen) == .write(ledger))
        // "Retry" came meanwhile: the pass's write keeps it (refusals forgotten).
        #expect(
            assistantLedgerWrite(ledger: ledger, seen: seen, current: AssistantLedgerResets(forgets: 1, retries: 2))
                == .write(AssistantUploadLedger(epoch: 2, uploaded: ["a": "f1"], rejected: [:], rejectionReasons: [:]))
        )
        // Forgotten meanwhile ("remove this device", turn off): the pass never writes its old ledger back.
        #expect(assistantLedgerWrite(ledger: ledger, seen: seen, current: AssistantLedgerResets(forgets: 2, retries: 1)) == .abandon)
        #expect(assistantLedgerWrite(ledger: ledger, seen: seen, current: AssistantLedgerResets(forgets: 2, retries: 2)) == .abandon)
    }
}

@Suite struct HostedScopeStampTests {
    @Test func currentOnlyForSameRunAndAccount() {
        let stamp: HostedScopeStamp = HostedScopeStamp(generation: 4, accountKey: "acct", userID: "user")
        #expect(hostedStampIsCurrent(stamp: stamp, generation: 4, accountKey: "acct", userID: "user"))
        #expect(!hostedStampIsCurrent(stamp: stamp, generation: 5, accountKey: "acct", userID: "user"))
        #expect(!hostedStampIsCurrent(stamp: stamp, generation: 4, accountKey: "other", userID: "user"))
        #expect(!hostedStampIsCurrent(stamp: stamp, generation: 4, accountKey: "acct", userID: "other"))
        #expect(!hostedStampIsCurrent(stamp: stamp, generation: 4, accountKey: nil, userID: nil))
    }
}

/// A token source without a session: any request the engine makes fails before the network and is counted.
private final class CountingSignedOutTokens: HostedAccessTokenSource {
    let requests: Mutex<Int> = Mutex(0)

    nonisolated var clientInfo: HostedClientInfo {
        HostedClientInfo(appVersion: "0.0.0 (0)", osVersion: "test")
    }

    func validAccessToken() async throws -> String {
        requests.withLock { $0 += 1 }
        throw HostedClientError.notSignedIn
    }

    func refreshAccessToken() async throws {
        requests.withLock { $0 += 1 }
        throw HostedClientError.notSignedIn
    }
}

/// A debounce clock whose wait ignores cancellation and ends when the test opens `release`: the timer has fired and
/// its pass is on its way when `stop()` comes.
private final class HeldClock: SyncClock {
    let started: TestGate = TestGate()
    let release: TestGate = TestGate()

    func now() -> Date {
        Date()
    }

    func sleep(seconds: Double) async throws {
        started.open()
        let release: TestGate = release
        await Task { () async -> Void in await release.wait() }.value
    }
}

@Suite struct SyncEngineLifecycleTests {
    @Test func acceptsOnlyWhileOpen() {
        #expect(syncEngineAccepts(lifecycle: .open, request: .queue))
        #expect(syncEngineAccepts(lifecycle: .open, request: .pass))
        #expect(!syncEngineAccepts(lifecycle: .stopped, request: .queue))
        #expect(!syncEngineAccepts(lifecycle: .stopped, request: .pass))
        #expect(!isItemSyncError(error: SyncEngineError.stopped))
    }

    private func engine(clock: any SyncClock, tokens: CountingSignedOutTokens, observed: ObservedResults, root: URL) throws -> SyncEngine {
        let store: SyncAccountFolderStore = SyncAccountFolderStore(
            accountDirectory: root, defaultsSuite: "ainotepad.test.\(UUID().uuidString)", valuesDomain: "ainotepad.test.values.\(UUID().uuidString)",
            busy: { () async -> Set<String> in [] }, recordingInProgress: { () -> Bool in false }, now: { () -> Date in Date() }
        )
        return try SyncEngine(
            client: HostedSyncClient(baseURL: try #require(URL(string: "http://127.0.0.1:9")), credentials: tokens, deviceID: "device"), store: store,
            accountKey: newSyncAccountKey(), userID: "user", files: SyncMetadataFiles(directory: root.appending(path: "Sync", directoryHint: .isDirectory)),
            clock: clock,
            settings: SyncEngineSettings(debounceSeconds: 0.1, maxConflictRounds: 5, pageSize: 10, conflictReason: "changed", myNotesSeparator: "---")
        ) { (_: Result<SyncPassReport, any Error>) -> Void in
            observed.count.withLock { $0 += 1 }
        }
    }

    // After stop the engine takes no work: queueing and passes throw `stopped`, nothing reaches the server or observer.
    @Test func stoppedEngineRefusesWork() async throws {
        let root: URL = FileManager.default.temporaryDirectory.appending(path: "sync-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens: CountingSignedOutTokens = CountingSignedOutTokens()
        let observed: ObservedResults = ObservedResults()
        let engine: SyncEngine = try engine(clock: SystemSyncClock(), tokens: tokens, observed: observed, root: root)
        await engine.stop()
        await #expect(throws: SyncEngineError.stopped) { try await engine.noteLocalChange(item: .prefs) }
        await #expect(throws: SyncEngineError.stopped) { try await engine.queueEverything() }
        await #expect(throws: SyncEngineError.stopped) { _ = try await engine.syncNow() }
        #expect(await engine.pendingWork().items.isEmpty)
        #expect(tokens.requests.withLock { $0 } == 0)
        #expect(observed.count.withLock { $0 } == 0)
    }

    // The audit's ordering: the debounce timer has fired and its pass waits for the engine when the app stops it (account
    // switch). That pass must not run for the old account.
    @Test func firedDebounceDoesNotPassAfterStop() async throws {
        let root: URL = FileManager.default.temporaryDirectory.appending(path: "sync-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens: CountingSignedOutTokens = CountingSignedOutTokens()
        let observed: ObservedResults = ObservedResults()
        let clock: HeldClock = HeldClock()
        let engine: SyncEngine = try engine(clock: clock, tokens: tokens, observed: observed, root: root)
        try await engine.noteLocalChange(item: .prefs)
        await clock.started.wait()
        await engine.stop()
        clock.release.open()
        // Give the released timer time to reach the engine (without the stopped state it starts a pass that asks for a
        // token at once).
        try await Task.sleep(for: .milliseconds(500))
        #expect(tokens.requests.withLock { $0 } == 0)
        #expect(observed.count.withLock { $0 } == 0)
        // The queue stays on disk for the next engine of this account.
        #expect(await engine.pendingWork().items.contains(.prefs))
    }
}

/// Counts the results handed to the engine's observer.
private final class ObservedResults: Sendable {
    let count: Mutex<Int> = Mutex(0)
}
