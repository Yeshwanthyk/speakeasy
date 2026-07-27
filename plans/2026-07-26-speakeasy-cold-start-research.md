# Speakeasy Long-Idle / Cold-Start Failure Research

**Date:** 2026-07-26  
**Symptom:** After Speakeasy has been running but unused for a long time (potentially across sleep, wake, or device changes), its hotkey produces a macOS-style error beep and no useful operation. Relaunching Speakeasy restores operation.

## Executive finding

**The captured 2026-07-26 incident is confirmed: Speakeasy ignored an `AVAudioEngine` configuration change after its input device died, so its audio tap stopped delivering samples while the app continued to report itself prepared.** Hours later, two recording attempts contained 6,400 stale pre-roll samples and exactly 0 active samples. Speakeasy classified each as too short/no speech and reduced that error to a system beep. Relaunching rebuilt the engine, tap, format, and converter; the next recording immediately captured 30,419 active samples and pasted successfully.

Apple documents the exact platform transition: an I/O channel-count or sample-rate change causes `AVAudioEngine` to **stop and uninitialize itself** before posting `AVAudioEngineConfigurationChangeNotification`.[^audio-config-change] Speakeasy starts one engine and installs one input tap at launch, then permanently trusts its own `isPrepared` flag. It does not observe that notification, sleep/wake, engine running state, or callback freshness, and `beginRecording()` does not validate or restart the engine.

A fresh-launch model-warmup gate can produce the same beep in other circumstances: the hotkey is registered before asynchronous warmup finishes, and a press while warmup is pending/warming intentionally does nothing except request error feedback (`Sources/AppCoordinator.swift:322-329`, `:364-371`; warmup launched at `Sources/AppDelegate.swift:47-49`). It did **not** cause this captured incident; the failing old process reached `Recording started` twice and then reported 0 active samples.

The beep is not diagnostic by itself: Speakeasy deliberately maps every `UserFeedbackEvent.error` to `NSSound.beep()` (`Sources/UserFeedback.swift:4-16`), while discarding the error message. Apple defines `NSSound.beep()` as playing the system beep.[^nssound-beep] The same sound can therefore mean model warmup, short/silent audio, transcription failure/timeout, accessibility denial, paste-event construction failure, or a target application's rejected Cmd-V.

## Captured incident reconstruction

Unified logs provide a red-capable signal and the full causal chain:

1. **16:26:15.793 — input route failed:** CoreAudio logged `Device 417 died!`, disconnected the aggregate device, and reconnected the process to input device 78.
2. **16:26:15.852 — invalidation delivered:** `AVAudioEngine` logged `iounit configuration changed > posting notification`. Speakeasy has no observer, so no application recovery followed.
3. **21:46:14–21 — stale capture failed twice:** process 5717 logged two recordings with `6400 samples (0 active, 6400 preroll), RMS=0.0000`, both ending as `outcome=noSpeech`. The first outcome was immediately followed by a connection to `com.apple.audio.SystemSoundServer-OSX`, consistent with `SystemFeedback` calling `NSSound.beep()`.
4. **21:46:30 — relaunch rebuilt capture:** fresh process 46745 logged `AudioCapture engine armed and running (idle)`.
5. **21:46:31–33 — recovery proved:** the first post-relaunch recording contained `36819 samples (30419 active, 6400 preroll), RMS=0.0057` and ended as `outcome=pasted`.

The **first contract divergence** is step 2: Apple invalidated the engine and notified the app, but Speakeasy retained `isPrepared == true` and never rebuilt the graph. The five-hour idle interval exposed the failure; elapsed time itself did not break the app.

## Actual API surface (important exclusions)

