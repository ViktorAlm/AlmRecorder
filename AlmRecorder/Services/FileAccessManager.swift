import Foundation
import AppKit

class FileAccessManager: ObservableObject {
    static let shared = FileAccessManager()
    
    @Published var hasVoiceMemosAccess = false
    private let bookmarkKey = "VoiceMemosBookmark"
    
    private init() {
        restoreBookmark()
    }
    
    func requestVoiceMemosAccess(completion: @escaping (URL?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Voice Memos Folder"
        openPanel.message = "Please select the Voice Memos folder to allow AlmRecorder to access your recordings"
        openPanel.prompt = "Grant Access"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = false
        
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let groupContainersURL = homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Group Containers")
            .appendingPathComponent("group.com.apple.VoiceMemos.shared")
            .appendingPathComponent("Recordings")
        
        if FileManager.default.fileExists(atPath: groupContainersURL.path) {
            openPanel.directoryURL = groupContainersURL
        } else {
            let alternativeURL = homeURL
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("com.apple.voicememos")
                .appendingPathComponent("Recordings")
            
            if FileManager.default.fileExists(atPath: alternativeURL.path) {
                openPanel.directoryURL = alternativeURL
            }
        }
        
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                self.saveBookmark(for: url)
                self.hasVoiceMemosAccess = true
                completion(url)
            } else {
                completion(nil)
            }
        }
    }
    
    func requestFileAccess(completion: @escaping ([URL]?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Audio Files"
        openPanel.message = "Select one or more audio files to transcribe"
        openPanel.prompt = "Select"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .mp3]
        
        openPanel.begin { response in
            if response == .OK {
                completion(openPanel.urls)
            } else {
                completion(nil)
            }
        }
    }
    
    private func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
            UserDefaults.standard.synchronize()
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }
    
    private func restoreBookmark() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return
        }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if !isStale && url.startAccessingSecurityScopedResource() {
                hasVoiceMemosAccess = true
            } else if isStale {
                // Clear stale bookmark
                print("Bookmark is stale, clearing...")
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                hasVoiceMemosAccess = false
            }
        } catch {
            print("Failed to restore bookmark: \(error)")
            // Clear invalid bookmark data
            print("Clearing invalid bookmark data...")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            hasVoiceMemosAccess = false
        }
    }
    
    func getVoiceMemosURL() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if !isStale && url.startAccessingSecurityScopedResource() {
                return url
            } else if isStale {
                // Clear stale bookmark
                print("Bookmark is stale in getVoiceMemosURL, clearing...")
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                hasVoiceMemosAccess = false
            }
        } catch {
            print("Failed to resolve bookmark: \(error)")
            // Clear invalid bookmark data
            print("Clearing invalid bookmark data in getVoiceMemosURL...")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            hasVoiceMemosAccess = false
        }
        
        return nil
    }
    
    func clearAccess() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.synchronize()
        hasVoiceMemosAccess = false
    }
}