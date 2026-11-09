# Gistsmith on Apple Watch

Date: 2026-11-08, hardened 2026-11-09. Status: v1 on `feat/apple-watch`, rebased on main (iPhone minimum iOS 18.0).
Watch-microphone recording ships behind the server switch, OFF in production, until one paired-device check passes
("Go / no-go" below); the rest of the Watch app ships on. Toolchain checked: Xcode 27.2 (27B52) ships the watchOS 27.2 and watchOS Simulator 27.2
SDKs; the local Simulator runtime is watchOS 26.5.

## What Granola's Watch app does (public sources)

- Launched 2026-07-28, free, a companion to the iPhone app; needs watchOS 11+ ([TechCrunch](https://techcrunch.com/2026/07/28/granola-launches-an-apple-watch-app/),
  [help center](https://docs.granola.ai/help-center/ios/apple-watch)).
- **The Watch records with its own microphone.** "The Watch captures audio, and the iPhone processes it into notes."
  Start from the app or a complication, either from an upcoming meeting or as a new note. Recording continues after
  the wrist is lowered or the watch face comes back. A chime and a tap mark start and end.
- After "End" a recording moves through Saved → Syncing to phone → Synced → Uploading → Generating notes → Complete.
  Unsynced recordings wait under "Waiting to sync" with Sync/Delete. Recording works offline; only syncing needs the
  phone.
- Calls, Siri or a low battery stop a recording; the partial audio syncs, the recording cannot be resumed.
- The Watch shows upcoming meetings, "new note", the list of Watch recordings with their state, and the signed-in
  account. Notes are read on the iPhone or desktop, not on the Watch. No tasks and no Q&A on the Watch.

## What the platform allows (verified)

- **The iPhone cannot start a new recording from the background.** `WCSession.sendMessage` from the Watch "wakes up
  the corresponding iOS app in the background" (WatchConnectivity docs), but iOS refuses to activate a recording audio
  session for a backgrounded app (`AVAudioSession.ErrorCode.cannotStartRecording`, a privacy rule since iOS 12.4;
  Apple forums [120038](https://developer.apple.com/forums/thread/120038), [815725](https://developer.apple.com/forums/thread/815725)).
  The only background start iOS grants is an `AudioRecordingIntent` run by the system (our Control Center control,
  Shortcuts, Siri), which must start a Live Activity ("If you don't start a Live Activity, the audio recording stops",
  `AudioRecordingIntent` docs). So "start on iPhone from the Watch" over WatchConnectivity works only while
  Gistsmith is open on the iPhone.
- **iPhone controls run on the Watch.** watchOS 26: "People can add the controls from your iPhone app to system spaces
  on Apple Watch, even if you don't have a Watch app. When the control is tapped on the Apple Watch, the action is
  performed on the companion iPhone. … controls whose actions foreground the iPhone app will not appear on Apple Watch"
  ([WWDC25 334](https://developer.apple.com/videos/play/wwdc2025/334/)). Our iPhone "Record" control
  (`ToggleRecordingIntent`, an `AudioRecordingIntent`) runs in the background when it can; whether watchOS lists it
  (its modes include `.foreground(.dynamic)`) needs a device check.
- **Pause, resume and stop of a running iPhone recording do work from the background**: the audio session is already
  active. The iPhone's Live Activity also appears in the Watch Smart Stack (watchOS 11+) with its buttons.
- **The Watch can record in the background once started in the foreground.** "The Audio, Location updates, and
  Workout processing modes let your app run the respective background sessions. Your app must start the session in
  the foreground, but the session continues to run when your app transitions to the background"
  ([Enabling Background Sessions](https://developer.apple.com/documentation/watchkit/enabling-background-sessions)).
  Interruptions (calls, Siri) end the session, as Granola documents.
- **Watch controls** (watchOS 26) run on the Watch and can sit in Control Center, the Smart Stack and the Action
  button on Ultra. A control that starts recording must open the app (a session starts only in the foreground).

## Scope of v1

Evidence changed the brief's order: the Watch's own microphone is the dependable way to start from the wrist (it is
how Granola works and the only start that does not need the iPhone in hand), and iPhone remote control covers the
recording that is already running there.

1. **Record on the Watch.** One big button, or tap an upcoming meeting to record under its title. Captured as PCM
   CAF (crash-safe), sent as AAC mono 16 kHz 32 kbps (~14 MB per hour). Timer (`Text(timerInterval:)`, no per-second
   redraw), End (no pause on the Watch, see R10). Haptic at start
   and end. Interrupted recordings are kept and sent. A recording stops itself at the account's longest meeting
   (from the iPhone's last snapshot). After End the file goes to the iPhone with `WCSession.transferFile` (queued,
   survives either app quitting) and the Watch deletes it only once the iPhone's snapshot lists it as received. On the iPhone the file
   lands in a durable inbox and goes through the existing import path (`importOne`: server final pass, speakers,
   note) as a meeting with the Watch's title and start time. The Watch lists its recordings with Waiting / Sending /
   Sent and a retry/delete.
2. **Control the iPhone's recording.** The Watch shows the iPhone's state (starting, recording, paused, finishing),
   title and elapsed time, with Pause/Resume and End. Commands carry the `RecordingID` from the snapshot and enter
   `RecorderStateMachine` as `RecorderTarget.recording(id)` events, so a stale button never touches a newer recording.
   "Start on iPhone" appears only while the snapshot says Gistsmith is open on the iPhone (`phoneAppOpen`); if the
   snapshot is stale the iPhone still refuses honestly and the Watch says to open the app or record on the Watch.
3. **Today.** Upcoming meetings from the iPhone calendar (only when the user turned the calendar on there). Tap to
   record on the Watch with that title.
4. **My tasks** (open, by urgency, up to 20) with mark-done. Mark-done goes as `transferUserInfo` (queued, delivered
   when the phone is reachable) and is applied with `markingTaskDone` (idempotent, never un-marks); the row hides at
   once on the Watch.
5. **Complication / Smart Stack widget**: Watch recording (timer) → iPhone recording (timer) → next meeting → "Record".
   Families: circular, corner, rectangular, inline.
6. **Control** (watchOS 26): "Record on Watch" opens the app and starts recording; works in Control Center, Smart
   Stack and on the Action button.

### Not in v1

**Ask from the Watch** (deferred to v1.1, see the review outcome): a dictated question answered by the iPhone. A
synchronous `sendMessage` reply does not survive a 10–30 s answer once the wrist drops, and it would read every
meeting from a Watch that may have no passcode. v1.1 shape: opt-in in iPhone Settings, answered only while the
iPhone's protected data is available, one answer per question ID delivered with `transferUserInfo`, rate-limited.

Live transcript on the Watch (needs the server path on the Watch: a token and network from the wrist), reading notes
on the Watch, a Watch account of its own, standalone Watch use without an iPhone, on-Watch transcription. iPhone
notifications already mirror to the Watch.

## Design

- **No secrets on the Watch.** The Watch never talks to the server. Everything goes through WatchConnectivity to the
  iPhone app, which already holds the account. The Watch keeps the last snapshot (titles, task text, the recording
  state) in its own container and its widget's App Group, and audio until it reaches the iPhone.
- **One protocol module.** `AINotepadWatchLink` (its own local package `Packages/AINotepadWatchLink`, Foundation only,
  builds for watchOS without the core package's WhisperKit graph) holds the Codable messages, the snapshot, and pure functions (snapshot from inputs, answer shortening,
  file metadata, recording limit). The iPhone-only mapping `watchRecordingState(state: RecorderState, …)` lives in
  `AINotepadCore` next to the state machine. Tests cover both.
- **iPhone side** (`iOS/PhoneWatchLink.swift`): a thin `WCSessionDelegate` adapter. It pushes the snapshot with
  `updateApplicationContext` when the recorder state, tasks or calendar change (latest state wins, delivered even when
  the Watch app is not running), routes commands to the existing `PhoneRecorder` methods, and moves received files
  into `Application Support/WatchInbox` before the delegate returns. No new recording state: the snapshot is derived
  from `PhoneRecorder.state`.
- **Watch side** (`Watch/`): SwiftUI app with a `WatchRecorder` adapter (AVAudioRecorder + AVAudioSession
  `.playAndRecord`, `UIBackgroundModes` audio), the model as WCSession delegate, and a widget extension (complication +
  control). Deployment target watchOS 26.0 (Controls need it). Watches on watchOS 26 pair with iPhones on iOS 26; an
  iPhone on iOS 18–25 runs Gistsmith without offering the Watch app. `AINotepadWatchLink` builds for iOS 18 and uses
  no iOS 26 API.
- **Server switch**: `GET /v1/me` → `watchRecording` (`WATCH_RECORDING_POLICY` on/off, `WATCH_RECORDING_USERS`
  allowlist while off). The iPhone passes it in the snapshot (`watchRecordingEnabled`); off, the Watch hides its record
  button and says "Recording on the watch isn't available yet. Record on your iPhone for now." An older server (no
  field) means off.

## Battery, privacy, App Review

- Battery: 32 kbps AAC, no network on the Watch, one transfer after End, timers drawn by the system. Expected cost is
  that of a voice memo; measure on a device before release.
- Privacy: audio leaves the Watch only to the paired iPhone (WatchConnectivity is encrypted end to end), then follows
  the iPhone path already described in the privacy policy. Microphone usage string on the Watch. Privacy manifest for
  the Watch app (UserDefaults, file timestamps). Consent: the start screen carries the same "Let people know you're
  recording" line as the iPhone.
- App Review: the Watch app works on its own once linked (records offline), so it is not a bare launcher; background
  audio is used for recording only; Watch screenshots required.

## Recording on the Watch: platform facts (research 2026-11-09)

Primary sources first; community reports only where Apple says nothing.

| # | Fact | Source |
|---|------|--------|
| R1 | The audio background mode on watchOS is the `UIBackgroundModes` key with `audio`. `WKBackgroundModes` accepts only `workout-processing`, `self-care`, `mindfulness`, `physical-therapy`, `alarm`, `underwater-depth`; `audio` there is invalid (App Store Connect upload rejects "The value for the key 'WKBackgroundModes' … is invalid"). | Apple: [WKBackgroundModes](https://developer.apple.com/documentation/bundleresources/information-property-list/wkbackgroundmodes) (possible values), [Playing Background Audio](https://developer.apple.com/documentation/watchkit/playing-background-audio) ("This step sets the UIBackgroundModes key"); upload error quoted in [shoutkit#199](https://github.com/cascadiacollections/shoutkit/pull/199). |
| R2 | "The Audio, Location updates, and Workout processing modes let your app run the respective background sessions. Your app must start the session in the foreground, but the session continues to run when your app transitions to the background … Apple Watch displays your app whenever the user raises their wrist." | Apple: [Enabling Background Sessions](https://developer.apple.com/documentation/watchkit/enabling-background-sessions). |
| R3 | Recording specifically: a watchOS app that "records audio for an extended period … continues to record in background mode when the watch face is off". Apple Frameworks Engineer: "Recording cannot be resumed when the app is in the background on watchOS. It must be a user-initiated event while the app is in the foreground. (Recording can then continue once the app moves to the background.)" Session there: `.playAndRecord`, `.default`. | [Developer Forums 750432](https://developer.apple.com/forums/thread/750432) (Apple answer, Apr 2024). |
| R4 | A call or Siri interrupts the session (`AVAudioSession.interruptionNotification` `.began`); re-activating in the background fails ("Session activation failed"). So an interruption ends a Watch recording; Granola documents the same ("Calls, Siri or a low battery stop a recording; the partial audio syncs"). The `AVAudioRecorderDelegate` is not called for an interruption. | R3; [Granola help](https://docs.granola.ai/help-center/ios/apple-watch); [watch-pilot Q3 research](https://github.com/frederico-kluser/watch-pilot/blob/main/docs/research/Q3-audio-capture.md) (SDK headers). |
| R5 | Extended runtime sessions (`WKExtendedRuntimeSession`) exist only for self care, mindfulness, physical therapy, smart alarm and underwater depth. None fits meeting recording; claiming one is an App Review risk. The audio mode is the right tool. | Apple: WKBackgroundModes values (R1); [justspeaktoit#659](https://github.com/crmitchelmore/justspeaktoit/issues/659) reaches the same conclusion. |
| R6 | Without the audio mode an engine/recorder app goes inactive ~3 s after the screen locks; open-source Watch recorders that stop on `.background` lose wrist-down audio. | [Forums 726484](https://developer.apple.com/forums/thread/726484); [VivaDicta#414](https://github.com/n0an/VivaDicta/issues/414). |
| R7 | `AVAudioRecorder` exists on watchOS 4+; AAC 16 kHz mono in `.m4a` is valid; the container comes from the file extension; `setPreferredSampleRate` is unavailable on watchOS (the encoder resamples). An AAC `.m4a` gets its index only at `stop()`: a file cut off by termination cannot be read. | AVAudioRecorder.h (watchOS SDK) via watch-pilot Q3; our tests below. |
| R8 | `record(forDuration:)` neither stopped nor closed the file in the watchOS 26.5 Simulator (our `WatchRecorderTests`). Not relied on. | This repo, 2026-11-09. |
| R9 | A file cut off before `stop()` (copied while recording, as a kill leaves it), watchOS 26.5 Simulator: AAC `.m4a` unreadable ("dta?"); AAC in `.caf` opens with 0 frames; IMA4 cannot be recorded ("fmt?"); 16-bit PCM `.caf` readable with 2.83 of 3 s. | This repo, 2026-11-09 (probe, kept as `captureCutOffMidRecordingIsReadable`). |
| R10 | The audio background mode keeps an app running while it records; a paused recorder is not recording, so a paused app with the wrist down can be suspended and its session interrupted (`.appWasSuspended`). | Apple "Configuring background execution modes" (audio: "as long as it is playing … or recording audio"); reviewer finding C3. |
| R11 | `NSPrivacyAccessedAPICategoryDiskSpace` (reason `E174.1`) is required when an app reads free volume space; missing it gets ITMS-91053 at upload. | Apple privacy manifest required-reason APIs. |

### WatchConnectivity `transferFile`

| # | Fact | Source |
|---|------|--------|
| T1 | Queued, sent "asynchronously on a background thread … may throttle delivery speeds to accommodate performance and power"; `outstandingFileTransfers` lists the queued ones; callable only while `activationState == .activated` ("programmer error" otherwise). | [transferFile(_:metadata:)](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:)) |
| T2 | Background transfers "continue when the current app is suspended or terminated" (stated for `transferUserInfo`, same queue for files); all transfers are delivered in order. | [WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession), [WCSessionDelegate](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate) |
| T3 | Receiver: "If you don't move the file synchronously during your implementation of this method, the system deletes the file when the method returns." Not called in the Simulator. | [session(_:didReceive:)](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didreceive:)) |
| T4 | Sender: `session(_:didFinish:error:)` reports success or error; on error "perhaps … send the file again at a later time" — the system does not retry. Errors: no space on the target, malformed data, communications error. | [didFinish](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didfinish:error:)-6dtcu), WCSession overview |
| T5 | Delivery to a non-running iPhone app: Apple promises no background launch for queued transfers; they reach the delegate when the app next runs. `sendMessage` from the Watch "wakes up its companion iOS app, if the companion is reachable". | [Transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity); DTS in [forums 766559](https://developer.apple.com/forums/thread/766559) |
| T6 | `isReachable` on the Watch is true only while the app is foreground or high-priority background; messages to an unreachable counterpart fail. | [isReachable](https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable) |
| T7 | No documented size or time limit; transfer time grows with size. Our file is ~14 MB/hour (32 kbps). | WCSession overview |
| T8 | Watch Connectivity background tasks must be completed, or the app's background budget runs out. | Transferring data sample, "Handle Watch Connectivity background tasks" (we use SwiftUI `.backgroundTask(.watchConnectivity)`, which completes when the closure returns). |
| T9 | Simulator: `transferFile` returns, the Watch gets `didFinish` without error, but the iPhone's `session(_:didReceive:)` is never called (seen 2026-11-09, matches T3). Messages and application context do work between paired Simulators. | This repo, paired Series 11 (watchOS 26.5) + iPhone 17 (iOS 26.5). |

## Our implementation against the facts

| Fact | Before this pass | Now |
|------|------------------|-----|
| R1 | `WKBackgroundModes: [audio]` — invalid; upload would fail and recording would stop at wrist-down. | `UIBackgroundModes: [audio]` (project.yml + Info.plist; checked in the built bundle). |
| R2/R3 | Start only from a foreground tap or the control (`supportedModes: .foreground`). Category `.record`. The control's `perform` was empty in the widget extension (which process runs it on watchOS is not documented). | Category `.playAndRecord`/`.default`, the configuration Apple's engineer confirmed for background recording. The control leaves a start request in the App Group; the app starts it when its scene is active (requests older than 2 minutes are dropped). |
| R4 | Interruption `.began` ends and keeps the recording (marked interrupted). | Same, plus `mediaServicesWereReset` ends it; the reason is logged. |
| R7/R9 | AAC `.m4a` written while recording: a crash, force quit or dead battery left an unreadable file, deleted silently at the next launch — the whole meeting lost. | The Watch records 16-bit PCM CAF (~115 MB/h) and compresses it to the AAC `.m4a` (~14 MB/h, the iPhone's format) after End ("Preparing"); a cut-off capture is recovered at the next launch as an interrupted recording and sent. Only an unreadable one is deleted, with a notice. Low battery (≤ 5 % unplugged) ends and saves the recording; < 520 MB free (4 h of capture) refuses to start. |
| R10 | Pause/resume on the Watch. | Removed: Finish and a new recording. (Pause of the iPhone's recording from the Watch stays.) |
| R11 | Privacy manifest had UserDefaults only. | DiskSpace `E174.1` added. |
| R8 | Limit via `record(forDuration:)`. | A 5 s watchdog compares `AVAudioRecorder.currentTime` (pauses excluded) to the account's limit and ends the recording; the delegate's `didFinish` now means "the system stopped it" (`failed`, saved, user told). |
| Swift 6 | `sendMessage` reply/error closures were written in a `@MainActor` method: WatchConnectivity calls them on a background queue and the runtime trapped (`EXC_BREAKPOINT` in `_dispatch_assert_queue_fail` ← `closure #1 in WatchAppModel.send(request:)` ← `-[WCSession onqueue_handleResponseDictionary:…]`, crash report of 2026-11-09 04:09 from the paired Simulator, first iPhone command). | Reply and error blocks are built by `nonisolated static` factories (`replyHandler(model:)`, `errorHandler(model:)`) that read plain values and hop to the main actor; `WatchModelIsolationTests` calls them and the delegate callbacks from a background queue. On the iPhone every WCSession entry point is a `nonisolated` delegate method whose blocks are `@Sendable` and hop with `Task { @MainActor in … }`. The paired-Simulator Pause/Resume round trip ran without a crash afterwards (three runs). |
| T2/T4 | Failed transfers stayed failed until "Send again". | Failed or lost transfers (and recordings whose transfer was never queued) are queued again whenever the app opens and at activation; a retry cancels the earlier queued copy first; a recording whose audio is gone stays "Couldn't send" instead of looping. |
| T3 | Move then metadata write inside the delegate (good). | Same, now in `storeWatchRecording` (package, tested): ID must be a UUID, empty files are refused, metadata is written last so a half-stored entry is never listed. |
| C1 | The iPhone marked a Watch recording imported only after uploading and processing the whole queue: iOS ending the app in between imported (and charged) the same audio twice. | Marked imported and removed from the inbox right after the meeting is queued; `runQueue` runs after that. |
| I3 | A recording longer than the account's remaining allowance (the Watch's limit can be hours old) was refused whole, with no way to split it on the phone. | Kept, never cut (cutting lost the rest for good, pre-push review): the recording stays in the iPhone's inbox as a failed import with a Watch-specific reason ("…at most N minutes right now. Try again when your time renews.") and Try again / Delete on the Watch; the Watch refuses to start below 2 minutes left. |
| I2 | The iPhone sent "Watch recording off" while it had not read the account yet (launch, offline), hiding the Record button. | Sent as unknown (nil); the Watch keeps its last known value for the same account (`watchMergedSnapshot`). |
| I4 | A recording the system ended with the wrist down ended silently. | Every system stop shows the reason in the app and, when the app is not on screen, as a local notification (permission asked at the first recording). |
| T5 | Watch deleted its copy only after the iPhone's snapshot lists the ID (good), but nothing woke the iPhone app. | Finish sends `refresh` at once (the Watch is reachable then); after `didFinish` succeeds the Watch sends `refresh` again (a message wakes the iPhone app); the iPhone then imports the inbox and pushes the confirming snapshot. The iPhone lacked `session(_:didReceiveMessage:)` for reply-less messages, so `refresh` was dropped ("does not implement delegate method" in the Simulator log) — added. The Watch list says "Sent when your iPhone is nearby. Opening Gistsmith on your iPhone speeds it up." |
| T6 | Commands only when reachable, else a message. | Same. |
| T8 | `.backgroundTask(.watchConnectivity)` waits ≤ 5 s for `hasContentPending`. | Same. |

## Tests and Simulator checks (2026-11-09)

- `AINotepadWatchLink` (14 tests): payloads, account binding, requeue rule (incl. preparing), battery/space/allowance
  rules, confirmation rule, keeping the last known switch and limit.
- `AINotepadCoreTests/WatchRecordingImportTests` — the iPhone's side end to end without WatchConnectivity: a real AAC
  16 kHz mono 32 kbps `.m4a` (the Watch's format) arrives as WatchConnectivity hands it over (temporary file + metadata
  payload), is moved into the inbox (the temporary copy is gone, as T3 requires), read back, decided on (wait for
  signed-out / other account, import for its account), imported through `importMediaAudio` + `importedMeetingRecord`
  with the Watch's title and start (duration matches), removed, and a repeated transfer is skipped as a duplicate.
  Malformed transfers (non-UUID ID, no metadata, empty file) and broken inbox entries are refused.
- `AINotepadWatchTests` (watchOS Simulator, real audio stack, 7 tests): End closes a readable PCM capture of the
  recorded length and `compress` turns it into the AAC 16 kHz mono `.m4a` that is sent; a capture copied mid-recording
  (what a kill leaves) is readable and compresses; the limit ends and closes the file and is reported once; the
  WatchConnectivity reply, error and delegate blocks run from a background queue without a trap; every glance family ×
  content draws (PNG renders).
- `AINotepadWatchUITests` (watchOS Simulator): every screen in English and Turkish with sample data, a real recording
  with the microphone and notification prompts answered, finish; with `WATCH_LINK_TEST=1` and the paired iPhone Simulator
  running `--tanitim --ornek-kayit --ornek-takvim`: the snapshot arrives, Pause and Resume from the Watch change the
  iPhone recording and come back in its snapshot; recording on the Watch and finishing compresses the capture and
  queues the transfer, which the Simulator reports as sent (T9, "Sent to iPhone" after "Preparing"; log "Watch
  recording compressed … seconds: 31"). Seen too: the Watch Simulator dropped to the watch face during a recording and
  showed the recording indicator above the time, the recording still running. The paired-Simulator link is fragile:
  install the Watch app before the iPhone app, or the iPhone never pushes its snapshot.
- Server: `/v1/me` `watchRecording` follows `WATCH_RECORDING_POLICY` and the `WATCH_RECORDING_USERS` allowlist;
  production is pinned off by `wranglerConfig.test.ts`.

What no Simulator can show: the iPhone receiving the file (T3/T9), recording with the wrist down and the screen off,
a real call/Siri interruption, battery cost, the microphone prompt on hardware.

## Go / no-go for Watch-microphone recording

Decision: **no-go for "on by default"; ship the Watch app with recording behind the server switch, OFF in
production** (`WATCH_RECORDING_POLICY=off`, testers by user ID in `WATCH_RECORDING_USERS`). Everything else on the
Watch (iPhone recording control, Today, tasks, glances) ships on.

Why: the research, the Simulator and the adversarial review found and fixed defects that would each have broken
Watch recording for real users: an invalid background-mode key (recording stops at wrist-down, upload rejected), a
crash on every iPhone command, a dropped `refresh`, a limit that never fired, whole meetings lost to a crash or dead
battery, double import and charge, an import refused for a stale limit, a missing privacy-manifest reason. None was
visible to the first review. The two facts the feature stands on — recording continues with the
wrist down (R3 is one Apple forum answer, not documentation), and the iPhone receives and imports the file (T3/T9:
untestable in the Simulator) — are still unverified on hardware. The owner's criterion was "no unresolved risk"; these
two remain.

Turning it on (no app release needed): one paired iPhone + Apple Watch on TestFlight, the tester's user ID in
`WATCH_RECORDING_USERS`, then:

1. Record 30+ minutes with the wrist down and the screen off (Always On on and off); End; the meeting appears on the
   iPhone with the Watch's title and start time and gets a note. Repeat with the iPhone app force-quit before End (the
   file must arrive once the Watch opens again or the iPhone app is opened).
2. A phone call and a Siri request mid-recording: the recording ends, is marked interrupted, arrives.
3. Lower the wrist and open another app for 10 minutes: still recording (timer, red indicator in the Smart Stack).
4. Battery: note the Watch battery before and after a 60-minute recording (expect a voice-memo cost, a few %).
5. First use: the microphone prompt shows on the Watch; denying shows the Settings hint.
6. Start from the "Record on Watch" control in Control Center: the app opens and records.
Then set `WATCH_RECORDING_POLICY=on` in `server/wrangler.jsonc` production vars (and update `wranglerConfig.test.ts`).

App Review: the review notes must say the Watch app records meetings with the watch microphone in the background
(`UIBackgroundModes` audio) and that the feature is enabled per account during rollout; add the review account's user
ID to `WATCH_RECORDING_USERS` before submitting so the reviewer can use it.

## Review outcome (2026-11-08)

Two independent reviewers read the draft of this spec (practicality; red team for privacy, battery, App Review).

Practicality: approve with changes. Taken: own local package instead of a product in `AINotepadCore`; a separate
import entry point with the Watch's title and start time (`PhoneRecorder.importWatchRecording`); inbox drained at
launch, on foreground and when the account changes; complication refresh through `.backgroundTask(.watchConnectivity)`
and `transferCurrentComplicationUserInfo` when the iPhone recording starts or stops; CI step that downloads the watchOS
platform when the runner lacks it; XcodeGen 2.45.3 embedding checked (Embed Watch Content, widget in the Watch app);
Watch strings in their own catalogs covered by the localization tests; `phoneAppOpen` in the snapshot.

Red team: verdict "holds up, fix three gaps". Taken: account binding (each recording carries the loaded account's
key, the iPhone imports it only into that account, otherwise it waits; signed out = wait); a ledger of imported
recording IDs against repeated transfers; signing out on the iPhone sends the empty snapshot and the Watch drops the
account's data (unsent recordings stay with their account tag); meeting titles and task text are `privacySensitive` and
the glance redacts titles in Always On; the App Group holds only what the glances draw; Watch privacy manifest; the
recording screen carries the "Let people know you're recording" line, also when started from the control; interrupted
recordings are labelled; snapshot pushes are debounced (1 s) and sent only when changed; the privacy policy names the
Watch.

Dissent kept: both reviewers recommended moving Ask out of v1. Agreed and done (see "Not in v1"); the brief made Ask
conditional on feasibility, and the evidence says the synchronous version is not. The red team's "background recording
is not documented for recording, only for playback" stands as a release blocker until the device check: Apple's
"Enabling Background Sessions" covers the Audio mode generally, Granola ships the same behaviour, but no Apple page
promises it for the microphone. Not taken: a stale-limit warning (the iPhone checks the real limit at import) and a
first-use consent sheet (the notice is on every recording screen).

## Owner steps

1. Device check (paired iPhone + Watch, TestFlight build, tester's user ID in `WATCH_RECORDING_USERS`): the six steps
   under "Go / no-go". Also: Pause/End an iPhone recording from the Watch. Mark a task done on the
   Watch with the iPhone away, then bring it back. Sign out on the iPhone: the Watch shows the sign-in hint. Check
   whether the iPhone's own "Record" control shows under "From Your iPhone" in the Watch's Control Center.
2. App Store Connect: Watch screenshots (at least one size, e.g. 46 mm Series 11: 416×496) on the iPhone app's
   version page; Watch app icon comes from the build. App Review notes: "The Apple Watch app records meetings with
   the watch microphone (the audio background mode keeps a recording running after the wrist drops) and sends the
   audio to the paired iPhone. Recording on the watch is enabled per account during rollout; it is on for the review
   account." No new data types for the privacy label (audio and user content are already declared).
3. The first archive registers two App IDs and the App Group automatically (`-allowProvisioningUpdates`); if signing
   fails, add them in the developer portal: `com.senoldogan.AINotepad.hosted.watchkitapp`,
   `com.senoldogan.AINotepad.hosted.watchkitapp.Widgets`, group `group.com.senoldogan.AINotepad.hosted.watch`.

## Review outcome (2026-11-09, adversarial, read-only)

One independent reviewer read the rebased code with the brief "find reasons recording or transfer fails on a real
device" (the Swift 6 trap, the background-mode key, the limit and the missing reply-less handler were already fixed and
listed for it). 3 Critical, 6 Important, 4 Minor. Verdict: no-go on default-on without a device test.

Fixed: C1 double import/charge (mark imported before `runQueue`); C2 meeting lost on kill (PCM CAF capture + compress
after End + recovery at launch; proven in the Simulator by `captureCutOffMidRecordingIsReadable`); C3 pause lets the
app be suspended (pause removed on the Watch); I1 DiskSpace reason in the privacy manifest; I2 Record button vanishing
offline (unknown switch keeps the last value); I3 import refused for a stale limit (kept as a retryable failed import with a clear reason; no start below 2 minutes); I4 silent system stop (reason in the app + local notification); I6 control intent (App Group start
request honoured when the scene is active); M1 stale glance timer after a crash (glance redrawn at launch).

Partly taken: I5 (transfers often wait for the iPhone app to be opened): Finish now sends `refresh` while the Watch
is reachable, and again after `didFinish`; a background refresh task that keeps retrying was not added (the Watch is
not reachable from a background refresh, so the message would fail). The footer tells the user that opening Gistsmith
on the iPhone speeds it up. Device check 1 measures it.

Not taken (recorded for v1.1): M2 inbox entries of another account wait indefinitely on the iPhone (they are imported
when that account signs in again); M3 a `.sent` recording the iPhone lost stays until "Send again"; M4 after a reboot
before the first unlock the iPhone may push "signed out" for a moment (the Watch then hides the Record button until the
next snapshot; recordings already made are not touched).

Device checks the reviewer requires, merged into "Go / no-go" above: 60-minute wrist-down recording with battery
reading; force quit while recording (the capture must come back as interrupted); call, Siri, timer, Voice Memos
interruptions; start from Control Center / Smart Stack / Action button, cold and warm, including the first-run
prompts; transfer with the iPhone app force-quit and the iPhone locked; kill the iPhone app during the import (one
meeting, one charge); out of range and back; iPhone offline (Record stays); a remaining allowance shorter than the
recording; the archive uploads without ITMS-91053.
