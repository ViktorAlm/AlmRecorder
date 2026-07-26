import Foundation

enum TranscriptionBackend: String, CaseIterable, Codable {
    case whisper = "Whisper"
    case llm = "LLM"
    case vibeVoice = "VibeVoice"
}

/// Which LLM engine powers the "LLM" backend — for both transcription and text generation.
enum LLMEngine: String, CaseIterable, Codable {
    case voxtral = "Voxtral"
    case gemma = "Gemma"
}

class GlobalModelSettings: ObservableObject {
    static let shared = GlobalModelSettings()
    private let settingsRepo = GRDBSettingsRepository.shared
    private var isInitializing = true
    
    // Transcription settings
    @Published var transcriptionBackend: TranscriptionBackend {
        didSet {
            settingsRepo.setString(transcriptionBackend.rawValue, forKey: "transcriptionBackend")
        }
    }
    
    // New variant-based property
    @Published var selectedWhisperVariant: WhisperModelVariant? {
        didSet {
            // Save variant as identifier string
            if let variant = selectedWhisperVariant {
                settingsRepo.setString(variant.toIdentifier(), forKey: "selectedWhisperVariant")
                // Always use full identifier to distinguish between quantizations
                selectedWhisperModel = variant.toIdentifier()
            } else {
                settingsRepo.removeObject(forKey: "selectedWhisperVariant")
            }
        }
    }
    
    // Legacy string-based property (kept for backward compatibility)
    @Published var selectedWhisperModel: String {
        didSet {
            settingsRepo.setString(selectedWhisperModel, forKey: "selectedWhisperModel")
            // Try to update variant if it's different (skip during init to avoid circular dependency)
            if !isInitializing {
                if let variant = WhisperModelManager.shared.getVariant(for: selectedWhisperModel),
                   selectedWhisperVariant != variant {
                    selectedWhisperVariant = variant
                }
            }
        }
    }
    
    @Published var selectedVoxtralTranscriptionModel: String {
        didSet {
            settingsRepo.setString(selectedVoxtralTranscriptionModel, forKey: "selectedVoxtralTranscriptionModel")
        }
    }

    @Published var selectedVibeVoiceQuantization: VibeVoiceQuantization {
        didSet {
            settingsRepo.setString(
                selectedVibeVoiceQuantization.rawValue,
                forKey: "selectedVibeVoiceQuantization"
            )
        }
    }

    @Published var vibeVoiceSpeakerMode: VibeVoiceSpeakerMode {
        didSet {
            settingsRepo.setString(vibeVoiceSpeakerMode.rawValue, forKey: "vibeVoiceSpeakerMode")
        }
    }

    /// Optional names, terms, or meeting context supplied to VibeVoice as hotword metadata.
    @Published var vibeVoiceContext: String {
        didSet {
            settingsRepo.setString(vibeVoiceContext, forKey: "vibeVoiceContext")
        }
    }

    /// Which engine the LLM backend uses (Voxtral or Gemma).
    @Published var selectedLLMEngine: LLMEngine {
        didSet {
            settingsRepo.setString(selectedLLMEngine.rawValue, forKey: "selectedLLMEngine")
        }
    }

    /// Selected Gemma model key for transcription (e.g. "12B-Q5_K_M").
    @Published var selectedGemmaTranscriptionModel: String {
        didSet {
            settingsRepo.setString(selectedGemmaTranscriptionModel, forKey: "selectedGemmaTranscriptionModel")
        }
    }

    /// Gemma model key used for text generation (summaries / topics / tags).
    @Published var selectedTextLLMModel: String {
        didSet {
            settingsRepo.setString(selectedTextLLMModel, forKey: "selectedTextLLMModel")
        }
    }
    
    // Summary model settings
    @Published var selectedSummaryModel: String {
        didSet {
            settingsRepo.setString(selectedSummaryModel, forKey: "selectedSummaryModel")
        }
    }
    
    @Published var autoGenerateSummaries: Bool {
        didSet {
            settingsRepo.setBool(autoGenerateSummaries, forKey: "autoGenerateSummaries")
        }
    }

    /// Transcript cleanup: score utterances for hallucinations and verify suspicious lines
    /// against the audio with Gemma after each transcription (plus library backfill).
    @Published var autoCleanTranscripts: Bool {
        didSet {
            settingsRepo.setBool(autoCleanTranscripts, forKey: "autoCleanTranscripts")
        }
    }

    /// Exemplar-sweep sensitivity: 0 strict / 1 balanced / 2 eager (Review page master slider).
    /// Moving it applies the preset to the four individual thresholds below; the Advanced
    /// sliders can then override any of them individually ("Custom").
    @Published var sweepSensitivity: Double {
        didSet {
            settingsRepo.setString(String(sweepSensitivity), forKey: "sweepSensitivity")
        }
    }

