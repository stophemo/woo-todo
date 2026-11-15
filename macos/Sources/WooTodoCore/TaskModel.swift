import Foundation

/// 任务类型（分类）。order 越小越靠前。
public struct TaskCategory: Identifiable, Codable, Equatable, Hashable, Sendable {
    public static let inboxID = "inbox"
    public static let maximumCount = 8
    public static let maximumNameLength = 12

    private static let idPattern = "^[a-z0-9][a-z0-9_-]{0,31}$"
    private static let customIDCharacters = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public let id: String
    public var name: String
    public var order: Int

    public static let defaults: [TaskCategory] = [
        try! TaskCategory(id: inboxID, name: "未分类", order: 0),
        try! TaskCategory(id: "main", name: "主线", order: 1),
        try! TaskCategory(id: "side", name: "支线", order: 2),
        try! TaskCategory(id: "extra", name: "外传", order: 3),
    ]

    public init(id: String, name: String, order: Int) throws {
        guard Self.isValidID(id) else { throw TaskValidationError.invalidCategory }
        let normalizedName = try Self.normalizeName(name)
        guard (0...63).contains(order) else { throw TaskValidationError.invalidCategory }
        self.id = id
        self.name = normalizedName
        self.order = order
    }

    public static func isValidID(_ value: String) -> Bool {
        value.range(of: idPattern, options: .regularExpression) != nil
    }

    public static func normalizeName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.unicodeScalars.count <= maximumNameLength,
              !normalized.contains(where: { $0.isNewline }) else {
            throw TaskValidationError.invalidCategory
        }
        return normalized
    }

    /// 补齐 inbox、去重、按当前顺序重排 order，并限制最多 8 个。
    public static func normalizeList(_ input: [TaskCategory]) -> [TaskCategory] {
        var inbox: TaskCategory?
        var seenIds = Set<String>()
        var seenNames = Set<String>()
        var values: [TaskCategory] = []
        for category in input {
            guard let name = try? normalizeName(category.name),
                  isValidID(category.id),
                  seenIds.insert(category.id).inserted,
                  seenNames.insert(name).inserted else {
                continue
            }
            let normalized = try? TaskCategory(id: category.id, name: name, order: 0)
            guard let normalized else { continue }
            if category.id == inboxID {
                inbox = normalized
            } else {
                values.append(normalized)
            }
        }
        let inboxValue = inbox ?? (try! TaskCategory(id: inboxID, name: "未分类", order: 0))
        values.insert(inboxValue, at: 0)
        return values.prefix(maximumCount).enumerated().map { index, category in
            try! TaskCategory(id: category.id, name: category.name, order: index)
        }
    }

    public static func newID(existing: Set<String>) -> String {
        for _ in 0..<64 {
            let suffix = String((0..<7).map { _ in customIDCharacters.randomElement()! })
            let candidate = "c\(suffix)"
            if !existing.contains(candidate) { return candidate }
        }
        preconditionFailure("无法生成唯一分类 ID")
    }

    public static func resolveName(id: String, categories: [TaskCategory]) -> String {
        categories.first(where: { $0.id == id })?.name
            ?? defaults.first(where: { $0.id == id })?.name
            ?? "未分类"
    }
}

/// Pass 是放弃后的最终状态，会进入历史；不再自动产生。
public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case completed
    case pass

    public var displayName: String {
        switch self {
        case .pending: "待完成"
        case .completed: "已完成"
        case .pass: "已放弃"
        }
    }
}

public enum TaskValidationError: LocalizedError, Equatable {
    case emptyTitle
    case titleTooLong
    case invalidDates
    case invalidCategory
    case invalidReminderTime
    case invalidState

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "任务内容不能为空"
        case .titleTooLong: "任务内容不能超过 120 个 Unicode 字符"
        case .invalidDates: "开始日期和结束日期必须同时设置或同时为空，且开始不能晚于结束"
        case .invalidCategory: "任务类型无效：名称需为 1–12 个字符，标识需为 1–32 位小写字母、数字、下划线或连字符"
        case .invalidReminderTime: "提醒时间必须是 00:00 到 23:59，且任务需要有日期"
        case .invalidState: "任务状态与结算时间组合无效"
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

/// 一条任务。日期范围同时为空表示“未安排”，否则必须同时有开始和结束日期。
public struct TodoTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let seriesID: UUID
    public var title: String
    public var categoryID: String
    public var status: TaskStatus
    public var startDate: Date?
    public var endDate: Date?
    public var sortIndex: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var reminderTime: TaskReminderTime?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        seriesID: UUID? = nil,
        title: String,
        categoryID: String,
        status: TaskStatus = .pending,
        startDate: Date? = nil,
        endDate: Date? = nil,
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
        guard TaskCategory.isValidID(categoryID) else {
            throw TaskValidationError.invalidCategory
        }
        guard (startDate == nil) == (endDate == nil) else {
            throw TaskValidationError.invalidDates
        }
        let calendar = Self.protocolCalendar
        let normalizedStart = startDate.map { calendar.startOfDay(for: $0) }
        let normalizedEnd = endDate.map { calendar.startOfDay(for: $0) }
        if let start = normalizedStart, let end = normalizedEnd, start > end {
            throw TaskValidationError.invalidDates
        }
        if reminderTime != nil, normalizedStart == nil {
            throw TaskValidationError.invalidReminderTime
        }
        if status == .pending {
            guard completedAt == nil else { throw TaskValidationError.invalidState }
        } else {
            guard completedAt != nil else { throw TaskValidationError.invalidState }
        }

        self.id = id
        self.seriesID = seriesID ?? id
        self.title = normalizedTitle
        self.categoryID = categoryID
        self.status = status
        self.startDate = normalizedStart
        self.endDate = normalizedEnd
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.reminderTime = normalizedStart == nil ? nil : reminderTime
        self.completedAt = completedAt
    }

    public static func displayOrder(_ lhs: TodoTask, _ rhs: TodoTask) -> Bool {
        if lhs.status != rhs.status {
            return lhs.status == .pending
        }
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }
        return lhs.createdAt < rhs.createdAt
    }

    public static var protocolCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}
