import Foundation
import AVFoundation
import Combine

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration = 0
    @Published var recordedFileURL = ""
    @Published var fileSize: Int64 = 0
    @Published var recordedChunks: [URL] = []
    
    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    
    // Chunking configuration
    private let chunkDuration: TimeInterval = 600 // 10 minutes
    private var currentChunkStartTime: TimeInterval = 0
    private var currentChunkIndex = 0
    
    override init() {
        super.init()
        requestMicrophonePermission()
    }
    
    private func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    print("Microphone permission denied")
                }
            }
        case .denied, .restricted:
            print("Microphone permission denied or restricted")
        @unknown default:
            break
        }
    }
    
    func startRecording() {
        // Reset chunk tracking
        recordedChunks = []
        currentChunkIndex = 0
        currentChunkStartTime = 0
        recordingDuration = 0
        
        // Start first chunk
        startNewChunk()
        
        // Start duration timer
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.recordingDuration += 1
            
            // Check if we need to start a new chunk
            let chunkElapsedTime = TimeInterval(self.recordingDuration) - self.currentChunkStartTime
            if chunkElapsedTime >= self.chunkDuration {
                self.rotateToNewChunk()
            }
        }
    }
    
    /// Directory where recorded audio is stored:
    /// `~/Library/Application Support/AlmRecorder/Recordings` — co-located with the database and
    /// downloaded models, instead of dropping loose files into the user's Documents folder.
    /// (Resolves to the sandbox container when sandboxed, the real path otherwise.) Created on access.
    static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("AlmRecorder/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func startNewChunk() {
        let timestamp = Date().timeIntervalSince1970
        let audioFilename = Self.recordingsDirectory.appendingPathComponent("recording_\(timestamp)_chunk_\(currentChunkIndex).m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            isRecording = true
            recordedFileURL = audioFilename.path
            recordedChunks.append(audioFilename)
            
        } catch {
            print("Failed to start recording chunk \(currentChunkIndex): \(error)")
        }
    }
    
    private func rotateToNewChunk() {
        // Stop current recorder
        audioRecorder?.stop()
        
        // Update chunk tracking
        currentChunkIndex += 1
        currentChunkStartTime = TimeInterval(recordingDuration)
        
        // Start new chunk
        startNewChunk()
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        
        timer?.invalidate()
        timer = nil
        
        isRecording = false
        
        if !recordedFileURL.isEmpty {
            updateFileSize()
        }
    }
    
    func clearRecording() {
        if !recordedFileURL.isEmpty {
            try? FileManager.default.removeItem(atPath: recordedFileURL)
            recordedFileURL = ""
            fileSize = 0
            recordingDuration = 0
        }
    }
    
    private func updateFileSize() {
        guard !recordedFileURL.isEmpty else { return }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: recordedFileURL)
            fileSize = attributes[.size] as? Int64 ?? 0
        } catch {
            print("Failed to get file size: \(error)")
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording failed")
            clearRecording()
        }
    }
}