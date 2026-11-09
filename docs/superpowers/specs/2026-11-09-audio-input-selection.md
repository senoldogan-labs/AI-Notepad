# Audio input selection (Mac + iPhone)

Status: implemented for 0.2.3. The owner reviews it before merge (it changes the recording path).

## Goal

When headphones or an external microphone are connected, Gistsmith adapts on its own, and people who want a specific
microphone can pick one. Plugging or unplugging a device never stops a recording.

## What the app did before

- iPhone: the recording session was `.playAndRecord` with `[.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]`.
  With no `.allowBluetoothHFP`, AirPods and other Bluetooth headset microphones were never used. There was no
  `setPreferredInput`, no input picker and no `routeChangeNotification` handling. `AVAudioEngineConfigurationChange`
  already rebuilt the engine, so an unplug did not end the recording.
- Mac: `AVAudioEngine.inputNode` followed the system default input. Settings › Voice typing only showed the default
  input's name and linked to System Settings. There was no picker and no per-app device.
- Echo: when the call plays through the speakers, the microphone ("Sen") also hears the other side. `suppressEchoes`
  / `suppressStoredEchoes` (`Session/EchoFilter.swift`) already remove a "Sen" segment when at least 50 % of its time
  overlaps "Diğerleri" and the trigram similarity is 0.6 or higher. This runs on the live view, the stored transcript,
  the notes and exports.

## Research (Apple sources)

| Topic | Finding | Source |
| --- | --- | --- |
| A2DP | Stereo and output only. With `.playAndRecord` it is opt-in (`.allowBluetoothA2DP`). | [allowBluetoothA2DP](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp) |
| HFP vs A2DP | If both options are set and one device supports both profiles, "the HFP ports will be given a higher priority for routing". AirPods would then switch to HFP, which means a narrow-band mic and lower output quality. | iOS 27.2 SDK `AVAudioSessionTypes.h`, `AllowBluetoothA2DP`; same text on the doc page above |
| HFP option | `.allowBluetoothHFP` (the renamed `.allowBluetooth`) makes HFP devices available **for input**. Bluetooth inputs only appear in `availableInputs` when this option is set. | [allowBluetoothHFP](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp); SDK header |
| AirPods high quality (iOS 26) | `.bluetoothHighQualityRecording` gives full-bandwidth AirPods recording with a "LAV microphone"-like tuning, in `.default` mode only. Combined with `.allowBluetoothHFP`, HFP is the fallback on routes that don't support it. Apple suggests `setPrefersNoInterruptionsFromSystemAlerts` alongside it, which we already set. | SDK header; [WWDC25 251 "Enhance your app's audio recording capabilities"](https://developer.apple.com/videos/play/wwdc2025/251/) |
| `defaultToSpeaker` | "plugging in a headset doesn't cause the route to change to headset mic … the route remains to the built-in mic and speaker". A **USB input-only accessory** is still used for input. | [defaultToSpeaker](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/defaulttospeaker) |
| `setPreferredInput` | Must be called after setting the category and mode and activating the session. The port must come from `availableInputs`. Passing `nil` clears the preference. The change can be asynchronous, so check `currentRoute`. | [setPreferredInput(_:)](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredinput(_:)) |
| `availableInputs` | Depends on the category and options (for example built-in mic plus headset mic). | [availableInputs](https://developer.apple.com/documentation/avfaudio/avaudiosession/availableinputs) |
| Route changes | `routeChangeNotification` arrives on a secondary thread. Its reasons include `newDeviceAvailable`, `oldDeviceUnavailable`, `categoryChange`, `override`, `noSuitableRouteForCategory` and others. | [routeChangeNotification](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangenotification), [RouteChangeReason](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangereason) |
| System input picker (iOS 26) | `AVInputPickerInteraction` (AVKit) shows the system input list with level meters, and the audio stack remembers the choice. It needs iOS 26 and doesn't know our "Automatic / room" rule, so we use our own picker, which also works on iOS 18. | SDK `AVInputPickerInteraction.h`; WWDC25 251 |
| Mac per-app device | `AUAudioUnit.setDeviceID(_:)` on `AVAudioEngine.inputNode.auAudioUnit` selects the HAL device, with the engine stopped. | macOS SDK `AUAudioUnit.h` |
| Format after `setDeviceID` (experiment on this Mac) | After `setDeviceID` to a 44.1 kHz device, `inputNode.inputFormat` reports 44.1 kHz but `outputFormat` (the client side the tap uses) stays at the previous device's 48 kHz. The engine reports "running", but the tap gets **0 frames**. Setting the client format on `auAudioUnit.outputBusses[1]` to the device's rate fixes it. | probe run with BlackHole 2ch at 44.1 kHz and the MacBook Air mic at 48 kHz |
| Engine stops on config change | When the I/O unit sees a hardware channel-count or sample-rate change, the engine stops itself and posts `AVAudioEngineConfigurationChange`. A notification that comes while the engine still runs with a matching format is harmless. | `AVAudioEngine.h` (`AVAudioEngineConfigurationChangeNotification`) |
| Mac device list | Read `kAudioHardwarePropertyDevices` and keep devices that have input streams (`kAudioDevicePropertyStreams`, input scope). Use `kAudioDevicePropertyDeviceUID` as the stable id and `kAudioDevicePropertyTransportType` for the kind. Watch `kAudioHardwarePropertyDevices` and `kAudioHardwarePropertyDefaultInputDevice` with `AudioObjectAddPropertyListenerBlock`. | Core Audio `AudioHardware.h` |
| Aggregate pitfall | Our system-audio tap builds a **private** aggregate device ("AI-Notepad Tap"). It shows up in our own process's device list and has input streams, so it is filtered out by name (`systemAudioTapDeviceName`). Other virtual or aggregate devices (BlackHole, Loopback, call apps' virtual devices) are listed as "virtual". Picking one can feed call audio into "Sen"; the echo filter then removes duplicates. | `SystemAudioCapture.swift` |
| System audio vs output | The tap follows the **default output** (the aggregate's main sub-device), not the input. Changing the input doesn't touch "Diğerleri". | `SystemAudioCapture.swift` |
| Echo cancellation | Voice processing (`setVoiceProcessingEnabled`) cancels only the engine's own playback and ducks other audio, which would duck the call. Not used. | macOS SDK `AVAudioIONode.h` |

## Decisions

1. **iPhone "Automatic" = the room microphone.** iPhone recordings are always in-person (iOS gives the microphone to
   the call app during a call). AirPods mics beamform on the wearer and HFP cuts quality, so Automatic never picks a
   Bluetooth headset. A USB microphone is used when plugged in (the system already does that with `defaultToSpeaker`).
   AirPods still play sound over A2DP.
   - Evidence: `defaultToSpeaker` and HFP routing docs above; WWDC25 251 describes the AirPods mic as a LAV-style
     tuning for the wearer.
2. **iPhone explicit choices are kinds, not devices:** iPhone microphone, AirPods / Bluetooth headset, Wired or USB
   microphone. iOS only lists Bluetooth inputs once HFP is enabled, so a device list would be empty for AirPods until
   picked. "Bluetooth headset" turns on `.allowBluetoothHFP`, plus `.bluetoothHighQualityRecording` on iOS 26, so
   supported AirPods record full bandwidth and others fall back to HFP.
3. **Mac "Automatic" = the system default input**, except in **in-person** recordings: if the default is a Bluetooth
   headset, the built-in microphone is used instead, for the same reason as on iPhone. Online calls and voice typing
   follow the default, which usually matches the call app. Explicit choices on Mac are specific devices (UID), plus the
   stored device as "(not connected)" while it is unplugged.
4. **A missing or failing choice falls back and says so, for as long as it lasts.** The recording never stops. If the
   chosen input is missing, the Automatic rule is used. On Mac, if the chosen device can't be opened (`setDeviceID`,
   format or `engine.start` fails), the system default input is used instead of retrying the same device; the fallback
   order comes from `audioInputAttempts`. While the choice is unavailable, the recording screen and panel keep showing
   "AirPods / Bluetooth headset isn't available; recording continues with iPhone microphone." On the Mac recording bar
   the mic menu shows `mic.badge.xmark`. When the device comes back, the next device change switches back, and a short
   "Microphone changed" notice is shown.
