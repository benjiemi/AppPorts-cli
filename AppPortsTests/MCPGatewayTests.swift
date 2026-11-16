import XCTest
@testable import AppPorts

@MainActor
final class MCPGatewayTests: XCTestCase {
    private var suiteNames: [String] = []
    private var fixtures: [MCPTestSupport.Fixture] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        for fixture in fixtures { MCPTestSupport.cleanup(fixture) }
        suiteNames = []
        fixtures = []
        super.tearDown()
    }

    private func makeGateway() throws -> (MCPGateway, UserDefaults) {
        let (service, fixture) = try MCPTestSupport.makeService()
        fixtures.append(fixture)
        let name = "MCPGatewayTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let gateway = MCPGateway(defaults: defaults, toolService: service)
        return (gateway, defaults)
    }

    private func request(body: Data, token: String? = nil, method: String = "POST",
                         path: String = MCPSettings.endpointPath,
                         origin: String? = nil) -> MCPHTTPRequest {
        var headers: [String: String] = ["content-type": "application/json"]
        if let token { headers["authorization"] = "Bearer " + token }
        if let origin { headers["origin"] = origin }
        return MCPHTTPRequest(method: method, path: path, query: nil, headers: headers, body: body)
    }

    private func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ response: MCPHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    // MARK: - Transport-level policy

    func testRejectsUnauthorizedRequests() async throws {
        let (gateway, defaults) = try makeGateway()
        let body = try jsonBody(["jsonrpc": "2.0", "id": 1, "method": "ping"])

        let anonymous = await gateway.handle(request(body: body))
        XCTAssertEqual(anonymous.status, 401)

        let wrong = await gateway.handle(request(body: body, token: "not-the-token"))
        XCTAssertEqual(wrong.status, 401)

        let token = try XCTUnwrap(MCPSettings(defaults: defaults).token())
        let authorized = await gateway.handle(request(body: body, token: token))
        XCTAssertEqual(authorized.status, 200)
    }

    func testRejectsForeignOrigin() async throws {
        let (gateway, defaults) = try makeGateway()
        let token = try XCTUnwrap(MCPSettings(defaults: defaults).token())
        let body = try jsonBody(["jsonrpc": "2.0", "id": 1, "method": "ping"])

        let foreign = await gateway.handle(request(body: body, token: token, origin: "https://evil.example"))
        XCTAssertEqual(foreign.status, 403)

        let local = await gateway.handle(request(body: body, token: token, origin: "http://localhost:5173"))
        XCTAssertEqual(local.status, 200)
    }

    func testRejectsWrongPathAndMethod() async throws {
        let (gateway, defaults) = try makeGateway()
        let token = try XCTUnwrap(MCPSettings(defaults: defaults).token())
        let body = try jsonBody(["jsonrpc": "2.0", "id": 1, "method": "ping"])

        let wrongPath = await gateway.handle(request(body: body, token: token, path: "/other"))
        XCTAssertEqual(wrongPath.status, 404)

        let get = await gateway.handle(request(body: Data(), token: token, method: "GET"))
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(get.headers["Allow"], "POST, OPTIONS")

        let options = await gateway.handle(request(body: Data(), token: token, method: "OPTIONS"))
        XCTAssertEqual(options.status, 204)
    }

    func testRejectsNonJSONContentType() async throws {
        let (gateway, defaults) = try makeGateway()
        let token = try XCTUnwrap(MCPSettings(defaults: defaults).token())
        let request = MCPHTTPRequest(method: "POST", path: MCPSettings.endpointPath, query: nil,
                                     headers: ["authorization": "Bearer " + token,
                                               "content-type": "text/plain"],
                                     body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        let response = await gateway.handle(request)
        XCTAssertEqual(response.status, 415)
    }

    // MARK: - JSON-RPC routing

    func testInitializeNegotiatesVersionAndCapabilities() async throws {
        let (gateway, defaults) = try makeGateway()
        let token = try XCTUnwrap(MCPSettings(defaults: defaults).token())
        let body = try jsonBody([
            "jsonrpc": "2.0", "id": "init-1", "method": "initialize",
            "params": ["protocolVersion": "2025-03-26",
                       "capabilities": [String: Any](),
                       "clientInfo": ["name": "Tests", "version": "1"]],
        ])

        let response = await gateway.handle(request(body: body, token: token))
        XCTAssertEqual(response.status, 200)
        let object = try decode(response)
        XCTAssertEqual(object["id"] as? String, "init-1")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "AppPorts")
        XCTAssertNotNil(result["instructions"])
    }

    func testToolsListAndUnknownMethod() async throws {
        let (gateway, defaults) = try makeGateway()
        let token = try XCTUnwrap(MCPSettings(defaults: defaults).token())

        let listBody = try jsonBody(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [String: Any]()])
        let listResponse = await gateway.handle(request(body: listBody, token: token))
        let list = try decode(listResponse)
        let result = try XCTUnwrap(list["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, MCPToolService.tools.count)
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }.sorted(),
                       MCPToolService.tools.map(\.name).sorted())

        let unknownBody = try jsonBody(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        let unknown = try decode(await gateway.handle(request(body: unknownBody, token: token)))
        let error = try XCTUnwrap(unknown["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, MCPJSONRPC.methodNotFound)
    }

    func testToolsCallValidatesNameAndDelegates() async throws {
        let (gateway, defaults) = try makeGateway()
        let token = try XCTUnwrap(MCPSettings(defaults: defaults).token())

        let missingName = try jsonBody(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": [String: Any]()])
        let missing = try decode(await gateway.handle(request(body: missingName, token: token)))
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, MCPJSONRPC.invalidParams)

        let unknownTool = try jsonBody(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                        "params": ["name": "appports_nope", "arguments": [String: Any]()]])
        let unknown = try decode(await gateway.handle(request(body: unknownTool, token: token)))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, MCPJSONRPC.invalidParams)

        let status = try jsonBody(["jsonrpc": "2.0", "id": 6, "method": "tools/call",
                                   "params": ["name": "appports_status", "arguments": [String: Any]()]])
        let statusResponse = try decode(await gateway.handle(request(body: status, token: token)))
        let result = try XCTUnwrap(statusResponse["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertNil(result["isError"])
    }

    func testNotificationsAreAcknowledgedWithoutBody() async throws {
        let (gateway, defaults) = try makeGateway()
        let token = try XCTUnwrap(MCPSettings(defaults: defaults).token())
        let notification = try jsonBody(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let response = await gateway.handle(request(body: notification, token: token))
        XCTAssertEqual(response.status, 202)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testMalformedBodyReturnsInvalidRequest() async throws {
        let (gateway, defaults) = try makeGateway()
        let token = try XCTUnwrap(MCPSettings(defaults: defaults).token())
        let response = await gateway.handle(request(body: Data("not json".utf8), token: token))
        XCTAssertEqual(response.status, 400)
        let object = try decode(response)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, MCPJSONRPC.parseError)
    }

    // MARK: - Listener

    func testLoopbackListenerServesOneRequest() async throws {
        let server = MCPServer()
        let ready = expectation(description: "listener ready")
        var port: UInt16?
        server.onStateChange = { state in
            if case let .running(value) = state {
                port = value
                ready.fulfill()
            }
        }
        try server.start(port: nil) { request in
            MCPHTTPResponse.json(["ok": true, "method": request.method], status: 200)
        }
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        let boundPort = try XCTUnwrap(port)
        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(boundPort)/mcp")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "POST")
        XCTAssertEqual(object["ok"] as? Bool, true)
    }
}
