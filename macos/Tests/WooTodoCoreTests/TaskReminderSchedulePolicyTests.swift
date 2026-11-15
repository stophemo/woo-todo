import Foundation
import Testing
@testable import WooTodoCore

struct TaskReminderSchedulePolicyTests {
    @Test func usesStartDateAndFixedWallClockTime() throws {
        let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        var calendar = TodoTask.protocolCalendar
        calendar.timeZone = timeZone
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 21
        )))
        let task = try TodoTask(
            title: "测试提醒",
            categoryID: "main",
            startDate: start,
            endDate: start,
            reminderTime: TaskReminderTime(hour: 23, minute: 10)
        )

        #expect(TaskReminderSchedulePolicy.fireDate(for: task, timeZone: timeZone) ==
            Date(timeIntervalSince1970: 1_784_646_600))
        #expect(TaskReminderSchedulePolicy.protocolTimeZone.identifier == "Asia/Shanghai")
        #expect(TaskReminderSchedulePolicy.fireDate(for: task) ==
            Date(timeIntervalSince1970: 1_784_646_600))
    }

    @Test func ignoresSettledOrUnconfiguredTasks() throws {
        let undated = try TodoTask(title: "无提醒", categoryID: "main")
        #expect(TaskReminderSchedulePolicy.fireDate(for: undated) == nil)

        let start = Date(timeIntervalSince1970: 1_784_630_400)
        let settled = try TodoTask(
            title: "已完成",
            categoryID: "main",
            status: .completed,
            startDate: start,
            endDate: start,
            reminderTime: TaskReminderTime(hour: 9, minute: 0),
            completedAt: start
        )
        #expect(TaskReminderSchedulePolicy.fireDate(for: settled) == nil)
    }
}
