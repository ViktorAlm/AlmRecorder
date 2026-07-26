import Darwin
import Foundation
import AlmRecorderMCPProtocol

final class MCPUnixSocketServer: @unchecked Sendable {
    enum SocketError: LocalizedError {
        case pathTooLong
        case operation(String, Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong:
                return "The MCP Unix socket path is too long."
            case .operation(let operation, let code):
                return "\(operation) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    private let acceptQueue = DispatchQueue(label: "com.almrecorder.mcp.accept", qos: .utility)
    private let clientQueue = DispatchQueue(
        label: "com.almrecorder.mcp.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private let clientSlots = DispatchSemaphore(value: 16)
    private let invocationLimiter = MCPInvocationLimiter()
    private let activeRequests = MCPActiveRequestRegistry()
    private var descriptor: Int32 = -1
    private var stopped = false

    func start() throws {
        let directory = AlmRecorderMCP.defaultDirectoryURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        unlink(AlmRecorderMCP.defaultSocketURL.path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.operation("socket", errno) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))

        do {
            try Self.bind(fd: fd, path: AlmRecorderMCP.defaultSocketURL.path)
            guard Darwin.listen(fd, 16) == 0 else {
                throw SocketError.operation("listen", errno)
            }
            chmod(AlmRecorderMCP.defaultSocketURL.path, 0o600)
        } catch {
            Darwin.close(fd)
            unlink(AlmRecorderMCP.defaultSocketURL.path)
            throw error
        }

        stateLock.lock()
        descriptor = fd
        stopped = false
        stateLock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop(fd: fd) }
    }

    func stop() {
        activeRequests.cancelAll()
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let fd = descriptor
        descriptor = -1
        stateLock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        unlink(AlmRecorderMCP.defaultSocketURL.path)
    }

    func cancelActiveRequests() {
        activeRequests.cancelAll()
    }

