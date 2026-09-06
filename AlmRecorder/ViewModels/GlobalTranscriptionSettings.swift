import Foundation
import SwiftUI

/// Global transcription settings shared across the app
class GlobalTranscriptionSettings: ObservableObject {
    
    // MARK: - Singleton
    static let shared = GlobalTranscriptionSettings()
    private let settingsRepo = GRDBSettingsRepository.shared
    
    // MARK: - Published Properties
    @Published var temperature: Double = 0.0 {
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var topK: Int = 1 {
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var topP: Double? = nil {
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var useTopP: Bool = false {
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var maxTokens: Int = 15000 {
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var contextKeep: Int = 512 {
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var gpuLayers: Int = -1 {  // -1 means use all
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var seed: Int? = nil {
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var useSeed: Bool = false {
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var useCustomSettings: Bool = false {
        didSet { 
            if isInitialized { saveSettings() }
        }
    }
    
    @Published var selectedPreset: SettingsPreset = .balanced {
        didSet {
            if isInitialized {
                if selectedPreset != .custom {
                    applyPreset(selectedPreset)
                }
                saveSettings()
            }
        }
    }
    
    private var isInitialized = false
    
    // MARK: - Settings Presets
    enum SettingsPreset: String, CaseIterable {
        case fast = "Fast"
        case balanced = "Balanced"
        case highQuality = "High Quality"
        case deterministic = "Deterministic"
        case creative = "Creative"
        case custom = "Custom"
        
        var description: String {
            switch self {
            case .fast:
                return "Optimized for speed with reasonable accuracy"
            case .balanced:
                return "Good balance between speed and quality"
            case .highQuality:
                return "Maximum accuracy, slower processing"
            case .deterministic:
                return "Reproducible results (temperature=0)"
            case .creative:
                return "More varied outputs (higher temperature)"
            case .custom:
                return "Custom user settings"
            }
        }
        
        var settings: (temperature: Double, topK: Int, topP: Double?, maxTokens: Int) {
            switch self {
            case .fast:
                return (0.2, 5, nil, 10000)
            case .balanced:
                return (0.1, 3, nil, 15000)
            case .highQuality:
                return (0.0, 1, nil, 20000)
            case .deterministic:
                return (0.0, 1, nil, 15000)
            case .creative:
                return (0.7, 40, 0.9, 15000)
            case .custom:
                return (0.0, 1, nil, 15000)  // Default values
            }
        }
    }
    
    // MARK: - UserDefaults Keys
    private enum UserDefaultsKeys {
        static let temperature = "transcription.temperature"
        static let topK = "transcription.topK"
        static let topP = "transcription.topP"
        static let useTopP = "transcription.useTopP"
        static let maxTokens = "transcription.maxTokens"
        static let contextKeep = "transcription.contextKeep"
        static let gpuLayers = "transcription.gpuLayers"
        static let seed = "transcription.seed"
        static let useSeed = "transcription.useSeed"
        static let useCustomSettings = "transcription.useCustomSettings"
        static let selectedPreset = "transcription.selectedPreset"
    }
    
    // MARK: - Init
    private init() {
        // Migrate from UserDefaults if needed
        migrateFromUserDefaultsIfNeeded()
        // Load settings synchronously to ensure proper initialization
        loadSettings()
        isInitialized = true
    }
    
    // MARK: - Methods
    
    /// Create RunSettings from current global settings
    func createRunSettings(customPrompt: String? = nil) -> RunSettings {
        // If not using custom settings, return default
        guard useCustomSettings else {
            if let customPrompt = customPrompt {
                let settings = RunSettings.defaultSettings
                return RunSettings(
                    temperature: settings.temperature,
                    topK: settings.topK,
                    topP: settings.topP,
                    maxTokens: settings.maxTokens,
                    contextKeep: settings.contextKeep,
                    gpuLayers: settings.gpuLayers,
                    seed: settings.seed,
                    prompt: customPrompt
                )
            }
            return RunSettings.defaultSettings
        }
        
        return RunSettings(
            temperature: temperature,
            topK: topK,
            topP: useTopP ? topP : nil,
            maxTokens: maxTokens,
            contextKeep: contextKeep,
            gpuLayers: gpuLayers,
            seed: useSeed ? seed : nil,
            prompt: customPrompt ?? RunSettings.defaultSettings.prompt
        )
    }
    
    /// Apply a preset
    func applyPreset(_ preset: SettingsPreset) {
        let settings = preset.settings
        temperature = settings.temperature
        topK = settings.topK
        topP = settings.topP
        useTopP = settings.topP != nil
        maxTokens = settings.maxTokens
        
        // Keep other settings unchanged
        if preset != .custom {
            selectedPreset = preset
        }
    }
    
    /// Reset to defaults
    func resetToDefaults() {
        temperature = 0.0
        topK = 1
        topP = nil
        useTopP = false
        maxTokens = 15000
        contextKeep = 512
        gpuLayers = -1
        seed = nil
        useSeed = false
        useCustomSettings = false
        selectedPreset = .balanced
    }
    
    // MARK: - Persistence
    
    private func saveSettings() {
        guard isInitialized else { return }
        
        settingsRepo.setDouble(temperature, forKey: UserDefaultsKeys.temperature)
        settingsRepo.setInt(topK, forKey: UserDefaultsKeys.topK)
        if let topP = topP {
            settingsRepo.setDouble(topP, forKey: UserDefaultsKeys.topP)
        } else {
            settingsRepo.removeObject(forKey: UserDefaultsKeys.topP)
        }
        settingsRepo.setBool(useTopP, forKey: UserDefaultsKeys.useTopP)
        settingsRepo.setInt(maxTokens, forKey: UserDefaultsKeys.maxTokens)
        settingsRepo.setInt(contextKeep, forKey: UserDefaultsKeys.contextKeep)
        settingsRepo.setInt(gpuLayers, forKey: UserDefaultsKeys.gpuLayers)
        if let seed = seed {
            settingsRepo.setInt(seed, forKey: UserDefaultsKeys.seed)
        } else {
            settingsRepo.removeObject(forKey: UserDefaultsKeys.seed)
        }
        settingsRepo.setBool(useSeed, forKey: UserDefaultsKeys.useSeed)
        settingsRepo.setBool(useCustomSettings, forKey: UserDefaultsKeys.useCustomSettings)
        settingsRepo.setString(selectedPreset.rawValue, forKey: UserDefaultsKeys.selectedPreset)
    }
    
    private func loadSettings() {
        // Load saved values from GRDB or use defaults
        temperature = settingsRepo.getDouble(forKey: UserDefaultsKeys.temperature) ?? 0.0
        topK = settingsRepo.getInt(forKey: UserDefaultsKeys.topK) ?? 1
        topP = settingsRepo.getDouble(forKey: UserDefaultsKeys.topP)
        useTopP = settingsRepo.getBool(forKey: UserDefaultsKeys.useTopP) ?? false
        maxTokens = settingsRepo.getInt(forKey: UserDefaultsKeys.maxTokens) ?? 15000
        contextKeep = settingsRepo.getInt(forKey: UserDefaultsKeys.contextKeep) ?? 512
        gpuLayers = settingsRepo.getInt(forKey: UserDefaultsKeys.gpuLayers) ?? -1
        seed = settingsRepo.getInt(forKey: UserDefaultsKeys.seed)
        useSeed = settingsRepo.getBool(forKey: UserDefaultsKeys.useSeed) ?? false
        useCustomSettings = settingsRepo.getBool(forKey: UserDefaultsKeys.useCustomSettings) ?? false
        
        if let presetRaw = settingsRepo.getString(forKey: UserDefaultsKeys.selectedPreset),
           let preset = SettingsPreset(rawValue: presetRaw) {
            selectedPreset = preset
        } else {
            selectedPreset = .balanced
        }
    }
    
    // MARK: - Migration
    
    private func migrateFromUserDefaultsIfNeeded() {
        // Check if migration has been done
        if settingsRepo.getBool(forKey: "transcriptionSettings.migrated") == true {
            return
        }
        
        let defaults = UserDefaults.standard
        
        // Migrate all settings
        if let temp = defaults.object(forKey: UserDefaultsKeys.temperature) as? Double {
            settingsRepo.setDouble(temp, forKey: UserDefaultsKeys.temperature)
        }
        if let k = defaults.object(forKey: UserDefaultsKeys.topK) as? Int {
            settingsRepo.setInt(k, forKey: UserDefaultsKeys.topK)
        }
        if let p = defaults.object(forKey: UserDefaultsKeys.topP) as? Double {
            settingsRepo.setDouble(p, forKey: UserDefaultsKeys.topP)
        }
        settingsRepo.setBool(defaults.bool(forKey: UserDefaultsKeys.useTopP), forKey: UserDefaultsKeys.useTopP)
        if let tokens = defaults.object(forKey: UserDefaultsKeys.maxTokens) as? Int {
            settingsRepo.setInt(tokens, forKey: UserDefaultsKeys.maxTokens)
        }
        if let keep = defaults.object(forKey: UserDefaultsKeys.contextKeep) as? Int {
            settingsRepo.setInt(keep, forKey: UserDefaultsKeys.contextKeep)
        }
        if let gpu = defaults.object(forKey: UserDefaultsKeys.gpuLayers) as? Int {
            settingsRepo.setInt(gpu, forKey: UserDefaultsKeys.gpuLayers)
        }
        if let s = defaults.object(forKey: UserDefaultsKeys.seed) as? Int {
            settingsRepo.setInt(s, forKey: UserDefaultsKeys.seed)
        }
        settingsRepo.setBool(defaults.bool(forKey: UserDefaultsKeys.useSeed), forKey: UserDefaultsKeys.useSeed)
        settingsRepo.setBool(defaults.bool(forKey: UserDefaultsKeys.useCustomSettings), forKey: UserDefaultsKeys.useCustomSettings)
        if let preset = defaults.string(forKey: UserDefaultsKeys.selectedPreset) {
            settingsRepo.setString(preset, forKey: UserDefaultsKeys.selectedPreset)
        }
        
        // Mark migration complete
        settingsRepo.setBool(true, forKey: "transcriptionSettings.migrated")
        
        // Clean up UserDefaults
        defaults.removeObject(forKey: UserDefaultsKeys.temperature)
        defaults.removeObject(forKey: UserDefaultsKeys.topK)
        defaults.removeObject(forKey: UserDefaultsKeys.topP)
        defaults.removeObject(forKey: UserDefaultsKeys.useTopP)
        defaults.removeObject(forKey: UserDefaultsKeys.maxTokens)
        defaults.removeObject(forKey: UserDefaultsKeys.contextKeep)
        defaults.removeObject(forKey: UserDefaultsKeys.gpuLayers)
        defaults.removeObject(forKey: UserDefaultsKeys.seed)
        defaults.removeObject(forKey: UserDefaultsKeys.useSeed)
        defaults.removeObject(forKey: UserDefaultsKeys.useCustomSettings)
        defaults.removeObject(forKey: UserDefaultsKeys.selectedPreset)
    }
}
