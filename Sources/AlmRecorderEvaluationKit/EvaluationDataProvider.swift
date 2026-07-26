import Foundation

/// A data source supplied by the current developer or app user.
///
/// Implementations own the data. EvaluationKit defines no seed, sample, fallback, or bundled
/// dataset.
public protocol EvaluationDatasetProvider {
    associatedtype Dataset

    func loadEvaluationDataset() throws -> Dataset
}

/// A versioned, data-agnostic container for developer-local evaluation inputs and artifacts.
public struct VersionedEvaluationEnvelope<Payload: Codable>: Codable {
    public let schemaVersion: Int
    public let kind: String
    public let payload: Payload

    public init(schemaVersion: Int, kind: String, payload: Payload) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.payload = payload
    }
}

/// JSON persistence for evaluation artifacts in an externally validated workspace.
public struct JSONEvaluationArtifactStore<Artifact: Codable> {
    public let artifactURL: URL

    public init(workspace: EvaluationWorkspace, fileName: String) throws {
        artifactURL = try workspace.artifactURL(fileName: fileName)
    }

    public func load() throws -> Artifact? {
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: artifactURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Artifact.self, from: data)
    }

    public func save(_ artifact: Artifact) throws {
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifact).write(to: artifactURL, options: .atomic)
    }
}
