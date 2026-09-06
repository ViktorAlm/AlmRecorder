import Foundation

/// Service for speaker diarization using TinyDiarize models
class SpeakerDiarizer {
    
    // MARK: - Types
    
    /// Represents a speaker segment in the audio
    struct SpeakerSegment: Codable {
        let speakerId: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String?
        var embedding: [Float]?  // Speaker embedding vector
        var embeddingConfidence: Float?
        
        var duration: TimeInterval {
            endTime - startTime
        }
        
        // Custom coding to handle optional embedding
        enum CodingKeys: String, CodingKey {
            case speakerId, startTime, endTime, text, embedding, embeddingConfidence
        }
    }
    
    /// Result of diarization process
    struct DiarizationResult {
        let segments: [SpeakerSegment]
        let speakerCount: Int
        let timeline: [(speaker: String, start: TimeInterval, end: TimeInterval)]
        let rawTranscript: String
        var speakerEmbeddings: [String: [Float]]?  // Speaker ID to average embedding
        var unifiedSpeakerMap: [String: String]?   // Local to global speaker mapping
    }
    
    /// Whisper output segment with diarization info
    struct WhisperSegment: Codable {
        let start: Double
        let end: Double
        let text: String
        let speaker_turn_next: Bool?  // TinyDiarize field indicating speaker change
    }
    
    /// Whisper JSON output structure
    struct WhisperOutput: Codable {
        let text: String
        let segments: [WhisperSegment]?
        let language: String?
    }
    
    // MARK: - Properties
    
    private let processRunner = WhisperProcessRunner()
    private let logger = VoxtralLogger.shared
    
    // MARK: - Public Methods
    
    /// Perform speaker diarization on audio file
    /// - Parameters:
    ///   - audioFile: Path to audio file (should be 16kHz WAV)
    ///   - modelPath: Path to TinyDiarize model
    /// - Returns: Diarization result with speaker segments
    func performDiarization(
        audioFile: String,
        modelPath: String
    ) async throws -> DiarizationResult {
        
        logger.info("[SpeakerDiarizer] Starting diarization for: \(audioFile)")
        
        // Run whisper with TinyDiarize model and JSON output
        let (text, jsonData) = try await processRunner.runTranscriptionWithJSON(
            modelPath: modelPath,
            audioPath: audioFile,
            enableDiarization: true,
            wordTimestamps: true
        )
        
        // Parse the output
        let segments = parseWhisperDiarization(
            textOutput: text,
            jsonOutput: jsonData
        )
        
        // Build speaker timeline
        let timeline = buildSpeakerTimeline(from: segments)
        
        // Count unique speakers
        let uniqueSpeakers = Set(segments.map { $0.speakerId })
        
        logger.info("[SpeakerDiarizer] Found \(uniqueSpeakers.count) speakers, \(segments.count) segments")
        
        return DiarizationResult(
            segments: segments,
            speakerCount: uniqueSpeakers.count,
            timeline: timeline,
            rawTranscript: text
        )
    }
    
    /// Parse whisper output with [SPEAKER_TURN] markers or JSON
    /// - Parameters:
    ///   - textOutput: Raw text output from whisper
    ///   - jsonOutput: Optional JSON output with structured segments
    /// - Returns: Array of speaker segments
    func parseWhisperDiarization(
        textOutput: String,
        jsonOutput: Data?
    ) -> [SpeakerSegment] {
        
        // For diarization, prefer text output with [SPEAKER_TURN] markers
        // as it contains proper speaker segment boundaries
        if textOutput.contains("[SPEAKER_TURN]") || textOutput.contains("-->") {
            logger.info("[SpeakerDiarizer] Using text parsing for diarization output")
            return parseTextOutput(textOutput)
        }
        
        // Fallback to JSON parsing if available
        if let jsonData = jsonOutput {
            logger.info("[SpeakerDiarizer] Using JSON parsing as fallback")
            if let segments = parseJSONOutput(jsonData) {
                return segments
            }
        }
        
        // Last resort: try text parsing anyway
        return parseTextOutput(textOutput)
    }
    
    // MARK: - Private Methods
    
