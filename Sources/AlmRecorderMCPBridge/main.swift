import Darwin
import Foundation
import MCP
import AlmRecorderMCPProtocol

@main
struct AlmRecorderMCPBridge {
    static func main() async {
        let rpc = LocalRPCClient()
        let server = Server(
            name: "almrecorder",
            version: AlmRecorderMCP.serverVersion,
            title: "AlmRecorder",
            instructions: """
                Browse and search the user's local AlmRecorder library. Use list_recordings for \
                recent or tag-based browsing and search_recordings for transcript questions. \
                get_recording returns compact metadata; when transcript_uri is present, call \
                resources/read on that URI for the complete visible transcript. Check \
                get_library_status before explicit semantic or hybrid search. Content and write \
                access are controlled separately in AlmRecorder Settings. Semantic search never \
                loads or downloads a model implicitly. After a conflict, re-read before retrying.
                Read almrecorder://help for exact mode, filter, permission, and recovery semantics.
                """,
            capabilities: .init(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            ),
            configuration: .strict
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.tools)
        }

        await server.withMethodHandler(CallTool.self) { parameters in
            guard AlmRecorderMCPContract.tool(named: parameters.name) != nil else {
                throw MCPError.invalidParams("Unknown tool: \(parameters.name)")
            }
            do {
                let arguments = parameters.arguments?.mapValues(Self.wireValue) ?? [:]
                try AlmRecorderMCPContract.validateToolArguments(
                    name: parameters.name,
                    arguments: arguments
                )
                let value = try await rpc.call(method: parameters.name, arguments: arguments)
                try AlmRecorderMCPContract.validateToolOutput(
                    name: parameters.name,
                    value: value
                )
                let json = Self.jsonString(value)
                let structured: MCP.Value? = Self.mcpValue(value)
                var content: [Tool.Content] = [
                    .text(text: json, annotations: nil, _meta: nil)
                ]
                for uri in Self.resourceURIs(in: value).prefix(12) {
                    content.append(
                        .resourceLink(
                            uri: uri,
                            name: uri,
                            description: "AlmRecorder resource returned by \(parameters.name)",
                            mimeType: "application/json"
                        )
                    )
                }
                return CallTool.Result(
                    content: content,
                    structuredContent: structured,
                    isError: false
                )
            } catch let error as MCPContractValidationError {
                return try Self.toolErrorResult(
                    code: "invalid_arguments",
                    message: error.localizedDescription,
                    retryable: false
                )
            } catch let error as MCPWireError {
                return try Self.toolErrorResult(
                    code: error.code,
                    message: error.message,
                    retryable: error.retryable,
                    details: error.details
                )
            } catch {
                return .init(
                    content: [
                        .text(
                            text: "AlmRecorder MCP request failed: \(error.localizedDescription)",
                            annotations: nil,
                            _meta: nil
                        )
                    ],
                    isError: true
                )
            }
        }