| Concern | What Speakeasy actually uses | Exact call sites | Consequence |
|---|---|---|---|
| Audio capture | `AVAudioEngine`, `AVAudioInputNode.inputFormat`, `installTap`, `prepare`, `start`; `AVAudioConverter` | `Sources/AudioCapture.swift:92-154` | One graph/tap/format/converter is created once at launch. |
| Audio lifecycle | Only `stop` + `removeTap` at app termination | `Sources/AudioCapture.swift:233-257`; `Sources/AppDelegate.swift:56-57` | No runtime recovery path. |
| Microphone permission | `AVCaptureDevice.authorizationStatus` / `requestAccess` | `Sources/Permissions.swift:15-32`, called only at `Sources/AppDelegate.swift:20-25` | Permission is checked at launch, not before later captures. |
| Global hotkey | Carbon `InstallEventHandler` + `RegisterEventHotKey` | `Sources/KeyComboMonitor.swift:54-92`; callback dispatch at `:104-137` | This is **not** a Core Graphics event tap and **not** an `NSEvent` global monitor. |
| Accessibility | `AXIsProcessTrusted[WithOptions]` | `Sources/Permissions.swift:35-47`; delivery-time check at `Sources/AppCoordinator.swift:493-497` | Relevant to synthetic paste, not hotkey registration or audio capture in this implementation. |
| Synthetic paste | `NSPasteboard.general`, `setString`, synthetic Cmd-V via `CGEvent.post(tap: .cghidEventTap)` | `Sources/PasteboardPaster.swift:14-53` | `.cghidEventTap` here is a **posting location**, not a tap object owned by Speakeasy. |
| Menu-bar process | `LSUIElement=true`, activation policy `.accessory`, `NSApplication.run()` | `Info.plist:19-20`; `Sources/main.swift:3-7` | Normal long-lived AppKit agent process with a main event loop. |
| ASR resources | GGUF path resolution, native `Model::load`, one persistent native session, Metal feature | `Sources/ModelPathResolver.swift:275-335`; `Sources/TranscribeCppTranscriber.swift:47-95`; `rust/asr_bridge/src/lib.rs:85-118`; `rust/asr_bridge/Cargo.toml` | Model/session is constructed and warmed at launch, then reused indefinitely. |

There are **no repository calls** to `AVAudioSession`, `CGEventTapCreate`, `CGEventTapEnable`, `NSEvent.addGlobalMonitorForEvents`, `NSWorkspace.willSleepNotification`, or `NSWorkspace.didWakeNotification`. iOS `AVAudioSession` route/interruption/media-services-reset guidance therefore does not directly describe this macOS implementation.

## Relevant platform contracts correlated to code

### 1. `AVAudioEngine` configuration changes invalidate Speakeasy's assumptions

Apple states that when an engine I/O unit observes an input/output hardware **channel-count or sample-rate change**, the engine **stops, uninitializes itself, and posts `AVAudioEngineConfigurationChangeNotification`**. Attached nodes remain connected with their prior formats; the app must reestablish connections if formats need to change. Apple also warns not to deallocate the engine synchronously inside that notification callback.[^audio-config-change]

**Repository correlation:**

- Speakeasy snapshots `inputNode.inputFormat(forBus: 0)` once (`Sources/AudioCapture.swift:105-106`).
- It constructs one converter using that format (`:117-126`).
- It installs one tap with that explicit format (`:129-135`).
- It calls `prepare()` and `start()` once (`:137-154`).
- Its own `isPrepared` becomes `true` *before* those operations and remains true unless initial startup fails or the app terminates (`:92-103`, `:233-257`).
- It never observes the configuration-change notification and never reads a fresh input format.

Apple documents that `AVAudioEngine.start()` can fail for an invalid graph, an audio-unit error, or a hardware-driver start failure.[^audio-start] Speakeasy handles those errors only during initial launch (`Sources/AudioCapture.swift:138-151`). There is no equivalent start/recovery attempt after long idle.

Apple allows installing/removing taps while an engine is running and permits only one tap per bus.[^audio-install-tap] Speakeasy correctly removes its tap if initial `start()` fails and at shutdown (`Sources/AudioCapture.swift:149`, `:247-248`), but it has no tap replacement lifecycle for a later hardware reconfiguration. Apple describes `reset()` as resetting all engine nodes (for example, clearing delay/reverb tails), not as a documented substitute for rebuilding stale I/O formats.[^audio-reset]

`beginRecording()` merely drains a semaphore, copies pre-roll, marks `isRecording`, and clears/reserves buffers (`Sources/AudioCapture.swift:157-183`). It does **not** call `engine.isRunning`, read the current input format, reinstall the tap, prepare, start, or test callback freshness. A dead engine can therefore leave the coordinator in a logically recording state.

Apple provides explicit AppKit notifications for system sleep and wake via `NSWorkspace.notificationCenter`.[^workspace-sleep][^workspace-wake] Speakeasy observes neither, so it has no wake-time revalidation point.

