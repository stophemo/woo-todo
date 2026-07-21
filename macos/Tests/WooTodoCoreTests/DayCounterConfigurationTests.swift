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

    @Test func disabledBlankOrFutureConfigurationIsHidden() throws {
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 21
        )))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))

        #expect(DayCounterConfiguration(
            isEnabled: false,
            title: "纪念日",
            startDate: today
        ).displayText(on: today, calendar: calendar) == nil)
        #expect(DayCounterConfiguration(
            isEnabled: true,
            title: "   ",
            startDate: today
        ).displayText(on: today, calendar: calendar) == nil)
        #expect(DayCounterConfiguration(
            isEnabled: true,
            title: "纪念日",
            startDate: tomorrow
        ).displayText(on: today, calendar: calendar) == nil)
    }
}