        await server.withMethodHandler(ListResources.self) { parameters in
            let result = try await rpc.call(
                method: "resources/list",
                arguments: parameters.cursor.map { ["cursor": .string($0)] } ?? [:]
            )
            let resources: [Resource] = result.objectValue?["resources"]?.arrayValue?.compactMap {
                guard let object = $0.objectValue,
                      let uri = object["uri"]?.stringValue,
                      let name = object["name"]?.stringValue else { return nil }
                return Resource(
                    name: name,
                    uri: uri,
                    description: object["description"]?.stringValue,
                    mimeType: object["mime_type"]?.stringValue
                )
            } ?? []
            return .init(
                resources: resources,
                nextCursor: result.objectValue?["next_cursor"]?.stringValue
            )
        }

        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: [
                .init(
                    uriTemplate: "almrecorder://recordings/{recording_id}",
                    name: "Recording",
                    description: "Recording metadata, tags, speakers, linked meetings, and optionally transcript",
                    mimeType: "application/json"
                ),
                .init(
                    uriTemplate: "almrecorder://recordings/{recording_id}/transcript",
                    name: "Recording transcript",
                    description: "Visible transcript utterances with timestamps and speakers",
                    mimeType: "application/json"
                ),
                .init(
                    uriTemplate: "almrecorder://recordings/{recording_id}/comments",
                    name: "Recording comments",
                    description: "Open and resolved comments on a recording",
                    mimeType: "application/json"
                )
            ])
        }

        await server.withMethodHandler(ReadResource.self) { parameters in
            do {
                let value = try await rpc.call(
                    method: "resources/read",
                    arguments: ["uri": .string(parameters.uri)]
                )
                return .init(contents: [
                    .text(Self.jsonString(value), uri: parameters.uri, mimeType: "application/json")
                ])
            } catch let error as MCPWireError {
                switch error.code {
                case "not_found":
                    throw MCPError.serverError(code: -32002, message: error.message)
                case "invalid_arguments":
                    throw MCPError.invalidParams(error.message)
                case "forbidden":
                    throw MCPError.serverError(code: -32003, message: error.message)
                default:
                    throw MCPError.serverError(code: -32000, message: error.message)
                }
            }
        }

        await server.withMethodHandler(ListPrompts.self) { _ in
            .init(prompts: [
                Prompt(
                    name: "prepare_meeting_follow_up",
                    title: "Prepare meeting follow-up",
                    description: "Turn one recording into decisions, action items, and a concise follow-up",
                    arguments: [
                        .init(
                            name: "recording_id",
                            description: "Stable rec_… recording ID from list_recordings",
                            required: true
                        )
                    ]
                ),
                Prompt(
                    name: "weekly_recap",
                    title: "Weekly recording recap",
                    description: "Summarize the past week across recordings, grouped by topic and action",
                    arguments: []
                )
            ])
        }

        await server.withMethodHandler(GetPrompt.self) { parameters in
            switch parameters.name {
            case "prepare_meeting_follow_up":
                guard let id = parameters.arguments?["recording_id"],
                      id.range(of: #"^rec_[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else {
                    throw MCPError.invalidParams("recording_id must be a stable rec_… ID")
                }
                return .init(
                    description: "Prepare a grounded follow-up from one AlmRecorder meeting.",
                    messages: [
                        .user(.text(text: """
                            Read almrecorder://recordings/\(id) and its transcript resource. Produce:
                            1. a short outcome summary,
                            2. decisions with supporting timestamps,
                            3. action items with owners and due dates only when explicit,
                            4. unresolved questions,
                            5. a concise follow-up message.
                            Do not invent commitments. Mention any uncertainty.
                            """))
                    ]
                )
            case "weekly_recap":
                return .init(
                    description: "Review the user's recent AlmRecorder library.",
                    messages: [
                        .user(.text(text: """
                            Use list_recordings with date_from set to seven days ago. Review relevant \
                            recordings and summarize recurring topics, decisions, action items, and \
                            unresolved threads. Cite recording titles and timestamped transcript evidence.
                            """))
                    ]
                )
            default:
                throw MCPError.invalidParams("Unknown prompt: \(parameters.name)")
            }
        }

        do {
            let transport = StdioTransport()
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            FileHandle.standardError.write(
                Data("AlmRecorder MCP bridge failed: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    private static func wireValue(_ value: MCP.Value) -> MCPJSONValue {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .integer(Int64(value))
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .data(let mimeType, let data):
            return .object([
                "mime_type": mimeType.map(MCPJSONValue.string) ?? .null,
                "base64": .string(data.base64EncodedString())
            ])
        case .array(let values): return .array(values.map(wireValue))
        case .object(let values): return .object(values.mapValues(wireValue))
        }
    }

    fileprivate static func mcpValue(_ value: MCPJSONValue) -> MCP.Value {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .integer(let value):
            guard let exact = Int(exactly: value) else { return .double(Double(value)) }
            return .int(exact)
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .array(let values): return .array(values.map(mcpValue))
        case .object(let values): return .object(values.mapValues(mcpValue))
        }
    }

    private static func jsonString(_ value: MCPJSONValue) -> String {
        guard let data = try? MCPWireCoding.encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func toolErrorResult(
        code: String,
        message: String,
        retryable: Bool,
        details: [String: MCPJSONValue]? = nil
    ) throws -> CallTool.Result {
        let detail = MCPJSONValue.object([
            "code": .string(code),
            "message": .string(message),
            "retryable": .bool(retryable),
            "details": details.map(MCPJSONValue.object) ?? .null
        ])
        return try CallTool.Result(
            content: [.text(text: jsonString(detail), annotations: nil, _meta: nil)],
            structuredContent: mcpValue(detail),
            isError: true
        )
    }

    private static func resourceURIs(in value: MCPJSONValue) -> [String] {
        var result: [String] = []
        func visit(_ value: MCPJSONValue) {
            switch value {
            case .array(let values):
                values.forEach(visit)
            case .object(let object):
                for (key, child) in object {
                    if key == "uri" || key.hasSuffix("_uri"),
                       let uri = child.stringValue,
                       uri.hasPrefix("almrecorder://"),
                       !result.contains(uri) {
                        result.append(uri)
                    } else {
                        visit(child)
                    }
                }
            default:
                break
            }
        }
        visit(value)
        return result
    }
}

