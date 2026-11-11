# State-machine Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Cloud execution:** Read the [cloud-agent handoff](2026-11-11-state-machine-cloud-handoff.md) for environment preflight, the portable execution workflow and continuation requirements. It covers skill invocation when local execution skills are unavailable; all architecture, verification and review gates below remain binding.

**Goal:** Make recording, paid processing, account ownership and cross-system delivery recoverable and reviewable; address every identified implicit protocol through a concrete fix, a focused extraction or an evidence-backed decision to retain simple state.

**Architecture:** Keep existing explicit domain models. Add pure typed decisions only for missing ownership/transition boundaries, with IO in current adapters. Files, SQL transactions, epochs, idempotency records and outboxes remain durable authority. Separate behavior-preserving extraction from changes that add durability guarantees.

**Tech Stack:** Swift 6.2, Swift Testing/XCTest and SwiftPM; SwiftUI/AppKit/AVFoundation/WatchConnectivity; dependency-free KeyboardCore and Foundation-only WatchLink; Cloudflare Workers/D1/R2/KV, TypeScript 5.9.3 and Vitest; Astro and Node 26 built-in tests/Playwright. Keep existing npm locks and XcodeGen configuration.

**Spec:** [Scope, architecture decisions and complete 175-label registry](../specs/2026-11-11-state-machine-hardening.md).

## Global Constraints

- This is a proposed execution plan. No runtime bug has been reproduced and no implementation check is reported as passing by this document. Inventory labels overlap and do not count distinct defects.
- Before **each code-changing work package**, run both required Swift package test commands in the verification table. Record baseline failures before editing; do not relabel an unrelated failure as success. Documentation-only work does not need a runtime baseline.
- Reuse existing scenario tests first. Add minimal pure-transition tests and temporary-directory/local-service integration cases for missing invariants. Do not test each Boolean, mirror every implementation branch, or replace real D1/R2/filesystem behavior with mocks.
- Every asynchronous result carries the relevant owner and work/attempt identity. Guard publication and newly initiated side effects after `await`; cancellation alone is insufficient. Release stale resources by their own identity.
- No new FSM dependency, generic coordinator, catch-all effect type or application-wide enum. Keep independent dimensions separate and preserve legitimate parallel work.
- No file/wire/schema changes in extraction PRs. Preserve App Group JSON, Watch messages, API responses, checkpoint fingerprints and encrypted formats. A necessary persistence change is a separate additive, compatibility-tested PR.
- Do not promise exactly-once external effects. Preserve uncertain outcomes, partial tracker progress, provider idempotency and explicit retry rules. Keep existing intentional telemetry/fallback policies during extraction; new behavior needs a distinct regression and reviewed decision.
- Keep iOS 18/macOS 15/watchOS 26 support and availability guards. Keyboard extension must not link AINotepadCore/WhisperKit. Do not enable pilot policies or experimental release flags.
- Use English repository text, strict named types, explicit parameters and pure transformations. Time, IDs and configuration are supplied as data; transitions do not read clocks or create IO handles.
- Existing unrelated untracked documents are outside this program. Do not stage them, rewrite them or include them in plan commits.
- Ship independent reviewable PRs. Before settling each new nontrivial model or persistence design, get independent expert review and record agreement, dissent and rationale next to its owning task. Auth, payments, migrations and production infra changes stop/report before shipping under AGENTS.md; prepare concrete implementation and checks first. Do not introduce a speculative approval step for ordinary refactors.

## Review Focus

| Failure/input class | Required evidence owner |
| --- | --- |
| Compute/remote success followed by failed local persistence or process termination | P01, P11, P13, P20–P22, P25–P26; reopen the same files/DB/object store with fresh adapter instances. |
| Stale completion after A → B → A, request replacement or recording stop | P02–P10, P12, P14, P17–P19, P23, P27–P28; force reversed completion order with existing gates. |
| Duplicate trigger, callback, upload, webhook or background-task delivery | P01–P04, P08, P13–P16, P20–P28; assert observable effects and persistent counters, not just enum values. |
| Partial acquisition, cancellation, timeout or unavailable permission/hardware | P02–P08, P12, P14–P16, P26, P29; prove owner-specific cleanup and retained recovery evidence. |
| Compatibility across old/new components and concurrent writers | P01, P10–P11, P14, P16–P18, P21, P23–P25; fixtures, SQL CAS/epochs and both Worker bundles. |

## Execution order and PR boundaries

Start with **P00 → P01 → P02**. P01 first characterizes a concrete save-order hypothesis: `App/AppModel.swift` consumes pending external-action marks before its final save. Establish whether those marks already exist durably; fix only a demonstrated gap. Do not start by replacing the recorder reducer or adding a framework.

| Wave | Work packages | Exit condition |
| --- | --- | --- |
| A — Preserve recordings and committed results | P00–P08 | Save/recovery and resource shutdown traces pass; original audio/checkpoints remain recoverable. |
| B — Isolate identities and local custody | P09–P12 | Old work cannot publish into a replacement session; local moves/imports resume safely. |
| C — Client delivery and companion protocols | P13–P19 | Receipts, keyboard/Watch custody, sync and Ask attempts have one authority. |
| D — Server durable boundaries | P20–P26 | Accounting, publication, access and cleanup guarantees are proven at their durable boundaries. |
| E — Browser adapters and bounded protocols | P27–P29 | Browser ownership is explicit; each small protocol has a reviewed disposition. |
| F — Cross-layer acceptance | P30 | Every registry label has closure evidence; required hardware/sensitive-change gates are resolved. |

Within a wave, follow the task dependencies below. Serialize changes to `App/AppModel.swift`, `App/Hosted/HostedAccount.swift`, `iOS/PhoneRecorder.swift` and `iOS/AINotepadiOSApp.swift`; do not have workers edit those files concurrently. P03/P05/P15 and low-risk P28/P29 review can proceed independently after P00 when files do not overlap.

P01, P06, P11, P14, P21 and P28 contain explicit sub-PRs. Finish and check each sub-PR before starting the next; they are work-package groups, not permission to create one large change. Record each implementation PR and its verification result under the owning task. Test names below are proposed names for missing scenarios; reuse or extend an existing equivalent test instead of duplicating it. Scope expansion or a persistence migration creates an additional child PR, preserving this plan's coverage owner.

## File and interface conventions

Paths below use these exact roots: `Core/` = `Packages/AINotepadCore/Sources/AINotepadCore/`; `UI/` = `Packages/AINotepadCore/Sources/AINotepadUI/`; `Keyboard/` = `Packages/AINotepadCore/Sources/KeyboardCore/`; `CoreTests/`, `UITests/`, `KeyboardTests/` = the corresponding directories under `Packages/AINotepadCore/Tests/`. `Link/` = `Packages/AINotepadWatchLink/Sources/AINotepadWatchLink/`; `LinkTests/` = `Packages/AINotepadWatchLink/Tests/AINotepadWatchLinkTests/`. Other paths are repository-relative. In a comma-separated Files list, an unprefixed filename continues the immediately preceding directory (for example, `Core/Meeting/ProcessMeeting.swift`, `ProcessingCheckpoint.swift` are both in `Core/Meeting/`).

All **Create** files and new interface names below are proposed, not existing APIs. A domain `XTransition` is a named immutable value with `state: XState` and `effects: [XEffect]`; its effects are a concrete domain enum. No generic transition runtime is required. Events carry matching owner/attempt IDs, observations and explicit times when needed. SQL decision helpers return typed plans, and their adapters repeat expected epoch/revision/ownership conditions in the actual write. Types declared in an interface live in that task's proposed file unless an existing type is explicitly named.

## Verification commands

Run from the repository root unless a working directory is stated. A task's command labels expand to these commands; install locked npm dependencies with `npm ci` in `server/` and `web/` only when missing. Check definitions before execution if the baseline has changed.

| Label | Command / expectation |
| --- | --- |
| CORE | `swift test --package-path Packages/AINotepadCore` — required existing tests pass; report environment-gated tests separately. |
| LINK | `swift test --package-path Packages/AINotepadWatchLink` — required message/transfer policy tests pass. |
| MAC | `xcodegen generate`, then `xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet` — build succeeds. |
| HOSTED | Same macOS build command with `-scheme AINotepadHosted` — hosted adapter wiring compiles. |
| IOS | `xcodebuild -project AINotepad.xcodeproj -scheme AINotepadiOS -configuration Debug -derivedDataPath .build/xcode-ios -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet` after XcodeGen — succeeds. Also build Release for changed conditional code using a separate derived-data directory. |
| WATCH | `xcodebuild -project AINotepad.xcodeproj -scheme AINotepadWatch -configuration Debug -derivedDataPath .build/xcode-watch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build -quiet` — succeeds. Watch app adapter tests use the repo's paired-device test setup. |
| SERVER | In `server/`: `npm run typecheck`, then `npm test` — both pass using existing local D1/R2/KV and provider fixtures. |
| WORKERS | In `server/`: `npx wrangler deploy --dry-run --env "" --outdir <unique-temp-api-dir>` and `npx wrangler deploy --dry-run --config wrangler.mcp.jsonc --env "" --outdir <unique-temp-mcp-dir>` — both bundle; use separate fresh temporary directories. These commands do not deploy. |
| WEB | In `web/`: `npm run typecheck`, `npm run build`, `npm test` — Astro/TypeScript, production output and existing tests pass. |
| WEB-E2E | Build with `npm run build:local`; run the existing local API/site setup described in `web/scripts/e2e.ts`, then `node scripts/e2e.ts <local-site-url> <local-api-url> <chrome-path>` from `web/`. Expect final `e2e_done` with `failed: 0`. Use local D1 and no live provider/payment calls; stop owned local processes afterward. |
| DIFF | `git diff --check` — no whitespace errors; inspect the diff and changed-path list for scope and accidental credentials. |

There is no established Swift/server/web lint script to invent here. Keep compiler/type checks, repository scripts and CI checks. Use existing integration fixtures, fake upstreams and provider fakes; paid cloud/model tests are not default requirements. For device launches, deep links and screenshots use the available device tools; builds/installs/test runners may use Xcode tooling. Never stop a running user recording to free an audio device.

## P00 — Capture baseline and closure criteria

**Files:** Read `AGENTS.md`, `REVIEW.md`, `.github/workflows/ci.yml`, `.github/workflows/nightly.yml`, package manifests and this plan/spec. Update only task evidence and the spec registry as work completes.
**Dependencies:** None.