### 2. Permission can change while a long-running process remains alive

Apple says users can change capture authorization at any time, and denied/not-yet-granted recording produces silence.[^capture-auth]

**Repository correlation:** Speakeasy checks audio authorization only during launch (`Sources/AppDelegate.swift:20-25`; `Sources/Permissions.swift:15-32`). It does not recheck before `AudioCapture.beginRecording()`. A permission transition while Speakeasy remains alive can therefore appear as silent/empty capture and can coincide with an engine configuration transition. A relaunch reruns both authorization checking and complete engine construction.

Accessibility trust is checked at startup for guidance and again immediately before delivery (`Sources/AppDelegate.swift:27`; `Sources/AppCoordinator.swift:493-497`). Apple documents that `AXIsProcessTrusted()` reports current trust, while `AXIsProcessTrustedWithOptions` can asynchronously prompt and that prompting does not change the immediate return value.[^ax-trusted][^ax-options] Thus a revoked/stale accessibility grant can explain a **post-transcription** beep and no paste, but not failure to start recording.

### 3. The hotkey is Carbon, not a timeout-disableable `CGEventTap`

Apple's Carbon event model dispatches registered event types to installed handlers through the application event loop.[^carbon-events] Apple/DTS identifies `RegisterEventHotKey` as one global-key option but calls it tightly coupled to legacy Carbon and prefers `CGEventTap` for modern TCC-aware monitoring.[^global-hotkey-dts]

**Repository correlation:** Speakeasy installs a `kEventHotKeyPressed` handler on `GetApplicationEventTarget()` and registers Cmd-Control-Option-Shift-S (`Sources/KeyComboMonitor.swift:54-92`; modifier construction at `:140-159`; configured at `Sources/AppCoordinator.swift:282-294`). The callback reaches `toggleRecording()` through the main queue (`Sources/KeyComboMonitor.swift:127-137`). Registration status is logged once, but there is no later liveness probe or re-registration.

Apple documents `tapDisabledByTimeout` and says an unresponsive **Core Graphics event tap** can receive a disabled event and be re-enabled with `CGEvent.tapEnable`.[^tap-timeout][^tap-enable] That behavior does **not** apply to Speakeasy's hotkey because Speakeasy never creates a `CFMachPort` event tap. `CGEvent.post(tap: .cghidEventTap)` at `Sources/PasteboardPaster.swift:52-53` posts events at an event-stream location; Apple describes `post(tap:)` as immediately posting an event before taps at that location.[^event-post]

Apple's Sequoia `RegisterEventHotKey` restriction discussed by a Frameworks Engineer concerned Option/Shift-only shortcuts and was changed again in macOS 15.2 beta.[^sequoia-hotkey] Speakeasy includes both Command and Control, so that specific restriction contradicts this symptom as a primary explanation.

### 4. Menu-bar activation is not required for this hotkey path

Apple defines `.accessory` as an application that does not appear in the Dock or own a normal menu bar but may be activated programmatically or by a window click; it corresponds to `LSUIElement=1`.[^accessory-policy] Apple defines `LSUIElement` as an agent app that runs in the background and does not appear in the Dock.[^lsuielement]

**Repository correlation:** Speakeasy sets both (`Sources/main.swift:6`; `Info.plist:19-20`) and then runs the normal AppKit event loop (`Sources/main.swift:7`). The hotkey callback does not call activation APIs; it directly toggles state. `NSApplication.activate(ignoringOtherApps:)` is used only to present startup alerts/settings (`Sources/AppDelegate.swift:121-144`). Activation/focus can affect where Cmd-V lands, but there is no repo evidence that activation gates audio start.

### 5. Paste can fail silently or beep in the target app

Apple says `NSPasteboard.setString(_:forType:)` returns whether the write succeeded and can return false if pasteboard ownership changed; other errors can raise `NSPasteboardCommunicationException`.[^pasteboard-set-string] Speakeasy ignores that return value (`Sources/PasteboardPaster.swift:15-17`). Apple says `CGEvent.post(tap:)` posts into the stream but exposes no delivery/acceptance result.[^event-post]

