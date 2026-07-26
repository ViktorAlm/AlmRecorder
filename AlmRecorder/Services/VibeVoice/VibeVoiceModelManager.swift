import Combine
import Foundation

/// Downloads the immutable, multi-file MLX snapshot into staging and only publishes it after every
/// required file validates. This prevents a partial model from looking installed after a crash.
final class VibeVoiceModelManager: ObservableObject {
    static let shared = VibeVoiceModelManager()

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

    func isModelDownloaded(_ quantization: VibeVoiceQuantization) -> Bool {
        let directory = VibeVoiceConfiguration.modelDirectory(for: quantization)
        let manifest = VibeVoiceConfiguration.manifest(for: quantization)
        guard let storedData = try? Data(
            contentsOf: directory.appendingPathComponent(manifestFileName)
        ),
        let stored = try? JSONDecoder().decode(VibeVoiceModelManifest.self, from: storedData),
        stored == manifest else {
            return false
        }
        return manifest.files.allSatisfy { entry in
            let url = directory.appendingPathComponent(entry.name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return false }
            return Int64(size) >= entry.minimumBytes
        }
    }

    func downloadedQuantizations() -> [VibeVoiceQuantization] {
        VibeVoiceQuantization.allCases.filter(isModelDownloaded)
    }

    func downloadModel(_ quantization: VibeVoiceQuantization) async throws {
        if isModelDownloaded(quantization) { return }

        let manifest = VibeVoiceConfiguration.manifest(for: quantization)
        let parent = VibeVoiceConfiguration.modelsDirectory
        let destination = VibeVoiceConfiguration.modelDirectory(for: quantization)
        let staging = parent.appendingPathComponent(
            ".staging-\(quantization.rawValue)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        await updateState(
            isDownloading: true,
            progress: 0,
            status: "Preparing \(quantization.displayName)…",
            error: nil
        )

        do {
            for (index, entry) in manifest.files.enumerated() {
                try Task.checkCancellation()
                await updateState(
                    isDownloading: true,
                    progress: Double(index) / Double(manifest.files.count),
                    status: "Downloading \(entry.name) (\(index + 1)/\(manifest.files.count))…",
                    error: nil
                )

                let remote = VibeVoiceConfiguration.downloadURL(
                    quantization: quantization,
                    fileName: entry.name
                )
                let (temporaryURL, response) = try await session.download(from: remote)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw TranscriptionError.downloadFailed
                }
                let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
                guard Int64(values.fileSize ?? 0) >= entry.minimumBytes else {
                    throw TranscriptionError.transcriptionFailed(
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

            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
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

            await updateState(
                isDownloading: false,
                progress: 1,
                status: "\(quantization.displayName) ready",
                error: nil
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            await updateState(
                isDownloading: false,
                progress: 0,
                status: "Download failed",
                error: error.localizedDescription
            )
            throw error
        }
    }

    func deleteModel(_ quantization: VibeVoiceQuantization) throws {
        let directory = VibeVoiceConfiguration.modelDirectory(for: quantization)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func updateState(
        isDownloading: Bool,
        progress: Double,
        status: String,
        error: String?
    ) async {
        await MainActor.run {
            self.isDownloading = isDownloading
            self.downloadProgress = progress
            self.status = status
            self.errorMessage = error
        }
    }
}
