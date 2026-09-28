<div align="center">
  <img src="Assets/AppIcon/signal-fold.svg" width="128" alt="Speakeasy icon">
  <h1>Speakeasy</h1>
  <p><strong>Fast, private dictation for macOS.</strong></p>
  <p>Press fn, speak, and your words appear where you were typing.<br>Everything runs on your Mac.</p>
</div>

## What it does

- **Dictate anywhere.** Tap **fn** to start and stop, or hold it to talk. The text is pasted into the app you were using.
- **Stays on your Mac.** Speech is transcribed locally. Audio is never saved or sent anywhere.
- **Fast.** Short dictations come back in tens of milliseconds on Apple Silicon.
- **Doesn't lose your words.** Every transcript is saved before it's pasted, so you can copy or paste the last one from the menu bar.
- **Learns your words.** Add corrections like "cube control → kubectl" and they apply to every dictation.

## Models

Speakeasy downloads a model on first launch and verifies it before use.

| | Model | Size |
|---|---|---:|
| **Default** | [Parakeet TDT+CTC 110M](https://huggingface.co/handy-computer/parakeet-tdt_ctc-110m-gguf) | 135 MB |
| Optional | [Parakeet Unified EN 0.6B](https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf) | 731 MB |

Both are English, run through [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) with Metal, and are licensed CC-BY-4.0. You can switch models in Settings.

## Install

Requires an Apple Silicon Mac running macOS 12 or later.

1. Download the latest `Speakeasy-*.zip` from [Releases](https://github.com/Yeshwanthyk/speakeasy/releases), unzip it, and move **Speakeasy** to Applications.
2. Open it. macOS will block it because the app isn't notarized yet. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Allow **Microphone** access, and **Accessibility** access so Speakeasy can paste for you.

> **After updating:** macOS may forget the Accessibility permission. If paste stops working, remove Speakeasy from **Privacy & Security → Accessibility** and add it again.

## Build from source

Requires Xcode command-line tools and [Rust](https://rustup.rs).

```bash
git clone https://github.com/Yeshwanthyk/speakeasy.git
cd speakeasy
./script/build_and_run.sh
```

This builds the app, installs it to `~/Applications`, and opens it. Run the tests with `swift test`. [ARCHITECTURE.md](ARCHITECTURE.md) explains how it fits together.

## Credits

Speech recognition by NVIDIA's Parakeet models via [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp). The recording overlay adapts code from [Megaphone](https://github.com/Kuberwastaken/megaphone). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
