# Megaphone notch overlay and destination-app awareness

- **Research date:** 2026-08-07
- **Megaphone revision:** [`5a9136b3ac8c766e24a5d79ac056df4d427968f1`](https://github.com/Kuberwastaken/megaphone/tree/5a9136b3ac8c766e24a5d79ac056df4d427968f1)
- **Speakeasy revision:** [`7f6eb4c`](https://github.com/Yeshwanthyk/speakeasy/tree/7f6eb4c)
- **Scope:** analysis only; no application implementation

## Executive answer

Megaphone implements two separate kinds of awareness:

1. **The notch overlay is pipeline-state-aware, not destination-app-aware.** It changes between initializing, recording, transcribing, feedback, and update states; it also changes for hold/toggle invocation, command mode, notch availability, and display preference. It does not render differently for Mail, Slack, Terminal, or any other named app ([overlay state](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L5-L22), [layout inputs](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L342-L445)).
2. **Megaphone's output can be destination-app-aware, but only in its Smart Cleanup and command/edit paths.** Raw speech recognition does not receive app identity. Exact and Basic plain-dictation modes also do not use the app context. Smart Cleanup classifies the destination as email, work chat, casual chat, document, code/terminal, or neutral, then supplies different formatting guidance to Apple's on-device Foundation Model ([classification](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppleFoundationModelsPostProcessor.swift#L104-L208), [mode routing](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2818-L2855)).

The best Speakeasy move is therefore to treat these as independent tracks: adopt a small notch-style state indicator now, without importing Megaphone's app-context or Foundation Models pipeline.

## Screenshot diagnosis

The supplied crop matches Megaphone's compact notched layout:

- The **small white five-bar waveform to the left of the notch** is Megaphone's overlay.
- The black center is the physical notch covered by the overlay's solid-black spacer.
- The **orange microphone pill to the right is macOS microphone privacy/system UI**, not a Megaphone-drawn control. Megaphone's own optional toggle-mode control is a small red stop button, not an orange microphone ([wing implementation](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L474-L570)).

## How the overlay works

Megaphone owns one nonactivating, borderless `NSPanel` at screen-saver level. It is transparent, joins all Spaces, does not activate the app, and is normally mouse-transparent ([panel construction](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L38-L53)).

The default compact layout detects a notch with `NSScreen.safeAreaInsets.top`, computes the physical notch width from `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`, and places 36-point wings on either side ([notch metrics](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L109-L124), [wing frame](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L359-L380)). Its display can follow `NSScreen.main`, remain on the primary display, or be pinned to a selected display ID ([display selection](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L83-L107)).

The visible lifecycle is:

```text
recording requested
  -> show initializing dots only if startup exceeds 200 ms
  -> first non-silent audio buffer
  -> live waveform
  -> stop
  -> processing waveform
  -> spinner if processing exceeds 1 second
  -> dismiss, failure marker, or error pill
```

Evidence: [record start and delayed initialization](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2285-L2370), [transcribing transition](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2890-L2923), and [processing indicator](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L709-L890).

The live and processing waveforms target 30 Hz. Dismissal deliberately unmounts the SwiftUI hierarchy and closes the panel so infinite animations stop consuming Core Animation work ([waveform](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L573-L705), [teardown](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/RecordingOverlay.swift#L453-L465)).

## Exactly how destination-app awareness changes behavior

### What Megaphone captures

After recording starts, Megaphone asynchronously reads the frontmost app's name, bundle identifier, focused window title, selected text, and up to 240 characters before the caret through Accessibility APIs. Secure text fields are excluded from caret-context capture. Failed reads become `nil`; they do not fail dictation ([context capture](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppContextService.swift#L29-L150), [secure/caret handling](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppContextService.swift#L153-L192)).

It classifies app/bundle/window strings into:

| Category | Examples |
|---|---|
| Email | Mail, Outlook, Gmail |
| Work chat | Slack, Teams |
| Casual chat | Messages, Discord, WhatsApp, Telegram |
| Document | Pages, Notes, Obsidian, Notion, Word, Google Docs |
| Code or terminal | Terminal, iTerm, Ghostty, Warp, Xcode, VS Code, Cursor, Zed |
| Neutral | Everything else |

It separately recognizes Markdown-capable surfaces such as Obsidian, GitHub, GitLab, and Stack Overflow ([classifier source](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppleFoundationModelsPostProcessor.swift#L104-L170)).

### What changes

In Smart Cleanup, the model prompt includes destination app/window, category-specific cleanup rules, Markdown capability, selected text, preceding caret text, and local context summary. Email gets email punctuation and paragraph guidance; casual chat is told to remain conversational and avoid Markdown; code/terminal is told to preserve commands, flags, paths, identifiers, and formatting ([cleanup prompt](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppleFoundationModelsPostProcessor.swift#L751-L805)).

Selected-text Edit Mode and wake commands are also app-aware. Wake commands can optionally read up to 2,400 characters from the visible frontmost window, first through Accessibility and then through OCR only when Screen Recording permission was already granted ([screen text](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/ScreenTextService.swift#L5-L33), [command routing](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2710-L2811)).

### What does not change

- The raw SpeechAnalyzer recognition path receives locale/vocabulary, not destination-app context.
- Exact plain dictation returns raw text.
- Basic plain dictation applies deterministic cleanup only.
- The overlay has no app identity input.
- Paste is always a global synthetic Command-V; Megaphone does not target the captured PID at paste time ([paste](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L3556-L3567)).

This last point is important: if focus changes between context capture and paste, Megaphone can theoretically format for app A and paste into app B. Speakeasy's current behavior is safer: it captures a delivery target when recording starts and refuses automatic paste if that target changes, leaving text on the clipboard instead ([Speakeasy target capture](https://github.com/Yeshwanthyk/speakeasy/blob/7f6eb4c/Sources/AppCoordinator.swift#L670-L681), [target validation](https://github.com/Yeshwanthyk/speakeasy/blob/7f6eb4c/Sources/PasteboardPaster.swift#L144-L162)).

## Speakeasy's current feedback seam

Speakeasy already hides its edge glow behind the injected, main-actor `Flashing` protocol. `AppCoordinator` shows it only after capture commits to `recording`, hides it immediately when the coordinator enters `transcribing`, and also hides it on recording cancellation or microphone interruption ([protocol](https://github.com/Yeshwanthyk/speakeasy/blob/7f6eb4c/Sources/AppCoordinator.swift#L39-L43), [record/stop transitions](https://github.com/Yeshwanthyk/speakeasy/blob/7f6eb4c/Sources/AppCoordinator.swift#L766-L809), [interruption](https://github.com/Yeshwanthyk/speakeasy/blob/7f6eb4c/Sources/AppCoordinator.swift#L851-L891)).

That makes a recording-only notch indicator a nearly drop-in replacement. To show recording **and** processing, the narrow seam should become semantic—hidden, recording, processing—rather than retain `show(lineWidth:)` presentation terminology. The coordinator must remain the sole lifecycle owner.

Speakeasy already exposes a lock-backed `MicrophoneLevelSnapshot`; the menu polls it only while needed. A notch waveform can poll the same latest value at a bounded 20–30 Hz while visible, with no sample copies, conversion, or UI dispatch added to the audio callback ([level snapshot](https://github.com/Yeshwanthyk/speakeasy/blob/7f6eb4c/Sources/MicrophoneDevice.swift#L238-L268), [coordinator access](https://github.com/Yeshwanthyk/speakeasy/blob/7f6eb4c/Sources/AppCoordinator.swift#L371-L373)).

## Direct reuse decision

Megaphone is MIT-licensed, so source reuse and modification are allowed if its copyright and permission notice are retained in copies or substantial portions ([license](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/LICENSE)).

The complete 1,078-line `RecordingOverlay.swift` should not be copied wholesale. It contains command mode, updater UI, error toasts, toggle stop controls, settings keys, and Megaphone-specific state. As written, it also fails Speakeasy's macOS 12 target because `UnevenRoundedRectangle` requires a newer deployment target; the shape can be replaced without changing the notch mechanism.

Recommended reuse, with attribution:

- notch detection and auxiliary-area geometry;
- wing frame construction;
- compact five-bar recording waveform;
- compact processing waveform/spinner;
- panel teardown that unmounts continuous animations;
- optionally `LiveAudioLevelNormalizer`, adapted to Speakeasy's existing level snapshot.

Do not reuse Megaphone's capture-level publication path or central overlay state owner. Speakeasy should poll its existing snapshot and keep `AppCoordinator` authoritative.

## Recommended product shape

### First slice: visual feedback only

```text
AppCoordinator authoritative state
  -> recording: show notch waveform
  -> stop/processing: switch same panel to processing indicator
  -> terminal/cancel/interruption: dismiss by current session token

AudioCapture
  -> existing latest-level snapshot
  -> visible-only 20–30 Hz UI polling
```

- Notched display: use Megaphone's wing geometry.
- Non-notched display: use a small fixed-height top-center pill, not a zero-height menu-bar calculation.
- Keep the panel nonactivating and click-through; no stop button initially.
- Pin the chosen display for the recording session so phase changes do not jump monitors.
- Do not show app names or icons in the first slice.
- Respect Reduce Motion and test auto-hidden menu bars, full-screen Spaces, display disconnects, and rapid stop/start races.

### Separate later decision: app-aware output

Do not couple app awareness to the notch work. Speakeasy already captures bundle ID and PID for safe delivery, but it intentionally performs deterministic, model-independent correction. Megaphone's meaningful app adaptation depends on Apple's Foundation Models, while Speakeasy supports macOS 12 and prioritizes low latency.

If app-aware output is later explored:

1. Keep it optional and off the mandatory path.
2. Capture bounded context asynchronously after recording starts; never touch the audio callback.
3. Preserve Speakeasy's captured-target validation rather than Megaphone's global-current-focus paste behavior.
4. Start with bundle/category only; do not add Screen Recording/OCR initially.
5. Always retain deterministic output as the immediate fallback and measure release-to-paste regression.

## Conclusion

Megaphone's notch overlay is a good reusable visual mechanism, not evidence that the overlay itself understands the destination app. Its app awareness lives in a separate Smart Cleanup/command system. Speakeasy can adopt the polished recording/processing indicator without adopting that larger context pipeline, preserving its simpler and safer hot path.