    /// Individual sweep thresholds (Advanced sliders). These are what the sweep actually uses.
    @Published var sweepCosineFloor: Double {
        didSet { settingsRepo.setString(String(sweepCosineFloor), forKey: "sweepCosineFloor") }
    }
    @Published var sweepOverlapFloor: Double {
        didSet { settingsRepo.setString(String(sweepOverlapFloor), forKey: "sweepOverlapFloor") }
    }
    @Published var sweepCoverageFloor: Double {
        didSet { settingsRepo.setString(String(sweepCoverageFloor), forKey: "sweepCoverageFloor") }
    }
    @Published var sweepSparseCPS: Double {
        didSet { settingsRepo.setString(String(sweepSparseCPS), forKey: "sweepSparseCPS") }
    }

    /// The tuning the sweep runs with — always the four individual values.
    var sweepTuning: ExemplarSweepStore.Tuning {
        ExemplarSweepStore.Tuning(cosineFloor: sweepCosineFloor,
                                  overlapFloor: sweepOverlapFloor,
                                  coverageFloor: sweepCoverageFloor,
                                  sparseCharsPerSecond: sweepSparseCPS)
    }

    /// Apply a master-slider preset to the individual thresholds.
    func applySweepPreset(_ sensitivity: Double) {
        let preset = ExemplarSweepStore.Tuning.forSensitivity(sensitivity)
        sweepCosineFloor = preset.cosineFloor
        sweepOverlapFloor = preset.overlapFloor
        sweepCoverageFloor = preset.coverageFloor
        sweepSparseCPS = preset.sparseCharsPerSecond
    }
    
    // Embedding model settings
    @Published var selectedEmbeddingModel: String {
        didSet {
            settingsRepo.setString(selectedEmbeddingModel, forKey: "selectedEmbeddingModel")
        }
    }
    
    @Published var autoGenerateEmbeddings: Bool {
        didSet {
            settingsRepo.setBool(autoGenerateEmbeddings, forKey: "autoGenerateEmbeddings")
        }
    }
    
