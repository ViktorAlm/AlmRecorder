import Foundation

/// JSON value shared by the stdio MCP bridge and the running AlmRecorder app.
///
/// Keeping this module independent of the MCP SDK means the app does not need to
/// expose the SDK's transport types or write anything to stdout.
public enum MCPJSONValue: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MCPJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var integerValue: Int64? {
        switch self {
        case .integer(let value): return value
        case .double(let value) where value.rounded() == value: return Int64(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var arrayValue: [MCPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public static func from<T: Encodable>(_ value: T) throws -> MCPJSONValue {
        let data = try MCPWireCoding.encoder.encode(value)
        return try MCPWireCoding.decoder.decode(MCPJSONValue.self, from: data)
    }
}

public struct MCPWireRequest: Codable, Sendable {
    public let id: String
    public let token: String
    public let method: String
    public let arguments: [String: MCPJSONValue]

    public init(
        id: String = UUID().uuidString,
        token: String,
        method: String,
        arguments: [String: MCPJSONValue] = [:]
    ) {
        self.id = id
        self.token = token
        self.method = method
        self.arguments = arguments
    }
}

public struct MCPWireResponse: Codable, Sendable {
    public let id: String
    public let result: MCPJSONValue?
    public let error: MCPWireError?

    public init(id: String, result: MCPJSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: String, error: MCPWireError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct MCPWireError: Error, Codable, Sendable, LocalizedError {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let details: [String: MCPJSONValue]?

    public init(
        code: String,
        message: String,
        retryable: Bool = false,
        details: [String: MCPJSONValue]? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }

    public var errorDescription: String? { message }
}

public enum MCPWireCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum AlmRecorderMCP {
    public static let protocolVersion = 2
    public static let serverVersion = "0.2.0"
    public static let cancellationMethod = "_cancel_request"
    public static let maximumRequestBytes = 2 * 1_024 * 1_024
    public static let maximumResponseBytes = 16 * 1_024 * 1_024

    public static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlmRecorder", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
    }

    public static var defaultSocketURL: URL {
        defaultDirectoryURL.appendingPathComponent("mcp.sock")
    }

    public static var defaultCredentialsURL: URL {
        defaultDirectoryURL.appendingPathComponent("credentials.json")
    }
}
