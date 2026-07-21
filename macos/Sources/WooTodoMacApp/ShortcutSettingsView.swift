import SwiftUI
import WooTodoCore

struct ShortcutSettingsView: View {
    @ObservedObject var store: ShortcutSettingsStore

    var body: some View {
        Form {
            Section("全局快捷键") {
                ForEach(GlobalShortcutCommand.allCases, id: \.self) { command in
                    HStack(spacing: 14) {
                        Label(command.title, systemImage: command.systemImage)
                        Spacer()
                        ShortcutRecorder(binding: store.binding(for: command)) { binding in
                            store.update(command, binding: binding)
                        }
                        Button {
                            store.reset(command)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("恢复此项默认快捷键")
                    }
                    .frame(minHeight: 34)
                }
            }

            Section {
                Button {
                    store.resetAll()
                } label: {
                    Label("全部恢复默认", systemImage: "arrow.counterclockwise")
                }
            }

            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}