- [ ] Record current HEAD/worktree state and run CORE + LINK before the first code slice; run SERVER/WEB baseline before those domains change. Existing failures get a diagnostic and block that domain's completion.
- [ ] For each package, identify already-covered scenarios before adding tests. Preserve existing fixtures, environment gates and the local-service strategy.
- [ ] Record one primary owner per registry label and classify implementation outcomes as fixed regression, extracted protocol, or verified/retained state. Cross-links are dependencies, not duplicate completion claims.
- [ ] Record platform/device availability. Real dictation, Watch file delivery and experimental call capture remain explicit acceptance requirements if those adapters change; unavailable hardware is a blocker to those claims.
- [ ] Verify DIFF. Commit only deliberate plan/evidence changes; keep unrelated documents untouched.

## P01 — Commit results and recover paid processing safely

**Files:** Modify `Core/Meeting/ProcessMeeting.swift`, `ProcessingCheckpoint.swift`, `MeetingCheckpointWriter.swift`, `MeetingStore.swift`, `ChunkedNote.swift`; `Core/Hosted/HostedFinalTranscriber.swift`, `HostedFinalPassProgress.swift`; `App/AppModel.swift`, `iOS/PhoneRecorder.swift`, `iOS/AINotepadiOSApp.swift`. Create `Core/Meeting/MeetingCommit.swift`, `MeetingCommitAdapter.swift`, `ProcessingRecovery.swift`, `MeetingWorkLifecycle.swift`, `MeetingQueueLifecycle.swift`. Tests: extend `CoreTests/ProcessMeetingTests.swift`, `MeetingStoreTests.swift`, `MeetingJobsTests.swift`, `LongMeetingTests.swift`, `LongMeetingFollowupTests.swift`, `HostedOfflineTests.swift`; create `MeetingCommitTests.swift`, `MeetingCommitIntegrationTests.swift`, `MeetingWorkLifecycleTests.swift`, `MeetingQueueLifecycleTests.swift`.
**Dependencies:** P00. Reuse existing recording/account scope IDs; P10 later strengthens handover checks.
**Interfaces:** `commitMeetingWork(request: MeetingCommitRequest) throws -> MeetingCommitOutcome`; `mergingPendingMeetingMarks(record: MeetingRecord, marks: PendingMeetingMarks) -> MeetingRecord`; `acknowledgingPersistedMeetingMarks(pending: PendingMeetingMarks, persisted: PendingMeetingMarks) -> PendingMeetingMarks`; `processingRecoveryPlan(facts: ProcessingRecoveryFacts) -> ProcessingRecoveryPlan`; `meetingWorkStep(state: MeetingWorkState, event: MeetingWorkEvent) -> MeetingWorkTransition`; `meetingQueueStep(state: MeetingQueueState, event: MeetingQueueEvent) -> MeetingQueueTransition`.

**Verification cases:** `failedFinalSaveRetainsPendingMarksAndRecovery`, `supersededCommitCannotAcknowledgeMarks`, `newMarksSurviveOlderCommitAcknowledgement`, `restartReusesCompletedPaidChunks`: assert actual file contents/receipts, emitted effects and call counts; resource cleanup remains owner-specific.

- [x] **P01a, first PR:** Characterize final-save failure after pending sent/task/reminder marks are read, including whether each mark already exists on disk. Use real temporary directories and an explicit save failure. Assert no ready notification/automatic send precedes a successful save.
- [x] Extract the narrow filesystem seam `MeetingCommitAdapter.swift`, called by both App final-save paths. `MeetingCommitRequest` carries the merged record, pending-mark snapshot, directory, work ID and existing `MeetingWriteTicket`; `MeetingCommitOutcome` is `persisted(MeetingCommitReceipt)` or `superseded`. Return a receipt only after `saveMeeting(record:directory:ticket:)` confirms the write. A thrown write or superseded ticket emits no durable-completion acknowledgement. Test this exact seam against a real temporary directory with a deliberately invalid destination and an older ticket; reducer-only tests and app builds cannot establish this behavior.
- [ ] Make mark merging pure. Each pending mark has a stable receipt/mark identity; snapshot marks without consuming them; acknowledge only the exact successfully persisted snapshot, preserving newer arrivals. If process termination can lose an accepted external receipt, add the smallest reviewed durable journal in a separate compatibility PR; do not close this requirement with in-memory retention alone.
- [ ] Keep the existing `MeetingJobs` lock. Route both app adapters through the tested commit outcome; only `persisted` may acknowledge its snapshot, publish ready/send effects or delete durable recovery/receipt evidence. Failed or superseded attempts still release their own job/task/keep-awake resources; they retain checkpoints/pending marks and cannot release a replacement work ID. Test emitted effects from `meetingWorkStep` for failed, superseded and persisted outcomes, then inspect adapter wiring and perform the focused app smoke. Make final save success the barrier for marking durable completion, clearing recovery data and releasing the result to dependent actions; resource release on failure is a separate obligation. A failure retains resumable evidence and surfaces its cause.
**P01a evidence (branch `claude/practical-hawking-oqmzmi-p01a`):**

- *Hypothesis reproduced (by reading the code; the private App path has no test seam).* A mark of an external action that completes while a job locks the meeting (note sent, tracker tasks created, Reminders entry) existed only in memory. It was **not** on disk. The Mac's `applyingPendingReminders` removed the marks from their three dictionaries before the job's final `saveRecord`. `process` returned without them when that save failed. `editNote` and `rewriteNote` ignored the save result. `savePendingMarks` consumed them inside `updateRecordFromDisk`. On iPhone, `PhoneIntegrations.flushPendingMarks` cleared each entry before `writeMarks`, which swallowed its error. In every case the meeting unlocked without the mark: the automatic-send planner, or the user, could send the note again or create the tasks again. An unlocked mark whose write failed was lost the same way.
- *Ready/send ordering.* `process` already ran `autoSendToDestinations`, `meetingNoteReady` and `EngagementNotifier.meetingProcessed` only after the final save succeeded. This is kept: they now follow a `persisted` commit, and a `superseded` commit takes the failed-save branch (checkpoint kept, hosted queue cooldown, resume attempts kept).
- *Fix.*
  - Core `Meeting/MeetingCommit.swift`: `PendingMeetingMarks`, a list of marks with stable IDs, and the pure functions `mergingPendingMeetingMarks` and `acknowledgingPersistedMeetingMarks`. The merge writes the marks in the same order as before.
  - Core `Meeting/MeetingCommitAdapter.swift`: `commitMeetingWork` returns `persisted(receipt)` only after `saveMeeting(record:directory:ticket:)` confirms the write.
  - Mac `AppModel`: one `heldMarks` store replaces the three dictionaries. A snapshot is taken without consuming the marks. The final saves of processing, edit, rewrite and held-mark writes go through `commitRecord`, with the ticket claimed when the record is assembled. Only a persisted commit updates the list and acknowledges its snapshot. A failed unlocked write holds the mark. The automatic-send round first retries held marks (`flushHeldMarks`). Deleting a meeting drops its held marks.
  - iPhone `PhoneIntegrations`: holds the marks, writes them through the same seam, and acknowledges only the written snapshot.
  - No file or wire format changes; no new user-facing strings.
- *Tests.* `CoreTests/MeetingCommitTests.swift`, against real temporary directories:
  - `mergeMatchesFormerMarkOrder`
  - `failedFinalSaveRetainsPendingMarksAndRecovery`: the destination folder is missing; the commit throws, the earlier `meeting.json` is unchanged, and a retry persists every mark once.
  - `supersededCommitCannotAcknowledgeMarks`: an older ticket, with the newer content kept.
  - `newMarksSurviveOlderCommitAcknowledgement`
- *Independent review* (separate reviewer agent; AI, not human). It confirmed the defect on both platforms and agreed with the design. The changes it asked for were adopted:
  - claim the ticket when the record is assembled, not at write time;
  - treat `superseded` like a failed save;
  - keep the list update and reloader invalidation in the App adapter;
  - retry held marks on unlocked paths and at the automatic-send round;
  - drop held marks on deletion;
  - hold a mark whose unlocked write failed.

  Its residual point is open. Until the next round writes a held mark, manual "send" buttons read only the record, so the user can still send by hand.
- *Open in P01a.*
  - (1) **Process termination** while a mark is held still loses it: the marks are in memory only. Per this plan, a separate reviewed compatibility PR must add the smallest durable journal. The P01 requirement stays open until then.
  - (2) `meetingWorkStep` effect modelling (`MeetingWorkLifecycle.swift`) is a follow-up PR.
  - (3) The focused macOS/iPhone app smoke is not run: no Apple environment here.
- *Verification.* Swift compiles and tests ran only on the PR's macOS CI jobs (`test-and-build`: CORE, LINK, Mac, Gistsmith Debug/Release; `ios`: iPhone Debug/Release Simulator); the run is linked in the PR. No local Swift build was possible. DIFF: `git diff --check` clean.

- [ ] **P01b, second PR:** Derive resume decisions from actual checkpoint fingerprint, chunk results and files. Preserve upload keys and completed part results. Keep conversion, transcription and speaker work independent; do not serialize existing parallelism.
- [ ] Test restart after each paid chunk checkpoint, before/after final save, and during note overview. Assert completed billed chunks are not repeated, incompatible progress is invalidated precisely, older checkpoint tickets cannot overwrite newer final state, and original audio is removed only after a durable replacement exists.
- [ ] **P01c, queue PR:** Keep existing automatic-retry/import/offline eligibility functions. Model idle, selected/preparing meeting and coalesced rerun explicitly. Test duplicate network/import triggers, one admission at a time, manual retry clearing only its cooldown, exhausted automatic retry limits and account/live-recording changes before admission. Extend existing offline/retry/import-policy tests; reopen persisted retry history; do not replace it with an in-memory counter.
- [ ] Run CORE + LINK + MAC + HOSTED + IOS + DIFF; use the repo's local fake-upstream hosted smoke when transport behavior changes. Record whether the pending-mark hypothesis was reproduced or disproved.

## P02 — Bind recorder resources, admission and shutdown to recording identity

