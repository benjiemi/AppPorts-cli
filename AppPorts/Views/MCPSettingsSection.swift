//
//  MCPSettingsSection.swift
//  AppPorts
//
//  Settings surface for the local MCP endpoint.
//

import AppKit
import SwiftUI

/// The MCP endpoint is off by default. When enabled it listens on the loopback
/// interface only; the access token and the paste-ready client configuration
/// are shown here so the user can connect an AI client without guessing.
struct MCPSettingsSection: View {
    @ObservedObject private var gateway: MCPGateway
    private let settings: MCPSettings
    @AppStorage private var enabled: Bool
    @State private var copied = false

    init(settings: MCPSettings = MCPSettings(), gateway: MCPGateway = .shared) {
        self.settings = settings
        _gateway = ObservedObject(wrappedValue: gateway)
        _enabled = AppStorage(wrappedValue: false, MCPSettings.enabledKey, store: settings.defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundColor(.blue)
                Text("AI 接入（MCP）")
                    .font(.headline)
            }

            Text("允许本机 AI 客户端读取应用与数据目录列表，并创建应用、路径与数据迁移任务；任务会出现在任务中心，与手动操作一致。")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { enabled },
                set: { value in
                    enabled = value
                    copied = false
                    gateway.setEnabled(value)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启用 MCP 服务")
                    if gateway.isRunning {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("运行中")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .toggleStyle(.switch)

            if enabled {
                VStack(alignment: .leading, spacing: 10) {
                    valueRow(title: "服务地址", value: gateway.endpointURL.absoluteString)
                    valueRow(title: "访问令牌", value: tokenDisplay)

                    HStack(spacing: 10) {
                        Button(action: copyClientConfiguration) {
                            Label("复制客户端配置", systemImage: "doc.on.doc")
                        }
                        Button(action: rotateToken) {
                            Label("重新生成访问令牌", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.bordered)

                    if let error = gateway.lastError {
                        Text(verbatim: error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if copied {
                        Label("已复制客户端配置", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.06))
                .cornerRadius(10)
            }
        }
    }

    private var tokenDisplay: String {
        guard let token = settings.token(creatingIfNeeded: false) else { return "—" }
        return String(token.prefix(6)) + "…" + String(token.suffix(4))
    }

    private func valueRow(title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(verbatim: value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func copyClientConfiguration() {
        let configuration = gateway.clientConfiguration()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(configuration, forType: .string)
        copied = true
        AppLogger.shared.log("已复制 MCP 客户端配置", level: "INFO")
    }

    private func rotateToken() {
        gateway.rotateToken()
        copied = false
    }
}
