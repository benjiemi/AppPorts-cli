import XCTest
@testable import AppPorts

@MainActor
final class MCPToolServiceTests: XCTestCase {
    private var fixtures: [MCPTestSupport.Fixture] = []

    override func tearDown() {
        for fixture in fixtures { MCPTestSupport.cleanup(fixture) }
        fixtures = []
        super.tearDown()
    }

    private func track(_ fixture: MCPTestSupport.Fixture) {
        fixtures.append(fixture)
    }

    // MARK: - Status

    func testStatusReportsVersionRootAndTaskCounts() async throws {
        let (service, fixture) = try MCPTestSupport.makeService()
        track(fixture)

        let result = try await service.call(name: "appports_status", arguments: [:])
        XCTAssertFalse(result.isError)
        let payload = try MCPTestSupport.payload(result)

        let app = try XCTUnwrap(payload["app"] as? [String: Any])
        XCTAssertEqual(app["version"] as? String, "9.9.9 (1)")
        XCTAssertEqual(payload["busy"] as? Bool, false)
        XCTAssertEqual((payload["tasks"] as? [String: Any])?["total"] as? Int, 0)
        XCTAssertEqual(payload["external_root"] as? String, fixture.root.path)
        let policy = try XCTUnwrap(payload["migration_policy"] as? [String: Any])
        XCTAssertNotNil(policy["allow_app_store"])
    }

    // MARK: - Listing

