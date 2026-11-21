import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

/// Opt-in visual evidence for the AI access settings. Run with
/// TEST_RUNNER_APPPORTS_RENDER_UI_OUTPUT=/absolute/output/directory.
///
/// The render seeds the same UserDefaults keys the settings toggle writes, starts
/// the loopback endpoint so the status row is truthful, and restores both the
/// defaults and the listener afterwards.
final class MCPSettingsRenderTests: XCTestCase {
    @MainActor
    func testRenderSettingsSheetWithMCPAccess() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to render the MCP settings sheet")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let enabledKey = MCPSettings.enabledKey
        let tokenKey = MCPSettings.tokenKey
        let previousEnabled = UserDefaults.standard.object(forKey: enabledKey)
        let previousToken = UserDefaults.standard.object(forKey: tokenKey)
        let previousLanguage = LanguageManager.shared.language
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set("render-token-0123456789abcdef", forKey: tokenKey)
        defer {
            MCPGateway.shared.stop()
            if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: enabledKey) }
            if let previousToken { UserDefaults.standard.set(previousToken, forKey: tokenKey) }
            else { UserDefaults.standard.removeObject(forKey: tokenKey) }
            LanguageManager.shared.language = previousLanguage
        }
        MCPGateway.shared.startIfEnabled()
        try await Task.sleep(nanoseconds: 400_000_000)

        for language in ["zh-Hans", "en"] {
            LanguageManager.shared.language = language
            for scheme in [ColorScheme.light, .dark] {
                let view = AppStoreSettingsView()
                    .environment(\.locale, Locale(identifier: language))
                try await render(view,
                                 size: NSSize(width: 560, height: 1100),
                                 to: output.appendingPathComponent("mcp-settings-\(language)-\(scheme.fileSuffix).png"),
                                 defaults: .standard,
                                 colorScheme: scheme)
            }
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, size: NSSize, to url: URL,
                                 defaults: UserDefaults, colorScheme: ColorScheme) async throws {
        let appearance = try XCTUnwrap(NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua))
        let originalAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = originalAppearance }

        let host = NSHostingView(rootView: view
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, colorScheme)
            .background(colorScheme == .dark ? Color.black : Color.white))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: 0))
        window.orderFront(nil)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

private extension ColorScheme {
    var fileSuffix: String {
        self == .dark ? "dark" : "light"
    }
}
