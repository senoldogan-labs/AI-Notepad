# Notes from phone calls on iPhone

Date: 2026-11-08. Status: phase 1 built (this change); phase 2 waits for the owner (telephony account and per-minute
cost). Earlier research on capturing call audio with iOS 27 ScreenCaptureKit:
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

**Phase 2 (owner decision): Granola-style in-app dialer (B).** It's the only way to get an outbound call recorded in
regions without Apple's call recording. It needs the owner's telephony account, secrets and money, so it isn't built
here. Recommended shape:

- iOS: Twilio Voice SDK (Swift package; pinned in `Config/Package.resolved`) + CallKit, outbound only. The app taps
  the call's audio (local microphone = "You", remote = "Others") into the existing two-stream live recorder
  (`startHybridRecording(meAudio:othersAudio:)`, as on the Mac). The audio is not stored by Twilio (no
  `<Dial record>`).
- Server (Worker):
  - a token endpoint (Twilio access token with a Voice grant, scoped to the signed-in account);
  - a TwiML endpoint that plays a spoken recording notice to the callee before bridging;
  - caller-ID verification per account;
  - a destination allowlist (Twilio Geo Permissions), blocked premium-rate and emergency numbers (emergency numbers
    hand off to the native dialer with `tel:`);
  - per-account minute and spend caps, counted against the plan's monthly meeting minutes;
  - a server feature flag so the dialer can be turned on per region.
- Risks to settle before signing up:
  - Caller ID: Turkish operators (BTK) and several EU regulators block calls from abroad that present a domestic
    number of a subscriber who isn't roaming. Showing the user's own +90 number from a Twilio leg would be blocked or
    flagged as spoofing. Options: a Gistsmith-owned local number (regulatory bundle) or no dialer in those markets.
  - Cost: about $0.29/min to Turkish mobiles (Twilio price list), so a 30-minute call costs about $8.60, close to a
    month's subscription. US/Canada are about 1–1.5¢/min.
  - App Review:
    - 2.5.14: a visible recording indicator throughout the call, and a spoken notice;
    - 5.1.2(i): name the third-party processors that receive the call audio and get consent;
    - 1.1.6: no anonymous or spoofed calls;
    - CallKit is not allowed in the China storefront.
  - Law: Turkey TCK 133 makes recording a non-public conversation without the other side's consent a crime, even
    for a participant; KVKK and GDPR require notice and a lawful basis; US all-party-consent states require the notice
    before recording starts.
- Suggested rollout: US/Canada pilot behind the server flag; decide TR/EU after the caller-ID question.

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