5a. **Each rebuild uses a fresh `AVAudioEngine`, and the tap waits for the hardware format.**
   - iPhone: after `setPreferredInput`, wait up to 1 s until `currentRoute` shows the target input. Then the tap is
     installed only if `inputNode.outputFormat.sampleRate == session.sampleRate`.
   - Mac: set the client format to the device's nominal rate, then check it (see the experiment above).
   - On a mismatch, `inputFormatNotReady` is raised and the build is retried. A tap is never installed with a stale
     format.
   - The active input is reported only after the route really switched (`settledActiveInput`).
   - Route, device and choice changes that arrive during a rebuild are queued (`mergedRouteChange`) and evaluated once
     afterwards, so they are not dropped.
   - A configuration notification is ignored while the engine is still running with a matching format, so one switch
     means one rebuild.
   - A choice change that keeps the same device (`needsCaptureRebuild`) doesn't rebuild at all.
5b. **An unreadable stored choice** (corrupt or from an older format) is a separate state (`readAudioInputChoice`). At
   recording start it is logged once and cleared, and the recording screen says so once. SwiftUI views read it without
   logging.
5. **One choice per device**, stored in `UserDefaults` (`audioInputChoice`, JSON) and **not synced**: microphones are
   specific to each device. Voice typing, Ask dictation and the keyboard use the same choice in the personal context.
6. **Recorder lifecycle unchanged.** A plug or unplug is not a `RecorderEvent`. `RecorderStateMachine` decides the
   recording's lifecycle, and a route change must never move it, so the recorder state machine stays untouched. The
   route decision lives in pure functions: `selectAudioInput`, `shouldReselectInput`, `audioInputChangeNotice`. The
   capture adapter (`MicrophoneCapture`) applies them on every (re)build. The apps keep one optional notice value and
   no flags.
