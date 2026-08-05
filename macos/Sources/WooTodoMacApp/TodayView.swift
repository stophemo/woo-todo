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
            if store.tasks.isEmpty {
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
        .frame(minWidth: 340, minHeight: 420)
        .foregroundStyle(.white)
        .tint(WooTodoTheme.purpleLight)
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingNewTask) {
            TaskEditorView(mode: .create) { title, tier, repeatsDaily, reminderTime, deadlineDate in
                store.add(
                    title: title,
                    tier: tier,
                    repeatsDaily: repeatsDaily,
                    reminderTime: reminderTime,
                    deadlineDate: deadlineDate
                )
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(mode: .edit(task)) { title, tier, repeatsDaily, reminderTime, deadlineDate in
                store.edit(
                    id: task.id,
                    title: title,
                    tier: tier,
                    repeatsDaily: repeatsDaily,
                    reminderTime: reminderTime,
                    deadlineDate: deadlineDate
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(WooTodoTheme.purpleLight)
                    .frame(width: 26, height: 26)
                    .background(WooTodoTheme.purple.opacity(0.26), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    if let title = dayCounterStore.configuration.headerText(
                        on: dayCounterStore.renderDate
                    ) {
                        Text(title)
                            .font(.title2.weight(.semibold))
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
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(dayCounterStore.renderDate, format: .dateTime.month().day())
                    .font(.callout.weight(.semibold))
                Text(dayCounterStore.renderDate, format: .dateTime.weekday(.wide))
                    .font(.caption2)
                    .foregroundStyle(WooTodoTheme.mutedOnDark)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var progress: some View {
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text("\(pendingCount)")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("项待办")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WooTodoTheme.mutedOnDark)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(completedCount) / \(totalCount)")
                        .font(.headline.monospacedDigit())
                    Text("已完成")
                        .font(.caption2)
                        .foregroundStyle(WooTodoTheme.mutedOnDark)
                }
            }

            HStack {
                Text("今日进度")
                Spacer()
                Text("\(Int((completionFraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(WooTodoTheme.mutedOnDark)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(WooTodoTheme.lineOnDark)
                    Capsule()
                        .fill(WooTodoTheme.green)
                        .frame(width: proxy.size.width * completionFraction)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private var taskList: some View {
        List {
            ForEach(QuestTier.allCases, id: \.self) { tier in
                let group = store.tasks.filter { $0.tier == tier }
                let pending = group.filter { $0.status == .pending }
                let settled = group.filter { $0.status != .pending }
                if !group.isEmpty {
                    Section {
                        ForEach(pending) { task in
                            TaskRow(
                                task: task,
                                toggle: { store.toggleCompletion(id: task.id) },
                                pass: { store.pass(id: task.id) },
                                edit: { editingTask = task },
                                delete: { store.delete(id: task.id) }
                            )
                        }
                        .onMove { offsets, destination in
                            store.move(
                                tier: tier,
                                fromOffsets: offsets,
                                toOffset: destination
                            )
                        }
                        ForEach(settled) { task in
                            TaskRow(
                                task: task,
                                toggle: { store.toggleCompletion(id: task.id) },
                                pass: {},
                                edit: { editingTask = task },
                                delete: { store.delete(id: task.id) }
                            )
                            .moveDisabled(true)
                        }
                    } header: {
                        let completed = group.filter { $0.status == .completed }.count
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tier.accentColor)
                                .frame(width: 5, height: 18)
                            Text(tier.displayName)
                            Spacer()
                            Text("\(completed) / \(group.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(WooTodoTheme.mutedOnDark)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WooTodoTheme.mutedOnDark)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListHeaderHeight, 0)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "moon.stars")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(WooTodoTheme.purpleLight)
            Text("今天还没有任务")
                .font(.headline)
            Text("把最重要的一件事放进今天")
                .font(.caption)
                .foregroundStyle(WooTodoTheme.mutedOnDark)
            Button {
                showingNewTask = true
            } label: {
                Label("新增任务", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var completedCount: Int {
        store.tasks.filter { $0.status == .completed }.count
    }

    private var pendingCount: Int {
        store.tasks.filter { $0.status == .pending }.count
    }

    private var totalCount: Int {
        store.tasks.count
    }

    private var completionFraction: CGFloat {
        guard totalCount > 0 else { return 0 }
        return CGFloat(completedCount) / CGFloat(totalCount)
    }
}

private struct TaskRow: View {
    let task: TodoTask
    let toggle: () -> Void
    let pass: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(task.tier.accentColor)
                .frame(width: 3, height: 20)

            Button(action: toggle) {
                Image(systemName: statusImage)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(task.status == .pass)
            .help(task.status == .completed ? "撤销完成" : "标记完成")

            Text(task.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .strikethrough(task.status == .completed)
                .foregroundStyle(
                    task.status == .completed ? WooTodoTheme.mutedOnDark : Color.white
                )
            if case .repeating = task.recurrence {
                Image(systemName: "repeat")
                    .font(.caption)
                    .foregroundStyle(WooTodoTheme.mutedOnDark)
                    .help("每日重复")
            }
            if task.reminderTime != nil {
                Image(systemName: "bell")
                    .font(.caption)
                    .foregroundStyle(WooTodoTheme.mutedOnDark)
                    .help("已设置提醒")
            }
            if let deadline = task.deadlineDate {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(
                        deadline < Calendar.current.startOfDay(for: Date())
                            ? WooTodoTheme.orange
                            : WooTodoTheme.mutedOnDark
                    )
                    .help("截止日期：\(deadline.formatted(.dateTime.year().month().day()))")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if task.status == .pending { edit() }
        }
        .contextMenu {
            if task.status == .pending {
                Button("编辑", action: edit)
                Button("Pass", action: pass)
                Button("删除", role: .destructive, action: delete)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WooTodoTheme.lineOnDark)
                .frame(height: 1)
        }
    }

    private var statusImage: String {
        switch task.status {
        case .pending: "square"
        case .completed: "checkmark.square.fill"
        case .pass: "xmark.square.fill"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: WooTodoTheme.mutedOnDark
        case .completed: WooTodoTheme.green
        case .pass: WooTodoTheme.orange
        }
    }
}

private struct TaskEditorView: View {
    enum Mode {
        case create
        case edit(TodoTask)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var tier: QuestTier
    @State private var repeatsDaily: Bool
    @State private var reminderEnabled: Bool
    @State private var reminderDate: Date
    @State private var deadlineEnabled: Bool
    @State private var deadlineDate: Date
    let mode: Mode
    let save: (String, QuestTier, Bool, TaskReminderTime?, Date?) -> Void

    init(
        mode: Mode,
        save: @escaping (String, QuestTier, Bool, TaskReminderTime?, Date?) -> Void
    ) {
        self.mode = mode
        self.save = save
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _tier = State(initialValue: .mainline)
            _repeatsDaily = State(initialValue: false)
            _reminderEnabled = State(initialValue: false)
            _reminderDate = State(initialValue: Self.defaultReminderDate)
            _deadlineEnabled = State(initialValue: false)
            _deadlineDate = State(initialValue: Date())
        case let .edit(task):
            _title = State(initialValue: task.title)
            _tier = State(initialValue: task.tier)
            if case .repeating = task.recurrence {
                _repeatsDaily = State(initialValue: true)
            } else {
                _repeatsDaily = State(initialValue: false)
            }
            _reminderEnabled = State(initialValue: task.reminderTime != nil)
            _reminderDate = State(initialValue: Self.date(for: task.reminderTime))
            _deadlineEnabled = State(initialValue: task.deadlineDate != nil)
            _deadlineDate = State(initialValue: task.deadlineDate ?? Date())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "编辑任务" : "新增今日任务")
                .font(.title3.weight(.semibold))

            TextField("一句话写下要做的事", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            Picker("任务级别", selection: $tier) {
                ForEach(QuestTier.allCases, id: \.self) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .pickerStyle(.segmented)

            Toggle("每天重复", isOn: $repeatsDaily)
            Toggle("在指定时间提醒", isOn: $reminderEnabled)
            if reminderEnabled {
                DatePicker(
                    "提醒时间",
                    selection: $reminderDate,
                    displayedComponents: .hourAndMinute
                )
            }
            Toggle("设置截止日期", isOn: $deadlineEnabled)
                .disabled(repeatsDaily)
            if deadlineEnabled && !repeatsDaily {
                DatePicker("截止日期", selection: $deadlineDate, displayedComponents: .date)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: repeatsDaily) { _, enabled in
            if enabled { deadlineEnabled = false }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !normalizedTitle.isEmpty else { return }
        let components = Calendar.current.dateComponents([.hour, .minute], from: reminderDate)
        let reminderTime = reminderEnabled
            ? try? TaskReminderTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
            : nil
        save(
            normalizedTitle,
            tier,
            repeatsDaily,
            reminderTime,
            deadlineEnabled && !repeatsDaily
                ? Calendar.current.startOfDay(for: deadlineDate)
                : nil
        )
        dismiss()
    }

    private static var defaultReminderDate: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private static func date(for reminderTime: TaskReminderTime?) -> Date {
        guard let reminderTime else { return defaultReminderDate }
        return Calendar.current.date(
            bySettingHour: reminderTime.hour,
            minute: reminderTime.minute,
            second: 0,
            of: Date()
        ) ?? defaultReminderDate
    }
}
