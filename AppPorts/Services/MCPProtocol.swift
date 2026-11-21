//
//  MCPProtocol.swift
//  AppPorts
//
//  JSON-RPC 2.0 envelope handling for the local MCP endpoint.
//

import Foundation

// MARK: - Message identity

/// A JSON-RPC id may be a number or a string. The original spelling is kept so
/// the response can echo exactly what the client sent.
enum MCPMessageID: Hashable {
    case number(Int)
    case string(String)

    var jsonValue: Any {
        switch self {
        case let .number(value): return value
        case let .string(value): return value
        }
    }

    var displayValue: String {
        switch self {
        case let .number(value): return String(value)
        case let .string(value): return value
        }
    }
}

// MARK: - Incoming messages

struct MCPIncomingMessage {
    enum Kind: Equatable {
        case request
        case notification
    }

    let kind: Kind
    let id: MCPMessageID?
    let method: String
    let params: [String: Any]

    var isRequest: Bool { kind == .request }
}

enum MCPDecodingError: Error {
    case malformedJSON
    case notAnObject
    case missingMethod
    case unsupportedEnvelope

    var jsonRPCErrorCode: Int {
        switch self {
        case .malformedJSON: return MCPJSONRPC.parseError
        case .notAnObject, .unsupportedEnvelope, .missingMethod: return MCPJSONRPC.invalidRequest
        }
    }

    var message: String {
        switch self {
        case .malformedJSON: return "请求不是合法的 JSON"
        case .notAnObject: return "请求必须是 JSON 对象"
        case .missingMethod: return "缺少 method 字段"
        case .unsupportedEnvelope: return "无法识别的 JSON-RPC 消息"
        }
    }
}

enum MCPJSONRPC {
    static let version = "2.0"

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

enum MCPMessageDecoder {
    /// Decodes one JSON-RPC request or notification. Responses from the client
    /// are accepted by the transport but carry no method here.
    static func decode(_ data: Data) throws -> MCPIncomingMessage {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw MCPDecodingError.malformedJSON
        }
        guard let dictionary = object as? [String: Any] else { throw MCPDecodingError.notAnObject }
        return try decode(dictionary)
    }

    static func decode(_ dictionary: [String: Any]) throws -> MCPIncomingMessage {
        guard let method = dictionary["method"] as? String, !method.isEmpty else {
            throw MCPDecodingError.missingMethod
        }
        if let version = dictionary["jsonrpc"] as? String, version != MCPJSONRPC.version {
            throw MCPDecodingError.unsupportedEnvelope
        }
        let id: MCPMessageID?
        if let number = dictionary["id"] as? Int {
            id = .number(number)
        } else if let string = dictionary["id"] as? String {
            id = .string(string)
        } else if let number = dictionary["id"] as? NSNumber {
            id = .number(number.intValue)
        } else {
            id = nil
        }
        let params = (dictionary["params"] as? [String: Any]) ?? [:]
        return MCPIncomingMessage(kind: id == nil ? .notification : .request,
                                  id: id, method: method, params: params)
    }

    /// A JSON-RPC *response* from the client (no method, has id or error). The
    /// server never asks the client for anything, so these are only acknowledged.
    static func isClientResponse(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["method"] == nil && (object["result"] != nil || object["error"] != nil)
    }
}

// MARK: - Protocol version negotiation

enum MCPProtocolVersion {
    /// Newest first. The server answers with the client's version when supported
    /// so a client never has to downgrade its own expectations.
    static let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let preferred = "2025-06-18"

    static func negotiate(requested: String?) -> String {
        guard let requested, supported.contains(requested) else { return preferred }
        return requested
    }
}

// MARK: - Response encoding

enum MCPResponseEncoder {
    static func result(id: MCPMessageID?, value: Any) -> [String: Any] {
        var object: [String: Any] = ["jsonrpc": MCPJSONRPC.version, "result": value]
        if let id { object["id"] = id.jsonValue }
        return object
    }

