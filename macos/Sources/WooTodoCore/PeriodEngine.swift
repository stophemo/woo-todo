import Foundation

public struct SettlementResult: Equatable, Sendable {
    public let tasks: [TodoTask]
    public let changedTaskIDs: Set<UUID>
    public let generatedTaskIDs: Set<UUID>

    public init(
        tasks: [TodoTask],
        changedTaskIDs: Set<UUID>,
        generatedTaskIDs: Set<UUID>
    ) {
        self.tasks = tasks
        self.changedTaskIDs = changedTaskIDs
        self.generatedTaskIDs = generatedTaskIDs
    }
}

/// 统一处理周期边界，避免把“是否跨日”分散到 UI 和后台任务中。
public struct PeriodEngine: Sendable {
    public var calendar: Calendar

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

    public func period(containing date: Date, for scope: TimeScope) -> TaskPeriod? {
        switch scope {
        case .daily:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return TaskPeriod(start: start, end: end)
        case .weekly:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
                return nil
            }
            return TaskPeriod(start: interval.start, end: interval.end)
        case .monthly:
            guard let interval = calendar.dateInterval(of: .month, for: date) else {
                return nil
            }
            return TaskPeriod(start: interval.start, end: interval.end)
        case .anytime:
            return nil
        }
    }

    /// 惰性结算所有已过期实例，并为重复规则补齐遗漏实例直到当前周期。
    public func settle(
        _ input: [TodoTask],
        at now: Date,
        reservedTaskIDs: Set<UUID> = []
    ) -> SettlementResult {
        var tasksByID = Dictionary(uniqueKeysWithValues: input.map { ($0.id, $0) })
        var occurrenceKeys = Set(input.compactMap(Self.occurrenceKey))
        var queue = input.sorted { ($0.period?.start ?? .distantFuture) < ($1.period?.start ?? .distantFuture) }
        var cursor = 0
        var changed = Set<UUID>()
        var generated = Set<UUID>()

        while cursor < queue.count {
            var task = queue[cursor]
            cursor += 1

            guard let period = task.period, period.end <= now else { continue }

            if task.status == .pending {
                task.status = .pass
                task.completedAt = now
                task.updatedAt = now
                tasksByID[task.id] = task
                changed.insert(task.id)
            }

            guard case let .repeating(rule) = task.recurrence,
                  let nextPeriod = nextPeriod(after: period, rule: rule) else {
                continue
            }

            let key = OccurrenceKey(
                seriesID: task.seriesID,
                scope: task.timeScope,
                periodStart: nextPeriod.start
            )
            guard !occurrenceKeys.contains(key) else { continue }

            let nextTask: TodoTask
            do {
                let occurrenceID = OccurrenceIDGenerator.makeID(
                    seriesID: task.seriesID,
                    scope: task.timeScope,
                    periodStart: nextPeriod.start,
                    timeZone: calendar.timeZone
                )
                // 实例被改到其他周期后仍会保留原 ID。此时旧重复规则再次推导出
                // 相同确定性 ID，必须保留用户编辑后的任务，不能静默覆盖。
                guard tasksByID[occurrenceID] == nil,
                      !reservedTaskIDs.contains(occurrenceID) else { continue }
                nextTask = try TodoTask(
                    id: occurrenceID,
                    seriesID: task.seriesID,
                    title: task.title,
                    timeScope: task.timeScope,
                    tier: task.tier,
                    recurrence: task.recurrence,
                    period: nextPeriod,
                    sortIndex: task.sortIndex,
                    createdAt: now,
                    reminderTime: task.reminderTime
                )
            } catch {
                assertionFailure("生成重复任务失败：\(error.localizedDescription)")
                continue
            }

            occurrenceKeys.insert(key)
            tasksByID[nextTask.id] = nextTask
            queue.append(nextTask)
            generated.insert(nextTask.id)
        }

        return SettlementResult(
            tasks: tasksByID.values.sorted(by: TodoTask.displayOrder),
            changedTaskIDs: changed,
            generatedTaskIDs: generated
        )
    }

    private func nextPeriod(after period: TaskPeriod, rule: RepeatRule) -> TaskPeriod? {
        let component: Calendar.Component
        switch rule.frequency {
        case .daily: component = .day
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        case .anytime: return nil
        }

        guard let nextDate = calendar.date(
            byAdding: component,
            value: rule.interval,
            to: period.start
        ) else {
            return nil
        }
        return self.period(containing: nextDate, for: rule.frequency)
    }

    private struct OccurrenceKey: Hashable {
        let seriesID: UUID
        let scope: TimeScope
        let periodStart: Date
    }

    private static func occurrenceKey(for task: TodoTask) -> OccurrenceKey? {
        guard let period = task.period else { return nil }
        return OccurrenceKey(
            seriesID: task.seriesID,
            scope: task.timeScope,
            periodStart: period.start
        )
    }
}