**Files:** Modify `App/AppModel.swift`, `App/Hosted/HostedAccount.swift`, `App/ScreenSnapshots.swift`, `iOS/PhoneRecorder.swift`; create `Core/Session/RecordingResources.swift`, `ModelPreparationLifecycle.swift`, `Core/Hosted/HostedMeetingLifecycle.swift`. Tests: extend `CoreTests/RecordingReliabilityTests.swift`, `LifecycleRulesTests.swift`, `RecorderStateMachineTests.swift`, `HostedSessionTests.swift`, `HostedPauseReportsTests.swift`; create `RecordingResourceTests.swift`.
**Dependencies:** P01; P03–P05 supply deeper transport/capture guarantees afterward. Preserve `RecorderStateMachine`, microphone/screen reducers and pause queue rules.
**Interfaces:** `recordingResourceStep(state: RecordingResourceState, event: RecordingResourceEvent) -> RecordingResourceTransition`; `hostedAdmissionStep(state: HostedAdmissionState, event: HostedAdmissionEvent) -> HostedAdmissionTransition`; `pauseWorkerStep(state: PauseWorkerState, event: PauseWorkerEvent) -> PauseWorkerTransition`; `modelPreparationStep(state: ModelPreparationState, event: ModelPreparationEvent) -> ModelPreparationTransition`.

**Verification cases:** `staleMicrophoneAdmissionClosesOnlyOldCapture`, `sharedPreparationSurvivesOneConsumerStop`, `oldMeetingCloseKeepsNewRecording`: assert acquired/released identities, live preparation joiners and unchanged replacement ownership.

- [ ] Characterize stop/cancel while preparing a local model, awaiting microphone permission, acquiring a hosted token and attaching a late microphone. A stale success must release its resources and never join another recording.
- [ ] Give shared model preparation an engine/configuration identity and a set of consumer identities. Concurrent consumers join one preparation; stopping one recording detaches that consumer without cancelling preparation still needed by dictation/another owner. Test concurrent joiners, last-consumer cancellation and engine switch with late old completion. Keep the shared preparation resource outside any one recording's resource record.
- [ ] Keep actual session/capture/tasks in recording-keyed adapter resource records. Distinguish admitted resources from pending acquisitions and completion waiters. Derive UI flags from the existing recorder state plus resource observations.
- [ ] Preserve hosted orphan/open-meeting ledger, offline permit and pause-order semantics. Old close/resume callbacks cannot clear a new recording or strand token waiters. Screen binding and first-success telemetry remain subprotocols of the existing capture effect.
- [ ] Test one outage escalation per outage, stop during reconnect, repeated stop, failed admission, pause report retry and all waiter terminal outcomes. Do not claim a package test exercises AppKit observer wiring; perform a focused macOS/Hosted stop-start smoke.
- [ ] Run CORE + LINK + MAC + HOSTED + IOS + DIFF. Preserve App shutdown behavior until all acquired recording resources have matching release evidence.

## P03 — Make Deepgram connection and replay decisions explicit

**Files:** Modify `Core/Cloud/DeepgramStream.swift`, `DeferredDeepgramStream.swift`; create `DeepgramLifecycle.swift`, `DeepgramAudioLifecycle.swift` in that directory. Extend `CoreTests/DeepgramShutdownTests.swift`, `DeepgramStreamTests.swift`, `DeferredDeepgramStreamTests.swift`, `DeepgramMessageTests.swift`.
**Dependencies:** P00; integrate with P02 without concurrent App edits.
**Interfaces:** `deepgramLifecycleStep(state: DeepgramLifecycleState, event: DeepgramLifecycleEvent) -> DeepgramLifecycleTransition`; `deepgramAudioStep(state: DeepgramAudioState, event: DeepgramAudioEvent) -> DeepgramAudioTransition`.

**Verification cases:** `closeDuringReconnectRejectsLateSocket`, `reconnectReplaysOnlyUnacknowledgedAudio`: assert socket-open count, sample offsets, visible finals and terminal completion count.

- [ ] Use existing gates/local WebSocket tests to pin connect, reconnect, language-switch, drain/CloseStream, abort and deadline behavior before extraction.
- [ ] Keep connection control separate from pending/in-flight/unacknowledged audio and replay watermarks. Pure state carries offsets/metadata; keep PCM storage in the adapter to avoid repeated queue/array copies.
- [ ] Bind socket/token/receiver/watchdog effects to a connection generation. Closing/invalidation rejects a late open; deferred first non-silent audio cannot open after cancellation.
- [ ] Assert FIFO replay of unacknowledged audio, no replay of acknowledged samples, no duplicate visible finals, at most one concurrent audio sender, and terminal finish exactly once after all close races. Compare throughput/allocation behavior with the baseline if buffer representation changes.
- [ ] Run CORE + LINK + MAC + HOSTED + DIFF. Keep the deployed Deepgram message protocol unchanged.

## P04 — Model live backend drain, language ownership and recording sinks

**Files:** Modify `Core/Session/HybridLiveSession.swift`, `CloudLiveSession.swift`, `LiveSession.swift`, `Core/Audio/CafRecorder.swift`; create `Core/Session/LivePipelineLifecycle.swift`. Extend `CoreTests/HybridLiveSessionTests.swift`, `CloudLiveSessionTests.swift`, `LiveSessionTests.swift`; create `LivePipelineLifecycleTests.swift` for extracted decisions only.
**Dependencies:** P03 and P02 contract.
**Interfaces:** `livePipelineStep(state: LivePipelineState, event: LivePipelineEvent) -> LivePipelineTransition`; `liveLanguageStep(state: LiveLanguageState, event: LiveLanguageEvent) -> LiveLanguageTransition`.

**Verification cases:** `stopDuringLocalPreparationDrainsEveryConsumer`, `manualLanguageWinsOverLateDetection`: assert no consumer leak, preserved final-window work and the selected language.

- [ ] Preserve `HybridBackend`. Model pending local preparation, per-speaker attachment and active-consumer drain separately from backend selection; a new global linear phase must not erase their combinations.
- [ ] Stop periodic/new-input scheduling on end while preserving final queued transcription and the bounded final diarization window; flush producers, finish the job stream, drain workers, then finish output. Manual language choice invalidates older automatic detections.
- [ ] Characterize existing per-speaker CAF failure behavior. Keep its open/append/close contract with CORE-C07/C22; introduce no separate product FSM unless an interleaving requires it. Surface the original write error and retain the documented session outcome.
- [ ] Test stop during backend preparation, speaker detach/reattach, late partial after final, manual language while queued audio exists, failure during final flush and sink close exactly once. Confirm every consumer exits before drain reports completion.
- [ ] Run CORE + LINK + MAC + HOSTED + DIFF; perform a capture-to-finish smoke for changed audio adapters.

## P05 — Make system-audio resource recovery generation-safe

**Files:** Modify `Core/Audio/SystemAudioCapture.swift`; create `Core/Audio/SystemAudioLifecycle.swift`, `CoreTests/SystemAudioLifecycleTests.swift`. Reuse existing audio capture/device tests.
**Dependencies:** P00; P02 consumes resource observations.
**Interface:** `systemAudioStep(state: SystemAudioState, event: SystemAudioEvent) -> SystemAudioTransition`.

**Verification cases:** `stopDuringRebuildReleasesOnlyOwnedDevices`: assert tap/device/listener release identity and no restart after terminal stop.

- [ ] Inventory tap, aggregate device, IO proc and listener acquisition/release order. Represent partial acquisition and rebuild generation without storing CoreAudio objects in pure state.
- [ ] Ensure stop invalidates queued rebuilds and IO mismatch callbacks. A stale device rebuild releases only its acquired resources; a persistent tap is not released by an old aggregate's completion.
- [ ] Test failure after each acquisition, stop during backoff/rebuild and repeated mismatch reports using pure observations plus existing adapter seams. Run an input/output-change capture smoke on available hardware; do not fabricate system-device evidence from a reducer test.
- [ ] Run CORE + LINK + MAC + HOSTED + DIFF. Record any unavailable device smoke as a limitation/blocker for the affected adapter claim.

## P06 — Isolate playback intent and macOS dictation/hot-key custody

**Files:** Modify `UI/MeetingAudioPlayer.swift`, `App/Dictation.swift`, `App/HotKeys.swift`; create `UI/PlaybackLifecycle.swift`, `Core/Dictation/DictationExecution.swift`. Extend `UITests/NowPlayingTests.swift`, `CoreTests/DictationTests.swift`; create `UITests/PlaybackLifecycleTests.swift`, `CoreTests/DictationExecutionTests.swift`.
**Dependencies:** P02/P04; shared Ask dictation is handled by P19.
**Interfaces:** `playbackStep(state: PlaybackState, event: PlaybackEvent) -> PlaybackTransition`; `dictationExecutionStep(state: DictationExecutionState, event: DictationExecutionEvent) -> DictationExecutionTransition`.

**Verification cases:** `activationAfterPauseDoesNotPlay`, `cancelledDictationCannotInsertIntoReplacementField`: assert emitted player/delivery actions and owned clipboard cleanup.

- [ ] **P06a:** Preserve playback intent separately from actual AVAudioSession/player activity. Test activation completing after pause/stop, interruption resume eligibility, route removal and loading a replacement meeting.
- [ ] **P06b:** Retain existing explicit key gesture logic. Bind dictation preparation/capture/transcription/delivery and clipboard conditional restoration to one attempt. Hot-key suspension has one owner, and nested presentation cannot register duplicate handlers.
- [ ] Test cancel before microphone starts, cancel during transcription, delivery after focus owner changed, release versus transcription completion and original clipboard restoration only when still owned. Use a macOS focused text-field smoke for AppKit insertion/IME behavior.
- [ ] Run CORE + LINK + MAC + HOSTED + IOS + DIFF. Device speech recognition stays environment-gated and is required only to claim real speech output.

## P07 — Own live translation, assistant, prompt and foreground scheduling

**Files:** Modify `App/AppModel.swift`, `App/MeetingNotifier.swift`, `iOS/PhoneRecorder.swift`, `iOS/PhoneCalendar.swift`; preserve `Core/Session/LiveTranslationQueue.swift`, `BackgroundLiveUpdates.swift`. Create `Core/Session/LiveWorkLifecycle.swift`, `MeetingPromptLifecycle.swift`. Extend `CoreTests/TranslationUnitTests.swift`, `TranscriptTranslationTests.swift`, `BackgroundRecordingTests.swift`, `CalendarMeetingTests.swift`.
**Dependencies:** P01/P02/P04; use current scope until P10 completes.
**Interfaces:** `liveWorkStep(state: LiveWorkState, event: LiveWorkEvent) -> LiveWorkTransition`; `meetingPromptStep(state: MeetingPromptState, event: MeetingPromptEvent) -> MeetingPromptTransition`.

**Verification cases:** `oldTranslationCannotReleaseNewSlot`, `promptReasonIsConsumedOncePerRecording`: assert current slot counts, output provenance and notification target IDs.

