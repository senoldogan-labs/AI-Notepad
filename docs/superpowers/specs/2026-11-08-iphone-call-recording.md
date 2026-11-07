# Notes from phone calls on iPhone

Date: 2026-11-08. Status: phase 1 built; phase 2 (in-app dialer, US/Canada pilot) built and switched off: it waits for
the owner's Twilio account and the steps in "Turning it on" below. Earlier research on capturing call audio with iOS 27 ScreenCaptureKit:
[2026-11-03-iphone-call-capture-research.md](2026-11-03-iphone-call-capture-research.md).

## What iOS allows

- `AVAudioSession.h` (iPhoneOS 27.2 SDK): an app may play audio while another app hosts a call, "however, they are not
  permitted to capture the microphone of the active call, so attempts to activate a session with category
  AVAudioSessionCategoryRecord or AVAudioSessionCategoryPlayAndRecord will fail with error
  AVAudioSessionErrorCodeInsufficientPriority." This covers cellular calls and VoIP apps that host their call
  (WhatsApp, FaceTime, Teams, Zoom).
- `ReplayKit/RPError.h`: `RPRecordingErrorActivePhoneCall` (-5811, "Recording unable to record due to active phone
  call"). The ScreenCaptureKit headers on iOS 27 say nothing about call audio; the flagged experiment in
  `iOS/CallCapture/` still waits for a device test, and its system-audio stream is not expected to carry call audio.
- No public API reads the Phone app's own call recordings. The user can share the audio out of Notes.

So no third-party app can record a cellular call that the Phone app is hosting. There are two working designs:

1. The call is recorded by something that is allowed to: iPhone's own call recording (iOS 18.1+), which announces
   the recording to both sides and saves the audio to Notes. The user shares the audio to Gistsmith.
2. The app hosts the call itself: an in-app dialer places the call over VoIP to the phone network. The app owns the
   call's audio, so the iOS restriction doesn't apply. This is what Granola does.

## How Granola does it

- iPhone app, launched 2025-09-15 ("Introducing notes on phone calls",
  <https://www.granola.ai/updates/introducing-notes-on-phone-calls>).
- Help center (<https://docs.granola.ai/help-center/ios/phone-calls.md>):
  - **Outbound calls only**, placed from Granola's own keypad (phone icon, bottom left).
  - The call goes over Wi-Fi or mobile data, not over the plan's minutes. It is free to the user.
  - Setup verifies the user's number by calling them; the callee sees the user's own number as the caller ID.
  - Inbound calls are not supported ("iOS and Android limitations"); Granola suggests calling the person back.
  - Available in the Americas, Europe, Asia Pacific and South Africa. Exceptions: +91 to +91 calls and Telstra
    numbers in Australia.
  - No automatic recording notice to the callee.
- Granola's blog says "Apple doesn't allow third-party apps to access the microphone during cellular calls"
  (<https://www.granola.ai/blog/best-ai-note-taker-for-phone-calls-on-android-and-iphone>).
- Inference, not confirmed by Granola: the verification call comes from +1 415 723 4000, which is Twilio's
  Verified Caller ID number. The stack is most likely the Twilio Voice SDK (VoIP leg from the app), PSTN termination,
  and a verified caller ID.

Competitors: Otter and Fireflies import files or integrate with business phone systems; TapeACall and Rev Call
Recorder merge a recording line into a three-way call; Plaud uses a MagSafe vibration-sensing recorder.

## Options

| Option | iOS | Cellular, other side | VoIP apps | Consent | App Review | Cost | Notes |
|---|---|---|---|---|---|---|---|
| **A. iPhone call recording → share to Gistsmith (built)** | 18.1+ | Yes | No | iPhone announces it to both sides | Low | None | Not offered in every region (reported unavailable in the EU and possibly Turkey); two-person calls only; manual share step |
| B. In-app dialer (Granola) | any | Yes, outbound only | No | App must announce (spoken notice) | Medium: 2.5.14, 5.1.2(i), 1.1.6 | PSTN per minute (Twilio lists Turkey mobile at about $0.29/min) | Telephony account, number verification, fraud controls; caller ID problems in TR/EU (below) |
| C. Recording line merged into a call | any | Yes | No | Line must announce | Low–medium | Number + minutes | Carrier must support conference calls; awkward |
| D. ScreenCaptureKit system audio (flagged experiment) | 27+ | Very unlikely | Untested | System capture indicator only | Medium: `screen-capture` background mode for audio only | None | Device test pending |
| E. Speaker + microphone | any | No (session is interrupted) | Mostly no | — | — | None | Doesn't work |
| F. Call on the Mac | — | Yes (Continuity calls) | Yes | Gistsmith's own reminder | — | None | Already works: the Mac app records system audio and microphone |

## Decision

**Phase 1 (this change): A + F, no new entitlement, no cost.**

- The app registers audio document types (`CFBundleDocumentTypes` for `public.audio`, `LSSupportsOpeningDocumentsInPlace`
  = NO) and shows up in the share sheet for audio files. iOS copies the file to `Documents/Inbox`; the app receives
  it through `onOpenURL` (`PhoneSharedFileInbox`). The file waits there through sign-in. Then the existing import
  runs (`PhoneRecorder.importFiles`): server-side transcription with speaker separation, the note, tasks and sync,
  exactly like an imported or in-person recording. The inbox copy is deleted afterwards. The same path also works
  for Voice Memos, voice messages and Files, in every region.
- A "Phone call" guide opens from a phone button on the home screen's bottom bar, from the record options menu and
  from the library. It covers:
  - the consent reminder;
  - the three steps (record in the call, share the audio from Notes, note ready), with shortcuts to Notes and to
    "Choose from Files" for when Gistsmith is missing from the share sheet;
  - the region limits;
  - the Mac route for regions without call recording and for app calls.
- Why: it is the only design that works today without a third party hearing the call, without new money, and
  without App Review risk, and the iPhone's own announcement handles consent. It also covers incoming calls, which
  Granola doesn't.
- Known limits:
  - Not available where Apple doesn't offer call recording (reported for the EU, possibly Turkey, which are the
    owner's main markets). The guide says so and points to the Mac.
  - That Notes' "Share Audio" lists document-type apps is inferred, not verified. Verify it on a device; if Gistsmith
    is missing there, add a Share Extension with an App Group (see the checklist).

**Phase 2 (owner approved as a US/Canada pilot): Granola-style in-app dialer (B).** It's the only way to get an
outbound call recorded in regions without Apple's call recording. Built behind two switches and off: see "Phase 2:
in-app dialer pilot" below for the design, the provider comparison, costs, the App Review checklist and what the owner
has to do to turn it on.

The ScreenCaptureKit experiment (D) stays behind `CALL_CAPTURE_EXPERIMENT` (Debug only) until a device test shows
whether VoIP call audio reaches the system-audio stream; it is not expected to capture cellular calls.

## Device checklist (owner's iPhone, TestFlight build)

1. In a region with call recording: make a call, tap record (top left), and confirm both sides hear the
   announcement. End the call.
2. In Notes › Call Recordings, open the recording, then the audio's menu › Share (or "Share Audio"). Is **Gistsmith**
   in the app row?
   - Yes: tap it. Gistsmith opens, the home screen shows "Importing…", and the meeting appears with its note,
     transcript (two speakers) and tasks. It syncs to the Mac when sync is on.
   - No: report it (that means a Share Extension is needed). Use Save Audio to Files › Gistsmith › Phone call ›
     "Choose from Files" and confirm the import works.
3. Share a Voice Memos recording to Gistsmith: same result.
4. Signed out: share an audio file, sign in, and confirm the file imports after sign-in (it waits in the inbox).
5. Share a non-audio file through "Open in…": the app doesn't offer itself (only audio types are declared).
6. Home screen: the phone button opens the guide, "Open Notes" opens Notes, and "Choose from Files" closes the guide
   and opens the file picker.
7. Mac: answer an iPhone call on the Mac (Continuity) while Gistsmith records; confirm both sides are in the transcript.

## Phase 2: in-app dialer pilot

Built 2026-11-08 behind two switches, both off: the server's `PHONE_CALLS_POLICY` (production `off`, checked by
`server/test/wranglerConfig.test.ts`) and the iPhone build setting `PHONE_DIALER` (Debug `YES`, Release `NO`). The App
Store build contains no CallKit or Twilio code; the dialer appears only in a `PHONE_DIALER=YES` build, for a subscriber,
in an allowed country, while the server switch is on.

### How a call works

1. The phone call guide shows "Call from Gistsmith" when `GET /v1/phone` says `available` (switch on, the user's
   country — their verified number's, otherwise Cloudflare's IP country — in `PHONE_CALLS_COUNTRIES`, subscription).
2. First use: a disclosure (what is recorded, the spoken notice, Twilio as the carrier that keeps the recording until
   the note is made, own number as caller ID, no emergency calls) and an explicit opt-in (`POST /v1/phone/consent`,
   stored with its version).
3. The user verifies their own number: Twilio calls it and the user types the 6-digit code shown in the app (Twilio
   Outgoing Caller IDs). One account per number; 5 verification calls per day.
4. Dialing: the app classifies the number like the server (`PhoneDialNumber.swift` mirrors `server/src/phone/numbers.ts`,
   checked by `PhoneDialerParityTests`). Emergency and short numbers (911, 112, 988, N11…) open the Phone app with
   `tel:`. Premium and special ranges (NANP 900, 976, 5XX, 700, 710; Caribbean and US-territory area codes; Finnish and
   Turkish premium prefixes) and countries outside the allow-list are refused on both sides.
5. `POST /v1/phone/calls` reserves the call (below) and returns a 2-minute Voice SDK access token (outgoing only).
   CallKit starts the call (`CXStartCallAction`), the Twilio Voice SDK connects with the call id as a parameter.
6. Twilio asks `POST /v1/phone/webhooks/voice` (TwiML App Voice URL). The server accepts the reservation once and
   answers `<Dial callerId=<verified number> timeLimit=<max> answerOnBridge record="record-from-answer-dual">` to the
   destination stored at reservation time (never one from the webhook). `<Number url>` plays the notice to the callee
   after they answer and before the two sides are connected: "This call is recorded and transcribed by Gistsmith for
   the caller's notes." The app shows a red "Recording" pill for the whole call.
7. When the call ends, `<Dial action>` (or the TwiML App status callback) settles the cost; the recording callback
   stores the recording id. The app polls the call, downloads the two-channel MP3 through the server, imports it with
   the existing import (`PhoneRecorder.importSharedFiles`: server transcription with speakers, note, tasks, sync; the
   file name "Call with +1 212 555 0199" becomes the title) and deletes it at Twilio. Calls waiting for their
   recording survive an app restart; the server deletes unfetched recordings after a day.

Every webhook must carry Twilio's `X-Twilio-Signature` (HMAC-SHA1 with the auth token over the URL and form fields) and
our account SID, otherwise `403`. Numbers are personal data: a call's destination and caller ID are cleared when it
settles, logs mask numbers, rows are deleted 90 days after the call; account deletion deletes the phone rows and
queues the account's recordings and caller ID for deletion at Twilio.

### Why server-side recording

The phase 1 sketch tapped both audio streams in the app. Twilio's iOS SDK only exposes them through a custom
`TVOAudioDevice` (our own AudioUnit capture and render), which is a lot of real-time audio code that can't be tested
without an account and a device. Twilio's dual-channel recording on the `<Dial>` gives the same two sides with no audio
code in the app, keeps working when the app is suspended or killed mid-call, and starts only when the callee answers,
right before the notice. The cost is $0.0025/min and a recording that sits at Twilio until the app fetches it (at most
a day), which the disclosure says.

### Provider comparison (list prices read 2026-11-07)

Outbound per minute, USD:

| | US | Canada | Finland landline / mobile | Turkey landline / mobile | App (SDK) leg | Recording |
|---|---|---|---|---|---|---|
| **Twilio** | 0.0140 | 0.0140 | 0.4950 / 0.5172 (0.044 when the call originates from a US/EU number) | 0.0701 / 0.2875 | 0.0040 | 0.0025 (+0.0005/min·month storage) |
| Telnyx | ≈0.007 (0.002 API + 0.005 SIP) | not on the pricing page | not on the pricing page | not on the pricing page | 0.002 | 0.002 |
| Plivo | 0.0115 | 0.0120 | 0.6010 / 0.6010 | 0.053–0.060 / 0.3900 | 0.0033 | free |
| Vonage | ≈0.0139 (unverified: pricing pages refused automated reads) | — | — | — | €0.004 (unverified) | free (unverified) |

Other criteria:

| | iOS SDK | Own number as caller ID | Fraud controls |
|---|---|---|---|
| **Twilio** | 6.13.8 (2026-10-14), SPM, CallKit guide, custom audio device | Self-serve API (Outgoing Caller IDs: Twilio calls, user types a code) | Geo permissions per country and high-risk ranges; usage triggers, no hard spend cap |
| Telnyx | 4.2.3 (2026-11-03), SPM, CallKit guide | Verified Numbers (SMS or voice code, $0.03 each) | Outbound voice profile: country allow-list, daily spend limit, max destination rate |
| Plivo | stable 2.1.9 (2019), beta 3.3.1 (2024), CocoaPods only | Console only | Geo permissions, high-risk blocking |
| Vonage | 2.11.2, SPM, needs `-ObjC` | Manual, through support | Fraud Defender rules |

Decision: **Twilio** for the pilot: the most mature iOS SDK, a self-serve caller ID verification API, and every price
we need published. Telnyx is the cheaper alternative (about half per US minute) with a real daily spend limit; the
server talks to the provider through `VoiceProvider` (`server/src/phone/provider.ts`), so a Telnyx adapter replaces
only `twilio.ts` on the server, plus the iOS transport. Plivo (stale SDK) and Vonage (manual caller ID, prices not
verifiable) are out.

### Cost

Worst case per minute, all legs, as configured in `PHONE_USD_PER_MINUTE` (kept above the real price):

| Country | App leg + network + recording | Configured | 30-minute call |
|---|---|---|---|
| US | 0.004 + 0.014 + 0.0025 = 0.0205 | 0.025 | ≈ $0.62 |
| Canada | 0.004 + 0.014 + 0.0025 = 0.0205 | 0.025 | ≈ $0.62 |
| Finland (not enabled) | 0.004 + 0.044–0.517 + 0.0025 | — | $1.52–15.70 |
| Turkey (not enabled) | 0.004 + 0.070 / 0.288 + 0.0025 | — | $2.30 / $8.83 (mobile) |

Fixed costs: no Twilio phone number is needed (calls use the user's verified number); each verification call is a
short outbound call (≈ $0.02). Pilot example: 50 users × 60 minutes a month = 3,000 minutes ≈ $62 a month at list
price. The transcription and note of the imported recording cost what any recording does and count toward the plan's
monthly hours.

### Spend safety

- Each call reserves its worst case (longest duration + 1 minute of ringing and notice, × the country's price) in
  `phone_calls`. The reservation counts toward the global daily ceiling (`DAILY_SPEND_CEILING_USD`, through
  `todaySpendSql`) and the dialer's own `PHONE_DAILY_SPEND_CEILING_USD` (pilot: $10, must not exceed the global one).
  One conditional insert checks both ceilings, the user's monthly minutes, one call at a time and 30 calls a day, so
  concurrent requests can't pass them. The settled cost replaces the reservation (`daily_spend.phone_micro_usd`).
- Longest call `PHONE_CALL_MAX_MINUTES` (pilot: 60), enforced by Twilio (`timeLimit`), and never past the plan's
  remaining monthly hours. Monthly minutes per user `PHONE_MONTHLY_MINUTES` (pilot: 120, at most $3 a user a month).
- A call whose callbacks never come is charged its worst case by the daily cleanup; a reservation that never
  connected is released at no cost.
- Twilio-side guards (owner, below): geo permissions for the US and Canada only, high-risk ranges off, no auto-recharge
  (the prepaid balance is the hard cap), a daily usage trigger.

### App Review and legal checklist

- 2.5.14 (recording): spoken notice to the callee before connecting; a red "Recording" pill for the whole call; the
  disclosure before first use; the opt-in.
- 5.1.1 / 5.1.2(i) (data use and third parties): the disclosure names Twilio and what it keeps; the privacy policy and
  App Privacy labels must add the phone number (contact info), call audio (audio data) and Twilio as a processor
  before the pilot build goes beyond internal testing.
- 1.1.6 (no spoofing): caller ID is only the user's own number, proven by a call; one account per number.
- CallKit: not allowed in the China storefront. The App Store build has no CallKit until the owner removes China
  mainland from the app's availability; only `PHONE_DIALER=YES` builds use it.
- Emergency calls: the app never places them; it opens the Phone app.
- Microphone purpose string: the pilot build should say the microphone is also used for calls placed from Gistsmith.
- Law: US all-party-consent states (California, Florida, Illinois, Maryland, Massachusetts, Montana, New Hampshire,
  Pennsylvania, Washington and others) and Canada are covered by the notice before connecting plus the user's own
  consent; the disclosure tells the user to get consent. Turkey (TCK 133, KVKK) and the EU (GDPR) stay off: caller ID
  from abroad is blocked or flagged there (BTK, Traficom), Twilio's per-minute price is high, and the recording would
  leave the EU (Twilio US region).

### Turning it on (owner)

1. Twilio: create an account, upgrade it (card; minimum top-up $20). Leave auto-recharge off: the balance is the hard
   cap. Add a usage trigger (Console › Monitor › Usage triggers) on Calls at $10/day that emails you.
2. Voice › Settings › Geo permissions: allow only United States and Canada (low-risk numbers); leave high-risk special
   services off.
3. Account › API keys: create a Standard API key; note the SID (`SK…`) and secret.
4. Voice › TwiML › TwiML Apps: create one with Voice Request URL `https://api.gistsmith.com/v1/phone/webhooks/voice`
   (POST) and Status Callback URL `https://api.gistsmith.com/v1/phone/webhooks/call-status`; note the SID (`AP…`).
5. Secrets (from `server/`): `npx wrangler secret put <NAME> --env production` for `TWILIO_ACCOUNT_SID` (`AC…`),
   `TWILIO_API_KEY_SID`, `TWILIO_API_KEY_SECRET`, `TWILIO_AUTH_TOKEN` (Console › Account info) and
   `TWILIO_TWIML_APP_SID`.
6. A reviewed PR that sets `PHONE_CALLS_POLICY` to `on` in `env.production.vars` and updates `wranglerConfig.test.ts`;
   the deploy workflow rolls it out. With the switch on and a secret missing, every API request fails
   (`config_invalid`), so add the secrets first.
7. App Store Connect: remove China mainland from availability (CallKit); update the privacy policy and App Privacy
   labels; add review notes (test account with a verified number, how to reach the dialer).
8. Archive the pilot build with `PHONE_DIALER=YES` (next to `CALL_CAPTURE_EXPERIMENT=YES`, see AGENTS.md) and send it to
   internal TestFlight testers only.

### Rollout

1. Internal TestFlight (`PHONE_DIALER=YES`) with the server switch on, US/Canada numbers: run the dialer checklist below,
   watch the `phone_*` logs and Twilio's usage page for a week.
2. External TestFlight group in the US/Canada.
3. App Store: only after the China decision and the App Review items; then the Release default of `PHONE_DIALER`
   changes in a reviewed PR.
4. Finland, Turkey, EU: a separate decision (caller ID from a Gistsmith-owned local number with a regulatory bundle, EU
   data residency, price per minute).

### Risks

- US carriers give a verified-but-not-owned caller ID STIR/SHAKEN attestation B; some may label calls "Spam likely".
- Twilio's verification call speaks English only; the callee hears the notice in English (US/Canada; no Quebec French).
- The Twilio static SDK adds roughly 6–8 MB to a `PHONE_DIALER=YES` build (estimate; the simulator Debug build grew 16
  MB unstripped). The Release build links none of it and embeds only the framework's 64 KB privacy-manifest shell.
- Nothing here has placed a real call: the server is tested against a fake Twilio REST API and signed webhooks; the
  app's CallKit and SDK code only builds. The device checklist is the first real test.

### Dialer device checklist (`PHONE_DIALER=YES` build, server switch on, a US or Canadian number)

1. The phone call guide shows "Call from Gistsmith"; with the switch off, or from a country not allowed, it doesn't.
2. Disclosure: "Agree and continue" stays disabled until the toggle is on.
3. Verify your number: Twilio calls, you type the code, the app shows the keypad. The same number from a second account
   is refused.
4. Dial 911: the Phone app opens with 911 (don't call). Dial a 1-900 number: refused.
5. Call a second phone: it rings, the callee hears the notice before audio connects, the red pill shows throughout.
   Lock the screen, use mute and speaker, switch to AirPods, hang up from the lock screen.
6. After the call: the meeting "Call with +1 …" appears with two speakers, note and tasks; the recording is gone from
   Twilio's console.
7. Kill the app right after hanging up and reopen it: the recording is imported.
