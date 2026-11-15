import Foundation

public struct DayActivity: Identifiable, Equatable, Sendable {
    public let date: Date
    public let completed: Int

    public var id: Date { date }

    public init(date: Date, completed: Int) {
        self.date = date
        self.completed = completed
    }
}

public struct CategoryActivity: Equatable, Sendable {
    public let categoryID: String
    public let completed: Int
    public let ratio: Double

    public init(categoryID: String, completed: Int, ratio: Double) {
        self.categoryID = categoryID
        self.completed = completed
        self.ratio = ratio
    }
}

public struct StatisticsSnapshot: Equatable, Sendable {
    public let completedThisWeek: Int
    public let currentStreakDays: Int
    public let onTimeRate: Double?
    public let pendingCount: Int
    public let dailyActivity: [DayActivity]
    public let categoryActivity: [CategoryActivity]
    public let recentHistory: [TodoTask]

    public init(
        completedThisWeek: Int = 0,
        currentStreakDays: Int = 0,
        onTimeRate: Double? = nil,
        pendingCount: Int = 0,
        dailyActivity: [DayActivity] = [],
        categoryActivity: [CategoryActivity] = [],
        recentHistory: [TodoTask] = []
    ) {
        self.completedThisWeek = completedThisWeek
        self.currentStreakDays = currentStreakDays
        self.onTimeRate = onTimeRate
        self.pendingCount = pendingCount
        self.dailyActivity = dailyActivity
        self.categoryActivity = categoryActivity
        self.recentHistory = recentHistory
    }

    public static let empty = StatisticsSnapshot()
}

/// 只读取任务实例计算统计，不依赖仓储、UI 或当前线程。
public struct StatisticsEngine: Sendable {
    private let calendar: Calendar

    public init(timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar
    }

    public init(calendar: Calendar) {
        var normalized = calendar
        normalized.firstWeekday = 2
        normalized.minimumDaysInFirstWeek = 4
        self.calendar = normalized
    }

    public func calculate(
        tasks: [TodoTask],
        at now: Date,
        historyLimit: Int = Int.max
    ) -> StatisticsSnapshot {
        let today = calendar.startOfDay(for: now)
        let completions = tasks.compactMap { task -> (TodoTask, Date)? in
            guard task.status == .completed, let completedAt = task.completedAt else {
                return nil
            }
            return (task, calendar.startOfDay(for: completedAt))
        }
        let completedTasks = completions.map(\.0)
        let completionDates = Dictionary(
            uniqueKeysWithValues: completions.map { ($0.0.id, $0.1) }
        )

        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let completedThisWeek = completions.filter { _, date in
            date >= calendar.startOfDay(for: weekStart) && date <= today
        }.count

        let completedDays = Set(completions.map(\.1))
        let streak = currentStreak(completedDays, today: today)

        let onTimeTasks = completedTasks.filter { $0.endDate != nil }
        let onTimeRate: Double?
        if onTimeTasks.isEmpty {
            onTimeRate = nil
        } else {
            let onTime = onTimeTasks.filter { task in
                guard let end = task.endDate,
                      let date = completionDates[task.id] else { return false }
                return date <= calendar.startOfDay(for: end)
            }.count
            onTimeRate = Double(onTime) / Double(onTimeTasks.count)
        }

        let dailyActivity = (0...13).reversed().compactMap { offset -> DayActivity? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return DayActivity(
                date: date,
                completed: completions.filter { $0.1 == date }.count
            )
        }

        let categoryStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let recentCompleted = completions.filter { _, date in
            date >= categoryStart && date <= today
        }
        let categoryCounts = Dictionary(grouping: recentCompleted, by: { $0.0.categoryID })
            .mapValues(\.count)
        let totalRecent = recentCompleted.count
        let categoryActivity = categoryCounts.map { categoryID, count in
            CategoryActivity(
                categoryID: categoryID,
                completed: count,
                ratio: totalRecent == 0 ? 0 : Double(count) / Double(totalRecent)
            )
        }
        .sorted {
            if $0.completed != $1.completed { return $0.completed > $1.completed }
            return $0.categoryID < $1.categoryID
        }

        let history = tasks
            .filter { $0.status != .pending && $0.completedAt != nil }
            .sorted { lhs, rhs in
                let lhsDate = lhs.completedAt ?? lhs.updatedAt
                let rhsDate = rhs.completedAt ?? rhs.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(max(0, historyLimit))

        return StatisticsSnapshot(
            completedThisWeek: completedThisWeek,
            currentStreakDays: streak,
            onTimeRate: onTimeRate,
            pendingCount: tasks.filter { $0.status == .pending }.count,
            dailyActivity: dailyActivity,
            categoryActivity: categoryActivity,
            recentHistory: Array(history)
        )
    }

    private func currentStreak(_ days: Set<Date>, today: Date) -> Int {
        let start: Date
        if days.contains(today) {
            start = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  days.contains(yesterday) {
            start = yesterday
        } else {
            return 0
        }
        var cursor = start
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return count
    }
}