- [ ] Preserve existing translation builders/queue transformations. Give each running slot an attempt and recording ID; a stale completion releases only its slot and cannot alter a replacement recording's counters or output.
- [ ] Keep live assistant card phases; represent request replacement/close ownership separately. Preserve background buffering and foreground flush through `BackgroundLiveUpdates` rather than parallel copies.
- [ ] Keep calendar enablement and prompt reason history distinct. A reason is consumed once per recording, continue rearms the correct silence history, and a late notification/calendar callback cannot start or target a replacement recording.
- [ ] Test translation disable/end/drain with in-flight work, generation replacement, cancelled assistant result, background partial flush and repeated prompt triggers. Live Activity events are consumed by P14's activity adapter contract.
- [ ] Run CORE + LINK + MAC + HOSTED + IOS + DIFF. Split translation and prompt/calendar adapter changes into separate PRs if both require new models.

## P08 — Make iOS background leases match processing work

**Files:** Modify `iOS/PhoneRecorder.swift`, `iOS/ProcessingResume.swift`; create `Core/Meeting/ProcessingLease.swift`, `CoreTests/ProcessingLeaseTests.swift`. Extend `CoreTests/BackgroundRecordingTests.swift`, `MeetingJobsTests.swift`.
**Dependencies:** P01 and P02; do not store UIKit/BGTask handles in Core.
**Interface:** `processingLeaseStep(state: ProcessingLeaseState, event: ProcessingLeaseEvent) -> ProcessingLeaseTransition`.

**Verification cases:** `lateBackgroundLeaseCompletesWithoutReplacingCurrentLease`, `expiredLeaseKeepsProcessingCheckpoint`: assert matching handle completions and durable resumable status.

- [ ] Bind UIKit and continued-processing handles to meeting/work attempt IDs. Keep job ownership separate from lease availability, and preserve iOS availability guards.
- [ ] Test BG delivery after work completed, duplicate task delivery, expiration during save, cancellation while waiting for network, and old lease expiration after a new retry. Each handle completes/releases once without replacing another live handle.
- [ ] Persist resumable processing before expiration cleanup. Note retry after suspension must reuse finished transcription/checkpoints from P01.
- [ ] Run CORE + LINK + IOS Debug/Release + DIFF; exercise foreground → background → resume using the existing device/test setup. A deterministic lease model test is not evidence that the OS grants runtime.

## P09 — Consolidate credential refresh and account-load generations

**Files:** Modify `Core/Hosted/HostedClient.swift`, `HostedTokenRefresh.swift`, `App/Hosted/HostedAccount.swift`; create `Core/Hosted/HostedRefreshLifecycle.swift`. Extend `CoreTests/HostedTests.swift`, `HostedAccountLoadTests.swift`, `HostedSessionTests.swift`.
**Dependencies:** P01/P02. Sensitive auth change: stop/report before shipping.
**Interface:** `hostedRefreshStep(state: HostedRefreshState, event: HostedRefreshEvent) -> HostedRefreshTransition`.

**Verification cases:** `oldRefreshCannotPersistIntoNewSession`: assert stored tokens, current account-load result and each waiter terminal outcome.

- [ ] Keep current token-action/cache helpers. Make single-flight refresh ownership and account-load attempt generation explicit without adding a second session authority.
- [ ] Test simultaneous refresh joiners, logout during refresh, old 401 after new login, A → B → A, rejected refresh and storage-write failure. Old completions cannot save tokens, clear the new session or consume its waiters.
- [ ] Preserve current repeatable versus one-shot request retry boundaries. Log attempt/request identity and status safely; never log tokens.
- [ ] Run CORE + LINK + MAC + HOSTED + IOS + DIFF, plus the local hosted auth smoke. Record independent auth review and the concrete shipping checkpoint.

## P10 — Establish one account-session owner and writer handover barrier

**Files:** Modify `Core/Support/AccountData.swift`, `App/Hosted/HostedAccount.swift`, `App/Hosted/HostedAccountScope.swift`, `App/AINotepadApp.swift`, `App/AppUpdater.swift`, `iOS/AINotepadiOSApp.swift`, `iOS/Purchases/AppStorePurchases.swift`; create `Core/Support/AccountSessionLifecycle.swift`. Extend `CoreTests/AccountDataTests.swift`, `HostedAppStoreTests.swift`, `PhoneAppGateTests.swift`; create `AccountSessionLifecycleTests.swift`.
**Dependencies:** P01/P02/P09; P11 applies the resulting owner to retained/local file transactions. Sensitive auth/purchase-identity change: stop/report before shipping.
**Interface:** `accountSessionStep(state: AccountSessionState, event: AccountSessionEvent) -> AccountSessionTransition`. `AccountSessionOwner` is a concrete immutable value with `accountKey: String` and `epoch: UUID`, supplied by the installing adapter. Existing `HostedScopeStamp` carries a feature-center generation rather than an installed-session epoch; keep it for feature runs and bind those runs to the session owner. The installed session is the sole source of the epoch, so A → B → A cannot reuse A's first owner. This Core type never enters KeyboardCore or WatchLink: their Foundation-only local stamps carry opaque account tags/UUIDs supplied by adapters. Epochs fence in-process callbacks; persisted offline/Watch work keeps its durable account key/tag and is readmitted under a fresh epoch after revalidation, preserving its paid-work/idempotency identifiers.

**Verification cases:** `firstAccountEpochCannotPublishAfterAToBToA`, `purchaseWaitsForRequestedIdentity`: assert installed owner, storage path and SDK operation order.

- [ ] Preserve `accountDataTransition`, `accountSwitchReadiness`, `ClosedAccountWriters` and hosted session policy. Centralize only requested switch → writer quiescence → adapter closure → prepared storage → installed session → loaded publication.
- [ ] Ensure failed preparation cannot publish half a new session; A → B → A rejects A's first epoch. Quit/update relaunch uses the same writer barrier instead of a separate readiness copy.
- [ ] Keep the legacy claim decision. Characterize partial file movement and retry under the claim owner; a separate migration/filesystem compatibility PR is required if durable progress cannot be reconstructed safely.
- [ ] Preserve RevenueCat identity serialization. Purchases/restores wait for the requested identity; identity failure prevents purchase. Never change paywall phases or purchase products as part of this slice.
- [ ] Test last-writer release, rapid switch replacement, failed resource closure, partial migration and purchase requested during A → logout → B. Run CORE + LINK + MAC + HOSTED + IOS + DIFF and a session-switch smoke.

## P11 — Make local file, import and retention custody recoverable

**Files:** Modify `Core/Support/CloudStorage.swift`, `DeletedAccountData.swift`, `Core/Meeting/RecentlyDeleted.swift`, `App/Hosted/HostedDeletedMeetings.swift`, `iOS/PhoneSharedFiles.swift`, `iOS/PhoneImport.swift`; create `Core/Meeting/SharedFileImportState.swift`, `StorageMovePlan.swift`. Extend `CoreTests/RecentlyDeletedTests.swift`, `DeletedAccountDataTests.swift`, `AccountDataTests.swift`, `MediaImportTests.swift`; create `SharedFileImportStateTests.swift`, `StorageMovePlanTests.swift`.
**Dependencies:** P01/P10; coordinate Watch inbox ownership with P16.
**Interfaces:** `sharedFileImportStep(state: SharedFileImportState, event: SharedFileImportEvent) -> SharedFileImportTransition`; `storageMovePlan(facts: StorageMoveFacts) -> StorageMovePlan`.

**Verification cases:** `scanAndOpenURLStartOneImport`, `copyBackFailureKeepsCloudLocation`: assert deduplicated work, real source/destination files and retained recoverable artifacts.

- [ ] **P11a:** Represent shared-file discovered/queued/in-progress/committed/rejected custody without duplicating picker UI. Scan + open-URL for the same file starts one import; taking pending files does not release in-progress deduplication.
- [ ] Test restart before/after copy, failed import and deferred Photos/file-picker presentation. Retain the source until a durable import or explicit rejection makes removal safe; ownership checks precede every account-bound publication.
- [ ] **P11b:** Characterize iCloud enable/disable/copy-back, recently-deleted move/restore/purge and retained deleted-account moves with real temp directories. Keep location authoritative if copy-back fails; incomplete moves/markers must be recoverable or visibly failed.
- [ ] Test each cross-file interruption, existing malformed entries, concurrent meeting writer eligibility and partial retained-file migration. Add a journal only if existing artifacts cannot support the required recovery; review format compatibility separately.
- [ ] Run CORE + LINK + MAC + HOSTED + IOS + DIFF. Account-layout/migration changes stop/report before shipping; simple adapter extraction does not itself change persisted layout.

## P12 — Own browser sign-in, connection setup and AI-consent reconciliation

**Files:** Modify `Core/Hosted/HostedBrowserSignIn.swift`, `Core/Integrations/LoopbackRedirect.swift`, `App/Hosted/HostedAccount.swift`, `App/Hosted/HostedAIConsentCenter.swift`, `App/ConnectionsSettings.swift`, `iOS/PhoneIntegrations.swift`, `iOS/PhoneConnectionsScreen.swift`; create `Core/Integrations/BrowserSignInLifecycle.swift`. Extend `CoreTests/HostedAIConsentTests.swift`, `CoreTests/MCPRemoteTests.swift`, `HostedTests.swift`, `StateInvariantTests.swift`; create `BrowserSignInLifecycleTests.swift`.
**Dependencies:** P09/P10; server enforcement remains P23. Sensitive auth/consent change: stop/report before shipping.
**Interface:** `browserSignInStep(state: BrowserSignInState, event: BrowserSignInEvent) -> BrowserSignInTransition`.

**Verification cases:** `oldBrowserCancellationCannotCancelReplacement`, `consentWithdrawalBlocksAdmission`: assert actual loopback completion count and no unauthorized AI request effect.

- [ ] Bind browser, loopback listener, callback and cancellation to one attempt. Late cancellation closes its own browser without cancelling a newer session; preserve actionable root failure instead of replacing it with generic cancellation.
- [ ] Reuse existing exactly-once listener/timeout primitives. Test callback/cancel/timeout races with real local loopback and deterministic gates; repeated completion must not resume a continuation twice.
- [ ] Preserve `HostedAIConsentCenter` and server consent authority. Characterize local-persist/server-reconcile order, withdrawal during a request and old-account consent completion. No AI request is admitted without applicable consent.
- [ ] Keep small connection-sheet phases; one setup attempt may publish channel/token/test status. Run CORE + LINK + MAC + HOSTED + IOS + SERVER for changed consent contracts + DIFF.

