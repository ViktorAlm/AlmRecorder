# Audio Preprocessing Implementation

## Overview
AlmRecorder now includes native audio preprocessing capabilities using AVFoundation, eliminating the need for FFmpeg and avoiding licensing/distribution issues.

## Features

### 1. Automatic Recording Chunking (10 minutes)
- Recordings automatically split into 10-minute chunks
- Seamless recording experience - user doesn't notice the splits
- Chunks are tracked in `AudioRecorder.recordedChunks` array
- Prevents memory issues with very long recordings

### 2. Audio File Splitting
- **AudioPreprocessor** service handles all splitting operations
- Native AVFoundation implementation (no FFmpeg required)
- Supports splitting any audio file into specified chunk durations
- Automatic format conversion to WAV for Voxtral compatibility

### 3. Voxtral Preparation
- Automatic splitting of files >30 minutes (Voxtral's limit)
- Conversion to 16kHz mono WAV format
- Chunk-based transcription with progress tracking
- Results combined automatically

## Implementation Details

### Services Created/Updated:

1. **AudioPreprocessor.swift** (New)
   - `splitAudioFile()` - Split audio into chunks
   - `convertToWAV()` - Convert to Voxtral-compatible format
   - `prepareForVoxtral()` - Automatic preparation for transcription
   - `cleanupChunks()` - Temporary file cleanup

2. **AudioRecorder.swift** (Updated)
   - Auto-chunking every 10 minutes during recording
   - `recordedChunks` array tracks all chunk files
   - Seamless chunk rotation without interrupting recording

3. **VoxtralCppService.swift** (Updated)
   - `transcribeChunks()` - Process multiple audio chunks
   - Progress reporting for long transcriptions
   - Automatic result combination with chunk markers

## Usage Examples

### Recording with Auto-Chunking
```swift
// Start recording - automatically chunks every 10 minutes
audioRecorder.startRecording()

// After stopping, access all chunks
let chunks = audioRecorder.recordedChunks
```

### Preprocessing for Transcription
```swift
let preprocessor = AudioPreprocessor()

// Prepare any audio file for Voxtral (splits if >30min)
let chunks = try await preprocessor.prepareForVoxtral(audioURL: fileURL)

// Transcribe all chunks
let transcript = try await voxtralService.transcribeChunks(
    audioChunks: chunks,
    progressHandler: { progress in
        print("Progress: \(progress * 100)%")
    }
)

// Cleanup temporary files
preprocessor.cleanupChunks(chunks)
```

### Manual Splitting
```swift
// Split into custom duration chunks
let chunks = try await preprocessor.splitAudioFile(
    sourceURL: audioFile,
    chunkDuration: 300 // 5 minutes
)
```

## Technical Benefits

1. **No FFmpeg Dependency**
   - Avoids LGPL licensing issues
   - App Store compatible
   - No external binaries to bundle
   - Smaller app size

2. **Native Performance**
   - Uses hardware-accelerated AVFoundation
   - Efficient memory usage
   - Metal acceleration where available

3. **Reliability**
   - No dependency on user-installed tools
   - Consistent behavior across all macOS versions
   - Better error handling and recovery

## Chunk Duration Guidelines

- **Recording**: 10 minutes per chunk
  - Balances file size and processing efficiency
  - Prevents memory issues during long sessions
  
- **Voxtral Processing**: 30 minutes maximum
  - Model's context window limitation
  - Optimal transcription quality
  
- **Import/Export**: User configurable
  - Can be adjusted based on needs
  - Default to 10-minute chunks

## Future Enhancements

1. Smart splitting at silence boundaries
2. Parallel chunk processing for faster transcription
3. Configurable chunk durations in settings
4. Audio level detection for auto-pause
5. Compression options for storage optimization