import Foundation
import Testing
@testable import WooTodoCore

@Suite("任务领域模型")
struct TaskModelTests {
    @Test("任务内容会去除首尾空白")
    func titleIsTrimmed() throws {
        let task = try TodoTask(
            title: "  写周报  \n",
            timeScope: .anytime,
            tier: .side,
            period: nil
        )
        #expect(task.title == "写周报")
    }

    @Test("空任务不能创建")
    func emptyTitleIsRejected() {
        #expect(throws: TaskValidationError.emptyTitle) {
            try TodoTask(title: "  \n", timeScope: .anytime, tier: .extra, period: nil)
        }
    }

    @Test("标题上限按 Unicode scalar 而不是字形簇计算")
    func titleLimitUsesUnicodeScalars() throws {
        let valid = String(repeating: "😀", count: 61)
        #expect(
            try TodoTask(
                title: valid,
                timeScope: .anytime,
                tier: .mainline,
                period: nil
            ).title == valid
        )
        #expect(throws: TaskValidationError.titleTooLong) {
            try TodoTask(
                title: String(repeating: "👨‍👩‍👧‍👦", count: 18),
                timeScope: .anytime,
                tier: .mainline,
                period: nil
            )
        }
    }

    @Test("重复频率必须与时间维度一致")
    func recurrenceMustMatchScope() {
        let now = Date()
        let period = TaskPeriod(start: now, end: now.addingTimeInterval(86_400))
        #expect(throws: TaskValidationError.invalidRecurrence) {
            try TodoTask(
                title: "不合法任务",
                timeScope: .daily,
                tier: .mainline,
                recurrence: .repeating(RepeatRule(frequency: .weekly)),
                period: period
            )
        }
    }

    @Test("任务按主线、支线、外传排序")
    func tierSortOrder() throws {
        let tasks = try [QuestTier.extra, .mainline, .side].map { tier in
            try TodoTask(title: tier.displayName, timeScope: .anytime, tier: tier, period: nil)
        }
        #expect(tasks.sorted(by: TodoTask.displayOrder).map(\.tier) == [
            .mainline, .side, .extra
        ])
    }

    @Test("跨端协议枚举值保持稳定")
    func wireValuesAreStable() {
        #expect(TimeScope.daily.rawValue == "day")
        #expect(TimeScope.weekly.rawValue == "week")
        #expect(TimeScope.monthly.rawValue == "month")
        #expect(TimeScope.anytime.rawValue == "someday")
        #expect(QuestTier.mainline.rawValue == "main")
        #expect(QuestTier.side.rawValue == "side")
        #expect(QuestTier.extra.rawValue == "extra")
    }
}
