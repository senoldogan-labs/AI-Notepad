# On-device live preview (Gistsmith)

Status: implemented behind `ON_DEVICE_LIVE_PERCENT` (server). The owner reviews it before merge.

## Goal

Cut Gistsmith's per-meeting cost. Wherever the live transcript is only a preview, write it with Apple's on-device
speech recognition (`SpeechAnalyzer`: `SpeechTranscriber`, `DictationTranscriber`) instead of streaming the audio to
Deepgram. The saved transcript and the note still come from the cloud batch pass (ElevenLabs Scribe through our
server). The exceptions are listed under "Accepted risks".

## Current live path

- The app asks the server for a 30 s Deepgram grant for each connection (`POST /v1/live/deepgram-token`,
  `server/src/deepgram.ts`) and streams 16 kHz PCM straight to Deepgram Nova-3.
- `/v1/me` → `liveEngine` tells the app which engine to use:
  - `deepgram` while `DEEPGRAM_POLICY=on` and the estimated spend is under `DEEPGRAM_BUDGET_USD`;
  - `whisperkit` otherwise.
- `runHybridLiveSession` starts either on Deepgram or locally. When Deepgram stops, it falls back to the local engine
  and emits `.liveEngineFellBack`. The local engine is WhisperKit on Mac (a ~630 MB download) and Apple speech on
  iPhone.
- Tracks recorded:
  - Mac: "Sen" (microphone) and "Diğerleri" (system audio);
  - Mac in-person mode: "Diğerleri" only (the microphone);
  - iPhone: "Diğerleri" only.
- The final pass (hosted, `hostedFinalPassPlan`) always runs on the server for "Diğerleri".
- **"Sen" is not re-transcribed.** Its live text is saved as the transcript unless `meNeedsFinalPass` is set (after a
  stream failure). This is why "Sen" can't move on-device without lowering the saved transcript:
  - the server's audio allowance per meeting (`meetingAudioLimit`) is one meeting-length of audio;
  - the monthly cap counts that audio once;
  - so re-transcribing "Sen" as well would hit `audio_too_long` and double-count monthly hours.

## Cost per hour

List prices from `wrangler.jsonc`: Deepgram $0.0092/min per stream; Scribe $0.22/h plus $0.05/h for keyterms.

| | Live (Deepgram) | Final (Scribe + keyterms) | ASR total |
|---|---|---|---|
| Mac online meeting, today | 2 streams: $1.10 | $0.27 | $1.37 |
| Mac online meeting, after | 1 stream ("Sen"): $0.55 | $0.27 | $0.82 (−40%) |
| Mac in-person / iPhone, today | 1 stream: $0.55 | $0.27 | $0.82 |
| Mac in-person / iPhone, after | none | $0.27 | $0.27 (−67%) |

Deepgram bills streamed audio including silence.

At the 10 h monthly cap (plan price $5.99):

- a heavy Mac user's ASR cost drops from $13.70 to $8.20;
- an iPhone user's drops from $8.20 to $2.70.

The server's budget estimate now charges the number of streams the app declares at the first grant
(`x-live-streams`, migration 0061; missing means 2, for older apps). The $185 Deepgram budget therefore stretches from
~168 to ~335 Mac meeting-hours, and iPhone and in-person meetings use none of it.

## Languages (measured on macOS 26.6, this Mac, 2026-11-08)

Apple supports 30 of the 35 spoken meeting languages on-device:

- `SpeechTranscriber` (long-form model), 9 languages: en, de, fr, es, pt, it, zh, ja, ko.
- `DictationTranscriber` only, 21 languages: fi, sv, nb, da, nl, pl, cs, sk, hu, ro, hr, el, ru, uk, tr, ar, he, hi,
  id, vi, th.
- Not supported, 5 languages: et, bg, lv, lt, fa. These stay on the cloud live stream, as today.

The choice is made on the device at runtime (`appleSpeechChoice`), so differences in the iOS locale list are handled.
The language is fixed (automatic mode uses the primary meeting language), as with the hosted Deepgram stream today,
which doesn't detect language either.

## Decision: route each track

The pure functions in `Hosted/HostedLiveRoute.swift` are unit tested.

1. **"Diğerleri"** is always re-transcribed by the final pass. It goes on-device (`.onDevice`) when all of these hold:
   - the user is in the rollout (`liveOnDevice` from `/v1/me`);
   - the OS has `SpeechAnalyzer` (macOS 26+ or iOS 26+; the iPhone app also runs on iOS 18–25, where the preview is off);
   - Apple supports the language;
   - **its model is already installed.**

   Otherwise it follows the server: the cloud, or local when there is no cloud.
2. **"Sen" on Mac** stays with the server. Its live text is the saved text.
3. **Supported language, model not installed:** this meeting uses the cloud. The model is installed in the background
   for the next meeting, only on a network that is not expensive or constrained, outside Low Power Mode, and once per
   launch and language.
