import Foundation

struct SpeakerPostProcessingResult {
    let chunks: [TranscriptionChunk]
    let speakerEmbeddings: [TranscriptionSpeakerEmbedding]
}

/// Engine-independent speaker fusion. ASR backends provide text/timestamps; this stage provides
/// overlap-aware local labels and the same 256-dimensional voice evidence used by global matching.
enum SpeakerPostProcessor {
    static func fuse(
        chunks sourceChunks: [TranscriptionChunk],
        audioURL: URL,
        configuration: SpeakerPipelineConfiguration
    ) async throws -> SpeakerPostProcessingResult {
        guard !sourceChunks.isEmpty else {
            return SpeakerPostProcessingResult(chunks: [], speakerEmbeddings: [])
        }

        let service = try await FluidAudioEmbeddingService(configuration: configuration)
        var run = try await service.diarizeDetailed(
            audioURL,
            configuration: configuration
        )
        let timedWords = sourceChunks.flatMap {
            SpeakerAlignment.approximateWordSegments(
                text: $0.text,
                start: $0.startTime,
                end: $0.endTime
            )
        }
        if configuration.diarizationBackend == .offlineVBxTargetedSortformer {
            run = try await service.repairWithTargetedSortformer(
                audioURL,
                baseline: run,
                targetSegments: timedWords,
                configuration: configuration
            )
        }

        let aligned = SpeakerAlignment.align(
            timedWords,
            to: run.turns,
            strategy: configuration.alignmentStrategy,
            utteranceSegmentation: configuration.effectiveUtteranceSegmentation
        )
        let chunks = aligned.map { segment in
            let rawSpeaker = segment.speaker
            let nativeLabel = sourceChunks
                .max(by: {
                    temporalOverlap($0, segment) < temporalOverlap($1, segment)
                })?
                .nativeSpeakerLabel
            return TranscriptionChunk(
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                speaker: rawSpeaker.map { "Speaker \($0)" },
                speakerUUID: nil,
                nativeSpeakerLabel: nativeLabel,
                voiceEmbedding: segment.embedding,
                voiceEmbeddingQuality: rawSpeaker.flatMap {
                    SpeakerAlignment.quality(
                        for: $0,
                        start: segment.startTime,
                        end: segment.endTime,
                        turns: run.turns
                    )
                },
                speakerOverlapRatio: segment.speakerOverlapRatio,
                activeSpeakerCount: segment.activeSpeakerCount,
                overlappingSpeakerLabels: segment.overlappingSpeakers.map { "Speaker \($0)" },
                confidence: segment.confidence,
                tokenStats: segment.tokenStats
            )
        }
        let centroids = SpeakerAlignment.clusterEmbeddings(
            from: run.turns,
            policy: configuration.centroidPolicy
        )
        let embeddings = centroids.map {
            TranscriptionSpeakerEmbedding(
                speakerId: "Speaker \($0.speaker)",
                embedding: $0.embedding,
                startTime: $0.start,
                endTime: $0.end,
                confidence: $0.confidence
            )
        }
        return SpeakerPostProcessingResult(chunks: chunks, speakerEmbeddings: embeddings)
    }

    private static func temporalOverlap(
        _ source: TranscriptionChunk,
        _ aligned: SpeakerAlignedTextSegment
    ) -> TimeInterval {
        max(0, min(source.endTime, aligned.endTime) - max(source.startTime, aligned.startTime))
    }
}
