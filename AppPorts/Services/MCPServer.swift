//
//  MCPServer.swift
//  AppPorts
//
//  Minimal loopback HTTP transport for the Model Context Protocol.
//
//  The endpoint speaks the stateless "Streamable HTTP" dialect: one JSON-RPC
//  message per POST, one JSON response, no server-initiated stream. That is all
//  the AppPorts tools need, and it keeps the transport small enough to audit.
//

import Foundation
import Network

// MARK: - HTTP model

struct MCPHTTPRequest {
    let method: String
    let path: String
    let query: String?
    /// Header names are lower-cased; values keep their original spelling.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct MCPHTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func json(_ object: [String: Any], status: Int = 200) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status,
                        headers: ["Content-Type": "application/json"],
                        body: MCPResponseEncoder.data(object))
    }

    static func jsonData(_ data: Data, status: Int = 200) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func empty(status: Int, headers: [String: String] = [:]) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: headers, body: Data())
    }

    static func text(_ message: String, status: Int) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"],
                        body: Data(message.utf8))
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Response"
        }
    }

    /// Serialized HTTP/1.1 response. The connection is closed afterwards, which
    /// removes keep-alive and chunked-encoding state from the transport.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(for: status))\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        for name in allHeaders.keys.sorted() {
            head += "\(name): \(allHeaders[name] ?? "")\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

enum MCPHTTPParseOutcome {
    case needMoreData
    case request(MCPHTTPRequest)
    case malformed(status: Int, message: String)
}

enum MCPHTTPParser {
    static let maximumHeaderBytes = 32 * 1024
    static let maximumBodyBytes = 4 * 1024 * 1024

    /// Parses exactly one HTTP/1.1 request from the accumulated bytes.
    static func parse(_ data: Data) -> MCPHTTPParseOutcome {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return data.count > maximumHeaderBytes
                ? .malformed(status: 413, message: "请求头过大")
                : .needMoreData
        }
        let headerData = data[data.startIndex..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed(status: 400, message: "请求头不是 UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed(status: 400, message: "缺少请求行") }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return .malformed(status: 400, message: "无法识别的请求行")
        }
        let target = parts[1]
        var path = target
        var query: String?
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<questionMark])
            query = String(target[target.index(after: questionMark)...])
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }

        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else {
                return .malformed(status: 400, message: "Content-Length 无效")
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maximumBodyBytes else {
            return .malformed(status: 413, message: "请求体过大")
        }

        let bodyStart = headerRange.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return .needMoreData }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = Data(data[bodyStart..<bodyEnd])
        return .request(MCPHTTPRequest(method: parts[0].uppercased(), path: path, query: query,
                                       headers: headers, body: body))
    }
}

// MARK: - Server

/// Loopback HTTP listener that forwards one parsed request at a time to a
/// handler and writes the response back. All network work happens on a private
/// serial queue; state changes are reported on the main queue.
final class MCPServer: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
        var port: UInt16? { if case let .running(port) = self { return port }; return nil }
    }

    typealias Handler = @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse

    private let queue = DispatchQueue(label: "com.appports.mcp.server")
    private let stateLock = NSLock()
    private var storedState: State = .stopped
    /// Only touched on `queue`.
    private var listener: NWListener?
    private var connections: [UUID: MCPHTTPConnection] = [:]
    private var handler: Handler?

    /// Called on the main queue whenever the listener state changes.
    var onStateChange: (@Sendable (State) -> Void)?

    var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return storedState
    }

    private func setState(_ state: State) {
        stateLock.lock()
        let changed = storedState != state
        storedState = state
        stateLock.unlock()
        guard changed else { return }
        let callback = onStateChange
        DispatchQueue.main.async { callback?(state) }
    }

    /// Starts listening on `127.0.0.1`. Pass `nil` for an ephemeral port.
    func start(port: UInt16?, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let nwPort = port.map { NWEndpoint.Port(rawValue: $0) ?? .any } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
        setState(.starting)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let actualPort = listener.port?.rawValue ?? nwPort.rawValue
                self.setState(.running(port: actualPort))
            case let .failed(error):
                self.setState(.failed(error.localizedDescription))
                self.queue.async { self.teardown() }
            case .cancelled:
                if case .failed = self.state { return }
                self.setState(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.queue.async { self.accept(connection) }
        }

        queue.sync {
            self.listener?.cancel()
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
            self.handler = handler
            self.listener = listener
            listener.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardown()
            self.setState(.stopped)
        }
    }

    /// Cancels the listener and every open connection. Runs on `queue`.
    private func teardown() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        handler = nil
    }

    private func accept(_ connection: NWConnection) {
        guard let handler else { connection.cancel(); return }
        let id = UUID()
        let wrapper = MCPHTTPConnection(id: id, connection: connection, queue: queue, handler: handler)
        connections[id] = wrapper
        wrapper.onClose = { [weak self] closedID in
            self?.queue.async {
                guard let self else { return }
                self.connections[closedID] = nil
            }
        }
        wrapper.start()
    }
}

/// One accepted TCP connection: accumulate bytes, parse a single request, run
/// the handler, write one response, close.
private final class MCPHTTPConnection: @unchecked Sendable {
    private let id: UUID
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: MCPServer.Handler
    var onClose: ((UUID) -> Void)?
    private var buffer = Data()
    private var finished = false

    init(id: UUID, connection: NWConnection, queue: DispatchQueue, handler: @escaping MCPServer.Handler) {
        self.id = id
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onClose?(id)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > MCPHTTPParser.maximumHeaderBytes + MCPHTTPParser.maximumBodyBytes {
                    self.respond(.text("请求体过大", status: 413))
                    return
                }
                self.handleBufferedData()
                if self.finished { return }
            }
            if error != nil || isComplete {
                self.finish()
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func handleBufferedData() {
        switch MCPHTTPParser.parse(buffer) {
        case .needMoreData:
            return
        case let .malformed(status, message):
            respond(.text(message, status: status))
        case let .request(request):
            Task { [weak self] in
                guard let self else { return }
                let response = await self.handler(request)
                self.queue.async { self.respond(response) }
            }
        }
    }

    private func respond(_ response: MCPHTTPResponse) {
        guard !finished else { return }
        let data = response.serialized()
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.finish()
            self.connection.cancel()
        })
    }
}
