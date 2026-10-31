# uiui

Private, on-device dictation for macOS, tuned for how Indian professionals actually speak: Indian English, Hinglish and workplace vocabulary.

Tap a key, speak, and the text is pasted where you were typing. Audio never leaves your Mac.

- **Built for Indian speech:** a custom speech model, Phonon-2-HL, handles Indian English and Hindi-English mixing in Roman script.
- **Fast:** runs on the Apple Neural Engine at well over 100 times real time.
- **Local:** no cloud fallback, no wake phrase, no background listening. The microphone is off between recordings.
- **Native:** SwiftUI and AppKit, with no web runtime.

## Results

Word error rate %, lower is better. Public subsets of 150 clips per set, on an Apple M5 Pro.

| | Svarah (Indian English) | MUCS (Hinglish) | Hindi accents | LibriSpeech | Disk |
|---|---|---|---|---|---|
| **Phonon-2-HL** | 12.94 | **41.31** | 28.93 | 2.24 | 0.38 GB |
| Parakeet v3 | 16.59 | 87.17 | 77.70 | 2.27 | 2.5 GB |
| Whisper turbo (auto) | 12.0 | 72.2 | 57.1 | 2.3 | 1.6 GB |
| Qwen3-ASR-1.7B (auto) | 14.7 | 47.6 | **23.0** | **1.6** | 4.7 GB |

Larger models still win on pure Hindi and clearly read English. The [technical report](docs/technical-report.md) covers the data, training, every experiment, full comparisons, limits and open licence questions.

## Features

- **Shortcut:** tap Fn/Globe by default, or record any modifier, function key or combination. Optional hold-to-speak.
- **Notch feedback:** Mosaic, Liquid or Ribbon [styles](docs/notch-styles.md) show recognised words as you speak. uiui never presses Enter or sends a message.
- **History:** search, copy, pin and delete past dictations.
- **Recovery:** keeps the recognised text of up to 20 unfinished recordings. Raw audio is not saved.
- **Dictionary:** custom names, spellings and shorthand with exact case.
- **Updates:** signed updates from GitHub Releases, with hash and signature checks. See [updates](docs/updates.md).

## Models

| Model | Job | Runtime |
|---|---|---|
| Phonon-2-HL | Speech to text, with punctuation and casing | Core ML, Neural Engine and CPU, macOS 15+ |
| Silero VAD | Trims non-speech tails | Core ML, CPU |
| uiui MiniLM | Adds punctuation and casing only when the text has none | ONNX Runtime, CPU |

macOS 14 falls back to a Parakeet path, and other languages use Apple's on-device speech. Output that's already formatted skips the cleanup model.

## Build

Requires macOS 14+, Apple Silicon and Xcode with Swift 6.2.

```sh
swift build
swift test
```

To package the app you also need:

1. **A local signing identity.** See [local signing](docs/local-signing.md).
2. **Model files.** Weights are too large for git and are distributed as release packs pinned by `resources/ModelPacks.json`. Unpack them into `resources/Phonon` and `resources/MiniLM`, then:

```sh
./scripts/build-app.sh
```

Packaging and releases are described in [updates](docs/updates.md).

## Repository layout

| Path | Contents |
|---|---|
| `Sources/UIUI` | App state, OS integration and views |
| `Sources/UIUICore` | Local persistence and pure transformations |
| `Sources/CMiniLM` | Native cleanup model bridge |
| `Vendor/` | Pinned speech runtime and MiniLM native libraries, with licences |
| `resources/` | App resources, model manifests, licences and notices |
| `scripts/` | Build, packaging and asset verification |
| `docs/` | Technical report, updates, signing and notch styles |

## Licences

Model weights are CC-BY-4.0 and derive from NVIDIA Parakeet and Fermion Research's Phonon-2; see `resources/Phonon/NOTICE`. Vendored components keep their own licences. Some training-data licensing questions are still open, as listed in [section 9 of the report](docs/technical-report.md#9-licences-and-open-questions).