## P13 — Persist delivery receipts and partial tracker outcomes

**Files:** Modify `Core/Integrations/IntegrationSending.swift`, `NoteDestinations.swift`, `MCPIntegrations.swift`, `App/AppModel.swift`, `iOS/PhoneIntegrations.swift`; create `Core/Integrations/DeliveryAttempt.swift`. Extend `CoreTests/IntegrationSendingTests.swift`, `DestinationTests.swift`, `TrackerTargetTests.swift`; create `DeliveryAttemptTests.swift`.
**Dependencies:** P01/P10/P12. Credential persistence changes are sensitive and stop/report before shipping.
**Interface:** `deliveryAttemptStep(state: DeliveryAttemptState, event: DeliveryAttemptEvent) -> DeliveryAttemptTransition`.

**Verification cases:** `remoteSuccessAndLocalSaveFailureDoNotAutoResend`, `partialTrackerProgressKeepsCompletedTaskReceipts`: assert receiver calls and persisted confirmed/uncertain/partial evidence.

- [ ] Model per-owner/meeting/destination attempt separately from pass coalescing. Keep confirmed delivery, receipt pending, uncertain acceptance, permanent rejection, retryable failure and partial task creation distinct.
- [ ] Route receipt persistence through P01's successful-save acknowledgement. A meeting lock defers the receipt, never schedules the same automatic send again. Preserve per-connection token identity when refresh completes.
- [ ] Use a local HTTP receiver and real receipt files to test remote success/local save failure, timeout after acceptance, partial tracker creation, reconnect during token refresh and a rerun requested during a pass.
- [ ] Verify process restart at the request/receipt boundary. Where provider reconciliation cannot prove completion, persist uncertainty rather than retrying automatically. No generic backoff helper may turn that outcome into retryable failure.
- [ ] Run CORE + LINK + MAC + HOSTED + IOS + DIFF and the changed destination smoke. Record external idempotency capabilities per adapter without making live sends.

## P14 — Model keyboard microphone, cross-process insertion and Ask execution

**Files:** Modify `iOS/Keyboard/PhoneKeyboardHost.swift`, `PhoneKeyboardAsk.swift`, `PhoneKeyboardActivity.swift`, `iOSKeyboard/KeyboardViewController.swift`, `KeyboardAskController.swift`, and recording activity wiring in `iOS/PhoneRecorder.swift`; preserve existing `Keyboard/KeyboardHandoff.swift`, `KeyboardAskSheet.swift`, `KeyboardShared.swift`. Create `Keyboard/KeyboardSessionLifecycle.swift`, `KeyboardInsertion.swift`, `KeyboardAskExecution.swift`, `Core/Session/LiveActivityOwnership.swift`. Create `KeyboardTests/KeyboardSessionLifecycleTests.swift`, `KeyboardTests/KeyboardInsertionTests.swift`, `CoreTests/LiveActivityOwnershipTests.swift`; extend `KeyboardTests/KeyboardAskTests.swift`, `KeyboardTests/KeyboardAskStateTests.swift`, `KeyboardTests/KeyboardCallbackIsolationTests.swift`, `KeyboardTests/KeyboardCoreTests.swift`.
**Dependencies:** P02/P10/P12; Ask effects integrate with P19.
**Interfaces:** `keyboardSessionStep(state: KeyboardSessionState, event: KeyboardSessionEvent) -> KeyboardSessionTransition`; `keyboardDictationStep(state: KeyboardDictationState, event: KeyboardDictationEvent) -> KeyboardDictationTransition`; `keyboardInsertionStep(state: KeyboardInsertionState, event: KeyboardInsertionEvent) -> KeyboardInsertionTransition`; `keyboardAskExecutionStep(state: KeyboardAskExecutionState, event: KeyboardAskExecutionEvent) -> KeyboardAskExecutionTransition`; `liveActivityStep(state: LiveActivityState, event: LiveActivityEvent) -> LiveActivityTransition`. The activity model contains only logical binding/ID/revision values; ActivityKit objects remain in iOS adapters. KeyboardCore uses a module-local `KeyboardOwnerStamp` of opaque tag/epoch values, never a Core type or new dependency.

**Verification cases:** `sameRequestNewAttemptRejectsOldResult`, `documentSwitchPreventsOldInsertion`, `duplicateSignalStartsOneAsk`: assert owned resource cleanup, emitted text edits and billed-request count.

- [ ] **P14a:** Keep warm microphone ownership separate from a dictation attempt. Key resources by owner/session/attempt; two attempts sharing a request ID must remain distinguishable. First tap warms only; a delayed matching signal must not begin dictation unexpectedly.
- [ ] Test stop/lock/account switch/meeting start during opening and transcription. Late start success emits owner-specific cleanup; failure for A cannot end session B. Live Activity start/update/end carries activity and logical owner IDs; system-disabled activities never alter capture state.
- [ ] **P14b:** Represent request + document + marked-text + committed request ownership. Test partial replacement, final insertion once, cancellation/document switch and acknowledgement cleanup; an old result never removes or inserts text in a new field.
- [ ] **P14c:** Retain the Ask sheet reducer; add only accepted/running/persisted/released execution ownership. Test duplicate deep link + Darwin signal, foreground adoption, release during answer and expiry.
- [ ] Keep process-local epochs out of persisted queue authority. Bind recovered requests to the existing durable account/request evidence, revalidate it, then admit a fresh local attempt. Preserve current JSON payloads/file names and add old-extension/current-app compatibility fixtures. No new KeyboardCore dependency. Run CORE + LINK + IOS + DIFF; validate actual speech insertion on iPhone hardware. Simulator can certify handoff UI, not transcription output.

## P15 — Extract keyboard touch/editing rules and retain setup policy

**Files:** Modify `iOSKeyboard/KeyboardGridView.swift`, `KeyboardViewController.swift`, `iOS/Keyboard/PhoneKeyboardSetupFlow.swift`; create `Keyboard/KeyboardTouchState.swift`, `KeyboardEditingState.swift`. Create `KeyboardTests/KeyboardTouchStateTests.swift`, `KeyboardEditingStateTests.swift`; extend `KeyboardCoreTests.swift`, `KeyboardSwipeTests.swift`, `KeyboardSetupTests.swift`.
**Dependencies:** P00; P14 for dictation readiness facts only.
**Interfaces:** `keyboardTouchStep(state: KeyboardTouchState, event: KeyboardTouchEvent) -> KeyboardTouchTransition`; `keyboardEditingStep(state: KeyboardEditingState, event: KeyboardEditingEvent) -> KeyboardEditingTransition`.

**Verification cases:** `secondFingerCommitsFirstTouchOnce`, `deleteTickAfterReleaseDoesNothing`: assert exact edit actions; field-change history must reset correction/punctuation eligibility.

- [ ] Keep UIKit hit testing/input effects in the extension. Pure touch rules distinguish pending/committed tap, alternatives, swipe, cursor drag and an owner-tagged delete timer.
- [ ] Test second-finger early commit once, cancellation after commit, swipe versus long press, cursor drag suppressing space and stale delete ticks after release. Preserve current thresholds and supplied timestamps.
- [ ] Preserve text-rule functions. Test caps-lock timing, correction undo/rejection and double-space reset on field change. Do not combine unrelated editing histories into one global phase.
- [ ] Retain `keyboardSetupStep` and documented setup evidence. Associate fact collection with its event/age; do not infer undocumented input-mode identifiers.
- [ ] Run CORE + LINK + IOS + DIFF; perform extension tap/swipe/field-switch smoke. Run the existing opt-in swipe benchmark only if recognition/geometry performance changes.

## P16 — Preserve Watch capture and transfer file custody

**Files:** Modify `Watch/App/WatchAppModel.swift`, `WatchRecorder.swift`, `Watch/Shared/WatchShared.swift`, `iOS/PhoneWatchLink.swift`; preserve `Link/WatchLogic.swift`, `WatchImport.swift`, `WatchLink.swift`. Create `Link/WatchCaptureLifecycle.swift`; create `LinkTests/WatchCaptureLifecycleTests.swift`; extend `LinkTests/WatchStateMachineTests.swift`, `WatchLinkTests.swift`, `Watch/Tests/WatchRecorderTests.swift`, `WatchModelIsolationTests.swift`, `CoreTests/WatchRecordingImportTests.swift`.
**Dependencies:** P01/P10/P11. Keep transfer/import reducers authoritative. WatchLink uses Foundation-only module-local owner/tag values, never `AccountSessionOwner` or a Core import.
**Interface:** `watchCaptureStep(state: WatchCaptureState, event: WatchCaptureEvent) -> WatchCaptureTransition`. Existing inbox-pass and snapshot revisions remain compact typed values; extract `watchInboxStep(state: WatchInboxState, event: WatchInboxEvent) -> WatchInboxTransition` only for the missing coalescing decision.

**Verification cases:** `deleteDuringCompressionDoesNotTransferOutput`, `failedSnapshotPushDoesNotAdvanceSentRevision`: assert real file custody, transfer-token ownership and snapshot revision.

- [ ] Bind permission/start/capture/recovery to an attempt, with durable running metadata. Late permission or interrupted capture cannot leave an active flag without its owned recorder/file.
- [ ] Keep CAF/M4A/compression/transfer token custody explicit around existing transfer states. Test deletion during compression, stale transfer callback after retry and restart with raw/compressed/queued combinations; remove local audio only after the phone-held acknowledgement policy is satisfied.
- [ ] Preserve fresh deferred-start intent and optimistic task marks. Require the correct account snapshot to acknowledge marks. Test request/reply success, failure, lost reachability and a late old reply after replacement; only its owner/request may clear sending state or publish its error. Inbox arrival during a pass requests one follow-up; failed snapshot push must not advance the sent revision.
- [ ] Characterize a queued `completeTask` across account switch before claiming cross-account safety. The current payload has meeting/task IDs without an account tag; a new in-memory epoch cannot recover its original owner. If existing durable evidence cannot prove the owner, a separate additive/versioned compatible message-envelope PR is required. Carry the durable account tag for mutating commands, test old/new endpoint combinations, and return an explicit stale-context failure plus snapshot refresh for an unscoped mutating command whose owner cannot be proved; never silently execute it under the current account. Keep the program blocked until this boundary is resolved.
- [ ] Run CORE + LINK + IOS + WATCH + DIFF and Watch adapter tests with the repo's permission/install setup. Complete paired-hardware file transfer proof; Simulator `transferFile` is not reliable acceptance evidence. Keep deployed decoding/read-only message behavior compatible; any necessary ownership envelope follows the separate compatibility PR above.

