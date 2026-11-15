import Foundation

/// 任务与日期的关系判断，列表、悬浮面板与提醒共用。
public enum TaskDateState {
    public static func isOverdue(
        _ task: TodoTask,
        on date: Date,
        calendar: Calendar = TodoTask.protocolCalendar
    ) -> Bool {
        guard task.status == .pending, let end = task.endDate else { return false }
        return calendar.startOfDay(for: end) < calendar.startOfDay(for: date)
    }

    public static func isActive(
        _ task: TodoTask,
        on date: Date,
        calendar: Calendar = TodoTask.protocolCalendar
    ) -> Bool {
        guard let start = task.startDate, let end = task.endDate else { return false }
        let day = calendar.startOfDay(for: date)
        return calendar.startOfDay(for: start) <= day &&
            day <= calendar.startOfDay(for: end)
    }

    public static func isRelevant(
        _ task: TodoTask,
        on date: Date,
        calendar: Calendar = TodoTask.protocolCalendar
    ) -> Bool {
        if task.status != .pending { return false }
        if task.startDate == nil && task.endDate == nil { return true }
        return isOverdue(task, on: date, calendar: calendar) ||
            isActive(task, on: date, calendar: calendar)
    }

    public static func isSettled(
        _ task: TodoTask,
        on date: Date,
        calendar: Calendar = TodoTask.protocolCalendar
    ) -> Bool {
        guard task.status != .pending, let completedAt = task.completedAt else {
            return false
        }
        return calendar.isDate(completedAt, inSameDayAs: date)
    }
}
