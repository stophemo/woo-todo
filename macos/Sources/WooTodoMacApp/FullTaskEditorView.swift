import SwiftUI
import WooTodoCore

struct FullTaskInput {
    let title: String
    let categoryID: String
    let startDate: Date?
    let endDate: Date?
    let reminderTime: TaskReminderTime?
    let recurrence: TaskRecurrence
}

enum FullTaskEditorMode {
    case create
    case edit(TodoTask)
}

struct FullTaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var categoryName: String
    @State private var categoryError: String?
    @State private var dateRangeEnabled: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var reminderEnabled: Bool
    @State private var reminderDate: Date
    @State private var dailyRepeat: Bool
    @State private var localCategories: [TaskCategory]
    @State private var showingCategories = false

    let mode: FullTaskEditorMode
    let persistCategories: (([TaskCategory]) -> [TaskCategory])?
    let save: (FullTaskInput) -> Void

    init(
        mode: FullTaskEditorMode,
        categories: [TaskCategory],
        persistCategories: (([TaskCategory]) -> [TaskCategory])? = nil,
        save: @escaping (FullTaskInput) -> Void
    ) {
        self.mode = mode
        self.persistCategories = persistCategories
        self.save = save
        let resolvedCategories = categories.isEmpty ? TaskCategory.defaults : categories
        _localCategories = State(initialValue: resolvedCategories)
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _categoryName = State(initialValue: "")
            _dateRangeEnabled = State(initialValue: false)
            _startDate = State(initialValue: Calendar.current.startOfDay(for: Date()))
            _endDate = State(initialValue: Calendar.current.startOfDay(for: Date()))
            _reminderEnabled = State(initialValue: false)
            _reminderDate = State(initialValue: Self.defaultReminderDate)
            _dailyRepeat = State(initialValue: false)
        case let .edit(task):
            _title = State(initialValue: task.title)
            _categoryName = State(initialValue: resolvedCategories.first(where: {
                $0.id == task.categoryID && $0.id != TaskCategory.inboxID
            })?.name ?? "")
            _dateRangeEnabled = State(initialValue: task.startDate != nil && task.endDate != nil)
            _startDate = State(initialValue: task.startDate ?? Date())
            _endDate = State(initialValue: task.endDate ?? task.startDate ?? Date())
            _reminderEnabled = State(initialValue: task.reminderTime != nil)
            _reminderDate = State(initialValue: Self.date(for: task.reminderTime))
            _dailyRepeat = State(initialValue: task.recurrence == .daily)
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
                Text("标签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "可留空，输入新名称会自动创建",
                    text: $categoryName
                )
                .textFieldStyle(.roundedBorder)
                .onChange(of: categoryName) { _, _ in
                    categoryError = nil
                }
                if let categoryError {
                    Text(categoryError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if persistCategories != nil {
                    Button("管理标签") {
                        showingCategories = true
                    }
                    .font(.caption)
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
                Toggle("每天重复", isOn: $dailyRepeat)
                if dailyRepeat {
                    Text("每天生成一条新任务；前一天未完成会自动记为放弃。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .sheet(isPresented: $showingCategories) {
            TaskCategorySettingsView(categories: localCategories) { updated in
                let typedName = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                let previous = localCategories.first(where: {
                    $0.name.compare(
                        typedName,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
                })
                let result = persistCategories?(updated) ?? updated
                localCategories = result
                if let previous {
                    categoryName = result.first(where: { $0.id == previous.id })?.name ?? ""
                }
            }
        }
        .onChange(of: dateRangeEnabled) { _, enabled in
            if !enabled {
                reminderEnabled = false
                dailyRepeat = false
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
        guard let categoryID = resolvedCategoryID() else { return }
        save(FullTaskInput(
            title: normalizedTitle,
            categoryID: categoryID,
            startDate: dateRangeEnabled ? startDate : nil,
            endDate: dateRangeEnabled ? endDate : nil,
            reminderTime: dateRangeEnabled && reminderEnabled ? selectedReminderTime : nil,
            recurrence: dateRangeEnabled && dailyRepeat ? .daily : .once
        ))
        dismiss()
    }

    private func resolvedCategoryID() -> String? {
        do {
            switch try TaskCategory.resolveInput(categoryName, categories: localCategories) {
            case .none:
                return TaskCategory.inboxID
            case let .existing(category):
                return category.id
            case let .create(category):
                let updated = persistCategories?(localCategories + [category])
                    ?? TaskCategory.normalizeList(localCategories + [category])
                localCategories = updated
                guard updated.contains(where: { $0.id == category.id }) else {
                    categoryError = "无法创建标签"
                    return nil
                }
                return category.id
            }
        } catch {
            categoryError = error.localizedDescription
            return nil
        }
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
