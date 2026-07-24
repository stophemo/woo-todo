import Foundation

/// 今日面板的可编辑标题模板。模板中的动态变量由本地日期计算，不参与任务同步。
public struct DayCounterConfiguration: Equatable, Sendable {
    public static let defaultHeaderTemplate = "今日任务"
    public static let weekdayToken = "{weekday}"
    public static let weekdayShortToken = "{weekdayShort}"
    public static let weekdayEnToken = "{weekdayEn}"
    public static let weekdayEnShortToken = "{weekdayEnShort}"
    public static let dateToken = "{date}"
    public static let dateLongToken = "{dateLong}"
    public static let yearToken = "{year}"
    public static let monthToken = "{month}"
    public static let monthPaddedToken = "{monthPadded}"
    public static let dayToken = "{day}"
    public static let dayPaddedToken = "{dayPadded}"
    public static let startDateToken = "{startDate}"
    public static let deadlineDateToken = "{deadlineDate}"
    public static let elapsedDaysToken = "{elapsedDays}"
    public static let deadlineDaysToken = "{deadlineDays}"
    public static let elapsedMonthsDaysToken = "{elapsedMonthsDays}"
    public static let deadlineMonthsDaysToken = "{deadlineMonthsDays}"

    public var headerTemplate: String
    public var subtitleTemplate: String
    public var startDate: Date
    public var deadlineDate: Date

    public init(
        headerTemplate: String = Self.defaultHeaderTemplate,
        subtitleTemplate: String = "",
        startDate: Date = Date(),
        deadlineDate: Date = Date()
    ) {
        self.headerTemplate = headerTemplate
        self.subtitleTemplate = subtitleTemplate
        self.startDate = startDate
        self.deadlineDate = deadlineDate
    }

    /// 兼容旧版固定“标题 · 第 N 天”配置，供偏好迁移与旧数据测试使用。
    public init(isEnabled: Bool, title: String, startDate: Date) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            subtitleTemplate: isEnabled && !normalizedTitle.isEmpty
                ? "\(normalizedTitle) · 第 \(Self.elapsedDaysToken) 天"
                : "",
            startDate: startDate
        )
    }

    public func headerText(
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        render(headerTemplate, on: date, calendar: calendar)
    }

    public func subtitleText(
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        render(subtitleTemplate, on: date, calendar: calendar)
    }

    /// 保留旧调用名，语义等同于渲染副标题。
    public func displayText(
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        subtitleText(on: date, calendar: calendar)
    }

    private func render(
        _ template: String,
        on date: Date,
        calendar: Calendar
    ) -> String? {
        let normalizedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTemplate.isEmpty else { return nil }
        let start = calendar.startOfDay(for: startDate)
        let current = calendar.startOfDay(for: date)
        let deadline = calendar.startOfDay(for: deadlineDate)
        let elapsed = calendar.dateComponents([.day], from: start, to: current).day ?? 0
        let deadlineRemaining = calendar.dateComponents([.day], from: current, to: deadline).day ?? 0
        let elapsedMonthsDays: String
        if current < start {
            elapsedMonthsDays = Self.zeroMonthsDays
        } else if let elapsedEnd = calendar.date(byAdding: .day, value: 1, to: current) {
            elapsedMonthsDays = Self.monthsDays(from: start, to: elapsedEnd, calendar: calendar)
        } else {
            elapsedMonthsDays = Self.zeroMonthsDays
        }
        let deadlineMonthsDays = Self.monthsDays(
            from: current,
            to: deadline,
            calendar: calendar
        )
        let year = calendar.component(.year, from: current)
        let month = calendar.component(.month, from: current)
        let day = calendar.component(.day, from: current)
        let weekdayIndex = calendar.component(.weekday, from: current) - 1
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        let dateLong = "\(year)年\(month)月\(day)日"
        let variables: [(String, String)] = [
            (Self.weekdayToken, Self.weekdays[weekdayIndex]),
            (Self.weekdayShortToken, Self.weekdayShort[weekdayIndex]),
            (Self.weekdayEnToken, Self.weekdaysEn[weekdayIndex]),
            (Self.weekdayEnShortToken, Self.weekdaysEnShort[weekdayIndex]),
            (Self.dateToken, date),
            (Self.dateLongToken, dateLong),
            (Self.yearToken, String(year)),
            (Self.monthToken, String(month)),
            (Self.monthPaddedToken, String(format: "%02d", month)),
            (Self.dayToken, String(day)),
            (Self.dayPaddedToken, String(format: "%02d", day)),
            (Self.startDateToken, Self.isoDate(start, calendar: calendar)),
            (Self.deadlineDateToken, Self.isoDate(deadline, calendar: calendar)),
            (Self.elapsedDaysToken, String(max(0, elapsed + 1))),
            (Self.deadlineDaysToken, String(deadlineRemaining)),
            (Self.elapsedMonthsDaysToken, elapsedMonthsDays),
            (Self.deadlineMonthsDaysToken, deadlineMonthsDays)
        ]

        return variables.reduce(normalizedTemplate) { rendered, variable in
            rendered.replacingOccurrences(of: variable.0, with: variable.1)
        }
    }

    private static let weekdays = [
        "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六",
    ]
    private static let weekdayShort = ["日", "一", "二", "三", "四", "五", "六"]
    private static let weekdaysEn = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
    ]
    private static let weekdaysEnShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func isoDate(_ date: Date, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static let zeroMonthsDays = "0个月零0天"

    private static func monthsDays(
        from source: Date,
        to destination: Date,
        calendar: Calendar
    ) -> String {
        guard source != destination else { return zeroMonthsDays }
        let isNegative = destination < source
        let earlier = isNegative ? destination : source
        let later = isNegative ? source : destination
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: earlier,
            to: later
        )
        let months = max(0, (components.year ?? 0) * 12 + (components.month ?? 0))
        let days = max(0, components.day ?? 0)
        let sign = isNegative ? "-" : ""
        return "\(sign)\(months)个月零\(days)天"
    }
}
