import Combine
import Foundation

/// Publishes the two-file BitNet snapshot atomically, so an interrupted download never appears ready.
final class VibeASRBitNetModelManager: ObservableObject {
    static let shared = VibeASRBitNetModelManager()

    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?

    private let manifestFileName = ".almrecorder-manifest.json"
    private let fileManager: FileManager
    private let session: URLSession

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
    }

    var isModelDownloaded: Bool {
        let directory = RealtimeDictationConfiguration.modelDirectory
        let manifest = RealtimeDictationConfiguration.manifest
        guard let data = try? Data(
            contentsOf: directory.appendingPathComponent(manifestFileName)
        ),
        let stored = try? JSONDecoder().decode(VibeASRBitNetManifest.self, from: data),
        stored == manifest else {
            return false
        }
        return manifest.files.allSatisfy { entry in
            let url = directory.appendingPathComponent(entry.name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else {
                return false
            }
            return Int64(size) >= entry.minimumBytes
        }
    }

    func downloadModel() async throws {
        if isModelDownloaded { return }

        let config = RealtimeDictationConfiguration.self
        let manifest = config.manifest
        let destination = config.modelDirectory
        let staging = config.modelsDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        await update(
            downloading: true,
            progress: 0,
            status: "Preparing VibeVoice ASR BitNet…",
            error: nil
        )

        do {
            for (index, entry) in manifest.files.enumerated() {
                try Task.checkCancellation()
                await update(
                    downloading: true,
                    progress: Double(index) / Double(manifest.files.count),
                    status: "Downloading \(entry.name) (\(index + 1)/\(manifest.files.count))…",
                    error: nil
                )
                let (temporaryURL, response) = try await session.download(
                    from: config.downloadURL(for: entry.name)
                )
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw RealtimeDictationError.serverFailed(
                        "The model host returned an invalid response."
                    )
                }
                let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
                guard Int64(values.fileSize ?? 0) >= entry.minimumBytes else {
                    throw RealtimeDictationError.serverFailed(
                        "Downloaded \(entry.name) is incomplete."
                    )
                }
                try fileManager.moveItem(
                    at: temporaryURL,
                    to: staging.appendingPathComponent(entry.name)
                )
            }

            let data = try JSONEncoder().encode(manifest)
            try data.write(
                to: staging.appendingPathComponent(manifestFileName),
                options: .atomic
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let backup = destination.deletingLastPathComponent().appendingPathComponent(
                ".backup-\(UUID().uuidString)",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
            }
            do {
                try fileManager.moveItem(at: staging, to: destination)
                if fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.removeItem(at: backup)
                }
            } catch {
                if fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                throw error
            }
            await update(
                downloading: false,
                progress: 1,
                status: "VibeVoice ASR BitNet ready",
                error: nil
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            await update(
                downloading: false,
                progress: 0,
                status: "Download failed",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func update(
        downloading: Bool,
        progress: Double,
        status: String,
        error: String?
    ) async {
        await MainActor.run {
            self.isDownloading = downloading
            self.downloadProgress = progress
            self.status = status
            self.errorMessage = error
        }
    }
}