    static func error(id: MCPMessageID?, code: Int, message: String, data: Any? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        var object: [String: Any] = ["jsonrpc": MCPJSONRPC.version, "error": error]
        if let id { object["id"] = id.jsonValue }
        return object
    }

    static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"响应编码失败\"}}".utf8)
    }
}

// MARK: - Tool schema helpers

enum MCPToolSchema {
    static func object(properties: [String: Any] = [:], required: [String] = [],
                       additionalProperties: Bool = false) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": additionalProperties,
        ]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    static func string(description: String, values: [String]? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string", "description": description]
        if let values { schema["enum"] = values }
        return schema
    }

    static func boolean(description: String, defaultValue: Bool? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "boolean", "description": description]
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }

    static func integer(description: String, minimum: Int? = nil, maximum: Int? = nil,
                        defaultValue: Int? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "integer", "description": description]
        if let minimum { schema["minimum"] = minimum }
        if let maximum { schema["maximum"] = maximum }
        if let defaultValue { schema["default"] = defaultValue }
        return schema
    }
}

// MARK: - Tool descriptions and results

struct MCPToolDefinition {
    let name: String
    let title: String
    let description: String
    let inputSchema: [String: Any]
    let readOnly: Bool
    let destructive: Bool

    var jsonObject: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": destructive,
                "idempotentHint": readOnly,
                "openWorldHint": false,
            ],
        ]
    }
}

/// A tool invocation result. Tool-level failures travel as `isError` content so
/// the calling model can correct its arguments instead of losing the session.
struct MCPToolResult {
    let text: String
    let isError: Bool

    init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    static func json(_ object: [String: Any], isError: Bool = false) -> MCPToolResult {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return MCPToolResult(text: String(data: data, encoding: .utf8) ?? "{}", isError: isError)
    }

    static func failure(code: String, message: String, hint: String? = nil,
                        details: [String: Any] = [:]) -> MCPToolResult {
        var object: [String: Any] = ["error": code, "message": message]
        if let hint { object["hint"] = hint }
        if !details.isEmpty { object["details"] = details }
        return .json(object, isError: true)
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { object["isError"] = true }
        return object
    }
}

// MARK: - Argument access

/// Small typed accessor so tool implementations can fail with a consistent
/// JSON-RPC invalid-params error instead of trapping on casts.
struct MCPArguments {
    let values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    enum ArgumentError: Error {
        case missing(String, expected: String)
        case wrongType(String, expected: String)

        var message: String {
            switch self {
            case let .missing(name, expected): return "缺少参数 \(name)（\(expected)）"
            case let .wrongType(name, expected): return "参数 \(name) 必须是 \(expected)"
            }
        }
    }

    func optionalString(_ name: String) throws -> String? {
        guard let value = values[name] else { return nil }
        if value is NSNull { return nil }
        guard let string = value as? String else { throw ArgumentError.wrongType(name, expected: "string") }
        return string
    }

    func string(_ name: String) throws -> String {
        guard let string = try optionalString(name) else { throw ArgumentError.missing(name, expected: "string") }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ArgumentError.missing(name, expected: "non-empty string") }
        return trimmed
    }

    func optionalBool(_ name: String) throws -> Bool? {
        guard let value = values[name] else { return nil }
        if value is NSNull { return nil }
        guard let bool = value as? Bool ?? (value as? NSNumber).map({ $0.boolValue }) else {
            throw ArgumentError.wrongType(name, expected: "boolean")
        }
        return bool
    }

    func bool(_ name: String, default defaultValue: Bool) throws -> Bool {
        try optionalBool(name) ?? defaultValue
    }

    func optionalInt(_ name: String) throws -> Int? {
        guard let value = values[name] else { return nil }
        if value is NSNull { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        throw ArgumentError.wrongType(name, expected: "integer")
    }

    func int(_ name: String, default defaultValue: Int, range: ClosedRange<Int>? = nil) throws -> Int {
        let value = try optionalInt(name) ?? defaultValue
        if let range, !range.contains(value) { throw ArgumentError.wrongType(name, expected: "\(range)") }
        return value
    }
}