    /// Parse JSON output from whisper
    private func parseJSONOutput(_ data: Data) -> [SpeakerSegment]? {
        do {
            let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
            guard let segments = output.segments else { return nil }
            
            var speakerSegments: [SpeakerSegment] = []
            var currentSpeaker = "Speaker 1"
            var speakerCounter = 1
            
            // Group segments by speaker turns
            var currentSpeakerSegments: [WhisperSegment] = []
            
            for (index, segment) in segments.enumerated() {
                currentSpeakerSegments.append(segment)
                
                // Check if this is the last segment or if speaker changes after this segment
                let isLastSegment = (index == segments.count - 1)
                let speakerChanges = (segment.speaker_turn_next == true)
                
                if isLastSegment || speakerChanges {
                    // Create a speaker segment from accumulated segments
                    if !currentSpeakerSegments.isEmpty {
                        let startTime = currentSpeakerSegments[0].start
                        let endTime = currentSpeakerSegments[currentSpeakerSegments.count - 1].end
                        let combinedText = currentSpeakerSegments
                            .map { $0.text }
                            .joined(separator: " ")
                        
                        let speakerSegment = SpeakerSegment(
                            speakerId: currentSpeaker,
                            startTime: startTime,
                            endTime: endTime,
                            text: combinedText
                        )
                        speakerSegments.append(speakerSegment)
                        
                        // Clear for next speaker
                        currentSpeakerSegments.removeAll()
                    }
                    
                    // Update speaker for next segment
                    if speakerChanges && !isLastSegment {
                        speakerCounter += 1
                        currentSpeaker = "Speaker \(speakerCounter)"
                    }
                }
            }
            
            logger.info("[SpeakerDiarizer] Parsed \(speakerSegments.count) speaker segments from \(segments.count) word segments")
            return speakerSegments
            
        } catch {
            logger.error("[SpeakerDiarizer] Failed to parse JSON: \(error)")
            return nil
        }
    }
    
    /// Parse text output with [SPEAKER_TURN] markers
    private func parseTextOutput(_ text: String) -> [SpeakerSegment] {
        var segments: [SpeakerSegment] = []
        var currentSpeaker = "Speaker 1"
        var speakerCounter = 1
        
        // Split by [SPEAKER_TURN] marker
        let parts = text.components(separatedBy: "[SPEAKER_TURN]")
        
        for (index, part) in parts.enumerated() {
            let trimmedText = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedText.isEmpty { continue }
            
            // Extract all timestamps and text from this speaker's turn
            // Handle multi-line segments where one speaker has multiple timestamp lines
            let lines = trimmedText.components(separatedBy: .newlines)
            var segmentTexts: [String] = []
            var segmentStart: TimeInterval?
            var segmentEnd: TimeInterval?
            
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty { continue }
                
                let (lineStart, lineEnd, lineText) = extractTimestamps(from: trimmedLine)
                
                if let start = lineStart, let end = lineEnd {
                    // Update segment boundaries
                    if segmentStart == nil {
                        segmentStart = start
                    }
                    segmentEnd = end
                    
                    if !lineText.isEmpty {
                        segmentTexts.append(lineText)
                    }
                } else if !trimmedLine.isEmpty {
                    // Line without timestamp, add to text
                    segmentTexts.append(trimmedLine)
                }
            }
            
            // Create segment if we have valid data
            if let start = segmentStart, let end = segmentEnd {
                let combinedText = segmentTexts.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Validate segment duration
                if end > start {
                    let segment = SpeakerSegment(
                        speakerId: currentSpeaker,
                        startTime: start,
                        endTime: end,
                        text: combinedText.isEmpty ? nil : combinedText
                    )
                    segments.append(segment)
                } else {
                    logger.warning("[SpeakerDiarizer] Skipping segment with invalid duration: \(start) to \(end)")
                }
            }
            
            // Change speaker for next segment
            if index < parts.count - 1 {
                speakerCounter += 1
                currentSpeaker = "Speaker \(speakerCounter)"
            }
        }
        