4. The Mac's two tracks run as two hybrid sub-sessions over the one recording (`runSplitHybridLiveSession`). Neither
   the recording nor `HybridRouter` changes. The events merge into one stream, which ends when both sub-sessions end.
   When every track routes the same way, the code path is exactly the old `runHybridLiveSession`.
5. Only the on-device tracks get the preview engine (`InstalledAppleSpeechEngine`, fixed language). It never
   downloads a model. Every other track keeps the regular local engine and the user's language mode, whether as the
   start (the server offers no cloud stream) or as the fallback when the cloud stream stops. On Mac that is WhisperKit,
   because "Sen"'s live text is its saved transcript (see Review).
6. The first grant declares how many tracks stream (`x-live-streams`), so the budget estimate is correct.
7. `RecorderStateMachine` is unchanged. The route is chosen once in the existing `awaitingServer` start stage and kept
   as a single value per recording: `hostedLiveRoutesInUse` on Mac, `liveRouteInUse` on iPhone.

## Fallback rule (explicit and visible)

| Situation | What happens |
|---|---|
| Unsupported language, older OS, model not installed, user outside the rollout, or flag at 0 | What the server offers, as today (cloud, or the local engine when there is no cloud). Nothing gets worse. Telemetry counts `on_device_live_unavailable` for users in the rollout, whatever the server offers. |
| On-device in use | The live screen's empty state says the live text is written on this device and a more accurate final transcript follows the meeting (Mac panel and main window, iPhone). Diagnostics on Mac shows "Bu Mac'te" or "Bu Mac'te ve bulutta". |
| On-device fails mid-meeting | Each failed segment shows its failure text. After 3 failed final segments in a row, the hybrid session emits `.streamFailed` ("metin akışı durdu"), once per track, and telemetry counts `on_device_live_failed`. The recording continues, and the final pass transcribes the whole track. |
| User switches mid-meeting to a language that isn't ready | Segments fail with "Bu dilin canlı metni bu cihazda yazılamıyor; toplantıdan sonra son metin yine hazırlanır." Nothing is downloaded. |

The live stream does not switch to the cloud mid-meeting, because that would need a local → cloud router path. This
is accepted for the pilot and measured with telemetry.

## Live translation

Live translation reads `LiveSegment` finals from `LiveSessionEvent.segment`, whatever the engine (`TranslationUnits`,
`LiveTranslationQueue`). The on-device engine emits partials and finals through the same `runTranscriptionPipeline`
that the iPhone fallback and the developer edition already use. All 37 translation languages keep working.

Quality is lower in two places:

- In the 21 dictation-only languages (Turkish and Finnish included), the live text, and so live translation and
  "Ne kaçırdım?", is weaker, and it gets no keyterms or attendee names.
- For the 5 unsupported languages the live stream stays on Deepgram.

## Battery and CPU

Measured with `OnDeviceLivePreviewEngineTests` (`AINOTEPAD_ONDEVICE_TESTS=1`, macOS 26.6, M-series). The fixtures are
fed in real time, 4× each, 94 s of audio in total:

| Where | CPU |
|---|---|
| Test process | 1.1 s |
| `localspeechrecognition` XPC service | 3.4 s |
| Total | 4.5 s, about 5% of one core |

Text quality on the fixtures:

- English: exact.
- Finnish dictation: correct, without punctuation.

`AppleSpeechEngine` re-analyses the open segment for every partial, every 1.5 s. Short segments keep that cheap, but
the cost grows with segment length.

No iPhone measurement was possible here. Before the rollout goes above the pilot share:

- the owner checks battery and heat on a device for a full hour;
- a streaming analyzer per track is the follow-up if that check shows heat.

The cloud path keeps the radio busy uploading 256 kbit/s of PCM for the whole meeting.

## Privacy

Audio for the tracks written on-device is not sent to Deepgram:

- "Diğerleri" on Mac;
- the whole room on iPhone and in in-person mode.

The final pass is unchanged. `web/src/pages/privacy.astro` now says three things:

- which tracks can be written on-device;
- that "Sen" on Mac still goes to Deepgram;
- that Apple's model is downloaded from Apple by the system.

It also says the attendee-name hints go to Deepgram only when Deepgram writes the live transcript. The App Store
privacy labels do not change: less data is shared, in the same categories.

## Rollout flag

- Server var: `ON_DEVICE_LIVE_PERCENT`, 0–100.
- `/v1/me` adds `liveOnDevice: boolean`, computed from a stable FNV-1a bucket of the user id (`server/src/onDevice.ts`).
  Raising the percent only adds users.
- Older apps ignore the field. A newer app treats a missing field (older server, rollback) as `false`.

| | Default |
|---|---|
| Development and tests | 100 |
| Production | 25 (pilot) |

