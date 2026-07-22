import Foundation
import Testing
@testable import WooTodoCore

struct DayCounterConfigurationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    @Test func startDateIsDayOneAcrossDayBoundary() throws {
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 20,
            hour: 23
        )))
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 21,
            hour: 1
        )))
        let configuration = DayCounterConfiguration(
            isEnabled: true,
            title: "来到西安 remake",
            startDate: start
        )

        #expect(configuration.displayText(on: today, calendar: calendar) ==
            "来到西安 remake · 第 2 天")
    }

    @Test func rendersAllVariablesAcrossYearAndDeadlineBoundary() throws {
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 12, day: 31
        )))
        let today = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 2
        )))
        let deadline = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 1
        )))
        let configuration = DayCounterConfiguration(
            headerTemplate: "重启 · {weekday}",
            subtitleTemplate: "耗时 {elapsedDays} 天 · 截止 {deadlineDays} 天",
            startDate: start,
            deadlineDate: deadline
        )

        #expect(configuration.headerText(on: today, calendar: calendar) == "重启 · 星期六")
        #expect(configuration.subtitleText(on: today, calendar: calendar) ==
            "耗时 3 天 · 截止 -1 天")
    }

    @Test func futureStartUsesZeroAndUnknownVariablesRemainLiteral() throws {
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 21
        )))
        let future = try #require(calendar.date(byAdding: .day, value: 3, to: today))
        let configuration = DayCounterConfiguration(
            headerTemplate: "  ",
            subtitleTemplate: "第 {elapsedDays} 天 · {custom}",
            startDate: future,
            deadlineDate: future
        )

        #expect(configuration.headerText(on: today, calendar: calendar) == nil)
        #expect(configuration.subtitleText(on: today, calendar: calendar) ==
            "第 0 天 · {custom}")
    }
}