**Repository correlation:** after successful transcription and a passing accessibility check, Speakeasy logs the outcome as `.pasted` **before** calling `paster.paste` (`Sources/AppCoordinator.swift:500-513`). It then writes the pasteboard and posts Cmd-V (`Sources/PasteboardPaster.swift:14-53`). Apple's event-handling guide documents that an unhandled key-down event is passed up the responder chain and ultimately causes the system to beep.[^key-events] A target that does not handle the synthetic command can therefore produce the same sound; Speakeasy cannot distinguish that from successful insertion. Conversely, failures to construct `CGEventSource`, key-down, or key-up explicitly invoke Speakeasy's beep-only feedback (`Sources/PasteboardPaster.swift:23-46`).

This path cannot explain a beep on the **first press that should begin recording**. It is relevant only after the second press, transcription, or a menu history paste.

### 6. Model/file "staleness" is a weaker match than runtime session/backend state

At launch, Speakeasy accepts an already-installed model based on regular-file status and exact byte count (`Sources/ModelPathResolver.swift:275-280`). SHA-256 is checked when `ASRModelInstaller.install` verifies/downloads an artifact (`Sources/ASRModelInstaller.swift:58-119`), but an existing size-correct catalog file bypasses that checksum through `resolveOrInstall` (`:46-55`). The Swift layer then calls native `asr_create` once (`Sources/TranscribeCppTranscriber.swift:47-66`), and the Rust bridge loads a `Model`, creates one `Session`, and retains it behind a mutex (`rust/asr_bridge/src/lib.rs:85-118`). Warmup performs a real one-second silent inference once (`Sources/TranscribeCppTranscriber.swift:92-95`; invoked at `Sources/AppDelegate.swift:47-49`).

After launch, no code reopens, revalidates, or replaces the model file. Therefore:

- A missing/corrupt model is primarily a **launch/model-load** failure, not a long-idle-only failure that relaunch reliably repairs.
- A persistent native session or Metal/backend failure after sleep remains possible, but it occurs only after audio is stopped and transcription starts (`Sources/AppCoordinator.swift:440-475`).
- A native inference that never returns leaves coordinator state `.transcribing` even after the app's timeout beep; timeout sets `didTimeOut` but deliberately does not return to idle until native work returns (`Sources/AppCoordinator.swift:516-548`). Relaunch is then the only implemented recovery.

Apple's Metal contract provides command-buffer status/error diagnostics when GPU execution fails; enhanced command-buffer errors can identify the failing encoder.[^metal-errors] Speakeasy's native bridge surfaces only the final transcribe.cpp error string (`Sources/TranscribeCppTranscriber.swift:78-88`) and has no backend/session recreation path. There is not enough evidence to claim macOS sleep invalidates this model/session; treat that as an unproven runtime-backend hypothesis, not "stale model file" behavior.

## Ranked hypotheses

| Rank | Hypothesis | Confidence | Why it matches | Key contradiction / discriminator |
|---:|---|---|---|---|
| 1 | **Audio engine stopped/uninitialized after an input-device/sample-rate/channel change; Speakeasy still believed it was prepared.** | **Confirmed for this incident** | CoreAudio logged the device death and configuration notification; Speakeasy then captured 0 active samples twice; relaunch rebuilt the graph and immediately restored active samples. | Sleep was not required for this occurrence. Future variants should still correlate the notification with callback freshness. |
| 2 | **Fresh launch is still warming the model (or warmup is stuck), so the explicit gate rejects the hotkey and beeps.** | High for a different immediate post-launch press; ruled out for this incident | This is the exact implemented behavior: hotkey registration precedes async warmup, and pending/warming maps to beep-only error feedback. | The failing process reached recording and returned 0 active samples; it did not log the warmup rejection. |
| 3 | **Microphone authorization changed while app remained alive, producing silence and/or an unrecovered audio transition.** | Medium | Apple explicitly allows authorization changes at any time and documents silent capture when denied; Speakeasy checks only at launch. | A still-denied permission should make relaunch reject startup, not fix it. Strong only if permission was toggled/regranted before relaunch. |
| 4 | **Native transcribe.cpp/Metal inference session hangs or errors after long idle/sleep, leaving the coordinator transcribing.** | Medium-low | One native session/backend is reused forever; timeout intentionally does not restore idle; relaunch recreates all native state. | Cannot affect the first recording press and requires a prior capture/stop. Look for `Transcription timed out`, a blocked native stack, or absence of transcription-end logs. |
| 5 | **Carbon hotkey delivery/registration becomes unhealthy after sleep/unlock or another app interferes.** | Low | Long-lived registration has no health check or re-registration; relaunch registers again. | No first-party contract found equivalent to CGEventTap timeout disablement for `RegisterEventHotKey`. If Speakeasy's own logger records `Recording started` or its own beep path, the hotkey was delivered. Speakeasy uses a nonexclusive registration. |
| 6 | **Accessibility trust or synthetic paste fails after transcription.** | Low for start failure; medium for “dictation completed but no text” | Trust is checked dynamically; pasteboard result and synthetic event acceptance are not observed; target app may beep on an unhandled Cmd-V. | Occurs after transcription, not when capture starts. Relaunch does not itself restore TCC or target paste capability. |
| 7 | **Menu-bar activation/App Nap prevents operation.** | Low | Agent app is long-lived and depends on its main event loop. | The Carbon hotkey callback and audio path do not require foreground activation. No evidence in logs/code that activation state is consulted. |
| 8 | **On-disk model/file became stale.** | Very low | Existing files are only size-checked on launch; external replacement/corruption is possible. | Model is loaded into a persistent native handle at launch; long idle does not cause a repository file lookup. Relaunch would more likely reproduce load failure than repair it. |

