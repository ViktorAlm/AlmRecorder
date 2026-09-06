import Foundation

struct VibeVoiceModelManifest: Codable, Equatable {
    struct FileEntry: Codable, Equatable {
        let name: String
        let minimumBytes: Int64
    }

    let repositoryID: String
    let revision: String
    let tokenizerRepositoryID: String
    let tokenizerRevision: String
    let mlxAudioRevision: String
    let files: [FileEntry]
}

enum VibeVoiceConfiguration {
    /// Revision tested by AlmRecorder. Runtime setup scripts install this exact commit rather than
    /// following a moving PyPI/GitHub release.
    static let mlxAudioRevision = "9b50bf46577ab547e536b60179f3345c9f73ce41"
    static let tokenizerRepositoryID = "Qwen/Qwen2.5-7B"
    static let tokenizerRevision = "d149729398750b98c0af14eb82c78cfe92750796" // gitleaks:allow -- public commit.

    /// VibeVoice's generation cache grows with audio duration. A 55-minute 4-bit pass reached
    /// 15.1 GB RSS on a 24 GB Mac during the 2026-07-27 compressor/swap watchdog panic, while the
    /// 12-minute gold benchmark peaked at 9.64 GB. Bound each pass so long conversations cannot
    /// silently turn a nominally 5.7 GB model into a system-sized allocation.
    static let maximumSinglePassDuration: TimeInterval = 18 * 60
    static let longRecordingTargetDuration: TimeInterval = 15 * 60
    static let helperSchemaVersion = 1

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlmRecorder/Models/VibeVoice", isDirectory: true)
    }

    static func modelRevision(for quantization: VibeVoiceQuantization) -> String {
        switch quantization {
        case .fourBit: return "a1a15cb6c7b70f76b588af7e12f6fab34d5ab654"
        case .sixBit: return "c49a90a728418da9a315be05cfd526a2bbe77a5c"
        case .eightBit: return "725c72e54d6ef875472c27fbc50fab470a960940"
        }
    }

    static func manifest(for quantization: VibeVoiceQuantization) -> VibeVoiceModelManifest {
        let shardSizes: (Int64, Int64)
        switch quantization {
        case .fourBit:
            shardSizes = (5_366_951_429, 346_896_560)
        case .sixBit:
            shardSizes = (5_360_114_475, 2_257_554_265)
        case .eightBit:
            shardSizes = (5_331_193_271, 4_190_296_379)
        }
        return VibeVoiceModelManifest(
            repositoryID: quantization.repositoryID,
            revision: modelRevision(for: quantization),
            tokenizerRepositoryID: tokenizerRepositoryID,
            tokenizerRevision: tokenizerRevision,
            mlxAudioRevision: mlxAudioRevision,
            files: [
                .init(name: "config.json", minimumBytes: 4_372),
                .init(name: "model.safetensors.index.json", minimumBytes: 130_385),
                .init(
                    name: "model-00001-of-00002.safetensors",
                    minimumBytes: shardSizes.0
                ),
                .init(
                    name: "model-00002-of-00002.safetensors",
                    minimumBytes: shardSizes.1
                ),
                .init(name: "tokenizer.json", minimumBytes: 7_031_645),
                .init(name: "tokenizer_config.json", minimumBytes: 7_228),
                .init(name: "merges.txt", minimumBytes: 1_671_839),
                .init(name: "vocab.json", minimumBytes: 2_776_833)
            ]
        )
    }

    static func modelDirectory(for quantization: VibeVoiceQuantization) -> URL {
        modelsDirectory
            .appendingPathComponent(quantization.rawValue, isDirectory: true)
            .appendingPathComponent(modelRevision(for: quantization), isDirectory: true)
    }

    static func downloadURL(
        quantization: VibeVoiceQuantization,
        fileName: String
    ) -> URL {
        let isTokenizerFile = [
            "tokenizer.json",
            "tokenizer_config.json",
            "merges.txt",
            "vocab.json"
        ].contains(fileName)
        let repositoryID = isTokenizerFile
            ? tokenizerRepositoryID
            : quantization.repositoryID
        let revision = isTokenizerFile
            ? tokenizerRevision
            : modelRevision(for: quantization)
        return URL(
            string: "https://huggingface.co/\(repositoryID)/resolve/\(revision)/\(fileName)"
        )!
    }
}
