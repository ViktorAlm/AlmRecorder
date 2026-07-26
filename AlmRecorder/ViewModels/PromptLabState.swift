import Foundation
import SwiftUI

/// Persistent state for the Prompt Lab view
class PromptLabState: ObservableObject {
    
    // MARK: - Singleton
    static let shared = PromptLabState()
    
    // MARK: - Published Properties
    @Published var selectedConfig: PromptTestConfig?
    @Published var comparisonMode = false
    @Published var baselineResult: PromptTestResult?
    @Published var maxChunks: Int = 3
    @Published var selectedModel: String = VoxtralConfiguration.defaultModel
    @Published var testJobIds: Set<UUID> = []
    @Published var isRunningTest = false
    @Published var showingFilePicker = false
    @Published var showingExportMenu = false
    
    // MARK: - Run Settings
    @Published var temperature: Double = 0.0
    @Published var topK: Int = 1
    @Published var topP: Double? = nil
    @Published var useTopP: Bool = false
    @Published var maxTokens: Int = 15000
    @Published var contextKeep: Int = 512
    @Published var seed: Int? = nil
    @Published var useSeed: Bool = false
    @Published var showAdvancedSettings: Bool = false
    
    // MARK: - Reference to tester
    let tester = VoxtralPromptTester.shared
    
    private init() {
        // Private init for singleton
    }
    
    // MARK: - Methods
    
    /// Clear all test job IDs
    func clearTestJobIds() {
        testJobIds.removeAll()
    }
    
    /// Add a test job ID
    func addTestJobId(_ id: UUID) {
        testJobIds.insert(id)
    }
    
    /// Remove a test job ID
    func removeTestJobId(_ id: UUID) {
        testJobIds.remove(id)
    }
    
    /// Reset state (but keep audio file and model selection)
    func resetResults() {
        tester.results.removeAll()
        baselineResult = nil
        testJobIds.removeAll()
        selectedConfig = nil
    }
    
    /// Check if a config has a result
    func hasResult(for configId: String) -> Bool {
        return tester.results.contains { $0.configId == configId }
    }
    
    /// Get result for a config
    func getResult(for configId: String) -> PromptTestResult? {
        return tester.results.first { $0.configId == configId }
    }
    
    /// Create RunSettings from current state
    func createRunSettings(prompt: String? = nil) -> RunSettings {
        return RunSettings(
            temperature: temperature,
            topK: topK,
            topP: useTopP ? topP : nil,
            maxTokens: maxTokens,
            contextKeep: contextKeep,
            gpuLayers: -1,  // Always use all GPU layers
            seed: useSeed ? seed : nil,
            prompt: prompt ?? RunSettings.defaultSettings.prompt
        )
    }
}