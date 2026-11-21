//
//  MCPGateway.swift
//  AppPorts
//
//  Owns the loopback MCP endpoint: settings, authentication, JSON-RPC routing
//  and lifecycle. Tool execution stays on the main actor and reuses the same
//  services as the App UI.
//

import Combine
import Foundation

@MainActor
final class MCPGateway: ObservableObject {
    static let shared = MCPGateway()

    @Published private(set) var state: MCPServer.State = .stopped
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults
    private let toolService: MCPToolService
    private let server = MCPServer()
    private var handlerInstalled = false

    init(defaults: UserDefaults = .standard, toolService: MCPToolService? = nil) {
        self.defaults = defaults
        self.toolService = toolService ?? MCPToolService()
        server.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.state = state
                if case let .failed(message) = state {
                    self.lastError = message
                    AppLogger.shared.log("MCP 服务启动失败：\(message)", level: "ERROR")
                }
            }
        }
    }

    var settings: MCPSettings { MCPSettings(defaults: defaults) }

    var isRunning: Bool { state.isRunning }

    var endpointURL: URL {
        if let port = state.port {
            return URL(string: "http://127.0.0.1:\(port)\(MCPSettings.endpointPath)")!
        }
        return settings.endpointURL
    }

    // MARK: Lifecycle

    /// Called once during app launch. The endpoint stays off until the user has
    /// explicitly enabled it in settings.
    func startIfEnabled() {
        guard settings.isEnabled else {
            stop()
            return
        }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        settings.setEnabled(enabled)
        if enabled { start() } else { stop() }
    }

    func restart() {
        stop()
        guard settings.isEnabled else { return }
        start()
    }

    func stop() {
        server.stop()
        state = .stopped
    }

    @discardableResult
    func rotateToken() -> String? {
        let token = settings.rotateToken()
        AppLogger.shared.log("MCP 访问令牌已重新生成", level: "SECURITY")
        return token
    }

    func clientConfiguration() -> String {
        settings.clientConfiguration(endpoint: endpointURL)
    }

    private func start() {
        guard let token = settings.token(creatingIfNeeded: true), !token.isEmpty else {
            state = .failed("无法创建访问令牌")
            lastError = "无法创建访问令牌"
            return
        }
        lastError = nil
        let port = settings.port
        do {
            try server.start(port: port) { [weak self] request in
                guard let self else {
                    return MCPHTTPResponse.text("AppPorts MCP 服务已停止", status: 503)
                }
                return await self.handle(request)
            }
            AppLogger.shared.logContext("MCP 服务已启动", details: [
                ("host", "127.0.0.1"), ("port", String(port)), ("path", MCPSettings.endpointPath),
            ])
        } catch {
            state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            AppLogger.shared.logError("MCP 服务启动失败", error: error, errorCode: "MCP-SERVER-START-FAILED")
        }
    }

    // MARK: Request handling

    /// Transport-level routing for one HTTP request. Exposed for tests.
    func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard request.path == MCPSettings.endpointPath else {
            return .text("未找到 MCP 端点", status: 404)
        }
        if request.method == "OPTIONS" {
            return .empty(status: 204, headers: ["Allow": "POST, OPTIONS"])
        }
        guard request.method == "POST" else {
            return .empty(status: 405, headers: ["Allow": "POST, OPTIONS"])
        }
        if let origin = request.header("origin"), !Self.isAllowedOrigin(origin) {
            return .text("拒绝来自该 Origin 的请求", status: 403)
        }
        guard Self.isAuthorized(request, token: settings.token(creatingIfNeeded: false)) else {
            AppLogger.shared.log("MCP 请求被拒绝：访问令牌缺失或不匹配", level: "SECURITY")
            return .text("缺少或无效的访问令牌", status: 401)
        }
        if let contentType = request.header("content-type"),
           !contentType.lowercased().hasPrefix("application/json") {
            return .text("Content-Type 必须是 application/json", status: 415)
        }
        guard !request.body.isEmpty else {
            return .json(MCPResponseEncoder.error(id: nil, code: MCPJSONRPC.invalidRequest, message: "空请求"),
                         status: 400)
        }
        // A JSON-RPC response from the client needs no answer. The server never
        // sends requests, but acknowledging keeps the transport spec-compliant.
        if MCPMessageDecoder.isClientResponse(request.body) {
            return .empty(status: 202)
        }
        let message: MCPIncomingMessage
        do {
            message = try MCPMessageDecoder.decode(request.body)
        } catch let error as MCPDecodingError {
            return .json(MCPResponseEncoder.error(id: nil, code: error.jsonRPCErrorCode, message: error.message),
                         status: 400)
        } catch {
            return .json(MCPResponseEncoder.error(id: nil, code: MCPJSONRPC.parseError, message: "请求解析失败"),
                         status: 400)
        }
        guard message.isRequest else {
            return .empty(status: 202)
        }
        let response = await route(message)
        return .json(response)
    }

    private func route(_ message: MCPIncomingMessage) async -> [String: Any] {
        let id = message.id
        switch message.method {
        case "initialize":
            return MCPResponseEncoder.result(id: id, value: [
                "protocolVersion": MCPProtocolVersion.negotiate(requested: message.params["protocolVersion"] as? String),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "AppPorts",
                    "title": "AppPorts",
                    "version": Self.applicationVersion,
                ],
                "instructions": Self.instructions,
            ])
        case "ping":
            return MCPResponseEncoder.result(id: id, value: [String: Any]())
        case "tools/list":
            return MCPResponseEncoder.result(id: id, value: [
                "tools": MCPToolService.tools.map(\.jsonObject),
            ])
        case "tools/call":
            guard let name = message.params["name"] as? String, !name.isEmpty else {
                return MCPResponseEncoder.error(id: id, code: MCPJSONRPC.invalidParams,
                                               message: "tools/call 需要 name")
            }
            let arguments = message.params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try await toolService.call(name: name, arguments: arguments)
                return MCPResponseEncoder.result(id: id, value: result.jsonObject)
            } catch let error as MCPToolError {
                let code = { () -> Int in
                    switch error {
                    case .unknownTool, .invalidArguments: return MCPJSONRPC.invalidParams
                    }
                }()
                return MCPResponseEncoder.error(id: id, code: code, message: error.message)
            } catch {
                AppLogger.shared.logError("MCP 工具调用失败", error: error, errorCode: "MCP-TOOL-FAILED",
                                          context: [("tool", name)])
                return MCPResponseEncoder.error(id: id, code: MCPJSONRPC.internalError,
                                               message: error.localizedDescription)
            }
        default:
            return MCPResponseEncoder.error(id: id, code: MCPJSONRPC.methodNotFound,
                                           message: "不支持的方法：\(message.method)")
        }
    }

    // MARK: Authentication helpers

    nonisolated static func bearerToken(from header: String) -> String? {
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func isAuthorized(_ request: MCPHTTPRequest, token: String?) -> Bool {
        guard let token, !token.isEmpty,
              let header = request.header("authorization"),
              let provided = bearerToken(from: header) else { return false }
        return MCPSettings.secureEquals(provided, token)
    }

    /// Streamable HTTP servers must reject cross-origin callers so a web page
    /// cannot reach the loopback endpoint through DNS rebinding.
    nonisolated static func isAllowedOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    nonisolated static var applicationVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }

    nonisolated static let instructions = """
    AppPorts moves macOS applications between /Applications and an external volume, keeping a local entry that \
    launches the external copy. It also moves two other kinds of data the same way: application data \
    directories, tool directories and custom directories (by symlink, or by mounting a container volume), and \
    application container data including WeChat accounts. Tools can list applications, paths and data \
    migration records, create migrations, restore them, and read task progress. Every mutation runs as an \
    AppPorts task: it appears in the app's task center, can be paused or cancelled, and leaves the same \
    journals, mount records and cleanup entries as a manual operation. Read appports_status first, then \
    appports_list_apps or appports_list_paths before naming a target. Application data directories need \
    app_path so the path can be attributed to one application. Container directories cannot be symlinked; \
    they migrate by mounting an APFS volume, so mode=mount (or auto) is required unless the user has enabled \
    classic mode. Refuse to migrate system applications, running applications, or App Store / iOS applications \
    unless the app's settings allow it, and start a migration only when the destination root is the external \
    volume the user actually chose. WeChat account data additionally requires the user to have enabled \
    account split migration; whole-container migration is offered only through appports_migrate_wechat_account \
    with mode=whole.
    """
}
