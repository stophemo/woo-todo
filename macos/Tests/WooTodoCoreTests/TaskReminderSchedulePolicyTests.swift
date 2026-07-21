import Foundation
import Testing
@testable import WooTodoCore

struct TaskReminderSchedulePolicyTests {
    @Test func usesTaskPeriodDateAndFixedWallClockTime() throws {
        let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let periodStart = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 21
        )))
        let task = try TodoTask(
            title: "测试提醒",
            timeScope: .daily,
            tier: .mainline,
            period: TaskPeriod(
                start: periodStart,
                end: try #require(calendar.date(byAdding: .day, value: 1, to: periodStart))
            ),
            reminderTime: TaskReminderTime(hour: 23, minute: 10)
        )

        #expect(TaskReminderSchedulePolicy.fireDate(for: task, timeZone: timeZone) ==
            Date(timeIntervalSince1970: 1_784_646_600))
        #expect(TaskReminderSchedulePolicy.protocolTimeZone.identifier == "Asia/Shanghai")
        #expect(TaskReminderSchedulePolicy.fireDate(for: task) ==
            Date(timeIntervalSince1970: 1_784_646_600))
    }

    @Test func ignoresSettledOrUnconfiguredTasks() throws {
        let task = try TodoTask(
            title: "无提醒",
            timeScope: .anytime,
            tier: .mainline,
            period: nil
        )
        #expect(TaskReminderSchedulePolicy.fireDate(for: task) == nil)
    }
}
