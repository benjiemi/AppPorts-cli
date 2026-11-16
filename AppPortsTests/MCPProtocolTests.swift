import XCTest
@testable import AppPorts

final class MCPProtocolTests: XCTestCase {
    // MARK: - JSON-RPC envelopes

    func testDecodesRequestWithNumericID() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}"#.utf8)
        let message = try MCPMessageDecoder.decode(data)
        XCTAssertEqual(message.id, .number(7))
        XCTAssertEqual(message.method, "tools/list")
        XCTAssertTrue(message.isRequest)
    }

    func testDecodesRequestWithStringIDAndArguments() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"appports_status","arguments":{"limit":5}}}"#.utf8)
        let message = try MCPMessageDecoder.decode(data)
        XCTAssertEqual(message.id, .string("abc"))
        XCTAssertEqual(message.params["name"] as? String, "appports_status")
        XCTAssertEqual((message.params["arguments"] as? [String: Any])?["limit"] as? Int, 5)
    }

    func testDecodesNotificationWithoutID() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let message = try MCPMessageDecoder.decode(data)
        XCTAssertNil(message.id)
        XCTAssertEqual(message.kind, .notification)
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try MCPMessageDecoder.decode(Data("not json".utf8))) { error in
            XCTAssertEqual((error as? MCPDecodingError)?.jsonRPCErrorCode, MCPJSONRPC.parseError)
        }
    }

    func testRejectsMissingMethod() {
        XCTAssertThrowsError(try MCPMessageDecoder.decode(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))) { error in
            XCTAssertEqual((error as? MCPDecodingError)?.jsonRPCErrorCode, MCPJSONRPC.invalidRequest)
        }
    }

    func testRejectsUnsupportedJSONRPCVersion() {
        XCTAssertThrowsError(try MCPMessageDecoder.decode(
            Data(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#.utf8)
        ))
    }

    func testRecognisesClientResponses() {
        XCTAssertTrue(MCPMessageDecoder.isClientResponse(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)))
        XCTAssertFalse(MCPMessageDecoder.isClientResponse(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)))
    }

    // MARK: - Versions

    func testNegotiatesProtocolVersion() {
        XCTAssertEqual(MCPProtocolVersion.negotiate(requested: "2024-11-05"), "2024-11-05")
        XCTAssertEqual(MCPProtocolVersion.negotiate(requested: "2025-06-18"), "2025-06-18")
        XCTAssertEqual(MCPProtocolVersion.negotiate(requested: "1999-01-01"), MCPProtocolVersion.preferred)
        XCTAssertEqual(MCPProtocolVersion.negotiate(requested: nil), MCPProtocolVersion.preferred)
    }

    // MARK: - Catalog

    func testToolCatalogIsWellFormed() {
        let tools = MCPToolService.tools
        XCTAssertEqual(tools.count, 7)
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count)
        for tool in tools {
            XCTAssertTrue(tool.name.hasPrefix("appports_"), tool.name)
            XCTAssertFalse(tool.description.isEmpty)
            XCTAssertEqual(tool.inputSchema["type"] as? String, "object")
            XCTAssertNotNil(tool.inputSchema["properties"] as? [String: Any])
            if let required = tool.inputSchema["required"] as? [String] {
                let properties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
                for name in required {
                    XCTAssertNotNil(properties[name], "\(tool.name) requires an undeclared property \(name)")
                }
            }
        }
        XCTAssertTrue(tools.filter(\.readOnly).map(\.name).contains("appports_list_apps"))
        XCTAssertFalse(tools.first { $0.name == "appports_migrate_app" }?.readOnly ?? true)
        XCTAssertNil(MCPToolService.definition(named: "appports_unknown"))
    }

    func testToolJSONCarriesAnnotationsAndInputSchema() throws {
        let tool = try XCTUnwrap(MCPToolService.definition(named: "appports_migrate_app"))
        let object = tool.jsonObject
        XCTAssertEqual(object["name"] as? String, "appports_migrate_app")
        let annotations = try XCTUnwrap(object["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, true)
        let schema = try XCTUnwrap(object["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["app_path"])
        XCTAssertEqual(schema["required"] as? [String], ["app_path"])
    }

    // MARK: - Arguments

    func testArgumentAccessorsValidateTypes() throws {
        let args = MCPArguments(["path": "/Applications/Foo.app", "lock": true, "limit": 5])
        XCTAssertEqual(try args.string("path"), "/Applications/Foo.app")
        XCTAssertEqual(try args.bool("lock", default: false), true)
        XCTAssertEqual(try args.bool("missing", default: true), true)
        XCTAssertEqual(try args.int("limit", default: 10), 5)
        XCTAssertEqual(try args.int("missing", default: 10), 10)
        XCTAssertNil(try args.optionalString("absent"))
        XCTAssertThrowsError(try args.string("absent"))
        XCTAssertThrowsError(try MCPArguments(["path": 3]).string("path"))
        XCTAssertThrowsError(try MCPArguments(["limit": 1000]).int("limit", default: 5, range: 1...10))
    }

    func testToolFailurePayloadMarksError() throws {
        let result = MCPToolResult.failure(code: "APP_NOT_FOUND", message: "missing", hint: "list apps")
        XCTAssertTrue(result.isError)
        let object = result.jsonObject
        XCTAssertEqual(object["isError"] as? Bool, true)
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("APP_NOT_FOUND"))
    }

    func testResponseEncoderEchoesID() throws {
        let object = MCPResponseEncoder.result(id: .string("x"), value: ["ok": true])
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? String, "x")
        XCTAssertNotNil(object["result"])
        let error = MCPResponseEncoder.error(id: .number(3), code: MCPJSONRPC.methodNotFound, message: "no")
        XCTAssertEqual(error["id"] as? Int, 3)
        XCTAssertNil(error["result"])
    }

    // MARK: - HTTP parsing

    private func requestData(method: String = "POST", path: String = "/mcp",
                             headers: [String: String] = [:], body: String? = nil) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if let body { head += "Content-Length: \(body.utf8.count)\r\n" }
        head += "\r\n"
        return Data((head + (body ?? "")).utf8)
    }

    func testParsesCompleteRequest() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let outcome = MCPHTTPParser.parse(requestData(headers: ["Content-Type": "application/json",
                                                                "Authorization": "Bearer secret"],
                                                      body: body))
        guard case let .request(request) = outcome else {
            return XCTFail("expected a parsed request, got \(outcome)")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertNil(request.query)
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertEqual(request.header("AUTHORIZATION"), "Bearer secret")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testParsesQuerySeparately() throws {
        let outcome = MCPHTTPParser.parse(requestData(path: "/mcp?session=1", body: ""))
        guard case let .request(request) = outcome else { return XCTFail("expected request") }
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.query, "session=1")
    }

    func testNeedsMoreDataForSplitHeadersAndBody() {
        let full = requestData(body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        for split in [10, full.count - 5, full.count - 1] {
            let partial = full.prefix(split)
            guard case .needMoreData = MCPHTTPParser.parse(Data(partial)) else {
                return XCTFail("expected needMoreData for a \(split)-byte prefix")
            }
        }
    }

    func testRejectsMalformedRequests() {
        guard case let .malformed(status, _) = MCPHTTPParser.parse(Data("GET /mcp\r\n\r\n".utf8)) else {
            return XCTFail("expected malformed request line")
        }
        XCTAssertEqual(status, 400)

        let badLength = Data("POST /mcp HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)
        guard case let .malformed(lengthStatus, _) = MCPHTTPParser.parse(badLength) else {
            return XCTFail("expected malformed content length")
        }
        XCTAssertEqual(lengthStatus, 400)

        let tooLarge = Data(("POST /mcp HTTP/1.1\r\nContent-Length: \(MCPHTTPParser.maximumBodyBytes + 1)\r\n\r\n").utf8)
        guard case let .malformed(sizeStatus, _) = MCPHTTPParser.parse(tooLarge) else {
            return XCTFail("expected payload rejection")
        }
        XCTAssertEqual(sizeStatus, 413)
    }

    func testSerializesResponseWithLengthAndConnectionHeader() {
        let response = MCPHTTPResponse.json(["ok": true])
        let serialized = String(data: response.serialized(), encoding: .utf8) ?? ""
        XCTAssertTrue(serialized.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(serialized.contains("Content-Length: "))
        XCTAssertTrue(serialized.contains("Connection: close"))
        XCTAssertTrue(serialized.hasSuffix("{\"ok\":true}"))
    }

    // MARK: - Credentials

    func testBearerTokenParsing() {
        XCTAssertEqual(MCPGateway.bearerToken(from: "Bearer abc"), "abc")
        XCTAssertEqual(MCPGateway.bearerToken(from: "bearer  abc "), "abc")
        XCTAssertNil(MCPGateway.bearerToken(from: "Basic abc"))
        XCTAssertNil(MCPGateway.bearerToken(from: "Bearer"))
    }

    func testSecureComparison() {
        XCTAssertTrue(MCPSettings.secureEquals("token", "token"))
        XCTAssertFalse(MCPSettings.secureEquals("token", "Token"))
        XCTAssertFalse(MCPSettings.secureEquals("token", "token "))
    }

    func testAllowedOrigins() {
        XCTAssertTrue(MCPGateway.isAllowedOrigin("http://127.0.0.1:5173"))
        XCTAssertTrue(MCPGateway.isAllowedOrigin("http://localhost:3000"))
        XCTAssertFalse(MCPGateway.isAllowedOrigin("https://example.com"))
        XCTAssertFalse(MCPGateway.isAllowedOrigin("file:///tmp/x"))
        XCTAssertFalse(MCPGateway.isAllowedOrigin(""))
    }

    func testTokenGenerationAndRotation() throws {
        let suiteName = "MCPProtocolTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = MCPSettings(defaults: defaults)

        XCTAssertNil(settings.token(creatingIfNeeded: false))
        let token = try XCTUnwrap(settings.token())
        XCTAssertGreaterThanOrEqual(token.count, 32)
        XCTAssertEqual(settings.token(), token)

        let rotated = try XCTUnwrap(settings.rotateToken())
        XCTAssertNotEqual(rotated, token)
        XCTAssertEqual(settings.token(), rotated)

        XCTAssertEqual(settings.port, MCPSettings.defaultPort)
        settings.setPort(19999)
        XCTAssertEqual(settings.port, 19999)
        settings.setPort(80)
        XCTAssertEqual(settings.port, MCPSettings.defaultPort)

        let configuration = settings.clientConfiguration()
        XCTAssertTrue(configuration.contains("mcpServers"))
        XCTAssertTrue(configuration.contains("Bearer " + rotated))
    }
}