## P17 — Own client sync passes, dirty generations and reload coalescing

**Files:** Modify `Core/Sync/SyncEngine.swift`, `SyncEnginePlan.swift`, `SyncLedger.swift`, `Core/Meeting/MeetingReloader.swift`, `App/Hosted/HostedSync.swift`, `iOS/Hosted/PhoneSync.swift`; create `Core/Sync/SyncPassLifecycle.swift`, `Core/Meeting/MeetingReloadState.swift`. Extend `CoreTests/SyncEnginePlanTests.swift`, `SyncLedgerTests.swift`, `SyncMergeTests.swift`; create `MeetingReloadStateTests.swift`.
**Dependencies:** P01/P10/P11; server counterpart P21. Sensitive access/epoch changes require the shipping checkpoint.
**Interfaces:** `syncPassStep(state: SyncPassState, event: SyncPassEvent) -> SyncPassTransition`; `meetingReloadStep(state: MeetingReloadState, event: MeetingReloadEvent) -> MeetingReloadTransition`.

**Verification cases:** `editDuringUploadRemainsDirty`, `staleReloadCannotOverwriteLocalMutation`: assert persisted pending/cursor state and current record contents.

- [ ] Preserve pending/deferred files, merge bases and current engine open/stopped authority. Make debounce/pass/rerun ownership and per-item dirty generation explicit without replacing merge algorithms.
- [ ] Test edit during upload remains dirty, stopped engine starts no new IO, cursor commits only after applied writes, epoch/cursor reset and deferred download during a meeting writer. Reload bursts coalesce; stale disk results cannot overwrite a local mutation.
- [ ] Reopen the same ledger/files with a fresh adapter and resume partial work. Run CORE + LINK + MAC + HOSTED + IOS + DIFF and the existing local `HostedSyncE2E` path with fake upstreams when wire orchestration changes.

## P18 — Make assistant-copy reconciliation epoch-safe

**Files:** Modify `Core/Assistant/AssistantUploader.swift`, `AssistantPassSchedule.swift`, `App/Hosted/HostedAssistant.swift`, `iOS/Hosted/PhoneAssistant.swift`; create `Core/Assistant/AssistantUploadPlan.swift`. Extend `CoreTests/AssistantUploadTests.swift`, `SyncAssistantStateTests.swift`; use existing local `HostedAssistantE2ETests.swift` for changed wire orchestration.
**Dependencies:** P10/P17; server access/publication in P21/P23. Access/privacy changes receive explicit review and stop/report before shipping when auth or migration behavior changes.
**Interface:** `assistantUploadPlan(facts: AssistantUploadFacts) -> AssistantUploadPlan`.

**Verification cases:** `forgottenEpochCannotRestoreAssistantLedger`: assert persisted uploaded/rejected entries, remote deletion/upload calls and current epoch.

- [ ] Preserve `AssistantPassSchedule` and durable uploaded/rejected fingerprints. Separate eligibility from in-flight IO; forget/reset/disable changes the expected epoch so an old pass cannot restore cleared ledger state.
- [ ] Test changed content after permanent rejection, manual retry, access loss, off/on, account switch and forget while upload/deletion runs. Confirm no stale completion resurrects a copy or clears new pending work.
- [ ] Run CORE + LINK + MAC + HOSTED + IOS + DIFF and relevant local assistant integration traces. Do not turn a permanent rejection into a silent retry loop.

## P19 — Isolate Ask, dictation and meeting-request ownership

**Files:** Modify `Core/LLM/LLMStream.swift`, `UI/AskStore.swift`, `AskDictation.swift`, `App/AskPage.swift`, `AskInputField.swift`, `App/MeetingsPages.swift`, `App/AppModel.swift`, `iOS/AskTab.swift`, `iOS/MeetingsTab.swift`, `iOS/MeetingNoteLanguage.swift`; create `UI/AskOwnership.swift`, `Core/Meeting/MeetingRequestOwnership.swift`. Extend `UITests/AskChatTests.swift`, `CoreTests/AskHistoryTests.swift`, `AskScopeTests.swift`, `MeetingAskFollowUpTests.swift`; create `UITests/AskOwnershipTests.swift`, `CoreTests/MeetingRequestOwnershipTests.swift`.
**Dependencies:** P01/P06/P10/P14. Keep exchange/card/follow-up visible phase types.
**Interfaces:** `askOwnershipStep(state: AskOwnershipState, event: AskOwnershipEvent) -> AskOwnershipTransition`; `meetingRequestStep(state: MeetingRequestState, event: MeetingRequestEvent) -> MeetingRequestTransition`.

**Verification cases:** `retiredAnswerCannotResaveReopenedChat`, `oldLanguageDraftCannotReplaceNewRequest`: assert persisted conversation ownership, note version and no post-visible-output retry.

- [ ] Bind answering/saving/retiring a conversation to one context and exchange ID. A retired callback cannot update or resave a reopened chat; sample-meeting participation still prevents persistence.
- [ ] Keep AskDictation phase and independent preparation resources; cancellation targets the captured composer owner. Preserve AppKit marked text and cursor/mention behavior.
- [ ] Tag translation, follow-up draft and speaker-review results with meeting, source version/language and request attempt. Old results cannot overwrite current edits or consume newer suggestions.
- [ ] Test leave/reopen during answer, cancel during model preparation, field replacement, old-language draft completing last and source note changing during translation. LLM retry remains legal only before visible output; never replay a partially shown answer.
- [ ] Split shared Ask ownership and meeting-request adapters into separate PRs. Run CORE + LINK + MAC + HOSTED + IOS + DIFF and focused composer/IME smoke for changed UI bridges.

## P20 — Name server reservation, streaming and upload decisions

**Files:** Modify `server/src/reservations.ts`, `server/src/llm/proxy.ts`, `server/src/transcribe.ts`, `server/src/transcriptionCache.ts`, `server/src/deepgram.ts`, `server/src/elevenLabsCapacity.ts`; create `server/src/usageReservationLifecycle.ts`, `server/src/llm/streamLifecycle.ts`, `server/src/audioUploadLifecycle.ts`. Extend `server/test/spend.test.ts`, `server/test/llm.test.ts`, `server/test/transcribe.test.ts`, `server/test/deepgram.test.ts`, `server/test/elevenLabs.test.ts`, `server/test/cleanup.test.ts`.
**Dependencies:** P00; P01/P03 align client retry/stop observations. Sensitive financial/accounting changes stop/report before shipping.
**Interfaces:** `reservationSettlementDecision(input: ReservationSettlementInput): ReservationSettlementDecision`; `streamTransition(state: StreamState, event: StreamEvent): StreamTransition`; `audioUploadTransition(state: AudioUploadState, event: AudioUploadEvent): AudioUploadTransition`.

**Verification cases:** "settling one reservation twice updates every counter once" and "HTTP success with failed upload never commits transcription": assert all D1 usage/spend rows and provider call counts.

- [ ] Characterize two settlement calls for one reservation, normal completion racing expiry, and account deletion during an upstream request. Assert every usage/spend counter, not only the reservation row.
- [ ] Keep D1 guards/transactions authoritative. If a counter can be applied twice, fix that specific atomicity boundary in a separate regression PR; extraction cannot certify idempotency by itself.
- [ ] Distinguish successful message stop, client disconnect, deadline and provider error for settlement. HTTP success is usable only with successful exact-length upload; client-close failure cannot skip accounting.
- [ ] Preserve transcription-key replay and cache limits; no provider re-call for a valid cached completion. Keep existing Deepgram grant and ElevenLabs snapshot phases; old reads cannot overwrite newer exhaustion or settlement observations.
- [ ] Reuse existing local D1/provider scenario harness. Run SERVER + WORKERS + DIFF; record independent accounting review and any separate migration/checkpoint requirement.

## P21 — Harden server sync/assistant publication and purge epochs

**Files:** Modify `server/src/sync.ts`, `server/src/cleanup.ts`, `server/src/assistant/store.ts`, `server/src/assistant/cleanup.ts`; create `server/src/syncLifecycle.ts`, `server/src/assistant/lifecycle.ts`. Extend `server/test/sync.test.ts`, `server/test/cleanup.test.ts`, `server/test/assistantApi.test.ts`, `server/test/assistantUnits.test.ts`, `server/test/assistantInert.test.ts`, `server/test/mcpSecurity.test.ts`.
**Dependencies:** P17/P18/P20; P23 consumes access/epoch semantics. Privacy/access changes need expert review; migration/auth changes stop/report before shipping.
**Interfaces:** `syncWriteDecision(input: SyncWriteInput): SyncWriteDecision`; `syncRetentionDecision(input: SyncRetentionInput): SyncRetentionDecision`; `assistantRetentionDecision(input: AssistantRetentionInput): AssistantRetentionDecision`. Typed inputs include expected owner/epoch/revision or access-loss mark; adapters enforce them again in SQL.

**Verification cases:** "old epoch purge preserves new epoch blobs" and "publication interruption is recoverable with fresh adapters": assert D1 references, R2 objects and discoverable remaining outbox work.

- [ ] **P21a, sync PR:** Preserve upload blob → CAS publish new reference → queue/delete old blob order. Test same-object conflict, tombstone/cursor bounds, pairing/recovery TTL and old-epoch retention racing reset/access restoration.
- [ ] **P21b, assistant PR:** Keep feature/access-loss retention distinct from object publication. Off/on invalidates stale upload and consent; D1 logical deletion denies reads/grants before physical purge completes.
- [ ] Reuse the same D1/R2 state with fresh adapter instances after upload-before-publish, publish-before-old-delete and partial-prefix-purge boundaries. A losing request removes only its own uploaded blob.
- [ ] Prove existing outboxes can discover unfinished cleanup. If a crash can leave an undiscoverable orphan, create a separately reviewed additive outbox/GC PR with two-Worker compatibility tests. Do not mark crash-safe cleanup complete while that gap remains.
- [ ] Run SERVER + WORKERS + DIFF and corresponding local client sync/assistant integration traces. No manual production migration or deployment.

## P22 — Reconcile encrypted-share creation, revocation and expiry

