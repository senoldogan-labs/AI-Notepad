# Gistsmith voice keyboard (iPhone)

Date: 2026-11-09. Target: iPhone 0.2.3. Status: spec reviewed (see "Review"), MVP built; the keyboard
only appears after the user adds it in iOS Settings.

## Why

Granola iOS 1.16.3 (App Store, 2026-11-08) ships "The Granola voice keyboard, featuring: voice typing, real-time
dictation, swipe typing, autocorrect, an emoji keyboard, your own dictionary, 50+ languages, and mechanical keyboard
mode". Wispr Flow and Typeless sell voice keyboards on iPhone. Gistsmith already has voice typing on the Mac
(`App/Dictation.swift`) and on-device dictation on iPhone (Ask field, `AppleDictationEngine`). The keyboard brings that
voice typing to every iPhone app.

## What the platform allows (verified)

| Fact | Source |
| --- | --- |
| "Custom keyboards, like all app extensions in iOS 8.0, have no access to the device microphone, so dictation input is not possible." Still the rule; every shipping voice keyboard hands off to its app. | App Extension Programming Guide, Custom Keyboard; Wispr Flow FAQ ("To turn on the mic from the Flow keyboard, iOS requires us to bring you back to the Flow app") |
| Without Full Access (`RequestsOpenAccess`) a keyboard has no network and **no shared container** with its app. Full Access adds the shared container, network, `UIPasteboard`, input clicks. | Same guide, Table 8-1/8-2 |
| Secure text fields and `phonePad`/`namePhonePad` fields always use the system keyboard; apps can reject all custom keyboards (`shouldAllowExtensionPointIdentifier`). | Same guide |
| Every keyboard must offer a way to the next keyboard; show it when `needsInputModeSwitchKey` and use `handleInputModeList(from:with:)`. | Same guide; `UIInputViewController.h` (27.2 SDK) |
| `hasDictationKey = true` disables the system dictation key under the keyboard (we provide our own). | `UIInputViewController.h` |
| `UILexicon` (`requestSupplementaryLexicon`) gives text shortcuts and contact names; `UITextChecker` gives guesses and completions. No API exists for autocorrect, autocapitalisation or double-space period: the keyboard implements them. A keyboard cannot show inline correction UI at the caret. | Same guide; `UILexicon.h` |
| App Review 4.4.1: keyboards must provide typed input, a next-keyboard method, **"remain functional without full network access and without requiring full access"**, collect activity only to improve the keyboard; must not "launch other apps besides Settings" or repurpose keys. 5.2.5: keyboards "may not include Apple emoji". 2.5.18: no ads in keyboards. 4.4: disclose the extension in the marketing text. | App Store Review Guidelines (fetched 2026-11-09) |
| No public API tells a keyboard which app hosts it, or returns the user from the containing app to the host app. Apple DTS (Jun 2026): "Is there a public, App-Store-safe API … to identify its host application? No." Enhancement request FB22247647 is open. | Apple Developer Forums thread 826851 |
| iOS 26.4 changed app switching: Wispr Flow can no longer always return the user automatically; the user swipes right on the bottom bar ("swipe-back behavior is an iOS 26.4 platform change and cannot be overridden"). | Wispr Flow help, "Adapting to iOS 26.4" (2026-03-31) |
| `UIApplication.openURL:options:completionHandler:` is not marked extension-unavailable (only `sharedApplication` is). Reaching the `UIApplication` instance through the responder chain is how shipping keyboards open their app; it is an implementation detail Apple may change. | `UIApplication.h` (27.2 SDK); forum threads 841057, 826851 |
| Keyboard memory limit is undocumented; field reports range 30–60 MB. Keep the extension small: no WhisperKit, no Speech, no `AINotepadCore`. | Fleksy blog; Stack Overflow reports |
| On-device dictation (`DictationTranscriber`, iOS/macOS 26+) supports 54 locales in 33 languages on macOS 26.6.2 (`ar ca cs da de el en es fi fr he hi hr hu id it ja ko ms nb nl pl pt ro ru sk sv th tr uk vi yue zh`). | `DictationTranscriber.supportedLocales`, run on this Mac |
| `SpeechAnalyzer.setContext(AnalysisContext)` with `contextualStrings[.general]`: "With the DictationTranscriber module, you can use this property to specify short custom phrases … names of characters, products, or places … Limit the total number of phrases across all tags to no more than 100." | Speech.swiftdoc, iPhoneSimulator 27.2 SDK |

