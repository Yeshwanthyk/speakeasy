# Speakeasy first-run onboarding: codebase audit

## 1. Startup and first run

`main.swift` creates `NSApplication`, assigns `AppDelegate`, selects accessory policy, then runs the event loop (`Sources/main.swift:3-7`). On launch `AppDelegate` starts a main-actor task: resolve duplicate current/legacy bundle instances (`AppDelegate.swift:14-20,146-189`); request microphone access (`22-27`); guide missing Accessibility (`29,206-226`); construct the coordinator (`31-34`); prepare the audio graph (`34`); install wake/unlock rewarm observers (`36-42`); wire feedback and menu-bar callbacks (`43-129`); then start model warmup in a utility task (`131-133`). Construction resolves/downloads the model before the menu exists. Any thrown construction/prepare error shows a fatal alert and quits (`134-136,228-239`). `main.swift` itself has no setup logic.

No first-run/onboarding-complete UserDefaults flag exists in the inspected startup sources. The default shortcut and invalid/missing saved shortcut fallback are `fn` (`DictationShortcut.swift:47-52,83-100`). Model selection is preference `ASRModel` (legacy `WISP_ASR_MODEL`) and environment `SPEAKEASY_ASR_MODEL` / `WISP_ASR_MODEL` (`ModelPathResolver.swift:170-203`). Accessibility guidance recurs whenever trust is absent; `ensureAccessibilityPrompted()` invokes the macOS prompt API but does not persist a “prompted” flag (`Permissions.swift:39-48`).

## 2. Model acquisition and readiness

Default model is Parakeet 110M (135,373,280 bytes); Unified EN is 731,357,568 bytes. Both artifacts pin Hugging Face revision, expected size, SHA-256 and CC-BY-4.0 (`ModelPathResolver.swift:115-135`). Files go under `~/Library/Application Support/<bundle-id>/models/<filename>`; legacy `com.wisp.app` path is a verified fallback (`468-477,392-422`). Model path overrides are `PARAKEET_110M_GGUF_PATH` / `PARAKEET_UNIFIED_GGUF_PATH`, or matching `Parakeet110MGGUFPath` / `ParakeetUnifiedGGUFPath` defaults (`97-113,301-317,383-389`).

`ASRModelInstaller.resolveOrInstall(kind:)` reuses only verified files, otherwise downloads to a staging path, checks regular-file/size/SHA-256, then atomically promotes (`ASRModelInstaller.swift:45-100`; verification `ModelPathResolver.swift:331-373`). URLSession’s `download(from:)` reports no progress callback here (`ASRModelInstaller.swift:12-24`): no bytes/percent observable. Errors include invalid URL/HTTP status/missing downloaded file/size/checksum, plus URL/network/filesystem errors (`ASRModelInstaller.swift:4-10,76-92`). Invalid/missing models trigger replacement; overrides with invalid files fail validation.

Startup loads the native transcriber before UI, then `warmUpModel()` performs one second of silence inference; warmup failure is logged only and intentionally still allows transcription (`AppCoordinator.swift:697-703,305-325`; implementation `TranscribeCppTranscriber.swift:29-35,96-100`). `UserFeedbackEvent` is only status/error/model-switch-failed, no typed download/readiness/progress event (`UserFeedback.swift:5-20`). A first model download failure therefore reaches a generic fatal “Failed to start” alert; no recover/retry UI is exposed at that point.

## 3. Permissions

Microphone: status checked; `.notDetermined` requests access; denied/restricted throws and app quits (`Permissions.swift:15-33`, `AppDelegate.swift:22-27`). `Info.plist` contains microphone usage text (see `Info.plist:23+`). No in-app recovery path after denial.

Accessibility: checked via `AXIsProcessTrusted`; `AXIsProcessTrustedWithOptions` prompts and app opens the Accessibility pane with instructions (`Permissions.swift:35-51`, `AppDelegate.swift:207-225`). Missing trust does not block recording/transcription: delivery checks it and emits “Accessibility permission required” (`AppCoordinator.swift:1459-1473,1555-1558`). It is checked again per paste. No return-to-app recheck/relaunch flow. Typical TCC changes to Accessibility/Input Monitoring may require relaunching Speakeasy for access to take effect.

