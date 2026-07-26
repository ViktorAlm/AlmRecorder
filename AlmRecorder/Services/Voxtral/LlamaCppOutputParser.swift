import Foundation

/// Parses output from llama-mtmd-cli to extract transcripts and errors
class LlamaCppOutputParser {
    
    /// Result of parsing llama.cpp output
    struct ParseResult {
        let transcript: String?
        let error: ParsedError?
        let warnings: [String]
        let processingInfo: ProcessingInfo
        
        var isSuccess: Bool {
            transcript != nil && error == nil
        }
    }
    
    /// Parsed error information
    struct ParsedError {
        let type: ErrorType
        let message: String
        let details: String?
        
        enum ErrorType {
            case fileNotFound
            case modelError
            case memoryError
            case audioFormatError
            case processTimeout
            case unknown
        }
    }
    
    /// Processing information extracted from logs
    struct ProcessingInfo {
        let modelLoadTime: TimeInterval?
        let audioEncodingTime: TimeInterval?
        let decodingTime: TimeInterval?
        let tokensGenerated: Int?
        let tokenSequence: String? // Extracted token IDs if verbose
    }
    
    private let logger = VoxtralLogger.shared
    
    /// Parse llama.cpp output into structured result
    func parse(stdout: String, stderr: String, exitCode: Int32) -> ParseResult {
        logger.debug("Parsing output - exit code: \(exitCode)")
        
        // Save raw output in debug mode for investigation
        #if DEBUG
        if stdout.count > 0 {
            logger.debug("=== RAW STDOUT (\(stdout.count) chars) ===")
            logger.debug(String(stdout.prefix(500)))
            if stdout.count > 500 {
                logger.debug("... [\(stdout.count - 500) more characters]")
            }
        }
        if stderr.count > 0 {
            logger.debug("=== RAW STDERR (\(stderr.count) chars) ===")
            logger.debug(String(stderr.prefix(500)))
        }
        #endif
        
        // Check for errors first
        if let error = parseError(stdout: stdout, stderr: stderr, exitCode: exitCode) {
            logger.warning("Detected error in output: \(error.message)")
            return ParseResult(
                transcript: nil,
                error: error,
                warnings: extractWarnings(from: stderr),
                processingInfo: extractProcessingInfo(from: stderr, stdout: stdout)
            )
        }
        
        // Extract transcript from stdout
        let transcript = extractTranscript(from: stdout)
        
        // If no transcript found but no error detected, create a generic error
        if transcript == nil || transcript?.isEmpty == true {
            logger.warning("No transcript found in output")
            return ParseResult(
                transcript: nil,
                error: ParsedError(
                    type: .unknown,
                    message: "No transcription generated",
                    details: "The model did not produce any output. The audio may be silent or corrupted."
                ),
                warnings: extractWarnings(from: stderr),
                processingInfo: extractProcessingInfo(from: stderr, stdout: stdout)
            )
        }
        
        return ParseResult(
            transcript: transcript,
            error: nil,
            warnings: extractWarnings(from: stderr),
            processingInfo: extractProcessingInfo(from: stderr, stdout: stdout)
        )
    }
    
    /// Parse error from output
    private func parseError(stdout: String, stderr: String, exitCode: Int32) -> ParsedError? {
        // Check exit code first
        if exitCode != 0 {
            // Check for specific error patterns
            if stderr.contains("Unable to open file") || stderr.contains("No such file or directory") {
                let details = extractErrorDetails(from: stderr, pattern: "Unable to open file.*")
                return ParsedError(
                    type: .fileNotFound,
                    message: "Audio file not found",
                    details: details ?? "The audio file could not be accessed. It may have been moved or deleted."
                )
            }
            
            if stderr.contains("failed to load model") || stderr.contains("ggml_graph_compute") {
                return ParsedError(
                    type: .modelError,
                    message: "Model loading failed",
                    details: extractErrorDetails(from: stderr, pattern: "failed to.*")
                )
            }
            
            if stderr.contains("out of memory") || stderr.contains("malloc failed") {
                return ParsedError(
                    type: .memoryError,
                    message: "Insufficient memory",
                    details: "Not enough memory to process the audio. Try closing other applications."
                )
            }
            
            if stderr.contains("unsupported audio format") || stderr.contains("invalid audio") {
                return ParsedError(
                    type: .audioFormatError,
                    message: "Unsupported audio format",
                    details: extractErrorDetails(from: stderr, pattern: "audio.*")
                )
            }
            
            // Generic error for non-zero exit code
            return ParsedError(
                type: .unknown,
                message: "Process failed with exit code \(exitCode)",
                details: stderr.isEmpty ? nil : String(stderr.prefix(500))
            )
        }
        
        // Check for error patterns even with exit code 0
        if stdout.contains("Error:") || stdout.contains("ERROR") {
            let errorLine = stdout.components(separatedBy: .newlines)
                .first { $0.contains("Error:") || $0.contains("ERROR") }
            
            return ParsedError(
                type: .unknown,
                message: "Processing error",
                details: errorLine
            )
        }
        
        return nil
    }
    
