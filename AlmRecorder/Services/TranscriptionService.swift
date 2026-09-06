import Foundation
import Combine

class TranscriptionService: ObservableObject {
    private let logger = VoxtralLogger.shared
    
    enum Backend {
        case whisper  // Whisper.cpp (primary)
        case native   // llama.cpp with Voxtral (secondary)
        case vibeVoice // Microsoft VibeVoice-ASR through the bundled MLX helper
        case python   // Python server (fallback)
    }
    
    @Published var isServerRunning = false
    @Published var currentBackend: Backend = .whisper
    @Published var isReady = false
    @Published var transcriptionStatus: String = ""
    @Published var transcriptionProgress: Double = 0.0
    
    private let serverURL = "http://localhost:8000"
    private var serverProcess: Process?
    private let whisperService = WhisperService.shared
    private let voxtralService = VoxtralCppService()
    private let vibeVoiceService = VibeVoiceService.shared
    private var statusCancellable: AnyCancellable?
    private var whisperCancellables = Set<AnyCancellable>()
    
    init() {
        logger.info("[TranscriptionService] Initializing...")
        logger.info("[TranscriptionService] WhisperService - Ready: \(whisperService.isReady)")
        logger.info("[TranscriptionService] VoxtralService - Model loaded: \(voxtralService.isModelLoaded)")
        logger.info("[TranscriptionService] VoxtralService - Llama installed: \(voxtralService.isLlamaInstalled)")
        
        // Bind status updates
        setupStatusBinding()
        
        let selectedBackend = GlobalModelSettings.shared.transcriptionBackend

        if selectedBackend == .vibeVoice {
            currentBackend = .vibeVoice
            isReady = vibeVoiceService.isRuntimeInstalled
                && VibeVoiceModelManager.shared.isModelDownloaded(
                    GlobalModelSettings.shared.selectedVibeVoiceQuantization
                )
            setupStatusBinding()
            logger.info(
                "[TranscriptionService] Restored VibeVoice backend; ready: \(isReady)"
            )
        } else if selectedBackend == .llm {
            // Gemma audio transcription is deferred. The legacy `.gemma` preference is migrated
            // by GlobalModelSettings; only Voxtral may occupy the LLM transcription backend.
            currentBackend = .native
            isReady = voxtralService.isModelLoaded && voxtralService.isLlamaInstalled
            setupStatusBinding()
            logger.info(
                "[TranscriptionService] Restored LLM backend; ready: \(isReady)"
            )
        } else if whisperService.isReady {
            currentBackend = .whisper
            isReady = true
            logger.info("[TranscriptionService] Using Whisper backend (preferred)")
        }
        // Only use Voxtral if Whisper is not available and user explicitly wants it
        else if voxtralService.isModelLoaded && (GRDBSettingsRepository.shared.getBool(forKey: "preferVoxtral") ?? false) {
            currentBackend = .native
            isReady = true
            logger.info("[TranscriptionService] Using native Voxtral backend (Whisper not available)")
        } else if selectedBackend == .whisper && !whisperService.isReady {
            // Keep startup side-effect free. The setup wizard and Models screen explain the
            // download size and let the user choose; an actual queued Whisper run may also request
            // its explicitly selected model.
            currentBackend = .whisper
            isReady = false
            transcriptionStatus = "No Whisper model installed — choose one in Models"
        }
        
        logger.info("[TranscriptionService] Initial backend: \(currentBackend), Ready: \(isReady)")
    }
    
    private func setupStatusBinding() {
        // Clear any existing subscriptions
        whisperCancellables.removeAll()
        statusCancellable?.cancel()
        
        // Bind to appropriate service based on backend
        switch currentBackend {
        case .whisper:
            // Subscribe to status updates from WhisperService
            whisperService.$transcriptionStatus
                .sink { [weak self] status in
                    self?.transcriptionStatus = status
                }
                .store(in: &whisperCancellables)
            
            whisperService.$transcriptionProgress
                .sink { [weak self] progress in
                    self?.transcriptionProgress = progress
                }
                .store(in: &whisperCancellables)
                
        case .native:
            // Subscribe to status updates from VoxtralService
            voxtralService.$transcriptionStatus
                .assign(to: &$transcriptionStatus)
            
            voxtralService.$transcriptionProgress
                .assign(to: &$transcriptionProgress)
                
        case .vibeVoice:
            vibeVoiceService.$transcriptionStatus
                .assign(to: &$transcriptionStatus)

            vibeVoiceService.$transcriptionProgress
                .assign(to: &$transcriptionProgress)

        case .python:
            // Python backend doesn't provide real-time status
            break
        }
    }
    
    func startServer() async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [FileManager.default.currentDirectoryPath + "/Python/voxtral_server.py"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        try task.run()
        serverProcess = task
        
        try await Task.sleep(nanoseconds: 5_000_000_000)
        
        checkServerStatus()
    }
    
