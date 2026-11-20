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
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("开放 MCP 服务")
                                Text("仅限本机其他 Agent 调用")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { store.isEnabled },
                                    set: { store.setEnabled($0) }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }

                        Text("开启后，Woo Todo 会在本机开放 MCP 服务，仅限本机的其他 Agent 通过回环地址调用。Agent 可以查询、新增、编辑、完成、撤销、放弃、删除和恢复任务，管理标签，并读取统计。服务不会暴露到局域网或互联网；任务仍只保存在本机，并会参与你已配置的同步。服务使用首次生成后固定的五位随机端口；端口冲突时会自动更换，届时需要重新复制 Agent 命令。")
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
                    Label("MCP 服务", systemImage: "server.rack")
                        .font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Woo Todo 需要保持运行。把命令添加到对应 Agent；访问令牌相当于本机密码，不要发送给其他人。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        agentSnippet(
                            title: "Claude Code",
                            text: store.claudeCodeSnippet,
                            target: "claude"
                        )
                        agentSnippet(
                            title: "Codex",
                            note: "令牌变量需要保留在启动 Codex 的 shell 环境中。",
                            text: store.codexSnippet,
                            target: "codex"
                        )
                        agentSnippet(
                            title: "Pi",
                            text: store.piSnippet,
                            target: "pi"
                        )
                        agentSnippet(
                            title: "Hermes",
                            note: "运行后按提示粘贴访问令牌。",
                            text: store.hermesSnippet,
                            target: "hermes"
                        )
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("常用 Agent", systemImage: "terminal")
                        .font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Cursor / VS Code / 其他 MCP 客户端（MCP JSON）")
                            .font(.caption.weight(.semibold))
                        snippet(store.configurationSnippet, target: "json")
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("通用配置", systemImage: "curlybraces")
                        .font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("仅本机可访问", systemImage: "lock.shield")
                        Text("服务运行在 Woo Todo 进程内，不会额外启动后台进程；多个本机 Agent 共用同一个地址。只监听 127.0.0.1，关闭开关或退出应用后立即停止监听；每个请求都必须携带访问令牌。")
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

    private func agentSnippet(
        title: String,
        note: String? = nil,
        text: String,
        target: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            snippet(text, target: target)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
