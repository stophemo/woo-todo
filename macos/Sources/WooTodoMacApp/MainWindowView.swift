import AppKit
import Charts
import SwiftUI
import WooTodoCore

enum MainWindowSection: String, CaseIterable, Identifiable, Hashable {
    case today
    case all
    case history
    case statistics
    case trash

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "今天"
        case .all: "全部任务"
        case .history: "历史"
        case .statistics: "统计"
        case .trash: "最近删除"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .all: "tray.full"
        case .history: "clock.arrow.circlepath"
        case .statistics: "chart.bar"
        case .trash: "trash"
        }
    }
}

@MainActor
final class MainWindowNavigation: ObservableObject {
    @Published var selection: MainWindowSection

    init(selection: MainWindowSection = .today) {
        self.selection = selection
    }
}

private struct MainEditorRequest: Identifiable {
    let id = UUID()
    let mode: FullTaskEditorMode
}

struct MainWindowView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var dayCounterStore: DayCounterStore
    @ObservedObject var navigation: MainWindowNavigation
    let openSettings: () -> Void

    @State private var editorRequest: MainEditorRequest?
    @State private var showingCategories = false
    @State private var quickAddDraft = QuickAddDraft()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbar }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
                    .background(.bar)
            }
        }
        .tint(WooTodoTheme.purple)
        .onChange(of: navigation.selection) { _, section in
            if section == .trash {
                store.reloadTrash()
            } else if section == .statistics {
                store.reloadStatisticsIfNeeded()
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            List {
                Section("任务") {
                    sidebarButton(.today)
                    sidebarButton(.all)
                }
                Section("回顾") {
                    sidebarButton(.history)
                    sidebarButton(.statistics)
                }
                Section("恢复") {
                    sidebarButton(.trash)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            sidebarFooter
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func sidebarButton(_ section: MainWindowSection) -> some View {
        Button {
            navigation.selection = section
        } label: {
            SidebarNavigationRow(
                title: section.title,
                systemImage: section.systemImage,
                count: count(for: section),
                isSelected: navigation.selection == section
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(navigation.selection == section ? .isSelected : [])
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

    private var selectionBackground: Color {
        colorScheme == .dark
            ? WooTodoTheme.purpleLight.opacity(0.18)
            : WooTodoTheme.purple.opacity(0.10)
    }

    private var sidebarHeader: some View {
        let date = dayCounterStore.renderDate
        let lunar = TraditionalCalendarInfo.render(on: date)
        let tasks = todayRelevantTasks
        let completed = tasks.filter { $0.status == .completed }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WooTodoTheme.purple)
                Text("Woo Todo")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(date.formatted(.dateTime.month(.wide).day()))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text("\(date.formatted(.dateTime.weekday(.wide))) · \(lunar.lunarDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("今日完成")
                    Spacer()
                    Text("\(completed) / \(tasks.count)")
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ProgressView(
                    value: Double(completed),
                    total: Double(max(tasks.count, 1))
                )
                .tint(WooTodoTheme.green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: openSettings) {
                Label("设置…", systemImage: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .today:
            taskContent(sections: todaySections, emptyTitle: "今天没有待办")
        case .all:
            allTasksContent
        case .history:
            VStack(spacing: 0) {
                detailHeader
                HistoryView(
                    tasks: store.history,
                    categories: store.categories,
                    clear: store.clearHistory
                )
            }
        case .statistics:
            VStack(spacing: 0) {
                detailHeader
                StatisticsView(
                    snapshot: store.statistics,
                    categories: store.categories
                )
                .onAppear { store.reloadStatisticsIfNeeded() }
            }
        case .trash:
            VStack(spacing: 0) {
                detailHeader
                TrashView(
                    store: store,
                    categoryName: store.categoryName
                )
            }
        }
    }

    private var allTasksContent: some View {
        VStack(spacing: 0) {
            detailHeader
            QuickAddBar(store: store, draft: quickAddDraft) {
                editorRequest = MainEditorRequest(mode: .create)
            }
            Divider()
                .padding(.horizontal, 28)
            if allPendingSections.isEmpty {
                ContentUnavailableView(
                    "还没有待办",
                    systemImage: "tray",
                    description: Text("写下要做的事，完成即止。")
                )
            } else {
                List {
                    ForEach(allPendingSections, id: \.category.id) { section in
                        Section {
                            ForEach(section.tasks) { task in
                                taskRow(task, showCategory: false, categoryOrder: section.category.order)
                            }
                        } header: {
                            sectionHeader(section.category.name, order: section.category.order, count: section.tasks.count)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func taskContent(
        sections: [TaskListSection],
        emptyTitle: String
    ) -> some View {
        VStack(spacing: 0) {
            detailHeader
            QuickAddBar(store: store, draft: quickAddDraft) {
                editorRequest = MainEditorRequest(mode: .create)
            }
            Divider()
                .padding(.horizontal, 28)
            if sections.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "checklist",
                    description: Text("写下要做的事，完成即止。")
                )
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.tasks) { task in
                                taskRow(
                                    task,
                                    showCategory: true,
                                    categoryOrder: categoryOrder(for: task.categoryID)
                                )
                            }
                        } header: {
                            HStack(spacing: 7) {
                                Text(section.kind.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text("\(section.tasks.count)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.top, 8)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func taskRow(
        _ task: TodoTask,
        showCategory: Bool,
        categoryOrder: Int?
    ) -> some View {
        MainTaskRow(
            task: task,
            categoryName: store.categoryName(for: task.categoryID),
            categoryOrder: categoryOrder,
            showCategory: showCategory,
            toggle: { store.toggleCompletion(id: task.id) },
            pass: { store.pass(id: task.id) },
            edit: { editorRequest = MainEditorRequest(mode: .edit(task)) },
            delete: { store.delete(id: task.id) }
        )
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerTitle)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if navigation.selection == .today || navigation.selection == .all {
                Button {
                    showingCategories = true
                } label: {
                    Label("管理标签", systemImage: "tag")
                }
                .controlSize(.large)
                Button {
                    editorRequest = MainEditorRequest(mode: .create)
                } label: {
                    Label("新增任务", systemImage: "plus")
                }
                .controlSize(.large)
            }
            Button {
                store.reload()
                if navigation.selection == .trash {
                    store.reloadTrash()
                }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
        }
    }

    private var todaySections: [TaskListSection] {
        store.sections
    }

    private var todayRelevantTasks: [TodoTask] {
        let date = store.referenceDate
        return store.allTasks.filter {
            TaskDateState.isRelevant($0, on: date) ||
                TaskDateState.isSettled($0, on: date)
        }
    }

    private var allPendingSections: [(category: TaskCategory, tasks: [TodoTask])] {
        let knownIDs = Set(store.categories.map(\.id))
        let pending = store.allTasks.filter { $0.status == .pending }
        let grouped = Dictionary(grouping: pending) { task in
            knownIDs.contains(task.categoryID) ? task.categoryID : TaskCategory.inboxID
        }
        return store.categories
            .sorted { $0.order < $1.order }
            .compactMap { category in
                let tasks = (grouped[category.id] ?? []).sorted(by: TodoTask.displayOrder)
                return tasks.isEmpty ? nil : (category, tasks)
            }
    }

    private var pendingCount: Int {
        store.allTasks.filter { $0.status == .pending }.count
    }

    private func count(for section: MainWindowSection) -> Int? {
        switch section {
        case .today:
            // 与“今天”列表实际展示的分组保持一致（含接下来与未安排）。
            store.sections.reduce(0) { total, listSection in
                total + listSection.tasks.filter { $0.status == .pending }.count
            }
        case .all:
            pendingCount
        case .history:
            store.history.count
        case .trash:
            store.trashedCount
        case .statistics:
            nil
        }
    }

    private var headerTitle: String {
        switch navigation.selection {
        case .today:
            dayCounterStore.configuration.headerText(on: dayCounterStore.renderDate) ?? "今天"
        case .all:
            "全部任务"
        case .history:
            "历史"
        case .statistics:
            "统计"
        case .trash:
            "最近删除"
        }
    }

    private var headerSubtitle: String {
        switch navigation.selection {
        case .today:
            if let subtitle = dayCounterStore.configuration.subtitleText(
                on: dayCounterStore.renderDate
            ) {
                return subtitle
            }
            let tasks = todayRelevantTasks
            let completed = tasks.filter { $0.status == .completed }.count
            return "今日完成 \(completed) / \(tasks.count)"
        case .all:
            return "\(pendingCount) 条待办"
        case .history:
            return "完成或放弃的任务会留在这里"
        case .statistics:
            return "按完成记录统计；放弃不进入完成率、趋势和标签分布。"
        case .trash:
            return "删除的任务会保留在本机，可随时恢复；恢复后会像新任务一样同步到其他设备。"
        }
    }

    private func sectionHeader(_ title: String, order: Int, count: Int) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(WooTodoTheme.categoryColor(order: order))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }

    private func categoryOrder(for categoryID: String) -> Int? {
        store.categories.first(where: { $0.id == categoryID })?.order
    }

    private func save(_ input: FullTaskInput, request: MainEditorRequest) {
        switch request.mode {
        case .create:
            store.add(
                title: input.title,
                categoryID: input.categoryID,
                startDate: input.startDate,
                endDate: input.endDate,
                reminderTime: input.reminderTime,
                recurrence: input.recurrence
            )
        case let .edit(task):
            store.edit(
                id: task.id,
                title: input.title,
                categoryID: input.categoryID,
                startDate: input.startDate,
                endDate: input.endDate,
                reminderTime: input.reminderTime,
                recurrence: input.recurrence
            )
        }
    }
}

struct SidebarNavigationRow: View {
    let title: String
    let systemImage: String
    let count: Int?
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let accent = colorScheme == .dark ? WooTodoTheme.purpleLight : WooTodoTheme.purple
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? accent : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovered && !isSelected ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

final class QuickAddDraft: ObservableObject {
    @Published var title = ""
}

private struct QuickAddBar: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var draft: QuickAddDraft
    let onDetails: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(WooTodoTheme.purple)
            ZStack(alignment: .leading) {
                if draft.title.isEmpty {
                    Text("写下要做的事，回车添加")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFocused)
                    .onSubmit(add)
                    .accessibilityLabel("新增任务")
            }
            if !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("添加", action: add)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            Button(action: onDetails) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("详细设置标签、时间与提醒")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private func add() {
        let normalized = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        store.add(title: normalized)
        guard store.errorMessage == nil else { return }
        draft.title = ""
        isFocused = true
    }
}

private struct MainTaskRow: View {
    let task: TodoTask
    let categoryName: String
    let categoryOrder: Int?
    let showCategory: Bool
    let toggle: () -> Void
    let pass: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                statusIndicator
                    .frame(width: 22, height: 22)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(task.status == .pass)
            .help(task.status == .completed ? "撤销完成" : "标记完成")
            .accessibilityLabel(task.status == .completed ? "撤销完成" : "标记完成")

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 14))
                    .lineLimit(2)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(titleColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if showCategory, task.categoryID != TaskCategory.inboxID {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(WooTodoTheme.categoryColor(order: categoryOrder ?? 0))
                                .frame(width: 6, height: 6)
                            Text(categoryName)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text(TaskDateLabel.range(start: task.startDate, end: task.endDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if task.recurrence == .daily {
                        Label("每天", systemImage: "repeat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let overdue = TaskDateLabel.overdue(task) {
                        Label(overdue, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(WooTodoTheme.orange)
                    }
                    if task.reminderTime != nil {
                        Image(systemName: "bell")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("已设置提醒")
                    }
                }
            }

            Spacer(minLength: 8)

            if task.status == .pending {
                Button(action: edit) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isHovered ? Color.primary : Color.secondary.opacity(0.65))
                .help("编辑任务")
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if task.status == .pending { edit() }
        }
        .contextMenu {
            if task.status == .pending {
                Button("编辑", action: edit)
                Button("放弃", action: pass)
                Button("移到最近删除", role: .destructive, action: delete)
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(isHovered ? Color.primary.opacity(0.035) : Color.clear)
    }

    private var titleColor: Color {
        task.status == .pending ? .primary : .secondary
    }

    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(task.status == .pending ? Color.clear : statusColor)
            Circle()
                .strokeBorder(
                    task.status == .pending ? Color.secondary.opacity(0.45) : statusColor,
                    lineWidth: 1.5
                )
            if task.status != .pending {
                Image(systemName: task.status == .completed ? "checkmark" : "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 20, height: 20)
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: .secondary
        case .completed: WooTodoTheme.green
        case .pass: WooTodoTheme.orange
        }
    }
}

private enum TaskDateLabel {
    static func range(start: Date?, end: Date?) -> String {
        guard let start, let end else { return "未安排" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日"
        if TodoTask.protocolCalendar.isDate(start, inSameDayAs: end) {
            return formatter.string(from: start)
        }
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }

    static func overdue(_ task: TodoTask) -> String? {
        guard TaskDateState.isOverdue(task, on: Date()), let end = task.endDate else {
            return nil
        }
        let calendar = TodoTask.protocolCalendar
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: end),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        return days > 0 ? "逾期 \(days) 天" : "逾期"
    }
}

private struct TrashView: View {
    @ObservedObject var store: DashboardStore
    let categoryName: (String) -> String

    @State private var pendingRemoval: TrashedTask?
    @State private var showingEmptyConfirmation = false

    var body: some View {
        Group {
            if store.trashedTasks.isEmpty {
                ContentUnavailableView(
                    "最近删除为空",
                    systemImage: "trash",
                    description: Text("删除的任务会保留在本机，可随时恢复。")
                )
            } else {
                List(store.trashedTasks) { item in
                    TrashRow(
                        item: item,
                        categoryName: categoryName(item.task.categoryID),
                        restore: { store.restoreTrash(id: item.id) },
                        remove: { pendingRemoval = item }
                    )
                    .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .toolbar {
            if !store.trashedTasks.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showingEmptyConfirmation = true
                    } label: {
                        Label("清空最近删除", systemImage: "trash")
                    }
                    .controlSize(.large)
                }
            }
        }
        .confirmationDialog(
            "清空最近删除？",
            isPresented: $showingEmptyConfirmation
        ) {
            Button("清空 \(store.trashedTasks.count) 条恢复副本", role: .destructive) {
                store.removeTrash(ids: nil)
            }
        } message: {
            Text("只移除本机的恢复副本；任务已经同步删除，不会影响其他设备。")
        }
        .confirmationDialog(
            "彻底删除这条恢复副本？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("彻底删除", role: .destructive) {
                if let pendingRemoval {
                    store.removeTrash(ids: [pendingRemoval.id])
                }
                pendingRemoval = nil
            }
        } message: {
            Text("只移除本机的恢复副本；任务已经同步删除，不会影响其他设备。")
        }
        .onAppear { store.reloadTrash() }
    }
}

private struct TrashRow: View {
    let item: TrashedTask
    let categoryName: String
    let restore: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.task.title)
                    .font(.system(size: 14))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if item.task.categoryID != TaskCategory.inboxID {
                        Text(categoryName)
                    }
                    Text(TaskDateLabel.range(
                        start: item.task.startDate,
                        end: item.task.endDate
                    ))
                    Text("删除于 \(deletedAtText)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("恢复", action: restore)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("恢复", action: restore)
            Button("彻底删除", role: .destructive, action: remove)
        }
    }

    private var deletedAtText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: item.deletedAt)
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
                .padding(.horizontal, 20)
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

private struct StatisticsView: View {
    let snapshot: StatisticsSnapshot
    let categories: [TaskCategory]

    private var totalActivity: Int {
        snapshot.dailyActivity.map(\.completed).reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
