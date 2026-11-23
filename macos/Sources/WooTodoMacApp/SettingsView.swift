import SwiftUI
import WooTodoCore

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case display
    case reminders
    case shortcuts
    case sync
    case mcp
    case localData

    var id: Self { self }

    var title: String {
        switch self {
        case .display: "显示"
        case .reminders: "提醒"
        case .shortcuts: "快捷键"
        case .sync: "跨设备"
        case .mcp: "MCP 服务"
        case .localData: "本机数据"
        }
    }

    var systemImage: String {
        switch self {
        case .display: "textformat"
        case .reminders: "bell"
        case .shortcuts: "command"
        case .sync: "laptopcomputer.and.iphone"
        case .mcp: "link"
        case .localData: "externaldrive"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection

    init(selection: SettingsSection = .display) {
        self.selection = selection
    }
}

struct SettingsView: View {
    @ObservedObject var syncSettingsStore: SyncSettingsStore
    @ObservedObject var dayCounterStore: DayCounterStore
    @ObservedObject var dailyDigestSettingsStore: DailyDigestSettingsStore
    @ObservedObject var shortcutSettingsStore: ShortcutSettingsStore
    @ObservedObject var mcpSettingsStore: MCPSettingsStore
    let localDataManager: LocalDataManager
    @ObservedObject var navigation: SettingsNavigation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        navigation.selection = section
                    } label: {
                        SidebarNavigationRow(
                            title: section.title,
                            systemImage: section.systemImage,
                            count: nil,
                            isSelected: navigation.selection == section
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(
                        navigation.selection == section ? .isSelected : []
                    )
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        Group {
                            if navigation.selection == section {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(selectionBackground)
                                    .padding(.vertical, 1)
                            } else {
                                Color.clear
                            }
                        }
                    )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .underPageBackgroundColor))
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            detail
                .background(Color(nsColor: .windowBackgroundColor))
                .textSelection(.enabled)
        }
        .tint(WooTodoTheme.purple)
    }

    @ViewBuilder
    private var selectionBackground: Color {
        colorScheme == .dark
            ? WooTodoTheme.purpleLight.opacity(0.18)
            : WooTodoTheme.purple.opacity(0.10)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .display:
            DayCounterSettingsView(store: dayCounterStore)
        case .reminders:
            ReminderSettingsView(digestStore: dailyDigestSettingsStore)
        case .shortcuts:
            ShortcutSettingsView(store: shortcutSettingsStore)
        case .sync:
            SyncSettingsView(store: syncSettingsStore)
        case .mcp:
            MCPSettingsView(store: mcpSettingsStore)
        case .localData:
            LocalDataSettingsView(manager: localDataManager)
        }
    }
}