private final class LocalRPCClient: @unchecked Sendable {
    private let token = ProcessInfo.processInfo.environment["ALMRECORDER_MCP_TOKEN"]
    private let socketPath = ProcessInfo.processInfo.environment["ALMRECORDER_MCP_SOCKET"]
        ?? AlmRecorderMCP.defaultSocketURL.path

    func call(
        method: String,
        arguments: [String: MCPJSONValue] = [:]
    ) async throws -> MCPJSONValue {
        guard let token, !token.isEmpty else {
            throw MCPWireError(
                code: "configuration_error",
                message: "ALMRECORDER_MCP_TOKEN is missing. Copy the client configuration from AlmRecorder Settings → MCP."
            )
        }
        let request = MCPWireRequest(
            token: token,
            method: method,
            arguments: arguments
        )
        let cancellation = LocalRPCCancellationState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                do {
                    return try Self.perform(
                        request: request,
                        socketPath: self.socketPath,
                        cancellation: cancellation
                    )
                } catch {
                    if cancellation.cancelled {
                        throw CancellationError()
                    }
                    throw error
                }
            }.value
        } onCancel: {
            cancellation.cancel()
            Task.detached(priority: .userInitiated) {
                // Cancellation can race the app accepting the primary connection. Retry a few
                // times so the app-owned Task is cancelled, not merely its bridge socket.
                for _ in 0..<3 {
                    if (try? Self.sendCancellation(
                        requestId: request.id,
                        token: token,
                        socketPath: self.socketPath
                    )) == true {
                        return
                    }
                    usleep(20_000)
                }
            }
        }
    }

    private static func perform(
        request: MCPWireRequest,
        socketPath: String,
        cancellation: LocalRPCCancellationState?
    ) throws -> MCPJSONValue {
        let fd = try connect(path: socketPath)
        guard cancellation?.attach(fd) ?? true else {
            Darwin.close(fd)
            throw CancellationError()
        }
        defer {
            cancellation?.detach(fd)
            Darwin.close(fd)
        }
        configure(fd)
        var data = try MCPWireCoding.encoder.encode(request)
        data.append(0x0A)
        try writeAll(data, to: fd)
        guard let responseData = readLine(
            from: fd,
            maximumBytes: AlmRecorderMCP.maximumResponseBytes
        ) else {
            throw MCPWireError(
                code: "app_unavailable",
                message: "AlmRecorder closed the local MCP connection without a response.",
                retryable: true
            )
        }
        let response = try MCPWireCoding.decoder.decode(MCPWireResponse.self, from: responseData)
        if let error = response.error { throw error }
        guard let result = response.result else {
            throw MCPWireError(code: "invalid_response", message: "AlmRecorder returned no result.")
        }
        return result
    }

    private static func sendCancellation(
        requestId: String,
        token: String,
        socketPath: String
    ) throws -> Bool {
        let result = try perform(
            request: MCPWireRequest(
                token: token,
                method: AlmRecorderMCP.cancellationMethod,
                arguments: ["request_id": .string(requestId)]
            ),
            socketPath: socketPath,
            cancellation: nil
        )
        return result.objectValue?["cancelled"]?.boolValue ?? false
    }

    private static func configure(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(
                fd, SOL_SOCKET, SO_RCVTIMEO, $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
            _ = setsockopt(
                fd, SOL_SOCKET, SO_SNDTIMEO, $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

    private static func connect(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPWireError(code: "socket_error", message: String(cString: strerror(errno)))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw MCPWireError(code: "configuration_error", message: "The MCP socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw MCPWireError(
                code: "app_unavailable",
                message: "Could not connect to AlmRecorder. Open the app and enable MCP in Settings. \(String(cString: strerror(code)))",
                retryable: true
            )
        }
        return fd
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw MCPWireError(code: "socket_error", message: String(cString: strerror(errno)))
                }
                sent += count
            }
        }
    }

    private static func readLine(from fd: Int32, maximumBytes: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximumBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<newline])
                break
            }
            data.append(contentsOf: buffer[..<count])
        }
        return data.isEmpty || data.count > maximumBytes ? nil : data
    }
}