### How the others do it

- **Granola** (App Store 1.16.3; iOS 18+): typing keyboard with swipe, autocorrect, emoji, dictionary, "50+ languages"
  (likely cloud dictation; their own docs list 17 mobile meeting languages), "mechanical keyboard mode". Their Mac
  voice typing keeps a **separate** dictation dictionary from the meeting jargon list ("you'd need to add a term to
  both"). App UI is English only. Privacy label: audio data and user content linked to the user.
- **Wispr Flow**: keyboard needs Full Access + microphone. Mic key opens the Flow app, which starts a "Flow session"
  (mic on, audio processed only between start and stop), then returns or asks the user to swipe back. Session length
  is a setting (up to "never"). Cloud transcription, 100+ languages.
- **Typeless**: AI voice keyboard via keyboard extension; swipe gestures switch keyboards.

## Design

### Keyboard (extension `GistsmithKeyboard`)

Built in SwiftUI inside `UIInputViewController`, linked only to a new dependency-free package target `KeyboardCore`
(layouts, autocorrect ranking, text-context rules, handoff protocol, emoji data). It never links networking code and
never sends keystrokes anywhere, with or without Full Access.

Works **without Full Access** (App Review 4.4.1):
- Layouts for the Latin-script languages of the app and its meeting languages: English (QWERTY), Turkish (Q), German
  (QWERTZ), French (AZERTY), Spanish, Italian, Portuguese, Dutch, Swedish/Finnish, Norwegian, Danish. Long-press
  shows accented letters. Numbers and symbols layers; email/URL fields get `@ . /` keys.
- Shift, caps lock (double tap), autocapitalisation per `autocapitalizationType`, double-space period, delete that
  repeats and speeds up to whole words, return key titled from `returnKeyType`, space-bar drag moves the cursor,
  globe key when `needsInputModeSwitchKey`.
- Suggestion bar and autocorrect: `UITextChecker` guesses and completions in the keyboard's language, `UILexicon`
  shortcuts, and the personal dictionary. Autocorrect replaces a word on space or punctuation only when the word is
  unknown and one candidate is clearly best (edit distance ≤ 2, ranking in `KeyboardCore`); backspace right after a
  correction restores the typed word and learns it. Personal-dictionary words are never corrected. Setting to turn
  autocorrect off.
- Emoji panel: Unicode emoji by category (system font; no bundled images, guideline 5.2.5) with recents.
- Light and dark from `keyboardAppearance`/trait; key labels fixed size like the system keyboard, panels and the
  suggestion bar honour Dynamic Type up to the keyboard's height.

Needs **Full Access** (each shows a one-line explanation and an "Open Settings" button when it is off):
- **Voice typing** (iOS 26+): see handoff below. On iOS 18–25 the mic key is hidden and the system dictation key
  stays.
- **Insert from Gistsmith** (opt-in in the app): the last 20 meetings with title and date; tap one, then "Summary",
  "Action items" or "My tasks" to insert that text. Data is a snapshot the app writes to the App Group container.
- Learned words always stay in the keyboard's own container, with or without Full Access; they never reach the
  app, the synced vocabulary or the server.

### Voice handoff

```
keyboard                       App Group (file + Darwin notify)           Gistsmith app
mic tap ──────────────────────▶ command{id,start,docID,lang,at}
  no live session?  open gistsmith://keyboard/dictate/<id> ──────────────▶ link valid only if command.json has the same
                                                                            id, action start, < 15 s old; then mic on
                                                                            (audio bg mode) and listening starts at once
                                                                            ("◀ back to your app" sheet shows live text)
  live session?     (no app switch) ─────────────────────────────────────▶ start DictationTranscriber + context
  user returns, live text strip  ◀── status{session heartbeat, listening, partial}
  tap ✓ / tap mic                ─▶ command{id,stop}          ───────────▶ finalize
  insert final text              ◀── status{finished, final text}
```

- One protocol model in `KeyboardCore` (`KeyboardDictationCommand`, `KeyboardDictationStatus`) and one pure state
  function `keyboardMicState(…)` drive the keyboard UI; tested.
- The session is a heartbeat in `status.json`: if it is older than 4 s the keyboard treats the session as gone.
- The keyboard re-reads its own last command from `command.json` when it reappears (a new extension instance after the
  app switch), so the strip shows the dictation it started; acknowledge or cancel closes the strip.
- The app keeps the microphone open for the session length (default 5 min after the last dictation; 1, 5 or 15 min
  in Settings) so the user can dictate again without the app switch. Audio between dictations is dropped, never
  buffered or written. The orange microphone indicator shows; "End session" is in the keyboard and the app.
- Dictation runs on the device (`DictationTranscriber`); no audio, text or keystroke leaves the phone and nothing
  counts against the subscription's minutes.
- **Vocabulary-aware**: the app passes up to 100 contextual strings (Apple's limit): the user's name, the Gistsmith
  recognition dictionary, saved people, and speaker names and terms from recent meetings (`recognitionKeyterms`). The
  same list feeds the keyboard's suggestion lexicon, so "Senol" and "Gistsmith" are neither misheard nor
  autocorrected. One dictionary for meetings, Ask and the keyboard (Granola keeps two).
- Recording a meeting takes the microphone: starting a recording ends the keyboard session; a mic tap during a
  recording comes back as the "A meeting is being recorded" failure in the strip. Ask's voice question also ends the
  keyboard session (one audio session).
- Return to the host app is manual (no public API): the app shows the iOS back button hint ("◀ Messages" in the
  status bar, or swipe right on the bottom bar).

### App

- `gistsmith://keyboard/dictate/<uuid>` and `gistsmith://keyboard/setup` links (`keyboardLinkRoute` in
  KeyboardCore; iPhone only, checked before `appLinkRoute`, so the Mac ignores them).
- Settings › Keyboard: setup status (keyboard seen, Full Access on), languages (layouts), session length, autocorrect,
  "Meeting notes in the keyboard" (off by default), dictionary (opens the existing recognition dictionary).
- Setup sheet (`HeroSheet`): what it does, three steps (Settings › Gistsmith › Keyboards › Gistsmith Keyboard, Allow
  Full Access), "Open Settings" (`UIApplication.openSettingsURLString`), live status ticks.
- App Group `group.com.senoldogan.AINotepad.hosted` on the app and the keyboard only (not the widget).

### Privacy

- Keystrokes: never stored by us beyond the learned-words list on the device, never sent.
- Voice: on-device, not stored.
- Meeting snapshot: only when the user turns it on; lives in the App Group container on the device, removed when
  turned off or on sign-out.
- App Privacy label: nothing new is collected (no data leaves the device). Privacy policy gets a "Gistsmith Keyboard"
  section that says exactly this. Extension gets its own `PrivacyInfo.xcprivacy` (UserDefaults reason `1C8F.1`).
- Marketing text and release notes name the keyboard (guideline 4.4).

## Scope

### 0.2.3 (this PR), quality bar

Design changes from the review (table above) are part of the scope.

Ships only if, on a real device: extension cold start under 250 ms, peak memory under 40 MB with the emoji panel
open, typing latency feels like the system keyboard (no dropped taps at speed), no crash or
memory kill in 30 minutes of mixed typing/emoji/voice, autocorrect never "corrects" a dictionary word, and the voice
round trip works in Messages, Notes, Mail, Safari and WhatsApp.

Typing keyboard (11 Latin layouts), suggestions + autocorrect + personal dictionary + learned words, emoji, voice
typing with handoff and vocabulary context, Insert from Gistsmith, app settings and setup, 11 UI languages, privacy
docs.

### Moved into 0.2.3 by the owner (follow-up PR)

Owner decision (2026-11-09): the deferred keyboard features ship in 0.2.3 too, each only if it meets a measured bar.

- **Ask Gistsmith from the keyboard, without the account token in the extension.** The keyboard gets an Ask field
  (sparkles button): keys type into the field, not the document, and selected text pre-fills it. "Ask" writes
  `ask.json` (question ≤ 500 characters, request id, document id) and opens `gistsmith://keyboard/ask/<id>`; while the
  microphone session keeps the app running it only posts a Darwin notification. The app asks only for a fresh (≤ 15 s)
  matching command, with its own signed-in session through the Siri path (`PhoneAsk.askForIntent`: all meetings, sample
  meeting excluded, plan and trial rules, one question at a time, kept in Ask history), inside a background task so the
  answer finishes after the user switches back. It writes only the plain answer text (`plainAnswerText`) to
  `ask-answer.json` (`.complete` protection, no backup). The keyboard shows "Gistsmith is checking your meetings…", then
  the answer with **Add**; adding or dismissing deletes the file at once. An unused answer is not shown after 10
  minutes and is deleted then if the app is still running, otherwise when the keyboard appears or the app becomes
  active next. Failures show the app's reason (subscription,
  trial, network) in the keyboard. Logic in `KeyboardAsk.swift`, 7 tests.
- **Swipe typing.** SHARK²-style matcher (`KeyboardSwipe.swift`): location distance + normalised shape distance +
  length ratio + endpoint distance + "letters the path never reached" + a small frequency prior. Candidates come from
  the device's own dictionary: `UITextChecker.completions` (Apple documents them as most-probable-first) for the 2- and
  3-letter prefixes the path suggests (≤ 48 queries), plus the personal vocabulary and learned words. No word list ships
  and nothing goes online, so there is no data licence to track. Best word inserted with automatic spacing and the
  user's shift state; the next two stay in the bar (tap to replace); delete right after removes the whole word. Only on
  the letters page, only where iOS has a dictionary for the language; setting on by default.
  **Benchmark** (`KeyboardSwipeBenchmark`, `AINOTEPAD_SWIPE_BENCH=1`): 3 synthetic swipes per common word (key
  centres jittered by σ = 0.22 key widths, corners cut by smoothing, ±0.6 pt jitter; 390-pt iPhone layout),
  candidates from macOS `NSSpellChecker` completions (same kind of ranked list as `UITextChecker`):

  | Language | Swipes | Top-1 | Top-3 |
  | --- | --- | --- | --- |
  | English | 240 | 92.1% | 95.4% |
  | Turkish | 180 | 86.7% | 88.9% |
  | German | 150 | 99.3% | 100.0% |
  | Finnish | 120 | 90.8% | 94.2% |

  All four pass the ≥ 80% top-1 bar on common words. Synthetic swipes are cleaner than real thumbs; the device
  checklist adds a real-hand check.
- **Mechanical keyboard mode.** Off by default; with Full Access it plays one of four sounds and a light rigid haptic.
  The sounds are synthesized by `scripts/make-keyboard-sounds.py` (click + damped body resonance, fixed seed; ~47 KB of
  CAF), so we own them outright. `scripts/elevenlabs-keyboard-sounds.sh` holds the exact prompts for a more realistic
  pack via ElevenLabs Sound Effects; it is not run (it costs credits: $0.12 per generated minute, commercial use only
  for sounds made on a paid plan — verify the current Service-Specific Terms first).
- **Emoji skin tones.** A tone button in the emoji panel cycles six tones; applied only to the 316 emoji for which
  Unicode 15.1 defines all five toned forms (generated from emoji-test.txt, Unicode License).

### Still deferred

| Item | Why not now |
| --- | --- |
| Emoji search | Needs a search field typed with the keyboard's own keys while the emoji grid is visible, plus localized CLDR annotations for 11 languages; not worth rushing. |
| Japanese, Korean, Chinese typing | Needs input methods (kana/romaji, Hangul composition, pinyin candidates). Voice typing works in those languages now; typing uses the system keyboard via the globe key. |
| Automatic return to the host app | No public API (FB22247647); file our own round-trip ER. |
| Mac voice typing with vocabulary context | Same `setContext` change in the shared engine; Mac voice typing already works, ship after the iPhone path is proven. |
| Granola's "50+ languages" | We ship 33 on-device dictation languages (Apple's list). Cloud dictation would cost per minute and send audio off the phone. |

