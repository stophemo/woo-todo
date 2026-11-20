import SwiftUI
import WooTodoCore

struct TodayView: View {
    @ObservedObject var store: TodayStore
    @ObservedObject var dayCounterStore: DayCounterStore
    @State private var showingNewTask = false
    @State private var editingTask: TodoTask?

    var body: some View {
        VStack(spacing: 0) {
            header
            progress
            if store.tasks.isEmpty && store.upcomingTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(minWidth: 300, minHeight: 360)
        .foregroundStyle(.white)
        .tint(WooTodoTheme.purpleLight)
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingNewTask) {
            FullTaskEditorView(
                mode: .create,
                categories: store.categories,
                persistCategories: { store.updateCategories($0) }
            ) { input in
                store.add(
                    title: input.title,
                    categoryID: input.categoryID,
                    startDate: input.startDate,
                    endDate: input.endDate,
                    reminderTime: input.reminderTime,
                    recurrence: input.recurrence
                )
            }
        }
        .sheet(item: $editingTask) { task in
            FullTaskEditorView(
                mode: .edit(task),
                categories: store.categories,
                persistCategories: { store.updateCategories($0) }
            ) { input in
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

    private var header: some View {
        let traditionalDate = TraditionalCalendarInfo.render(on: dayCounterStore.renderDate)
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if let title = dayCounterStore.configuration.headerText(
                    on: dayCounterStore.renderDate
                ) {
                    Text(title)
                        .font(.system(size: 27, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let subtitle = dayCounterStore.configuration.subtitleText(
                    on: dayCounterStore.renderDate
                ) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(WooTodoTheme.mutedOnDark)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(traditionalDate.lunarDate)
                    .font(.system(size: 12))
                if let annotation = traditionalDate.annotation {
                    Text(annotation)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WooTodoTheme.purpleLight)
                }
            }
            .foregroundStyle(WooTodoTheme.mutedOnDark)
        }
        .padding(.horizontal, 24)
        .padding(.top, 23)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WooTodoTheme.lineOnDark)
                .frame(height: 1)
        }
    }

    private var progress: some View {
        let completed = store.tasks.filter { $0.status == .completed }.count
        let total = store.tasks.count
        return VStack(spacing: 0) {
            HStack {
                Text("今天完成")
                Spacer()
                Text("\(completed) / \(total)")
                    .foregroundStyle(.white)
                    .font(.system(size: 13, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(WooTodoTheme.mutedOnDark)
            .padding(.bottom, 10)

            Rectangle()
                .fill(WooTodoTheme.green)
                .frame(height: 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private var taskList: some View {
        let allTasks = store.tasks + store.upcomingTasks.filter { upcoming in
            !store.tasks.contains(where: { $0.id == upcoming.id })
        }
        let sections = TaskListPresenter.sections(
            tasks: allTasks,
            categories: store.categories,
            on: store.referenceDate
        )
        return List {
            ForEach(sections) { section in
                Section {
                    HStack(spacing: 7) {
                        Image(systemName: sectionSymbol(section.kind))
                            .font(.system(size: 10, weight: .semibold))
                        Text(section.kind.title)
                        Spacer(minLength: 4)
                        Text("\(section.tasks.count)")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(section.kind == .overdue
                        ? WooTodoTheme.orange
                        : WooTodoTheme.mutedOnDark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 18)
                    .padding(.horizontal, 16)
                    .padding(.top, 9)
                    .padding(.bottom, 2)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityAddTraits(.isHeader)

                    ForEach(section.tasks) { task in
                        TaskRow(
                            task: task,
                            toggle: { store.toggleCompletion(id: task.id) },
                            pass: {
                                if task.status == .pending {
                                    store.pass(id: task.id)
                                }
                            },
                            edit: { editingTask = task },
                            delete: { store.delete(id: task.id) }
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .padding(.top, 7)
        .environment(\.defaultMinListRowHeight, 1)
        .environment(\.defaultMinListHeaderHeight, 1)
    }

    private func sectionSymbol(_ kind: TaskSectionKind) -> String {
        switch kind {
        case .overdue: "exclamationmark.circle"
        case .today: "sun.max"
        case .upcoming: "calendar"
        case .unscheduled: "tray"
        case .settledToday: "checkmark.circle"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "moon.stars")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(WooTodoTheme.purpleLight)
            Text("今天还没有任务")
                .font(.headline)
            Text("写下要做的事，完成即止。")
                .font(.caption)
                .foregroundStyle(WooTodoTheme.mutedOnDark)
            Button("新增任务") {
                showingNewTask = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

}

private struct TaskRow: View {
    let task: TodoTask
    let toggle: () -> Void
    let pass: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    @State private var isStatusHovered = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                toggleIfAllowed()
            } label: {
                statusIndicator
                    .frame(width: 40, height: 39)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(isStatusHovered ? 0.08 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isStatusHovered = hovering && task.status != .pass
            }
            .accessibilityLabel(task.status == .completed ? "撤销完成" : "标记完成")
            .help(task.status == .completed ? "撤销完成" : "标记完成")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(
                        task.status == .pending
                            ? WooTodoTheme.taskOnDark
                            : WooTodoTheme.settledOnDark
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { toggleIfAllowed() }
                HStack(spacing: 6) {
                    Text(dateRangeText)
                        .font(.system(size: 10))
                        .foregroundStyle(WooTodoTheme.metadataOnDark)
                    if TaskDateState.isOverdue(task, on: Date()) {
                        Text(overdueText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(WooTodoTheme.orange)
                    }
                    if task.reminderTime != nil {
                        Image(systemName: "bell")
                            .font(.system(size: 10))
                            .foregroundStyle(WooTodoTheme.metadataOnDark)
                    }
                }
            }
            if task.status == .pending {
                Button(action: edit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WooTodoTheme.metadataOnDark)
                .help("编辑任务")
            }
        }
        .contextMenu {
            if task.status == .pending {
                Button("编辑", action: edit)
                Button("放弃", action: pass)
                Button("移到最近删除", role: .destructive, action: delete)
            }
        }
        .frame(minHeight: 39)
        .padding(.horizontal, 16)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WooTodoTheme.taskLineOnDark)
                .frame(height: 1)
                .padding(.horizontal, 16)
        }
    }

    private var dateRangeText: String {
        guard let start = task.startDate, let end = task.endDate else { return "未安排" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日"
        let range = if TodoTask.protocolCalendar.isDate(start, inSameDayAs: end) {
            formatter.string(from: start)
        } else {
            "\(formatter.string(from: start))–\(formatter.string(from: end))"
        }
        return task.recurrence == .daily ? "\(range) · 每天" : range
    }

    private var overdueText: String {
        guard let end = task.endDate else { return "逾期" }
        let calendar = TodoTask.protocolCalendar
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: end),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        return "逾期 \(days) 天"
    }

    private var statusIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(task.status == .pending ? Color.clear : statusColor)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    task.status == .pending ? WooTodoTheme.controlBorderOnDark : statusColor,
                    lineWidth: 1
                )
            if task.status != .pending {
                Image(systemName: task.status == .completed ? "checkmark" : "xmark")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(WooTodoTheme.ink)
            }
        }
        .frame(width: 17, height: 17)
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: WooTodoTheme.mutedOnDark
        case .completed: WooTodoTheme.green
        case .pass: WooTodoTheme.orange
        }
    }

    private func toggleIfAllowed() {
        if task.status != .pass { toggle() }
    }
}