    /// Extract transcript from stdout
    private func extractTranscript(from stdout: String) -> String? {
        logger.debug("Extracting transcript from \(stdout.count) characters of output")
        
        var transcript = stdout
        
        // Extended list of processing patterns to filter out
        let processingPatterns = [
            // Model loading
            "main: loading model:",
            "llama_model_loader:",
            "llama_new_context",
            "llama_kv_cache",
            
            // Audio processing
            "encoding audio slice",
            "audio slice encoded",
            "decoding audio batch",
            "audio decoded",
            "audio_slices:",
            
            // System info
            "ggml_",
            "llama_",
            "system_info:",
            "sampling:",
            "compute_buffer_size:",
            "available_memory:",
            
            // Timing info
            "sample time",
            "prompt eval time",
            "eval time",
            "total time",
            
            // Progress indicators
            "Processing",
            "Loading",
            "Initializing"
        ]
        
        // Look for specific transcript markers first
        // The actual transcript often appears after specific markers
        if let transcriptStart = stdout.range(of: "\n\n", options: .backwards) {
            // Get everything after the last double newline
            let possibleTranscript = String(stdout[transcriptStart.upperBound...])
            if !possibleTranscript.isEmpty {
                transcript = possibleTranscript
            }
        }
        
        // Split into lines and filter out processing logs
        let lines = transcript.components(separatedBy: .newlines)
        let filteredLines = lines.filter { line in
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines
            if trimmedLine.isEmpty {
                return false
            }
            
            // Skip lines that are clearly debug/processing logs
            for pattern in processingPatterns {
                if trimmedLine.lowercased().contains(pattern.lowercased()) {
                    return false
                }
            }
            
            // Skip lines that look like debug output
            if trimmedLine.hasPrefix("[") || 
               trimmedLine.hasPrefix("{") || 
               trimmedLine.hasPrefix("//") ||
               trimmedLine.hasPrefix("#") ||
               trimmedLine.contains("=") && trimmedLine.contains(":") { // Skip key=value debug lines
                return false
            }
            
            // Skip timing/performance lines
            if trimmedLine.contains(" ms") || 
               trimmedLine.contains(" tokens/s") ||
               trimmedLine.contains(" MB") {
                return false
            }
            
            return true
        }
        
        transcript = filteredLines.joined(separator: "\n")
        
        // Clean up the transcript
        transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Return nil if transcript is empty or too short (likely just noise)
        if transcript.isEmpty || transcript.count < 3 {
            return nil
        }
        
        return transcript
    }
    
    /// Extract warnings from stderr
    private func extractWarnings(from stderr: String) -> [String] {
        var warnings: [String] = []
        
        let lines = stderr.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("warning:") || trimmed.contains("Warning:") {
                warnings.append(trimmed)
            }
        }
        
        return warnings
    }
    
    /// Extract processing information from logs
    private func extractProcessingInfo(from stderr: String, stdout: String = "") -> ProcessingInfo {
        var modelLoadTime: TimeInterval?
        var audioEncodingTime: TimeInterval?
        var decodingTime: TimeInterval?
        var tokensGenerated: Int?
        
        // Parse timing information if available
        if let match = stderr.range(of: "model loaded in (\\d+\\.\\d+) ms", options: .regularExpression) {
            let timeStr = String(stderr[match])
            if let time = extractNumber(from: timeStr) {
                modelLoadTime = time / 1000.0 // Convert ms to seconds
            }
        }
        
        if let match = stderr.range(of: "audio slice encoded in (\\d+\\.\\d+) ms", options: .regularExpression) {
            let timeStr = String(stderr[match])
            if let time = extractNumber(from: timeStr) {
                audioEncodingTime = time / 1000.0
            }
        }
        
        if let match = stderr.range(of: "decoded in (\\d+\\.\\d+) ms", options: .regularExpression) {
            let timeStr = String(stderr[match])
            if let time = extractNumber(from: timeStr) {
                decodingTime = time / 1000.0
            }
        }
        
        // Parse token count if available
        if let match = stderr.range(of: "generated (\\d+) tokens", options: .regularExpression) {
            let tokenStr = String(stderr[match])
            if let count = extractNumber(from: tokenStr) {
                tokensGenerated = Int(count)
            }
        }
        
        // Extract token sequence if present (from verbose-prompt output)
        var tokenSequence: String?
        
        // Try multiple patterns for token extraction
        // Pattern 1: "prompt tokens: [1, 2, 3]"
        if let tokenMatch = stderr.range(of: "prompt tokens: \\[([^\\]]+)\\]", options: .regularExpression) {
            let tokenStr = String(stderr[tokenMatch])
            tokenSequence = tokenStr.replacingOccurrences(of: "prompt tokens: ", with: "")
        }
        // Pattern 2: "tokens: ..."
        else if let tokenMatch = stderr.range(of: "tokens: [^\\n]+", options: .regularExpression) {
            let tokenStr = String(stderr[tokenMatch])
            tokenSequence = tokenStr.replacingOccurrences(of: "tokens: ", with: "")
        }
        // Pattern 3: Look in stdout for verbose prompt output
        else if let tokenMatch = stdout.range(of: "prompt: [^\\n]+", options: .regularExpression) {
            let tokenStr = String(stdout[tokenMatch])
            tokenSequence = tokenStr.replacingOccurrences(of: "prompt: ", with: "")
        }
        
        return ProcessingInfo(
            modelLoadTime: modelLoadTime,
            audioEncodingTime: audioEncodingTime,
            decodingTime: decodingTime,
            tokensGenerated: tokensGenerated,
            tokenSequence: tokenSequence
        )
    }
    
    /// Extract error details matching a pattern
    private func extractErrorDetails(from text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range) {
            let matchRange = Range(match.range, in: text)!
            return String(text[matchRange])
        }
        
        return nil
    }
    
    /// Extract number from string
    private func extractNumber(from text: String) -> Double? {
        let pattern = "(\\d+\\.?\\d*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range) {
            let matchRange = Range(match.range(at: 1), in: text)!
            return Double(text[matchRange])
        }
        
        return nil
    }
}