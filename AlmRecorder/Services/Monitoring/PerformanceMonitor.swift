import Foundation
import Combine

/// Monitors and reports on system performance metrics
class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    
    // MARK: - Published Properties
    
    @Published var isMonitoring = false
    @Published var currentMetrics: PerformanceMetrics
    @Published var averageMetrics: PerformanceMetrics
    
    // MARK: - Private Properties
    
    private let logger = VoxtralLogger.shared
    private var startTime: Date?
    private var sampleCount = 0
    private var metricsHistory: [PerformanceMetrics] = []
    private let maxHistorySize = 100
    private var timer: Timer?
    
    // Component-specific metrics
    private var componentMetrics: [String: ComponentMetrics] = [:]
    
    // MARK: - Initialization
    
    private init() {
        self.currentMetrics = PerformanceMetrics()
        self.averageMetrics = PerformanceMetrics()
        
        logger.debug("[PerformanceMonitor] Initialized")
    }
    
    // MARK: - Public Methods
    
    /// Start monitoring performance
    func startMonitoring(interval: TimeInterval = 5.0) {
        guard !isMonitoring else {
            logger.warning("[PerformanceMonitor] Already monitoring")
            return
        }
        
        isMonitoring = true
        startTime = Date()
        sampleCount = 0
        
        logger.info("[PerformanceMonitor] Started monitoring | interval=\(interval)s")
        
        // Start periodic collection
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            self.collectMetrics()
        }
    }
    
    /// Stop monitoring
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        
        if let startTime = startTime {
            let duration = Date().timeIntervalSince(startTime)
            logger.info("[PerformanceMonitor] Stopped monitoring | duration=\(String(format: "%.1f", duration))s samples=\(sampleCount)")
        }
        
        logSummary()
    }
    
    /// Track a component operation
    func trackOperation(component: String, operation: String, duration: TimeInterval, success: Bool = true) {
        if componentMetrics[component] == nil {
            componentMetrics[component] = ComponentMetrics(name: component)
        }
        
        componentMetrics[component]?.addOperation(operation: operation, duration: duration, success: success)
        
        if duration > 1.0 {
            logger.warning("[PerformanceMonitor] Slow operation | component=\(component) operation=\(operation) duration=\(String(format: "%.3f", duration))s")
        }
    }
    
    /// Track memory usage for a component
    func trackMemoryUsage(component: String, bytes: Int) {
        if componentMetrics[component] == nil {
            componentMetrics[component] = ComponentMetrics(name: component)
        }
        
        componentMetrics[component]?.updateMemoryUsage(bytes: bytes)
        
        let mb = Double(bytes) / (1024 * 1024)
        if mb > 100 {
            logger.warning("[PerformanceMonitor] High memory usage | component=\(component) MB=\(String(format: "%.1f", mb))")
        }
    }
    
    /// Get metrics for a specific component
    func getComponentMetrics(_ component: String) -> ComponentMetrics? {
        return componentMetrics[component]
    }
    
    /// Reset all metrics
    func reset() {
        metricsHistory.removeAll()
        componentMetrics.removeAll()
        sampleCount = 0
        currentMetrics = PerformanceMetrics()
        averageMetrics = PerformanceMetrics()
        
        logger.info("[PerformanceMonitor] Metrics reset")
    }
    
    // MARK: - Private Methods
    
    private func collectMetrics() {
        var metrics = PerformanceMetrics()
        
        // Collect memory metrics
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: 1) { pointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), pointer, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            metrics.memoryUsageBytes = Int(info.resident_size)
            metrics.virtualMemoryBytes = Int(info.virtual_size)
        }
        
        // Collect CPU metrics
        if let cpuUsage = getCurrentCPUUsage() {
            metrics.cpuUsagePercent = cpuUsage
        }
        
        // Collect component-specific metrics
        metrics.activeComponentCount = componentMetrics.count
        metrics.totalOperations = componentMetrics.values.reduce(0) { $0 + $1.operationCount }
        metrics.averageOperationTime = componentMetrics.values
            .compactMap { $0.averageDuration }
            .reduce(0, +) / Double(max(1, componentMetrics.count))
        
        // Update current and history
        currentMetrics = metrics
        metricsHistory.append(metrics)
        sampleCount += 1
        
        // Maintain history size
        if metricsHistory.count > maxHistorySize {
            metricsHistory.removeFirst()
        }
        
        // Calculate averages
        updateAverages()
        
        // Log if significant changes
        if let previousMetrics = metricsHistory.dropLast().last {
            let memoryChange = Double(metrics.memoryUsageBytes - previousMetrics.memoryUsageBytes) / (1024 * 1024)
            if abs(memoryChange) > 10 {
                logger.debug("[PerformanceMonitor] Memory change | delta=\(String(format: "%.1f", memoryChange))MB current=\(String(format: "%.1f", Double(metrics.memoryUsageBytes) / (1024 * 1024)))MB")
            }
        }
    }
    
    private func getCurrentCPUUsage() -> Double? {
        var cpuInfo: processor_info_array_t!
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCpus: natural_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCpus, &cpuInfo, &numCpuInfo)
        
        guard result == KERN_SUCCESS else { return nil }
        
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCpuInfo))
        }
        
        var totalUsage = 0.0
        let cpuLoadInfo = cpuInfo.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(numCpus)) { ptr in
            return ptr
        }
        
        for i in 0..<Int(numCpus) {
            let cpu = cpuLoadInfo[i]
            let userTime = Double(cpu.cpu_ticks.0)
            let systemTime = Double(cpu.cpu_ticks.1)
            let idleTime = Double(cpu.cpu_ticks.2)
            let niceTime = Double(cpu.cpu_ticks.3)
            
            let total = userTime + systemTime + idleTime + niceTime
            if total > 0 {
                let usage = (userTime + systemTime) / total * 100.0
                totalUsage += usage
            }
        }
        
        return totalUsage / Double(numCpus)
    }
    
    private func updateAverages() {
        guard !metricsHistory.isEmpty else { return }
        
        let count = Double(metricsHistory.count)
        
        averageMetrics.memoryUsageBytes = Int(Double(metricsHistory.reduce(0) { $0 + $1.memoryUsageBytes }) / count)
        averageMetrics.virtualMemoryBytes = Int(Double(metricsHistory.reduce(0) { $0 + $1.virtualMemoryBytes }) / count)
        averageMetrics.cpuUsagePercent = metricsHistory.reduce(0) { $0 + $1.cpuUsagePercent } / count
        averageMetrics.totalOperations = metricsHistory.reduce(0) { $0 + $1.totalOperations }
        averageMetrics.averageOperationTime = metricsHistory.reduce(0) { $0 + $1.averageOperationTime } / count
    }
    
    private func logSummary() {
        logger.info("[PerformanceMonitor] === Performance Summary ===")
        logger.info("[PerformanceMonitor] Samples collected: \(sampleCount)")
        logger.info("[PerformanceMonitor] Average memory: \(String(format: "%.1f", Double(averageMetrics.memoryUsageBytes) / (1024 * 1024)))MB")
        logger.info("[PerformanceMonitor] Average CPU: \(String(format: "%.1f", averageMetrics.cpuUsagePercent))%")
        logger.info("[PerformanceMonitor] Total operations: \(averageMetrics.totalOperations)")
        
        // Log component summaries
        for (name, metrics) in componentMetrics {
            logger.info("[PerformanceMonitor] Component '\(name)': ops=\(metrics.operationCount) avgTime=\(String(format: "%.3f", metrics.averageDuration ?? 0))s successRate=\(String(format: "%.1f", metrics.successRate * 100))%")
        }
        
        logger.info("[PerformanceMonitor] === End Summary ===")
    }
}

