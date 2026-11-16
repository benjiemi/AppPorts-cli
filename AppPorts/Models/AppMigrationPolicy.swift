//
//  AppMigrationPolicy.swift
//  AppPorts
//

import Foundation

/// The migration gate shared by the App UI and the MCP tools, so both refuse
/// exactly the same applications.
enum AppMigrationPolicy {
    struct Options: Equatable {
        let allowAppStoreMigration: Bool
        let allowIOSAppMigration: Bool

        static var current: Options {
            let masSupported = AppMigrationService.isMASExternalInstallSupported
            return Options(
                allowAppStoreMigration: masSupported
                    || UserDefaults.standard.bool(forKey: "allowAppStoreMigration"),
                allowIOSAppMigration: masSupported
                    || UserDefaults.standard.bool(forKey: "allowIOSAppMigration")
            )
        }
    }

    enum SkipReason: String {
        case systemApp = "system_app"
        case running = "running"
        case alreadyLinked = "already_linked"
        case iosMigrationDisabled = "ios_migration_disabled"
        case appStoreMigrationDisabled = "app_store_migration_disabled"
    }

    static func skipReason(for app: AppItem, options: Options) -> SkipReason? {
        if app.isSystemApp { return .systemApp }
        if app.isRunning { return .running }
        if app.status == AppStatus.linked { return .alreadyLinked }
        if app.isIOSApp && !options.allowIOSAppMigration { return .iosMigrationDisabled }
        if app.isAppStoreApp && !options.allowAppStoreMigration { return .appStoreMigrationDisabled }
        return nil
    }
}