    private init() {
        // Initialize with defaults first
        self.transcriptionBackend = TranscriptionProductionDefaults.backend
        self.selectedWhisperVariant = nil
        self.selectedWhisperModel = ""
        self.selectedVoxtralTranscriptionModel = "Q4_K_M"
        self.selectedVibeVoiceQuantization =
            TranscriptionProductionDefaults.vibeVoiceQuantization
        self.vibeVoiceSpeakerMode = TranscriptionProductionDefaults.vibeVoiceSpeakerMode
        self.vibeVoiceContext = ""
        self.selectedLLMEngine = .voxtral
        self.selectedGemmaTranscriptionModel = GemmaConfiguration.defaultModel
        self.selectedTextLLMModel = GemmaConfiguration.defaultModel
        self.selectedSummaryModel = "Q4_K_M"
        self.selectedEmbeddingModel = "qwen3-embedding-0.6b-q4_k_m"
        self.autoGenerateSummaries = false
        self.autoGenerateEmbeddings = false
        self.autoCleanTranscripts = false
        self.sweepSensitivity = 1
        self.sweepCosineFloor = ExemplarSweepStore.Tuning.balanced.cosineFloor
        self.sweepOverlapFloor = ExemplarSweepStore.Tuning.balanced.overlapFloor
        self.sweepCoverageFloor = ExemplarSweepStore.Tuning.balanced.coverageFloor
        self.sweepSparseCPS = ExemplarSweepStore.Tuning.balanced.sparseCharsPerSecond

        // Migrate from UserDefaults if needed (one-time migration)
        migrateFromUserDefaultsIfNeeded()
        
        // Load saved preferences from GRDB
        let storedBackendRaw = settingsRepo.getString(forKey: "transcriptionBackend")
        if let backendRaw = storedBackendRaw {
            if let backend = TranscriptionBackend(rawValue: backendRaw) {
                self.transcriptionBackend = backend
            } else if backendRaw == "Voxtral" {
                // Migrate the legacy "Voxtral" backend into the new LLM series (engine = Voxtral).
                self.transcriptionBackend = .llm
                settingsRepo.setString(TranscriptionBackend.llm.rawValue, forKey: "transcriptionBackend")
            } else {
                self.transcriptionBackend = TranscriptionProductionDefaults.backend
            }
        } else {
            self.transcriptionBackend = TranscriptionProductionDefaults.backend
        }
        
        // Try to load variant first (new system)
        if let variantId = settingsRepo.getString(forKey: "selectedWhisperVariant"),
           let variant = WhisperModelVariant.fromIdentifier(variantId) {
            self.selectedWhisperVariant = variant
            self.selectedWhisperModel = variant.toLegacyKey() ?? variantId
        } else {
            // Fall back to legacy model string
            let legacyModel = settingsRepo.getString(forKey: "selectedWhisperModel") ?? ""
            self.selectedWhisperModel = legacyModel
            
            // Skip variant lookup during init to avoid circular dependency
            // WhisperModelManager will sync this later
            self.selectedWhisperVariant = nil
        }
        
        self.selectedVoxtralTranscriptionModel = settingsRepo.getString(forKey: "selectedVoxtralTranscriptionModel") ?? "Q4_K_M"
        self.selectedVibeVoiceQuantization = settingsRepo
            .getString(forKey: "selectedVibeVoiceQuantization")
            .flatMap(VibeVoiceQuantization.init(rawValue:))
            ?? TranscriptionProductionDefaults.vibeVoiceQuantization
        self.vibeVoiceSpeakerMode = settingsRepo
            .getString(forKey: "vibeVoiceSpeakerMode")
            .flatMap(VibeVoiceSpeakerMode.init(rawValue:))
            ?? TranscriptionProductionDefaults.vibeVoiceSpeakerMode
        self.vibeVoiceContext = settingsRepo.getString(forKey: "vibeVoiceContext") ?? ""

        // Roll the benchmark winner into production once. Existing users are switched only when
        // its model is already installed; first-run setup downloads it below.
        if settingsRepo.getBool(forKey: TranscriptionProductionDefaults.rolloutKey) != true {
            let shouldAdopt = TranscriptionProductionDefaults.shouldAdopt(
                hasStoredBackend: storedBackendRaw != nil,
                hasFourBitModel: VibeVoiceModelManager.shared.isModelDownloaded(.fourBit)
            )
            if shouldAdopt {
                self.transcriptionBackend = TranscriptionProductionDefaults.backend
                self.selectedVibeVoiceQuantization =
                    TranscriptionProductionDefaults.vibeVoiceQuantization
                self.vibeVoiceSpeakerMode =
                    TranscriptionProductionDefaults.vibeVoiceSpeakerMode
            }
            settingsRepo.setBool(true, forKey: TranscriptionProductionDefaults.rolloutKey)
        }
        if let engineRaw = settingsRepo.getString(forKey: "selectedLLMEngine"),
           let engine = LLMEngine(rawValue: engineRaw) {
            self.selectedLLMEngine = engine
        }
        self.selectedGemmaTranscriptionModel = settingsRepo.getString(forKey: "selectedGemmaTranscriptionModel") ?? GemmaConfiguration.defaultModel
        self.selectedTextLLMModel = settingsRepo.getString(forKey: "selectedTextLLMModel") ?? GemmaConfiguration.defaultModel
        self.selectedSummaryModel = settingsRepo.getString(forKey: "selectedSummaryModel") ?? "Q4_K_M"
        self.selectedEmbeddingModel = settingsRepo.getString(forKey: "selectedEmbeddingModel") ?? "qwen3-embedding-0.6b-q4_k_m"
        
        self.autoGenerateSummaries = settingsRepo.getBool(forKey: "autoGenerateSummaries") ?? false
        self.autoGenerateEmbeddings = settingsRepo.getBool(forKey: "autoGenerateEmbeddings") ?? false
        // Off by default: each verification span is a full Gemma model load — opt-in only.
        self.autoCleanTranscripts = settingsRepo.getBool(forKey: "autoCleanTranscripts") ?? false
        self.sweepSensitivity = Double(settingsRepo.getString(forKey: "sweepSensitivity") ?? "") ?? 1
        let storedPreset = ExemplarSweepStore.Tuning.forSensitivity(self.sweepSensitivity)
        self.sweepCosineFloor = Double(settingsRepo.getString(forKey: "sweepCosineFloor") ?? "") ?? storedPreset.cosineFloor
        self.sweepOverlapFloor = Double(settingsRepo.getString(forKey: "sweepOverlapFloor") ?? "") ?? storedPreset.overlapFloor
        self.sweepCoverageFloor = Double(settingsRepo.getString(forKey: "sweepCoverageFloor") ?? "") ?? storedPreset.coverageFloor
        self.sweepSparseCPS = Double(settingsRepo.getString(forKey: "sweepSparseCPS") ?? "") ?? storedPreset.sparseCharsPerSecond
        
        // Set Large v3 as default if nothing selected yet
        if selectedWhisperVariant == nil {
            // Default to Large v3 (high quality)
            selectedWhisperVariant = WhisperModelVariant(
                family: .openai,
                size: .large,
                version: .v3,
                quantization: .q5_0
            )
            if let variant = selectedWhisperVariant {
                selectedWhisperModel = variant.toIdentifier()
            }
        }
        
        // Default to enabling auto-generation
        if settingsRepo.getBool(forKey: "hasSetAutoGenerate") != true {
            autoGenerateSummaries = true
            autoGenerateEmbeddings = true
            settingsRepo.setBool(true, forKey: "hasSetAutoGenerate")
        }
        
        // Mark initialization as complete
        isInitializing = false
        
        // Now sync with WhisperModelManager if needed
        if selectedWhisperVariant == nil && !selectedWhisperModel.isEmpty {
            Task { @MainActor in
                if let variant = WhisperModelManager.shared.getVariant(for: selectedWhisperModel) {
                    self.selectedWhisperVariant = variant
                }
            }
        }
    }
    
