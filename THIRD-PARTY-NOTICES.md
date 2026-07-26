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
| [SQLite](https://www.sqlite.org) | Custom DB engine build with extension loading (`libsqlite3_custom.dylib`) | Public Domain | — |
| [vectorlite](https://github.com/1yefuwang1/vectorlite) | HNSW vector search SQLite extension (`vectorlite.dylib`) | Apache-2.0 | © 1yefuwang1 |
| [sqlite-vec](https://github.com/asg017/sqlite-vec) | Vector search SQLite extension (`vec0.dylib`) | Apache-2.0 OR MIT | © Alex Garcia |
| Pyannote-derived speaker embedding (`AlmRecorder/Resources/Models/PyannoteSpeakerEmbedding.mlpackage`) | CoreML speaker-embedding model for diarization | **⚠️ TO VERIFY** — see note below | — |

> **⚠️ PyannoteSpeakerEmbedding.mlpackage** — this is a CoreML speaker-embedding model bundled in
> the repo. The [pyannote.audio](https://github.com/pyannote/pyannote-audio) toolkit is MIT-licensed,
> but some pretrained pyannote weights are gated / carry their own conditions. **Confirm the exact
> source model and its redistribution terms before publishing**, or switch to a model with clearly
> redistributable weights (e.g., one provided by FluidAudio).

## Swift Package Manager dependencies

Fetched at build time (not vendored), linked into the app.

| Package | Use | License | Copyright |
|---|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Speaker diarization embeddings | Apache-2.0 | © FluidInference |
| [DBSCAN](https://github.com/mattt/DBSCAN) | Clustering for diarization | MIT | © Read Evaluate Press, LLC |

## AI models (downloaded at runtime — NOT bundled, NOT covered by AlmRecorder's license)

AlmRecorder downloads models on first use. Each is governed by its own license/terms:

| Model | Source | Terms |
|---|---|---|
| Whisper (ggml) | OpenAI / ggml | MIT |
| Voxtral Mini 3B | Mistral AI | Apache-2.0 |
| **Gemma** | Google | **[Gemma Terms of Use](https://ai.google.dev/gemma/terms)** — not OSI; carries use restrictions. Weights are never redistributed by this project. |
| Qwen3-Embedding | Alibaba | Apache-2.0 |

Full license texts for the permissive components above are available at each project's repository.
The Apache-2.0 text also applies to AlmRecorder itself and is included in [`LICENSE`](LICENSE).
