import Foundation

/// Manages caching of converted WAV files to avoid redundant conversions
class WAVCacheManager {
    
    // MARK: - Singleton
    static let shared = WAVCacheManager()
    
    // MARK: - Properties
    private let cacheDirectory: URL
    private let maxCacheSize: Int64 = 500 * 1024 * 1024 // 500MB
    private let maxCacheAge: TimeInterval = 3600 // 1 hour
    private let logger = VoxtralLogger.shared
    
    // In-memory tracking of cache entries
    private var cacheEntries: [String: CacheEntry] = [:]
    private let cacheQueue = DispatchQueue(label: "wav.cache.queue", attributes: .concurrent)
    
    private struct CacheEntry {
        let key: String
        let path: URL
        let size: Int64
        let createdAt: Date
        var lastAccessedAt: Date
    }
    
    // MARK: - Initialization
    private init() {
        // Create cache directory in temporary folder
        let tempDir = FileManager.default.temporaryDirectory
        self.cacheDirectory = tempDir.appendingPathComponent("AlmRecorder/WAVCache")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        
        // Load existing cache entries
        loadCacheEntries()
        
        // Clean old entries on init
        cleanOldEntries()
        
        logger.debug("[WAVCache] Initialized at: \(cacheDirectory.path)")
    }
    
    // MARK: - Public Methods
    
    /// Get cached WAV file if available
    func getCachedWAV(for sourceFile: String) -> String? {
        let key = cacheKey(for: sourceFile)
        
        return cacheQueue.sync {
            guard let entry = cacheEntries[key] else { return nil }
            
            // Check if file still exists
            guard FileManager.default.fileExists(atPath: entry.path.path) else {
                cacheEntries.removeValue(forKey: key)
                return nil
            }
            
            // Check age
            if Date().timeIntervalSince(entry.createdAt) > maxCacheAge {
                // Too old, remove it
                try? FileManager.default.removeItem(at: entry.path)
                cacheEntries.removeValue(forKey: key)
                return nil
            }
            
            // Update last accessed time
            cacheEntries[key]?.lastAccessedAt = Date()
            
            logger.debug("[WAVCache] Cache hit for: \(sourceFile)")
            return entry.path.path
        }
    }
    
    /// Cache a converted WAV file
    func cacheWAV(sourceFile: String, wavFile: String) {
        let key = cacheKey(for: sourceFile)
        let sourceURL = URL(fileURLWithPath: wavFile)
        
        cacheQueue.async(flags: .barrier) {
            // Check if source file still exists (avoid race conditions)
            guard FileManager.default.fileExists(atPath: wavFile) else {
                self.logger.debug("[WAVCache] File no longer exists, skipping cache: \(wavFile)")
                return
            }
            
            // Get file size
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: wavFile),
                  let fileSize = attributes[.size] as? Int64 else {
                self.logger.debug("[WAVCache] Cannot get file attributes, skipping cache: \(wavFile)")
                return
            }
            
            // Check cache size limit
            self.ensureCacheSize(additionalSize: fileSize)
            
            // Copy to cache directory
            let cachedPath = self.cacheDirectory.appendingPathComponent("\(key).wav")
            
            // Remove existing if present
            try? FileManager.default.removeItem(at: cachedPath)
            
            // Copy new file
            do {
                try FileManager.default.copyItem(at: sourceURL, to: cachedPath)
                
                // Track in memory
                self.cacheEntries[key] = CacheEntry(
                    key: key,
                    path: cachedPath,
                    size: fileSize,
                    createdAt: Date(),
                    lastAccessedAt: Date()
                )
                
                self.logger.debug("[WAVCache] Cached: \(sourceFile) (\(fileSize / 1024)KB)")
                
            } catch {
                // Don't log as error if file doesn't exist - it's a race condition, not an error
                if (error as NSError).code == NSFileReadNoSuchFileError {
                    self.logger.debug("[WAVCache] File was deleted before caching completed: \(sourceFile)")
                } else {
                    self.logger.warning("[WAVCache] Failed to cache: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Clear all cache
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            // Remove all files
            if let files = try? FileManager.default.contentsOfDirectory(at: self.cacheDirectory,
                                                                       includingPropertiesForKeys: nil) {
                for file in files {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            
            // Clear memory tracking
            self.cacheEntries.removeAll()
            
            self.logger.info("[WAVCache] Cache cleared")
        }
    }
    
    /// Get current cache size
    func getCacheSize() -> Int64 {
        return cacheQueue.sync {
            cacheEntries.values.reduce(0) { $0 + $1.size }
        }
    }
    
    // MARK: - Private Methods
    
    private func cacheKey(for file: String) -> String {
        // Create a unique key based on file path and modification date
        let url = URL(fileURLWithPath: file)
        var key = url.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        
        // Add modification date if available
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file),
           let modDate = attributes[.modificationDate] as? Date {
            key += "_\(Int(modDate.timeIntervalSince1970))"
        }
        
        // Add file size for extra uniqueness
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file),
           let size = attributes[.size] as? Int64 {
            key += "_\(size)"
        }
        
        // Remove problematic characters
        key = key.replacingOccurrences(of: "/", with: "_")
        key = key.replacingOccurrences(of: ":", with: "_")
        
        return key
    }
    
    private func loadCacheEntries() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else { return }
        
        for file in files where file.pathExtension == "wav" {
            if let attributes = try? file.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]),
               let size = attributes.fileSize,
               let created = attributes.creationDate {
                
                let key = file.deletingPathExtension().lastPathComponent
                cacheEntries[key] = CacheEntry(
                    key: key,
                    path: file,
                    size: Int64(size),
                    createdAt: created,
                    lastAccessedAt: created
                )
            }
        }
        
        logger.debug("[WAVCache] Loaded \(cacheEntries.count) cache entries")
    }
    
    private func cleanOldEntries() {
        cacheQueue.async(flags: .barrier) {
            let now = Date()
            var keysToRemove: [String] = []
            
            for (key, entry) in self.cacheEntries {
                if now.timeIntervalSince(entry.createdAt) > self.maxCacheAge {
                    keysToRemove.append(key)
                    try? FileManager.default.removeItem(at: entry.path)
                }
            }
            
            for key in keysToRemove {
                self.cacheEntries.removeValue(forKey: key)
            }
            
            if !keysToRemove.isEmpty {
                self.logger.debug("[WAVCache] Removed \(keysToRemove.count) old entries")
            }
        }
    }
    
    private func ensureCacheSize(additionalSize: Int64) {
        var currentSize = cacheEntries.values.reduce(0) { $0 + $1.size }
        
        // If adding this file would exceed limit, remove oldest entries
        if currentSize + additionalSize > maxCacheSize {
            // Sort by last accessed time
            let sortedEntries = cacheEntries.values.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            
            for entry in sortedEntries {
                if currentSize + additionalSize <= maxCacheSize {
                    break
                }
                
                // Remove this entry
                try? FileManager.default.removeItem(at: entry.path)
                cacheEntries.removeValue(forKey: entry.key)
                currentSize -= entry.size
                
                logger.debug("[WAVCache] Evicted: \(entry.key)")
            }
        }
    }
}