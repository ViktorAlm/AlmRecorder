import Foundation
import Combine

/// Unified download queue for all model types (Whisper, Voxtral, Embeddings)
class UnifiedDownloadQueue: NSObject, ObservableObject {

    struct AdditionalDownload {
        let url: URL
        let path: URL
        let fileSize: Int64
    }
    
    // MARK: - Download Task
    
    struct DownloadTask: Identifiable {
        let id = UUID()
        let modelId: String
        let displayName: String
        let modelType: String // "whisper", "voxtral", "embedding"
        let downloadURL: URL
        let destinationPath: URL
        let fileSize: Int64
        var additionalFiles: [AdditionalDownload] = []
        
        var state: DownloadState = .pending
        var progress: Double = 0.0
        var error: Error?
        var sessionTask: URLSessionDownloadTask?
        var retryCount: Int = 0
        var retryNotBefore: Date?
        var startTime: Date?
        var bytesWritten: Int64 = 0
        var totalBytes: Int64 = 0
        
        enum DownloadState: Equatable {
            case pending
            case downloading
            case completed
            case failed
            case cancelled
        }
        
        var estimatedTimeRemaining: TimeInterval? {
            guard state == .downloading,
                  let startTime = startTime,
                  progress > 0 && progress < 1 else { return nil }
            
            let elapsed = Date().timeIntervalSince(startTime)
            let estimatedTotal = elapsed / progress
            return estimatedTotal - elapsed
        }
    }
    
    // MARK: - Published Properties
    
    @Published var downloadTasks: [DownloadTask] = []
    @Published var activeDownloads: Int = 0
    @Published var isDownloading: Bool = false
    
    // MARK: - Private Properties
    
    private let maxConcurrentDownloads = 2
    private let maxRetries = 3
    private var urlSession: URLSession!
    private var taskMapping: [URLSessionDownloadTask: UUID] = [:]
    
    // MARK: - Singleton
    
    static let shared = UnifiedDownloadQueue()
    
    // MARK: - Initialization
    
    override private init() {
        super.init()
        
        // Configure URLSession (using default for CLI compatibility)
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 300
        // The largest optional model exceeds 12 GB; slow but healthy connections need more than
        // the former two-hour ceiling.
        config.timeoutIntervalForResource = 8 * 60 * 60
        config.allowsCellularAccess = true
        
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    /// Catalog sizes are estimates, but accepting any file larger than 1 MB lets a truncated GGUF
    /// masquerade as an installed multi-gigabyte model. A 70% floor leaves room for deliberately
    /// conservative catalog estimates while rejecting practically useful partial downloads.
    static func minimumAcceptableBytes(declaredSize: Int64) -> Int64 {
        max(1_000_000, Int64(Double(max(0, declaredSize)) * 0.70))
    }

    static func isAcceptableFileSize(
        _ actualBytes: Int64,
        declaredSize: Int64,
        serverExpectedBytes: Int64? = nil
    ) -> Bool {
        guard actualBytes > 1_000_000 else { return false }
        if let serverExpectedBytes, serverExpectedBytes > 1_000_000 {
            return actualBytes == serverExpectedBytes
        }
        return actualBytes >= minimumAcceptableBytes(declaredSize: declaredSize)
    }

    static func retryIsReady(notBefore: Date?, now: Date = Date()) -> Bool {
        guard let notBefore else { return true }
        return notBefore <= now
    }
    
    // MARK: - Public Methods
    
    /// Add a model to the download queue
    func enqueueDownload(
        modelId: String,
        displayName: String,
        modelType: String,
        downloadURL: URL,
        destinationPath: URL,
        fileSize: Int64,
        additionalFiles: [AdditionalDownload] = []
    ) {
        // Check if already downloading or downloaded
        if downloadTasks.contains(where: {
            $0.modelId == modelId && 
            ($0.state == .pending || $0.state == .downloading)
        }) {
            print("[UnifiedQueue] Model already in queue: \(displayName)")
            return
        }

        // A completed/failed row is historical UI state, not proof that the destination still
        // exists. In particular, deleting a model must allow it to be downloaded again.
        downloadTasks.removeAll {
            $0.modelId == modelId
                && ($0.state == .completed || $0.state == .failed || $0.state == .cancelled)
        }
        
        // Check if file already exists with valid size
        if FileManager.default.fileExists(atPath: destinationPath.path) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: destinationPath.path),
               let size = attributes[.size] as? Int64,
               Self.isAcceptableFileSize(size, declaredSize: fileSize) {
                print("[UnifiedQueue] Model already downloaded: \(displayName)")
                var completed = DownloadTask(
                    modelId: modelId,
                    displayName: displayName,
                    modelType: modelType,
                    downloadURL: downloadURL,
                    destinationPath: destinationPath,
                    fileSize: fileSize,
                    additionalFiles: additionalFiles
                )
                completed.state = .completed
                completed.progress = 1
                downloadTasks.append(completed)
                enqueueAdditionalFiles(for: completed)
                return
            } else {
                // Remove corrupted file
                try? FileManager.default.removeItem(at: destinationPath)
            }
        }
        