// MARK: - Supporting Types

struct PerformanceMetrics {
    var memoryUsageBytes: Int = 0
    var virtualMemoryBytes: Int = 0
    var cpuUsagePercent: Double = 0.0
    var activeComponentCount: Int = 0
    var totalOperations: Int = 0
    var averageOperationTime: TimeInterval = 0
    var timestamp = Date()
    
    var memoryUsageMB: Double {
        Double(memoryUsageBytes) / (1024 * 1024)
    }
    
    var virtualMemoryMB: Double {
        Double(virtualMemoryBytes) / (1024 * 1024)
    }
}

class ComponentMetrics {
    let name: String
    var operationCount: Int = 0
    var successCount: Int = 0
    var totalDuration: TimeInterval = 0
    var peakMemoryBytes: Int = 0
    var lastMemoryBytes: Int = 0
    var operations: [(operation: String, duration: TimeInterval, success: Bool, timestamp: Date)] = []
    private let maxOperationHistory = 100
    
    init(name: String) {
        self.name = name
    }
    
    func addOperation(operation: String, duration: TimeInterval, success: Bool) {
        operationCount += 1
        if success {
            successCount += 1
        }
        totalDuration += duration
        
        operations.append((operation, duration, success, Date()))
        
        // Maintain history size
        if operations.count > maxOperationHistory {
            operations.removeFirst()
        }
    }
    
    func updateMemoryUsage(bytes: Int) {
        lastMemoryBytes = bytes
        if bytes > peakMemoryBytes {
            peakMemoryBytes = bytes
        }
    }
    
    var averageDuration: TimeInterval? {
        guard operationCount > 0 else { return nil }
        return totalDuration / Double(operationCount)
    }
    
    var successRate: Double {
        guard operationCount > 0 else { return 1.0 }
        return Double(successCount) / Double(operationCount)
    }
    
    var peakMemoryMB: Double {
        Double(peakMemoryBytes) / (1024 * 1024)
    }
    
    var lastMemoryMB: Double {
        Double(lastMemoryBytes) / (1024 * 1024)
    }
}