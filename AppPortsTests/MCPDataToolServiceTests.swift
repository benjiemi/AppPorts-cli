import XCTest
@testable import AppPorts

/// Covers the path and data migration tools: catalog wiring, argument and
/// precheck behavior, task-center submission, and the read-only listings.
/// Every fixture lives in a disposable directory created by MCPDataTestSupport.
@MainActor
final class MCPDataToolServiceTests: XCTestCase {
    // MARK: - Catalog

    func testCatalogAddsPathAndDataTools() {
        let names = Set(MCPToolService.tools.map(\.name))
        for name in ["appports_list_paths", "appports_migrate_path", "appports_restore_path",
                     "appports_list_data_migrations", "appports_migrate_wechat_account",
                     "appports_restore_wechat_account"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertEqual(MCPToolService.tools.count, 13)
        XCTAssertEqual(MCPToolService.tools.filter(\.readOnly).count, 6)
        XCTAssertEqual(MCPToolService.definition(named: "appports_list_paths")?.readOnly, true)
        XCTAssertEqual(MCPToolService.definition(named: "appports_list_data_migrations")?.readOnly, true)
        XCTAssertEqual(MCPToolService.definition(named: "appports_migrate_path")?.destructive, true)
        XCTAssertEqual(MCPToolService.definition(named: "appports_restore_path")?.destructive, true)
        XCTAssertEqual(MCPToolService.definition(named: "appports_migrate_wechat_account")?.readOnly, false)
        XCTAssertEqual(MCPToolService.definition(named: "appports_restore_wechat_account")?.readOnly, false)
        let migrate = MCPToolService.definition(named: "appports_migrate_path")!
        XCTAssertEqual(migrate.inputSchema["required"] as? [String], ["path"])
        let properties = migrate.inputSchema["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(properties.keys), ["path", "app_path", "destination_root", "mode"])
    }

    func testDispatchRejectsUnknownTool() async {
        let (service, fixture, _) = try! make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        do {
            _ = try await service.call(name: "appports_watch", arguments: [:])
            XCTFail("unknown tool must throw")
        } catch let error as MCPToolError {
            guard case let .unknownTool(name) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(name, "appports_watch")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testDispatchValidatesArguments() async {
        let (service, fixture, _) = try! make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        do {
            _ = try await service.call(name: "appports_migrate_path", arguments: [:])
            XCTFail("missing path must throw")
        } catch let error as MCPToolError {
            guard case .invalidArguments = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        do {
            _ = try await service.call(name: "appports_migrate_path",
                                       arguments: ["path": fixture.toolPath.path, "mode": "copy"])
            XCTFail("unknown mode must throw")
        } catch let error as MCPToolError {
            guard case let .invalidArguments(message) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertTrue(message.contains("mode"), message)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - list_paths

    func testListPathsGroupsToolCustomAndManagerRecords() async throws {
        let link = ManagedDataLinkRecord(operationID: UUID(), originalPath: "/tmp/original",
                                         destinationPath: "/tmp/external",
                                         destinationIdentity: DataPathIdentity(device: 1, inode: 2),
                                         appName: "Foo", dataDirType: DataDirType.caches.rawValue)
        let (service, fixture, _) = try make(.init(managedLinks: [link]))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let all = try await service.call(name: "appports_list_paths", arguments: ["scope": "all"])
        XCTAssertFalse(all.isError)
        let payload = try MCPTestSupport.payload(all)
        XCTAssertEqual(payload["scope"] as? String, "all")
        let tools = try XCTUnwrap(payload["tool_directories"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertTrue(all.text.contains(".npm"))
        let custom = try XCTUnwrap(payload["custom_directories"] as? [[String: Any]])
        XCTAssertEqual(custom.count, 1)
        let links = try XCTUnwrap(payload["managed_links"] as? [[String: Any]])
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(all.text.contains("/tmp/original"))
    }

    func testListPathsWithoutAppPathExplainsAttribution() async throws {
        let (service, fixture, _) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_list_paths", arguments: ["scope": "app"])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual((payload["app_data"] as? [[String: Any]])?.count, 0)
        let notes = try XCTUnwrap(payload["notes"] as? [String])
        XCTAssertTrue(notes.contains { $0.contains("app_path") })
    }

    func testListPathsRejectsUnknownApp() async throws {
        let (service, fixture, _) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_list_paths",
                                            arguments: ["scope": "app",
                                                        "app_path": fixture.base.appendingPathComponent("Ghost.app").path])
        XCTAssertEqual(try code(of: result), "APP_NOT_FOUND")
    }

    // MARK: - migrate_path prechecks

    func testMigratePathRequiresDestinationRoot() async throws {
        let (service, fixture, _) = try make(.init(hasExternalRoot: false))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.dataPath.path,
                                                        "app_path": fixture.appPath.path])
        XCTAssertEqual(try code(of: result), "NO_EXTERNAL_ROOT")
    }

    func testMigratePathRejectsMissingDirectory() async throws {
        let (service, fixture, _) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.base.appendingPathComponent("Absent").path])
        XCTAssertEqual(try code(of: result), "PATH_NOT_FOUND")
    }

    func testMigratePathRequiresAttributionForAppData() async throws {
        let (service, fixture, _) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.dataPath.path])
        XCTAssertEqual(try code(of: result), "APP_REQUIRED")
    }

    func testMigratePathRequiresFullDiskAccessAndInstallationLocation() async throws {
        let (denied, deniedFixture, _) = try make(.init(fullDiskAccess: false))
        defer { MCPDataTestSupport.cleanup(deniedFixture) }
        let deniedResult = try await denied.call(name: "appports_migrate_path",
                                                 arguments: ["path": deniedFixture.dataPath.path,
                                                             "app_path": deniedFixture.appPath.path])
        XCTAssertEqual(try code(of: deniedResult), "ACCESS_DENIED")

        let (moved, movedFixture, _) = try make(.init(installationAllowed: false))
        defer { MCPDataTestSupport.cleanup(movedFixture) }
        let movedResult = try await moved.call(name: "appports_migrate_path",
                                               arguments: ["path": movedFixture.dataPath.path,
                                                           "app_path": movedFixture.appPath.path])
        XCTAssertEqual(try code(of: movedResult), "INSTALLATION_LOCATION")
    }

    func testCustomDirectoryMigrationKeepsWorkingOutsideInstallationLocation() async throws {
        let (service, fixture, recorder) = try make(.init(fullDiskAccess: false, installationAllowed: false))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.customLocal.path, "mode": "link"])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertNil(payload["error"])
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload["task_id"] as? String)))
        let job = try await MCPDataTestSupport.settledJob(taskID, in: fixture.center)
        XCTAssertEqual(job.category, .directories)
        XCTAssertEqual(recorder.values(.link).count, 1)
    }

    func testMigratePathRejectsContainerSymlinkWithoutClassicMode() async throws {
        let (service, fixture, _) = try make(.init(requiresMount: true, type: .containers))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.dataPath.path,
                                                        "app_path": fixture.appPath.path,
                                                        "mode": "link"])
        XCTAssertEqual(try code(of: result), "MOUNT_REQUIRED")
    }

    func testMigratePathRejectsMountModeForSymlinkOnlyDirectory() async throws {
        let (service, fixture, _) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        do {
            _ = try await service.call(name: "appports_migrate_path",
                                       arguments: ["path": fixture.toolPath.path, "mode": "mount"])
            XCTFail("mount mode on a tool directory must be rejected")
        } catch let error as MCPToolError {
            guard case let .invalidArguments(message) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertTrue(message.contains(".npm"), message)
        }
    }

    func testMigratePathRejectsAlreadyMigratedRunningAndPendingTransfers() async throws {
        let (migrated, migratedFixture, _) = try make(.init(status: DataDirStatus.linked))
        defer { MCPDataTestSupport.cleanup(migratedFixture) }
        let migratedResult = try await migrated.call(name: "appports_migrate_path",
                                                     arguments: ["path": migratedFixture.dataPath.path,
                                                                 "app_path": migratedFixture.appPath.path])
        XCTAssertEqual(try code(of: migratedResult), "ALREADY_MIGRATED")

        let (running, runningFixture, _) = try make(.init(appRunning: true))
        defer { MCPDataTestSupport.cleanup(runningFixture) }
        let runningResult = try await running.call(name: "appports_migrate_path",
                                                   arguments: ["path": runningFixture.dataPath.path,
                                                               "app_path": runningFixture.appPath.path])
        XCTAssertEqual(try code(of: runningResult), "RUNNING")

        let (pending, pendingFixture, _) = try make(.init(dataPathPendingTransfer: true))
        defer { MCPDataTestSupport.cleanup(pendingFixture) }
        let pendingResult = try await pending.call(name: "appports_migrate_path",
                                                   arguments: ["path": pendingFixture.dataPath.path,
                                                               "app_path": pendingFixture.appPath.path])
        XCTAssertEqual(try code(of: pendingResult), "PENDING_TRANSFER")
    }

    func testMigratePathRejectsSameVolumeDestination() async throws {
        let (service, fixture, _) = try make(.init(sameVolume: true))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.dataPath.path,
                                                        "app_path": fixture.appPath.path])
        XCTAssertEqual(try code(of: result), "DESTINATION_NOT_EXTERNAL")
    }

    func testMigratePathValidatesMountPreflight() async throws {
        let cases: [(MountMigrationPreflight.Outcome, String)] = [
            (.notAPFS(filesystem: "ExFAT"), "DESTINATION_NOT_APFS"),
            (.encrypted, "ENCRYPTION_PASSWORD_REQUIRED"),
            (.destinationUnavailable, "DESTINATION_UNAVAILABLE"),
            (.insufficientSpace(requiredBytes: 4096, availableBytes: 128), "INSUFFICIENT_SPACE"),
        ]
        for (outcome, expected) in cases {
            let (service, fixture, _) = try make(.init(requiresMount: true, type: .containers, preflight: outcome))
            defer { MCPDataTestSupport.cleanup(fixture) }
            let result = try await service.call(name: "appports_migrate_path",
                                                arguments: ["path": fixture.dataPath.path,
                                                            "app_path": fixture.appPath.path])
            XCTAssertEqual(try code(of: result), expected)
        }
    }

    // MARK: - migrate_path submission

    func testMigratePathSubmitsLinkTaskAndRunsOperation() async throws {
        let (service, fixture, recorder) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.dataPath.path,
                                                        "app_path": fixture.appPath.path])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual(payload["mode"] as? String, "link")
        XCTAssertEqual(payload["status"] as? String, "queued")
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload["task_id"] as? String)))
        let job = try await MCPDataTestSupport.settledJob(taskID, in: fixture.center)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.category, .appData)
        XCTAssertTrue(job.title.contains("FooData"))
        let destination = try XCTUnwrap(recorder.values(.link).first)
        XCTAssertTrue(destination.hasSuffix("Caches/FooData"), destination)
        XCTAssertEqual(recorder.values(.prepare), [fixture.dataPath.path])
        XCTAssertTrue(recorder.values(.mount).isEmpty)
    }

    func testMigrateToolDirectoryUsesToolsCategory() async throws {
        let (service, fixture, recorder) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.toolPath.path])
        let payload = try MCPTestSupport.payload(result)
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload["task_id"] as? String)))
        let job = try await MCPDataTestSupport.settledJob(taskID, in: fixture.center)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.category, .tools)
        XCTAssertTrue(recorder.values(.prepare).isEmpty, "tool directories skip app data preparation")
    }

    func testMigratePathSubmitsMountTaskForContainer() async throws {
        let (service, fixture, recorder) = try make(.init(requiresMount: true, type: .containers))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.dataPath.path,
                                                        "app_path": fixture.appPath.path])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual(payload["mode"] as? String, "mount")
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload["task_id"] as? String)))
        let job = try await MCPDataTestSupport.settledJob(taskID, in: fixture.center)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.resources.keys, ["apfs-layout"])
        XCTAssertEqual(recorder.values(.mount).count, 1)
        XCTAssertTrue(recorder.values(.link).isEmpty)
    }

    // MARK: - restore_path

    func testRestorePathRejectsLocalDirectory() async throws {
        let (service, fixture, _) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_restore_path",
                                            arguments: ["path": fixture.dataPath.path,
                                                        "app_path": fixture.appPath.path])
        XCTAssertEqual(try code(of: result), "NOT_MIGRATED")
    }

    func testRestorePathRejectsUnknownRecord() async throws {
        let (service, fixture, _) = try make(.init(status: DataDirStatus.missing))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_restore_path",
                                            arguments: ["path": fixture.dataPath.path,
                                                        "app_path": fixture.appPath.path])
        XCTAssertEqual(try code(of: result), "NO_MIGRATION_RECORD")
    }

    func testRestorePathSubmitsLinkRestore() async throws {
        let (service, fixture, recorder) = try make(.init(toolStatus: DataDirStatus.linked))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_restore_path",
                                            arguments: ["path": fixture.toolPath.path])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual(payload["mode"] as? String, "link")
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload["task_id"] as? String)))
        let job = try await MCPDataTestSupport.settledJob(taskID, in: fixture.center)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(recorder.values(.restore), [fixture.toolPath.path])
    }

    func testRestorePathPrefersMountRecord() async throws {
        let (service, fixture, recorder) = try make(.init(status: DataDirStatus.mounted,
                                                          requiresMount: true,
                                                          type: .containers,
                                                          mountAtDataPath: true))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_restore_path",
                                            arguments: ["path": fixture.dataPath.path,
                                                        "app_path": fixture.appPath.path])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual(payload["mode"] as? String, "mount")
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload["task_id"] as? String)))
        let job = try await MCPDataTestSupport.settledJob(taskID, in: fixture.center)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(recorder.values(.mountRestore), [fixture.dataPath.path])
        XCTAssertTrue(recorder.values(.restore).isEmpty)
    }

    // MARK: - list_data_migrations

    func testListDataMigrationsReportsRecordsAndWeChatState() async throws {
        let (service, fixture, _) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_list_data_migrations", arguments: [:])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual((payload["mounts"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((payload["managed_links"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(payload["unfinished_transfers"] as? Int, 0)
        let accounts = try XCTUnwrap(payload["wechat_accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(payload["wechat_split_enabled"] as? Bool, true)
    }

    func testListDataMigrationsReportsUnreadableStore() async throws {
        struct Broken: Error {}
        let (service, fixture, _) = try make(.init(inspectionError: Broken()))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_list_data_migrations", arguments: [:])
        XCTAssertEqual(try code(of: result), "STORE_UNREADABLE")
    }

    // MARK: - WeChat accounts

    func testPathToolsRedirectWeChatAccountPaths() async throws {
        let (service, fixture, _) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_path",
                                            arguments: ["path": fixture.accountPath.path])
        XCTAssertEqual(try code(of: result), "WECHAT_ACCOUNT")
        let restore = try await service.call(name: "appports_restore_path",
                                             arguments: ["path": fixture.accountPath.path])
        XCTAssertEqual(try code(of: restore), "WECHAT_ACCOUNT")
    }

    func testWeChatMigrationRequiresEnabledSplit() async throws {
        let (service, fixture, _) = try make(.init(splitEnabled: false))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_wechat_account",
                                            arguments: ["account_path": fixture.accountPath.path])
        XCTAssertEqual(try code(of: result), "WECHAT_DISABLED")
    }

    func testWeChatMigrationRejectsMigratedAndConflictingAccounts() async throws {
        let (split, splitFixture, _) = try make(.init(accountState: .split))
        defer { MCPDataTestSupport.cleanup(splitFixture) }
        let splitResult = try await split.call(name: "appports_migrate_wechat_account",
                                               arguments: ["account_path": splitFixture.accountPath.path])
        XCTAssertEqual(try code(of: splitResult), "RESTORE_FIRST")

        let (conflict, conflictFixture, _) = try make(.init(accountState: .conflict))
        defer { MCPDataTestSupport.cleanup(conflictFixture) }
        let conflictResult = try await conflict.call(name: "appports_migrate_wechat_account",
                                                     arguments: ["account_path": conflictFixture.accountPath.path])
        XCTAssertEqual(try code(of: conflictResult), "WECHAT_CONFLICT")
    }

    func testWeChatMigrationRejectsNonAccountPath() async throws {
        let (service, fixture, _) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_wechat_account",
                                            arguments: ["account_path": fixture.base.appendingPathComponent("not-wechat").path])
        XCTAssertEqual(try code(of: result), "ACCOUNT_NOT_FOUND")
    }

    func testWeChatSplitMigrationSubmitsTask() async throws {
        let (service, fixture, recorder) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_wechat_account",
                                            arguments: ["account_path": fixture.accountPath.path, "mode": "split"])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual(payload["mode"] as? String, "split")
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload["task_id"] as? String)))
        let job = try await MCPDataTestSupport.settledJob(taskID, in: fixture.center)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.category, .appData)
        XCTAssertEqual(job.resources.keys, ["apfs-layout"])
        XCTAssertEqual(recorder.values(.weChatMigrate).count, 1)
        XCTAssertTrue(try XCTUnwrap(recorder.values(.weChatMigrate).first).hasSuffix("#split"))
    }

    func testWeChatWholeMigrationUsesWholeMode() async throws {
        let (service, fixture, recorder) = try make()
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_migrate_wechat_account",
                                            arguments: ["account_path": fixture.accountPath.path, "mode": "whole"])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual(payload["mode"] as? String, "whole")
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload["task_id"] as? String)))
        _ = try await MCPDataTestSupport.settledJob(taskID, in: fixture.center)
        XCTAssertEqual(recorder.values(.weChatMigrate).count, 1)
        XCTAssertTrue(try XCTUnwrap(recorder.values(.weChatMigrate).first).hasSuffix("#whole"))
    }

    func testWeChatRestoreRejectsLocalAndWholeStates() async throws {
        let (local, localFixture, _) = try make(.init(accountState: .local))
        defer { MCPDataTestSupport.cleanup(localFixture) }
        let localResult = try await local.call(name: "appports_restore_wechat_account",
                                               arguments: ["account_path": localFixture.accountPath.path])
        XCTAssertEqual(try code(of: localResult), "NOT_MIGRATED")

        let (whole, wholeFixture, _) = try make(.init(accountState: .whole))
        defer { MCPDataTestSupport.cleanup(wholeFixture) }
        let wholeResult = try await whole.call(name: "appports_restore_wechat_account",
                                               arguments: ["account_path": wholeFixture.accountPath.path])
        XCTAssertEqual(try code(of: wholeResult), "NOT_SPLIT_MIGRATED")
    }

    func testWeChatSplitRestoreSubmitsTask() async throws {
        let (service, fixture, recorder) = try make(.init(accountState: .split))
        defer { MCPDataTestSupport.cleanup(fixture) }
        let result = try await service.call(name: "appports_restore_wechat_account",
                                            arguments: ["account_path": fixture.accountPath.path])
        let payload = try MCPTestSupport.payload(result)
        XCTAssertEqual(payload["mode"] as? String, "split")
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload["task_id"] as? String)))
        let job = try await MCPDataTestSupport.settledJob(taskID, in: fixture.center)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(recorder.values(.weChatRestore), [fixture.accountPath.path])
    }

    // MARK: - Helpers

    private func make(_ build: MCPDataTestSupport.Build = MCPDataTestSupport.Build())
    throws -> (MCPToolService, MCPDataTestSupport.Fixture, MCPDataTestSupport.OperationRecorder) {
        try MCPDataTestSupport.makeService(build)
    }

    private func code(of result: MCPToolResult) throws -> String {
        XCTAssertTrue(result.isError, "expected a failure result, got \(result.text)")
        let payload = try MCPTestSupport.payload(result)
        return try XCTUnwrap(payload["error"] as? String)
    }
}
