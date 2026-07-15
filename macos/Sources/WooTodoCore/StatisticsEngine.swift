import Foundation

public struct AdherenceMetric: Equatable, Sendable {
    public let completed: Int
    public let pass: Int

    public init(completed: Int = 0, pass: Int = 0) {
        self.completed = completed
        self.pass = pass
    }

    public var total: Int { completed + pass }

    /// 没有已结束样本时返回 nil，避免把“暂无数据”误写成 0%。
    public var rate: Double? {
        guard total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
}

public struct StatusCounts: Equatable, Sendable {
    public private(set) var pending: Int
    public private(set) var completed: Int
    public private(set) var pass: Int

    public init(pending: Int = 0, completed: Int = 0, pass: Int = 0) {
        self.pending = pending
        self.completed = completed
        self.pass = pass
    }

    public var total: Int { pending + completed + pass }

    public mutating func record(_ status: TaskStatus) {
        switch status {
        case .pending: pending += 1
        case .completed: completed += 1
        case .pass: pass += 1
        }
    }
}

public struct TrendBucket: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let completed: Int
    public let pass: Int
    public let isEnded: Bool

    public init(
        start: Date,
        end: Date,
        completed: Int = 0,
        pass: Int = 0,
        isEnded: Bool
    ) {
        self.start = start
        self.end = end
        self.completed = completed
        self.pass = pass
        self.isEnded = isEnded
    }

    /// 样本数与履约率分母保持一致，不把异常未结算的待办记录算进去。
    public var sampleCount: Int { completed + pass }

    /// 当前周期仍可能新增任务或产生 Pass，因此只为已结束桶计算履约率。
    public var rate: Double? {
        guard isEnded, sampleCount > 0 else { return nil }
        return Double(completed) / Double(sampleCount)
    }
}

public struct StatisticsSnapshot: Equatable, Sendable {
    public let endedPeriods: AdherenceMetric
    public let mainlineEndedPeriods: AdherenceMetric
    public let countsByScope: [TimeScope: StatusCounts]
    public let countsByTier: [QuestTier: StatusCounts]
    public let dailyTrend: [TrendBucket]
    public let weeklyTrend: [TrendBucket]
    public let monthlyTrend: [TrendBucket]
    public let recentHistory: [TodoTask]

    public init(
        endedPeriods: AdherenceMetric,
        mainlineEndedPeriods: AdherenceMetric,
        countsByScope: [TimeScope: StatusCounts],
        countsByTier: [QuestTier: StatusCounts],
        dailyTrend: [TrendBucket],
        weeklyTrend: [TrendBucket],
        monthlyTrend: [TrendBucket],
        recentHistory: [TodoTask]
    ) {
        self.endedPeriods = endedPeriods
        self.mainlineEndedPeriods = mainlineEndedPeriods
        self.countsByScope = countsByScope
        self.countsByTier = countsByTier
        self.dailyTrend = dailyTrend
        self.weeklyTrend = weeklyTrend
        self.monthlyTrend = monthlyTrend
        self.recentHistory = recentHistory
    }

    public static let empty = StatisticsSnapshot(
        endedPeriods: AdherenceMetric(),
        mainlineEndedPeriods: AdherenceMetric(),
        countsByScope: [:],
        countsByTier: [:],
        dailyTrend: [],
        weeklyTrend: [],
        monthlyTrend: [],
        recentHistory: []
    )
}

/// 只读取任务实例计算统计，不依赖仓储、UI 或当前线程。
public struct StatisticsEngine: Sendable {
    private let periodEngine: PeriodEngine

    public init(timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) {
        periodEngine = PeriodEngine(timeZone: timeZone)
    }

    public init(calendar: Calendar) {
        periodEngine = PeriodEngine(calendar: calendar)
    }

    public func calculate(
        tasks: [TodoTask],
        at now: Date,
        historyLimit: Int = 30
    ) -> StatisticsSnapshot {
        let endedOutcomes = tasks.filter { task in
            guard let period = task.period, period.end <= now else { return false }
            return task.status == .completed || task.status == .pass
        }
        let mainlineOutcomes = endedOutcomes.filter { $0.tier == .mainline }

        var countsByScope: [TimeScope: StatusCounts] = [:]
        var countsByTier: [QuestTier: StatusCounts] = [:]
        for task in tasks {
            countsByScope[task.timeScope, default: StatusCounts()].record(task.status)
            countsByTier[task.tier, default: StatusCounts()].record(task.status)
        }

        let history = tasks
            .filter { $0.status == .completed || $0.status == .pass }
            .sorted(by: historyOrder)

        return StatisticsSnapshot(
            endedPeriods: metric(for: endedOutcomes),
            mainlineEndedPeriods: metric(for: mainlineOutcomes),
            countsByScope: countsByScope,
            countsByTier: countsByTier,
            dailyTrend: trend(tasks: tasks, scope: .daily, bucketCount: 7, at: now),
            weeklyTrend: trend(tasks: tasks, scope: .weekly, bucketCount: 8, at: now),
            monthlyTrend: trend(tasks: tasks, scope: .monthly, bucketCount: 6, at: now),
            recentHistory: Array(history.prefix(max(0, historyLimit)))
        )
    }

    private func trend(
        tasks: [TodoTask],
        scope: TimeScope,
        bucketCount: Int,
        at now: Date
    ) -> [TrendBucket] {
        guard bucketCount > 0,
              let currentPeriod = periodEngine.period(containing: now, for: scope),
              let component = calendarComponent(for: scope) else {
            return []
        }

        var outcomesByStart: [Date: StatusCounts] = [:]
        for task in tasks where task.timeScope == scope {
            guard task.status == .completed || task.status == .pass,
                  let taskPeriod = task.period,
                  let normalizedPeriod = periodEngine.period(
                      containing: taskPeriod.start,
                      for: scope
                  ) else {
                continue
            }
            outcomesByStart[normalizedPeriod.start, default: StatusCounts()].record(task.status)
        }

        return (0..<bucketCount).reversed().compactMap { offset in
            guard let bucketDate = periodEngine.calendar.date(
                byAdding: component,
                value: -offset,
                to: currentPeriod.start
            ),
            let period = periodEngine.period(containing: bucketDate, for: scope) else {
                return nil
            }
            let counts = outcomesByStart[period.start] ?? StatusCounts()
            return TrendBucket(
                start: period.start,
                end: period.end,
                completed: counts.completed,
                pass: counts.pass,
                isEnded: period.end <= now
            )
        }
    }

    private func calendarComponent(for scope: TimeScope) -> Calendar.Component? {
        switch scope {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        case .anytime: nil
        }
    }

    private func metric(for tasks: [TodoTask]) -> AdherenceMetric {
        AdherenceMetric(
            completed: tasks.filter { $0.status == .completed }.count,
            pass: tasks.filter { $0.status == .pass }.count
        )
    }

    private func historyOrder(_ lhs: TodoTask, _ rhs: TodoTask) -> Bool {
        let lhsDate = lhs.completedAt ?? lhs.period?.end ?? lhs.updatedAt
        let rhsDate = rhs.completedAt ?? rhs.period?.end ?? rhs.updatedAt
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
