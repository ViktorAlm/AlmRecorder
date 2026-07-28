import Foundation

struct VibeASRBitNetManifest: Codable, Equatable {
    struct FileEntry: Codable, Equatable {
        let name: String
        let minimumBytes: Int64
    }

    let repositoryID: String
    let revision: String
    let files: [FileEntry]
}

enum RealtimeDictationConfiguration {
    static let sampleRate = 24_000
    static let windowDuration: TimeInterval = 2.0
    static let overlapDuration: TimeInterval = 0.35
    static let minimumFinalWindowDuration: TimeInterval = 0.35

    static let repositoryID = "microsoft/VibeVoice-ASR-BitNet"
    // Public Hugging Face commit tested with microsoft/VibeASR.cpp at the pinned submodule commit.
    static let modelRevision = "66e78021ab8f5f06133d1ab421ba4d348bda97c9"
    static let serverCommit = "4af6a72174b775af0ef108a8ddcb881c72ea9995"

    static let vaeFileName = "vibeasr-vae-encoder-i8_s.gguf"
    static let languageModelFileName = "vibeasr-lm-i2_s-embed-q6_k.gguf"

    static let manifest = VibeASRBitNetManifest(
        repositoryID: repositoryID,
        revision: modelRevision,
        files: [
            .init(name: vaeFileName, minimumBytes: 703_080_064),
            .init(name: languageModelFileName, minimumBytes: 992_877_600)
        ]
    )

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlmRecorder/Models/VibeASRBitNet", isDirectory: true)
    }

    static var modelDirectory: URL {
        modelsDirectory.appendingPathComponent(modelRevision, isDirectory: true)
    }

    static var vaeModelURL: URL {
        modelDirectory.appendingPathComponent(vaeFileName)
    }

    static var languageModelURL: URL {
        modelDirectory.appendingPathComponent(languageModelFileName)
    }

    static func downloadURL(for fileName: String) -> URL {
        URL(
            string: "https://huggingface.co/\(repositoryID)/resolve/\(modelRevision)/\(fileName)"
        )!
    }

    static func resolveServerExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fileManager = FileManager.default
        if let override = environment["ALMREC_VIBEASR_SERVER"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let candidates: [URL?] = [
            Bundle.main.url(
                forResource: "vibeasr-stream-server",
                withExtension: nil,
                subdirectory: "Binaries"
            ),
            Bundle.main.url(forResource: "vibeasr-stream-server", withExtension: nil),
            URL(
                fileURLWithPath:
                    "\(DevPaths.repoRoot)/External/VibeASR.cpp/build/bin/asr_stream_server"
            ),
            URL(
                fileURLWithPath:
                    "\(DevPaths.repoRoot)/AlmRecorder/Resources/Binaries/vibeasr-stream-server"
            )
        ]
        return candidates.compactMap { $0 }.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }
}

enum RealtimeDictationError: LocalizedError {
    case accessibilityPermissionRequired
    case microphonePermissionRequired
    case modelNotDownloaded
    case serverNotInstalled
    case serverFailed(String)
    case serverClosed
    case serverBusy
    case audioConversionFailed(String)
    case secureTextField
    case noText

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility access is required to monitor the dictation shortcut and insert text."
        case .microphonePermissionRequired:
            return "Microphone access is required for realtime dictation."
        case .modelNotDownloaded:
            return "The VibeVoice ASR BitNet model has not been downloaded."
        case .serverNotInstalled:
            return "The VibeASR realtime runtime is not installed. Run Scripts/package_vibeasr_bitnet.sh."
        case .serverFailed(let detail):
            return "VibeASR failed: \(detail)"
        case .serverClosed:
            return "The VibeASR process closed unexpectedly."
        case .serverBusy:
            return "VibeASR is already processing an audio window."
        case .audioConversionFailed(let detail):
            return "Could not prepare microphone audio: \(detail)"
        case .secureTextField:
            return "Dictation is disabled for secure text fields."
        case .noText:
            return "No speech was recognized."
        }
    }
}
