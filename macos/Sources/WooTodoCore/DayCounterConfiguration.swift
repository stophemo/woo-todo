import Foundation

/// 可选的纪念日计数。起始日按第 1 天计算，未启用或日期尚未到达时不显示。
public struct DayCounterConfiguration: Equatable, Sendable {
    public var isEnabled: Bool
    public var title: String
    public var startDate: Date

    public init(
        isEnabled: Bool = false,
        title: String = "",
        startDate: Date = Date()
    ) {
        self.isEnabled = isEnabled
        self.title = title
        self.startDate = startDate
    }

    public func displayText(
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !normalizedTitle.isEmpty else { return nil }
        let start = calendar.startOfDay(for: startDate)
        let current = calendar.startOfDay(for: date)
        guard current >= start,
              let elapsed = calendar.dateComponents([.day], from: start, to: current).day else {
            return nil
        }
        return "\(normalizedTitle) · 第 \(elapsed + 1) 天"
    }
}
