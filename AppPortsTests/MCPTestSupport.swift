import Foundation
import XCTest
@testable import AppPorts

/// Shared fixtures for MCP tests. Every fixture uses a disposable directory and
/// injected service/store instances, so no test reads or writes real records.
enum MCPTestSupport {
    struct Fixture {
        let root: URL
        let localDirectory: URL
        let store: AppTransferStore
        let center: MigrationTaskCenter
        let operations: AppOperationState
    }

    static func appItem(path: URL, status: String = AppStatus.local, running: Bool = false,
                        system: Bool = false, appStore: Bool = false, ios: Bool = false,
                        folder: Bool = false, needsLock: Bool = false) -> AppItem {
        var item = AppItem(name: path.lastPathComponent, path: path, bundleURL: path, status: status,
                           isSystemApp: system, isRunning: running, isAppStoreApp: appStore,
                           isIOSApp: ios, needsLock: needsLock)
        if folder {
            item.isFolder = true
            item.containerKind = .appSuiteFolder
            item.appCount = 1
        }
        return item
    }

    /// Builds a tool service whose environment never reaches the real filesystem
    /// beyond the disposable fixture directory.
    @MainActor
    static func makeService(localApps: [AppItem] = [], externalApps: [AppItem] = [],
                            hasExternalRoot: Bool = true,
                            sameVolume: Bool = false,
                            needsUpdateProtection: Bool = false,
                            policyOptions: AppMigrationPolicy.Options = .init(allowAppStoreMigration: true,
                                                                              allowIOSAppMigration: false),
                            running: Set<URL> = [],
                            migration: @escaping @Sendable (AppItem, URL, Bool, DataTransferProgress) async throws -> String? = { _, _, _, _ in nil },
                            restore: @escaping @Sendable (AppItem, URL, DataTransferProgress) async throws -> String? = { _, _, _ in nil })
    throws -> (MCPToolService, Fixture) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPToolServiceTests-\(UUID().uuidString)", isDirectory: true)
        let local = base.appendingPathComponent("Local", isDirectory: true)
        let external = base.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let store = AppTransferStore(directoryURL: base.appendingPathComponent("app-transfers", isDirectory: true))
        let operations = AppOperationState(notificationCenter: NotificationCenter())
        let center = MigrationTaskCenter(
            historyStore: MigrationTaskHistoryStore(fileURL: base.appendingPathComponent("history.json")),
            operationState: operations,
            makeOperationLock: { OperationLock(fileURL: base.appendingPathComponent("operation.lock")) }
        )
        let fixture = Fixture(root: external, localDirectory: local, store: store, center: center,
                              operations: operations)

        let environment = MCPToolService.Environment(
            applicationVersion: { "9.9.9 (1)" },
            externalRoot: { hasExternalRoot ? external : nil },
            localAppsDirectories: { [local] },
            customLocalDirectories: { [] },
            runningApplications: { running },
            scanLocal: { _, _, _ in localApps },
            scanExternal: { _, _ in externalApps },
            store: store,
            taskCenter: center,
            operations: operations,
            migrationService: { AppMigrationService(transferStore: store) },
            isSameVolume: { _, _ in sameVolume },
            needsUpdateProtection: { _ in needsUpdateProtection },
            policyOptions: { policyOptions },
            migrationOperation: migration,
            restoreOperation: restore
        )
        return (MCPToolService(environment: environment), fixture)
    }

    static func cleanup(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent())
    }

    /// Polls the task center until the job reaches a terminal state.
    @MainActor
    static func waitForJob(_ id: UUID, in center: MigrationTaskCenter,
                           timeout: TimeInterval = 5) async -> MigrationJob? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = center.jobs.first(where: { $0.id == id }), job.status.isFinished {
                return job
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return center.jobs.first(where: { $0.id == id })
    }

    /// Runs one tool call and decodes the JSON text payload.
    static func payload(_ result: MCPToolResult) throws -> [String: Any] {
        let data = Data(result.text.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
