import AppKit
import SwiftUI

struct LocalDataSettingsView: View {
    private enum LocalDataAlert: Identifiable {
        case clear
        case uninstall
        case error(String)
        case manualRemoval

        var id: String {
            switch self {
            case .clear: "clear"
            case .uninstall: "uninstall"
            case .error: "error"
            case .manualRemoval: "manualRemoval"
            }
        }
    }

    let manager: LocalDataManager
    @State private var alert: LocalDataAlert?

    var body: some View {
        Form {
            Section("本机数据") {
                Text("任务数据库、同步凭据、显示与快捷键设置都保存在这台 Mac 上。")
                Text(manager.dataDirectoryPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("清理") {
                Button(role: .destructive) {
                    alert = .clear
                } label: {
                    Label("清除全部本机数据…", systemImage: "trash")
                }
                Button(role: .destructive) {
                    alert = .uninstall
                } label: {
                    Label("卸载并清除…", systemImage: "trash.slash")
                }
                .disabled(!manager.canRemoveApplication)
            }

            Section("说明") {
                Text("清除只影响这台 Mac；云端或其他设备上的任务不会被删除。")
                Text("直接拖拽卸载 App 不会自动清理本机数据，需要使用上面的“卸载并清除”。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(16)
        .alert(item: $alert) { item in
            switch item {
            case .clear:
                Alert(
                    title: Text("清除全部本机数据？"),
                    message: Text(
                        "将删除本机任务、同步凭据、显示和快捷键设置，然后退出应用。此操作无法恢复，云端或其他设备的数据不会受影响。"
                    ),
                    primaryButton: .destructive(Text("清除并退出")) {
                        clearAndQuit()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .uninstall:
                Alert(
                    title: Text("卸载并清除？"),
                    message: Text(
                        "将删除本机全部数据，并把 Woo Todo 移到废纸篓。云端或其他设备的数据不会受影响。"
                    ),
                    primaryButton: .destructive(Text("卸载并清除")) {
                        uninstallAndQuit()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .error(let message):
                Alert(
                    title: Text("操作失败"),
                    message: Text(message),
                    dismissButton: .default(Text("确定"))
                )
            case .manualRemoval:
                Alert(
                    title: Text("本机数据已清除"),
                    message: Text("无法自动把 App 移到废纸篓，请手动拖入废纸篓后退出。"),
                    primaryButton: .default(Text("退出")) {
                        NSApp.terminate(nil)
                    },
                    secondaryButton: .cancel(Text("稍后"))
                )
            }
        }
    }

    private func clearAndQuit() {
        do {
            try manager.clearLocalData()
            NSApp.terminate(nil)
        } catch {
            alert = .error(error.localizedDescription)
        }
    }

    private func uninstallAndQuit() {
        do {
            try manager.clearLocalData()
        } catch {
            alert = .error(error.localizedDescription)
            return
        }
        do {
            try manager.moveApplicationToTrash()
            NSApp.terminate(nil)
        } catch {
            alert = .manualRemoval
        }
    }
}