Input Monitoring: no explicit permission query, request, settings deep link, or denial handling was found. `KeyComboMonitor` installs local/global `NSEvent` keyboard monitors and handles `flagsChanged` for `fn` (`KeyComboMonitor.swift:147-211,313-387`). Failure to install both monitors yields nil; coordinator retains no explicit user-visible diagnostic when that factory returns nil (`AppCoordinator.swift:291-295`). This is distinct from microphone and Accessibility.

## 4. Shortcut

`fn` is default (`DictationShortcut.swift:47-56`). Shortcut recorder already teaches “Tap fn by itself” or a modified key and rejects unsafe bare keys (`ShortcutRecorder.swift:9-10,95-131`). fn tap toggles; function hold for push-to-talk waits 180ms, and combined fn use is ignored (`KeyComboMonitor.swift:48-100,109-110,364-403`). Carbon registration errors distinguish unavailable monitor vs “already in use” (`13-25,291-310`). No check/warning for macOS Function/Globe key actions (Emoji & Symbols / system Dictation) conflicting with fn.

## 5. Reusable UI and tests

Existing building blocks: settings model/test covers model, shortcut, device, visibility and feedback actions (`Tests/SpeakeasyTests/SettingsModelTests.swift:9-57,59-95`; settings implementation currently lives in `Sources/SettingsWindow.swift`, which is being rewritten and was not inspected). Recording overlay signals recording/processing, microphone level and errors (`RecordingIndicator.swift:161-224,258-321`); `OverlayModel` has recording/transcribing/done/error states (`OverlayModel.swift:37-80`). `CorrectionEditorWindowController` demonstrates reusable activated AppKit window + SwiftUI hosting pattern (`CorrectionEditor.swift:274-323`).

Relevant tests: installer verified promotion/skip/wrong size/checksum (`ASRModelInstallerTests.swift:15-81`); resolver path/env/hash/migration (`ModelPathResolverTests.swift:22-211`); shortcut defaults/persistence (`DictationShortcutTests.swift:5-47`); fn state and modes (`KeyComboMonitorTests.swift:41-74`); Accessibility settings URL (`PermissionsTests.swift:5-10`); settings window/model tests above. `script/e2e.sh` checks Accessibility/Notes prerequisites, installs/relaunches the app, synthesizes real fn, reads overlay and transcript trace, and scores fixture WER (`script/e2e.sh:59-67`; README `117-122`). This validates full dictation, not a first-run guided flow. `build.sh` targets macOS 12 (`build.sh:4-9`).

## Gaps and onboarding support

**Already supportable:** microphone prompt; Accessibility settings link and trust check; model resolution, verified download, warmup; shortcut selection/default and feedback; start/stop recording, live overlay, transcript persistence and copy/paste fallback. A guided flow can sequence these existing operations and finish with an actual user-spoken sample.

**New hooks needed (suggested):**
- `func onboardingStatus() async -> OnboardingStatus` (model installed/verified/warmed, permissions, shortcut, test result).
- `func installModel(kind: ASRModelKind, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> ASRModelConfiguration` (URLSession delegate/progress + surfaced failures).
- `func requestMicrophoneAccess() async -> PermissionStatus`; `func accessibilityStatus() -> PermissionStatus`; `func openAccessibilitySettings()`; `func openInputMonitoringSettings()`; `func inputMonitoringStatus() -> PermissionStatus` (practical status may require observing monitor installation/events rather than a reliable public check).
- `func retryWarmup() async throws`; `func beginOnboardingTestDictation()` / completion callback with transcript + delivery outcome.
- `func markOnboardingComplete()` persisted only after all criteria; app-active callback to recheck TCC, with explicit restart guidance when necessary.

**Open risks:** Big offline/network downloads have no progress/cancel/retry UI; menu appears only after download; warmup failure is not surfaced and “failed” counts as ready (`AppCoordinator.swift:82-98,321-325`); Accessibility denial is discovered only after dictation; fn can collide with user-configured macOS behavior; global-monitor permission denial can appear as a dead shortcut. An app-bundle signing identity matters because ad-hoc rebuilds can invalidate Accessibility grants (`build.sh:33-44`).