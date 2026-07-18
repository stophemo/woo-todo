import Foundation
import Testing
@testable import WooTodoCore

@Suite("周期惰性结算")
struct PeriodEngineTests {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    @Test("每日一次性任务跨日后自动 Pass")
    func oneTimeDailyTaskPassesAfterDeadline() throws {
        let engine = PeriodEngine(timeZone: timeZone)
        let task = try makeTask(
            title: "提交日报",
            scope: .daily,
            recurrence: .once,
            containing: date("2026-07-15T12:00:00+08:00"),
            engine: engine
        )
        let settledAt = date("2026-07-16T08:00:00+08:00")
        let result = engine.settle([task], at: settledAt)

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.status == .pass)
        #expect(result.tasks.first?.completedAt == settledAt)
        #expect(result.changedTaskIDs == Set([task.id]))
        #expect(result.generatedTaskIDs.isEmpty)
    }

    @Test("重复任务补齐遗漏周期且不会重复生成")
    func repeatingTaskBackfillsMissedPeriods() throws {
        let engine = PeriodEngine(timeZone: timeZone)
        var first = try makeTask(
            title: "写明日计划",
            scope: .daily,
            recurrence: .repeating(RepeatRule(frequency: .daily)),
            containing: date("2026-07-13T22:00:00+08:00"),
            engine: engine
        )
        first.status = .completed
        first.completedAt = date("2026-07-13T23:00:00+08:00")

        let now = date("2026-07-16T09:00:00+08:00")
        let firstResult = engine.settle([first], at: now)
        let secondResult = engine.settle(firstResult.tasks, at: now)

        #expect(firstResult.tasks.count == 4)
        #expect(firstResult.tasks.filter { $0.status == .completed }.count == 1)
        #expect(firstResult.tasks.filter { $0.status == .pass }.count == 2)
        #expect(firstResult.tasks.filter { $0.status == .pending }.count == 1)
        #expect(firstResult.generatedTaskIDs.count == 3)
        #expect(secondResult.tasks.count == firstResult.tasks.count)
        #expect(secondResult.generatedTaskIDs.isEmpty)
    }

    @Test("重复实例改到其他周期后不会被旧规则按确定性 ID 覆盖")
    func editedOccurrenceIsNotOverwrittenByOldRule() throws {
        let engine = PeriodEngine(timeZone: timeZone)
        let firstPeriod = try #require(
            engine.period(containing: date("2026-07-13T22:00:00+08:00"), for: .daily)
        )
        let seriesID = UUID()
        let first = try TodoTask(
            seriesID: seriesID,
            title: "原每日任务",
            timeScope: .daily,
            tier: .mainline,
            recurrence: .repeating(RepeatRule(frequency: .daily)),
            period: firstPeriod,
            createdAt: firstPeriod.start
        )
        let nextDailyPeriod = try #require(
            engine.period(containing: date("2026-07-14T12:00:00+08:00"), for: .daily)
        )
        let reusedID = OccurrenceIDGenerator.makeID(
            seriesID: seriesID,
            scope: .daily,
            periodStart: nextDailyPeriod.start,
            timeZone: timeZone
        )
        let edited = try TodoTask(
            id: reusedID,
            seriesID: seriesID,
            title: "已改成周任务",
            timeScope: .weekly,
            tier: .side,
            recurrence: .once,
            period: engine.period(
                containing: date("2026-07-14T12:00:00+08:00"),
                for: .weekly
            ),
            createdAt: date("2026-07-14T12:00:00+08:00")
        )

        let result = engine.settle(
            [first, edited],
            at: date("2026-07-14T13:00:00+08:00")
        )

        let preserved = try #require(result.tasks.first { $0.id == reusedID })
        #expect(preserved.title == "已改成周任务")
        #expect(preserved.timeScope == .weekly)
        #expect(result.generatedTaskIDs.isEmpty)
    }

    @Test("v1 拒绝无法跨端表达的多周期重复间隔")
    func unsupportedRepeatingIntervalIsRejected() {
        let engine = PeriodEngine(timeZone: timeZone)
        #expect(throws: TaskValidationError.invalidRecurrence) {
            try makeTask(
                title: "整理桌面",
                scope: .daily,
                recurrence: .repeating(RepeatRule(frequency: .daily, interval: 2)),
                containing: date("2026-07-11T10:00:00+08:00"),
                engine: engine
            )
        }
    }

    @Test("周周期从周一零点开始")
    func weekStartsOnMonday() {
        let engine = PeriodEngine(timeZone: timeZone)
        let period = engine.period(containing: date("2026-07-15T14:00:00+08:00"), for: .weekly)

        #expect(period?.start == date("2026-07-13T00:00:00+08:00"))
        #expect(period?.end == date("2026-07-20T00:00:00+08:00"))
    }

    @Test("月任务在下月边界结算")
    func monthlyTaskPassesAtNextMonth() throws {
        let engine = PeriodEngine(timeZone: timeZone)
        let task = try makeTask(
            title: "月度复盘",
            scope: .monthly,
            recurrence: .once,
            containing: date("2026-07-31T20:00:00+08:00"),
            engine: engine
        )

        #expect(engine.settle([task], at: date("2026-07-31T23:59:59+08:00")).tasks.first?.status == .pending)
        #expect(engine.settle([task], at: date("2026-08-01T00:00:00+08:00")).tasks.first?.status == .pass)
    }

    @Test("闲时任务永不过期")
    func anytimeTaskNeverPassesAutomatically() throws {
        let task = try TodoTask(
            title: "学习新工具",
            timeScope: .anytime,
            tier: .extra,
            period: nil,
            createdAt: date("2020-01-01T00:00:00+08:00")
        )
        let result = PeriodEngine(timeZone: timeZone).settle(
            [task],
            at: date("2030-01-01T00:00:00+08:00")
        )

        #expect(result.tasks.first?.status == .pending)
        #expect(result.changedTaskIDs.isEmpty)
    }

    private func makeTask(
        title: String,
        scope: TimeScope,
        recurrence: RecurrenceRule,
        containing date: Date,
        engine: PeriodEngine
    ) throws -> TodoTask {
        try TodoTask(
            title: title,
            timeScope: scope,
            tier: .mainline,
            recurrence: recurrence,
            period: engine.period(containing: date, for: scope),
            createdAt: date
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
