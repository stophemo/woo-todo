import Foundation

public struct DailyDigestConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var time: TaskReminderTime

    public init(enabled: Bool, time: TaskReminderTime) {
        self.enabled = enabled
        self.time = time
    }
}

public struct DailyDigestMessage: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// 晚间提醒：按选定时间汇总“明天要做”的待办，而不是逐条推送。
public enum DailyDigestBuilder {
    public static func message(
        tasks: [TodoTask],
        on referenceDate: Date,
        calendar: Calendar = TodoTask.protocolCalendar
    ) -> DailyDigestMessage {
        let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: referenceDate)
        ) ?? referenceDate
        var tasksForTomorrow = tasks
            .filter { task in
                guard task.status == .pending else { return false }
                return TaskDateState.isActive(task, on: tomorrow, calendar: calendar)
                    || TaskDateState.isOverdue(task, on: tomorrow, calendar: calendar)
            }
            .sorted { lhs, rhs in
                let left = lhs.startDate ?? .distantFuture
                let right = rhs.startDate ?? .distantFuture
                if left != right { return left < right }
                return TodoTask.displayOrder(lhs, rhs)
            }

        // 每天重复任务的下一条通常要等当天结算后才生成；晚间汇总提前补上它的明日占位。
        let todayStart = calendar.startOfDay(for: referenceDate)
        let representedSeries = Set(tasksForTomorrow.map(\.seriesID))
        var latestDailyBySeries: [UUID: TodoTask] = [:]
        for task in tasks where task.recurrence == .daily {
            guard let start = task.startDate,
                  calendar.startOfDay(for: start) <= todayStart else { continue }
            if let current = latestDailyBySeries[task.seriesID],
               let currentStart = current.startDate,
               currentStart >= start {
                continue
            }
            latestDailyBySeries[task.seriesID] = task
        }
        tasksForTomorrow.append(contentsOf: latestDailyBySeries.values
            .filter { !representedSeries.contains($0.seriesID) }
            .sorted(by: TodoTask.displayOrder))

        guard !tasksForTomorrow.isEmpty else {
            return DailyDigestMessage(
                title: "明天的任务",
                body: "明天暂时没有安排任务。"
            )
        }
        let titles = tasksForTomorrow.prefix(3).map(\.title).joined(separator: "、")
        let suffix = tasksForTomorrow.count > 3 ? " 等 \(tasksForTomorrow.count) 项" : ""
        return DailyDigestMessage(
            title: "明天的任务",
            body: "明天有 \(tasksForTomorrow.count) 项：\(titles)\(suffix)"
        )
    }
}