**Files:** Modify `App/Hosted/HostedNoteShares.swift`, `Core/Sharing/NoteShare.swift`, `Core/Hosted/HostedShareClient.swift`, `server/src/shares.ts`; preserve `web/src/lib/share-view.ts`. Create `Core/Sharing/NoteShareLifecycle.swift`. Extend `CoreTests/NoteShareTests.swift`, `server/test/shares.test.ts`, `web/scripts/share-note.test.ts`; use local `HostedShareE2ETests.swift` when orchestration changes.
**Dependencies:** P10/P11/P21. Crypto/access changes stop/report before shipping; do not change the encrypted format.
**Interface:** `noteShareStep(state: NoteShareState, event: NoteShareEvent) -> NoteShareTransition`.

**Verification cases:** `remoteShareCreatedButLocalReceiptFailedIsReconciled` and "expired share is denied before physical purge": assert local ledger/key custody and server availability, without logging secrets.

- [ ] Separate local key/ledger ownership from remote share availability. Test successful remote create followed by local ledger failure, revoke failure, account replacement and restart reconciliation.
- [ ] Keep TTL availability authoritative even before physical cleanup. Retain the explicit web share-view request guard; wrong key/gone/network outcomes remain distinct.
- [ ] Run CORE + LINK + MAC + HOSTED + IOS where shared UI compiles + SERVER + WEB + DIFF. Never log share secrets; use local encrypted fixtures.

## P23 — Preserve server one-shot identity and MCP revocation boundaries

**Files:** Modify `server/src/auth/identityToken.ts`, `server/src/auth/tokens.ts`, `server/src/attest/devices.ts`, `server/src/mcp/authorize.ts`, `server/src/mcp/grants.ts`, `server/src/aiConsent.ts` only where a gap is demonstrated; create `server/src/mcp/connectionLifecycle.ts`, `server/src/auth/jwksLifecycle.ts` for needed pure classifiers. Extend `server/test/auth.test.ts`, `server/test/attest.test.ts`, `server/test/appleTokens.test.ts`, `server/test/mcp.test.ts`, `server/test/mcpSecurity.test.ts`, `server/test/mcpReviewer.test.ts`, `server/test/aiConsent.test.ts`.
**Dependencies:** P09/P12/P21. Sensitive auth change: stop/report before shipping.
**Interfaces:** `connectionActivationDecision(input: ConnectionActivationInput): ConnectionActivationDecision`; `connectionRefreshDecision(input: ConnectionRefreshInput): ConnectionRefreshDecision`; `jwksRefreshDecision(input: JwksRefreshInput): JwksRefreshDecision`.

**Verification cases:** "stale consent cannot activate after off/on" and "grant removal denies access before KV revoke": assert authenticated requests and persisted D1/KV boundaries.

- [ ] Preserve `server/src/auth/refreshState.ts`, provider-library transactions and database one-shot challenge/nonce consumption. Do not duplicate them in process-local pending sets.
- [ ] Test nonce/purpose/user binding, monotonic assertion counts, unknown-key rotation, refresh-family absorbing revocation and old family responses after a new login. Preserve documented cache policy without adding a new fallback.
- [ ] Prove feature off/on invalidates pending consent/code exchange; D1 grant removal blocks access before queued KV revoke. Old consent cannot activate a connection for a newer epoch.
- [ ] Preserve versioned AI-consent enforcement and prior explicit trial/referral policy; inspect current tests before adding fixtures. Run SERVER + WORKERS + DIFF with the existing local MCP harness and independent auth review.

## P24 — Make billing preparation, webhook order and compensation durable

**Files:** Modify `server/src/billing.ts`, `server/src/appStore.ts`; preserve `server/src/subscriptionLifecycle.ts`, `server/src/referralState.ts`, `server/src/withdrawalState.ts`. Create `server/src/billing/checkoutLifecycle.ts`, `server/src/billing/duplicateLifecycle.ts`, `server/src/billing/webhookLifecycle.ts`. Modify `App/Hosted/HostedAccount.swift` only for billing-return ownership. Extend `server/test/billing.test.ts`, `server/test/appStore.test.ts`, `server/test/referrals.test.ts`, `server/test/withdrawal.test.ts`, `server/test/subscriptionStateGuards.test.ts`, `server/test/subscriptionLifecycle.test.ts`, `CoreTests/HostedCheckoutStateTests.swift`, `CoreTests/HostedAppStoreTests.swift`.
**Dependencies:** P09/P10/P20/P23; browser intent is P27. Sensitive payment change: stop/report before shipping.
**Interfaces:** `checkoutPreparationDecision(input: CheckoutPreparationInput): CheckoutPreparationDecision`; `duplicateRemediationDecision(input: DuplicateRemediationInput): DuplicateRemediationDecision`; `webhookApplyDecision(input: WebhookApplyInput): WebhookApplyDecision`.

**Verification cases:** "refund success and cancel failure does not refund again after 24 hours": assert durable remediation marker, refund/cancel calls and current entitlement snapshot.

- [ ] Preserve provider subscription/snapshot authority and existing access classifiers. Name customer generation/idempotency, checkout preparation/abandonment and event-order decisions without a second subscription state source.
- [ ] Test duplicate subscription compensation: durable marker precedes refund; refund succeeds/cancel fails; retry after more than 24 hours does not refund twice. Retain and extend the existing Stripe fake scenarios.
- [ ] Test customer.deleted generation replacement, stale webhook/RevenueCat snapshots, repeated event delivery and browser return before entitlement convergence. Keep checkout/paywall action locks and all products/referral/withdrawal rules.
- [ ] Run CORE + LINK + HOSTED + IOS + SERVER + WORKERS + DIFF. Use existing Stripe/RevenueCat fixtures; real charges and StoreKit Simulator purchase proof are not requirements. Record payment review and shipping checkpoint.

## P25 — Make account deletion resumable across durable boundaries

**Files:** Modify `server/src/account.ts` and its existing billing/token/assistant/sync/phone adapters; create `server/src/accountDeletionLifecycle.ts`. If crash characterization proves missing durable progress, create a separate additive API migration under `server/migrations/`, and `server/src/accountDeletionJobs.ts`. Extend `server/test/account.test.ts`, `server/test/appleTokens.test.ts`, `server/test/spend.test.ts`, `server/test/sync.test.ts`, `server/test/assistantApi.test.ts`, `server/test/phone.test.ts`.
**Dependencies:** P20–P24 and P26. Sensitive auth/payment/migration change: stop/report before shipping.
**Interface:** `accountDeletionDecision(observation: AccountDeletionObservation): AccountDeletionDecision`; decisions identify the expected account identity/epoch and the next specific external or transactional action.

**Verification cases:** "fresh deletion runner resumes each durable boundary" and "old deletion job cannot affect a new account epoch": assert service calls, logical access refusal and remaining physical-cleanup evidence.

- [ ] First characterize the current saga at every durable boundary with failure/retry and fresh adapters sharing the same D1/R2. Name observed progress; do not report full crash resumption after extraction alone.
- [ ] Preserve current external preconditions: a failed Stripe close cannot silently begin the account transaction. Logical deletion/revocation must prevent late LLM/audio/upload results from recreating private state.
- [ ] If progress cannot be reconstructed safely, design the smallest durable deletion job with explicit steps, attempts and lease ownership. Independently review schema/PII retention and backward compatibility before choosing its migration filename from the then-current next sequence; do not reserve a stale number in this plan.
- [ ] Test claim/reclaim, two runners, external success before checkpoint, partial object purge and an old deletion job against a new account/epoch. Provider idempotency and reconciliation, not the lease alone, govern safe external repeats.
- [ ] Run SERVER + WORKERS + DIFF and migration tests against old/new Worker assumptions. Apply only local migrations in validation; CI performs production rollout after the required review checkpoint.

## P26 — Guard pilot phone verification, import and provider cleanup

**Files:** Modify `iOS/PhoneDialer/PhoneDialer.swift`, `iOS/CallCapture/CallCaptureAudio.swift`, `server/src/phone/calls.ts`; preserve `iOS/PhoneDialer/PhoneCallController.swift`, `Core/Hosted/PhoneCallKitState.swift`, `server/src/phone/lifecycle.ts`. Create `Core/Hosted/PhoneCallImportState.swift`, `server/src/phone/verificationLifecycle.ts`. Extend `CoreTests/PhoneDialerTests.swift`, `CoreTests/PhoneCallKitStateTests.swift`, `server/test/phone.test.ts`; create `CoreTests/PhoneCallImportStateTests.swift`. If the call-audio writer changes, modify `project.yml` and create `iOSTests/CallCaptureAudioTests.swift` with the concrete `AINotepadiOSAudioTests` unit-test target/scheme described below.
**Dependencies:** P01/P10/P11/P20/P23. Sensitive auth/phone policy or migration changes stop/report before shipping.
**Interfaces:** `phoneCallImportStep(state: PhoneCallImportState, event: PhoneCallImportEvent) -> PhoneCallImportTransition`; `verificationCallbackDecision(input: VerificationCallbackInput): VerificationCallbackDecision`.

**Verification cases:** `importedCallIsNotImportedAgainAfterProviderDeleteFailure` and "old verification callback cannot verify replacement number": assert local import count, pending purge row and expected number/SID.

- [ ] Keep verification, call reservation and recording import separate. Bind callbacks to expected number/provider SID and owner/call/attempt; a replacement number cannot inherit an old successful verification.
- [ ] Test duplicate watcher + resume import, local import success/provider delete failure, old callback after deletion and queue persistence while dialer policy is off. Remove provider purge rows only after confirmed deletion.
- [ ] Retain typed experimental call-capture controller. Characterize first-format binding, gap filling and append-after-close in the writer; add a state type only if it clarifies the resource contract. If the writer changes, add `AINotepadiOSAudioTests` as an iOS unit-test target/scheme in `project.yml`, compiling only `iOSTests/CallCaptureAudioTests.swift` and `iOS/CallCapture/CallCaptureAudio.swift`, depending on AINotepadCore, with `CALL_CAPTURE_EXPERIMENT` defined. Use generated PCM buffers and real temporary CAF files for first-format, gaps and append/close tests; this source does not import ScreenCaptureKit and can run in Simulator. After XcodeGen, run `xcodebuild -project AINotepad.xcodeproj -scheme AINotepadiOSAudioTests -derivedDataPath .build/xcode-ios-audio-tests -destination 'platform=iOS Simulator,name=iPhone 17' test -quiet`. Keep actual ScreenCaptureKit capture proof device-only. If the writer contract is retained unchanged, document its guards and existing smoke evidence without creating a test target.
- [ ] Run CORE + LINK + IOS Debug/Release + SERVER + WORKERS + DIFF. Use existing Twilio fakes, no real calls, no pilot-policy changes. Device-only writer/capture evidence remains explicitly gated.