    var currentTranscriptionModel: String {
        switch transcriptionBackend {
        case .whisper:
            return selectedWhisperModel
        case .llm:
            switch selectedLLMEngine {
            case .voxtral: return selectedVoxtralTranscriptionModel
            case .gemma: return selectedGemmaTranscriptionModel
            }
        case .vibeVoice:
            return selectedVibeVoiceQuantization.repositoryID
        }
    }
    
    /// Get the current transcription variant (if using Whisper)
    var currentTranscriptionVariant: WhisperModelVariant? {
        guard transcriptionBackend == .whisper else { return nil }
        return selectedWhisperVariant
    }
    
    /// Set variant and update legacy model string
    func selectWhisperVariant(_ variant: WhisperModelVariant) {
        print("[GlobalModelSettings] Selecting whisper variant: \(variant.displayName)")
        selectedWhisperVariant = variant
        // Always use full identifier to distinguish between quantizations
        selectedWhisperModel = variant.toIdentifier()
        print("[GlobalModelSettings] Updated selectedWhisperModel to: \(selectedWhisperModel)")
        print("[GlobalModelSettings] Current variant: \(selectedWhisperVariant?.displayName ?? "nil")")
        
        // Update WhisperModelManager
        WhisperModelManager.shared.currentVariant = variant
    }
    
    /// Migrate from legacy model string to variant
    func migrateToVariantSystem() {
        if selectedWhisperVariant == nil && !selectedWhisperModel.isEmpty {
            if let variant = WhisperModelManager.shared.getVariant(for: selectedWhisperModel) {
                selectedWhisperVariant = variant
                print("[GlobalModelSettings] Migrated model '\(selectedWhisperModel)' to variant: \(variant.displayName)")
            }
        }
    }
    
    /// One-time migration from UserDefaults to GRDB
    private func migrateFromUserDefaultsIfNeeded() {
        // Check if migration has already been done
        if settingsRepo.getBool(forKey: "globalModelSettings.migrated") == true {
            return
        }
        
        print("[GlobalModelSettings] Migrating from UserDefaults to GRDB...")
        
        // Migrate all settings
        if let backendRaw = UserDefaults.standard.string(forKey: "transcriptionBackend") {
            settingsRepo.setString(backendRaw, forKey: "transcriptionBackend")
        }
        
        if let variantId = UserDefaults.standard.string(forKey: "selectedWhisperVariant") {
            settingsRepo.setString(variantId, forKey: "selectedWhisperVariant")
        }
        
        if let model = UserDefaults.standard.string(forKey: "selectedWhisperModel") {
            settingsRepo.setString(model, forKey: "selectedWhisperModel")
        }
        
        if let model = UserDefaults.standard.string(forKey: "selectedVoxtralTranscriptionModel") {
            settingsRepo.setString(model, forKey: "selectedVoxtralTranscriptionModel")
        }
        
        if let model = UserDefaults.standard.string(forKey: "selectedSummaryModel") {
            settingsRepo.setString(model, forKey: "selectedSummaryModel")
        }
        
        if let model = UserDefaults.standard.string(forKey: "selectedEmbeddingModel") {
            settingsRepo.setString(model, forKey: "selectedEmbeddingModel")
        }
        
        // Migrate booleans (they always have a value from UserDefaults)
        settingsRepo.setBool(UserDefaults.standard.bool(forKey: "autoGenerateSummaries"), forKey: "autoGenerateSummaries")
        settingsRepo.setBool(UserDefaults.standard.bool(forKey: "autoGenerateEmbeddings"), forKey: "autoGenerateEmbeddings")
        settingsRepo.setBool(UserDefaults.standard.bool(forKey: "hasSetAutoGenerate"), forKey: "hasSetAutoGenerate")
        
        // Mark migration as complete
        settingsRepo.setBool(true, forKey: "globalModelSettings.migrated")
        
        print("[GlobalModelSettings] Migration complete")
    }
}
