import Foundation
import Testing
@testable import WooTodoCore

@Suite("本地完成统计")
struct StatisticsEngineTests {
    private let referenceDate = date("2026-07-15")
    private let engine = StatisticsEngine(timeZone: TimeZone(identifier: "Asia/Shanghai")!)

    @Test("本周完成只统计本周一之后的任务")
    func completedThisWeek() throws {
        let tasks = try [
            completed("last-week", date("2026-07-08")),
            completed("monday", date("2026-07-13")),
            completed("today", referenceDate),
            passed("ignored", referenceDate),
        ]

        let snapshot = engine.calculate(tasks: tasks, at: referenceDate)

        #expect(snapshot.completedThisWeek == 2)
    }

    @Test("连续天数从今天或昨天开始回溯")
    func currentStreak() throws {
        let withToday = try [
            completed("today", referenceDate),
            completed("yesterday", date("2026-07-14")),
            completed("two-days", date("2026-07-13")),
            completed("gap", date("2026-07-11")),
        ]
        #expect(engine.calculate(tasks: withToday, at: referenceDate).currentStreakDays == 3)

        let withoutToday = try [
            completed("yesterday", date("2026-07-14")),
            completed("two-days", date("2026-07-13")),
        ]
        #expect(engine.calculate(tasks: withoutToday, at: referenceDate).currentStreakDays == 2)

        let none = try [completed("older", date("2026-07-12"))]
        #expect(engine.calculate(tasks: none, at: referenceDate).currentStreakDays == 0)
    }

    @Test("按时率只统计有截止日期的已完成任务")
    func onTimeRate() throws {
        let tasks = try [
            task("on-time", status: .completed, start: "2026-07-10", end: "2026-07-15", completed: "2026-07-14"),
            task("same-day", status: .completed, start: "2026-07-15", end: "2026-07-15", completed: "2026-07-15"),
            task("late", status: .completed, start: "2026-07-01", end: "2026-07-10", completed: "2026-07-12"),
            task("no-end", status: .completed, start: nil, end: nil, completed: "2026-07-11"),
            task("pass", status: .pass, start: "2026-07-01", end: "2026-07-31", completed: "2026-07-11"),
        ]

        let snapshot = engine.calculate(tasks: tasks, at: referenceDate)
        #expect(abs((snapshot.onTimeRate ?? 0) - 2.0 / 3.0) < 0.0001)
        #expect(
            engine.calculate(
                tasks: [try task("pending", status: .pending, start: nil, end: nil, completed: nil)],
                at: referenceDate
            ).onTimeRate == nil
        )
    }

    @Test("十四天趋势包含今天和窗口外排除")
    func dailyActivity() throws {
        let tasks = try [
            completed("outside", date("2026-07-01")),
            completed("first", date("2026-07-02")),
            completed("today", referenceDate),
        ]

        let activity = engine.calculate(tasks: tasks, at: referenceDate).dailyActivity

        #expect(activity.count == 14)
        #expect(activity.first?.date == date("2026-07-02"))
        #expect(activity.last?.date == referenceDate)
        #expect(activity.first?.completed == 1)
        #expect(activity.last?.completed == 1)
        #expect(activity.map(\.completed).reduce(0, +) == 2)
    }

    @Test("近三十天分类分布按完成数排序")
    func categoryActivity() throws {
        let tasks = try [
            completed("work-1", date("2026-07-14"), categoryID: "work"),
            completed("work-2", referenceDate, categoryID: "work"),
            completed("life", date("2026-07-13"), categoryID: "life"),
            completed("outside", date("2026-06-15"), categoryID: "life"),
        ]

        let categories = engine.calculate(tasks: tasks, at: referenceDate).categoryActivity

        #expect(categories.map(\.categoryID) == ["work", "life"])
        #expect(categories.first?.completed == 2)
        #expect(abs((categories.first?.ratio ?? 0) - 2.0 / 3.0) < 0.0001)
    }

    @Test("历史按结算时间倒序且包含放弃")
    func recentHistory() throws {
        let tasks = try [
            completed("old", date("2026-07-13")),
            passed("new", referenceDate),
            try task("pending", status: .pending, start: nil, end: nil, completed: nil),
        ]

        let history = engine.calculate(tasks: tasks, at: referenceDate).recentHistory
        #expect(history.map(\.title) == ["new", "old"])
    }

    @Test("上海零点边界按本地日期计算")
    func shanghaiMidnightBoundary() throws {
        let boundary = ISO8601DateFormatter().date(from: "2026-07-15T16:00:00Z")!
        let task = try task(
            "boundary",
            status: .completed,
            start: "2026-07-16",
            end: "2026-07-16",
            completedAt: boundary
        )

        let snapshot = engine.calculate(tasks: [task], at: date("2026-07-16"))
        #expect(snapshot.dailyActivity.last?.completed == 1)
        #expect(snapshot.currentStreakDays == 1)
    }

    private func completed(
        _ title: String,
        _ date: Date,
        categoryID: String = TaskCategory.inboxID
    ) throws -> TodoTask {
        try TodoTask(
            title: title,
            categoryID: categoryID,
            status: .completed,
            completedAt: date
        )
    }

    private func passed(_ title: String, _ date: Date) throws -> TodoTask {
        try TodoTask(
            title: title,
            categoryID: TaskCategory.inboxID,
            status: .pass,
            completedAt: date
        )
    }

    private func task(
        _ title: String,
        status: TaskStatus,
        start: String?,
        end: String?,
        completed: String?,
        categoryID: String = TaskCategory.inboxID
    ) throws -> TodoTask {
        try task(
            title,
            status: status,
            start: start,
            end: end,
            completedAt: completed.map { date($0) },
            categoryID: categoryID
        )
    }

    private func task(
        _ title: String,
        status: TaskStatus,
        start: String?,
        end: String?,
        completedAt: Date?,
        categoryID: String = TaskCategory.inboxID
    ) throws -> TodoTask {
        try TodoTask(
            title: title,
            categoryID: categoryID,
            status: status,
            startDate: start.map { date($0) },
            endDate: end.map { date($0) },
            completedAt: completedAt
        )
    }

}

private func date(_ value: String) -> Date {
    if value.count == 10 {
        return TodoTask.protocolCalendar.date(from: DateComponents(
            year: Int(value.prefix(4)),
            month: Int(value.dropFirst(5).prefix(2)),
            day: Int(value.suffix(2))
        ))!
    }
    return ISO8601DateFormatter().date(from: value)!
}
