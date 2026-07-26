# Contributing to AlmRecorder

Thanks for your interest in AlmRecorder! This guide covers building from source and the project
layout. By contributing you agree your contributions are licensed under the project's
[Apache-2.0 License](LICENSE).

## Prerequisites

- macOS 14+ on **Apple Silicon**
- Xcode command-line tools (`xcode-select --install`) — provides the Swift 5.9+ toolchain
- For rebuilding the native C++ libraries (optional): `cmake` (`brew install cmake`)

## Clone & build

```bash
git clone --recurse-submodules https://github.com/viktoralm/AlmRecorder.git
cd AlmRecorder
swift build
swift run            # or ./Scripts/run_dev_app.sh
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

The repo ships **prebuilt** native libraries under `AlmRecorder/Resources/{Libraries,Binaries}`, so
a plain `swift build` does not compile any C++. You only need the submodules + `cmake` if you want
to rebuild those libraries yourself.

### Development path resolution

When the app runs **outside** a packaged `.app` (i.e. via `swift run`), it can't use
`Bundle.main` resources, so it falls back to repo-relative paths resolved by
`AlmRecorder/Services/Support/DevPaths.swift`. That resolver finds the repo root automatically from
the source location, or you can set it explicitly:

```bash
export ALMRECORDER_DEV_ROOT=/path/to/AlmRecorder
```

There are **no hardcoded absolute paths** — please keep it that way (CI/reviewers check for
machine-specific home-directory literals).

## Rebuilding native libraries (advanced)

- **whisper.cpp / llama.cpp** — build the submodules under `External/`, then stage the resulting
  dylibs/binaries into `AlmRecorder/Resources/Libraries` and `AlmRecorder/Resources/Binaries`.
  The pinned upstream commits are recorded in `.gitmodules` / the submodule SHAs
  (llama.cpp is at tag **b9430**; whisper.cpp at the pinned master commit).
- **Custom SQLite** — `./build_custom_sqlite.sh` builds `libsqlite3_custom.dylib` with
  `SQLITE_ENABLE_LOAD_EXTENSION` (required to load vectorlite/sqlite-vec).
- **GRDB.xcframework** — see [`GRDBCustom/REGENERATING.md`](GRDBCustom/REGENERATING.md) for the
  pinned GRDB + SQLite versions and the rebuild recipe.

## Project layout

```
AlmRecorder/            # The SwiftUI app (target source)
  Services/             # Transcription, DB, embeddings, diarization, LLM, …
  Views/ ViewModels/    # UI
  Resources/            # Committed prebuilt dylibs, CLI binaries, model assets
GRDBCustom/             # Local SwiftPM package: prebuilt GRDB.xcframework + custom-SQLite config
External/               # llama.cpp + whisper.cpp git submodules (for rebuilding native libs)
Scripts/                # Dev/run/packaging scripts
docs/                   # Public architecture and product documentation
```

## Privacy boundary

```bash
./Scripts/check_repository_privacy.sh
```

This public source tree intentionally does not track test suites, evaluation fixtures, gold sets,
recording/transcript exports, identity labels, or comparison outputs. Evaluation runs against the
current user's local library and local labels only. Keep experimental tests and evaluation tooling
outside Git. Never paste user-derived text, names, email addresses, filenames, timestamps, metrics,
or snippets into source, documentation, issues, commits, or pull requests.

To enable the repository's pre-commit privacy check in a clone:

```bash
git config core.hooksPath .githooks
```

If you maintain private fingerprints that must never appear in a tracked file, put one exact
literal per line in the ignored `.privacy-blocklist` file. The privacy check reads it locally
without adding those literals to the repository.

## Pull requests

- Keep changes focused; describe what and why.
- Run `swift build` and `./Scripts/check_repository_privacy.sh` before opening a PR.
- Don't commit models, media, databases, test/evaluation material, exports, build output, or
  machine-specific paths (see `.gitignore` and [`PRIVACY.md`](PRIVACY.md)).
- Be mindful of model licenses (especially Gemma) — see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
