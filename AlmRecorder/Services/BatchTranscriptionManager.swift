import Foundation
import Combine

@MainActor
class BatchTranscriptionManager: ObservableObject {
    @Published var isProcessing = false
    @Published var currentFile: String = ""
    @Published var progress: Double = 0.0
    @Published var completedItems: [TranscriptionItem] = []
    @Published var failedFiles: [(file: String, error: String)] = []
    @Published var currentStatus: String = ""
    @Published var currentFileProgress: Double = 0.0
    @Published var pendingSpeakerReviews: [(recordingId: Int64, audioPath: String, result: TranscriptionResult, fileName: String)] = []
    
    private let unifiedManager = UnifiedTranscriptionManager.shared
    private let queueManager = TranscriptionQueueManager.shared
    private let globalSettings = GlobalTranscriptionSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var isCancelled = false
    private var queuedJobIds: [UUID] = [] // Track jobs added to queue
    
    init() {
        setupStatusBinding()
    }
    
    private func setupStatusBinding() {
        // Subscribe to status updates from UnifiedTranscriptionManager
        unifiedManager.$transcriptionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.currentStatus = status
            }
            .store(in: &cancellables)
        
        unifiedManager.$currentFileProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.currentFileProgress = progress
            }
            .store(in: &cancellables)
    }
    
    func transcribeBatch(_ files: [VoiceMemoFile], importer: VoiceMemosImporter, runSettings: RunSettings? = nil) async {
        isProcessing = true
        isCancelled = false
        progress = 0.0
        completedItems = []
        failedFiles = []
        pendingSpeakerReviews = []
        
        let totalFiles = files.count
        
        for (index, file) in files.enumerated() {
            if isCancelled {
                break
            }
            
            await MainActor.run {
                currentFile = file.name
                progress = Double(index) / Double(totalFiles)
                importer.setTranscribing(for: file.id, isTranscribing: true)
            }
            
            // Use provided settings or global settings if custom settings are enabled
            let settingsToUse = runSettings ?? (globalSettings.useCustomSettings ? globalSettings.createRunSettings() : nil)
            
            // Use transcribeWithResult to capture speaker detection data
            let (transcriptionItem, transcriptionResult, recordingId) = await unifiedManager.transcribeWithResult(
                audioFile: file.url.path,
                fileName: file.name,
                source: .voiceMemos,
                runSettings: settingsToUse
            )
            
            print("[BatchTranscriptionManager] Transcription completed for \(file.name)")
            print("[BatchTranscriptionManager] - Status: \(transcriptionItem.status)")
            print("[BatchTranscriptionManager] - Has result: \(transcriptionResult != nil)")
            print("[BatchTranscriptionManager] - Recording ID: \(recordingId ?? -1)")
            
            await MainActor.run {
                if transcriptionItem.status == .completed || transcriptionItem.status == .partialSuccess {
                    completedItems.append(transcriptionItem)
                    importer.updateProgress(for: file.id, progress: 1.0)
                    
                    // Check if we have multiple speakers that need review
                    if let result = transcriptionResult {
                        if let recordingId = recordingId {
                            let speakerCount = result.detectedSpeakerCount ?? 0
                            let embeddingCount = result.speakerEmbeddings?.count ?? 0
                            let hasMultipleSpeakers = speakerCount > 1 || embeddingCount > 1
                            
                            print("[BatchTranscriptionManager] Speaker analysis for \(file.name):")
                            print("[BatchTranscriptionManager] - Detected speakers: \(speakerCount)")
                            print("[BatchTranscriptionManager] - Embedding count: \(embeddingCount)")
                            print("[BatchTranscriptionManager] - Has multiple speakers: \(hasMultipleSpeakers)")
                            
                            if hasMultipleSpeakers {
                                // Store the speaker review data for later processing
                                pendingSpeakerReviews.append((
                                    recordingId: recordingId,
                                    audioPath: file.url.path,
                                    result: result,
                                    fileName: file.name
                                ))
                                print("[BatchTranscriptionManager] Added \(file.name) to speaker review queue (total: \(pendingSpeakerReviews.count))")
                            }
                        } else {
                            print("[BatchTranscriptionManager] ERROR: No recording ID for \(file.name) - cannot add to speaker review!")
                        }
                    } else {
                        print("[BatchTranscriptionManager] No transcription result for \(file.name) - skipping speaker detection")
                    }
                } else if transcriptionItem.status == .failed {
                    failedFiles.append((file: file.name, error: transcriptionItem.error ?? "Unknown error"))
                }
                importer.setTranscribing(for: file.id, isTranscribing: false)
            }
        }
        
        await MainActor.run {
            isProcessing = false
            progress = 1.0
            currentFile = ""
        }
    }
    
    func cancel() {
        isCancelled = true
        // Also cancel queued jobs
        for jobId in queuedJobIds {
            queueManager.cancelJob(jobId)
        }
        queuedJobIds.removeAll()
    }
    
    // New queue-based batch transcription
    func transcribeBatchUsingQueue(_ files: [VoiceMemoFile], importer: VoiceMemosImporter, runSettings: RunSettings? = nil) async {
        await MainActor.run {
            isProcessing = true
            isCancelled = false
            progress = 0.0
            completedItems = []
            failedFiles = []
            pendingSpeakerReviews = []
            queuedJobIds = []
        }
        
        let totalFiles = files.count
        let settingsToUse = runSettings ?? (globalSettings.useCustomSettings ? globalSettings.createRunSettings() : nil)
        
        // Add all files to queue
        for file in files {
            let job = queueManager.addJob(
                audioFile: file.url.path,
                fileName: file.name,
                source: .voiceMemos,
                priority: .normal,
                runSettings: settingsToUse
            )
            
            await MainActor.run {
                queuedJobIds.append(job.id)
                importer.setTranscribing(for: file.id, isTranscribing: true)
            }
        }
        
        print("[BatchTranscriptionManager] Added \(totalFiles) files to transcription queue")
        
        // Monitor queue progress
        await monitorQueueProgress(files: files, importer: importer)
    }
    
    private func monitorQueueProgress(files: [VoiceMemoFile], importer: VoiceMemosImporter) async {
        let totalFiles = files.count
        var processedCount = 0
        
        // Poll queue status periodically
        while processedCount < totalFiles && !isCancelled {
            try? await Task.sleep(for: .milliseconds(500)) // Check every 500ms
            
            var completed = 0
            var failed = 0
            var currentFileName = ""
            
            // Check status of our jobs
            var currentJobProgress: Double = 0
            var currentJobStatus = ""
            
            for (index, jobId) in queuedJobIds.enumerated() {
                if let job = queueManager.jobs.first(where: { $0.id == jobId }) {
                    switch job.status {
                    case .completed:
                        completed += 1
                        if index < files.count {
                            await MainActor.run {
                                importer.setTranscribing(for: files[index].id, isTranscribing: false)
                            }
                        }
                    case .failed:
                        failed += 1
                        if index < files.count {
                            await MainActor.run {
                                importer.setTranscribing(for: files[index].id, isTranscribing: false)
                                failedFiles.append((file: files[index].name, error: job.error ?? "Unknown error"))
                            }
                        }
                    case .processing:
                        currentFileName = job.fileName
                        currentJobProgress = job.detailedProgress
                        currentJobStatus = job.detailedProgressMessage
                    default:
                        break
                    }
                }
            }
            
            processedCount = completed + failed
            
            // Capture values for safe concurrent access
            let capturedProcessedCount = processedCount
            let capturedFileName = currentFileName
            let capturedJobProgress = currentJobProgress
            let capturedJobStatus = currentJobStatus
            
            await MainActor.run {
                progress = Double(capturedProcessedCount) / Double(totalFiles)
                currentFile = capturedFileName
                
                // Use actual job status if available
                if !capturedJobStatus.isEmpty {
                    currentStatus = capturedJobStatus
                    currentFileProgress = capturedJobProgress
                } else {
                    currentStatus = "Processing \(capturedProcessedCount) of \(totalFiles) files..."
                    currentFileProgress = 0
                }
            }
        }
        
        await MainActor.run {
            isProcessing = false
            progress = 1.0
            currentFile = ""
            currentStatus = "Batch processing complete"
        }
    }
    
    // Delegate to UnifiedTranscriptionManager for loading saved transcriptions
    func loadSavedTranscriptions() -> [TranscriptionItem] {
        return unifiedManager.loadSavedTranscriptions()
    }
    
    func exportTranscriptions(items: [TranscriptionItem], format: ExportFormat) -> URL? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Date().timeIntervalSince1970
        
        switch format {
        case .txt:
            return exportAsText(items: items, to: documentsPath.appendingPathComponent("transcriptions_\(Int(timestamp)).txt"))
        case .csv:
            return exportAsCSV(items: items, to: documentsPath.appendingPathComponent("transcriptions_\(Int(timestamp)).csv"))
        case .json:
            return exportAsJSON(items: items, to: documentsPath.appendingPathComponent("transcriptions_\(Int(timestamp)).json"))
        }
    }
    
    private func exportAsText(items: [TranscriptionItem], to url: URL) -> URL? {
        var content = "AlmRecorder Transcriptions Export\n"
        content += "Generated: \(Date())\n"
        content += String(repeating: "=", count: 50) + "\n\n"
        
        for item in items {
            content += "File: \(item.fileName)\n"
            content += "Date: \(item.formattedTranscribedDate)\n"
            content += "Duration: \(item.formattedDuration)\n"
            content += "Language: \(item.language)\n"
            content += "Status: \(item.status.rawValue)\n"
            if let error = item.error {
                content += "Error: \(error)\n"
            }
            content += "\nTranscript:\n"
            content += item.transcript.isEmpty ? "[No transcript available]" : item.transcript
            content += "\n"
            content += "\n" + String(repeating: "-", count: 50) + "\n\n"
        }
        
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("Failed to export as text: \(error)")
            return nil
        }
    }
    
    private func exportAsCSV(items: [TranscriptionItem], to url: URL) -> URL? {
        var content = "File Name,Date,Duration,Language,Status,Error,Transcript\n"
        
        for item in items {
            let escapedTranscript = item.transcript
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
            
            content += "\"\(item.fileName)\","
            content += "\"\(item.formattedTranscribedDate)\","
            content += "\"\(item.formattedDuration)\","
            content += "\"\(item.language)\","
            content += "\"\(item.status.rawValue)\","
            content += "\"\(item.error ?? "")\","
            content += "\"\(escapedTranscript)\"\n"
        }
        
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("Failed to export as CSV: \(error)")
            return nil
        }
    }
    
    private func exportAsJSON(items: [TranscriptionItem], to url: URL) -> URL? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(items)
            try data.write(to: url)
            return url
        } catch {
            print("Failed to export as JSON: \(error)")
            return nil
        }
    }
    
    enum ExportFormat {
        case txt
        case csv
        case json
    }
}