### Mac parity

The Mac already has voice typing (global shortcut, paste into any app); it does not need a keyboard. The new
vocabulary-aware path (`AppleDictationEngine.transcribe(…contextualStrings:…)`) is in the shared engine; switching Mac
voice typing and the Ask voice question to it is the 0.2.4 parity item.

## Built (0.2.3 PR)

- `Packages/AINotepadCore/Sources/KeyboardCore/`: layouts, geometry and hit testing, text rules, autocorrect ranking,
  handoff protocol and state, shared models, App Group bridge, emoji data; `Tests/KeyboardCoreTests/` (37 tests).
- `iOSKeyboard/`: the extension (UIKit key grid, SwiftUI bar and panels), entitlements, privacy manifest.
- `iOS/Keyboard/`: `PhoneKeyboardHost` (session, dictation, shared files) and the settings, setup and session screens.
- Simulator check (iPhone 17, iOS 26.5): keyboard added in Settings, typing and Turkish autocorrect with undo, emoji,
  Full Access off panel, Full Access on → mic opens Gistsmith with "◀ Reminders", the session sheet appears, the
  status comes back to the keyboard strip; dark mode; largest text in the app screens. On-device transcription is not
  available in the Simulator (`noAudioFormat`), so dictation text needs a real device.

### Device checklist additions (follow-up PR)