        // Add to queue
        let task = DownloadTask(
            modelId: modelId,
            displayName: displayName,
            modelType: modelType,
            downloadURL: downloadURL,
            destinationPath: destinationPath,
            fileSize: fileSize,
            additionalFiles: additionalFiles
        )
        downloadTasks.append(task)
        
        print("[UnifiedQueue] Enqueued download: \(displayName)")
        
        // Start processing queue
        processQueue()
    }
    
    /// Cancel a download
    func cancelDownload(_ taskId: UUID) {
        guard let index = downloadTasks.firstIndex(where: { $0.id == taskId }) else { return }
        
        var task = downloadTasks[index]
        task.sessionTask?.cancel()
        task.state = .cancelled
        downloadTasks[index] = task
        
        // Clean up mapping
        if let sessionTask = task.sessionTask {
            taskMapping.removeValue(forKey: sessionTask)
        }
        
        updateActiveCount()
        processQueue()
    }
    
    /// Retry a failed download
    func retryDownload(_ taskId: UUID) {
        guard let index = downloadTasks.firstIndex(where: { $0.id == taskId }) else { return }
        
        var task = downloadTasks[index]
        task.state = .pending
        task.error = nil
        task.progress = 0
        task.retryCount = 0
        task.retryNotBefore = nil
        downloadTasks[index] = task
        
        processQueue()
    }
    
    /// Clear completed/failed downloads from list
    func clearCompleted() {
        downloadTasks.removeAll { task in
            task.state == .completed || task.state == .failed || task.state == .cancelled
        }
    }
    
    /// Check if a model is queued or downloading
    func isInQueue(_ modelId: String) -> Bool {
        downloadTasks.contains { 
            $0.modelId == modelId && 
            ($0.state == .pending || $0.state == .downloading)
        }
    }
    
    // MARK: - Private Methods
    
    private func processQueue() {
        let activeCount = downloadTasks.filter { $0.state == .downloading }.count
        
        guard activeCount < maxConcurrentDownloads else { return }
        
        // Find next pending task
        let now = Date()
        guard let nextIndex = downloadTasks.firstIndex(where: {
            $0.state == .pending && Self.retryIsReady(notBefore: $0.retryNotBefore, now: now)
        }) else {
            updateActiveCount()
            return
        }
        
        var task = downloadTasks[nextIndex]
        
        // Check if file was downloaded while in queue
        if FileManager.default.fileExists(atPath: task.destinationPath.path) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: task.destinationPath.path),
               let size = attributes[.size] as? Int64,
               Self.isAcceptableFileSize(size, declaredSize: task.fileSize) {
                task.state = .completed
                downloadTasks[nextIndex] = task
                enqueueAdditionalFiles(for: task)
                processQueue()
                return
            }
        }
        
        // Start download
        var request = URLRequest(url: task.downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let sessionTask = urlSession.downloadTask(with: request)
        
        task.sessionTask = sessionTask
        task.state = .downloading
        task.retryNotBefore = nil
        task.startTime = Date()
        downloadTasks[nextIndex] = task
        
        // Map session task to task ID
        taskMapping[sessionTask] = task.id
        
        sessionTask.resume()
        
        print("[UnifiedQueue] Started download: \(task.displayName)")
        print("[UnifiedQueue] Download URL: \(task.downloadURL.absoluteString)")
        
        updateActiveCount()
        
        // Process more if slots available
        processQueue()
    }
    
    private func updateActiveCount() {
        activeDownloads = downloadTasks.filter { $0.state == .downloading }.count
        isDownloading = activeDownloads > 0
    }
    
    private func findTask(for sessionTask: URLSessionTask) -> (index: Int, task: DownloadTask)? {
        guard let downloadTask = sessionTask as? URLSessionDownloadTask,
              let taskId = taskMapping[downloadTask],
              let index = downloadTasks.firstIndex(where: { $0.id == taskId }) else {
            return nil
        }
        return (index, downloadTasks[index])
    }
    
    private func handleDownloadCompletion(sessionTask: URLSessionDownloadTask, location: URL) {
        guard let (index, originalTask) = findTask(for: sessionTask) else { return }
        var task = originalTask
        
        let destinationPath = task.destinationPath
        
        do {
            guard let response = sessionTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                let status = (sessionTask.response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(
                    domain: "UnifiedQueue",
                    code: status,
                    userInfo: [NSLocalizedDescriptionKey: "Model host returned HTTP \(status)"]
                )
            }

            // Validate file size
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            print("[UnifiedQueue] Downloaded file size: \(fileSize) bytes (\(fileSize / 1_000_000) MB)")
            print("[UnifiedQueue] Source location: \(location.path)")
            print("[UnifiedQueue] Destination: \(destinationPath.path)")
            
            let responseBytes = response.expectedContentLength > 0
                ? response.expectedContentLength
                : nil
            guard Self.isAcceptableFileSize(
                fileSize,
                declaredSize: task.fileSize,
                serverExpectedBytes: responseBytes
            ) else {
                print("[UnifiedQueue] File incomplete: \(fileSize) bytes")
                throw NSError(
                    domain: "UnifiedQueue",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded model is incomplete"]
                )
            }
            
            // Create directory if needed
            let destDir = destinationPath.deletingLastPathComponent()
            print("[UnifiedQueue] Creating directory: \(destDir.path)")
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)
            
            // Remove existing file if it exists
            if FileManager.default.fileExists(atPath: destinationPath.path) {
                print("[UnifiedQueue] Removing existing file at destination")
                try FileManager.default.removeItem(at: destinationPath)
            }
            
            // Move file
            print("[UnifiedQueue] Moving file to destination...")
            try FileManager.default.moveItem(at: location, to: destinationPath)
            
            // Verify file exists at destination
            if FileManager.default.fileExists(atPath: destinationPath.path) {
                let destAttributes = try FileManager.default.attributesOfItem(atPath: destinationPath.path)
                let destFileSize = destAttributes[.size] as? Int64 ?? 0
                print("[UnifiedQueue] File successfully moved. Size at destination: \(destFileSize) bytes")
            } else {
                throw NSError(domain: "UnifiedQueue", code: 2, userInfo: [NSLocalizedDescriptionKey: "File not found at destination"])
            }
            
            task.state = .completed
            task.progress = 1.0
            task.sessionTask = nil
            downloadTasks[index] = task
            
            print("[UnifiedQueue] Completed download: \(task.displayName)")
            
            // Download additional files if any (e.g., mmproj for Voxtral)
            enqueueAdditionalFiles(for: task)
            
        } catch {
            print("[UnifiedQueue] Failed to save downloaded file: \(error.localizedDescription)")
            print("[UnifiedQueue] Destination path: \(destinationPath.path)")
            print("[UnifiedQueue] Error details: \(error)")
            handleDownloadError(sessionTask: sessionTask, error: error)
        }
        
        // Clean up mapping
        taskMapping.removeValue(forKey: sessionTask)
        
        updateActiveCount()
        processQueue()
    }
    
    private func handleDownloadError(sessionTask: URLSessionDownloadTask, error: Error) {
        guard let (index, originalTask) = findTask(for: sessionTask) else { return }
        var task = originalTask
        
        task.retryCount += 1
        
        if task.retryCount < maxRetries {
            // Retry with exponential backoff
            let delay = Double(task.retryCount) * 2.0
            print("[UnifiedQueue] Retrying download in \(delay)s: \(task.displayName)")
            
            task.state = .pending
            task.error = nil
            task.sessionTask = nil
            task.retryNotBefore = Date().addingTimeInterval(delay)
            downloadTasks[index] = task
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.processQueue()
            }
        } else {
            // Max retries reached
            task.state = .failed
            task.error = error
            downloadTasks[index] = task
            
            print("[UnifiedQueue] Download failed after \(maxRetries) retries: \(task.displayName)")
        }
        
        // Clean up mapping
        taskMapping.removeValue(forKey: sessionTask)
        
        updateActiveCount()
        processQueue()
    }

    private func enqueueAdditionalFiles(for task: DownloadTask) {
        for (index, additional) in task.additionalFiles.enumerated() {
            let suffix = task.additionalFiles.count == 1 ? "additional" : "additional-\(index)"
            enqueueDownload(
                modelId: "\(task.modelId)-\(suffix)",
                displayName: "\(task.displayName) (additional \(index + 1))",
                modelType: task.modelType,
                downloadURL: additional.url,
                destinationPath: additional.path,
                fileSize: additional.fileSize
            )
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension UnifiedDownloadQueue: URLSessionDownloadDelegate {
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (index, originalTask) = findTask(for: downloadTask) else { 
            print("[UnifiedQueue] Warning: Could not find task for progress update")
            return 
        }
        var task = originalTask
        
        task.bytesWritten = totalBytesWritten
        task.totalBytes = totalBytesExpectedToWrite
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : originalTask.fileSize
        task.progress = expected > 0
            ? min(1, Double(totalBytesWritten) / Double(expected))
            : 0
        
        // Update on main thread to trigger UI updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.downloadTasks[index] = task
            
            // Log progress every 10%
            let percent = Int(task.progress * 100)
            if percent % 10 == 0 {
                print("[UnifiedQueue] Progress: \(task.displayName) - \(percent)%")
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        handleDownloadCompletion(sessionTask: downloadTask, location: location)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("[UnifiedQueue] Download error: \(error)")
            print("[UnifiedQueue] Error code: \((error as NSError).code)")
            print("[UnifiedQueue] Error domain: \((error as NSError).domain)")
            
            if let downloadTask = task as? URLSessionDownloadTask {
                handleDownloadError(sessionTask: downloadTask, error: error)
            }
        } else {
            print("[UnifiedQueue] Download task completed successfully")
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        print("[UnifiedQueue] Redirect from: \(task.originalRequest?.url?.absoluteString ?? "unknown")")
        print("[UnifiedQueue] Redirect to: \(request.url?.absoluteString ?? "unknown")")
        print("[UnifiedQueue] Response code: \(response.statusCode)")
        
        // Allow redirects (common with HuggingFace)
        completionHandler(request)
    }
}