## P27 — Make browser sign-in, tab ownership and purchase intent explicit

**Files:** Modify `web/src/client/sign-in.ts`, `web/src/client/app-handoff.ts`, `web/src/client/session.ts`, `web/src/client/account.ts`, `web/src/client/checkout-choice.ts`; preserve `web/src/lib/session-state.ts`, `web/src/lib/checkout-state.ts`. Create `web/src/lib/sign-in-state.ts`, `web/src/lib/tab-claim-state.ts`, `web/src/lib/purchase-intent-state.ts`, `web/src/lib/invite-input-state.ts`, `web/src/lib/account-deletion-state.ts`. Extend `web/scripts/state-machines.test.ts`, `web/scripts/e2e.ts`; add pure model tests only where existing scenarios do not cover the new decisions.
**Dependencies:** P23/P24; deletion completion depends on P25. Sensitive auth/payment/deletion changes stop/report before shipping.
**Interfaces:** `signInAttemptTransition(state: SignInAttemptState, event: SignInAttemptEvent): SignInAttemptTransition`; `tabClaimTransition(state: TabClaimState, event: TabClaimEvent): TabClaimTransition`; `purchaseIntentTransition(state: PurchaseIntentState, event: PurchaseIntentEvent): PurchaseIntentTransition`; `inviteInputTransition(state: InviteInputState, event: InviteInputEvent): InviteInputTransition`; `accountDeletionTransition(state: AccountDeletionState, event: AccountDeletionEvent): AccountDeletionTransition`.

**Verification cases:** "old sign-in attempt cannot establish a session" and "unapplied referral cannot start full-price checkout": assert browser storage/session state, intercepted request bodies and no duplicate action.

- [ ] Keep nonce/state/browser-handoff records one-shot and attempt-bound. Test old popup/callback after cancel/retry, pending record replay and duplicate-tab ownership while refresh finishes.
- [ ] Preserve existing session/checkout reducers. Model cross-login purchase intent and invite validation separately; invalid/unapplied referral input cannot silently become a full-price checkout.
- [ ] Test payment return before login and before entitlement convergence, back-forward cache restore and repeated actions. Deletion freezes its confirmed account/target through request/completion/redirect and rejects duplicate invocation.
- [ ] Run WEB + WEB-E2E + SERVER + DIFF with local provider interception. Split identity/tab ownership and account purchase/deletion adapters into separate PRs.

## P28 — Guard admin selection, blog editing/publication and contact submission

**Files:** Modify `web/src/client/admin.ts`, `web/src/client/admin-users.ts`, `web/src/client/admin-blog.ts`, `web/src/client/admin-blog-image.ts`, `web/src/client/contact.ts`, `server/src/blog.ts`; preserve `web/src/lib/admin-load.ts`. Create `web/src/lib/admin-selection-state.ts`, `web/src/lib/blog-editor-state.ts`, `web/src/lib/blog-image-state.ts`, `web/src/lib/contact-state.ts`, `server/src/blogWriteLifecycle.ts`. Extend `web/scripts/admin-load.test.ts`, `web/scripts/state-machines.test.ts`, `web/scripts/e2e.ts`, `server/test/blog.test.ts`, `server/test/reports.test.ts`; create `web/scripts/blog-editor-state.test.ts`, `web/scripts/blog-image-state.test.ts` for pure policies.
**Dependencies:** P00; current account ownership from P23/P27 when integrated. Admin authorization behavior remains unchanged; auth changes trigger the sensitive checkpoint.
**Interfaces:** `selectionTransition(state: SelectionState, event: SelectionEvent): SelectionTransition`; `blogEditorTransition(state: BlogEditorState, event: BlogEditorEvent): BlogEditorTransition`; `blogImageTransition(state: BlogImageState, event: BlogImageEvent): BlogImageTransition`; `contactTransition(state: ContactState, event: ContactEvent): ContactTransition`; `blogWriteDecision(input: BlogWriteInput): BlogWriteDecision`.

**Verification cases:** "late image upload cannot insert into another post" and "stale admin action cannot target new selection": assert editor text, object-URL cleanup and actual API target IDs.

- [ ] **P28a:** Carry selected report/user identity and request generation together. Test selection change before load/action completes; a stale result cannot act on or reopen another target. Preserve the explicit loader and report open/done authority.
- [ ] **P28b:** Scope dirty/save/refresh and image prepare/preview/upload/insertion to the current editor/post/image attempt. Test out-of-order image results, navigation during save and object-URL owner cleanup.
- [ ] Keep GitHub branch/head/PR authority at the server edge. Preserve head CAS, concurrent first-save losing-PR cleanup and save-during-merge tests; select the next operation from observed provider state rather than recreating GitHub's state machine. Use existing GitHub fakes, no live publication.
- [ ] **P28c:** Make captcha readiness/one-submit token consumption explicit only as needed; test duplicate submit, expired token and error reset without reusing a consumed token.
- [ ] Run SERVER + WORKERS + WEB + WEB-E2E + DIFF for changed adapters. Ship the three feature slices independently.

## P29 — Close smaller protocols with proportional changes

**Files:** Review each registry row owned by P29 at its linked source. Likely adapters include `App/Toasts.swift`, `LivePanel.swift`, `DictationPill.swift`, `IslandController.swift`, `MainWindow.swift`, `MacAppLinks.swift`, `SetupPage.swift`, `SettingsPage.swift`, `MeetingSpotlightIndex.swift`, `EngagementNotifier.swift`, `App/Hosted/HostedTelemetryCenter.swift`, `HostedRecommendBanner.swift`; shared UI meter/hover/history/splash files; `iOS/ProcessingOverlay.swift`, `PhoneOnboarding.swift`, `PhoneVoices.swift`, `PhoneHome.swift`, `MeetingsTab.swift`, `MeetingPhotos.swift`, `RecordTab.swift`; web hero/voice/video/pull/theme clients. No blanket Create list is authorized.
**Dependencies:** P01/P10 for commit/owner checks; the relevant domain task for each adapter. Most entries are expected to retain their current simple representation.

- [ ] For **every** P29 registry label and unnumbered completeness boundary, record its invariant and concrete evidence. Existing passing coverage plus reviewed local transition code is sufficient for a bounded one-shot UI operation; add a new test only for a changed or missing invariant.
- [ ] Keep telemetry batching/drop policy and daily rollover intentional; do not turn best-effort telemetry into a durable queue. Verify Spotlight/notification reconciliation coalesces correctly and old scope work cannot publish. Keep banner consumption and usage-offer history within existing policy.
- [ ] Verify deferred deep links wait for sign-in/data and consume once; source handoff belongs to the matching meeting. Freeze destructive target IDs when confirmation opens, then revalidate locks/owner at execution. Stale query/image/draft/voice-download completion cannot update a new target or write an unread registry.
- [ ] Verify toast replacement versus old expiry, hover suspension, window delayed hide, focus/IME ownership, sample save after disappearance, processing-overlay dismissal and transcript follow/unseen behavior. Retain explicit parent phases and simple copy acknowledgements.
- [ ] Verify web user playback intent versus visibility, one RAF/timer chain, hidden-page race timing, pull cancellation and system/manual theme ownership. Keep CSS demos/animations simple unless a reproduced ordering gap justifies a small pure policy.
- [ ] Preserve `ResumeOnce`, Darwin observer cancellation, throttles, parsing recognizers and existing serial/retry utilities. Test cleanup/ordering only at changed dependent boundaries. Do not introduce a generic timer/async-status framework.
- [ ] Run only the applicable CORE/LINK/MAC/HOSTED/IOS/WATCH/SERVER/WEB/WEB-E2E commands plus DIFF; identify them per sub-PR. Evidence-backed retain decisions close rows without fabricated code churn. Record any newly found defect under the same owner and fix it in a focused child PR.

## P30 — Verify the complete cross-layer behavior and close the registry

**Files:** Update evidence under completed tasks and the spec registry. Extend existing end-to-end suites only for uncovered cross-boundary traces; do not add a second test harness or duplicate documentation.
**Dependencies:** All required P01–P29 outcomes, including sensitive-change and hardware checkpoints.

**Verification cases:** Use the existing hosted/browser cross-layer suites named by the owning packages; do not introduce a duplicate acceptance suite. Assert complete user-visible traces and persistent outcomes, with each relevant gate explicitly reported.

- [ ] Trace record → stop/drain → interrupted processing → restart → resume paid work → durable note → delivery/receipt. Verify no lost recording, repeated completed billed chunk or pre-save ready publication.
- [ ] Trace A → pending work → B → A across credential refresh, sync upload, Ask answer, integration receipt, keyboard result and Watch import. Old work cleans up without writing into the replacement session.
- [ ] Trace assistant/sync disable/reset during upload and purge; subscription duplicate compensation during retry; deletion while upstream work is active. Assert durable counters, access refusal and object custody after fresh adapter instances.
- [ ] Complete real iPhone dictation and paired-Watch transfer checks for changed adapters; keep device-only call capture separate. Record unavailable/failed evidence as an unresolved blocker, not a pass or a global program completion.
- [ ] Run CORE + LINK, affected macOS/Hosted/iOS/Watch builds, SERVER + WORKERS + WEB + WEB-E2E and DIFF once for the final integrated change set. Respect existing environment gates; run expensive live suites only when a specific unresolved concern warrants them.
- [ ] Verify all 175 labels and unnumbered boundaries have a primary owner and a linked implementation PR or reviewed retain decision with evidence. Record source-format compatibility and independent design-review outcomes. Stop on any failed relevant check or unproven new durability guarantee.
- [ ] Follow AGENTS.md for safe shipping: branch, Conventional Commit, scoped PR and auto-merge with required checks. For sensitive changes, report the concrete result/checks and the required checkpoint instead of shipping. Do not manually deploy Workers or production migrations.

## Definition of done

The program is complete when the full registry has evidence-backed dispositions, relevant existing behavior/compatibility is preserved, confirmed regressions are fixed, missing durability guarantees are implemented and checked at their persistent boundaries, and all required checks/reviews have passed. A smaller number of flags, a collection of new enums, or successful source-link validation does not establish completion.

Recommended first implementation deliverable: **P00 baseline plus P01a final-save/receipt characterization and the smallest proven fix**, followed by P02 recording shutdown. Keep the remainder as independently reviewable work packages; do not begin a whole-app rewrite.