        logger.info("[SpeakerDiarizer] Parsed \(segments.count) speaker segments from text output")
        return validateAndFilterSegments(segments)
    }
    
    /// Extract timestamps from text like "[00:00:00.000 --> 00:00:03.800]"
    private func extractTimestamps(from text: String) -> (start: TimeInterval?, end: TimeInterval?, text: String) {
        let pattern = #"\[(\d{2}:\d{2}:\d{2}\.\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}\.\d{3})\]"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return (nil, nil, text)
        }
        
        let startStr = (text as NSString).substring(with: match.range(at: 1))
        let endStr = (text as NSString).substring(with: match.range(at: 2))
        
        let start = parseTimestamp(startStr)
        let end = parseTimestamp(endStr)
        
        // Remove timestamp from text
        let cleanText = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (start, end, cleanText)
    }
    
    /// Parse timestamp string "HH:MM:SS.mmm" to TimeInterval
    private func parseTimestamp(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        
        guard let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        
        return hours * 3600 + minutes * 60 + seconds
    }
    
    /// Merge consecutive segments from the same speaker
    private func mergeConsecutiveSpeakerSegments(
        _ segments: [SpeakerSegment],
        maxGap: TimeInterval = 0.5
    ) -> [SpeakerSegment] {
        
        guard !segments.isEmpty else { return [] }
        
        var merged: [SpeakerSegment] = []
        var currentSegment = segments[0]
        
        for i in 1..<segments.count {
            let nextSegment = segments[i]
            
            // Check if same speaker and close enough in time
            if currentSegment.speakerId == nextSegment.speakerId,
               nextSegment.startTime - currentSegment.endTime <= maxGap {
                // Merge segments
                let mergedText = [currentSegment.text, nextSegment.text]
                    .compactMap { $0 }
                    .joined(separator: " ")
                
                currentSegment = SpeakerSegment(
                    speakerId: currentSegment.speakerId,
                    startTime: currentSegment.startTime,
                    endTime: nextSegment.endTime,
                    text: mergedText
                )
            } else {
                // Different speaker or too far apart, save current and start new
                merged.append(currentSegment)
                currentSegment = nextSegment
            }
        }
        
        // Don't forget the last segment
        merged.append(currentSegment)
        
        return merged
    }
    
    /// Build a timeline of speaker turns
    private func buildSpeakerTimeline(
        from segments: [SpeakerSegment]
    ) -> [(speaker: String, start: TimeInterval, end: TimeInterval)] {
        
        return segments.map { segment in
            (speaker: segment.speakerId, start: segment.startTime, end: segment.endTime)
        }
    }
    
    /// Validate and filter segments for quality and robustness
    private func validateAndFilterSegments(
        _ segments: [SpeakerSegment],
        minDuration: TimeInterval = 0.5,
        maxGapToMerge: TimeInterval = 0.3
    ) -> [SpeakerSegment] {
        
        guard !segments.isEmpty else { return [] }
        
        var validated: [SpeakerSegment] = []
        let sortedSegments = segments.sorted { $0.startTime < $1.startTime }
        
        // Remove overlapping segments and merge very close segments from same speaker
        var currentSegment = sortedSegments[0]
        
        for i in 1..<sortedSegments.count {
            let nextSegment = sortedSegments[i]
            
            // Check for overlap
            if nextSegment.startTime < currentSegment.endTime {
                logger.warning("[SpeakerDiarizer] Overlapping segments detected: \(currentSegment.speakerId) [\(currentSegment.startTime)-\(currentSegment.endTime)] and \(nextSegment.speakerId) [\(nextSegment.startTime)-\(nextSegment.endTime)]")
                // Adjust the end time to avoid overlap
                currentSegment = SpeakerSegment(
                    speakerId: currentSegment.speakerId,
                    startTime: currentSegment.startTime,
                    endTime: min(currentSegment.endTime, nextSegment.startTime),
                    text: currentSegment.text
                )
            }
            
            // Check if we should merge with next segment (same speaker, small gap)
            let gap = nextSegment.startTime - currentSegment.endTime
            if currentSegment.speakerId == nextSegment.speakerId && gap <= maxGapToMerge && gap >= 0 {
                // Merge segments
                let mergedText = [currentSegment.text, nextSegment.text]
                    .compactMap { $0 }
                    .joined(separator: " ")
                
                currentSegment = SpeakerSegment(
                    speakerId: currentSegment.speakerId,
                    startTime: currentSegment.startTime,
                    endTime: nextSegment.endTime,
                    text: mergedText.isEmpty ? nil : mergedText
                )
            } else {
                // Save current segment if it meets minimum duration
                if currentSegment.duration >= minDuration {
                    validated.append(currentSegment)
                } else {
                    logger.info("[SpeakerDiarizer] Filtering out short segment: \(currentSegment.speakerId) [\(currentSegment.startTime)-\(currentSegment.endTime)] duration=\(currentSegment.duration)s")
                }
                currentSegment = nextSegment
            }
        }
        
        // Don't forget the last segment
        if currentSegment.duration >= minDuration {
            validated.append(currentSegment)
        }
        
        logger.info("[SpeakerDiarizer] Validated \(validated.count) segments from \(segments.count) original segments")
        return validated
    }
    
    /// Merge multiple segments into one
    private func mergeSpeakerSegments(_ segments: [SpeakerSegment]) -> SpeakerSegment? {
        guard !segments.isEmpty else {
            logger.warning("[SpeakerDiarizer] Attempted to merge empty segments - returning nil")
            return nil
        }
        
        let text = segments.compactMap { $0.text }.joined(separator: " ")
        
        return SpeakerSegment(
            speakerId: segments[0].speakerId,
            startTime: segments[0].startTime,
            endTime: segments[segments.count - 1].endTime,
            text: text.isEmpty ? nil : text
        )
    }
}
