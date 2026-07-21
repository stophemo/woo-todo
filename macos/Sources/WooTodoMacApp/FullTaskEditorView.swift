import SwiftUI
import WooTodoCore

struct FullTaskInput {
    let title: String
    let scope: TimeScope
    let targetDate: Date
    let tier: QuestTier
    let repeats: Bool
    let reminderTime: TaskReminderTime?
}

enum FullTaskEditorMode {
    case create(defaultScope: TimeScope, targetDate: Date)
    case edit(TodoTask)
}

struct FullTaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var scope: TimeScope
    @State private var targetDate: Date
    @State private var tier: QuestTier
    @State private var repeats: Bool
    @State private var reminderEnabled: Bool
    @State private var reminderDate: Date

    let mode: FullTaskEditorMode
    let save: (FullTaskInput) -> Void

    init(mode: FullTaskEditorMode, save: @escaping (FullTaskInput) -> Void) {
        self.mode = mode
        self.save = save
        switch mode {
        case let .create(defaultScope, targetDate):
            _title = State(initialValue: "")
            _scope = State(initialValue: defaultScope)
            _targetDate = State(initialValue: targetDate)
            _tier = State(initialValue: .mainline)
            _repeats = State(initialValue: false)
            _reminderEnabled = State(initialValue: false)
            _reminderDate = State(initialValue: Self.defaultReminderDate)
        case let .edit(task):
            _title = State(initialValue: task.title)
            _scope = State(initialValue: task.timeScope)
            _targetDate = State(initialValue: task.period?.start ?? task.createdAt)
            _tier = State(initialValue: task.tier)
            _reminderEnabled = State(initialValue: task.reminderTime != nil)
            _reminderDate = State(initialValue: Self.date(for: task.reminderTime))
            if case .repeating = task.recurrence {
                _repeats = State(initialValue: true)
            } else {
                _repeats = State(initialValue: false)
            }
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
                Text("时间范围")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("时间范围", selection: $scope) {
                    ForEach(TimeScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if scope != .anytime {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker(
                        targetDateLabel,
                        selection: $targetDate,
                        displayedComponents: .date
                    )
                    Text(targetPeriodDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(repeatLabel, isOn: $repeats)
                Toggle("在指定时间提醒", isOn: $reminderEnabled)
                if reminderEnabled {
                    DatePicker(
                        "提醒时间",
                        selection: $reminderDate,
                        displayedComponents: .hourAndMinute
                    )
                }
            } else {
                Text("闲时任务没有截止周期，也不会自动 Pass。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("任务级别")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("任务级别", selection: $tier) {
                    ForEach(QuestTier.allCases, id: \.self) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
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
        .padding(22)
        .frame(width: 430)
        .onChange(of: scope) { _, newScope in
            if newScope == .anytime {
                repeats = false
                reminderEnabled = false
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var targetDateLabel: String {
        switch scope {
        case .daily: "目标日期"
        case .weekly: "目标周内任意一天"
        case .monthly: "目标月内任意一天"
        case .anytime: ""
        }
    }

    private var repeatLabel: String {
        switch scope {
        case .daily: "每天重复"
        case .weekly: "每周重复"
        case .monthly: "每月重复"
        case .anytime: ""
        }
    }

    private var targetPeriodDescription: String {
        guard let period = PeriodEngine().period(containing: targetDate, for: scope) else {
            return ""
        }
        return "目标周期：\(TaskPeriodText.text(for: period, scope: scope))"
    }

    private func commit() {
        guard !normalizedTitle.isEmpty else { return }
        save(FullTaskInput(
            title: normalizedTitle,
            scope: scope,
            targetDate: targetDate,
            tier: tier,
            repeats: repeats && scope != .anytime,
            reminderTime: reminderEnabled && scope != .anytime ? selectedReminderTime : nil
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

enum TaskPeriodText {
    static func text(for task: TodoTask) -> String {
        guard let period = task.period else { return "闲时" }
        return text(for: period, scope: task.timeScope)
    }

    static func text(for period: TaskPeriod, scope: TimeScope) -> String {
        switch scope {
        case .daily:
            return period.start.formatted(.dateTime.year().month().day())
        case .weekly:
            let finalDay = period.end.addingTimeInterval(-1)
            return "\(period.start.formatted(.dateTime.month().day()))–\(finalDay.formatted(.dateTime.month().day()))"
        case .monthly:
            return period.start.formatted(.dateTime.year().month())
        case .anytime:
            return "闲时"
        }
    }
}
