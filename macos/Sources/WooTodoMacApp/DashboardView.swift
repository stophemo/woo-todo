import SwiftUI
import WooTodoCore

private enum DashboardSection: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case someday
    case history
    case statistics
    case sync

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "今日"
        case .week: "本周"
        case .month: "本月"
        case .someday: "闲时"
        case .history: "历史"
        case .statistics: "统计"
        case .sync: "同步"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .week: "calendar.badge.clock"
        case .month: "calendar"
        case .someday: "sparkles"
        case .history: "clock.arrow.circlepath"
        case .statistics: "chart.bar"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }

    var scope: TimeScope? {
        switch self {
        case .today: .daily
        case .week: .weekly
        case .month: .monthly
        case .someday: .anytime
        case .history, .statistics, .sync: nil
        }
    }
}

private struct TaskEditorRequest: Identifiable {
    let id = UUID()
    let mode: FullTaskEditorMode
}

struct DashboardView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var syncSettingsStore: SyncSettingsStore
    @State private var selection: DashboardSection = .today
    @State private var editorRequest: TaskEditorRequest?

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Woo Todo")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            detail
                .navigationTitle(selection.title)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if selection == .sync {
                        syncSettingsStore.requestSync(.manual)
                        Task { await syncSettingsStore.refreshDevices() }
                    } else {
                        store.reload()
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                if selection != .sync {
                    Button {
                        editorRequest = TaskEditorRequest(
                            mode: .create(
                                defaultScope: selection.scope ?? .daily,
                                targetDate: store.referenceDate
                            )
                        )
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
            FullTaskEditorView(mode: request.mode) { input in
                save(input, request: request)
            }
        }
        .onAppear { store.reload() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .today:
            ScopedTasksView(
                title: "今日与已规划的每日任务",
                scope: .daily,
                tasks: store.tasks(for: .daily),
                referenceDate: store.referenceDate,
                toggle: store.toggleCompletion,
                edit: edit,
                delete: store.delete
            )
        case .week:
            ScopedTasksView(
                title: "本周与已规划的每周任务",
                scope: .weekly,
                tasks: store.tasks(for: .weekly),
                referenceDate: store.referenceDate,
                toggle: store.toggleCompletion,
                edit: edit,
                delete: store.delete
            )
        case .month:
            ScopedTasksView(
                title: "本月与已规划的每月任务",
                scope: .monthly,
                tasks: store.tasks(for: .monthly),
                referenceDate: store.referenceDate,
                toggle: store.toggleCompletion,
                edit: edit,
                delete: store.delete
            )
        case .someday:
            ScopedTasksView(
                title: "没有截止时间的闲时任务",
                scope: .anytime,
                tasks: store.tasks(for: .anytime),
                referenceDate: store.referenceDate,
                toggle: store.toggleCompletion,
                edit: edit,
                delete: store.delete
            )
        case .history:
            HistoryView(tasks: store.recentHistory)
        case .statistics:
            StatisticsView(snapshot: store.statistics)
        case .sync:
            SyncSettingsView(store: syncSettingsStore)
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
                scope: input.scope,
                targetDate: input.targetDate,
                tier: input.tier,
                repeats: input.repeats
            )
        case let .edit(task):
            store.edit(
                id: task.id,
                title: input.title,
                scope: input.scope,
                targetDate: input.targetDate,
                tier: input.tier,
                repeats: input.repeats
            )
        }
    }
}

private struct ScopedTasksView: View {
    let title: String
    let scope: TimeScope
    let tasks: [TodoTask]
    let referenceDate: Date
    let toggle: (UUID) -> Void
    let edit: (TodoTask) -> Void
    let delete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            if tasks.isEmpty {
                ContentUnavailableView(
                    "暂无任务",
                    systemImage: "checklist",
                    description: Text("点击工具栏的加号创建任务。")
                )
            } else {
                List {
                    if scope == .anytime {
                        taskRows(tasks, title: "闲时任务")
                    } else {
                        let current = tasks.filter { $0.period?.contains(referenceDate) == true }
                        let upcoming = tasks.filter { task in
                            guard let period = task.period else { return false }
                            return period.start > referenceDate
                        }
                        taskRows(current, title: currentTitle)
                        taskRows(upcoming, title: "已规划")
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var currentTitle: String {
        switch scope {
        case .daily: "今日"
        case .weekly: "本周"
        case .monthly: "本月"
        case .anytime: "闲时"
        }
    }

    @ViewBuilder
    private func taskRows(_ rows: [TodoTask], title: String) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { task in
                    DashboardTaskRow(
                        task: task,
                        toggle: { toggle(task.id) },
                        edit: { edit(task) },
                        delete: { delete(task.id) }
                    )
                }
            }
        }
    }
}