## Contradictions and unknowns

1. **The exact physical input behind CoreAudio device 417 is not exposed in the retained process logs.** The logs prove an aggregate/default-input route death and fallback, but not whether the physical trigger was Continuity Mic, Bluetooth, USB, or another device transition.
2. **The beep has no semantic payload.** Every app-level error is collapsed to the same `NSSound.beep()` (`Sources/UserFeedback.swift:12-16`). It may also be a target application's beep after synthetic Cmd-V.
3. **“Not open/used” remains ambiguous for future occurrences.** A process that was quit has a fresh engine on launch; a menu-bar process left running has stale-runtime exposure. The captured incident was the latter.
4. **No OS/hardware matrix is recorded.** macOS version, Mac model, built-in/USB/Bluetooth mic, clamshell/dock state, number of sleep/wake cycles, and whether input changed are unknown.
5. **No first-party source found says `RegisterEventHotKey` is timeout-disabled after idle.** The well-documented timeout mechanism belongs to `CGEventTap`, which this repo does not use.
6. **No evidence proves Metal resources become invalid merely from sleep.** Native/Metal failure remains plausible only if logs/stacks place the failure inside inference.
7. **No evidence distinguishes permission denial from dead audio callbacks.** Both can yield empty/silent audio with current instrumentation.

## Missing observability

- No log at the Carbon callback boundary before dispatching `toggleRecording()`.
- No exposed coordinator state/warmup state when a hotkey is ignored.
- `SystemFeedback` discards the error message and emits only a beep.
- No `AVAudioEngine.isRunning`, current input format/device, configuration-change, sleep/wake, or last-audio-callback timestamp.
- No callback-count/sample-count heartbeat while idle or recording.
- Empty audio is logged as a trace outcome but gives no user feedback; short/silent audio shares the same beep.
- No pasteboard `setString` result, pasteboard change count, frontmost target bundle ID, CG event-post permission preflight, or delivery acknowledgment.
- `.pasted` is logged before paste is attempted.
- Native inference has start/end trace timestamps, but no native phase, Metal command-buffer error, cancellation, or backend/session health telemetry.
- Startup model resolution distinguishes few failure classes in the UI; existing-model validation is size-only on the fast path.

## Recommended correction

### P0 — recover the capture graph instead of requiring relaunch

1. Replace the independent `isPrepared` Boolean with an authoritative capture lifecycle such as `stopped → starting → running → recovering → failed`.
2. Observe `AVAudioEngineConfigurationChangeNotification` for the owned engine. The notification handler must only enqueue recovery onto a private serial lifecycle executor; it must not synchronously destroy the engine on Apple's internal callback queue.
3. On recovery, coalesce duplicate notifications, stop the engine, remove the old tap, clear stale pre-roll, read the new input format, rebuild the converter/conversion buffer, reinstall exactly one tap, prepare/start the engine, and mark capture ready only after a fresh callback arrives.
4. If configuration changes during recording, terminate that recording as **interrupted**, signal any grace wait, discard discontinuous audio, return the coordinator to idle, hide the flash, and surface a recoverable message. Do not misclassify it as “too short” or “no speech.”
5. Before entering coordinator state `.recording`, verify both engine state and callback freshness. A stale engine should use the same recovery path; coordinator state must not say “recording” until capture confirms readiness.

