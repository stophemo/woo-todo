import Foundation

/// 任务所属的时间维度。
public enum TimeScope: String, Codable, CaseIterable, Sendable {
    case daily = "day"
    case weekly = "week"
    case monthly = "month"
    case anytime = "someday"

    public var displayName: String {
        switch self {
        case .daily: "每日"
        case .weekly: "每周"
        case .monthly: "每月"
        case .anytime: "闲时"
        }
    }
}

/// 游戏化任务级别，同时决定默认展示优先级。
public enum QuestTier: String, Codable, CaseIterable, Sendable {
    case mainline = "main"
    case side
    case extra

    public var displayName: String {
        switch self {
        case .mainline: "主线"
        case .side: "支线"
        case .extra: "外传"
        }
    }

    public var priority: Int {
        switch self {
        case .mainline: 0
        case .side: 1
        case .extra: 2
        }
    }
}

/// Pass 是到期未完成的最终状态，会进入履约统计。
public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case completed
    case pass

    public var displayName: String {
        switch self {
        case .pending: "待完成"
        case .completed: "已完成"
        case .pass: "Pass"
        }
    }
}

public struct RepeatRule: Codable, Equatable, Sendable {
    public let frequency: TimeScope
    public let interval: Int

    public init(frequency: TimeScope, interval: Int = 1) {
        self.frequency = frequency
        self.interval = max(1, interval)
    }
}

public enum RecurrenceRule: Codable, Equatable, Sendable {
    case once
    case repeating(RepeatRule)
}

/// 左闭右开的周期区间，例如一天为 [今日 00:00, 明日 00:00)。
public struct TaskPeriod: Codable, Equatable, Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        precondition(start < end, "任务周期的开始时间必须早于结束时间")
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }
}

public enum TaskValidationError: LocalizedError, Equatable {
    case emptyTitle
    case titleTooLong
    case missingPeriod
    case unexpectedPeriod
    case invalidRecurrence
    case invalidReminderTime

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "任务内容不能为空"
        case .titleTooLong: "任务内容不能超过 120 个 Unicode 字符"
        case .missingPeriod: "每日、每周和每月任务必须指定周期"
        case .unexpectedPeriod: "闲时任务不能指定周期"
        case .invalidRecurrence: "重复频率必须与时间维度一致；v1 仅支持每周期一次，闲时任务不能重复"
        case .invalidReminderTime: "提醒时间必须是 00:00 到 23:59"
        }
    }
}

public struct TaskReminderTime: Codable, Equatable, Hashable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw TaskValidationError.invalidReminderTime
        }
        self.hour = hour
        self.minute = minute
    }

    public init?(wireValue: String) {
        guard wireValue.range(
            of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"#,
            options: .regularExpression
        ) != nil else { return nil }
        let values = wireValue.split(separator: ":").compactMap { Int($0) }
        guard values.count == 2,
              let value = try? TaskReminderTime(hour: values[0], minute: values[1]) else {
            return nil
        }
        self = value
    }

    public var wireValue: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// 一条任务代表某个周期中的一次履约机会；重复任务通过 seriesID 串联。
public struct TodoTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let seriesID: UUID
    public var title: String
    public var timeScope: TimeScope
    public var tier: QuestTier
    public var status: TaskStatus
    public var recurrence: RecurrenceRule
    public var period: TaskPeriod?
    public var sortIndex: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var reminderTime: TaskReminderTime?
    /// completed 与 Pass 共用的结算时间；沿用字段名以兼容现有本地数据库。
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        seriesID: UUID? = nil,
        title: String,
        timeScope: TimeScope,
        tier: QuestTier,
        status: TaskStatus = .pending,
        recurrence: RecurrenceRule = .once,
        period: TaskPeriod?,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        reminderTime: TaskReminderTime? = nil,
        completedAt: Date? = nil
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw TaskValidationError.emptyTitle }
        guard normalizedTitle.unicodeScalars.count <= 120 else {
            throw TaskValidationError.titleTooLong
        }
        guard (timeScope == .anytime) == (period == nil) else {
            throw timeScope == .anytime
                ? TaskValidationError.unexpectedPeriod
                : TaskValidationError.missingPeriod
        }
        if case let .repeating(rule) = recurrence,
           rule.frequency == .anytime || rule.frequency != timeScope || rule.interval != 1 {
            throw TaskValidationError.invalidRecurrence
        }

        self.id = id
        self.seriesID = seriesID ?? id
        self.title = normalizedTitle
        self.timeScope = timeScope
        self.tier = tier
        self.status = status
        self.recurrence = recurrence
        self.period = period
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.reminderTime = timeScope == .anytime ? nil : reminderTime
        self.completedAt = completedAt
    }

    public static func displayOrder(_ lhs: TodoTask, _ rhs: TodoTask) -> Bool {
        if lhs.tier.priority != rhs.tier.priority {
            return lhs.tier.priority < rhs.tier.priority
        }
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }
        return lhs.createdAt < rhs.createdAt
    }
}
