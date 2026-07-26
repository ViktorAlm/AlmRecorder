import Foundation

/// Errors that can occur during transcription
enum TranscriptionError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case invalidURL
    case downloadFailed
    case downloadCancelled
    case downloadTimeout
    case serviceNotReady
    case llamaCppNotFound
    case processFailed(String)
    /// A llama.cpp/whisper child died with the Metal out-of-memory signature (see
    /// `BackgroundGPUAdmission.isMetalOOM`). Background queues treat this as systemic — requeue
    /// as `.pending` without burning retry budget — while `SystemMemoryGate` holds launches back.
    case gpuOutOfMemory(String)
    case homebrewNotFound
    case installationFailed
    case serverNotRunning
    case invalidResponse
    case transcriptionFailed(String)
    case diarizationFailed(String)
    case whisperNotFound
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Model configuration not found. Please download a model first."
        case .modelNotLoaded:
            return "Model not loaded. Please download and select a model."
        case .invalidURL:
            return "Invalid file URL or file does not exist."
        case .downloadFailed:
            return "Failed to download model. Please check your internet connection."
        case .downloadCancelled:
            return "Download was cancelled."
        case .downloadTimeout:
            return "Download timed out after 2 hours."
        case .serviceNotReady:
            return "Transcription service is not ready."
        case .llamaCppNotFound:
            return "llama-mtmd-cli not found. Please install llama.cpp first."
        case .processFailed(let error):
            return "Transcription process failed: \(error)"
        case .gpuOutOfMemory(let detail):
            return "GPU ran out of memory: \(detail)"
        case .homebrewNotFound:
            return "Homebrew not found. Please install Homebrew first to install llama.cpp."
        case .installationFailed:
            return "Failed to install llama.cpp. Please install manually."
        case .serverNotRunning:
            return "Transcription server is not running. Please start the server."
        case .invalidResponse:
            return "Invalid response from transcription service."
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error)"
        case .diarizationFailed(let error):
            return "Speaker diarization failed: \(error)"
        case .whisperNotFound:
            return "Whisper CLI not found. Please check your installation."
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .modelNotFound, .modelNotLoaded:
            return "Go to Settings > Models and download the selected transcription model."
        case .invalidURL:
            return "Make sure the audio file exists and is accessible."
        case .downloadFailed:
            return "Check your internet connection and try again."
        case .llamaCppNotFound:
            return "Install llama.cpp using: brew install llama.cpp"
        case .homebrewNotFound:
            return "Install Homebrew from https://brew.sh"
        case .serverNotRunning:
            return "Try switching to native transcription in Settings."
        case .gpuOutOfMemory:
            return "Close memory-heavy apps and try again — background AI work pauses and retries on its own."
        default:
            return nil
        }
    }
}
