//
//  MCPToolService+Data.swift
//  AppPorts
//
//  Path and data migration tools for the MCP surface. Every mutation is
//  submitted to MigrationTaskCenter and runs through the same services the UI
//  uses, so an AI-driven migration is visible, cancellable and recoverable in
//  the app.
//

import AppKit
import Foundation

// MARK: - Resolved target

private struct MCPDataTarget {
    enum Kind {
        case appData(AppItem)
        case toolDirectory
        case customDirectory(CustomDirConfig)
    }

    let item: DataDirItem
    let kind: Kind

    var app: AppItem? {
        if case let .appData(app) = kind { return app }
        return nil
    }
}

private enum MCPDataTargetLookup {
    case found(MCPDataTarget)
    case failure(MCPToolResult)
}

private enum MCPAppLookup {
    case found(AppItem)
    case failure(MCPToolResult)
}

@MainActor
extension MCPToolService {
    /// Everything the path and data tools need from the system. Injected so
    /// tests never read the real home directory or touch real volumes.
    struct DataEnvironment {
        var isClassicModeActive: () -> Bool
        var isPartialWeChatMigrationEnabled: (URL) -> Bool
        var weChatContainerIdentifier: () -> String
        var weChatAppURL: () -> URL?
        var isWeChatAccountPath: (URL) -> Bool
        var weChatMemberPaths: (URL) -> [URL]
        var fullDiskAccessGranted: () -> Bool
        var installationLocationAllowed: () -> Bool
        var scanAppData: (AppItem, URL?) async -> DataDirScanResult
        var scanToolDirectories: (URL?) async -> [DataDirItem]
        var customConfigurations: () -> [CustomDirConfig]
        var scanCustomDirectories: ([CustomDirConfig], Bool) async -> [CustomDirPair]
        var mountInspection: () throws -> ContainerMountStore.Inspection
        var hasPendingTransfer: (Set<String>) -> Bool
        var isApplicationRunning: (URL?, String?) -> Bool
        var weChatState: (URL) throws -> WeChatAccountMigrationService.State
        var weChatSizing: (URL) throws -> WeChatAccountMigrationService.Sizing
        var mountPreflight: (URL, Int64) async -> MountMigrationPreflight.Outcome
        var prepareDataMigration: (DataDirItem, AppItem, URL, DataTransferProgress) async throws -> DataDirItem
        var symlinkOperation: @Sendable (DataDirItem, URL, DataTransferProgress) async throws -> String?
        var mountOperation: @Sendable (DataDirItem, URL, DataTransferProgress) async throws -> String?
        var restoreOperation: @Sendable (DataDirItem, DataTransferProgress) async throws -> String?
        var mountRestoreOperation: @Sendable (ContainerMountRecord, Int64, DataTransferProgress) async throws -> String?
        var weChatMigrate: @Sendable (URL, WeChatAccountMigrationService.Mode, URL, DataTransferProgress) async throws -> [String]
        var weChatRestore: @Sendable (URL, DataTransferProgress) async throws -> [String]