Production goes to 100 after a week of telemetry and the owner's device check. The telemetry to watch:
`on_device_live_started`, `on_device_live_unavailable`, `on_device_live_failed`, and `final_pass_give_up` on those
meetings. Setting the var to 0 turns the preview off server-side immediately.

## Accepted risks

- **The final pass is skipped or fails** (no server session, ElevenLabs outage, an offline meeting that is never
  processed). The saved transcript is then the live text, which is Apple's instead of Deepgram's for "Diğerleri".
  - The existing notice says the live text was used, and "Tekrar işle" re-runs the final pass.
  - Tracked with `final_pass_give_up`.
- The live preview is weaker in dictation-only languages (see "Live translation").

## Review (two independent reviewers, 2026-11-08)

**Practicality reviewer: approve with changes.**

Adopted:

- new telemetry counters instead of reusing `onDeviceLive` (that one already means "fell back to Mac");
- the failure-path regression is stated under "Accepted risks";
- CPU measured before raising the rollout;
- the Deepgram stream count is fixed now, not as a follow-up;
- no mid-meeting model download.

Not adopted:

- **One local engine per meeting (Apple for "Sen"'s fallback too).** This was adopted first and then reverted after the
  pre-push review, which found a regression. When the server offers no cloud stream (budget used up, policy off), or
  the first grant fails, "Sen" would be written by Apple's dictation and saved that way. Before this change it was
  WhisperKit, with the user's language mode. "Sen" therefore keeps its regular engine, and only "Diğerleri" gets the
  preview engine.
- **"One router with per-speaker backends instead of two sub-sessions."** The concern was two sub-sessions sharing one
  recording sink. The sub-sessions don't share it: each has its own sink, and the wrapper forwards events and finishes
  the recording's stream after both. This leaves `HybridRouter`, and every existing path, unchanged. Tests cover a
  refused grant with "Sen" falling back while "Diğerleri" runs locally, iPhone with no cloud stream, and the failure
  threshold.
- **Version gating of the flag.** Unneeded, because old apps ignore the field.

Dissent (recorded):

- The reviewer would ship iPhone and in-person mode first (−67%, least code) and keep the Mac split at 0% until it has
  soaked, or do the Mac only together with phase 2 (re-transcribing "Sen" in the batch pass).
- The reviewer suggested keeping Deepgram for Turkish during the pilot.
- Kept as is: one flag at 25% covers both, and the owner's verification before release is the soak. The Turkish
  question is answered by the pilot's telemetry and the owner's own meetings (Turkish and Finnish) rather than by
  excluding the main market from the saving.

**Red-team reviewer: approve with changes.** Adopted:

| Finding | Fix |
|---|---|
| Final-pass failure regression | Stated under "Accepted risks" |
| Silent per-segment failures | Threshold that emits `.streamFailed`, plus telemetry |
| Automatic mode breaking Apple's engine | On-device sub-session uses `.fixed(liveLanguage)` |
| Telemetry mix-up | Separate counters |
| Budget claim wrong | `x-live-streams` and migration 0061 |
| `liveOnDevice` must be optional | Optional; missing means false |
| Privacy wording | Rewritten |
| Background download on cellular | Inexpensive network only, outside Low Power Mode |
| Mid-meeting download | `InstalledAppleSpeechEngine` never downloads |
| Diagnostics showed one engine for two tracks | Routes kept per track |

Not adopted:

- **Streaming analyzer per track.** This is a follow-up if the owner's device check shows heat.
- **Rejecting grants for users in the rollout.** Old clients behave as today, so this opens no new cost hole.

**Pre-push review:**

- `x-live-streams` is the client's own claim. A modified client could declare 1 stream and open 2, which would halve
  the budget *estimate* for its meetings. The per-meeting grant limits still apply (at most 8 grants in a 5-minute
  window). The real ceiling stays the prepaid Deepgram balance without auto top-up, and the estimate was never exact:
  the server can't see the streams.

Pre-push review nits, recorded as intended behaviour:

- **The 3-failures threshold applies to every local live session.** That includes Mac "Sen" on WhisperKit. A run of
  failed segments there now sets `meNeedsFinalPass`, so "Sen" goes through the final pass instead of being saved with
  holes. Before this change the gaps simply stayed in the saved text.
- **Automatic language mode with no cloud stream on Mac.** "Sen" on WhisperKit may lock a detected language after
  30 s, which the panel then shows, while the "Diğerleri" preview stays on the primary meeting language. This affects
  only the preview; the final pass detects the language itself.

## Follow-ups

- **Phase 2:** give "Sen" a second audio allowance on the server and re-transcribe it in the batch pass. That moves Mac
  live fully on-device: $0.27/h instead of $0.55/h.
- A streaming `SpeechAnalyzer` per track, if the device check shows heat.
- iPhone diagnostics show the server's offer rather than the last recording's route.
