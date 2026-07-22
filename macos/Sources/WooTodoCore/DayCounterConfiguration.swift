import Foundation

/// 今日面板的可编辑标题模板。模板中的动态变量由本地日期计算，不参与任务同步。
public struct DayCounterConfiguration: Equatable, Sendable {
    public static let defaultHeaderTemplate = "今日任务"
    public static let weekdayToken = "{weekday}"
    public static let elapsedDaysToken = "{elapsedDays}"
    public static let deadlineDaysToken = "{deadlineDays}"

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
        let weekday = Self.weekdays[calendar.component(.weekday, from: current) - 1]

        return normalizedTemplate
            .replacingOccurrences(of: Self.weekdayToken, with: weekday)
            .replacingOccurrences(of: Self.elapsedDaysToken, with: String(max(0, elapsed + 1)))
            .replacingOccurrences(of: Self.deadlineDaysToken, with: String(deadlineRemaining))
    }

    private static let weekdays = [
        "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六",
    ]
}
