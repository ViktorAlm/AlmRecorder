# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Core Architecture

AlmRecorder is a macOS transcription app with three transcription backends and a sophisticated queue management system:

### Transcription Backends
1. **Whisper.cpp** (`WhisperService.swift`) - Uses local whisper-cli binary
2. **Voxtral via llama.cpp** (`VoxtralCppService.swift`) - Native C++ implementation  
3. **Voxtral via Python** (`VoxtralPromptTester.swift`) - Python server backend

### Critical Services
- **UnifiedTranscriptionManager** - Routes transcription requests to appropriate backend
- **TranscriptionQueueManager** - Manages job queue with retry logic and progress tracking
- **GRDBDatabaseManager** - SQLite database with vectorlite extension for semantic search
- **EmbeddingService** - Generates embeddings for semantic search functionality

### Transcript Cleanup (hallucination detection)
- **TranscriptSuspicionScorer** (`Services/Cleanup/`) - pure, language-agnostic scoring of every
  utterance (silence-filler dot runs, repetition loops, script outliers vs the recording's own
  majority script, token-probability from whisper's `-ojf` sidecar, learned-exemplar affinity).
  Tier discipline: only hard text evidence can auto-hide; probabilistic signals cap at "verify".
- **TranscriptVerificationService** - cuts flagged spans (≤26s) and asks local Gemma (llama-mtmd-cli
  + audio mmproj) for per-line JSON verdicts; strict parsing, failures degrade to `pending_review`.
- **TranscriptCleanupService / TranscriptCleanupQueueManager** - orchestration at the LOWEST GPU
  priority (`GPUConsumer.cleanup = -2`); preempted jobs must requeue as `.pending`, never `.paused`.
- **HallucinationExemplarStore** - learned-only memory of confirmed hallucinations (no curated
  lists); hide teaches, Keep/Undo un-teaches; matched by exact text, char-trigram Jaccard, and
  text-embedding cosine.
- Everything is reversible: soft-hide + `original_text` provenance, review inbox in the sidebar.
- Metrics: `HallucinationEvalTests` (labeled fixture, asserts zero clean-speech auto-hides);
  `LiveLibraryCleanupEval` (env-gated `ALMREC_CLEANUP_EVAL=1`, read-only over the real library).

### Database Architecture
Uses GRDB with custom SQLite build that includes:
- `SQLITE_ENABLE_LOAD_EXTENSION` - Required for vectorlite
- Vectorlite extension for HNSW vector search
- Tables: recordings, utterances, speakers, transcription_jobs, embeddings
- Cleanup columns on utterances (v24: is_hidden, original_text, text_source, suspicion,
  review_status, …) and `hallucination_exemplars` (v25)

## Build Commands

### Build the app
```bash
# Clean and build with Swift Package Manager
swift package clean
swift build

# Build with specific destination
xcodebuild -scheme AlmRecorder -configuration Debug -destination "platform=macOS" build

# Build release version
swift build -c release
```

### Build GRDB custom SQLite (required for vectorlite)
```bash
cd GRDBCustom
./make_binary.sh macos
```

### Run the app
```bash
# Run from build directory
./.build/debug/AlmRecorder

# Or via Swift
swift run
```

## Development Paths

### Whisper Binary Location
- Development: `<repo-root>/External/whisper.cpp/build/bin/whisper-cli`
- Production: Bundled in app resources

### Dynamic Libraries
Whisper requires dynamic libraries loaded via `DYLD_LIBRARY_PATH`:
- Development paths in `WhisperProcessRunner.swift` lines 97-104
- Production: `Bundle.main.resourcePath/Libraries`

### Model Storage
- Whisper models: `~/Library/Application Support/AlmRecorder/Models/Whisper/`
- Voxtral models: `~/Library/Application Support/AlmRecorder/Models/Voxtral/`
- Embedding models: `~/Library/Application Support/AlmRecorder/Models/Embeddings/`

## Progress Calculation System

The app uses a detailed progress tracking system for transcription jobs:

### Progress Components
- **TranscriptionJob.detailedProgress** - Main progress calculation (0.0 to 1.0)
- **TranscriptionJob.progressPhase** - Current phase enum
- **completedChunks/totalChunks** - Chunk tracking for long audio

### Progress Display Rules
1. Always use `detailedProgress` not raw `progress` for UI
2. Current chunk = `completedChunks + 1` (unless currentChunkProgress >= 1.0)
3. Global queue progress uses `detailedProgress` of all active jobs

## Queue Management

### Job Processing Flow
1. Jobs added to `TranscriptionQueueManager.jobs` array
2. Worker processes jobs sequentially
3. Progress reported via callback: `(phase, progress, message, totalChunks, completedChunks)`
4. Automatic cleanup of stuck jobs every 30 seconds
5. Jobs persisted to database for recovery

### Job States
- `pending` - Waiting to process
- `processing` - Currently active
- `completed` - Successfully finished
- `failed` - Error occurred (can retry)
- `waitingForModel` - Model download required

## Testing Commands

### Test Whisper transcription
```bash
# Test with a WAV file
<repo-root>/External/whisper.cpp/build/bin/whisper-cli \
  -m ~/Library/Application\ Support/AlmRecorder/Models/Whisper/ggml-base.bin \
  -f test.wav
```

### Test database and vectorlite
```bash
swift test_grdb_vectorlite.swift
```

### Test embedding generation
```bash
swift test_embedding.swift
```

## Common Issues and Solutions

### CSQLite Module Missing
Build GRDB with custom SQLite:
```bash
cd GRDBCustom
./make_binary.sh macos
```

### Whisper Binary Not Found
Check `WhisperConfiguration.whisperCLIPath` - should point to development or bundled binary

### Dynamic Library Loading Failed
Verify `DYLD_LIBRARY_PATH` includes whisper library paths in `WhisperProcessRunner.swift`

### Vectorlite Extension Failed
Ensure database is using custom SQLite with `SQLITE_ENABLE_LOAD_EXTENSION`

## Key Configuration Files

- `WhisperConfiguration.swift` - Whisper model paths and parameters
- `VoxtralConfiguration.swift` - Voxtral settings
- `GRDBDatabaseManager.swift` - Database and vectorlite setup
- `Package.swift` - Dependencies including local GRDBCustom package

## Debug Logging

Enable verbose logging by checking:
- `WhisperProcessRunner` - Uses OSLog for process execution
- `GRDBDatabaseManager` - SQL query logging when DEBUG
- `VoxtralLogger` - File-based logging to `~/Library/Logs/AlmRecorder/`