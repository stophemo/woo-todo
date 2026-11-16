import AppKit
import Charts
import SwiftUI
import WooTodoCore

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case tasks
    case history
    case statistics
    case sync
    case display
    case shortcuts
    case localData

    var id: Self { self }

    static var taskSections: [Self] {
        [.tasks, .history, .statistics]
    }

    static var settingSections: [Self] {
        [.display, .shortcuts, .sync, .localData]
    }

    var title: String {
        switch self {
        case .tasks: "任务"
        case .history: "历史"
        case .statistics: "统计"
        case .sync: "同步"
        case .display: "显示"
        case .shortcuts: "快捷键"
        case .localData: "本机数据"
        }
    }

    var systemImage: String {
        switch self {
        case .tasks: "checklist"
        case .history: "clock.arrow.circlepath"
        case .statistics: "chart.bar"
        case .sync: "arrow.triangle.2.circlepath"
        case .display: "textformat"
        case .shortcuts: "command"
        case .localData: "externaldrive"
        }
    }
}

@MainActor
final class DashboardNavigation: ObservableObject {
    @Published var selection: DashboardSection

    init(selection: DashboardSection = .tasks) {
        self.selection = selection
    }
}

private struct TaskEditorRequest: Identifiable {
    let id = UUID()
    let mode: FullTaskEditorMode
}

struct DashboardView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var syncSettingsStore: SyncSettingsStore
    @ObservedObject var webDavSettingsStore: WebDavSettingsStore
    @ObservedObject var dayCounterStore: DayCounterStore
    @ObservedObject var shortcutSettingsStore: ShortcutSettingsStore
    let localDataManager: LocalDataManager
    @ObservedObject var navigation: DashboardNavigation
    @State private var editorRequest: TaskEditorRequest?
    @State private var showingCategories = false

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section("任务与统计") {
                    ForEach(DashboardSection.taskSections) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .foregroundStyle(
                                navigation.selection == section ? Color.white : Color.primary
                            )
                            .tag(section)
                    }
                }
                Section("设置") {
                    ForEach(DashboardSection.settingSections) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .foregroundStyle(
                                navigation.selection == section ? Color.white : Color.primary
                            )
                            .tag(section)
                    }
                }
            }
            .navigationTitle("Woo Todo")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            detail
                .background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle(navigation.selection.title)
                .textSelection(.enabled)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if navigation.selection == .sync {
                        syncSettingsStore.requestSync(.manual)
                        webDavSettingsStore.requestSync(.manual)
                        Task { await syncSettingsStore.refreshDevices() }
                    } else if navigation.selection != .display && navigation.selection != .shortcuts {
                        store.reload()
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                if navigation.selection == .tasks {
                    Button {
                        showingCategories = true
                    } label: {
                        Label("管理标签", systemImage: "tag")
                    }
                }
                if navigation.selection != .sync &&
                    navigation.selection != .display &&
                    navigation.selection != .shortcuts &&
                    navigation.selection != .localData {
                    Button {
                        editorRequest = TaskEditorRequest(mode: .create)
                    } label: {
                        Label("新增任务", systemImage: "plus")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .sheet(item: $editorRequest) { request in
            FullTaskEditorView(
                mode: request.mode,
                categories: store.categories,
                persistCategories: { categories in
                    store.updateCategories(categories)
                    return store.categories
                }
            ) { input in
                save(input, request: request)
            }
        }
        .sheet(isPresented: $showingCategories) {
            TaskCategorySettingsView(categories: store.categories) { categories in
                store.updateCategories(categories)
            }
        }
        .tint(WooTodoTheme.purple)
        .onAppear { store.reload() }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .tasks:
            TaskSectionsView(
                store: store,
                edit: edit
            )
        case .history:
            HistoryView(
                tasks: store.history,
                categories: store.categories,
                clear: store.clearHistory
            )
        case .statistics:
            StatisticsView(
                snapshot: store.statistics,
                categories: store.categories
            )
        case .sync:
            SyncSettingsView(store: syncSettingsStore, webDavStore: webDavSettingsStore)
        case .display:
            DayCounterSettingsView(store: dayCounterStore)
        case .shortcuts:
            ShortcutSettingsView(store: shortcutSettingsStore)
        case .localData:
            LocalDataSettingsView(manager: localDataManager)
        }
    }

    private func edit(_ task: TodoTask) {
        editorRequest = TaskEditorRequest(mode: .edit(task))
    }

    private func save(_ input: FullTaskInput, request: TaskEditorRequest) {
        switch request.mode {
        case .create:
            store.add(
                title: input.title,
                categoryID: input.categoryID,
                startDate: input.startDate,
                endDate: input.endDate,
                reminderTime: input.reminderTime
            )
        case let .edit(task):
            store.edit(
                id: task.id,
                title: input.title,
                categoryID: input.categoryID,
                startDate: input.startDate,
                endDate: input.endDate,
                reminderTime: input.reminderTime
            )
        }
    }
}

