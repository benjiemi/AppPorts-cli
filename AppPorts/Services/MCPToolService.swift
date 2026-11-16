//
//  MCPToolService.swift
//  AppPorts
//
//  Tool surface exposed to MCP clients. Every mutation reuses the same
//  migration services, task center and journals as the UI, so an AI-driven
//  migration is visible, cancellable and recoverable in the app.
//

import AppKit
import Foundation

// MARK: - Tool errors

enum MCPToolError: Error {
    case unknownTool(String)
    case invalidArguments(String)

    var message: String {
        switch self {
        case let .unknownTool(name): return "未知工具：\(name)"
        case let .invalidArguments(message): return message
        }
    }
}

// MARK: - Tool service

@MainActor
final class MCPToolService {
    struct Environment {
        var applicationVersion: () -> String
        var externalRoot: () -> URL?
        var localAppsDirectories: () -> [URL]
        var customLocalDirectories: () -> [URL]
        var runningApplications: () -> Set<URL>
        var scanLocal: (URL, Set<URL>, URL?) async -> [AppItem]
        var scanExternal: (URL, URL) async -> [AppItem]
        var store: AppTransferStore
        var taskCenter: MigrationTaskCenter
        var operations: AppOperationState
        var migrationService: () -> AppMigrationService
        /// Placement checks that tests can pin without touching real volumes.
        var isSameVolume: (URL, URL) -> Bool
        var needsUpdateProtection: (AppItem) -> Bool
        var policyOptions: () -> AppMigrationPolicy.Options
        /// One migration step. Injected so tests never touch the filesystem.
        var migrationOperation: @Sendable (AppItem, URL, Bool, DataTransferProgress) async throws -> String?
        /// One restore step, likewise injectable.
        var restoreOperation: @Sendable (AppItem, URL, DataTransferProgress) async throws -> String?

