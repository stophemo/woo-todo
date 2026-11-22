import Foundation
import Testing
@testable import WooTodoCore

@Suite("晚间任务提醒")
struct DailyDigestTests {
    @Test("汇总明天进行中、明天开始和已逾期的待办")
    func summarizesTomorrowTasks() throws {
        let today = date("2026-11-22")
        let tasks = [
            try TodoTask(
                title: "跨天项目",
                categoryID: "main",
                startDate: today,
                endDate: date("2026-11-24")
            ),
            try TodoTask(
                title: "明天开始",
                categoryID: "main",
                startDate: date("2026-11-23")
            ),
            try TodoTask(
                title: "已经逾期",
                categoryID: "main",
                startDate: date("2026-11-20")
            ),
            try TodoTask(
                title: "以后再说",
                categoryID: "main",
                startDate: date("2026-11-25")
            ),
            try TodoTask(title: "未安排", categoryID: "main"),
        ]

        let message = DailyDigestBuilder.message(tasks: tasks, on: today)

        #expect(message.title == "明天的任务")
        #expect(message.body == "明天有 3 项：已经逾期、跨天项目、明天开始")
    }

    @Test("每天重复任务会提前进入晚间汇总")
    func includesDailyRecurringSeries() throws {
        let today = date("2026-11-22")
        let task = try TodoTask(
            title: "铲屎",
            categoryID: "main",
            startDate: today,
            recurrence: .daily
        )

        let message = DailyDigestBuilder.message(tasks: [task], on: today)

        #expect(message.body == "明天有 1 项：铲屎")
    }

    @Test("明天没有任务时给出空闲提示")
    func reportsEmptyTomorrow() throws {
        let message = DailyDigestBuilder.message(
            tasks: [try TodoTask(title: "未安排", categoryID: "main")],
            on: date("2026-11-22")
        )

        #expect(message.body == "明天暂时没有安排任务。")
    }

    @Test("超过三条时只展示前三条")
    func limitsPreview() throws {
        let tomorrow = date("2026-11-23")
        let tasks = try (1...5).map { index in
            try TodoTask(
                title: "任务\(index)",
                categoryID: "main",
                startDate: tomorrow
            )
        }

        let message = DailyDigestBuilder.message(tasks: tasks, on: date("2026-11-22"))

        #expect(message.body == "明天有 5 项：任务1、任务2、任务3 等 5 项")
    }

    private func date(_ value: String) -> Date {
        TodoTask.protocolCalendar.date(from: DateComponents(
            year: Int(value.prefix(4)),
            month: Int(value.dropFirst(5).prefix(2)),
            day: Int(value.suffix(2))
        ))!
    }
}