        @MainActor
        static func live() -> DataEnvironment {
            DataEnvironment(
                isClassicModeActive: { MigrationPreferences.isClassicDataMigrationActive },
                isPartialWeChatMigrationEnabled: { MigrationPreferences.isPartialWeChatMigrationEnabled(for: $0) },
                weChatContainerIdentifier: { PartialWeChatMigrationPolicy.bundleIdentifier },
                weChatAppURL: {
                    NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: PartialWeChatMigrationPolicy.bundleIdentifier)?
                        .standardizedFileURL
                },
                isWeChatAccountPath: {
                    PartialWeChatMigrationPolicy().isAccount($0)
                },
                weChatMemberPaths: {
                    PartialWeChatMigrationPolicy().members(of: $0)
                },
                fullDiskAccessGranted: { LaunchReadinessChecker.fullDiskAccessState() == .granted },
                installationLocationAllowed: { AppInstallationLocation.isAllowed() },
                scanAppData: { app, root in
                    let split = MigrationPreferences.isPartialWeChatMigrationEnabled(for: app.path)
                    let scanner = DataDirScanner(
                        partialWeChatMigrationEnabled: split,
                        weChatContainerIdentifier: PartialWeChatMigrationPolicy.bundleIdentifier
                    )
                    return await scanner.scanLibraryDirsWithDiagnostics(for: app, externalRootURL: root)
                },
                scanToolDirectories: { root in
                    await DataDirScanner().scanKnownDotFolders(externalRootURL: root)
                },
                customConfigurations: { CustomDirConfigStore.shared.configs },
                scanCustomDirectories: { configs, calculateSizes in
                    await CustomDirScanner().scan(configs: configs, calculateSizes: calculateSizes)
                },
                mountInspection: { try ContainerMountStore.shared.recordsForInspection() },
                hasPendingTransfer: { paths in
                    guard let transfers = try? ContainerMountStore.shared.transfers() else { return false }
                    return transfers.contains { record in
                        let fields: [String?] = [record.originalPath, record.activePath,
                                                 record.destinationPath, record.stagingPath,
                                                 record.backupPath]
                        for field in fields {
                            guard let field else { continue }
                            if paths.contains(URL(fileURLWithPath: field).standardizedFileURL.path) {
                                return true
                            }
                        }
                        return false
                    }
                },
                isApplicationRunning: { url, bundleIdentifier in
                    MigrationApplicationState.isRunning(appURL: url, bundleIdentifier: bundleIdentifier)
                },
                weChatState: { try WeChatAccountMigrationService().state(of: $0) },
                weChatSizing: { try WeChatAccountMigrationService().measure($0) },
                mountPreflight: { root, bytes in
                    await MountMigrationPreflight().evaluate(destination: root, dataBytes: bytes)
                },
                prepareDataMigration: { item, app, root, progress in
                    let preparation = AppDataMigrationPreparation(
                        app: app,
                        externalRoot: root,
                        splitMode: MigrationPreferences.isPartialWeChatMigrationEnabled(for: app.path),
                        containerIdentifier: PartialWeChatMigrationPolicy.bundleIdentifier
                    )
                    return try await preparation.refresh(item, progress: progress)
                },
                symlinkOperation: { item, destination, progress in
                    progress.setDirectory(item.path)
                    let result = try await DataDirMover().migrateAndComplete(
                        item: item,
                        to: destination,
                        progressHandler: { progress.update($0) }
                    )
                    return result.cleanupWarning
                },
                mountOperation: { item, root, progress in
                    progress.setDirectory(item.path)
                    let result = try await ContainerVolumeMigrator().migrateAndComplete(
                        item: item,
                        externalRootURL: root,
                        appName: item.associatedAppName ?? item.name,
                        bundleIdentifier: item.associatedBundleIdentifier,
                        progressHandler: { progress.update($0) }
                    )
                    return result.cleanupWarning?.message
                },
                restoreOperation: { item, progress in
                    progress.setDirectory(item.path)
                    let result = try await DataDirMover().restoreAndComplete(
                        item: item,
                        progressHandler: { progress.update($0) }
                    )
                    return result.cleanupWarning
                },
                mountRestoreOperation: { record, estimatedBytes, progress in
                    progress.setDirectory(URL(fileURLWithPath: record.mountPointPath))
                    let warning = try await ContainerVolumeMigrator().restoreAndComplete(
                        record: record,
                        estimatedTotalBytes: estimatedBytes,
                        progressHandler: { progress.update($0) }
                    )
                    return warning?.message
                },
                weChatMigrate: { account, mode, root, progress in
                    let appURL = NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: PartialWeChatMigrationPolicy.bundleIdentifier)
                    let enabled = appURL.map { MigrationPreferences.isPartialWeChatMigrationEnabled(for: $0) } ?? false
                    let service = WeChatAccountMigrationService(enabled: enabled)
                    let appName = appURL?.deletingPathExtension().lastPathComponent ?? "WeChat"
                    return try await service.migrate(
                        account: account,
                        mode: mode,
                        externalRoot: root,
                        appName: appName,
                        progress: { progress.update($0) }
                    )
                },
                weChatRestore: { account, progress in
                    let service = WeChatAccountMigrationService(enabled: false)
                    return try await service.restoreSplit(account: account, progress: { progress.update($0) })
                }
            )
        }
    }

    // MARK: - Tools: paths

    func listPaths(_ args: MCPArguments) async throws -> MCPToolResult {
        let scope = try args.optionalString("scope") ?? "all"
        guard ["app", "tools", "custom", "all"].contains(scope) else {
            throw MCPToolError.invalidArguments("scope 只能是 app、tools、custom 或 all")
        }
        let query = (try args.optionalString("query"))?.lowercased()
        let limit = try args.int("limit", default: 100, range: 1...500)
        let appPath = try args.optionalString("app_path")
        let root = environment.externalRoot()
        let inspection = try? dataEnvironment.mountInspection()

        func matches(_ item: DataDirItem) -> Bool {
            guard let query, !query.isEmpty else { return true }
            return item.name.lowercased().contains(query)
                || item.path.path.lowercased().contains(query)
        }

        var object: [String: Any] = [
            "scope": scope,
            "external_root": root?.path ?? NSNull(),
            "limit": limit,
        ]
        var notes: [String] = []

        if scope == "app" || scope == "all" {
            if let appPath {
                switch try await resolveApp(appPath) {
                case let .failure(result):
                    return result
                case let .found(app):
                    let scan = await dataEnvironment.scanAppData(app, root)
                    let items = scan.items.filter(matches)
                    object["app"] = appPayload(app)
                    object["app_data"] = items.prefix(limit).map(dataItemPayload)
                    object["wechat_accounts"] = items
                        .filter { dataEnvironment.isWeChatAccountPath($0.path) }
                        .prefix(limit)
                        .map(accountPayload)
                    if scan.readIssues.isEmpty == false {
                        object["unreadable_directories"] = scan.readIssues.count
                    }
                }
            } else {
                object["app_data"] = [[String: Any]]()
                notes.append("提供 app_path 可以列出该应用的数据目录（~/Library 下的支持、缓存与容器目录）。")
            }
        }

        if scope == "custom" || scope == "all" {
            let configs = dataEnvironment.customConfigurations()
            if configs.isEmpty {
                object["custom_directories"] = [[String: Any]]()
                notes.append("还没有配置自定义目录。请在 AppPorts 的「自定义目录」中添加后重试。")
            } else {
                let pairs = await dataEnvironment.scanCustomDirectories(configs, true)
                object["custom_directories"] = pairs
                    .filter { matches($0.local.dataDirItem) }
                    .prefix(limit)
                    .map(customPairPayload)
            }
        }

        if scope == "tools" || scope == "all" {
            let items = await dataEnvironment.scanToolDirectories(root)
            object["tool_directories"] = items
                .filter(matches)
                .prefix(limit)
                .map(dataItemPayload)
        }

        if scope == "all", let inspection {
            object["managed_links"] = inspection.managedLinks.prefix(limit).map(linkPayload)
            object["mounted_volumes"] = inspection.mounts.prefix(limit).map(mountPayload)
        }
        if scope != "app", scope != "custom", scope != "tools", root == nil {
            notes.append("尚未选择外置存储目录。请先在 AppPorts 中选择，或在调用时提供 destination_root。")
        }
        if notes.isEmpty == false { object["notes"] = notes }
        return .json(object)
    }

    func migratePath(_ args: MCPArguments) async throws -> MCPToolResult {
        let rawPath = try args.string("path")
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        let modeArgument = try args.optionalString("mode") ?? "auto"
        guard ["auto", "link", "mount"].contains(modeArgument) else {
            throw MCPToolError.invalidArguments("mode 只能是 auto、link 或 mount")
        }
        let appPath = try args.optionalString("app_path")

        guard let root = try resolveRoot(explicit: args) else { return Self.noDestinationFailure }
        guard environment.operations.blocksInteraction == false else {
            return .failure(code: "BUSY", message: "AppPorts 正在执行前台操作，请等待当前操作结束后重试。")
        }
        if dataEnvironment.isWeChatAccountPath(url) {
            return weChatAccountRedirectFailure(url, tool: "appports_migrate_wechat_account")
        }

        let target: MCPDataTarget
        switch try await locateTarget(at: url, appPath: appPath) {
        case let .failure(result):
            return result
        case let .found(value):
            target = value
        }

        if case .appData = target.kind {
            guard dataEnvironment.installationLocationAllowed() else {
                return .failure(code: "INSTALLATION_LOCATION",
                                message: "请把 AppPorts 放在「应用程序」文件夹后重新打开，再迁移数据目录。",
                                hint: "非标准位置运行时 AppPorts 无法确认数据目录的边界。")
            }
            guard dataEnvironment.fullDiskAccessGranted() else {
                return .failure(code: "ACCESS_DENIED",
                                message: "AppPorts 没有完全磁盘访问权限，无法读取或迁移数据目录。",
                                hint: "请在系统设置 → 隐私与安全性 → 完全磁盘访问权限中允许 AppPorts。")
            }
        }

        let item = target.item
        let usesMount = modeArgument == "mount"
            || (modeArgument == "auto" && item.requiresMountMigration)
        if usesMount, item.requiresMountMigration == false,
           item.type != .containers, item.type != .groupContainers {
            throw MCPToolError.invalidArguments("「\(item.name)」不支持挂载迁移；容器目录以外的数据目录使用符号链接迁移。")
        }
        if usesMount == false, item.requiresMountMigration, dataEnvironment.isClassicModeActive() == false {
            return .failure(code: "MOUNT_REQUIRED",
                            message: "「\(item.name)」位于应用容器目录，只能用挂载迁移。",
                            hint: "改用 mode=mount。经典模式下的符号链接迁移需要用户先在 AppPorts 中显式开启。")
        }
        guard item.status == DataDirStatus.local else {
            return .failure(code: "ALREADY_MIGRATED",
                            message: "「\(item.name)」当前状态是「\(item.displayedStatus)」，不需要迁移。",
                            hint: "如需改回本地，使用 appports_restore_path。",
                            details: dataItemPayload(item))
        }
        guard item.isMigratable else {
            return .failure(code: "NOT_MIGRATABLE",
                            message: item.nonMigratableReason ?? "「\(item.name)」当前不可迁移。",
                            details: dataItemPayload(item))
        }
        if let app = target.app,
           dataEnvironment.isApplicationRunning(app.displayURL, item.associatedBundleIdentifier) {
            return .failure(code: "RUNNING",
                            message: "「\(app.displayName)」正在运行，请先退出后再迁移其数据目录。",
                            hint: "退出应用后重新调用；AppPorts 也会在执行时再次检查。")
        }

        if dataEnvironment.hasPendingTransfer([item.path.standardizedFileURL.path]) {
            return .failure(code: "PENDING_TRANSFER",
                            message: "「\(item.name)」有尚未完成的迁移记录，必须先处理。",
                            hint: "使用 appports_list_data_migrations 查看待处理事项，并在 AppPorts 中恢复或取消。")
        }
        guard environment.isSameVolume(item.path, root) == false else {
            return .failure(code: "DESTINATION_NOT_EXTERNAL",
                            message: "目标目录和数据目录在同一个卷上，迁移没有意义。",
                            hint: "destination_root 指向外置存储的根目录。")
        }

        let destination: URL
        if case let .customDirectory(config) = target.kind {
            destination = config.externalDestinationURL.standardizedFileURL
        } else {
            destination = Self.dataDestinationPath(for: item, under: root)
        }

        if usesMount {
            switch await dataEnvironment.mountPreflight(root, item.sizeBytes) {
            case .ready:
                break
            case .noDestination:
                return Self.noDestinationFailure
            case .destinationUnavailable:
                return .failure(code: "DESTINATION_UNAVAILABLE",
                                message: "无法访问目标目录：\(root.path)",
                                hint: "确认外置盘已连接、已解锁并且可写。")
            case let .notAPFS(filesystem):
                return .failure(code: "DESTINATION_NOT_APFS",
                                message: "挂载迁移要求 APFS 目标盘，当前文件系统是 \(filesystem ?? "未知")。",
                                hint: "改用 mode=link，或换一块 APFS 格式的外置盘。")
            case .encrypted:
                return .failure(code: "ENCRYPTION_PASSWORD_REQUIRED",
                                message: "目标盘是加密卷，挂载迁移需要先解锁。",
                                hint: "请用户在 AppPorts 中提供解锁凭据后重试。")
            case let .insufficientSpace(required, available):
                return .failure(code: "INSUFFICIENT_SPACE",
                                message: "目标盘空间不足：需要约 \(Self.byteText(required))，可用 \(Self.byteText(available))。")
            }
        } else if (try? AppTransferStore.exists(destination)) == true {
            return .failure(code: "DESTINATION_OCCUPIED",
                            message: "外置存储中已存在同名目录：\(destination.path)",
                            hint: "AppPorts 不会覆盖已有数据。请先处理外部副本，或改用 mode=mount。")
        }

        let taskID = usesMount
            ? submitMountMigration(target: target, root: root)
            : submitLinkMigration(target: target, destination: destination)
        return .json([
            "task_id": taskID.uuidString,
            "status": "queued",
            "mode": usesMount ? "mount" : "link",
            "path": dataItemPayload(item),
            "destination": destination.path,
            "notes": [
                "任务已在 AppPorts 任务中心创建，可随时暂停或取消。",
                "用 appports_task 查询进度；完成后记录会出现在 AppPorts 的数据目录迁移中。",
            ],
        ])
    }

    func restorePath(_ args: MCPArguments) async throws -> MCPToolResult {
        let rawPath = try args.string("path")
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        let appPath = try args.optionalString("app_path")

        guard environment.operations.blocksInteraction == false else {
            return .failure(code: "BUSY", message: "AppPorts 正在执行前台操作，请等待当前操作结束后重试。")
        }
        if dataEnvironment.isWeChatAccountPath(url) {
            return weChatAccountRedirectFailure(url, tool: "appports_restore_wechat_account")
        }

        let target: MCPDataTarget
        switch try await locateTarget(at: url, appPath: appPath) {
        case let .failure(result):
            return result
        case let .found(value):
            target = value
        }
        if case .appData = target.kind {
            guard dataEnvironment.installationLocationAllowed() else {
                return .failure(code: "INSTALLATION_LOCATION",
                                message: "请把 AppPorts 放在「应用程序」文件夹后重新打开，再还原数据目录。",
                                hint: "非标准位置运行时 AppPorts 无法确认数据目录的边界。")
            }
            guard dataEnvironment.fullDiskAccessGranted() else {
                return .failure(code: "ACCESS_DENIED",
                                message: "AppPorts 没有完全磁盘访问权限，无法还原数据目录。",
                                hint: "请在系统设置 → 隐私与安全性 → 完全磁盘访问权限中允许 AppPorts。")
            }
        }

        let item = target.item
        guard item.status != DataDirStatus.local else {
            return .failure(code: "NOT_MIGRATED",
                            message: "「\(item.name)」当前在本地，没有需要还原的数据。",
                            details: dataItemPayload(item))
        }

        if dataEnvironment.hasPendingTransfer([item.path.standardizedFileURL.path]) {
            return .failure(code: "PENDING_TRANSFER",
                            message: "「\(item.name)」有尚未完成的迁移记录，必须先处理。",
                            hint: "使用 appports_list_data_migrations 查看待处理事项，并在 AppPorts 中恢复或取消。")
        }
        if let app = target.app,
           dataEnvironment.isApplicationRunning(app.displayURL, item.associatedBundleIdentifier) {
            return .failure(code: "RUNNING",
                            message: "「\(app.displayName)」正在运行，请先退出后再还原其数据目录。",
                            hint: "退出应用后重新调用；AppPorts 也会在执行时再次检查。")
        }

        let inspection = try? dataEnvironment.mountInspection()
        let mountRecord = inspection?.mounts.first {
            URL(fileURLWithPath: $0.mountPointPath).standardizedFileURL == item.path.standardizedFileURL
        }

        let taskID: UUID
        let mode: String
        if let mountRecord {
            taskID = submitMountRestore(target: target, record: mountRecord)
            mode = "mount"
        } else if item.canRestore {
            taskID = submitLinkRestore(target: target)
            mode = "link"
        } else {
            return .failure(code: "NO_MIGRATION_RECORD",
                            message: "找不到「\(item.name)」对应的迁移记录，数据没有被移动。",
                            hint: "使用 appports_list_paths 或 appports_list_data_migrations 确认目录状态。",
                            details: dataItemPayload(item))
        }

        return .json([
            "task_id": taskID.uuidString,
            "status": "queued",
            "mode": mode,
            "path": dataItemPayload(item),
            "notes": [
                "任务已在 AppPorts 任务中心创建，可随时暂停或取消。",
                "用 appports_task 查询进度；还原失败时外置副本会保留。",
            ],
        ])
    }

    // MARK: - Tools: data migrations

    func listDataMigrations(_ args: MCPArguments) async throws -> MCPToolResult {
        let limit = try args.int("limit", default: 20, range: 1...100)
        let appPath = try args.optionalString("app_path")

        let inspection: ContainerMountStore.Inspection
        do {
            inspection = try dataEnvironment.mountInspection()
        } catch {
            return .failure(code: "STORE_UNREADABLE",
                            message: "无法读取数据迁移记录：\(error.localizedDescription)",
                            hint: "在 AppPorts 中打开一次数据目录页面后重试。")
        }

        var object: [String: Any] = ["limit": limit]
        var app: AppItem?
        if let appPath {
            switch try await resolveApp(appPath) {
            case let .failure(result):
                return result
            case let .found(found):
                app = found
                object["app"] = appPayload(found)
            }
        }

        let appBundleIdentifier = app.map(bundleIdentifier(of:)) ?? nil
        let appRootPath = app?.path.standardizedFileURL.path

        func belongs(_ bundle: String?, _ paths: [String]) -> Bool {
            guard app != nil else { return true }
            if let appBundleIdentifier, bundle == appBundleIdentifier { return true }
            guard let appRootPath else { return false }
            return paths.contains { $0 == appRootPath || $0.hasPrefix(appRootPath + "/") }
        }

        let mounts = inspection.mounts
            .filter { belongs($0.bundleIdentifier, [$0.mountPointPath, $0.externalRootPath]) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
        let links = inspection.managedLinks
            .filter { belongs($0.bundleIdentifier, [$0.originalPath, $0.destinationPath]) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
        let transfers = inspection.transfers
            .filter { belongs($0.bundleIdentifier, [$0.originalPath, $0.activePath, $0.destinationPath]) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
        let cleanups = inspection.cleanups
            .filter { belongs($0.mountRecord.bundleIdentifier,
                              [$0.localPath, $0.mountRecord.mountPointPath] + ($0.restoreStagingPath.map { [$0] } ?? [])) }
            .prefix(limit)

        object["mounts"] = mounts.map(mountPayload)
        object["managed_links"] = links.map(linkPayload)
        object["transfers"] = transfers.map(dataTransferPayload)
        object["pending_cleanups"] = cleanups.map(cleanupPayload)
        object["unfinished_transfers"] = inspection.transfers.count

        if let appURL = dataEnvironment.weChatAppURL(), app == nil || app?.path == appURL {
            let scan = try? await resolveApp(appURL.path)
            if case let .found(weChatApp)? = scan {
                let result = await dataEnvironment.scanAppData(weChatApp, environment.externalRoot())
                object["wechat_accounts"] = result.items
                    .filter { dataEnvironment.isWeChatAccountPath($0.path) }
                    .prefix(limit)
                    .map(accountPayload)
                object["wechat_split_enabled"] = dataEnvironment.isPartialWeChatMigrationEnabled(weChatApp.path)
            }
        }
        if app != nil, mounts.isEmpty, links.isEmpty, transfers.isEmpty, cleanups.isEmpty {
            object["notes"] = ["这个应用当前没有数据目录迁移记录。"]
        }
        return .json(object)
    }

    // MARK: - Tools: WeChat accounts

    func migrateWeChatAccount(_ args: MCPArguments) async throws -> MCPToolResult {
        let rawPath = try args.string("account_path")
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        let modeArgument = try args.optionalString("mode") ?? "split"
        guard let mode = Self.weChatMode(modeArgument) else {
            throw MCPToolError.invalidArguments("mode 只能是 split 或 whole")
        }
        guard dataEnvironment.isWeChatAccountPath(url) else {
            return .failure(code: "ACCOUNT_NOT_FOUND",
                            message: "\(url.path) 不是微信账号目录。",
                            hint: "账号目录位于微信容器的 xwechat_files 下；用 appports_list_paths（app_path=微信）查看。")
        }
        guard let root = try resolveRoot(explicit: args) else { return Self.noDestinationFailure }
        guard environment.operations.blocksInteraction == false else {
            return .failure(code: "BUSY", message: "AppPorts 正在执行前台操作，请等待当前操作结束后重试。")
        }
        guard dataEnvironment.installationLocationAllowed() else {
            return .failure(code: "INSTALLATION_LOCATION",
                            message: "请把 AppPorts 放在「应用程序」文件夹后重新打开，再迁移微信账号数据。",
                            hint: "非标准位置运行时 AppPorts 无法确认账号目录的边界。")
        }
        guard dataEnvironment.fullDiskAccessGranted() else {
            return .failure(code: "ACCESS_DENIED",
                            message: "AppPorts 没有完全磁盘访问权限，无法迁移微信账号数据。",
                            hint: "请在系统设置 → 隐私与安全性 → 完全磁盘访问权限中允许 AppPorts。")
        }
        guard let appURL = dataEnvironment.weChatAppURL() else {
            return .failure(code: "APP_NOT_FOUND",
                            message: "找不到微信应用，无法发起账号数据迁移。",
                            hint: "请先安装微信，并在 AppPorts 中确认它可被管理。")
        }
        guard mode != .split || dataEnvironment.isPartialWeChatMigrationEnabled(appURL) else {
            return .failure(code: "WECHAT_DISABLED",
                            message: "「微信账号拆分迁移」未开启，无法按账号拆分迁移。",
                            hint: "请用户在 AppPorts 的微信设置中开启后重试，或改用 mode=whole。")
        }

        let state: WeChatAccountMigrationService.State
        do {
            state = try dataEnvironment.weChatState(url)
        } catch {
            return .failure(code: "ACCOUNT_NOT_FOUND",
                            message: "无法确认微信账号目录：\(error.localizedDescription)",
                            hint: "确认账号目录仍然存在，并在 AppPorts 中重新扫描。")
        }
        switch state {
        case .conflict:
            return .failure(code: "WECHAT_CONFLICT",
                            message: "账号「\(url.lastPathComponent)」的迁移状态不一致，AppPorts 需要先人工处理。",
                            hint: "在 AppPorts 的数据目录页面处理冲突后再重试。")
        case .whole, .split:
            return .failure(code: "RESTORE_FIRST",
                            message: "账号「\(url.lastPathComponent)」已经迁移，需要先完整还原才能切换迁移方式。",
                            hint: "使用 appports_restore_wechat_account，或先还原账号数据。")
        case .local:
            break
        }

        let sizing: WeChatAccountMigrationService.Sizing
        do {
            sizing = try dataEnvironment.weChatSizing(url)
        } catch {
            return .failure(code: "SIZE_UNAVAILABLE",
                            message: "无法测量账号数据大小：\(error.localizedDescription)",
                            hint: "确认账号目录可读后重试。")
        }
        guard sizing.isComplete else {
            return .failure(code: "SIZE_INCOMPLETE",
                            message: "账号「\(url.lastPathComponent)」的数据大小无法完整测量，迁移可能不完整。",
                            hint: "关闭微信并重新扫描后再试。")
        }

        let memberURLs = mode == .split ? dataEnvironment.weChatMemberPaths(url) : [url]
        let memberPaths = Set(memberURLs.map { $0.standardizedFileURL.path })
        if dataEnvironment.hasPendingTransfer(memberPaths) {
            return .failure(code: "PENDING_TRANSFER",
                            message: "账号「\(url.lastPathComponent)」有尚未完成的迁移记录，必须先处理。",
                            hint: "使用 appports_list_data_migrations 查看待处理事项。")
        }

        switch await dataEnvironment.mountPreflight(root, sizing.total.bytes) {
        case .ready:
            break
        case .noDestination:
            return Self.noDestinationFailure
        case .destinationUnavailable:
            return .failure(code: "DESTINATION_UNAVAILABLE",
                            message: "无法访问目标目录：\(root.path)",
                            hint: "确认外置盘已连接、已解锁并且可写。")
        case let .notAPFS(filesystem):
            return .failure(code: "DESTINATION_NOT_APFS",
                            message: "微信账号数据只能用挂载迁移，要求 APFS 目标盘，当前文件系统是 \(filesystem ?? "未知")。")
        case .encrypted:
            return .failure(code: "ENCRYPTION_PASSWORD_REQUIRED",
                            message: "目标盘是加密卷，挂载迁移需要先解锁。",
                            hint: "请用户在 AppPorts 中提供解锁凭据后重试。")
        case let .insufficientSpace(required, available):
            return .failure(code: "INSUFFICIENT_SPACE",
                            message: "目标盘空间不足：需要约 \(Self.byteText(required))，可用 \(Self.byteText(available))。")
        }

        let taskID = submitWeChatMigration(account: url,
                                           members: memberURLs,
                                           mode: mode,
                                           root: root,
                                           name: url.lastPathComponent)
        return .json([
            "task_id": taskID.uuidString,
            "status": "queued",
            "mode": mode == .split ? "split" : "whole",
            "account": accountPayload(DataDirItem(name: url.lastPathComponent, path: url,
                                                  type: .containers, priority: .critical,
                                                  description: "微信账号数据")),
            "destination": root.path,
            "notes": [
                "任务已在 AppPorts 任务中心创建，可随时暂停或取消。",
                "用 appports_task 查询进度；完成后记录会出现在 AppPorts 的数据目录迁移中。",
            ],
        ])
    }

    func restoreWeChatAccount(_ args: MCPArguments) async throws -> MCPToolResult {
        let rawPath = try args.string("account_path")
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard dataEnvironment.isWeChatAccountPath(url) else {
            return .failure(code: "ACCOUNT_NOT_FOUND",
                            message: "\(url.path) 不是微信账号目录。",
                            hint: "用 appports_list_paths（app_path=微信）查看账号目录。")
        }
        guard environment.operations.blocksInteraction == false else {
            return .failure(code: "BUSY", message: "AppPorts 正在执行前台操作，请等待当前操作结束后重试。")
        }
        guard dataEnvironment.installationLocationAllowed() else {
            return .failure(code: "INSTALLATION_LOCATION",
                            message: "请把 AppPorts 放在「应用程序」文件夹后重新打开，再还原微信账号数据。",
                            hint: "非标准位置运行时 AppPorts 无法确认账号目录的边界。")
        }
        guard dataEnvironment.fullDiskAccessGranted() else {
            return .failure(code: "ACCESS_DENIED",
                            message: "AppPorts 没有完全磁盘访问权限，无法还原微信账号数据。",
                            hint: "请在系统设置 → 隐私与安全性 → 完全磁盘访问权限中允许 AppPorts。")
        }

        let state: WeChatAccountMigrationService.State
        do {
            state = try dataEnvironment.weChatState(url)
        } catch {
            return .failure(code: "ACCOUNT_NOT_FOUND",
                            message: "无法确认微信账号目录：\(error.localizedDescription)",
                            hint: "确认账号目录仍然存在，并在 AppPorts 中重新扫描。")
        }
        switch state {
        case .local:
            return .failure(code: "NOT_MIGRATED",
                            message: "账号「\(url.lastPathComponent)」当前在本地，没有需要还原的数据。")
        case .whole:
            return .failure(code: "NOT_SPLIT_MIGRATED",
                            message: "账号「\(url.lastPathComponent)」是按整体容器迁移的，请还原整个微信容器。",
                            hint: "使用 appports_restore_path 还原微信的容器目录。")
        case .conflict:
            return .failure(code: "WECHAT_CONFLICT",
                            message: "账号「\(url.lastPathComponent)」的迁移状态不一致，AppPorts 需要先人工处理。",
                            hint: "在 AppPorts 的数据目录页面处理冲突后再重试。")
        case .split:
            break
        }

        let members = dataEnvironment.weChatMemberPaths(url)
        let taskID = submitWeChatRestore(account: url, members: members)
        return .json([
            "task_id": taskID.uuidString,
            "status": "queued",
            "mode": "split",
            "account": url.path,
            "members": members.map { $0.lastPathComponent },
            "notes": [
                "任务已在 AppPorts 任务中心创建，可随时暂停或取消。",
                "用 appports_task 查询进度；还原失败时外置副本会保留。",
            ],
        ])
    }

    // MARK: - Submission

    private func submitLinkMigration(target: MCPDataTarget, destination: URL) -> UUID {
        let item = target.item
        let app = target.app
        let destinationParent = destination.deletingLastPathComponent()
        let prepare = dataEnvironment.prepareDataMigration
        let perform = dataEnvironment.symlinkOperation
        return environment.taskCenter.submit(
            title: String(format: "正在迁移「%@」".localized, item.name),
            category: category(for: target),
            resources: MigrationResources(paths: [item.path, destination]),
            presentDetails: false,
            operation: { progress in
                var fresh = item
                if let app {
                    fresh = try await prepare(item, app, destinationParent, progress)
                }
                return try await perform(fresh, destinationParent, progress)
            },
            completion: { NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil) }
        )
    }

    private func category(for target: MCPDataTarget) -> MigrationCategory {
        switch target.kind {
        case .customDirectory: return .directories
        case .toolDirectory: return .tools
        case .appData: return .appData
        }
    }

    private func submitMountMigration(target: MCPDataTarget, root: URL) -> UUID {
        let item = target.item
        let app = target.app
        let prepare = dataEnvironment.prepareDataMigration
        let perform = dataEnvironment.mountOperation
        return environment.taskCenter.submit(
            title: String(format: "正在挂载迁移「%@」".localized, item.name),
            category: .appData,
            resources: MigrationResources(paths: [item.path, root], keys: ["apfs-layout"]),
            presentDetails: false,
            operation: { progress in
                var fresh = item
                if let app {
                    fresh = try await prepare(item, app, root, progress)
                }
                return try await perform(fresh, root, progress)
            },
            completion: { NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil) }
        )
    }

    private func submitLinkRestore(target: MCPDataTarget) -> UUID {
        let item = target.item
        let perform = dataEnvironment.restoreOperation
        var paths = [item.path]
        if let destination = item.linkedDestination { paths.append(destination) }
        return environment.taskCenter.submit(
            title: String(format: "正在还原「%@」".localized, item.name),
            category: item.type == .dotFolder ? .tools : .appData,
            resources: MigrationResources(paths: paths),
            presentDetails: false,
            operation: { progress in try await perform(item, progress) },
            completion: { NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil) }
        )
    }

    private func submitMountRestore(target: MCPDataTarget, record: ContainerMountRecord) -> UUID {
        let item = target.item
        let estimated = item.sizeBytes
        let perform = dataEnvironment.mountRestoreOperation
        return environment.taskCenter.submit(
            title: String(format: "正在还原「%@」".localized, item.name),
            category: .appData,
            resources: MigrationResources(paths: [item.path, URL(fileURLWithPath: record.externalRootPath)],
                                          keys: ["apfs-layout"]),
            presentDetails: false,
            operation: { progress in try await perform(record, estimated, progress) },
            completion: { NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil) }
        )
    }

    private func submitWeChatMigration(account: URL,
                                       members: [URL],
                                       mode: WeChatAccountMigrationService.Mode,
                                       root: URL,
                                       name: String) -> UUID {
        let perform = dataEnvironment.weChatMigrate
        let title = mode == .split
            ? "正在拆分迁移微信账号数据".localized + " · " + name
            : String(format: "正在挂载迁移「%@」".localized, name)
        return environment.taskCenter.submit(
            title: title,
            category: .appData,
            resources: MigrationResources(paths: [account] + members, keys: ["apfs-layout"]),
            presentDetails: false,
            operation: { progress in
                let warnings = try await perform(account, mode, root, progress)
                return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            },
            completion: { NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil) }
        )
    }

    private func submitWeChatRestore(account: URL, members: [URL]) -> UUID {
        let perform = dataEnvironment.weChatRestore
        return environment.taskCenter.submit(
            title: "正在还原微信账号数据".localized + " · " + account.lastPathComponent,
            category: .appData,
            resources: MigrationResources(paths: [account] + members, keys: ["apfs-layout"]),
            presentDetails: false,
            operation: { progress in
                let warnings = try await perform(account, progress)
                return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            },
            completion: { NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil) }
        )
    }

    // MARK: - Target resolution

    private func resolveApp(_ path: String) async throws -> MCPAppLookup {
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.failure(code: "APP_NOT_FOUND",
                                     message: "找不到应用：\(requested.path)",
                                     hint: "先用 appports_list_apps 查看可迁移的应用路径。"))
        }
        let running = environment.runningApplications()
        let root = environment.externalRoot()
        var scanned: [AppItem] = []
        for directory in environment.localAppsDirectories() {
            scanned += await environment.scanLocal(directory, running, root)
        }
        guard let app = scanned.first(where: { $0.path.standardizedFileURL == requested }) else {
            return .failure(.failure(code: "APP_NOT_FOUND",
                                     message: "\(requested.path) 不是 AppPorts 可管理的应用。",
                                     hint: "只有 /Applications 中的真实 .app 或应用文件夹可以管理数据目录。"))
        }
        return .found(app)
    }

    private func locateTarget(at url: URL, appPath: String?) async throws -> MCPDataTargetLookup {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.failure(code: "PATH_NOT_FOUND",
                                     message: "找不到目录：\(standardized.path)",
                                     hint: "用 appports_list_paths 查看可迁移的目录路径。"))
        }

        if let appPath {
            switch try await resolveApp(appPath) {
            case let .failure(result):
                return .failure(result)
            case let .found(app):
                let scan = await dataEnvironment.scanAppData(app, environment.externalRoot())
                let direct = scan.items.first { $0.path.standardizedFileURL == standardized }
                let member = scan.items.first { candidate in
                    candidate.weChatSplitMembers.contains { $0.path.standardizedFileURL == standardized }
                }
                if let item = direct ?? member {
                    return .found(MCPDataTarget(item: item, kind: .appData(app)))
                }
                if dataEnvironment.installationLocationAllowed() == false {
                    return .failure(.failure(code: "INSTALLATION_LOCATION",
                                             message: "请把 AppPorts 放在「应用程序」文件夹后重新打开。",
                                             hint: "非标准位置运行时无法确认应用数据目录的边界。"))
                }
                return .failure(.failure(code: "PATH_NOT_A_DATA_DIRECTORY",
                                         message: "\(standardized.path) 不是「\(app.displayName)」的可迁移数据目录。",
                                         hint: "用 appports_list_paths（app_path=\(app.path.path)）查看该应用的目录列表。"))
            }
        }

        if let config = dataEnvironment.customConfigurations().first(where: {
            $0.localURL.standardizedFileURL == standardized
        }) {
            let pairs = await dataEnvironment.scanCustomDirectories([config], false)
            guard let pair = pairs.first else {
                return .failure(.failure(code: "PATH_NOT_FOUND",
                                         message: "无法读取自定义目录：\(standardized.path)"))
            }
            return .found(MCPDataTarget(item: pair.local.dataDirItem, kind: .customDirectory(config)))
        }

        let tools = await dataEnvironment.scanToolDirectories(environment.externalRoot())
        if let item = tools.first(where: { $0.path.standardizedFileURL == standardized }) {
            return .found(MCPDataTarget(item: item, kind: .toolDirectory))
        }
        if appPath == nil {
            return .failure(.failure(code: "APP_REQUIRED",
                                     message: "\(standardized.path) 需要 app_path 才能确定它属于哪个应用。",
                                     hint: "应用数据目录请提供 app_path；工具目录与自定义目录可以直接用路径。"))
        }
        return .failure(.failure(code: "PATH_NOT_FOUND",
                                 message: "\(standardized.path) 不在 AppPorts 的目录列表中。",
                                 hint: "用 appports_list_paths 查看可用路径。"))
    }

    // MARK: - Payloads

    private func dataItemPayload(_ item: DataDirItem) -> [String: Any] {
        var payload: [String: Any] = [
            "name": item.name,
            "path": item.path.path,
            "type": item.type.rawValue,
            "type_title": item.type.localizedTitle,
            "priority": item.priority.rawValue,
            "description": item.description,
            "status": item.status,
            "state": item.displayedStatus,
            "size_bytes": item.sizeBytes,
            "size_incomplete": item.sizeIsIncomplete,
            "is_migratable": item.isMigratable,
            "requires_mount_migration": item.requiresMountMigration,
            "can_restore": item.canRestore,
            "auto_mount_paused": item.autoMountPaused,
        ]
        if let size = item.size { payload["size"] = size }
        if let reason = item.nonMigratableReason { payload["non_migratable_reason"] = reason }
        if let name = item.associatedAppName { payload["associated_app_name"] = name }
        if let identifier = item.associatedBundleIdentifier {
            payload["associated_bundle_id"] = identifier
        }
        if let destination = item.linkedDestination {
            payload["linked_destination"] = destination.path
        }
        if item.weChatSplitMembers.isEmpty == false {
            payload["split_members"] = item.weChatSplitMembers.map { member -> [String: Any] in
                ["name": member.name, "path": member.path.path, "status": member.status]
            }
        }
        return payload
    }

    private func accountPayload(_ item: DataDirItem) -> [String: Any] {
        var payload: [String: Any] = [
            "name": item.path.lastPathComponent,
            "path": item.path.path,
            "status": item.status,
            "state": item.displayedStatus,
            "members": dataEnvironment.weChatMemberPaths(item.path).map { $0.lastPathComponent },
        ]
        if let state = try? dataEnvironment.weChatState(item.path) {
            payload["migration_state"] = Self.weChatStateValue(state)
        }
        return payload
    }

    private func customPairPayload(_ pair: CustomDirPair) -> [String: Any] {
        [
            "name": pair.config.displayName,
            "local_path": pair.config.localURL.path,
            "external_base": pair.config.externalBaseURL.path,
            "external_path": pair.config.externalDestinationURL.path,
            "status": pair.local.status,
            "state": CustomDirStatus.localized(pair.local.status),
            "size": pair.local.size ?? NSNull(),
            "size_bytes": pair.local.sizeBytes,
            "can_restore": pair.local.status == CustomDirStatus.linked,
        ]
    }

    private func mountPayload(_ record: ContainerMountRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "app_name": record.appName,
            "data_dir_type": record.dataDirType,
            "mount_point_path": record.mountPointPath,
            "volume_name": record.volumeName,
            "volume_uuid": record.volumeUUID,
            "external_root_path": record.externalRootPath,
            "created_at": Self.iso8601(record.createdAt),
        ]
        if let identifier = record.bundleIdentifier { payload["bundle_id"] = identifier }
        if let encrypted = record.isEncrypted { payload["is_encrypted"] = encrypted }
        return payload
    }

    private func linkPayload(_ record: ManagedDataLinkRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "operation_id": record.operationID.uuidString,
            "app_name": record.appName,
            "data_dir_type": record.dataDirType,
            "original_path": record.originalPath,
            "destination_path": record.destinationPath,
            "created_at": Self.iso8601(record.createdAt),
        ]
        if let identifier = record.bundleIdentifier { payload["bundle_id"] = identifier }
        return payload
    }

    private func dataTransferPayload(_ record: DataTransferRecord) -> [String: Any] {
        [
            "operation_id": record.operationID.uuidString,
            "mode": record.mode.rawValue,
            "direction": record.direction.rawValue,
            "phase": record.phase.rawValue,
            "app_name": record.appName,
            "data_dir_type": record.dataDirType,
            "original_path": record.originalPath,
            "active_path": record.activePath,
            "destination_path": record.destinationPath,
            "created_at": Self.iso8601(record.createdAt),
        ]
    }

    private func cleanupPayload(_ record: ContainerCleanupRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "cleanup_id": record.id.uuidString,
            "kind": record.kind.rawValue,
            "app_name": record.mountRecord.appName,
            "local_path": record.localPath,
            "mount_point_path": record.mountRecord.mountPointPath,
            "retry_failure_count": record.retryFailureCount,
        ]
        if let staging = record.restoreStagingPath { payload["restore_staging_path"] = staging }
        return payload
    }

    // MARK: - Helpers

    private func bundleIdentifier(of app: AppItem) -> String? {
        Bundle(url: app.bundleURL ?? app.path)?.bundleIdentifier
    }

    private func weChatAccountRedirectFailure(_ url: URL, tool: String) -> MCPToolResult {
        .failure(code: "WECHAT_ACCOUNT",
                 message: "\(url.lastPathComponent) 是微信账号目录。",
                 hint: "账号数据请使用 \(tool)。")
    }

    private static func weChatMode(_ value: String) -> WeChatAccountMigrationService.Mode? {
        switch value {
        case "split": return .split
        case "whole": return .whole
        default: return nil
        }
    }

    private static func weChatStateValue(_ state: WeChatAccountMigrationService.State) -> String {
        switch state {
        case .local: return "local"
        case .whole: return "whole"
        case .split: return "split"
        case .conflict: return "conflict"
        }
    }

    /// Mirrors `DataDirsView.suggestedDestinationPath(for:under:)`: the mover
    /// creates `<name>` inside this directory.
    private static func dataDestinationPath(for item: DataDirItem, under root: URL) -> URL {
        guard item.type != .dotFolder else {
            return root.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
        }
        let standardizedPath = item.path.standardizedFileURL.path
        let libraryRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library").standardizedFileURL.path
        if standardizedPath.hasPrefix(libraryRoot + "/") {
            let relativePath = String(standardizedPath.dropFirst(libraryRoot.count + 1))
            return root.appendingPathComponent(relativePath)
        }
        return root.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
    }

    private static func byteText(_ bytes: Int64) -> String {
        LocalizedByteCountFormatter.string(fromByteCount: bytes)
    }
}