1. Swipe in EN, TR, FI, DE with a real thumb, one-handed and two-handed: common words land first; the bar alternative
   replaces the word; delete removes the whole swiped word; no lag on a slow device (≤ 48 dictionary queries per swipe).
2. Swipe does not trigger on fast taps or on slides between neighbouring keys; long-press accents still work.
3. Ask from the keyboard in Messages and Notes: answer appears after returning, **Add** inserts it, X dismisses it, no
   answer shows after 10 minutes; with the microphone session live, Ask works without the app switch.
4. Ask while signed out / trial not started / subscription ended: the reason shows in the keyboard.
5. Mechanical sound on and off; silent switch mutes it; Full Access off → no sound.
6. Skin tones in recents and in the grid; the tone survives a keyboard restart.

## Risks

- **Guideline 4.4.1 "must not launch other apps besides Settings".** We open our own containing app from the mic key,
  as Wispr Flow, Granola and Typeless do. Review notes will say so and that typing works fully without Full Access. If
  rejected: mic key falls back to telling the user to open Gistsmith and tap "Start voice session" (no app launch).
- Responder-chain URL opening can break in an iOS update (Apple calls it an implementation detail). The keyboard checks
  the completion result and shows the manual instruction if it fails.
- Background microphone: the session relies on the `audio` background mode the app already has for recording.
- Memory: extension stays small (no Speech, no WhisperKit, emoji table as one static string array).

