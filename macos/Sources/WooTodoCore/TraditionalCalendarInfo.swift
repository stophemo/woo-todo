import Foundation

public struct TraditionalCalendarInfo: Equatable, Sendable {
    public let lunarDate: String
    public let annotation: String?

    public init(lunarDate: String, annotation: String?) {
        self.lunarDate = lunarDate
        self.annotation = annotation
    }

    public static func render(
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> TraditionalCalendarInfo {
        var gregorianCalendar = Calendar(identifier: .gregorian)
        gregorianCalendar.timeZone = calendar.timeZone
        let startOfDay = gregorianCalendar.startOfDay(for: date)

        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.timeZone = calendar.timeZone
        let lunar = lunarCalendar.dateComponents(
            [.month, .day, .isLeapMonth],
            from: startOfDay
        )
        let nextLunar = gregorianCalendar.date(byAdding: .day, value: 1, to: startOfDay)
            .map {
                lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: $0)
            }
        let lunarMonth = lunar.month ?? 1
        let lunarDay = lunar.day ?? 1
        let isLeapMonth = lunar.isLeapMonth == true
        let lunarText = lunarDateText(
            month: lunarMonth,
            day: lunarDay,
            isLeapMonth: isLeapMonth
        )

        let solar = gregorianCalendar.dateComponents([.year, .month, .day], from: startOfDay)
        let notes = [
            solarTerm(
                year: solar.year ?? 1,
                month: solar.month ?? 1,
                day: solar.day ?? 1
            ),
            lunarFestival(
                month: lunarMonth,
                day: lunarDay,
                isLeapMonth: isLeapMonth,
                nextMonth: nextLunar?.month,
                nextDay: nextLunar?.day
            ),
            solarFestivals[festivalKey(month: solar.month ?? 1, day: solar.day ?? 1)]
        ].compactMap { $0 }

        return TraditionalCalendarInfo(
            lunarDate: lunarText,
            annotation: notes.reduce(into: [String]()) { result, note in
                if !result.contains(note) {
                    result.append(note)
                }
            }.joined(separator: " · ").nilIfEmpty
        )
    }

    private static let lunarMonths = [
        "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"
    ]
    private static let lunarDays = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"
    ]
    private static let lunarFestivals = [
        festivalKey(month: 1, day: 1): "春节",
        festivalKey(month: 1, day: 15): "元宵节",
        festivalKey(month: 2, day: 2): "龙抬头",
        festivalKey(month: 5, day: 5): "端午节",
        festivalKey(month: 7, day: 7): "七夕",
        festivalKey(month: 7, day: 15): "中元节",
        festivalKey(month: 8, day: 15): "中秋节",
        festivalKey(month: 9, day: 9): "重阳节",
        festivalKey(month: 12, day: 8): "腊八节"
    ]
    private static let solarFestivals = [
        festivalKey(month: 1, day: 1): "元旦",
        festivalKey(month: 3, day: 8): "妇女节",
        festivalKey(month: 5, day: 1): "劳动节",
        festivalKey(month: 5, day: 4): "青年节",
        festivalKey(month: 6, day: 1): "儿童节",
        festivalKey(month: 10, day: 1): "国庆节"
    ]
    private static let solarTerms: [(name: String, minutes: Int)] = [
        ("小寒", 0), ("大寒", 21_208), ("立春", 42_467), ("雨水", 63_836),
        ("惊蛰", 85_337), ("春分", 107_014), ("清明", 128_867), ("谷雨", 150_921),
        ("立夏", 173_149), ("小满", 195_551), ("芒种", 218_072), ("夏至", 240_693),
        ("小暑", 263_343), ("大暑", 285_989), ("立秋", 308_563), ("处暑", 331_033),
        ("白露", 353_350), ("秋分", 375_494), ("寒露", 397_447), ("霜降", 419_210),
        ("立冬", 440_795), ("小雪", 462_224), ("大雪", 483_532), ("冬至", 504_758)
    ]
    private static let tropicalYearMilliseconds = 31_556_925_974.7

    private static func lunarDateText(month: Int, day: Int, isLeapMonth: Bool) -> String {
        let monthName = lunarMonths.indices.contains(month - 1) ? lunarMonths[month - 1] : String(month)
        let dayName = lunarDays.indices.contains(day - 1) ? lunarDays[day - 1] : String(day)
        return "农历\(isLeapMonth ? "闰" : "")\(monthName)月\(dayName)"
    }

    private static func lunarFestival(
        month: Int,
        day: Int,
        isLeapMonth: Bool,
        nextMonth: Int?,
        nextDay: Int?
    ) -> String? {
        guard !isLeapMonth else { return nil }
        if nextMonth == 1, nextDay == 1 {
            return "除夕"
        }
        return lunarFestivals[festivalKey(month: month, day: day)]
    }

    private static func solarTerm(year: Int, month: Int, day: Int) -> String? {
        guard (1900...2100).contains(year) else { return nil }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let baseDate = utcCalendar.date(from: DateComponents(
            calendar: utcCalendar,
            timeZone: utcCalendar.timeZone,
            year: 1900,
            month: 1,
            day: 6,
            hour: 2,
            minute: 5
        )) else {
            return nil
        }

        return solarTerms.first { term in
            let milliseconds = tropicalYearMilliseconds * Double(year - 1900)
                + Double(term.minutes) * 60_000
            let termDate = baseDate.addingTimeInterval(milliseconds / 1_000)
            let components = utcCalendar.dateComponents([.month, .day], from: termDate)
            return components.month == month && components.day == day
        }?.name
    }

    private static func festivalKey(month: Int, day: Int) -> Int {
        month * 100 + day
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