private final class LocalRPCCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private var didCancel = false

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
    }

    func attach(_ descriptor: Int32) -> Bool {
        lock.lock()
        self.descriptor = descriptor
        let active = !didCancel
        lock.unlock()
        if !active {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        return active
    }

    func detach(_ descriptor: Int32) {
        lock.lock()
        if self.descriptor == descriptor {
            self.descriptor = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        didCancel = true
        let descriptor = descriptor
        lock.unlock()
        if let descriptor {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }
}

private enum ToolCatalog {
    static let tools: [Tool] = AlmRecorderMCPContract.tools.map { definition in
        Tool(
            name: definition.name,
            title: definition.title,
            description: definition.description,
            inputSchema: AlmRecorderMCPBridge.mcpValue(definition.inputSchema),
            annotations: Tool.Annotations(
                readOnlyHint: definition.effects.readOnly,
                destructiveHint: definition.effects.destructive,
                idempotentHint: definition.effects.idempotent,
                openWorldHint: definition.effects.openWorld
            ),
            outputSchema: AlmRecorderMCPBridge.mcpValue(definition.outputSchema)
        )
    }

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )
    private static let additiveWrite = Tool.Annotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )
    private static let nonIdempotentAdditiveWrite = Tool.Annotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false
    )
    private static let mutatingWrite = Tool.Annotations(
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false
    )

    // Kept temporarily as an implementation-history reference while the contract migration lands.
    // It is never published; `tools` above is the shared app/bridge contract.
    private static let legacyTools: [Tool] = [
        tool(
            "get_library_status",
            "Get library status",
            "Return recording/tag/comment counts and whether local semantic search is ready.",
            properties: [:],
            annotations: readOnly
        ),
        tool(
            "list_recordings",
            "List recordings",
            "Browse recent recordings with stable cursor pagination and optional tag, speaker, source, date, and title/transcript filters. All supplied tags must match.",
            properties: recordingFilters([
                "cursor": string("Opaque cursor returned by a previous call"),
                "limit": integer("Page size, 1–100", minimum: 1, maximum: 100)
            ]),
            annotations: readOnly
        ),
        tool(
            "get_recording",
            "Get recording",
            "Return one recording with tags, speakers, linked meetings, comments count, and a transcript resource URI when allowed.",
            properties: ["recording_id": string("Stable rec_… recording ID")],
            required: ["recording_id"],
            annotations: readOnly
        ),
        tool(
            "search_recordings",
            "Search recordings",
            "Search visible transcript utterances. auto uses hybrid search only when the local model is already loaded, otherwise exact; MCP never downloads a model.",
            properties: recordingFilters([
                "query": string("Text to search for"),
                "mode": enumeration(["auto", "exact", "semantic", "hybrid"], "Search strategy"),
                "limit": integer("Maximum hits, 1–50", minimum: 1, maximum: 50)
            ]),
            required: ["query"],
            annotations: readOnly
        ),
        tool(
            "list_tags",
            "List tags",
            "List every tag, description, color, stable ID, and recording count.",
            properties: [:],
            annotations: readOnly
        ),
        tool(
            "get_meeting_notes",
            "Get meeting notes",
            "Read agenda and notes by calendar event ID, or for all meetings linked to a recording.",
            properties: [
                "calendar_event_id": string("Apple Calendar event ID"),
                "recording_id": string("Stable rec_… recording ID")
            ],
            annotations: readOnly
        ),
        tool(
            "list_comments",
            "List recording comments",
            "List open and/or resolved comments, including timestamp anchors.",
            properties: [
                "recording_id": string("Stable rec_… recording ID"),
                "status": enumeration(["open", "resolved"], "Optional status filter")
            ],
            required: ["recording_id"],
            annotations: readOnly
        ),
        tool(
            "add_recording_tags",
            "Add recording tags",
            "Attach existing tags to a recording. Accepts stable tag IDs or exact names.",
            properties: [
                "recording_id": string("Stable rec_… recording ID"),
                "tags": stringArray("One or more tag IDs or names", maximum: 100)
            ],
            required: ["recording_id", "tags"],
            annotations: additiveWrite
        ),
        tool(
            "remove_recording_tags",
            "Remove recording tags",
            "Detach existing tags from a recording. Accepts stable tag IDs or exact names.",
            properties: [
                "recording_id": string("Stable rec_… recording ID"),
                "tags": stringArray("One or more tag IDs or names", maximum: 100)
            ],
            required: ["recording_id", "tags"],
            annotations: mutatingWrite
        ),
        tool(
            "update_meeting_notes",
            "Update meeting notes",
            "Update agenda and/or notes. Pass if_updated_at from the read result to prevent overwriting newer edits.",
            properties: [
                "calendar_event_id": string("Apple Calendar event ID"),
                "agenda": string("Replacement agenda"),
                "notes": string("Replacement notes"),
                "if_updated_at": string("Optional ISO-8601 optimistic-concurrency timestamp")
            ],
            required: ["calendar_event_id"],
            annotations: mutatingWrite
        ),
        tool(
            "add_comment",
            "Add recording comment",
            "Add a comment, optionally anchored to transcript times. Reusing idempotency_key returns the original comment.",
            properties: [
                "recording_id": string("Stable rec_… recording ID"),
                "body": string("Comment body, 1–20,000 characters"),
                "anchor_start": number("Optional start time in seconds", minimum: 0),
                "anchor_end": number("Optional end time in seconds", minimum: 0),
                "source_utterance_id": integer("Optional source utterance ID", minimum: 1),
                "idempotency_key": string("Caller-generated key for safe retries")
            ],
            required: ["recording_id", "body"],
            annotations: nonIdempotentAdditiveWrite
        ),
        tool(
            "update_comment",
            "Update comment",
            "Replace a comment body and/or anchors, with optional optimistic concurrency.",
            properties: [
                "comment_id": string("Stable cmt_… comment ID"),
                "body": string("Replacement body"),
                "anchor_start": nullableNumber("Replacement start time, or null to clear", minimum: 0),
                "anchor_end": nullableNumber("Replacement end time, or null to clear", minimum: 0),
                "if_updated_at": string("Optional ISO-8601 optimistic-concurrency timestamp")
            ],
            required: ["comment_id"],
            annotations: mutatingWrite
        ),
        tool(
            "set_comment_status",
            "Set comment status",
            "Resolve or reopen a comment, with optional optimistic concurrency.",
            properties: [
                "comment_id": string("Stable cmt_… comment ID"),
                "status": enumeration(["open", "resolved"], "New status"),
                "if_updated_at": string("Optional ISO-8601 optimistic-concurrency timestamp")
            ],
            required: ["comment_id", "status"],
            annotations: mutatingWrite
        )
    ]

    private static func recordingFilters(
        _ additions: [String: MCP.Value]
    ) -> [String: MCP.Value] {
        var value: [String: MCP.Value] = [
            "tags": stringArray("Tag IDs or names; all must match", maximum: 100),
            "speaker_id": string("Speaker UUID"),
            "source": enumeration(["recording", "voiceMemos", "imported"], "Recording source"),
            "date_from": string("Inclusive ISO-8601 timestamp"),
            "date_to": string("Inclusive ISO-8601 timestamp"),
            "text": string("Optional title/transcript filter for browsing")
        ]
        value.merge(additions) { _, new in new }
        return value
    }

    private static func tool(
        _ name: String,
        _ title: String,
        _ description: String,
        properties: [String: MCP.Value],
        required: [String] = [],
        annotations: Tool.Annotations
    ) -> Tool {
        var schema: [String: MCP.Value] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(MCP.Value.string))
        }
        return Tool(
            name: name,
            title: title,
            description: description,
            inputSchema: .object(schema),
            annotations: annotations,
            outputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(true)
            ])
        )
    }

    private static func string(_ description: String) -> MCP.Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func number(
        _ description: String,
        minimum: Int? = nil
    ) -> MCP.Value {
        var object: [String: MCP.Value] = [
            "type": .string("number"),
            "description": .string(description)
        ]
        if let minimum { object["minimum"] = .int(minimum) }
        return .object(object)
    }

    private static func integer(
        _ description: String,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> MCP.Value {
        var object: [String: MCP.Value] = [
            "type": .string("integer"),
            "description": .string(description)
        ]
        if let minimum { object["minimum"] = .int(minimum) }
        if let maximum { object["maximum"] = .int(maximum) }
        return .object(object)
    }

    private static func nullableNumber(
        _ description: String,
        minimum: Int? = nil
    ) -> MCP.Value {
        var object: [String: MCP.Value] = [
            "type": .array([.string("number"), .string("null")]),
            "description": .string(description)
        ]
        if let minimum { object["minimum"] = .int(minimum) }
        return .object(object)
    }

    private static func enumeration(_ values: [String], _ description: String) -> MCP.Value {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(MCP.Value.string)),
            "description": .string(description)
        ])
    }

    private static func stringArray(_ description: String, maximum: Int) -> MCP.Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "minItems": .int(1),
            "maxItems": .int(maximum),
            "description": .string(description)
        ])
    }
}
