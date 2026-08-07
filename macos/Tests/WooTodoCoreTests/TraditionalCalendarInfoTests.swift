import Foundation
import Testing
@testable import WooTodoCore

struct TraditionalCalendarInfoTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    @Test func rendersLunarDateAndSolarTermAcrossYears() throws {
        let cases = [
            (DateComponents(year: 2025, month: 4, day: 4), "农历三月初七", "清明"),
            (DateComponents(year: 2026, month: 8, day: 7), "农历六月廿五", "立秋"),
            (DateComponents(year: 2027, month: 1, day: 5), "农历冬月廿八", "小寒")
        ]

        for item in cases {
            let date = try #require(calendar.date(from: item.0))
            let rendered = TraditionalCalendarInfo.render(on: date, calendar: calendar)
            #expect(rendered.lunarDate == item.1)
            #expect(rendered.annotation == item.2)
        }
    }

    @Test func rendersLunarFestivalsAndNewYearsEveAcrossCycleBoundary() throws {
        let cases = [
            (DateComponents(year: 2026, month: 2, day: 17), "春节"),
            (DateComponents(year: 2026, month: 9, day: 25), "中秋节"),
            (DateComponents(year: 2027, month: 2, day: 5), "除夕")
        ]

        for item in cases {
            let date = try #require(calendar.date(from: item.0))
            #expect(TraditionalCalendarInfo.render(on: date, calendar: calendar).annotation == item.1)
        }
    }

    @Test func combinesSolarAndLunarAnnotationsWithoutDuplicates() throws {
        let date = try #require(calendar.date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 29
        )))

        let rendered = TraditionalCalendarInfo.render(on: date, calendar: calendar)

        #expect(rendered.lunarDate == "农历正月初一")
        #expect(rendered.annotation == "春节")
    }
}
