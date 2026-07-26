import Foundation
import Combine

/// Configuration for debug features and logging
class DebugConfiguration: ObservableObject {
    static let shared = DebugConfiguration()
    
    // MARK: - Published Properties
    
    @Published var isDebugMode: Bool = false
    @Published var logLevel: LogLevel = .info
    @Published var enableConsoleLogging: Bool = true
    @Published var enableFileLogging: Bool = true
    @Published var enablePerformanceMonitoring: Bool = false
    @Published var enableSlowQueryWarnings: Bool = true
    @Published var slowQueryThreshold: TimeInterval = 0.1
    @Published var enableEmbeddingDebug: Bool = false
    @Published var enableDatabaseDebug: Bool = false
    @Published var enableNetworkDebug: Bool = false
    
    // Component-specific debug flags
    @Published var componentDebugFlags: [String: Bool] = [:]
    
    // MARK: - Private Properties
    
    private let logger = VoxtralLogger.shared
    private let performanceMonitor = PerformanceMonitor.shared
    private var cancellables = Set<AnyCancellable>()
    
    // User defaults keys
    private let userDefaults = UserDefaults.standard
    private let debugModeKey = "com.almrecorder.debug.enabled"
    private let logLevelKey = "com.almrecorder.debug.logLevel"
    private let performanceMonitoringKey = "com.almrecorder.debug.performanceMonitoring"
    
    // MARK: - Initialization
    
    private init() {
        // Load saved configuration
        loadConfiguration()
        
        // Set initial debug state based on build configuration
        #if DEBUG
        isDebugMode = true
        logLevel = .debug
        enablePerformanceMonitoring = true
        enableSlowQueryWarnings = true
        #else
        // Production defaults
        logLevel = .warning
        enableConsoleLogging = false
        #endif
        
        // Setup bindings
        setupBindings()
        
        logger.info("[DebugConfiguration] Initialized | debugMode=\(isDebugMode) logLevel=\(logLevel)")
    }
    
    // MARK: - Setup
    
    private func setupBindings() {
        // Update logger when settings change
        $logLevel
            .sink { [weak self] level in
                self?.logger.logLevel = level
                self?.logger.debug("[DebugConfiguration] Log level changed to \(level)")
            }
            .store(in: &cancellables)
        
        $enableConsoleLogging
            .sink { [weak self] enabled in
                self?.logger.enableConsoleOutput = enabled
                self?.logger.debug("[DebugConfiguration] Console logging \(enabled ? "enabled" : "disabled")")
            }
            .store(in: &cancellables)
        
        $enableFileLogging
            .sink { [weak self] enabled in
                self?.logger.enableFileLogging = enabled
                self?.logger.debug("[DebugConfiguration] File logging \(enabled ? "enabled" : "disabled")")
            }
            .store(in: &cancellables)
        
        // Start/stop performance monitoring based on setting
        $enablePerformanceMonitoring
            .sink { [weak self] enabled in
                if enabled {
                    self?.performanceMonitor.startMonitoring()
                } else {
                    self?.performanceMonitor.stopMonitoring()
                }
                self?.logger.debug("[DebugConfiguration] Performance monitoring \(enabled ? "enabled" : "disabled")")
            }
            .store(in: &cancellables)
        
        // Auto-save configuration changes
        Publishers.CombineLatest3($isDebugMode, $logLevel, $enablePerformanceMonitoring)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveConfiguration()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    /// Enable debug mode with specific components
    func enableDebugMode(components: [String] = []) {
        isDebugMode = true
        logLevel = .debug
        enableConsoleLogging = true
        enableFileLogging = true
        
        // Enable specific component debugging
        for component in components {
            componentDebugFlags[component] = true
        }
        
        logger.info("[DebugConfiguration] Debug mode enabled | components=\(components.isEmpty ? "all" : components.joined(separator: ", "))")
    }
    
    /// Disable debug mode
    func disableDebugMode() {
        isDebugMode = false
        logLevel = .warning
        enableConsoleLogging = false
        enablePerformanceMonitoring = false
        componentDebugFlags.removeAll()
        
        logger.info("[DebugConfiguration] Debug mode disabled")
    }
    
    /// Check if debugging is enabled for a specific component
    func isDebuggingEnabled(for component: String) -> Bool {
        return isDebugMode && (componentDebugFlags[component] ?? false)
    }
    
    /// Enable debugging for a specific component
    func enableComponentDebugging(_ component: String) {
        componentDebugFlags[component] = true
        logger.debug("[DebugConfiguration] Enabled debugging for component: \(component)")
    }
    
    /// Disable debugging for a specific component
    func disableComponentDebugging(_ component: String) {
        componentDebugFlags[component] = false
        logger.debug("[DebugConfiguration] Disabled debugging for component: \(component)")
    }
    
    /// Generate debug report
    func generateDebugReport() -> String {
        var report = "=== Debug Configuration Report ===\n"
        report += "Generated: \(Date())\n\n"
        
        report += "Configuration:\n"
        report += "  Debug Mode: \(isDebugMode)\n"
        report += "  Log Level: \(logLevel)\n"
        report += "  Console Logging: \(enableConsoleLogging)\n"
        report += "  File Logging: \(enableFileLogging)\n"
        report += "  Performance Monitoring: \(enablePerformanceMonitoring)\n"
        report += "  Slow Query Warnings: \(enableSlowQueryWarnings)\n"
        report += "  Slow Query Threshold: \(slowQueryThreshold)s\n\n"
        
        report += "Component Debug Flags:\n"
        if componentDebugFlags.isEmpty {
            report += "  None\n"
        } else {
            for (component, enabled) in componentDebugFlags {
                report += "  \(component): \(enabled)\n"
            }
        }
        report += "\n"
        
        // Add performance metrics if available
        if enablePerformanceMonitoring {
            let metrics = performanceMonitor.currentMetrics
            report += "Performance Metrics:\n"
            report += "  Memory Usage: \(String(format: "%.1f", metrics.memoryUsageMB))MB\n"
            report += "  CPU Usage: \(String(format: "%.1f", metrics.cpuUsagePercent))%\n"
            report += "  Active Components: \(metrics.activeComponentCount)\n"
            report += "  Total Operations: \(metrics.totalOperations)\n"
            report += "  Avg Operation Time: \(String(format: "%.3f", metrics.averageOperationTime))s\n\n"
        }
        
        // Add database statistics
        let dbStats = GRDBDatabaseManager.shared.getDatabaseStatistics()
        report += "Database Statistics:\n"
        report += "  Total Queries: \(dbStats.totalQueries)\n"
        report += "  Avg Query Time: \(String(format: "%.4f", dbStats.averageQueryTime))s\n"
        for (table, count) in dbStats.tableCounts {
            report += "  Table '\(table)': \(count) rows\n"
        }
        if let fileSize = dbStats.fileSizeBytes {
            let sizeMB = Double(fileSize) / (1024 * 1024)
            report += "  Database Size: \(String(format: "%.2f", sizeMB))MB\n"
        }
        report += "\n"
        
        // Add recent log entries
        report += "Recent Log Entries:\n"
        let recentLogs = logger.getRecentLogs(lines: 20)
        for log in recentLogs.prefix(20) {
            report += "  \(log)\n"
        }
        
        report += "\n=== End Report ===\n"
        
        return report
    }
    
    /// Export debug report to file
    func exportDebugReport() -> URL? {
        let report = generateDebugReport()
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        let fileName = "debug_report_\(timestamp).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try report.write(to: tempURL, atomically: true, encoding: .utf8)
            logger.info("[DebugConfiguration] Debug report exported to: \(tempURL.path)")
            return tempURL
        } catch {
            logger.error("[DebugConfiguration] Failed to export debug report: \(error)")
            return nil
        }
    }
    
