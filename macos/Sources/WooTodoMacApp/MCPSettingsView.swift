import AppKit
import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject var store: MCPSettingsStore
    @State private var revealsToken = false
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(
                            "允许本机 MCP 客户端操作任务",
                            isOn: Binding(
                                get: { store.isEnabled },
                                set: { store.setEnabled($0) }
                            )
                        )

                        Text("开启后，Claude Code、Cursor、VS Code 等支持 HTTP MCP 的客户端可以通过本机回环地址调用 Woo Todo 的任务接口。任务仍然只保存在本机，并会参与你已配置的同步。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        LabeledContent("状态") {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 8, height: 8)
                                Text(store.status.title)
                                if let detail = store.status.detail {
                                    Text(detail)
                                        .foregroundStyle(.red)
                                }
                            }
                        }

                        LabeledContent("地址") {
                            HStack(spacing: 10) {
                                Text(store.endpointURL.absoluteString)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                copyButton(
                                    title: "复制地址",
                                    value: store.endpointURL.absoluteString,
                                    target: "endpoint"
                                )
                            }
                        }

                        LabeledContent("访问令牌") {
                            HStack(spacing: 10) {
                                Text(revealsToken ? store.token : String(repeating: "•", count: 24))
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                Button {
                                    revealsToken.toggle()
                                } label: {
                                    Image(systemName: revealsToken ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                .help(revealsToken ? "隐藏令牌" : "显示令牌")
                                copyButton(
                                    title: "复制令牌",
                                    value: store.token,
                                    target: "token"
                                )
                                Button("重新生成") {
                                    store.regenerateToken()
                                    revealsToken = true
                                }
                                .help("旧令牌会立即失效，需要同步更新客户端配置")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("本机 MCP 接入", systemImage: "link")
                        .font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("配置客户端")
                            .font(.headline)
                        Text("Woo Todo 需要保持运行。把下面的配置添加到支持 MCP 的客户端；令牌相当于本机密码，不要发送给其他人。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Claude Code")
                            .font(.caption.weight(.semibold))
                        snippet(store.commandLineSnippet, target: "command")

                        Text("Cursor / VS Code（MCP JSON）")
                            .font(.caption.weight(.semibold))
                        snippet(store.configurationSnippet, target: "json")
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("客户端配置", systemImage: "terminal")
                        .font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("仅监听 127.0.0.1", systemImage: "lock.shield")
                        Text("服务不会暴露到局域网或互联网；每个请求都必须携带上面的访问令牌。关闭开关后立即停止监听。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("安全边界", systemImage: "hand.raised")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .textSelection(.enabled)
    }

    private var statusColor: Color {
        switch store.status {
        case .running: .green
        case .starting: .orange
        case .disabled, .failed: .secondary
        }
    }

    private func snippet(_ text: String, target: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            copyButton(title: "复制", value: text, target: target)
        }
    }

    private func copyButton(title: String, value: String, target: String) -> some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            copied = target
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if copied == target { copied = nil }
            }
        } label: {
            Label(
                copied == target ? "已复制" : title,
                systemImage: copied == target ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(.borderless)
    }
}
