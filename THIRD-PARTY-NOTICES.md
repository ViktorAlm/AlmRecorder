# Third-Party Notices

AlmRecorder (licensed under Apache-2.0) includes, links against, or bundles the third-party
components below. Each remains under its own license. This file is provided to satisfy the
attribution requirements of those licenses.

## Bundled / redistributed components

These ship inside this repository and/or inside the packaged `.app`.

| Component | Use in AlmRecorder | License | Copyright |
|---|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite toolkit (vendored as prebuilt `GRDBCustom/Binary/GRDB.xcframework`) | MIT | © Gwendal Roué |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Whisper transcription (submodule + prebuilt `libwhisper`/`ggml` dylibs + `whisper-cli`) | MIT | © The ggml authors |
| [llama.cpp](https://github.com/ggerganov/llama.cpp) | Voxtral/Gemma transcription & embeddings (submodule + prebuilt `libllama`/`ggml`/`mtmd` dylibs + `llama-*` binaries) | MIT | © The ggml authors |
| [VibeASR.cpp](https://github.com/microsoft/VibeASR.cpp) | Low-latency VibeVoice BitNet dictation server (submodule + prebuilt `vibeasr-stream-server`) | MIT | © Microsoft Corporation |
| [SQLite](https://www.sqlite.org) | Custom DB engine build with extension loading (`libsqlite3_custom.dylib`) | Public Domain | — |
| [vectorlite](https://github.com/1yefuwang1/vectorlite) | HNSW vector search SQLite extension (`vectorlite.dylib`) | Apache-2.0 | © 1yefuwang1 |
| [sqlite-vec](https://github.com/asg017/sqlite-vec) | Vector search SQLite extension (`vec0.dylib`) | Apache-2.0 OR MIT | © Alex Garcia |
| [uv](https://github.com/astral-sh/uv) | Bundled installer for the isolated VibeVoice Python runtime | Apache-2.0 OR MIT | © Astral Software Inc. and contributors |

The historical `PyannoteSpeakerEmbedding.mlpackage` in the source tree is a randomly initialized
developer smoke-test asset, not pretrained Pyannote weights. Production packaging explicitly
excludes `Resources/Models`; speaker embeddings are supplied by FluidAudio instead.

## Swift Package Manager dependencies

Fetched at build time (not vendored), linked into the app.

| Package | Use | License | Copyright |
|---|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Speaker diarization embeddings | Apache-2.0 | © FluidInference |
| [DBSCAN](https://github.com/mattt/DBSCAN) | Clustering for diarization | MIT | © Read Evaluate Press, LLC |
| [Model Context Protocol Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | Local MCP server and stdio bridge | Apache-2.0 | © Model Context Protocol contributors |
| [SwiftNIO](https://github.com/apple/swift-nio) | Networking used transitively by the MCP SDK | Apache-2.0 | © Apple Inc. and the SwiftNIO project authors |
| [swift-log](https://github.com/apple/swift-log) | Logging used transitively by the MCP SDK | Apache-2.0 | © Apple Inc. and the SwiftLog project authors |
| [swift-collections](https://github.com/apple/swift-collections) | Collection types used transitively | Apache-2.0 | © Apple Inc. and the Swift project authors |
| [swift-atomics](https://github.com/apple/swift-atomics) | Atomic primitives used transitively | Apache-2.0 | © Apple Inc. and the Swift project authors |
| [swift-system](https://github.com/apple/swift-system) | System interfaces used transitively | Apache-2.0 | © Apple Inc. and the Swift project authors |
| [EventSource](https://github.com/mattt/EventSource) | Server-sent events used transitively by the MCP SDK | MIT | © Mattt Thompson |

## AI models (downloaded at runtime — NOT bundled, NOT covered by AlmRecorder's license)

AlmRecorder downloads models on first use. Each is governed by its own license/terms:

| Model | Source | Terms |
|---|---|---|
| Whisper and KB Whisper (ggml) | OpenAI / KBLab / ggml conversion repositories | Check the selected repository's model card; OpenAI Whisper code and weights are MIT. |
| Voxtral Mini 3B GGUF | Mistral AI; community GGUF conversion | Apache-2.0 per the upstream model card. |
| VibeVoice-ASR MLX (4/6/8-bit) | Microsoft base model; MLX Community conversions | MIT per the conversion repositories' model cards. |
| VibeVoice-ASR-BitNet | Microsoft | MIT per its model card. |
| Qwen2.5 tokenizer files | Alibaba Qwen | Apache-2.0 per the upstream model repository. |
| Qwen3-Embedding | Alibaba Qwen | Apache-2.0. |
| **Gemma 4 GGUF** | Google; Unsloth conversion | Review the selected model card and Google's current **[Gemma terms](https://ai.google.dev/gemma/terms)** before use. Weights are never redistributed by this project. |

The optional VibeVoice runtime is installed on demand from a pinned `mlx-audio` Git commit into a
user-local virtual environment. Its Python dependencies and their license metadata are part of
that separately installed environment, not the application bundle.

The distribution script stages product notices and local copies of every bundled/linked dependency
license into `AlmRecorder.app/Contents/Resources/Licenses`. The Apache-2.0 text also applies to
AlmRecorder itself and is included in [`LICENSE`](LICENSE).
