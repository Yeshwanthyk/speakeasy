# Speakeasy macOS onboarding UX research

## Recommended sequence

1. **Welcome**: explain on-device transcription, model size, and why permissions are needed before asking. Apple's Privacy HIG recommends explanatory UI before system prompts ([HIG](https://developer.apple.com/design/human-interface-guidelines/privacy)). Offer “Not now.”
2. **Microphone**: on explicit click, call `AVCaptureDevice.requestAccess(for: .audio)` for the native prompt. For prior denial, offer Settings instead; don't imply the prompt can be shown again.
3. **Input Monitoring / shortcut**: explain the fn/Globe conflict, then request access on click. Keep this distinct from Accessibility.
4. **Accessibility**: explain it is used to synthesize paste keystrokes. Prompt and direct the user to enable Speakeasy in Accessibility settings; the app cannot toggle this grant.
5. **Model**: let the user choose small (~135 MB) or optional larger model. Begin downloading immediately and allow permission setup to continue in parallel. Show progress, pause/cancel, resume, and failure/offline states; validate a trusted digest/size before marking ready. Keep partial downloads recoverable. VoiceInk's UI explicitly supports progress, cancel, and resume ([download card](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Features/Onboarding/Components/TranscriptionModelDownloadCard.swift)).
6. **Microphone choice + “Try it now”**: select among input devices, record a short phrase, show transcript and retry. Confirm paste separately in a dedicated test field (or a deliberate “paste into another app” action); transcript success alone does not verify pasting.
7. **Finish**: customize shortcut and offer optional launch at login. macOS 13+: `SMAppService.mainApp.register()` and reflect status; use a legacy solution or omit on macOS 12 ([Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)).

## Permission APIs and Settings

```swift
let status = AVCaptureDevice.authorizationStatus(for: .audio)
if status == .notDetermined {
    AVCaptureDevice.requestAccess(for: .audio) { granted in /* update UI on main */ }
}
let axTrusted = AXIsProcessTrusted()
// On explicit action; may show Apple's prompt, does not grant access.
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(options)
let listens = CGPreflightListenEventAccess()
if !listens { _ = CGRequestListenEventAccess() }
```

`AVAuthorizationStatus` distinguishes `notDetermined`, `denied`, `restricted`, and `authorized` ([Apple](https://developer.apple.com/documentation/avfoundation/avauthorizationstatus)). Accessibility check: [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions). Input Monitoring: [CGPreflightListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()) and [CGRequestListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess()). `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` / `IOHIDRequestAccess(...)` are lower-level alternatives; don't request redundantly. Check SDK availability and guard APIs for macOS 12.

Common, **undocumented** deep links:

```swift
let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
// replace Privacy_Microphone with Privacy_Accessibility or Privacy_ListenEvent
if let url { NSWorkspace.shared.open(url) }
```

These anchors are observed, not a stable Apple API. macOS 13 replaced System Preferences with System Settings; the same anchors commonly open Privacy & Security on 13–15, but pane layout/app listing and scroll position vary. On macOS 12 they open the old Security & Privacy pane. Always show the manual path and a general Settings fallback. Apple forum guidance discusses the scheme but doesn't establish a supported contract ([forum](https://developer.apple.com/forums/thread/720543)).

Recheck when the app becomes active after Settings; poll modestly with a bounded timeout and a “Check again” action. Permission APIs—not successful Settings launch—are authoritative. Recreate event taps after access changes. TCC can appear stale; if key delivery stays blocked, tell the user to quit/relaunch rather than claiming it updated live.

## Fn/Globe behavior and app window

Apple exposes **“Press 🌐 key to” / “Press fn key to”** in Keyboard settings; choices can include Emoji & Symbols and Dictation ([Apple Support](https://support.apple.com/en-jo/guide/mac-help/-mchlp1560/mac)). Do not change it silently. Explain the conflict, allow another shortcut, and show the settings path. `defaults read com.apple.HIToolbox AppleFnUsageType` is an undocumented best-effort diagnostic only; don't write it or rely on it as an API.

Keep the app accessory-only at rest, but show a titled app-owned onboarding window activated from launch/menu. Apple's `.accessory` policy has no Dock icon but permits programmatic/window activation ([Apple](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory)). If a Dock icon is needed, temporarily switch to `.regular`, then restore `.accessory`; verify focus/relaunch behavior. Avoid floating/system-level windows. Keep onboarding reopenable from the status-item menu and visible while Settings is open.

## VoiceInk source skim

VoiceInk organizes onboarding into `Features/Onboarding/State`, `Views`, and `Components`. Its flow is permissions → microphone selection → transcription model → API/provider setup → experience/tutorial, with context/trust/license screens. It requires microphone and Accessibility; screen recording is optional. Permission code uses AVFoundation and `AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions`, opens Settings, then polls once per second for up to 60 seconds. The model card provides progress/cancel/resume, and shortcut setup has a recorder. See [OnboardingView](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Features/Onboarding/Views/OnboardingView.swift), [permission controller](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Features/Onboarding/State/OnboardingPermissionController.swift), and [permission models](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Features/Onboarding/State/OnboardingPermissionModels.swift). Current reviewed flow lacks Input Monitoring: Speakeasy should add it.

## Pitfalls

- TCC grants depend on app identity/signature. Bundle/signing changes, especially alternating ad-hoc and Developer ID builds, can invalidate Accessibility grants. Test the production-signed app and explain reauthorization after identity-changing updates. VoiceInk notes this in [build troubleshooting](https://github.com/Beingpax/VoiceInk/blob/main/building.md).
- Event-tap creation can appear successful while key events are withheld without Input Monitoring. Test actual key delivery, not just tap creation.
- Download off the UI thread; support resume only when the server supports ranges; write to a temporary file, verify, then atomically promote. Never claim a partial/corrupt file is ready.
- State clearly whether any audio leaves the device; don't overstate privacy guarantees.