### P0 — preserve the error reason

- Stop discarding `UserFeedbackEvent.error(String)`. Log the exact reason and expose transient status through the menu-bar controller.
- Distinguish at least: `microphone reconnecting`, `recording interrupted by input change`, `capture recovery failed`, `recording too short`, and `no speech`.
- Keep the beep only as an optional secondary cue; it must not be the sole diagnostic surface.

### P1 — make silent recurrence observable

- Record configuration-change receipt, recovery attempt/result, old/new sample rate and channel count, engine running state, and monotonic age of the last input callback.
- Add trace outcomes for `captureUnavailable`, `captureInterrupted`, and `captureRecoveryFailed` rather than reporting all three as `noSpeech`.
- Revalidate callback freshness on `NSWorkspace.didWakeNotification`; use wake as a health-check trigger, not as a substitute for the audio configuration notification.

### Required tests and acceptance

1. A configuration change stops a fake engine; recovery refreshes the format/converter, installs one tap, and restarts once.
2. Repeated notifications coalesce and never produce duplicate taps.
3. A route change during recording aborts coherently: coordinator idle, flash hidden, no transcription/paste, explicit interruption feedback.
4. A restart failure leaves capture in a recoverable failed state; a later retry can return to running.
5. A stale callback timestamp without a notification triggers the same self-heal path before recording.
6. Manual checks pass for built-in ↔ Continuity/Bluetooth/USB input changes, disconnect, sleep/wake, and the exact old-process scenario—without relaunching Speakeasy.

**Estimate:** 3–5 hours for lifecycle/state/feedback implementation and focused tests, plus 45–60 minutes for the manual device/sleep matrix.

## No-code-change diagnostic plan

### A. Capture one failure without relaunching

1. **Start unified logging before reproducing:**

   ```bash
   log stream --style compact --level debug \
     --predicate 'subsystem == "com.speakeasy.app"' \
     | tee /tmp/speakeasy-cold-start.log
   ```

2. Record four timestamps/actions: first hotkey press, second press, beep, and whether the edge flash appeared/disappeared. Also record current input device, whether the Mac slept/unlocked, and whether a dock/USB/Bluetooth device changed.
3. Immediately preserve recent logs:

   ```bash
   log show --last 10m --style compact --level debug \
     --predicate 'subsystem == "com.speakeasy.app"' \
     > /tmp/speakeasy-cold-start-show.log
   system_profiler SPAudioDataType > /tmp/speakeasy-audio.txt
   ```

### B. Classify by the last observed repository checkpoint

| Log/behavior | Interpretation |
|---|---|
| No Speakeasy log and no edge flash | Hotkey delivery/main-loop/registration path; do not investigate audio or model yet. |
| `Ignoring hotkey: model warmup in progress` + immediate beep | Warmup task is still `.warming`; inspect model/native backend. |
| `Recording started ...` and flash appears, but stop yields `outcome=emptyAudio`, zero active samples, `Recording too short`, or `No speech detected` | Audio callback/permission path; leading stale-engine hypothesis. |
| `Audio stats` is healthy, then `Transcription timed out` or no transcription completion | Native transcribe.cpp/Metal session path. |
| `outcome=accessibilityDenied` | TCC/accessibility path. |
| `outcome=pasted` but no insertion | Pasteboard/frontmost-target/synthetic Cmd-V path; `.pasted` currently precedes the attempt. |

### C. Isolate without restarting Speakeasy

