import Foundation

/// A data source supplied by the current developer or app user.
///
/// Implementations own the data. EvaluationKit defines no seed, sample, fallback, or bundled
/// dataset.
public protocol EvaluationDatasetProvider {
    associatedtype Dataset

    func loadEvaluationDataset() throws -> Dataset
}

public enum DeveloperEvaluationDatasetError: LocalizedError {
    case missing(URL)
    case unsupportedSchema(expected: Int, actual: Int)
    case unexpectedKind(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .missing(let url):
            return "No private evaluation dataset was found at \(url.path)."
        case .unsupportedSchema(let expected, let actual):
            return "Evaluation schema \(actual) is unsupported; expected \(expected)."
        case .unexpectedKind(let expected, let actual):
            return "Evaluation dataset kind “\(actual)” does not match “\(expected)”."
        }
    }
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

/// Loads one developer's private dataset from the external evaluation workspace.
///
/// The schema and loader live in the repository; the payload never does. This deliberately has no
/// repository-relative fallback, network download, sample corpus, or synthesized substitute.
public struct JSONDeveloperEvaluationDatasetStore<Dataset: Codable> {
    public let datasetURL: URL
    public let schemaVersion: Int
    public let kind: String

    public init(
        workspace: EvaluationWorkspace,
        fileName: String,
        schemaVersion: Int,
        kind: String
    ) throws {
        datasetURL = try workspace.artifactURL(fileName: fileName)
        self.schemaVersion = schemaVersion
        self.kind = kind
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: datasetURL.path)
    }

    /// Optional loading is useful for normal CI, where private data is expected to be absent.
    public func loadIfAvailable() throws -> Dataset? {
        guard isAvailable else { return nil }
        return try loadRequired()
    }

    /// Required loading is used by explicitly requested local benchmark runs.
    public func loadRequired() throws -> Dataset {
        guard isAvailable else {
            throw DeveloperEvaluationDatasetError.missing(datasetURL)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            VersionedEvaluationEnvelope<Dataset>.self,
            from: Data(contentsOf: datasetURL)
        )
        guard envelope.schemaVersion == schemaVersion else {
            throw DeveloperEvaluationDatasetError.unsupportedSchema(
                expected: schemaVersion,
                actual: envelope.schemaVersion
            )
        }
        guard envelope.kind == kind else {
            throw DeveloperEvaluationDatasetError.unexpectedKind(
                expected: kind,
                actual: envelope.kind
            )
        }
        return envelope.payload
    }
}
