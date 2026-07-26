# Speaker Identification System

AlmRecorder now includes a state-of-the-art speaker identification system using Pyannote embeddings via CoreML. This system can identify and track unique speakers across entire recordings, even when audio is split into multiple chunks.

## Features

- **Speaker Embeddings**: Extracts 512-dimensional voice embeddings using Pyannote's speaker verification model
- **Cross-Chunk Unification**: Automatically identifies the same speaker across different VAD chunks
- **Pure Swift Implementation**: Uses CoreML for fast, native inference on Apple Silicon
- **Hierarchical Clustering**: Groups similar voice embeddings to identify unique speakers
- **Confidence Scoring**: Provides confidence levels for speaker identification

## Setup

### 1. Convert Pyannote Model to CoreML

First, install the required Python dependencies:

```bash
pip install pyannote.audio torch coremltools
```

Then run the conversion script:

```bash
cd Scripts
python convert_pyannote_to_coreml.py
```

This will:
- Download the Pyannote embedding model from Hugging Face
- Convert it to CoreML format
- Save it to `AlmRecorder/Resources/Models/PyannoteSpeakerEmbedding.mlpackage`
- Verify the conversion was successful

The converted model is approximately 50MB.

### 2. Add Model to Xcode Project

1. Open the AlmRecorder Xcode project
2. Drag `PyannoteSpeakerEmbedding.mlpackage` into the project
3. Ensure it's added to the AlmRecorder target
4. Build and run

## How It Works

### Pipeline Overview

1. **VAD Splitting**: Audio is split into ~60-second chunks using Voice Activity Detection
2. **Speaker Diarization**: TinyDiarize identifies speaker boundaries within each chunk
3. **Embedding Extraction**: Pyannote model extracts voice embeddings for each speaker segment
4. **Speaker Unification**: Similar embeddings across chunks are grouped to identify unique speakers
5. **Transcription**: Each speaker segment is transcribed with unified speaker IDs

### Technical Details

#### Speaker Embedding Extraction
```swift
let embeddingService = try PyannoteSpeakerEmbedding()
let embedding = try await embeddingService.extractEmbedding(from: audioPath)
// Returns 512-dimensional Float array
```

#### Speaker Similarity Comparison
```swift
let similarity = embeddingService.similarity(embedding1, embedding2)
// Returns 0-1 score (higher = more similar)

let isSame = embeddingService.isSameSpeaker(embedding1, embedding2, threshold: 0.85)
// Returns true if likely same speaker
```

#### Speaker Unification Across Chunks
```swift
let unificationService = try SpeakerUnificationService()
let result = unificationService.unifySpeakers(from: chunkSpeakers)
// Returns unified speaker mapping
```

## Configuration

### Similarity Threshold
The default threshold for considering two speakers as the same is 0.85. You can adjust this:

```swift
let unificationService = try SpeakerUnificationService(similarityThreshold: 0.90)
```

Higher values = more strict matching (fewer false positives, more false negatives)
Lower values = more lenient matching (fewer false negatives, more false positives)

### Audio Window Size
Speaker embeddings are extracted from 3-second audio windows by default. This can be adjusted in `PyannoteSpeakerEmbedding.swift`:

```swift
private let windowSizeSeconds: Double = 3.0  // Adjust as needed
```

## Output Format

When speaker identification is enabled, transcriptions include unified speaker IDs:

```
[Speaker 1] Hello, this is the first speaker talking.

[Speaker 2] And this is a different person speaking.

[Speaker 1] The first speaker is talking again, even in a different chunk.
```

## Performance

- **Embedding Extraction**: ~100ms per 3-second segment
- **Similarity Computation**: <1ms per comparison
- **Unification**: O(n²) complexity where n = total speaker segments
- **Memory**: ~50MB for model + embedding storage

## Troubleshooting

### Model Not Found
If you see "Speaker embedding model not found":
1. Ensure you've run the conversion script
2. Add the .mlpackage to your Xcode project
3. Check that it's included in the app bundle

### No Speaker Embeddings
If embeddings aren't being extracted:
- The system will fall back to sequential speaker numbering
- Check console logs for error messages
- Ensure audio segments are at least 1 second long

### Poor Speaker Separation
If speakers aren't being properly distinguished:
- Try adjusting the similarity threshold
- Ensure good audio quality (low noise, clear speech)
- Consider that very similar voices may be challenging to separate

## Future Improvements

- **Speaker Database**: Store known speaker profiles for identification across recordings
- **Real-time Processing**: Extract embeddings during recording for live speaker identification
- **Voice Characteristics**: Display pitch, tone, and other voice characteristics
- **Speaker Naming**: Allow users to label and save speaker identities

## Technical References

- [Pyannote Audio](https://github.com/pyannote/pyannote-audio)
- [CoreML Documentation](https://developer.apple.com/documentation/coreml)
- [VoxCeleb Dataset](https://www.robots.ox.ac.uk/~vgg/data/voxceleb/) (training data)
- [ECAPA-TDNN Architecture](https://arxiv.org/abs/2005.07143) (model architecture)