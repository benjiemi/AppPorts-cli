import Foundation
import XCTest
@testable import AppPorts

/// Fixtures for the path and data migration tools. Every stub stays inside a
/// disposable directory, so no test reads the real home directory, mount store
/// or WeChat account.
enum MCPDataTestSupport {
    struct Fixture {
        let base: URL
        let localApps: URL
        let external: URL
        let appPath: URL
        let dataPath: URL
        let toolPath: URL
        let customLocal: URL
        let customExternal: URL
        let accountPath: URL
        let messagePath: URL
        let businessPath: URL
        let store: AppTransferStore
        let center: MigrationTaskCenter
        let operations: AppOperationState
    }

    final class OperationRecorder: @unchecked Sendable {
        enum Kind: String {
            case link, mount, restore, mountRestore, weChatMigrate, weChatRestore, prepare
        }

        private let lock = NSLock()
        private var storage: [Kind: [String]] = [:]

        func record(_ kind: Kind, _ value: String) {
            lock.lock()
            defer { lock.unlock() }
            storage[kind, default: []].append(value)
        }

        func values(_ kind: Kind) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage[kind] ?? []
        }
    }

    struct Build {
        var status: String = DataDirStatus.local
        var requiresMount: Bool = false
        var type: DataDirType = .caches
        var hasExternalRoot: Bool = true
        var classic: Bool = false
        var splitEnabled: Bool = true
        var fullDiskAccess: Bool = true
        var installationAllowed: Bool = true
        var sameVolume: Bool = false
        var preflight: MountMigrationPreflight.Outcome = .ready(availableBytes: nil)
        var mounts: [ContainerMountRecord] = []
        var managedLinks: [ManagedDataLinkRecord] = []
        var inspectionError: Error?
        var pendingTransferPaths: Set<String> = []
        var dataPathPendingTransfer: Bool = false
        var appRunning: Bool = false
        var mountAtDataPath: Bool = false
        var accountState: WeChatAccountMigrationService.State = .local
        var toolStatus: String = DataDirStatus.local
        var customStatus: String = CustomDirStatus.local
    }

    /// Builds a service whose environment never reaches the real filesystem
    /// beyond the disposable fixture directory.
    @MainActor
    static func makeService(_ build: Build = Build())
    throws -> (service: MCPToolService, fixture: Fixture, recorder: OperationRecorder) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPDataToolServiceTests-\(UUID().uuidString)", isDirectory: true)
        let localApps = base.appendingPathComponent("Local", isDirectory: true)
        let external = base.appendingPathComponent("External", isDirectory: true)
        let appPath = localApps.appendingPathComponent("Foo.app", isDirectory: true)
        let dataPath = base.appendingPathComponent("Data/FooData", isDirectory: true)
        let toolPath = base.appendingPathComponent(".npm", isDirectory: true)
        let customLocal = base.appendingPathComponent("CustomDocs", isDirectory: true)
        let customExternal = external.appendingPathComponent("CustomDocs", isDirectory: true)
        let accountPath = base.appendingPathComponent("wechat/wxid_test", isDirectory: true)
        let messagePath = accountPath.appendingPathComponent("msg", isDirectory: true)
        let businessPath = accountPath.appendingPathComponent("business", isDirectory: true)
        let weChatAppPath = localApps.appendingPathComponent("WeChat.app", isDirectory: true)
        for directory in [localApps, external, appPath, weChatAppPath, dataPath, toolPath, customLocal,
                          accountPath, messagePath, businessPath] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let store = AppTransferStore(directoryURL: base.appendingPathComponent("app-transfers", isDirectory: true))
        let operations = AppOperationState(notificationCenter: NotificationCenter())
        let center = MigrationTaskCenter(
            historyStore: MigrationTaskHistoryStore(fileURL: base.appendingPathComponent("history.json")),
            operationState: operations,
            makeOperationLock: { OperationLock(fileURL: base.appendingPathComponent("operation.lock")) }
        )
        let fixture = Fixture(base: base, localApps: localApps, external: external, appPath: appPath,
                              dataPath: dataPath, toolPath: toolPath, customLocal: customLocal,
                              customExternal: customExternal, accountPath: accountPath,
                              messagePath: messagePath, businessPath: businessPath,
                              store: store, center: center, operations: operations)
        let recorder = OperationRecorder()
        let hasExternalRoot = build.hasExternalRoot
        let appItem = MCPTestSupport.appItem(path: appPath)
        let weChatApp = MCPTestSupport.appItem(path: weChatAppPath)

        let dataItem = DataDirItem(name: "FooData", path: dataPath, type: build.type,
                                   priority: .optional, description: build.type.rawValue,
                                   status: build.status, sizeBytes: 2048,
                                   requiresMountMigration: build.requiresMount)
        let toolItem = DataDirItem(name: ".npm", path: toolPath, type: .dotFolder,
                                   priority: .optional, description: "工具目录",
                                   status: build.toolStatus, sizeBytes: 512)
        let accountItem = DataDirItem(name: accountPath.lastPathComponent, path: accountPath,
                                      type: .containers, priority: .critical,
                                      description: "微信账号数据", sizeBytes: 4096)
        let config = CustomDirConfig(localPath: customLocal.path, externalBasePath: external.path)
        let localEntry = CustomDirEntry(config: config, kind: .local, url: customLocal,
                                        status: build.customStatus, size: "1 MB", sizeBytes: 1024)
        let externalEntry = CustomDirEntry(config: config, kind: .external, url: customExternal,
                                           status: build.customStatus, size: "1 MB", sizeBytes: 1024)
        let pair = CustomDirPair(config: config, local: localEntry, external: externalEntry)
        let sizing = WeChatAccountMigrationService.Sizing(total: DirectorySizeResult(bytes: 4096),
                                                          media: DirectorySizeResult(bytes: 1024))
        let splitEnabled = build.splitEnabled
        let fda = build.fullDiskAccess
        let installationAllowed = build.installationAllowed
        let preflight = build.preflight
        let accountState = build.accountState
        let accountsRoot = accountPath.deletingLastPathComponent()

        let environment = MCPToolService.Environment(
            applicationVersion: { "9.9.9 (1)" },
            externalRoot: { hasExternalRoot ? external : nil },
            localAppsDirectories: { [localApps] },
            customLocalDirectories: { [] },
            runningApplications: { [] },
            scanLocal: { _, _, _ in [appItem, weChatApp] },
            scanExternal: { _, _ in [] },
            store: store,
            taskCenter: center,
            operations: operations,
            migrationService: { AppMigrationService(transferStore: store) },
            isSameVolume: { _, _ in build.sameVolume },
            needsUpdateProtection: { _ in false },
            policyOptions: { AppMigrationPolicy.Options(allowAppStoreMigration: true,
                                                        allowIOSAppMigration: false) },
            migrationOperation: { _, _, _, _ in nil },
            restoreOperation: { _, _, _ in nil }
        )

        let dataEnvironment = MCPToolService.DataEnvironment(
            isClassicModeActive: { build.classic },
            isPartialWeChatMigrationEnabled: { _ in splitEnabled },
            weChatContainerIdentifier: { PartialWeChatMigrationPolicy.bundleIdentifier },
            weChatAppURL: { weChatAppPath },
            isWeChatAccountPath: { url in
                let path = url.standardizedFileURL.path
                return path == accountPath.path || path.hasPrefix(accountsRoot.path + "/")
            },
            weChatMemberPaths: { _ in [messagePath, businessPath] },
            fullDiskAccessGranted: { fda },
            installationLocationAllowed: { installationAllowed },
            scanAppData: { app, _ in
                if app.path.standardizedFileURL == weChatAppPath.standardizedFileURL {
                    return DataDirScanResult(items: [accountItem], readIssues: [])
                }
                return DataDirScanResult(items: [dataItem, toolItem], readIssues: [])
            },
            scanToolDirectories: { _ in [toolItem] },
            customConfigurations: { [config] },
            scanCustomDirectories: { _, _ in [pair] },
            mountInspection: {
                if let error = build.inspectionError { throw error }
                var mounts = build.mounts
                if build.mountAtDataPath {
                    mounts.append(ContainerMountRecord(
                        appName: "Foo", bundleIdentifier: nil,
                        dataDirType: DataDirType.containers.rawValue,
                        mountPointPath: dataPath.path,
                        volumeUUID: "TEST-VOLUME-UUID", volumeName: "FooData",
                        externalRootPath: external.path))
                }
                return ContainerMountStore.Inspection(mounts: mounts, cleanups: [],
                                                      transfers: [], managedLinks: build.managedLinks,
                                                      remountInterventions: [:], preservedMaterials: [],
                                                      validationError: nil)
            },
            hasPendingTransfer: { paths in
                if build.dataPathPendingTransfer, paths.contains(dataPath.standardizedFileURL.path) { return true }
                return paths.contains(where: build.pendingTransferPaths.contains)
            },
            isApplicationRunning: { _, _ in build.appRunning },
            weChatState: { _ in accountState },
            weChatSizing: { _ in sizing },
            mountPreflight: { _, _ in preflight },
            prepareDataMigration: { item, _, _, _ in
                recorder.record(.prepare, item.path.path)
                return item
            },
            symlinkOperation: { item, destination, _ in
                recorder.record(.link, destination.path + "/" + item.path.lastPathComponent)
                return nil
            },
            mountOperation: { item, root, _ in
                recorder.record(.mount, root.path + "/" + item.path.lastPathComponent)
                return nil
            },
            restoreOperation: { item, _ in
                recorder.record(.restore, item.path.path)
                return nil
            },
            mountRestoreOperation: { record, _, _ in
                recorder.record(.mountRestore, record.mountPointPath)
                return nil
            },
            weChatMigrate: { account, mode, _, _ in
                recorder.record(.weChatMigrate, account.path + "#" + (mode == .split ? "split" : "whole"))
                return []
            },
            weChatRestore: { account, _ in
                recorder.record(.weChatRestore, account.path)
                return []
            }
        )
        return (MCPToolService(environment: environment, dataEnvironment: dataEnvironment),
                fixture, recorder)
    }

    static func cleanup(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.base)
    }

    @MainActor
    static func settledJob(_ id: UUID, in center: MigrationTaskCenter,
                           timeout: TimeInterval = 5) async throws -> MigrationJob {
        let job = await waitForJob(id, in: center, timeout: timeout)
        return try XCTUnwrap(job, "task did not settle")
    }

    @MainActor
    static func waitForJob(_ id: UUID, in center: MigrationTaskCenter,
                           timeout: TimeInterval = 5) async -> MigrationJob? {
        await MCPTestSupport.waitForJob(id, in: center, timeout: timeout)
    }
}
