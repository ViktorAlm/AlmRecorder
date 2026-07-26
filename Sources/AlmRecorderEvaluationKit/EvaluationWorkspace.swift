import Foundation

public enum EvaluationWorkspaceError: LocalizedError, Equatable {
    case emptyOverride
    case repositoryContained(URL)
    case invalidArtifactName(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOverride:
            return "The evaluation workspace override is empty."
        case .repositoryContained:
            return "Evaluation data and results must be stored outside every Git worktree."
        case .invalidArtifactName:
            return "Evaluation artifact names must be a single non-hidden filename."
        }
    }
}

/// A per-user, local-only root for evaluation inputs, labels, gold sets, and results.
///
/// The default lives in the current macOS user's Application Support directory. Developers may
/// override it with `ALMREC_EVALUATION_WORKSPACE`; overrides are rejected when they resolve inside
/// a Git worktree. There is deliberately no repository-relative fallback.
public struct EvaluationWorkspace: Equatable, Sendable {
    public static let environmentKey = "ALMREC_EVALUATION_WORKSPACE"

    public let rootURL: URL

    public init(rootURL: URL) throws {
        let resolved = Self.resolved(rootURL)
        if Self.enclosingGitWorktree(for: resolved) != nil {
            throw EvaluationWorkspaceError.repositoryContained(resolved)
        }
        self.rootURL = resolved
    }

    public static func current(
        applicationName: String = "AlmRecorder",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> EvaluationWorkspace {
        if let override = environment[environmentKey] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw EvaluationWorkspaceError.emptyOverride
            }
            return try EvaluationWorkspace(
                rootURL: URL(fileURLWithPath: trimmed, isDirectory: true)
            )
        }

        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try EvaluationWorkspace(
            rootURL: applicationSupport
                .appendingPathComponent(applicationName, isDirectory: true)
                .appendingPathComponent("DeveloperEvaluation", isDirectory: true)
        )
    }

    public func directory(named name: String) throws -> URL {
        guard Self.isSafeComponent(name) else {
            throw EvaluationWorkspaceError.invalidArtifactName(name)
        }
        return rootURL.appendingPathComponent(name, isDirectory: true)
    }

    public func artifactURL(fileName: String) throws -> URL {
        guard Self.isSafeComponent(fileName) else {
            throw EvaluationWorkspaceError.invalidArtifactName(fileName)
        }
        return rootURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.hasPrefix(".")
            && trimmed != "."
            && trimmed != ".."
            && !trimmed.contains("/")
            && !trimmed.contains("\\")
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func enclosingGitWorktree(for url: URL) -> URL? {
        var cursor = url
        let fileManager = FileManager.default
        while true {
            if fileManager.fileExists(
                atPath: cursor.appendingPathComponent(".git").path
            ) {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path {
                return nil
            }
            cursor = parent
        }
    }
}