7. **Echo: no new filter.** The existing text echo filter already covers speakers. The Mac settings row shows the
   output kind (built-in speakers / HDMI / DisplayPort / AirPlay = speakers) and a one-line explanation recommending
   headphones.

## Implementation

- Core, pure: `Audio/AudioInputSelection.swift` holds the choice, devices, selection, notice, reselect rule and
  storage. It posts `audioInputChoiceDidChange`, and running captures rebuild with the new input.
- Core, adapters:
  - `MicrophoneCapture` takes an `AudioInputRequest` provider.
  - iOS: applies `setPreferredInput` inside `AudioSessionQueue` after activation and observes `routeChangeNotification`.
  - Mac: `setDeviceID` before the tap, plus `MacAudioHardwareObserver`.
  - Reports `activeInput` / `onInputChange`.
- `Audio/MacAudioDevices.swift`: Core Audio listing, the default input, the output kind and the observer.
- UI:
  - Settings › Recording and languages › Microphone, on Mac and iPhone. Mac Voice typing shows the same row.
  - iPhone recording screen: a microphone chip under the level meter.
  - Mac: a microphone chip on the home record bar, a microphone menu on the recording bar, and a "Microphone"
    submenu in the menu bar while recording.
  - Notices: iPhone `MicrophoneNotice`; Mac panel notices (`microphoneNotices`).
- Debug: `--ornek-kayit --ornek-mikrofon` (iPhone) shows the "chosen AirPods not connected" notice.

## Tests

- `AudioInputSelectionTests` covers selection rules, fallback, reselect, notices, storage and Mac transport mapping.
- `AINOTEPAD_AUDIO_DEVICE_TESTS=1` lists this Mac's real devices (read only).
- `AINOTEPAD_MIC_DEVICE_TESTS=1` is a real capture test with **two different sample rates**:
  - The test sets the non-default input to 44.1 kHz (BlackHole 2ch) while the default (the MacBook Air mic) is at
    48 kHz, and restores the rate afterwards.
  - It opens the 44.1 kHz input, then switches live three times between Automatic (48 kHz) and that input.
  - After every switch it requires more than 4,800 new 16 kHz samples within 600 ms, `.running` status, the expected
    `activeInput` sequence, and no crash.
  - It passed on a MacBook Air. Before the client-format fix it failed: the tap received nothing, and the build fell
    back to the default input.

## Device test checklist (cannot be simulated)

iPhone (Gistsmith, TestFlight build):

1. AirPods connected, Microphone = Automatic, start an in-person recording. Recording uses "iPhone microphone" (chip).
   Music still plays through the AirPods afterwards. A person across the table is transcribed.
2. Same, Microphone = AirPods / Bluetooth headset. The chip shows the AirPods name. On iOS 26+ with AirPods Pro 2 or
   AirPods 4, audio quality is not "phone call" quality. On older AirPods, HFP works.
3. Recording on AirPods, take the AirPods out or put them in the case. Recording continues, the notice says AirPods
   isn't available and that the iPhone microphone is used (it stays until the AirPods are back), the level meter keeps moving, and there is no gap longer
   than about 1 s in the saved audio.
4. Put the AirPods back in during the same recording. It switches back with the notice "Microphone changed: AirPods…".
5. Wired EarPods (Lightning or USB-C adapter). Automatic: USB-C EarPods are used (USB), Lightning EarPods keep the
   built-in mic. "Wired or USB" uses the EarPods mic in both cases.
6. USB-C microphone (Rode or similar). Automatic picks it on plug-in during a recording and shows a notice. Unplug:
   back to the iPhone microphone, recording continues.
7. Change the microphone from the recording chip mid-recording, three times quickly. Recording continues, with no
   double audio and no crash.
8. Phone call during an AirPods recording: the existing "held by call" behaviour is unchanged, and the recording resumes
   on the chosen input.
9. Voice typing (keyboard) with AirPods chosen: it uses the AirPods.

Mac:

1. Settings › Recording and languages › Microphone lists all inputs. "Now: <default>" is correct, and plugging or
   unplugging a USB mic updates the list without reopening.
2. Pick a USB microphone and start an online-call recording. "Sen" comes from the USB mic, and "Diğerleri" (system
   audio) is unaffected.
3. Unplug that USB mic mid-recording. Recording continues on the system default, the panel notice appears, the level
   meter keeps moving, and Bluetooth headphones don't get stuck in HFP.
4. AirPods as the macOS default input, Automatic, **in-person** recording: the MacBook mic is used. The same in an
   online call: the AirPods are used.
5. Continuity microphone (iPhone as the Mac mic) appears as a choice and works.
6. Call audio on the built-in speakers: the settings row shows the speaker note, and the saved transcript has no
   duplicated "Sen" lines. With headphones, the note disappears.
7. Change the microphone from the menu bar submenu and from the recording bar during a recording.
8. Voice typing uses the chosen microphone.
