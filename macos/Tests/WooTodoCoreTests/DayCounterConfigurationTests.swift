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

    @Test func rendersCalendarMonthsAndDaysAcrossPeriodsAndPastDeadline() throws {
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 3
        )))
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 24
        )))
        let deadline = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 3
        )))
        let configuration = DayCounterConfiguration(
            headerTemplate: "{elapsedMonthsDays}",
            subtitleTemplate: "{deadlineMonthsDays}",
            startDate: start,
            deadlineDate: deadline
        )

        #expect(configuration.headerText(on: today, calendar: calendar) == "4个月零22天")
        #expect(configuration.subtitleText(on: today, calendar: calendar) == "-1个月零21天")
    }

    @Test func monthEndLeapDayAndSameDayUseNaturalMonthClamping() throws {
        let vectors = [
            (start: DateComponents(year: 2026, month: 1, day: 31),
             end: DateComponents(year: 2026, month: 2, day: 28),
             expected: "1个月零0天"),
            (start: DateComponents(year: 2024, month: 2, day: 29),
             end: DateComponents(year: 2025, month: 2, day: 28),
             expected: "12个月零0天")
        ]

        for vector in vectors {
            let start = try #require(calendar.date(from: vector.start))
            let end = try #require(calendar.date(from: vector.end))
            let elapsedDate = try #require(calendar.date(byAdding: .day, value: -1, to: end))
            let elapsed = DayCounterConfiguration(
                headerTemplate: "{elapsedMonthsDays}",
                startDate: start
            )
            let overdue = DayCounterConfiguration(
                subtitleTemplate: "{deadlineMonthsDays}",
                deadlineDate: start
            )

            #expect(elapsed.headerText(on: elapsedDate, calendar: calendar) == vector.expected)
            #expect(overdue.subtitleText(on: end, calendar: calendar) == "-\(vector.expected)")
        }

        let date = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 24
        )))
        let sameDay = DayCounterConfiguration(
            headerTemplate: "{elapsedMonthsDays}",
            subtitleTemplate: "{deadlineMonthsDays}",
            startDate: date,
            deadlineDate: date
        )
        #expect(sameDay.headerText(on: date, calendar: calendar) == "0个月零1天")
        #expect(sameDay.subtitleText(on: date, calendar: calendar) == "0个月零0天")
    }

    @Test func futureStartUsesZeroAndUnknownVariablesRemainLiteral() throws {
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 21
        )))
        let future = try #require(calendar.date(byAdding: .day, value: 3, to: today))
        let configuration = DayCounterConfiguration(
            headerTemplate: "  ",
            subtitleTemplate: "第 {elapsedDays} 天 · {elapsedMonthsDays} · {custom}",
            startDate: future,
            deadlineDate: future
        )

        #expect(configuration.headerText(on: today, calendar: calendar) == nil)
        #expect(configuration.subtitleText(on: today, calendar: calendar) ==
            "第 0 天 · 0个月零0天 · {custom}")
    }

    @Test func rendersEnglishWeekdayAndCompleteDateVariables() throws {
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 12, day: 31
        )))
        let today = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 2
        )))
        let deadline = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 9
        )))
        let configuration = DayCounterConfiguration(
            headerTemplate: "{weekdayEn} / {weekdayEnShort} / {weekdayShort}",
            subtitleTemplate: "{date} | {dateLong} | {year}/{month}/{day} | {monthPadded}/{dayPadded} | {startDate} -> {deadlineDate}",
            startDate: start,
            deadlineDate: deadline
        )

        #expect(configuration.headerText(on: today, calendar: calendar) == "Saturday / Sat / 六")
        #expect(configuration.subtitleText(on: today, calendar: calendar) ==
            "2027-01-02 | 2027年1月2日 | 2027/1/2 | 01/02 | 2026-12-31 -> 2027-01-09")
    }

    @Test func chineseAndEnglishWeekdaysMatchForACompleteWeek() throws {
        let monday = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 20
        )))
        let expected = [
            "星期一|一|Monday|Mon",
            "星期二|二|Tuesday|Tue",
            "星期三|三|Wednesday|Wed",
            "星期四|四|Thursday|Thu",
            "星期五|五|Friday|Fri",
            "星期六|六|Saturday|Sat",
            "星期日|日|Sunday|Sun"
        ]
        let configuration = DayCounterConfiguration(
            headerTemplate: "{weekday}|{weekdayShort}|{weekdayEn}|{weekdayEnShort}"
        )

        for (offset, value) in expected.enumerated() {
            let date = try #require(calendar.date(byAdding: .day, value: offset, to: monday))
            #expect(configuration.headerText(on: date, calendar: calendar) == value)
        }
    }
}