private struct DashboardTaskRow: View {
    let task: TodoTask
    let toggle: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.status == .completed ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(task.status != .pending)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(task.status == .completed ? .secondary : .primary)
                HStack(spacing: 6) {
                    TaskBadge(text: task.tier.displayName)
                    TaskBadge(text: TaskPeriodText.text(for: task))
                    if case .repeating = task.recurrence {
                        Image(systemName: "repeat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                Button("删除", role: .destructive, action: delete)
            }
        }
    }
}

private struct TaskBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private struct HistoryView: View {
    let tasks: [TodoTask]

    var body: some View {
        if tasks.isEmpty {
            ContentUnavailableView(
                "暂无历史",
                systemImage: "clock.arrow.circlepath",
                description: Text("完成或 Pass 的任务会出现在这里。")
            )
        } else {
            List(tasks) { task in
                HStack(spacing: 12) {
                    Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(task.status == .completed ? .green : .orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title)
                        HStack(spacing: 6) {
                            TaskBadge(text: task.status.displayName)
                            TaskBadge(text: task.timeScope.displayName)
                            TaskBadge(text: task.tier.displayName)
                            TaskBadge(text: TaskPeriodText.text(for: task))
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
    }
}

private struct StatisticsView: View {
    let snapshot: StatisticsSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("只统计已经结束的周期，闲时和当前周期不进入履约率；趋势中的当前桶仅展示阶段计数。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    RateCard(title: "周期履约率", metric: snapshot.endedPeriods)
                    RateCard(title: "主线履约率", metric: snapshot.mainlineEndedPeriods)
                }

                TrendTable(
                    title: "最近 7 天",
                    periodKind: .day,
                    buckets: snapshot.dailyTrend
                )
                TrendTable(
                    title: "最近 8 周",
                    periodKind: .week,
                    buckets: snapshot.weeklyTrend
                )
                TrendTable(
                    title: "最近 6 个月",
                    periodKind: .month,
                    buckets: snapshot.monthlyTrend
                )

                CountTable(
                    title: "按时间范围",
                    rows: TimeScope.allCases.map {
                        ($0.displayName, snapshot.countsByScope[$0] ?? StatusCounts())
                    }
                )
                CountTable(
                    title: "按任务级别",
                    rows: QuestTier.allCases.map {
                        ($0.displayName, snapshot.countsByTier[$0] ?? StatusCounts())
                    }
                )
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RateCard: View {
    let title: String
    let metric: AdherenceMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(rateText)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            Text("完成 \(metric.completed) · Pass \(metric.pass)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var rateText: String {
        guard let rate = metric.rate else { return "暂无数据" }
        return rate.formatted(.percent.precision(.fractionLength(0)))
    }
}

private enum TrendPeriodKind {
    case day
    case week
    case month

    var taskTypeText: String {
        switch self {
        case .day: "每日任务"
        case .week: "每周任务"
        case .month: "每月任务"
        }
    }

    var dateFormat: String {
        switch self {
        case .day: "M月d日"
        case .week: "M月d日当周"
        case .month: "yyyy年M月"
        }
    }
}

private struct TrendTable: View {
    let title: String
    let periodKind: TrendPeriodKind
    let buckets: [TrendBucket]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(periodKind.taskTypeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                GridRow {
                    Text("周期").foregroundStyle(.secondary)
                    Text("履约率").foregroundStyle(.secondary)
                    Text("完成").foregroundStyle(.secondary)
                    Text("Pass").foregroundStyle(.secondary)
                    Text("样本").foregroundStyle(.secondary)
                }
                Divider().gridCellColumns(5)
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                    GridRow {
                        Text(periodText(bucket.start))
                        Text(rateText(bucket))
                            .foregroundStyle(bucket.isEnded ? Color.primary : Color.blue)
                        Text(bucket.completed.formatted())
                        Text(bucket.pass.formatted())
                        Text(bucket.sampleCount.formatted())
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func periodText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = periodKind.dateFormat
        return formatter.string(from: date)
    }

    private func rateText(_ bucket: TrendBucket) -> String {
        guard bucket.isEnded else { return "进行中" }
        guard let rate = bucket.rate else { return "暂无" }
        return rate.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct CountTable: View {
    let title: String
    let rows: [(String, StatusCounts)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                GridRow {
                    Text("分类").foregroundStyle(.secondary)
                    Text("全部").foregroundStyle(.secondary)
                    Text("待完成").foregroundStyle(.secondary)
                    Text("已完成").foregroundStyle(.secondary)
                    Text("Pass").foregroundStyle(.secondary)
                }
                Divider().gridCellColumns(5)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0)
                        Text(row.1.total.formatted())
                        Text(row.1.pending.formatted())
                        Text(row.1.completed.formatted())
                        Text(row.1.pass.formatted())
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
