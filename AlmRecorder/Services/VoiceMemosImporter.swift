import Foundation
import Combine

class VoiceMemosImporter: ObservableObject {
    @Published var voiceMemos: [VoiceMemoFile] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let fileAccessManager = FileAccessManager.shared
    
    private let possibleVoiceMemosLocations = [
        "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings",
        "Library/Application Support/com.apple.voicememos/Recordings",
        "Library/Containers/com.apple.VoiceMemos/Data/tmp",
        "Music/iTunes/iTunes Media/Voice Memos"
    ]
    
    func loadVoiceMemos() {
        isLoading = true
        errorMessage = nil
        voiceMemos = []
        
        if let voiceMemosURL = fileAccessManager.getVoiceMemosURL() {
            loadMemosFromURL(voiceMemosURL)
        } else {
            checkDefaultLocations()
        }
        
        isLoading = false
    }
    
    private func loadMemosFromURL(_ url: URL) {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            
            let audioFiles = fileURLs.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "m4a" || ext == "mp3" || ext == "wav" || ext == "aiff" || ext == "qta"
            }
            
            voiceMemos = audioFiles.map { VoiceMemoFile(url: $0) }
                .sorted { $0.createdDate > $1.createdDate }
            
            if voiceMemos.isEmpty {
                errorMessage = "No voice memos found in the selected folder"
            }
        } catch {
            errorMessage = "Failed to load voice memos: \(error.localizedDescription)"
        }
    }
    
    private func checkDefaultLocations() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        
        for location in possibleVoiceMemosLocations {
            let url = homeURL.appendingPathComponent(location)
            
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
                    
                    errorMessage = "Voice Memos folder found but access denied. Please grant access."
                    return
                } catch {
                    continue
                }
            }
        }
        
        errorMessage = "Voice Memos folder not found. Please select it manually."
    }
    
    func importFromFiles(_ urls: [URL]) {
        let audioFiles = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "m4a" || ext == "mp3" || ext == "wav" || ext == "aiff"
        }
        
        let newMemos = audioFiles.map { VoiceMemoFile(url: $0) }
        voiceMemos.append(contentsOf: newMemos)
        voiceMemos.sort { $0.createdDate > $1.createdDate }
    }
    
    func selectAll() {
        for index in voiceMemos.indices {
            voiceMemos[index].isSelected = true
        }
    }
    
    func deselectAll() {
        for index in voiceMemos.indices {
            voiceMemos[index].isSelected = false
        }
    }
    
    func toggleSelection(for memo: VoiceMemoFile) {
        if let index = voiceMemos.firstIndex(where: { $0.id == memo.id }) {
            voiceMemos[index].isSelected.toggle()
        }
    }
    
    func getSelectedMemos() -> [VoiceMemoFile] {
        return voiceMemos.filter { $0.isSelected }
    }
    
    func updateProgress(for memoID: UUID, progress: Double) {
        if let index = voiceMemos.firstIndex(where: { $0.id == memoID }) {
            voiceMemos[index].transcriptionProgress = progress
        }
    }
    
    func setTranscribing(for memoID: UUID, isTranscribing: Bool) {
        if let index = voiceMemos.firstIndex(where: { $0.id == memoID }) {
            voiceMemos[index].isTranscribing = isTranscribing
            if !isTranscribing {
                voiceMemos[index].transcriptionProgress = 0.0
            }
        }
    }
}