1. **Audio:** In System Settings, note the selected input and live input level. Switch to another input and back, then retry. If this alone restores callbacks, it implicates engine/device configuration. Check microphone authorization before and after; do not toggle it until the original failure is captured.
2. **Paste:** Focus a plain TextEdit document. Retry a complete dictation. Immediately run `pbpaste`. Text in `pbpaste` but not TextEdit isolates synthetic-event/focus/TCC delivery; no text with `outcome=pasted` isolates pasteboard writing or an earlier mistaken log outcome.
3. **Accessibility:** Run the app's normal dictation with TextEdit focused and inspect System Settings → Privacy & Security → Accessibility. Capture logs before changing the grant. A grant toggle that fixes only paste but leaves sample logs healthy is not an audio fix.
4. **Native hang:** If a transcription starts but never ends, sample the live process before relaunch:

   ```bash
   pid=$(pgrep -x Speakeasy | head -1)
   sample "$pid" 10 -file /tmp/speakeasy-hung.sample.txt
   ```

   Look for the transcription queue blocked in `asr_transcribe`, Metal/ggml command execution, or mutex wait.

### D. Reproduce the suspected lifecycle transition deliberately

Run each condition separately from a known-good fresh launch, preserving logs each time:

1. Built-in mic, sleep/wake, then first dictation.
2. Connect/disconnect Bluetooth input while idle, then dictation.
3. Connect/disconnect USB audio or dock while idle, then dictation.
4. Change default input or sample-rate-capable device while idle, then dictation.
5. Lock/unlock repeatedly without sleep, then dictation.

For a controlled sleep test, save work first, then use `pmset sleepnow`. Do not combine sleep and a device change in the first pass.

### E. Minimal decision rule

- **Audio logs stop after a lifecycle transition and relaunch restores them:** hypothesis 1 is effectively confirmed.
- **Hotkey callback path never appears but another input method/menu action works:** investigate Carbon registration/main event loop.
- **Samples are healthy and native inference is blocked:** investigate transcribe.cpp/Metal session recovery.
- **Trace reaches `.pasted`:** audio/model are not the cause of that occurrence; investigate target focus, pasteboard, and posting permission.

## Primary sources

[^audio-config-change]: Apple, [`AVAudioEngineConfigurationChangeNotification`](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification).
[^audio-start]: Apple, [`AVAudioEngine.start()`](https://developer.apple.com/documentation/avfaudio/avaudioengine/start()).
[^audio-install-tap]: Apple, [`AVAudioNode.installTap(onBus:bufferSize:format:block:)`](https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)).
[^audio-reset]: Apple, [`AVAudioEngine.reset()`](https://developer.apple.com/documentation/avfaudio/avaudioengine/reset()).
[^workspace-sleep]: Apple, [`NSWorkspace.willSleepNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification).
[^workspace-wake]: Apple, [`NSWorkspace.didWakeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification).
[^capture-auth]: Apple, [`AVCaptureDevice.authorizationStatus(for:)`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)).
[^ax-trusted]: Apple, [`AXIsProcessTrusted`](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted).
[^ax-options]: Apple, [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions).
[^carbon-events]: Apple, [Carbon Event Manager Programming Guide — Event Handler Basics](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/Carbon_Event_Manager/Tasks/CarbonEventsTasks.html).
[^global-hotkey-dts]: Apple Developer Technical Support, [How to properly realize global hotkeys](https://developer.apple.com/forums/thread/735223).
[^tap-timeout]: Apple, [`CGEventType.tapDisabledByTimeout`](https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbytimeout).
[^tap-enable]: Apple, [`CGEvent.tapEnable(tap:enable:)`](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable(tap:enable:)).
[^event-post]: Apple, [`CGEvent.post(tap:)`](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)).
[^sequoia-hotkey]: Apple Frameworks Engineer, [macOS Sequoia `RegisterEventHotKey` Option/Shift behavior](https://developer.apple.com/forums/thread/763878).
[^accessory-policy]: Apple, [`NSApplication.ActivationPolicy.accessory`](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory).
[^lsuielement]: Apple, [`LSUIElement`](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement).
[^pasteboard-set-string]: Apple, [`NSPasteboard.setString(_:forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/setstring(_:fortype:)).
[^nssound-beep]: Apple, [`NSSound.beep()`](https://developer.apple.com/documentation/appkit/nssound/beep()).
[^key-events]: Apple, [Cocoa Event Handling Guide — Handling Key Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingKeyEvents/HandlingKeyEvents.html).
[^metal-errors]: Apple, WWDC20, [Debug GPU-side errors in Metal](https://developer.apple.com/videos/play/wwdc2020/10616/).
