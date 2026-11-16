import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

/// Baseline/after evidence for the settings sheet. This file is copied into the
/// baseline worktree unchanged, so it must not reference branch-only symbols.
/// Run with TEST_RUNNER_APPPORTS_RENDER_UI_OUTPUT=/absolute/output/directory.
final class SettingsSheetRenderTests: XCTestCase {
    @MainActor
    func testRenderSettingsSheet() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"], path.hasPrefix("/") else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT to render the settings sheet")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let enabledKey = "MCPServerEnabled"
        let tokenKey = "MCPServerToken"
        let previousEnabled = UserDefaults.standard.object(forKey: enabledKey)
        let previousToken = UserDefaults.standard.object(forKey: tokenKey)
        let previousLanguage = LanguageManager.shared.language
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set("render-token-0123456789abcdef", forKey: tokenKey)
        defer {
            if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: enabledKey) }
            if let previousToken { UserDefaults.standard.set(previousToken, forKey: tokenKey) }
            else { UserDefaults.standard.removeObject(forKey: tokenKey) }
            LanguageManager.shared.language = previousLanguage
        }

        for language in ["zh-Hans", "en"] {
            LanguageManager.shared.language = language
            for scheme in [ColorScheme.light, .dark] {
                let view = AppStoreSettingsView()
                    .environment(\.locale, Locale(identifier: language))
                try await render(view,
                                 size: NSSize(width: 560, height: 1100),
                                 to: output.appendingPathComponent("settings-\(language)-\(scheme.suffix).png"),
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
    var suffix: String { self == .dark ? "dark" : "light" }
}
