import Foundation

public enum TaskReminderSchedulePolicy {
    public static let protocolTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    public static func fireDate(
        for task: TodoTask,
        timeZone: TimeZone = protocolTimeZone
    ) -> Date? {
        guard task.status == .pending,
              let period = task.period,
              let reminderTime = task.reminderTime else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: period.start)
        components.timeZone = timeZone
        components.hour = reminderTime.hour
        components.minute = reminderTime.minute
        components.second = 0
        return calendar.date(from: components)
    }
}
