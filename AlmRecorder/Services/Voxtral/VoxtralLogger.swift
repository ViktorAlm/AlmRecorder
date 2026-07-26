import Foundation
import os.log
import AppKit // For NSWorkspace to open log files

/// Logging levels for Voxtral services
enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// Protocol for logging functionality
protocol VoxtralLogging {
    func debug(_ message: String)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}

/// Logger implementation for Voxtral services
class VoxtralLogger: VoxtralLogging {
    static let shared = VoxtralLogger()
    
    private let subsystem = "com.almrecorder.voxtral"
    private let logger: Logger
    
    /// Current log level - can be changed at runtime
    var logLevel: LogLevel = .info
    
    /// Enable/disable console output
    var enableConsoleOutput: Bool = true
    
    /// Enable/disable file logging
    var enableFileLogging: Bool = true
    
    /// Log file handle for writing
    private var fileHandle: FileHandle?
    
    /// URL to the log file
    private let logFileURL: URL
    
    /// Queue for thread-safe file operations
    private let fileQueue = DispatchQueue(label: "com.almrecorder.voxtral.filelogger")
    
    /// Maximum log file size (10MB)
    private let maxLogFileSize: Int = 10 * 1024 * 1024
    
    private init() {
        self.logger = Logger(subsystem: subsystem, category: "VoxtralCpp")
        
        // Setup log file path
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("AlmRecorder")
        
        // Create logs directory if it doesn't exist
        try? FileManager.default.createDirectory(at: logsDirectory, 
                                                withIntermediateDirectories: true, 
                                                attributes: nil)
        
        self.logFileURL = logsDirectory.appendingPathComponent("voxtral.log")
        
        // Always enable console output and file logging in DEBUG builds
        #if DEBUG
        self.enableConsoleOutput = true
        self.enableFileLogging = true
        self.logLevel = .debug
        #endif
        
        // Initialize log file
        setupLogFile()
        
        // Log startup message
        info("VoxtralLogger initialized. Log file: \(logFileURL.path)")
    }
    
    func debug(_ message: String) {
        log(message, level: .debug)
    }
    
    func info(_ message: String) {
        log(message, level: .info)
    }
    
    func warning(_ message: String) {
        log(message, level: .warning)
    }
    
    func error(_ message: String) {
        log(message, level: .error)
    }
    
    private func log(_ message: String, level: LogLevel) {
        guard level >= logLevel else { return }
        
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let prefix = "[\(timestamp)] [\(categoryName(for: level))]"
        let formattedMessage = "\(prefix) \(message)"
        
        // Log to system logger
        switch level {
        case .debug:
            logger.debug("\(formattedMessage)")
        case .info:
            logger.info("\(formattedMessage)")
        case .warning:
            logger.warning("\(formattedMessage)")
        case .error:
            logger.error("\(formattedMessage)")
        }
        
        // Always print to console in DEBUG builds for better visibility
        #if DEBUG
        print("🎙️ AlmRecorder: \(formattedMessage)")
        #else
        if enableConsoleOutput {
            print(formattedMessage)
        }
        #endif
        
        // Write to file if enabled
        if enableFileLogging {
            writeToLogFile(formattedMessage)
        }
    }
    
    private func categoryName(for level: LogLevel) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
    
    // MARK: - File Logging
    
    /// Setup the log file, creating it if necessary
    private func setupLogFile() {
        fileQueue.sync {
            // Create file if it doesn't exist
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, 
                                              contents: nil, 
                                              attributes: nil)
            }
            
            // Check file size and rotate if necessary
            rotateLogFileIfNeeded()
            
            // Open file handle for appending
            do {
                fileHandle = try FileHandle(forWritingTo: logFileURL)
                fileHandle?.seekToEndOfFile()
            } catch {
                print("Failed to open log file: \(error)")
            }
        }
    }
    
    /// Write a message to the log file
    private func writeToLogFile(_ message: String) {
        fileQueue.async { [weak self] in
            guard let self = self else { return }
            
            let messageWithNewline = message + "\n"
            guard let data = messageWithNewline.data(using: .utf8) else { return }
            
            do {
                if self.fileHandle == nil {
                    self.setupLogFile()
                }
                
                self.fileHandle?.write(data)
                
                // Flush to disk periodically
                if Int.random(in: 0..<10) == 0 {
                    self.fileHandle?.synchronizeFile()
                }
            } catch {
                print("Failed to write to log file: \(error)")
            }
        }
    }
    
    /// Rotate log file if it exceeds maximum size
    private func rotateLogFileIfNeeded() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: logFileURL.path)
            let fileSize = attributes[.size] as? Int ?? 0
            
            if fileSize > maxLogFileSize {
                // Close current file handle
                fileHandle?.closeFile()
                fileHandle = nil
                
                // Create backup filename with timestamp
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
                let timestamp = dateFormatter.string(from: Date())
                let backupURL = logFileURL.deletingLastPathComponent()
                    .appendingPathComponent("voxtral_\(timestamp).log")
                
                // Move current log to backup
                try FileManager.default.moveItem(at: logFileURL, to: backupURL)
                
                // Create new empty log file
                FileManager.default.createFile(atPath: logFileURL.path, 
                                              contents: nil, 
                                              attributes: nil)
                
                // Clean up old backup files (keep only last 5)
                cleanupOldLogFiles()
            }
        } catch {
            print("Failed to rotate log file: \(error)")
        }
    }
    
    /// Clean up old log backup files
    private func cleanupOldLogFiles() {
        do {
            let logsDirectory = logFileURL.deletingLastPathComponent()
            let files = try FileManager.default.contentsOfDirectory(at: logsDirectory,
                                                                   includingPropertiesForKeys: [.creationDateKey],
                                                                   options: .skipsHiddenFiles)
            
            let logBackups = files.filter { $0.lastPathComponent.starts(with: "voxtral_") }
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    return date1 > date2
                }
            
            // Keep only the 5 most recent backups
            if logBackups.count > 5 {
                for backup in logBackups.dropFirst(5) {
                    try FileManager.default.removeItem(at: backup)
                }
            }
        } catch {
            print("Failed to cleanup old log files: \(error)")
        }
    }
    
    // MARK: - Public Methods
    
    /// Clear the current log file
    func clearLogFile() {
        fileQueue.sync {
            fileHandle?.closeFile()
            fileHandle = nil
            
            // Truncate the file
            FileManager.default.createFile(atPath: logFileURL.path, 
                                          contents: nil, 
                                          attributes: nil)
            setupLogFile()
        }
        
        info("Log file cleared")
    }
    
    /// Get the path to the log file
    func getLogFilePath() -> String {
        return logFileURL.path
    }
    
    /// Get recent log entries
    func getRecentLogs(lines: Int = 100) -> [String] {
        do {
            let logContent = try String(contentsOf: logFileURL, encoding: .utf8)
            let allLines = logContent.components(separatedBy: .newlines)
            let recentLines = allLines.suffix(lines)
            return Array(recentLines).filter { !$0.isEmpty }
        } catch {
            return ["Failed to read log file: \(error)"]
        }
    }
    
    /// Open log file in Console app
    func openLogInConsole() {
        NSWorkspace.shared.open(logFileURL)
    }
    
    deinit {
        fileHandle?.closeFile()
    }
}

/// Convenience logger instance
let voxtralLog = VoxtralLogger.shared