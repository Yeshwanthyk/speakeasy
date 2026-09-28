<div align="center">
  <img src="Assets/AppIcon/signal-fold.svg" width="128" alt="Speakeasy icon">
  <h1>Speakeasy</h1>
  <p><strong>Fast, private dictation for macOS.</strong></p>
  <p>Press fn, speak, and the text is pasted where you were typing.<br>Transcription runs on your Mac.</p>
</div>

## What it does

- **Dictate anywhere.** Tap **fn** to start and stop, or hold it to talk. The text is pasted into the app you were using.
- **Local.** Speech is transcribed on your Mac. Audio is not saved to disk or sent anywhere. The only network use is downloading the model.
- **Fast.** On an M4 Pro, the default model transcribes a short clip in about 20 ms once loaded.
- **Recoverable.** Each transcript is saved before it is pasted. If a paste fails, copy or paste it again from the menu bar.
- **Corrections.** Add replacements like "cube control → kubectl". They apply to every dictation after you save them.

## Models

Speakeasy downloads the default model on first launch and checks its SHA-256 before loading it.

| | Model | Size |
|---|---|---:|
| **Default** | [Parakeet TDT+CTC 110M](https://huggingface.co/handy-computer/parakeet-tdt_ctc-110m-gguf) | 135 MB |
| Optional | [Parakeet Unified EN 0.6B](https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf) | 731 MB |

Both are English-only, run on the GPU through [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), and are licensed CC-BY-4.0. Switch models in Settings.

## Install

Requires an Apple Silicon Mac running macOS 12 or later.

1. Download the latest `Speakeasy-*.zip` from [Releases](https://github.com/Yeshwanthyk/speakeasy/releases), unzip it, and move **Speakeasy** to Applications.
2. Open it. macOS blocks the first launch because the app is not notarized. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Allow **Microphone** access. Allow **Accessibility** access so Speakeasy can paste.

> **After updating:** macOS may forget the Accessibility permission. If paste stops working, remove Speakeasy from **Privacy & Security → Accessibility** and add it again.

## Build from source

Requires Xcode command-line tools and [Rust](https://rustup.rs).

```bash
git clone https://github.com/Yeshwanthyk/speakeasy.git
cd speakeasy
./script/build_and_run.sh
```

This builds the app, installs it to `~/Applications`, and opens it. Run the tests with `swift test`. [ARCHITECTURE.md](ARCHITECTURE.md) describes the internals.

## Credits

Speech recognition uses NVIDIA's Parakeet models through [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp). The recording overlay adapts code from [Megaphone](https://github.com/Kuberwastaken/megaphone). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE). Model weights are licensed separately (CC-BY-4.0).
