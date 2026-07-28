<div align="center">

<img src="docs/assets/icon.svg" width="100" alt="AlmRecorder">

# AlmRecorder

**Open-source, private, on-device speech transcription for macOS.**

Record or import Voice Memos and transcribe locally with whisper.cpp · Voxtral · Gemma —
then search, diarize, and organize. Nothing ever leaves your Mac.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-2E2D29?style=flat-square&logo=apple&logoColor=FFFFFF)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-7C8A6B?style=flat-square)](#requirements)
[![100% on-device](https://img.shields.io/badge/100%25-on--device-8AA1AD?style=flat-square)](#privacy)
[![License Apache-2.0](https://img.shields.io/badge/license-Apache%202.0-B5894E?style=flat-square)](LICENSE)
[![Download](https://img.shields.io/github/v/release/ViktorAlm/AlmRecorder?style=flat-square&label=download&color=2E2D29)](https://github.com/ViktorAlm/AlmRecorder/releases/latest)

[**Download**](https://github.com/ViktorAlm/AlmRecorder/releases/latest) · [Build from source](#build-from-source) · [Contribute](CONTRIBUTING.md) · [Security](SECURITY.md) · [Enterprise analytics](#enterprise-conversation-analytics)

</div>

---

## Product preview

<table>
  <tr>
    <td width="50%"><img src="docs/assets/screenshots/dashboard.png" width="100%" alt="AlmRecorder dashboard with synthetic demo recordings"><br><sub><b>Dashboard</b> — recent recordings, activity, and speakers at a glance</sub></td>
    <td width="50%"><img src="docs/assets/screenshots/transcript.png" width="100%" alt="AlmRecorder transcript view with synthetic demo conversation"><br><sub><b>Transcript</b> — speaker-labeled, editable, exportable</sub></td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/assets/screenshots/search.png" width="100%" alt="AlmRecorder text search with synthetic demo results"><br><sub><b>Search</b> — find exact phrases or use semantic search across every recording</sub></td>
  </tr>
</table>

<p align="center"><sub>All screenshots use synthetic demo recordings and transcripts.</sub></p>

## Features

- **Recording** — real-time capture with a live waveform, then one-tap transcription.
- **Voice Memos import** — pull in Apple Voice Memos, or drag & drop audio, and batch-transcribe.
- **Multiple local engines** — [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
  Voxtral / Gemma via [llama.cpp](https://github.com/ggerganov/llama.cpp), and optional isolated
  runtimes for additional local models.
- **Semantic search** — transcripts are embedded locally and searchable by meaning, via a custom SQLite build + vector extensions.
- **Speaker diarization & identification** — "who spoke when," with labels you can correct.
- **Hallucination cleanup** — scores every line for whisper artifacts (silence fillers, repetition loops, subtitle boilerplate — language-agnostic), double-checks suspicious ones against the audio with Gemma, and learns from what it finds; everything reversible via a review inbox.
- **Automatic insights** — titles, summaries, and tags generated on-device for every recording.
- **Export** — TXT, CSV, or JSON; copy a line or a whole transcript.
- Native SwiftUI app, dark mode, sandbox-compatible with security-scoped bookmarks.

## Requirements

- macOS 14 (Sonoma) or later
- **Apple Silicon (M1 or later)** for the prebuilt download (bundled native libraries are arm64)
- ~3 GB free disk for a quantized model; 8 GB RAM minimum, 16 GB recommended
- Models are **downloaded on first run** — they are not bundled.

## Download & run

1. Download the latest `AlmRecorder.dmg` from the [Releases page](https://github.com/ViktorAlm/AlmRecorder/releases/latest).
2. Open the `.dmg` and drag **AlmRecorder** to your Applications folder.
3. **First launch (unsigned app).** AlmRecorder is open source but not Apple-notarized, so Gatekeeper warns on first open. Use any one of:
   - **Right-click** the app → **Open** → **Open**, or
   - **System Settings → Privacy & Security** → **Open Anyway**, or
   - Terminal: `xattr -dr com.apple.quarantine /Applications/AlmRecorder.app`
4. On first run, pick an engine and let the app **download its model**. After that you're fully offline.

Prefer not to run an unsigned binary? [Build from source](#build-from-source).

## Build from source

```bash
git clone --recurse-submodules https://github.com/ViktorAlm/AlmRecorder.git
cd AlmRecorder
swift build
swift run        # or: ./Scripts/run_dev_app.sh
```

The app ships prebuilt `whisper.cpp` / `llama.cpp` / `vectorlite` / custom-SQLite libraries under
`AlmRecorder/Resources/`, so a plain `swift build` works without compiling any C++. To rebuild those,
see [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`GRDBCustom/REGENERATING.md`](GRDBCustom/REGENERATING.md).

To package an unsigned `.dmg` yourself: `./Scripts/package_dmg.sh`.

## How it works

- **UI** — SwiftUI, AVFoundation for capture.
- **Transcription** — routed to whisper.cpp or llama.cpp (Voxtral / Gemma) by a unified manager with a retry/progress job queue.
- **Storage & search** — [GRDB](https://github.com/groue/GRDB.swift) on a custom SQLite build (extension loading enabled) with [vectorlite](https://github.com/1yefuwang1/vectorlite) / [sqlite-vec](https://github.com/asg017/sqlite-vec) for HNSW vector search.
- **Diarization** — [FluidAudio](https://github.com/FluidInference/FluidAudio) embeddings + [DBSCAN](https://github.com/mattt/DBSCAN) clustering.

Deeper notes live in [`docs/`](docs/).

## Privacy

All recording, transcription, embedding, and search happen locally on your Mac. AlmRecorder does
not upload audio or text. Models are downloaded once from their public sources and then run
offline. If you enable the optional MCP server, a connected client may send retrieved data to an
external service; recordings can be excluded individually or automatically through privacy tags.
Recordings are stored under `~/Library/Application Support/AlmRecorder/Recordings/`.

The source repository contains no recording or transcript corpus, identity labels, gold set,
comparison output, or test/evaluation fixture. Evaluation uses only the current user's local
library and locally stored labels. See [`PRIVACY.md`](PRIVACY.md) for the repository boundary.

## Enterprise conversation analytics

AlmRecorder is built for private, on-device workflows on a Mac. If your organization needs
customer-conversation analytics at enterprise scale — including programs processing millions of
calls — visit [**labelf.ai**](https://labelf.ai).

AlmRecorder is created and maintained by
[Viktor Alm](https://github.com/ViktorAlm), CEO of [labelf.ai](https://labelf.ai).

## License

Apache License 2.0 — see [`LICENSE`](LICENSE). Third-party components and their licenses are in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md). **AI models are downloaded at runtime and carry
their own licenses** — in particular Google's **Gemma** is governed by the
[Gemma Terms of Use](https://ai.google.dev/gemma/terms), not by this repository's license.

<div align="center"><sub>Logo & identity: a transparent speech-ribbon <b>A</b> with a horizontal studio-microphone crossbar, in sage and charcoal. See <a href="docs/design/logo/AlmRecorder-ribbon-A-blue-yeti-reference.svg">the approved SVG</a>.</sub></div>