    // MARK: - Persistence
    
    private func saveConfiguration() {
        userDefaults.set(isDebugMode, forKey: debugModeKey)
        userDefaults.set(logLevel.rawValue, forKey: logLevelKey)
        userDefaults.set(enablePerformanceMonitoring, forKey: performanceMonitoringKey)
        
        // Save component flags as dictionary
        if !componentDebugFlags.isEmpty {
            userDefaults.set(componentDebugFlags, forKey: "com.almrecorder.debug.componentFlags")
        }
        
        logger.debug("[DebugConfiguration] Configuration saved")
    }
    
    private func loadConfiguration() {
        if userDefaults.object(forKey: debugModeKey) != nil {
            isDebugMode = userDefaults.bool(forKey: debugModeKey)
        }
        
        if userDefaults.object(forKey: logLevelKey) != nil {
            let rawValue = userDefaults.integer(forKey: logLevelKey)
            logLevel = LogLevel(rawValue: rawValue) ?? .info
        }
        
        if userDefaults.object(forKey: performanceMonitoringKey) != nil {
            enablePerformanceMonitoring = userDefaults.bool(forKey: performanceMonitoringKey)
        }
        
        if let savedFlags = userDefaults.dictionary(forKey: "com.almrecorder.debug.componentFlags") as? [String: Bool] {
            componentDebugFlags = savedFlags
        }
        
        logger.debug("[DebugConfiguration] Configuration loaded")
    }
    
    /// Reset all debug settings to defaults
    func resetToDefaults() {
        #if DEBUG
        isDebugMode = true
        logLevel = .debug
        enablePerformanceMonitoring = true
        #else
        isDebugMode = false
        logLevel = .warning
        enablePerformanceMonitoring = false
        #endif
        
        enableConsoleLogging = true
        enableFileLogging = true
        enableSlowQueryWarnings = true
        slowQueryThreshold = 0.1
        componentDebugFlags.removeAll()
        
        saveConfiguration()
        logger.info("[DebugConfiguration] Reset to defaults")
    }
}

// MARK: - Debug Macros

/// Log debug information if component debugging is enabled
func debugLog(_ component: String, _ message: String) {
    if DebugConfiguration.shared.isDebuggingEnabled(for: component) {
        VoxtralLogger.shared.debug("[\(component)] \(message)")
    }
}

/// Track performance for a component operation
func trackPerformance<T>(component: String, operation: String, block: () throws -> T) rethrows -> T {
    let startTime = Date()
    let result = try block()
    let duration = Date().timeIntervalSince(startTime)
    
    PerformanceMonitor.shared.trackOperation(
        component: component,
        operation: operation,
        duration: duration
    )
    
    return result
}

/// Track async performance for a component operation
func trackPerformanceAsync<T>(component: String, operation: String, block: () async throws -> T) async rethrows -> T {
    let startTime = Date()
    let result = try await block()
    let duration = Date().timeIntervalSince(startTime)
    
    PerformanceMonitor.shared.trackOperation(
        component: component,
        operation: operation,
        duration: duration
    )
    
    return result
}