## Review (2026-11-09)

Two independent reviewers read the first draft: a product/UX reviewer and an App Review/privacy red team. Decisions:

| Finding | Reviewer | Decision |
| --- | --- | --- |
| Learned words flowing into the synced recognition dictionary would send keystrokes to the server (Deepgram keyterms, sync) and break 4.4.1. | Red team, BLOCKER | **Accepted.** Data flows app → keyboard only. Learned words stay in the keyboard's own storage. |
| `gistsmith://keyboard/dictate` would let any app or web page start a warm microphone. | Red team, BLOCKER | **Accepted.** The app starts a session only for a pending command in the App Group with the same request id, written in the last 15 s; otherwise the link opens setup without the microphone. |
| 4.4.1 "launch other apps" risk; don't `perform` an `openURL:` selector string. | Red team | **Accepted.** Typed responder-chain walk to `UIApplication`; review note text below; build setting `KEYBOARD_OPENS_APP` (YES) switches the mic key to the no-launch instruction without new code. |
| Microphone purpose string must mention keyboard dictation, in every language. | Red team | **Accepted.** |
| 60-minute warm session strains 2.5.4 and trust. | Red team; UX dissent on wording | **Accepted.** 1, 5 (default) or 15 minutes; the engine stops fully at session end, when a recording starts, on audio interruption and when the phone locks. Keyboard shows the remaining time. |
| Final text written to a file contradicts "not stored"; text could land in a different field. | Red team | **Accepted.** Status file uses `.complete` protection, is cleared once the keyboard inserts, and text is inserted only into the same document (`documentIdentifier`) that asked for it. |
| Meeting snapshot protection and lifecycle; meeting-derived names in the keyboard lexicon are meeting data. | Red team | **Accepted.** `.completeUnlessOpen`, excluded from backup, rewritten on every meeting change and account change, deleted when off. People and meeting terms reach the keyboard only with "Meeting notes in the keyboard" on; otherwise only the user's name and their own dictionary. |
| Sensitive fields. | Both | **Accepted.** No learning and no autocorrect when `autocorrectionType == .no`, or `textContentType` is one-time code, password, new password, credit card, username or telephone; words containing digits are never learned. |
| Privacy manifests (`CA92.1` + `1C8F.1`), no telemetry or crash SDK in the extension, no logging of text. | Red team | **Accepted.** The extension links only `KeyboardCore` and has no logger. |
| `hasDictationKey` only when voice typing is usable; hide the mic key on iOS 18–25. | Both | **Accepted.** |
| Key popups, touch-down input, multi-touch rollover; SwiftUI gestures drop taps. | UX, MUST | **Accepted.** Key grid is a UIKit view with its own touch handling; panels stay SwiftUI. Adaptive hit areas → 0.2.4. |
| Turkish casing, contractions, apostrophes. | UX, MUST | **Accepted**, in `KeyboardCore` with tests. |
| Typed word in quotes in the suggestion bar; don't re-correct a reverted word in the same field. | UX, MUST | **Accepted.** |
| iPhone Duo inner screen and landscape. | UX, MUST | **Accepted.** Regular width centres the keys at a phone-like width. |
| First-use model download breaks the first dictation. | UX, MUST | **Accepted.** Setup prepares the dictation model with progress. |
| Speech lost while switching back. | UX, MUST | **Accepted.** The app starts listening as soon as it opens for a valid request and shows the live text; the keyboard picks the same dictation up when the user returns. |
| Haptics and clicks need Full Access. | UX | **Accepted**, stated in setup; no sound or haptic without it. |
| Autocorrect only for languages proven on device. | UX | **Accepted** as a runtime rule: autocorrect runs only where `UITextChecker.availableLanguages` has the language; the device checklist covers EN/TR/DE/FR/ES. Bilingual users: a word valid in another enabled language is never corrected. |
| Filler-word cleanup with on-device Foundation Models as the "beat" feature. | UX, SHOULD | **Deferred to 0.2.4** (only on Apple Intelligence devices; needs its own quality eval). |
| "Insert from Gistsmith" as an explicit yes/no in setup, not buried. | UX dissent | **Accepted.** Last setup step; titles appear only after the user opens the panel (screen sharing). |
| Number row. | UX | Long-press on the top letter row gives the digit; a number-row setting → 0.2.4. |
| Quality bar: cold start < 250 ms, peak memory < 40 MB with emoji open, Turkish casing test. | UX | **Accepted** (device checklist). |
| "Insert from the live meeting" while recording. | UX, NIT | Deferred to 0.2.4. |

Dissent kept on record: the UX reviewer would rather avoid the orange dot between dictations altogether (one extra
app switch per dictation); we keep a short warm session (default 5 min, max 15) because that is what makes repeated
dictation usable, and it ends on lock. The red team notes that the Wispr Flow precedent lowers but does not remove the
4.4.1 risk; the `KEYBOARD_OPENS_APP` switch is the prepared answer.

App Review note (paste into App Store Connect):

> Gistsmith Keyboard is a full typing keyboard that works without Full Access. Keyboard extensions cannot use the
> microphone, so when the user taps the microphone key (only with Full Access on), the keyboard opens Gistsmith itself
> to start on-device dictation; it opens no other app and repurposes no key. Dictation runs on the device with Apple's
> speech recognition, the microphone stays ready for at most 15 minutes (default 5) with the system microphone
> indicator and an End button, and nothing typed or spoken is sent to any server.
