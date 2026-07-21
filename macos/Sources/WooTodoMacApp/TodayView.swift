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
            Divider().opacity(0.45)
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
        .background(Color.clear)
        .sheet(isPresented: $showingNewTask) {
            TaskEditorView(mode: .create) { title, tier, repeatsDaily, reminderTime in
                store.add(
                    title: title,
                    tier: tier,
                    repeatsDaily: repeatsDaily,
                    reminderTime: reminderTime
                )
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(mode: .edit(task)) { title, tier, repeatsDaily, reminderTime in
                store.edit(
                    id: task.id,
                    title: title,
                    tier: tier,
                    repeatsDaily: repeatsDaily,
                    reminderTime: reminderTime
                )
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("今日任务")
                    .font(.title2.weight(.semibold))
                if let counterText = dayCounterStore.configuration.displayText() {
                    Text(counterText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                showingNewTask = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("新增今日任务")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var taskList: some View {
        List {
            ForEach(QuestTier.allCases, id: \.self) { tier in
                let group = store.tasks.filter { $0.tier == tier }
                let pending = group.filter { $0.status == .pending }
                let settled = group.filter { $0.status != .pending }
                if !group.isEmpty {
                    Section(tier.displayName) {
                        ForEach(pending) { task in
                            TaskRow(
                                task: task,
                                toggle: { store.toggleCompletion(id: task.id) },
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
                                edit: { editingTask = task },
                                delete: { store.delete(id: task.id) }
                            )
                            .moveDisabled(true)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "moon.stars")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("今天还没有任务")
                .font(.headline)
            Text("今晚列好明日事项，明天直接开干。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: statusImage)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(task.status != .pending)
            .help(task.status == .pending ? "标记完成" : "任务已结算")

            Text(task.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .strikethrough(task.status == .completed)
                .foregroundStyle(task.status == .completed ? .secondary : .primary)
            if case .repeating = task.recurrence {
                Image(systemName: "repeat")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("每日重复")
            }
            if task.reminderTime != nil {
                Image(systemName: "bell")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("已设置提醒")
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    private var statusImage: String {
        switch task.status {
        case .pending: "circle"
        case .completed: "checkmark.circle.fill"
        case .pass: "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: .secondary
        case .completed: .green
        case .pass: .orange
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
    let mode: Mode
    let save: (String, QuestTier, Bool, TaskReminderTime?) -> Void

    init(
        mode: Mode,
        save: @escaping (String, QuestTier, Bool, TaskReminderTime?) -> Void
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
        save(normalizedTitle, tier, repeatsDaily, reminderTime)
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