    func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        isServerRunning = false
    }
    
    func transcribe(
        audioFile: String,
        modelKey: String? = nil,
        variant: WhisperModelVariant? = nil,
        language: String? = nil,
        speakerConfiguration: SpeakerPipelineConfiguration? = nil,
        engineSelection: TranscriptionEngineSelection? = nil,
        runSettings: RunSettings? = nil
    ) async throws -> String {
        logger.info("[TranscriptionService] Starting transcription for: \(audioFile)")
        logger.info("[TranscriptionService] Current backend: \(currentBackend)")

        // Direct/menu-bar calls do not necessarily pass through TranscriptionQueueManager. Keep a
        // final fail-closed admission check here so every backend is protected at the point where
        // it is about to map model weights.
        let resourceProfile = TranscriptionResourceProfile.forSelection(engineSelection)
        if let deferral = SystemMemoryGate.shared.transcriptionDeferral(
            profile: resourceProfile
        ) {
            throw TranscriptionError.resourcesUnavailable(deferral.reason)
        }
        
        switch currentBackend {
        case .whisper:
            // Use Whisper.cpp
            logger.info("[TranscriptionService] Using WhisperService...")
            return try await whisperService.transcribe(
                audioFile: audioFile,
                modelKey: modelKey,
                variant: variant,
                language: language,
                speakerConfiguration: speakerConfiguration
            )
            
        case .native:
            // Use native llama.cpp with Voxtral
            logger.info("[TranscriptionService] Using native VoxtralCppService...")
            return try await voxtralService.transcribe(
                audioFile: audioFile,
                modelKey: engineSelection?.llmModelKey,
                runSettings: runSettings
            )

        case .vibeVoice:
            guard let selection = engineSelection else {
                throw TranscriptionError.transcriptionFailed(
                    "VibeVoice job is missing its engine selection."
                )
            }
            return try await vibeVoiceService.transcribe(
                audioFile: audioFile,
                selection: selection,
                runSettings: runSettings,
                speakerConfiguration: speakerConfiguration
                    ?? SpeakerPipelineSettings.shared.activeConfiguration
            )
            
        case .python:
            // Fall back to Python server
            if !isServerRunning {
                try await startServer()
                guard isServerRunning else {
                    throw TranscriptionError.serverNotRunning
                }
            }
            
            let url = URL(string: "\(serverURL)/transcribe")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            
            let audioData = try Data(contentsOf: URL(fileURLWithPath: audioFile))
            
            let boundary = UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            
            var body = Data()
            
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
            body.append(audioData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            
            request.httpBody = body
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw TranscriptionError.invalidResponse
                }
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let transcript = json["transcript"] as? String {
                    return transcript
                } else {
                    throw TranscriptionError.invalidResponse
                }
            } catch {
                if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                   let errorMessage = String(data: data, encoding: .utf8) {
                    throw TranscriptionError.transcriptionFailed(errorMessage)
                }
                throw error
            }
        }
    }
    
    func switchToWhisper() async throws {
        if !whisperService.isReady {
            // Need to download a Whisper model first
            let defaultVariant = WhisperModelVariant.defaultVariant()
            try await WhisperModelManager.shared.downloadModel(defaultVariant)
        }
        currentBackend = .whisper
        isReady = whisperService.isReady
        setupStatusBinding()
        
        // Stop Python server if running
        stopServer()
    }
    
    func switchToNative() async throws {
        if !voxtralService.isModelLoaded {
            try await voxtralService.downloadModel()
        }
        currentBackend = .native
        isReady = true
        setupStatusBinding()

        // Stop Python server if running
        stopServer()
    }

    func switchToVibeVoice(
        quantization: VibeVoiceQuantization = GlobalModelSettings.shared.selectedVibeVoiceQuantization
    ) async throws {
        currentBackend = .vibeVoice
        isReady = VibeVoiceModelManager.shared.isModelDownloaded(quantization)
            && vibeVoiceService.isRuntimeInstalled
        setupStatusBinding()
        stopServer()
        if !VibeVoiceModelManager.shared.isModelDownloaded(quantization) {
            throw TranscriptionError.modelNotLoaded
        }
        try await vibeVoiceService.validateRuntime()
        isReady = true
    }
    
    func switchToPython() {
        currentBackend = .python
        setupStatusBinding()
        checkServerStatus()
    }
    
    func getAvailableBackends() -> [Backend] {
        var backends: [Backend] = []
        
        if whisperService.isReady {
            backends.append(.whisper)
        }
        
        if voxtralService.isModelLoaded {
            backends.append(.native)
        }

        if vibeVoiceService.isRuntimeInstalled,
           VibeVoiceModelManager.shared.downloadedQuantizations().isEmpty == false {
            backends.append(.vibeVoice)
        }

        // Python is always available as fallback
        backends.append(.python)
        
        return backends
    }
    
    private func checkServerStatus() {
        guard let url = URL(string: "\(serverURL)/health") else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    self?.isServerRunning = true
                } else {
                    self?.isServerRunning = false
                }
            }
        }.resume()
    }
}
