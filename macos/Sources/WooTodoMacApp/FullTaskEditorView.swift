import SwiftUI
import WooTodoCore

struct FullTaskInput {
    let title: String
    let categoryID: String
    let startDate: Date?
    let endDate: Date?
    let reminderTime: TaskReminderTime?
}

enum FullTaskEditorMode {
    case create
    case edit(TodoTask)
}

struct FullTaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var categoryID: String
    @State private var dateRangeEnabled: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var reminderEnabled: Bool
    @State private var reminderDate: Date

    let mode: FullTaskEditorMode
    let categories: [TaskCategory]
    let save: (FullTaskInput) -> Void

    init(
        mode: FullTaskEditorMode,
        categories: [TaskCategory],
        save: @escaping (FullTaskInput) -> Void
    ) {
        self.mode = mode
        self.categories = categories.isEmpty ? TaskCategory.defaults : categories
        self.save = save
        let fallbackCategory = self.categories.first(where: { $0.id == TaskCategory.inboxID })?.id
            ?? self.categories.first?.id
            ?? TaskCategory.inboxID
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _categoryID = State(initialValue: fallbackCategory)
            _dateRangeEnabled = State(initialValue: false)
            _startDate = State(initialValue: Calendar.current.startOfDay(for: Date()))
            _endDate = State(initialValue: Calendar.current.startOfDay(for: Date()))
            _reminderEnabled = State(initialValue: false)
            _reminderDate = State(initialValue: Self.defaultReminderDate)
        case let .edit(task):
            _title = State(initialValue: task.title)
            _categoryID = State(initialValue: self.categories.contains(where: {
                $0.id == task.categoryID
            }) ? task.categoryID : fallbackCategory)
            _dateRangeEnabled = State(initialValue: task.startDate != nil && task.endDate != nil)
            _startDate = State(initialValue: task.startDate ?? Date())
            _endDate = State(initialValue: task.endDate ?? task.startDate ?? Date())
            _reminderEnabled = State(initialValue: task.reminderTime != nil)
            _reminderDate = State(initialValue: Self.date(for: task.reminderTime))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isEditing ? "编辑任务" : "新增任务")
                .font(.title2.weight(.semibold))

            TextField("一句话写下要做的事", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            VStack(alignment: .leading, spacing: 8) {
                Text("类型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories) { category in
                            Button {
                                categoryID = category.id
                            } label: {
                                Text(category.name)
                                    .font(.callout)
                                    .foregroundStyle(
                                        categoryID == category.id ? Color.white : Color.primary
                                    )
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        categoryID == category.id
                                            ? WooTodoTheme.purple
                                            : Color.secondary.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Toggle("设置时间范围", isOn: $dateRangeEnabled)

            if dateRangeEnabled {
                DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                DatePicker("结束日期", selection: $endDate, displayedComponents: .date)
                if startDate > endDate {
                    Text("开始日期不能晚于结束日期")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("在指定时间提醒", isOn: $reminderEnabled)
                if reminderEnabled {
                    DatePicker(
                        "提醒时间",
                        selection: $reminderDate,
                        displayedComponents: .hourAndMinute
                    )
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedTitle.isEmpty || (dateRangeEnabled && startDate > endDate))
            }
        }
        .padding(22)
        .frame(width: 430)
        .onChange(of: dateRangeEnabled) { _, enabled in
            if !enabled {
                reminderEnabled = false
            } else if startDate > endDate {
                endDate = startDate
            }
        }
        .onChange(of: startDate) { _, value in
            if endDate < value { endDate = value }
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
        if dateRangeEnabled && startDate > endDate { return }
        save(FullTaskInput(
            title: normalizedTitle,
            categoryID: categoryID,
            startDate: dateRangeEnabled ? startDate : nil,
            endDate: dateRangeEnabled ? endDate : nil,
            reminderTime: dateRangeEnabled && reminderEnabled ? selectedReminderTime : nil
        ))
        dismiss()
    }

    private var selectedReminderTime: TaskReminderTime? {
        let components = Calendar.current.dateComponents([.hour, .minute], from: reminderDate)
        return try? TaskReminderTime(
            hour: components.hour ?? 0,
            minute: components.minute ?? 0
        )
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
