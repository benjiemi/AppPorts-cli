//
//  MCPSettings.swift
//  AppPorts
//
//  Persisted configuration for the local MCP endpoint.
//

import Foundation
import Security

/// Settings for the loopback MCP server.
///
/// The endpoint is off until the user enables it, binds only to `127.0.0.1`, and
/// requires a per-install bearer token so a random local process or a web page
/// cannot drive migrations. The token lives in the app's own preferences, which
/// is the same trust boundary as the app's other migration state.
struct MCPSettings {
    static let enabledKey = "MCPServerEnabled"
    static let portKey = "MCPServerPort"
    static let tokenKey = "MCPServerToken"
    static let defaultPort: UInt16 = 18765
    static let endpointPath = "/mcp"
    static let supportedPortRange: ClosedRange<Int> = 1024...65535

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    var port: UInt16 {
        let stored = defaults.integer(forKey: Self.portKey)
        guard Self.supportedPortRange.contains(stored) else { return Self.defaultPort }
        return UInt16(stored)
    }

    var endpointURL: URL {
        URL(string: "http://127.0.0.1:\(port)\(Self.endpointPath)")!
    }

    /// Reads the token, creating one on first use. `nil` means the token could
    /// not be persisted, and the server must stay stopped rather than run open.
    func token(creatingIfNeeded: Bool = true) -> String? {
        if let existing = defaults.string(forKey: Self.tokenKey), !existing.isEmpty { return existing }
        guard creatingIfNeeded else { return nil }
        let created = Self.makeToken()
        defaults.set(created, forKey: Self.tokenKey)
        guard let stored = defaults.string(forKey: Self.tokenKey), !stored.isEmpty else { return nil }
        return stored
    }

    @discardableResult
    func rotateToken() -> String? {
        let created = Self.makeToken()
        defaults.set(created, forKey: Self.tokenKey)
        return defaults.string(forKey: Self.tokenKey)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func setPort(_ port: UInt16) {
        defaults.set(Int(port), forKey: Self.portKey)
    }

    /// Client configuration that can be pasted into an MCP client. The token is
    /// included, so this text is meant for the user's own machine only.
    func clientConfiguration(endpoint: URL? = nil, token: String? = nil) -> String {
        let url = (endpoint ?? endpointURL).absoluteString
        let secret = token ?? self.token() ?? ""
        let object: [String: Any] = [
            "mcpServers": [
                "appports": [
                    "type": "http",
                    "url": url,
                    "headers": ["Authorization": "Bearer " + secret],
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time comparison used for the bearer token.
    static func secureEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