private struct TaskSectionsView: View {
    @ObservedObject var store: DashboardStore
    let edit: (TodoTask) -> Void
    @State private var showingCategories = false
    @State private var focusNewCategory = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("任务")
                    .font(.headline)
                Spacer()
                Button("＋ 新建标签") {
                    focusNewCategory = true
                    showingCategories = true
                }
                Button("管理标签") {
                    focusNewCategory = false
                    showingCategories = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if store.sections.isEmpty {
                ContentUnavailableView(
                    "暂无任务",
                    systemImage: "checklist",
                    description: Text("点击工具栏的加号创建任务；标签可直接输入新名称。")
                )
            } else {
                List {
                    ForEach(store.sections) { section in
                        Section(section.kind.title) {
                            ForEach(section.tasks) { task in
                                DashboardTaskRow(
                                    task: task,
                                    categoryName: store.categoryName(for: task.categoryID),
                                    toggle: { store.toggleCompletion(id: task.id) },
                                    pass: { store.pass(id: task.id) },
                                    edit: { edit(task) },
                                    delete: { store.delete(id: task.id) }
                                )
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showingCategories) {
            TaskCategorySettingsView(
                categories: store.categories,
                focusNewName: focusNewCategory
            ) { categories in
                store.updateCategories(categories)
            }
        }
    }
}

private struct DashboardTaskRow: View {
    let task: TodoTask
    let categoryName: String
    let toggle: () -> Void
    let pass: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: task.status == .completed ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(
                        task.status == .completed ? WooTodoTheme.green : Color.secondary
                    )
            }
            .buttonStyle(.plain)
            .disabled(task.status == .pass)
            .help(task.status == .completed ? "撤销完成" : "标记完成")

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(task.status == .completed ? .secondary : .primary)
                HStack(spacing: 6) {
                    if task.categoryID != TaskCategory.inboxID {
                        TaskBadge(text: categoryName, accent: WooTodoTheme.purple)
                    }
                    TaskBadge(text: dateRangeText)
                    if task.status != .pending {
                        TaskBadge(text: task.status.displayName)
                    }
                    if TaskDateState.isOverdue(task, on: Date()) {
                        Label(overdueText, systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    if task.reminderTime != nil {
                        Image(systemName: "bell")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("已设置提醒")
                    }
                }
            }
            Spacer()
            if task.status == .pending {
                Button(action: edit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("编辑任务")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if task.status == .pending { edit() }
        }
        .contextMenu {
            if task.status == .pending {
                Button("编辑", action: edit)
                Button("放弃", action: pass)
                Button("删除", role: .destructive, action: delete)
            }
        }
    }

    private var dateRangeText: String {
        guard let start = task.startDate, let end = task.endDate else {
            return "未安排"
        }
        let calendar = TodoTask.protocolCalendar
        if calendar.isDate(start, inSameDayAs: end) {
            return start.formatted(.dateTime.month().day())
        }
        return "\(start.formatted(.dateTime.month().day()))–\(end.formatted(.dateTime.month().day()))"
    }

    private var overdueText: String {
        guard let end = task.endDate else { return "已逾期" }
        let today = TodoTask.protocolCalendar.startOfDay(for: Date())
        let endDay = TodoTask.protocolCalendar.startOfDay(for: end)
        let days = TodoTask.protocolCalendar.dateComponents([.day], from: endDay, to: today).day ?? 0
        return "已逾期 \(days) 天"
    }
}

private struct TaskBadge: View {
    let text: String
    var accent: Color? = nil

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (accent ?? Color.secondary).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }
}

private struct HistoryView: View {
    let tasks: [TodoTask]
    let categories: [TaskCategory]
    let clear: (Set<UUID>?) -> Void
    @State private var isSelecting = false
    @State private var selectedIDs = Set<UUID>()
    @State private var pendingDeletionIDs = Set<UUID>()
    @State private var showingConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if !tasks.isEmpty {
                HStack(spacing: 10) {
                    Text(isSelecting ? "已选择 \(selectedIDs.count) 条" : "共 \(tasks.count) 条历史记录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isSelecting {
                        Button(selectedIDs.count == tasks.count ? "取消全选" : "全选") {
                            selectedIDs = selectedIDs.count == tasks.count
                                ? []
                                : Set(tasks.map(\.id))
                        }
                        Button(role: .destructive) {
                            requestDeletion(selectedIDs)
                        } label: {
                            Label("清除所选", systemImage: "trash")
                        }
                        .disabled(selectedIDs.isEmpty)
                    } else {
                        Button(role: .destructive) {
                            requestDeletion(Set(tasks.map(\.id)))
                        } label: {
                            Label("清除全部", systemImage: "trash")
                        }
                    }
                    Button {
                        isSelecting.toggle()
                        selectedIDs.removeAll()
                    } label: {
                        Label(
                            isSelecting ? "取消多选" : "多选",
                            systemImage: isSelecting ? "xmark" : "checklist"
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                Divider()
            }

            if tasks.isEmpty {
                ContentUnavailableView(
                    "暂无历史",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("完成或放弃的任务会出现在这里。")
                )
            } else {
                List(tasks) { task in
                    if isSelecting {
                        Button {
                            toggleSelection(task.id)
                        } label: {
                            historyRow(task, selected: selectedIDs.contains(task.id))
                        }
                        .buttonStyle(.plain)
                    } else {
                        historyRow(task, selected: nil)
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert("确认清除历史记录？", isPresented: $showingConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除 \(pendingDeletionIDs.count) 条记录", role: .destructive) {
                clear(pendingDeletionIDs)
                selectedIDs.removeAll()
                pendingDeletionIDs.removeAll()
                isSelecting = false
            }
        } message: {
            Text("删除会同步到其他设备，且无法恢复。")
        }
        .onChange(of: tasks.map(\.id)) { _, ids in
            selectedIDs.formIntersection(ids)
            if ids.isEmpty { isSelecting = false }
        }
    }

    private func requestDeletion(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeletionIDs = ids
        showingConfirmation = true
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func historyRow(_ task: TodoTask, selected: Bool?) -> some View {
        HStack(spacing: 12) {
            if let selected {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(selected ? WooTodoTheme.purple : Color.secondary)
            }
            Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(
                    task.status == .completed ? WooTodoTheme.green : WooTodoTheme.orange
                )
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    TaskBadge(text: task.status.displayName)
                    if task.categoryID != TaskCategory.inboxID {
                        TaskBadge(
                            text: TaskCategory.resolveName(
                                id: task.categoryID,
                                categories: categories
                            )
                        )
                    }
                    TaskBadge(text: historyDateText(task))
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private func historyDateText(_ task: TodoTask) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日"
        if let completedAt = task.completedAt {
            return formatter.string(from: completedAt)
        }
        if let start = task.startDate, let end = task.endDate {
            if TodoTask.protocolCalendar.isDate(start, inSameDayAs: end) {
                return formatter.string(from: start)
            }
            return "\(formatter.string(from: start))–\(formatter.string(from: end))"
        }
        return "未安排"
    }
}

private struct StatisticsView: View {
    let snapshot: StatisticsSnapshot
    let categories: [TaskCategory]

    private var totalActivity: Int {
        snapshot.dailyActivity.map(\.completed).reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("按完成记录统计；放弃不进入完成率、趋势和标签分布。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    StatCard(title: "本周完成", value: "\(snapshot.completedThisWeek)")
                    StatCard(title: "连续天数", value: "\(snapshot.currentStreakDays) 天")
                    StatCard(
                        title: "按时率",
                        value: snapshot.onTimeRate?.formatted(
                            .percent.precision(.fractionLength(0))
                        ) ?? "—"
                    )
                    StatCard(title: "进行中", value: "\(snapshot.pendingCount)")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("最近 14 天完成趋势")
                        .font(.headline)
                    Text("共完成 \(totalActivity) 个任务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if totalActivity == 0 {
                        Text("最近还没有完成记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        Chart(snapshot.dailyActivity) { day in
                            BarMark(
                                x: .value("日期", day.date, unit: .day),
                                y: .value("完成", day.completed)
                            )
                            .foregroundStyle(WooTodoTheme.purple)
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.month().day())
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading)
                        }
                        .frame(height: 180)
                        .accessibilityLabel("最近 14 天完成趋势")
                        .accessibilityValue("共完成 \(totalActivity) 个任务")
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    Text("标签分布 · 近 30 天")
                        .font(.headline)
                    if snapshot.categoryActivity.isEmpty {
                        Text("近 30 天还没有完成记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.categoryActivity, id: \.categoryID) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(
                                        TaskCategory.resolveName(
                                            id: item.categoryID,
                                            categories: categories
                                        )
                                    )
                                    Spacer()
                                    Text(
                                        "完成 \(item.completed) 个 · \(item.ratio.formatted(.percent.precision(.fractionLength(0))))"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                ProgressView(value: item.ratio)
                                    .tint(WooTodoTheme.purple)
                            }
                        }
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    Text("最近完成")
                        .font(.headline)
                    if snapshot.recentHistory.isEmpty {
                        Text("还没有完成或放弃的任务")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.recentHistory.prefix(10), id: \.id) { task in
                            HStack(spacing: 10) {
                                Image(
                                    systemName: task.status == .completed
                                        ? "checkmark.circle.fill"
                                        : "xmark.circle.fill"
                                )
                                .foregroundStyle(
                                    task.status == .completed
                                        ? WooTodoTheme.green
                                        : WooTodoTheme.orange
                                )
                                Text(task.title)
                                Spacer()
                                if task.categoryID != TaskCategory.inboxID {
                                    Text(
                                        TaskCategory.resolveName(
                                            id: task.categoryID,
                                            categories: categories
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Text(historyDateText(task))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func historyDateText(_ task: TodoTask) -> String {
        guard let completedAt = task.completedAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: completedAt)
    }
}

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}
