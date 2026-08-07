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
        .frame(minWidth: 300, minHeight: 360)
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
                Text(dayCounterStore.renderDate, format: .dateTime.month().day())
                    .font(.system(size: 12))
                Text(dayCounterStore.renderDate, format: .dateTime.weekday(.wide))
                    .font(.system(size: 12))
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
                Text("今日进度")
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
        List {
            ForEach(QuestTier.allCases, id: \.self) { tier in
                let group = store.tasks.filter { $0.tier == tier }
                let pending = group.filter { $0.status == .pending }
                let settled = group.filter { $0.status != .pending }
                let ordered = pending + settled
                if !group.isEmpty {
                    Section {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tier.accentColor)
                                .frame(width: 7, height: 7)
                            Text(tier.displayName)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WooTodoTheme.mutedOnDark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 18)
                        .padding(.horizontal, 16)
                        .padding(.top, 9)
                        .padding(.bottom, 2)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityAddTraits(.isHeader)

                        ForEach(ordered) { task in
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
                            .moveDisabled(task.status != .pending)
                        }
                        .onMove { offsets, destination in
                            store.move(
                                tier: tier,
                                fromOffsets: offsets,
                                toOffset: destination
                            )
                        }
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "moon.stars")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(WooTodoTheme.purpleLight)
            Text("今天还没有任务")
                .font(.headline)
            Text("今晚列好明日事项，明天直接开干。")
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

    var body: some View {
        HStack(spacing: 10) {
            statusIndicator
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleIfAllowed()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    task.status == .completed ? "撤销完成" : "标记完成"
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    toggleIfAllowed()
                }
                .help(task.status == .completed ? "撤销完成" : "标记完成")

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
                .onTapGesture {
                    toggleIfAllowed()
                }
            if case .repeating = task.recurrence {
                Text("每日")
                    .font(.system(size: 10))
                    .foregroundStyle(WooTodoTheme.metadataOnDark)
                    .help("每日重复")
            }
            if task.reminderTime != nil {
                Image(systemName: "bell")
                    .font(.system(size: 11))
                    .foregroundStyle(WooTodoTheme.metadataOnDark)
                    .help("已设置提醒")
            }
            if let deadline = task.deadlineDate {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 11))
                    .foregroundStyle(
                        deadline < Calendar.current.startOfDay(for: Date())
                            ? WooTodoTheme.orange
                            : WooTodoTheme.metadataOnDark
                    )
                    .help("截止日期：\(deadline.formatted(.dateTime.year().month().day()))")
            }
        }
        .contextMenu {
            if task.status == .pending {
                Button("编辑", action: edit)
                Button("Pass", action: pass)
                Button("删除", role: .destructive, action: delete)
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