        @MainActor
        static func live() -> Environment {
            let defaults = UserDefaults.standard
            let localApps = URL(fileURLWithPath: "/Applications")
            return Environment(
                applicationVersion: {
                    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                    guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                        return short
                    }
                    return "\(short) (\(build))"
                },
                externalRoot: {
                    guard let path = defaults.string(forKey: "ExternalDrivePath"), !path.isEmpty else { return nil }
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else { return nil }
                    return url
                },
                localAppsDirectories: { [localApps] },
                customLocalDirectories: {
                    (defaults.stringArray(forKey: "customLocalScanPaths") ?? [])
                        .map { URL(fileURLWithPath: $0).standardizedFileURL }
                },
                runningApplications: {
                    Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL }
                        .map { $0.standardizedFileURL })
                },
                scanLocal: { directory, running, external in
                    await AppScanner().scanLocalApps(at: directory, runningAppURLs: running,
                                                     externalAppsDir: external)
                },
                scanExternal: { root, localDirectory in
                    await AppScanner().scanExternalApps(at: root, localAppsDir: localDirectory)
                },
                store: .shared,
                taskCenter: .shared,
                operations: .shared,
                migrationService: { AppMigrationService() },
                isSameVolume: { source, destination in
                    func volume(_ url: URL) -> URL? {
                        try? url.resourceValues(forKeys: [.volumeURLKey]).volume
                    }
                    guard let left = volume(source), let right = volume(destination) else { return false }
                    return left.standardizedFileURL == right.standardizedFileURL
                },
                needsUpdateProtection: { AppMigrationService().needsUpdateProtection($0) },
                policyOptions: { .current },
                migrationOperation: { app, destination, lockExternal, progress in
                    progress.setDirectory(app.path)
                    try await MigrationExecution.control?.checkpointAsync()
                    if app.isAppStoreApp && AppMigrationService.isMASExternalInstallSupported {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                    }
                    let running = await MigrationApplicationState.isRunning(appURL: app.displayURL)
                    let result = try await AppMigrationService().moveAndLink(
                        appToMove: app,
                        destinationURL: destination,
                        isRunning: running,
                        lockExternal: lockExternal,
                        replacementChoice: nil,
                        deleteSourceFallback: AppMigrationService.removeItemViaFinder(at:),
                        progressHandler: { progress.update($0) }
                    )
                    await MainActor.run {
                        let transfer = AppListTransfer.movedOut(
                            app,
                            destination: destination,
                            isMASExternal: app.isAppStoreApp && AppMigrationService.isMASExternalInstallSupported
                        )
                        do { try AppPortalMaintenance.recordCompletedTransfer(transfer) }
                        catch { AppLogger.shared.logError("保存 MCP 迁移后的搜索记录失败", error: error) }
                    }
                    return result.pendingMessage
                },
                restoreOperation: { app, localDestination, progress in
                    progress.setDirectory(app.path)
                    try await MigrationExecution.control?.checkpointAsync()
                    let result = try await AppMigrationService().moveBack(
                        app: app,
                        localDestinationURL: localDestination,
                        progressHandler: { progress.update($0) }
                    )
                    await MainActor.run {
                        let transfer = AppListTransfer.movedBack(
                            app,
                            localDestination: localDestination,
                            externalSourceRemains: result.externalSourceRemains,
                            retiredLocalURLs: result.retiredLocalPortalURLs
                        )
                        do { try AppPortalMaintenance.recordCompletedTransfer(transfer) }
                        catch { AppLogger.shared.logError("保存 MCP 回迁后的搜索记录失败", error: error) }
                    }
                    return result.transferResult.pendingMessage
                }
            )
        }
    }

    private let environment: Environment

    init(environment: Environment? = nil) {
        self.environment = environment ?? .live()
    }

    // MARK: Catalog

    nonisolated static let tools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "appports_status",
            title: "AppPorts 状态",
            description: "读取 AppPorts 的运行状态：版本、外置存储根目录、当前任务、未完成的迁移记录数量。只读。",
            inputSchema: MCPToolSchema.object(),
            readOnly: true,
            destructive: false
        ),
        MCPToolDefinition(
            name: "appports_list_apps",
            title: "列出应用",
            description: "扫描本地与外部存储的应用，返回名称、路径、状态、版本和运行中标记。只读；完整扫描可能需要数秒。",
            inputSchema: MCPToolSchema.object(properties: [
                "scope": MCPToolSchema.string(description: "local、external 或 all，默认 all。",
                                              values: ["local", "external", "all"]),
                "query": MCPToolSchema.string(description: "按名称或路径包含的关键字过滤，忽略大小写。"),
                "include_system": MCPToolSchema.boolean(description: "是否包含系统应用，默认 false。", defaultValue: false),
                "limit": MCPToolSchema.integer(description: "每个范围最多返回的条目数，默认 100，最大 500。",
                                               minimum: 1, maximum: 500, defaultValue: 100),
            ]),
            readOnly: true,
            destructive: false
        ),
        MCPToolDefinition(
            name: "appports_list_transfers",
            title: "列出迁移记录与任务",
            description: "返回迁移日志中的记录（方向、阶段、待处理事项）和任务中心的当前任务。只读。",
            inputSchema: MCPToolSchema.object(properties: [
                "limit": MCPToolSchema.integer(description: "最多返回的迁移记录数，默认 20，最大 100。",
                                               minimum: 1, maximum: 100, defaultValue: 20),
            ]),
            readOnly: true,
            destructive: false
        ),
        MCPToolDefinition(
            name: "appports_migrate_app",
            title: "迁移应用到外置存储",
            description: "把 /Applications 中的真实应用迁移到外置存储并在本地保留入口。任务会出现在 AppPorts 任务中心，可暂停、取消或重试。",
            inputSchema: MCPToolSchema.object(properties: [
                "app_path": MCPToolSchema.string(description: "本地应用路径，例如 /Applications/Foo.app。"),
                "destination_root": MCPToolSchema.string(description: "外置存储根目录；省略时使用 AppPorts 已选择的目录。"),
                "lock_external": MCPToolSchema.boolean(
                    description: "自更新应用需要显式同意加入 uchg 更新保护后才迁移，默认 false。",
                    defaultValue: false
                ),
            ], required: ["app_path"]),
            readOnly: false,
            destructive: true
        ),
        MCPToolDefinition(
            name: "appports_restore_app",
            title: "回迁应用",
            description: "把已迁移到外置存储的应用复制回本地并收回入口。任务会出现在 AppPorts 任务中心，可暂停、取消或重试。",
            inputSchema: MCPToolSchema.object(properties: [
                "app_path": MCPToolSchema.string(description: "外部应用路径，或对应的本地入口路径。"),
                "local_destination": MCPToolSchema.string(description: "本地目标路径；省略时使用原来的本地入口位置。"),
            ], required: ["app_path"]),
            readOnly: false,
            destructive: true
        ),
        MCPToolDefinition(
            name: "appports_task",
            title: "查询任务",
            description: "查询一个或全部迁移任务的进度、状态和消息。只读。",
            inputSchema: MCPToolSchema.object(properties: [
                "task_id": MCPToolSchema.string(description: "任务 ID；省略时返回全部任务。"),
            ]),
            readOnly: true,
            destructive: false
        ),
        MCPToolDefinition(
            name: "appports_cancel_task",
            title: "取消任务",
            description: "请求取消一个排队中或执行中的迁移任务。已完成的文件步骤不会回滚，任务会在当前边界安全收尾。",
            inputSchema: MCPToolSchema.object(properties: [
                "task_id": MCPToolSchema.string(description: "任务 ID。"),
            ], required: ["task_id"]),
            readOnly: false,
            destructive: true
        ),
    ]

    nonisolated static func definition(named name: String) -> MCPToolDefinition? {
        tools.first { $0.name == name }
    }

    // MARK: Dispatch

    func call(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        let args = MCPArguments(arguments)
        do {
            switch name {
            case "appports_status":
                return try status()
            case "appports_list_apps":
                return try await listApps(args)
            case "appports_list_transfers":
                return try listTransfers(args)
            case "appports_migrate_app":
                return try await migrateApp(args)
            case "appports_restore_app":
                return try await restoreApp(args)
            case "appports_task":
                return try taskStatus(args)
            case "appports_cancel_task":
                return try cancelTask(args)
            default:
                throw MCPToolError.unknownTool(name)
            }
        } catch let error as MCPArguments.ArgumentError {
            throw MCPToolError.invalidArguments(error.message)
        }
    }

    // MARK: Status

    private func status() throws -> MCPToolResult {
        let jobs = environment.taskCenter.jobs
        let active = jobs.filter { !$0.status.isFinished }
        let inventory = try? environment.store.inventory()

        var object: [String: Any] = [
            "app": [
                "name": "AppPorts",
                "version": environment.applicationVersion(),
                "local_apps_directory": environment.localAppsDirectories().map(\.path),
            ],
            "busy": environment.operations.isBusy,
            "blocked_by_foreground_operation": environment.operations.blocksInteraction,
            "external_root": environment.externalRoot()?.path ?? NSNull(),
            "tasks": [
                "total": jobs.count,
                "active": active.count,
                "attention": jobs.filter { $0.status == .attention }.count,
            ],
            "pending_transfers": inventory?.records.count ?? 0,
            "unreadable_transfer_records": inventory?.issues.count ?? 0,
        ]
        if let root = environment.externalRoot() {
            let localApps = URL(fileURLWithPath: "/Applications")
            object["external_library"] = AppSearchExclusionService.library(in: root).path
            object["external_local_directory"] = localApps.path
        }
        let policy = environment.policyOptions()
        object["migration_policy"] = [
            "allow_app_store": policy.allowAppStoreMigration,
            "allow_ios": policy.allowIOSAppMigration,
            "mas_external_install_supported": AppMigrationService.isMASExternalInstallSupported,
        ]
        return .json(object)
    }

    // MARK: Listing

    private func listApps(_ args: MCPArguments) async throws -> MCPToolResult {
        let scope = try args.optionalString("scope") ?? "all"
        guard ["local", "external", "all"].contains(scope) else {
            throw MCPToolError.invalidArguments("scope 只能是 local、external 或 all")
        }
        let query = (try args.optionalString("query"))?.lowercased()
        let includeSystem = try args.bool("include_system", default: false)
        let limit = try args.int("limit", default: 100, range: 1...500)
        let root = environment.externalRoot()
        let running = environment.runningApplications()

        var local: [AppItem] = []
        var external: [AppItem] = []
        if scope != "external" {
            for directory in environment.localAppsDirectories() {
                local += await environment.scanLocal(directory, running, root)
            }
        }
        if scope != "local", let root {
            for directory in environment.localAppsDirectories() {
                external += await environment.scanExternal(root, directory)
            }
        }

        func filtered(_ apps: [AppItem]) -> [[String: Any]] {
            apps
                .filter { includeSystem || !$0.isSystemApp }
                .filter { app in
                    guard let query, !query.isEmpty else { return true }
                    return app.name.lowercased().contains(query)
                        || app.path.path.lowercased().contains(query)
                }
                .prefix(limit)
                .map(appPayload)
        }

        var object: [String: Any] = [
            "scope": scope,
            "external_root": root?.path ?? NSNull(),
            "limit": limit,
        ]
        if scope != "external" { object["local"] = filtered(local) }
        if scope != "local" {
            object["external"] = root == nil ? [[String: Any]]() : filtered(external)
        }
        if root == nil, scope != "local" {
            object["notes"] = ["尚未选择外置存储目录。请先在 AppPorts 中选择，或在调用时提供 destination_root。"]
        }
        return .json(object)
    }

    private func listTransfers(_ args: MCPArguments) throws -> MCPToolResult {
        let limit = try args.int("limit", default: 20, range: 1...100)
        let inventory = try environment.store.inventory()
        let records = inventory.records.sorted { $0.createdAt > $1.createdAt }.prefix(limit)
        let jobs = environment.taskCenter.jobs

        return .json([
            "transfers": records.map(transferPayload),
            "unreadable_records": inventory.issues.prefix(limit).map {
                ["app_name": $0.appName, "message": $0.message, "paths": $0.knownPaths]
            },
            "tasks": jobs.map(jobPayload),
        ])
    }

    // MARK: Migration

    private func migrateApp(_ args: MCPArguments) async throws -> MCPToolResult {
        let path = try args.string("app_path")
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let lockExternal = try args.bool("lock_external", default: false)

        guard let root = try resolveRoot(explicit: args) else {
            return Self.noDestinationFailure
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(code: "APP_NOT_FOUND", message: "找不到应用：\(requested.path)",
                            hint: "先用 appports_list_apps 查看可迁移的应用路径。")
        }
        guard environment.operations.blocksInteraction == false else {
            return .failure(code: "BUSY", message: "AppPorts 正在执行前台操作，请等待当前操作结束后重试。")
        }
        guard try environment.migrationService().pendingTransferInspection().records.isEmpty else {
            return .failure(code: "PENDING_TRANSFER",
                            message: "存在尚未完成的迁移记录，必须先按 AppPorts 的提示处理，才能开始新的迁移。",
                            hint: "使用 appports_list_transfers 查看待处理事项，并在 AppPorts 中恢复或取消。")
        }
        guard !environment.isSameVolume(requested, root) else {
            return .failure(code: "DESTINATION_NOT_EXTERNAL",
                            message: "目标目录和应用在同一个卷上，迁移没有意义。",
                            hint: "destination_root 指向外置存储的根目录。")
        }

        let running = environment.runningApplications()
        var scanned: [AppItem] = []
        for directory in environment.localAppsDirectories() {
            scanned += await environment.scanLocal(directory, running, root)
        }
        guard let app = scanned.first(where: { $0.path.standardizedFileURL.path == requested.path }) else {
            return .failure(code: "APP_NOT_FOUND",
                            message: "\(requested.path) 不是 AppPorts 可管理的应用。",
                            hint: "只有 /Applications 中的真实 .app 或应用文件夹可以迁移；请先用 appports_list_apps 确认。")
        }
        if let reason = AppMigrationPolicy.skipReason(for: app, options: environment.policyOptions()) {
            return .failure(code: reason.rawValue, message: skipMessage(reason, app: app),
                            hint: skipHint(reason))
        }

        if environment.needsUpdateProtection(app) && !lockExternal {
            return .failure(code: "UPDATE_LOCK_REQUIRED",
                            message: "\(app.displayName) 带自更新组件，迁移后需要加入更新保护（uchg）才能保持可用。",
                            hint: "与用户确认后，带 lock_external=true 重新调用。")
        }

        let destination = AppSearchExclusionService.destination(for: app, in: root)
        if try AppTransferStore.exists(destination) {
            return .failure(code: "DESTINATION_OCCUPIED",
                            message: "外置存储中已存在同名应用：\(destination.path)",
                            hint: "AppPorts 不会自动覆盖已有副本。请先在 AppPorts 中确认版本与处理方式。",
                            details: ["destination": destination.path])
        }

        let taskID = submitMigration(app: app, destination: destination, lockExternal: lockExternal)
        return .json([
            "task_id": taskID.uuidString,
            "status": "queued",
            "app": appPayload(app),
            "destination": destination.path,
            "notes": [
                "任务已在 AppPorts 任务中心创建，可随时暂停或取消。",
                "用 appports_task 查询进度；完成后迁移记录会出现在 AppPorts 中。",
            ],
        ])
    }

    private func restoreApp(_ args: MCPArguments) async throws -> MCPToolResult {
        let path = try args.string("app_path")
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let explicitLocal = try args.optionalString("local_destination").map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }

        guard let root = environment.externalRoot() else {
            return .failure(code: "NO_EXTERNAL_ROOT",
                            message: "尚未选择外置存储目录，无法回迁。",
                            hint: "先在 AppPorts 中选择外置存储，再重试。")
        }
        guard environment.operations.blocksInteraction == false else {
            return .failure(code: "BUSY", message: "AppPorts 正在执行前台操作，请等待当前操作结束后重试。")
        }
        guard try environment.migrationService().pendingTransferInspection().records.isEmpty else {
            return .failure(code: "PENDING_TRANSFER",
                            message: "存在尚未完成的迁移记录，必须先处理后再回迁。",
                            hint: "使用 appports_list_transfers 查看待处理事项，并在 AppPorts 中恢复或取消。")
        }

        let service = environment.migrationService()
        let running = environment.runningApplications()
        var localApps: [AppItem] = []
        var externalApps: [AppItem] = []
        for directory in environment.localAppsDirectories() {
            localApps += await environment.scanLocal(directory, running, root)
            externalApps += await environment.scanExternal(root, directory)
        }

        var target: AppItem?
        if let local = localApps.first(where: { $0.path.standardizedFileURL.path == requested.path }) {
            target = service.externalCounterpart(of: local, in: externalApps)
        }
        if target == nil {
            target = externalApps.first { $0.path.standardizedFileURL.path == requested.path }
        }
        guard let app = target else {
            return .failure(code: "APP_NOT_MIGRATED",
                            message: "\(requested.path) 不是已迁移到外置存储的应用。",
                            hint: "用 appports_list_apps（scope=external）确认外部应用路径。")
        }

        let defaultDirectory = environment.localAppsDirectories().first ?? URL(fileURLWithPath: "/Applications")
        let destination = explicitLocal ?? service.localDestinationForRestore(
            of: app,
            defaultDirectory: defaultDirectory,
            additionalDirectories: environment.customLocalDirectories()
        )
        if (try? AppTransferStore.exists(destination)) == true, !service.isManagedPortal(at: destination) {
            return .failure(code: "LOCAL_OCCUPIED",
                            message: "本地已存在同名真实应用：\(destination.path)",
                            hint: "先处理本地副本，或通过 local_destination 指定另一个位置。")
        }

        let taskID = submitRestore(app: app, localDestination: destination)
        return .json([
            "task_id": taskID.uuidString,
            "status": "queued",
            "app": appPayload(app),
            "destination": destination.path,
            "notes": [
                "任务已在 AppPorts 任务中心创建，可随时暂停或取消。",
                "用 appports_task 查询进度；本地副本失败时外置副本会保留。",
            ],
        ])
    }

    // MARK: Tasks

    private func taskStatus(_ args: MCPArguments) throws -> MCPToolResult {
        let jobs = environment.taskCenter.jobs
        if let identifier = try args.optionalString("task_id") {
            guard let uuid = UUID(uuidString: identifier),
                  let job = jobs.first(where: { $0.id == uuid }) else {
                return .failure(code: "TASK_NOT_FOUND", message: "找不到任务：\(identifier)")
            }
            return .json(jobPayload(job))
        }
        return .json(["tasks": jobs.map(jobPayload)])
    }

    private func cancelTask(_ args: MCPArguments) throws -> MCPToolResult {
        let identifier = try args.string("task_id")
        guard let uuid = UUID(uuidString: identifier),
              let job = environment.taskCenter.jobs.first(where: { $0.id == uuid }) else {
            return .failure(code: "TASK_NOT_FOUND", message: "找不到任务：\(identifier)")
        }
        guard !job.status.isFinished else {
            return .failure(code: "TASK_FINISHED", message: "任务已结束，无需取消。",
                            details: jobPayload(job))
        }
        environment.taskCenter.cancel([uuid])
        let updated = environment.taskCenter.jobs.first(where: { $0.id == uuid }) ?? job
        return .json(jobPayload(updated))
    }

    // MARK: Submission

    private func submitMigration(app: AppItem, destination: URL, lockExternal: Bool) -> UUID {
        let title = "正在迁移应用".localized + " · " + app.displayName
        let perform = environment.migrationOperation
        return environment.taskCenter.submit(
            title: title,
            category: .apps,
            resources: .application(paths: [app.path, app.displayURL, destination], appURL: app.displayURL),
            presentDetails: false,
            operation: { progress in
                try await perform(app, destination, lockExternal, progress)
            },
            completion: { NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil) }
        )
    }

    private func submitRestore(app: AppItem, localDestination: URL) -> UUID {
        let title = "正在还原应用".localized + " · " + app.displayName
        let perform = environment.restoreOperation
        return environment.taskCenter.submit(
            title: title,
            category: .apps,
            resources: .application(paths: [app.path, app.displayURL, localDestination], appURL: app.displayURL),
            presentDetails: false,
            operation: { progress in
                try await perform(app, localDestination, progress)
            },
            completion: { NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil) }
        )
    }

    // MARK: Payloads

    private func appPayload(_ app: AppItem) -> [String: Any] {
        var payload: [String: Any] = [
            "name": app.name,
            "display_name": app.displayName,
            "path": app.path.path,
            "bundle_path": app.displayURL.path,
            "status": app.status,
            "state": AppStatus.localized(app.status),
            "is_running": app.isRunning,
            "is_system": app.isSystemApp,
            "is_app_store": app.isAppStoreApp,
            "is_ios": app.isIOSApp,
            "is_folder": app.usesFolderOperation,
            "needs_update_protection": app.needsLock,
        ]
        if let version = app.version { payload["version"] = version }
        if let size = app.size { payload["size"] = size }
        if app.isFolder { payload["contained_apps"] = app.appCount }
        return payload
    }

    private func transferPayload(_ record: AppTransferRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "operation_id": record.operationID.uuidString,
            "app_name": record.appName,
            "direction": record.direction.rawValue,
            "phase": record.phase.rawValue,
            "source_path": record.sourcePath,
            "destination_path": record.destinationPath,
            "created_at": Self.iso8601(record.createdAt),
            "switch_complete": record.isSwitchComplete,
            "can_cancel": record.canCancel,
            "pending_tasks": record.pendingTasks.map { task -> [String: Any] in
                ["kind": task.kind.rawValue, "path": task.path ?? NSNull(), "message": task.message]
            },
        ]
        if let recoverable = record.recoverableReason { payload["recoverable_reason"] = recoverable }
        return payload
    }

    private func jobPayload(_ job: MigrationJob) -> [String: Any] {
        var payload: [String: Any] = [
            "task_id": job.id.uuidString,
            "title": job.title,
            "category": job.category.rawValue,
            "status": job.status.rawValue,
            "state": job.stateTitle,
            "message": job.message,
            "fraction": job.fraction,
            "elapsed_seconds": (job.elapsed * 10).rounded() / 10,
            "can_pause": !job.status.isFinished && job.supportsExecutionControls,
            "paths": job.resources.paths.sorted(),
        ]
        payload["is_finished"] = job.status.isFinished
        return payload
    }

    // MARK: Helpers

    private func resolveRoot(explicit args: MCPArguments) throws -> URL? {
        let root: URL?
        if let value = try args.optionalString("destination_root") {
            root = URL(fileURLWithPath: value).standardizedFileURL
        } else {
            root = environment.externalRoot()
        }
        guard let root else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MCPToolError.invalidArguments("destination_root 不是已存在的目录：\(root.path)")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard root.path != "/", root.path != home, !root.path.hasPrefix(home + "/") else {
            throw MCPToolError.invalidArguments("destination_root 不能是磁盘根目录或用户主目录：\(root.path)")
        }
        guard root.path != "/Applications" else {
            throw MCPToolError.invalidArguments("destination_root 不能是本地 /Applications。")
        }
        return root
    }

    private static var noDestinationFailure: MCPToolResult {
        .failure(code: "NO_EXTERNAL_ROOT",
                 message: "尚未选择外置存储目录。",
                 hint: "在 AppPorts 中选择外置存储，或在调用时提供 destination_root。")
    }

    private func skipMessage(_ reason: AppMigrationPolicy.SkipReason, app: AppItem) -> String {
        switch reason {
        case .systemApp: return "\(app.displayName) 是系统应用，AppPorts 不迁移系统应用。"
        case .running: return "\(app.displayName) 正在运行，请先退出后再迁移。"
        case .alreadyLinked: return "\(app.displayName) 已经迁移到外置存储。"
        case .iosMigrationDisabled: return "\(app.displayName) 是非原生（iPhone/iPad）应用，迁移开关未启用。"
        case .appStoreMigrationDisabled: return "\(app.displayName) 来自 App Store，迁移开关未启用。"
        }
    }

    private func skipHint(_ reason: AppMigrationPolicy.SkipReason) -> String {
        switch reason {
        case .systemApp: return "系统应用不在 AppPorts 的管理范围内。"
        case .running: return "退出应用后重新调用；AppPorts 也会在执行时再次检查。"
        case .alreadyLinked: return "如需改回本地，使用 appports_restore_app。"
        case .iosMigrationDisabled: return "如确有需要，请用户在 AppPorts 设置中启用「允许迁移非原生应用」。"
        case .appStoreMigrationDisabled: return "如确有需要，请用户在 AppPorts 设置中启用 App Store 应用迁移。"
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
