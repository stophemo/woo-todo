import SwiftUI
import WooTodoCore

struct ShortcutSettingsView: View {
    @ObservedObject var store: ShortcutSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                        ForEach(GlobalShortcutCommand.allCases, id: \.self) { command in
                            GridRow {
                                Label(command.title, systemImage: command.systemImage)
                                    .lineLimit(1)
                                    .frame(width: 190, alignment: .leading)
                                ShortcutRecorder(binding: store.binding(for: command)) { binding in
                                    store.update(command, binding: binding)
                                }
                                .frame(width: 160, alignment: .trailing)
                                Button {
                                    store.reset(command)
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.borderless)
                                .help("恢复此项默认快捷键")
                            }
                            .frame(minHeight: 32)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("全局快捷键", systemImage: "keyboard")
                        .font(.headline)
                }

                Button {
                    store.resetAll()
                } label: {
                    Label("全部恢复默认", systemImage: "arrow.counterclockwise")
                }

                if let errorMessage = store.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .textSelection(.enabled)
    }
}