    func testListAppsFiltersScopeQueryAndSystemApps() async throws {
        let localApp = MCPTestSupport.appItem(path: URL(fileURLWithPath: "/Applications/Alpha.app"))
        let systemApp = MCPTestSupport.appItem(path: URL(fileURLWithPath: "/System/Applications/Safari.app"),
                                               system: true)
        let remoteApp = MCPTestSupport.appItem(path: URL(fileURLWithPath: "/Volumes/Ext/Applications/Beta.app"),
                                               status: AppStatus.linked)
        let (service, fixture) = try MCPTestSupport.makeService(localApps: [localApp, systemApp],
                                                                externalApps: [remoteApp])
        track(fixture)

        let all = try await service.call(name: "appports_list_apps", arguments: ["scope": "all"])
        let allPayload = try MCPTestSupport.payload(all)
        let localRows = try XCTUnwrap(allPayload["local"] as? [[String: Any]])
        XCTAssertEqual(localRows.count, 1, "system applications are hidden by default")
        XCTAssertEqual(localRows.first?["name"] as? String, "Alpha.app")
        XCTAssertEqual((allPayload["external"] as? [[String: Any]])?.count, 1)

        let withSystem = try await service.call(name: "appports_list_apps",
                                                arguments: ["scope": "local", "include_system": true])
        XCTAssertEqual((try MCPTestSupport.payload(withSystem)["local"] as? [[String: Any]])?.count, 2)

        let filtered = try await service.call(name: "appports_list_apps", arguments: ["query": "beta"])
        let filteredPayload = try MCPTestSupport.payload(filtered)
        XCTAssertEqual((filteredPayload["external"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((filteredPayload["local"] as? [[String: Any]])?.count, 0)
    }

    func testListAppsWithoutExternalRootExplainsWhy() async throws {
        let (service, fixture) = try MCPTestSupport.makeService(hasExternalRoot: false)
        track(fixture)
        let result = try await service.call(name: "appports_list_apps", arguments: ["scope": "external"])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual((payload["external"] as? [[String: Any]])?.count, 0)
        XCTAssertNotNil(payload["notes"])
    }

    func testListTransfersReturnsEmptyInventoryAndTasks() async throws {
        let (service, fixture) = try MCPTestSupport.makeService()
        track(fixture)
        let result = try await service.call(name: "appports_list_transfers", arguments: [:])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual((payload["transfers"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((payload["tasks"] as? [[String: Any]])?.count, 0)
        XCTAssertNotNil(payload["unreadable_records"])
    }

    // MARK: - Migration preflight

    func testMigrateRejectsMissingAppAndMissingRoot() async throws {
        let (noRootService, noRootFixture) = try MCPTestSupport.makeService(hasExternalRoot: false)
        track(noRootFixture)
        let noRoot = try await noRootService.call(
            name: "appports_migrate_app",
            arguments: ["app_path": noRootFixture.localDirectory.appendingPathComponent("Ghost.app").path]
        )
        XCTAssertTrue(noRoot.isError)
        XCTAssertTrue(noRoot.text.contains("NO_EXTERNAL_ROOT"))

        let (service, fixture) = try MCPTestSupport.makeService()
        track(fixture)
        let missing = try await service.call(
            name: "appports_migrate_app",
            arguments: ["app_path": fixture.localDirectory.appendingPathComponent("Ghost.app").path]
        )
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("APP_NOT_FOUND"))
    }

    func testMigrateRejectsSameVolumeDestination() async throws {
        let base = try makeTemporaryDirectory(prefix: "same-volume")
        let appURL = base.appendingPathComponent("Foo.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let app = MCPTestSupport.appItem(path: appURL)
        let (service, fixture) = try MCPTestSupport.makeService(localApps: [app], sameVolume: true)
        track(fixture)

        let result = try await service.call(name: "appports_migrate_app",
                                            arguments: ["app_path": appURL.path,
                                                        "destination_root": fixture.root.path])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("DESTINATION_NOT_EXTERNAL"))
        try? FileManager.default.removeItem(at: base)
    }

    func testMigrateRejectsPolicyViolations() async throws {
        let cases: [(String, Bool, Bool, String, Bool, String)] = [
            ("Running", true, false, AppStatus.local, false, "running"),
            ("Mail", false, true, AppStatus.local, false, "system_app"),
            ("Linked", false, false, AppStatus.linked, false, "already_linked"),
            ("Mobile", false, false, AppStatus.local, true, "ios_migration_disabled"),
        ]
        for (name, running, system, status, ios, code) in cases {
            let base = try makeTemporaryDirectory(prefix: "policy")
            let appURL = base.appendingPathComponent("\(name).app")
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            let app = MCPTestSupport.appItem(path: appURL, status: status, running: running,
                                             system: system, ios: ios)
            let (service, fixture) = try MCPTestSupport.makeService(localApps: [app])
            track(fixture)

            let result = try await service.call(name: "appports_migrate_app",
                                                arguments: ["app_path": appURL.path,
                                                            "destination_root": fixture.root.path])
            XCTAssertTrue(result.isError, code)
            XCTAssertTrue(result.text.contains(code), "expected \(code), got \(result.text)")
            try? FileManager.default.removeItem(at: base)
        }
    }

    func testMigrateRequiresExplicitUpdateProtection() async throws {
        let base = try makeTemporaryDirectory(prefix: "update-lock")
        let appURL = base.appendingPathComponent("Sparkle.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let app = MCPTestSupport.appItem(path: appURL, needsLock: true)
        let (service, fixture) = try MCPTestSupport.makeService(localApps: [app], needsUpdateProtection: true)
        track(fixture)

        let result = try await service.call(name: "appports_migrate_app",
                                            arguments: ["app_path": appURL.path,
                                                        "destination_root": fixture.root.path])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("UPDATE_LOCK_REQUIRED"))
        try? FileManager.default.removeItem(at: base)
    }

    func testMigrateRejectsOccupiedDestination() async throws {
        let base = try makeTemporaryDirectory(prefix: "occupied")
        let appURL = base.appendingPathComponent("Occupied.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let app = MCPTestSupport.appItem(path: appURL)
        let (service, fixture) = try MCPTestSupport.makeService(localApps: [app])
        track(fixture)
        let destination = AppSearchExclusionService.destination(for: app, in: fixture.root)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = try await service.call(name: "appports_migrate_app",
                                            arguments: ["app_path": appURL.path,
                                                        "destination_root": fixture.root.path])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("DESTINATION_OCCUPIED"))
        try? FileManager.default.removeItem(at: base)
    }

    func testMigrateSubmitsTaskThroughTaskCenter() async throws {
        let base = try makeTemporaryDirectory(prefix: "migrate")
        let appURL = base.appendingPathComponent("Runner.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let app = MCPTestSupport.appItem(path: appURL)
        let (service, fixture) = try MCPTestSupport.makeService(localApps: [app])
        track(fixture)

        let result = try await service.call(name: "appports_migrate_app",
                                            arguments: ["app_path": appURL.path,
                                                        "destination_root": fixture.root.path])
        XCTAssertFalse(result.isError, result.text)
        let payload = try MCPTestSupport.payload(result)
        let identifier = try XCTUnwrap(payload["task_id"] as? String)
        let taskID = try XCTUnwrap(UUID(uuidString: identifier))
        XCTAssertEqual(payload["status"] as? String, "queued")
        XCTAssertEqual(payload["destination"] as? String,
                       AppSearchExclusionService.destination(for: app, in: fixture.root).path)

        let job = try XCTUnwrap(fixture.center.jobs.first { $0.id == taskID })
        XCTAssertTrue(job.resources.paths.contains(appURL.standardizedFileURL.path))
        let finished = await MCPTestSupport.waitForJob(taskID, in: fixture.center)
        XCTAssertEqual(finished?.status, .completed)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Restore

    func testRestoreRequiresExternalRootAndMigratedApp() async throws {
        let (noRootService, noRootFixture) = try MCPTestSupport.makeService(hasExternalRoot: false)
        track(noRootFixture)
        let missingRoot = try await noRootService.call(
            name: "appports_restore_app",
            arguments: ["app_path": "/Volumes/Ext/Applications/Foo.app"]
        )
        XCTAssertTrue(missingRoot.isError)
        XCTAssertTrue(missingRoot.text.contains("NO_EXTERNAL_ROOT"))

        let (service, fixture) = try MCPTestSupport.makeService()
        track(fixture)
        let notMigrated = try await service.call(
            name: "appports_restore_app",
            arguments: ["app_path": fixture.localDirectory.appendingPathComponent("Nope.app").path]
        )
        XCTAssertTrue(notMigrated.isError)
        XCTAssertTrue(notMigrated.text.contains("APP_NOT_MIGRATED"))
    }

    func testRestoreSubmitsTaskForMigratedApp() async throws {
        let externalApp = MCPTestSupport.appItem(
            path: URL(fileURLWithPath: "/Volumes/Ext/Applications/Restore.app"),
            status: AppStatus.linked
        )
        let (service, fixture) = try MCPTestSupport.makeService(externalApps: [externalApp])
        track(fixture)

        let result = try await service.call(name: "appports_restore_app",
                                            arguments: ["app_path": externalApp.path.path])
        XCTAssertFalse(result.isError, result.text)
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual(payload["destination"] as? String,
                       fixture.localDirectory.appendingPathComponent("Restore.app").path)
        let identifier = try XCTUnwrap(payload["task_id"] as? String)
        let taskID = try XCTUnwrap(UUID(uuidString: identifier))
        let finished = await MCPTestSupport.waitForJob(taskID, in: fixture.center)
        XCTAssertEqual(finished?.status, .completed)
    }

    // MARK: - Tasks

    func testTaskLookupReportsMissingTask() async throws {
        let (service, fixture) = try MCPTestSupport.makeService()
        track(fixture)
        let result = try await service.call(name: "appports_task",
                                            arguments: ["task_id": UUID().uuidString])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("TASK_NOT_FOUND"))

        let list = try await service.call(name: "appports_task", arguments: [:])
        XCTAssertFalse(list.isError)
        XCTAssertNotNil(try MCPTestSupport.payload(list)["tasks"])
    }

    func testCancelReportsUnknownTask() async throws {
        let (service, fixture) = try MCPTestSupport.makeService()
        track(fixture)
        let unknown = try await service.call(name: "appports_cancel_task",
                                             arguments: ["task_id": UUID().uuidString])
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.text.contains("TASK_NOT_FOUND"))
    }

    func testUnknownToolAndInvalidArgumentsAreReported() async throws {
        let (service, fixture) = try MCPTestSupport.makeService()
        track(fixture)

        do {
            _ = try await service.call(name: "appports_unknown", arguments: [:])
            XCTFail("unknown tools must fail")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, "未知工具：appports_unknown")
        }

        do {
            _ = try await service.call(name: "appports_migrate_app", arguments: [:])
            XCTFail("missing app_path must fail")
        } catch let error as MCPToolError {
            guard case .invalidArguments = error else { return XCTFail("expected invalid arguments") }
        }
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
