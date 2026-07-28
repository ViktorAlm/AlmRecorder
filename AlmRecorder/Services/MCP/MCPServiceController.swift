import Combine
import Foundation
import Security
import AlmRecorderMCPProtocol

struct MCPClientCredential: Codable, Sendable {
    var clientId: String
    var displayName: String
    var token: String
    var allowTranscripts: Bool
    var allowWrites: Bool
    var createdAt: Date
    var rotatedAt: Date?
    var authorizationRevision: String?

    static func fresh() -> MCPClientCredential {
        MCPClientCredential(
            clientId: "local-client",
            displayName: "Local MCP client",
            token: secureToken(),
            allowTranscripts: false,
            allowWrites: false,
            createdAt: Date(),
            rotatedAt: nil,
            authorizationRevision: UUID().uuidString
        )
    }

    private static func secureToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
    }
}

final class MCPAuthorizationStore: @unchecked Sendable {
    static let shared = MCPAuthorizationStore()
    private let lock = NSLock()
    private var credential: MCPClientCredential

    private init() {
        var loaded = Self.load() ?? .fresh()
        if loaded.authorizationRevision == nil {
            loaded.authorizationRevision = UUID().uuidString
        }
        credential = loaded
        try? Self.save(credential)
    }

    func current() -> MCPClientCredential {
        lock.lock()
        defer { lock.unlock() }
        return credential
    }

    func update(_ mutate: (inout MCPClientCredential) -> Void) throws -> MCPClientCredential {
        lock.lock()
        defer { lock.unlock() }
        var staged = credential
        mutate(&staged)
        staged.authorizationRevision = UUID().uuidString
        try Self.save(staged)
        credential = staged
        return credential
    }

    func authorize(token: String) -> RecordingLibraryAPI.Access? {
        let value = current()
        guard Self.constantTimeEqual(token, value.token) else { return nil }
        return RecordingLibraryAPI.Access(
            transcripts: value.allowTranscripts,
            writes: value.allowWrites,
            clientId: value.clientId,
            authorizationRevision: value.authorizationRevision ?? "",
            privacyRevision: MCPPrivacyRevisionStore.shared.snapshot()
        )
    }

    func remainsAuthorized(
        _ access: RecordingLibraryAPI.Access,
        content: Bool = false,
        write: Bool = false
    ) -> Bool {
        let value = current()
        guard value.clientId == access.clientId,
              value.authorizationRevision == access.authorizationRevision,
              MCPPrivacyRevisionStore.shared.snapshot() == access.privacyRevision else {
            return false
        }
        if content && !value.allowTranscripts { return false }
        if write && !value.allowWrites { return false }
        return true
    }

    private static func load() -> MCPClientCredential? {
        guard let data = try? Data(contentsOf: AlmRecorderMCP.defaultCredentialsURL) else {
            return nil
        }
        return try? MCPWireCoding.decoder.decode(MCPClientCredential.self, from: data)
    }

    private static func save(_ credential: MCPClientCredential) throws {
        let directory = AlmRecorderMCP.defaultDirectoryURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try MCPWireCoding.encoder.encode(credential)
        try data.write(to: AlmRecorderMCP.defaultCredentialsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AlmRecorderMCP.defaultCredentialsURL.path
        )
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        let count = max(a.count, b.count)
        for index in 0..<count {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            difference |= av ^ bv
        }
        return difference == 0
    }
}

@MainActor
final class MCPServiceController: ObservableObject {
    static let shared = MCPServiceController()
    static let enabledDefaultsKey = "mcpServerEnabled"

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Stopped"
    @Published private(set) var credential: MCPClientCredential

    private var server: MCPUnixSocketServer?
    private var privacyObserver: AnyCancellable?

    private init() {
        credential = MCPAuthorizationStore.shared.current()
        privacyObserver = NotificationCenter.default.publisher(
            for: .mcpRecordingPrivacyDidChange
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.server?.cancelActiveRequests()
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        enabled ? start() : stop()
    }

    func setTranscriptAccess(_ enabled: Bool) {
        updateCredential { $0.allowTranscripts = enabled }
    }

    func setWriteAccess(_ enabled: Bool) {
        updateCredential { $0.allowWrites = enabled }
    }

    func rotateToken() {
        updateCredential {
            var replacement = MCPClientCredential.fresh()
            replacement.clientId = $0.clientId
            replacement.displayName = $0.displayName
            replacement.allowTranscripts = $0.allowTranscripts
            replacement.allowWrites = $0.allowWrites
            replacement.createdAt = $0.createdAt
            replacement.rotatedAt = Date()
            replacement.authorizationRevision = UUID().uuidString
            $0 = replacement
        }
    }

    func start() {
        guard server == nil else { return }
        do {
            let server = MCPUnixSocketServer()
            try server.start()
            self.server = server
            isRunning = true
            statusMessage = "Listening on \(AlmRecorderMCP.defaultSocketURL.path)"
        } catch {
            isRunning = false
            statusMessage = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    var clientConfigurationJSON: String {
        let executable: String
        if Bundle.main.bundleURL.pathExtension == "app" {
            executable = Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/AlmRecorderMCPBridge").path
        } else {
            executable = Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("AlmRecorderMCPBridge").path
                ?? "AlmRecorderMCPBridge"
        }
        let object: [String: Any] = [
            "mcpServers": [
                "almrecorder": [
                    "command": executable,
                    "env": [
                        "ALMRECORDER_MCP_TOKEN": credential.token,
                        "ALMRECORDER_MCP_SOCKET": AlmRecorderMCP.defaultSocketURL.path
                    ]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func updateCredential(_ mutate: (inout MCPClientCredential) -> Void) {
        do {
            credential = try MCPAuthorizationStore.shared.update(mutate)
            server?.cancelActiveRequests()
        } catch {
            statusMessage = "Could not save MCP credentials: \(error.localizedDescription)"
        }
    }
}