    deinit {
        stop()
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                stateLock.lock()
                let shouldStop = stopped
                stateLock.unlock()
                if shouldStop { return }
                if errno == EINTR { continue }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            )
            Self.applyTimeouts(to: client)
            guard clientSlots.wait(timeout: .now()) == .success else {
                Darwin.close(client)
                continue
            }
            clientQueue.async { [weak self] in
                guard let self else {
                    Darwin.close(client)
                    return
                }
                self.handle(client) {
                    self.clientSlots.signal()
                }
            }
        }
    }

    private func handle(_ client: Int32, completion: @escaping @Sendable () -> Void) {
        guard let requestData = Self.readLine(
            from: client,
            maximumBytes: AlmRecorderMCP.maximumRequestBytes
        ) else {
            Darwin.close(client)
            completion()
            return
        }
        let request: MCPWireRequest
        do {
            request = try MCPWireCoding.decoder.decode(MCPWireRequest.self, from: requestData)
        } catch {
            let response = MCPWireResponse(
                id: "invalid",
                error: MCPWireError(code: "invalid_request", message: "The local request was not valid JSON.")
            )
            Self.write(response, to: client)
            Darwin.close(client)
            completion()
            return
        }

        guard let access = MCPAuthorizationStore.shared.authorize(token: request.token) else {
            let response = MCPWireResponse(
                id: request.id,
                error: MCPWireError(code: "unauthorized", message: "Invalid AlmRecorder MCP token.")
            )
            Self.write(response, to: client)
            Darwin.close(client)
            completion()
            return
        }

        if request.method == AlmRecorderMCP.cancellationMethod {
            guard let requestId = request.arguments["request_id"]?.stringValue,
                  !requestId.isEmpty else {
                Self.write(
                    MCPWireResponse(
                        id: request.id,
                        error: MCPWireError(
                            code: "invalid_arguments",
                            message: "request_id is required."
                        )
                    ),
                    to: client
                )
                Darwin.close(client)
                completion()
                return
            }
            let cancelled = activeRequests.cancel(
                requestId: requestId,
                clientId: access.clientId
            )
            Self.write(
                MCPWireResponse(
                    id: request.id,
                    result: .object(["cancelled": .bool(cancelled)])
                ),
                to: client
            )
            Darwin.close(client)
            completion()
            return
        }

        guard invocationLimiter.begin(clientId: access.clientId, method: request.method) else {
            let response = MCPWireResponse(
                id: request.id,
                error: MCPWireError(
                    code: "rate_limited",
                    message: "Too many local MCP requests. Retry after current work completes.",
                    retryable: true
                )
            )
            Self.write(response, to: client)
            Self.audit(
                clientId: access.clientId,
                method: request.method,
                arguments: request.arguments,
                success: false,
                errorCode: "rate_limited",
                durationMilliseconds: 0,
                responseBytes: Self.encodedSize(response)
            )
            Darwin.close(client)
            completion()
            return
        }

        let requestHandle = MCPActiveRequestHandle()
        activeRequests.register(
            requestId: request.id,
            clientId: access.clientId,
            handle: requestHandle
        )
        let startedAt = Date()
        let operation = Task {
            defer {
                self.activeRequests.unregister(
                    requestId: request.id,
                    clientId: access.clientId,
                    handle: requestHandle
                )
                self.invocationLimiter.finish(
                    clientId: access.clientId,
                    method: request.method
                )
                Darwin.close(client)
                completion()
            }
            let response: MCPWireResponse
            guard MCPAuthorizationStore.shared.remainsAuthorized(access) else {
                response = MCPWireResponse(
                    id: request.id,
                    error: MCPWireError(
                        code: "forbidden",
                        message: "The MCP credential or permissions were revoked."
                    )
                )
                Self.write(response, to: client)
                return
            }
            do {
                let result = try await RecordingLibraryAPI.shared.call(
                    method: request.method,
                    arguments: request.arguments,
                    access: access
                )
                try Task.checkCancellation()
                guard MCPAuthorizationStore.shared.remainsAuthorized(access) else {
                    throw RecordingLibraryAPI.APIError.forbidden(
                        "The MCP credential or permissions were revoked."
                    )
                }
                response = MCPWireResponse(id: request.id, result: result)
                Self.audit(
                    clientId: access.clientId,
                    method: request.method,
                    arguments: request.arguments,
                    success: true,
                    errorCode: nil,
                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    responseBytes: Self.encodedSize(response)
                )
            } catch is CancellationError {
                response = MCPWireResponse(
                    id: request.id,
                    error: MCPWireError(
                        code: "cancelled",
                        message: "The MCP request was cancelled.",
                        retryable: true
                    )
                )
                Self.audit(
                    clientId: access.clientId,
                    method: request.method,
                    arguments: request.arguments,
                    success: false,
                    errorCode: "cancelled",
                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    responseBytes: Self.encodedSize(response)
                )
            } catch let error as RecordingLibraryAPI.APIError {
                response = MCPWireResponse(
                    id: request.id,
                    error: MCPWireError(
                        code: error.code,
                        message: error.localizedDescription,
                        retryable: error.code == "unavailable"
                    )
                )
                Self.audit(
                    clientId: access.clientId,
                    method: request.method,
                    arguments: request.arguments,
                    success: false,
                    errorCode: error.code,
                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    responseBytes: Self.encodedSize(response)
                )
            } catch {
                response = MCPWireResponse(
                    id: request.id,
                    error: MCPWireError(code: "internal_error", message: error.localizedDescription)
                )
                Self.audit(
                    clientId: access.clientId,
                    method: request.method,
                    arguments: request.arguments,
                    success: false,
                    errorCode: "internal_error",
                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    responseBytes: Self.encodedSize(response)
                )
            }
            Self.write(response, to: client)
        }
        requestHandle.attach(operation)
    }

    private static func applyTimeouts(to fd: Int32) {
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
            _ = setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

    private static func bind(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        guard result == 0 else { throw SocketError.operation("bind", errno) }
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
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        return data
    }

    private static func write(_ response: MCPWireResponse, to fd: Int32) {
        guard var data = try? MCPWireCoding.encoder.encode(response),
              data.count <= AlmRecorderMCP.maximumResponseBytes else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                sent += count
            }
        }
    }

    private static func audit(
        clientId: String,
        method: String,
        arguments: [String: MCPJSONValue],
        success: Bool,
        errorCode: String?,
        durationMilliseconds: Int,
        responseBytes: Int
    ) {
        let target = arguments["recording_id"]?.stringValue
            ?? arguments["comment_id"]?.stringValue
            ?? arguments["calendar_event_id"]?.stringValue
        try? GRDBDatabaseManager.shared.write { db in
            try db.execute(
                sql: """
                    INSERT INTO mcp_audit_log (
                        id, client_id, method, target_external_id, success, error_code,
                        duration_ms, response_bytes, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "audit_\(UUID().uuidString.lowercased())",
                    clientId, method, target, success, errorCode,
                    durationMilliseconds, responseBytes, Date()
                ]
            )
        }
    }

    private static func encodedSize(_ response: MCPWireResponse) -> Int {
        (try? MCPWireCoding.encoder.encode(response).count) ?? 0
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }
}

final class MCPActiveRequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Task<Void, Never>?
    private var isCancelled = false

    func attach(_ operation: Task<Void, Never>) {
        lock.lock()
        self.operation = operation
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { operation.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let operation = operation
        lock.unlock()
        operation?.cancel()
    }
}

final class MCPActiveRequestRegistry: @unchecked Sendable {
    private struct Entry {
        let clientId: String
        let handle: MCPActiveRequestHandle
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func register(
        requestId: String,
        clientId: String,
        handle: MCPActiveRequestHandle
    ) {
        lock.lock()
        entries[requestId] = Entry(clientId: clientId, handle: handle)
        lock.unlock()
    }

    func unregister(
        requestId: String,
        clientId: String,
        handle: MCPActiveRequestHandle
    ) {
        lock.lock()
        if let entry = entries[requestId],
           entry.clientId == clientId,
           entry.handle === handle {
            entries.removeValue(forKey: requestId)
        }
        lock.unlock()
    }

    func cancel(requestId: String, clientId: String) -> Bool {
        lock.lock()
        let handle = entries[requestId].flatMap {
            $0.clientId == clientId ? $0.handle : nil
        }
        lock.unlock()
        handle?.cancel()
        return handle != nil
    }

    func cancelAll() {
        lock.lock()
        let handles = entries.values.map(\.handle)
        entries.removeAll()
        lock.unlock()
        handles.forEach { $0.cancel() }
    }
}

final class MCPInvocationLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var startsByClient: [String: [Date]] = [:]
    private var activeByClient: [String: Int] = [:]
    private var activeSearches = 0
    private let requestsPerMinute = 120
    private let maximumConcurrentPerClient = 8

    func begin(clientId: String, method: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-60)
        var starts = (startsByClient[clientId] ?? []).filter { $0 >= cutoff }
        guard starts.count < requestsPerMinute,
              activeByClient[clientId, default: 0] < maximumConcurrentPerClient,
              (method != "search_recordings" || activeSearches == 0) else {
            startsByClient[clientId] = starts
            return false
        }
        starts.append(Date())
        startsByClient[clientId] = starts
        activeByClient[clientId, default: 0] += 1
        if method == "search_recordings" { activeSearches += 1 }
        return true
    }

    func finish(clientId: String, method: String) {
        lock.lock()
        defer { lock.unlock() }
        activeByClient[clientId] = max(0, activeByClient[clientId, default: 0] - 1)
        if method == "search_recordings" {
            activeSearches = max(0, activeSearches - 1)
        }
    }
}
