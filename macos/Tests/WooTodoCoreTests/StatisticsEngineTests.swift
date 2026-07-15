import Foundation
import Testing
@testable import WooTodoCore

@Suite("本地履约统计")
struct StatisticsEngineTests {
    @Test("履约率只计算已结束周期的完成与 Pass")
    func ratesCountsAndHistory() throws {
        let tasks = try [
            task(
                "已完成日报",
                scope: .daily,
                tier: .mainline,
                status: .completed,
                start: "2026-07-13T00:00:00+08:00",
                end: "2026-07-14T00:00:00+08:00",
                event: "2026-07-13T18:00:00+08:00"
            ),
            task(
                "Pass 周任务",
                scope: .weekly,
                tier: .mainline,
                status: .pass,
                start: "2026-07-07T00:00:00+08:00",
                end: "2026-07-14T00:00:00+08:00",
                event: "2026-07-14T00:00:00+08:00"
            ),
            task(
                "已完成月任务",
                scope: .monthly,
                tier: .side,
                status: .completed,
                start: "2026-06-01T00:00:00+08:00",
                end: "2026-07-01T00:00:00+08:00",
                event: "2026-06-30T20:00:00+08:00"
            ),
            task(
                "当前周期已完成",
                scope: .daily,
                tier: .side,
                status: .completed,
                start: "2026-07-15T00:00:00+08:00",
                end: "2026-07-16T00:00:00+08:00",
                event: "2026-07-15T10:00:00+08:00"
            ),
            task(
                "闲时已完成",
                scope: .anytime,
                tier: .extra,
                status: .completed,
                start: nil,
                end: nil,
                event: "2026-07-14T20:00:00+08:00"
            ),
            task(
                "异常待结算记录",
                scope: .daily,
                tier: .side,
                status: .pending,
                start: "2026-07-12T00:00:00+08:00",
                end: "2026-07-13T00:00:00+08:00",
                event: "2026-07-13T00:00:00+08:00"
            )
        ]
        let snapshot = StatisticsEngine().calculate(
            tasks: tasks,
            at: date("2026-07-15T12:00:00+08:00"),
            historyLimit: 3
        )

        #expect(snapshot.endedPeriods == AdherenceMetric(completed: 2, pass: 1))
        #expect(snapshot.endedPeriods.rate == 2.0 / 3.0)
        #expect(snapshot.mainlineEndedPeriods == AdherenceMetric(completed: 1, pass: 1))
        #expect(snapshot.mainlineEndedPeriods.rate == 0.5)
        #expect(snapshot.countsByScope[.daily] == StatusCounts(pending: 1, completed: 2))
        #expect(snapshot.countsByScope[.weekly] == StatusCounts(pass: 1))
        #expect(snapshot.countsByScope[.monthly] == StatusCounts(completed: 1))
        #expect(snapshot.countsByScope[.anytime] == StatusCounts(completed: 1))
        #expect(snapshot.countsByTier[.mainline] == StatusCounts(completed: 1, pass: 1))
        #expect(snapshot.recentHistory.map(\.title) == [
            "当前周期已完成", "闲时已完成", "Pass 周任务"
        ])
    }

    @Test("没有已结束样本时履约率为空")
    func rateIsNilWithoutEndedOutcomes() throws {
        let current = try task(
            "今天完成",
            scope: .daily,
            tier: .mainline,
            status: .completed,
            start: "2026-07-15T00:00:00+08:00",
            end: "2026-07-16T00:00:00+08:00",
            event: "2026-07-15T10:00:00+08:00"
        )
        let snapshot = StatisticsEngine().calculate(
            tasks: [current],
            at: date("2026-07-15T12:00:00+08:00")
        )

        #expect(snapshot.endedPeriods.rate == nil)
        #expect(snapshot.mainlineEndedPeriods.rate == nil)
    }

    @Test("趋势按上海日周月周期分桶并排除窗口外样本")
    func trendsUseShanghaiPeriodsAndFixedWindows() throws {
        let tasks = try [
            task(
                "窗口外日报",
                scope: .daily,
                tier: .mainline,
                status: .completed,
                start: "2026-07-08T00:00:00+08:00",
                end: "2026-07-09T00:00:00+08:00",
                event: "2026-07-08T18:00:00+08:00"
            ),
            task(
                "最早日报",
                scope: .daily,
                tier: .mainline,
                status: .completed,
                start: "2026-07-09T00:00:00+08:00",
                end: "2026-07-10T00:00:00+08:00",
                event: "2026-07-09T18:00:00+08:00"
            ),
            task(
                "昨日日报",
                scope: .daily,
                tier: .side,
                status: .pass,
                start: "2026-07-14T00:00:00+08:00",
                end: "2026-07-15T00:00:00+08:00",
                event: "2026-07-15T00:00:00+08:00"
            ),
            task(
                "今日日报",
                scope: .daily,
                tier: .side,
                status: .completed,
                start: "2026-07-15T00:00:00+08:00",
                end: "2026-07-16T00:00:00+08:00",
                event: "2026-07-15T10:00:00+08:00"
            ),
            task(
                "窗口外周报",
                scope: .weekly,
                tier: .mainline,
                status: .completed,
                start: "2026-05-18T00:00:00+08:00",
                end: "2026-05-25T00:00:00+08:00",
                event: "2026-05-24T18:00:00+08:00"
            ),
            task(
                "最早周报",
                scope: .weekly,
                tier: .mainline,
                status: .completed,
                start: "2026-05-25T00:00:00+08:00",
                end: "2026-06-01T00:00:00+08:00",
                event: "2026-05-31T18:00:00+08:00"
            ),
            task(
                "本周周报",
                scope: .weekly,
                tier: .mainline,
                status: .completed,
                start: "2026-07-13T00:00:00+08:00",
                end: "2026-07-20T00:00:00+08:00",
                event: "2026-07-15T11:00:00+08:00"
            ),
            task(
                "窗口外月报",
                scope: .monthly,
                tier: .mainline,
                status: .completed,
                start: "2026-01-01T00:00:00+08:00",
                end: "2026-02-01T00:00:00+08:00",
                event: "2026-01-31T18:00:00+08:00"
            ),
            task(
                "最早月报",
                scope: .monthly,
                tier: .mainline,
                status: .completed,
                start: "2026-02-01T00:00:00+08:00",
                end: "2026-03-01T00:00:00+08:00",
                event: "2026-02-28T18:00:00+08:00"
            ),
            task(
                "上月月报",
                scope: .monthly,
                tier: .side,
                status: .pass,
                start: "2026-06-01T00:00:00+08:00",
                end: "2026-07-01T00:00:00+08:00",
                event: "2026-07-01T00:00:00+08:00"
            ),
            task(
                "本月月报",
                scope: .monthly,
                tier: .side,
                status: .completed,
                start: "2026-07-01T00:00:00+08:00",
                end: "2026-08-01T00:00:00+08:00",
                event: "2026-07-15T11:30:00+08:00"
            )
        ]

        let snapshot = StatisticsEngine().calculate(
            tasks: tasks,
            at: date("2026-07-15T12:00:00+08:00")
        )

        #expect(snapshot.dailyTrend.count == 7)
        #expect(snapshot.dailyTrend.first?.start == date("2026-07-09T00:00:00+08:00"))
        #expect(snapshot.dailyTrend.last?.start == date("2026-07-15T00:00:00+08:00"))
        #expect(snapshot.dailyTrend.map(\.sampleCount).reduce(0, +) == 3)
        let yesterday = try #require(snapshot.dailyTrend.first {
            $0.start == date("2026-07-14T00:00:00+08:00")
        })
        #expect(yesterday.completed == 0)
        #expect(yesterday.pass == 1)
        #expect(yesterday.sampleCount == 1)
        #expect(yesterday.rate == 0)

        let today = try #require(snapshot.dailyTrend.last)
        #expect(today.completed == 1)
        #expect(today.sampleCount == 1)
        #expect(!today.isEnded)
        #expect(today.rate == nil)

        #expect(snapshot.weeklyTrend.count == 8)
        #expect(snapshot.weeklyTrend.first?.start == date("2026-05-25T00:00:00+08:00"))
        #expect(snapshot.weeklyTrend.last?.start == date("2026-07-13T00:00:00+08:00"))
        #expect(snapshot.weeklyTrend.map(\.sampleCount).reduce(0, +) == 2)
        #expect(snapshot.weeklyTrend.last?.rate == nil)

        #expect(snapshot.monthlyTrend.count == 6)
        #expect(snapshot.monthlyTrend.first?.start == date("2026-02-01T00:00:00+08:00"))
        #expect(snapshot.monthlyTrend.last?.start == date("2026-07-01T00:00:00+08:00"))
        #expect(snapshot.monthlyTrend.map(\.sampleCount).reduce(0, +) == 3)
        #expect(snapshot.monthlyTrend.last?.rate == nil)
    }

    @Test("上海零点边界会结束昨日桶并开启无履约率的新桶")
    func shanghaiMidnightBoundary() throws {
        let yesterdayTask = try task(
            "零点前已完成",
            scope: .daily,
            tier: .mainline,
            status: .completed,
            start: "2026-07-15T00:00:00+08:00",
            end: "2026-07-16T00:00:00+08:00",
            event: "2026-07-15T23:59:59+08:00"
        )

        let snapshot = StatisticsEngine().calculate(
            tasks: [yesterdayTask],
            at: date("2026-07-15T16:00:00Z")
        )
        let endedYesterday = try #require(snapshot.dailyTrend.first {
            $0.start == date("2026-07-15T00:00:00+08:00")
        })
        let newToday = try #require(snapshot.dailyTrend.last)

        #expect(endedYesterday.isEnded)
        #expect(endedYesterday.rate == 1)
        #expect(newToday.start == date("2026-07-16T00:00:00+08:00"))
        #expect(!newToday.isEnded)
        #expect(newToday.sampleCount == 0)
        #expect(newToday.rate == nil)
    }

    private func task(
        _ title: String,
        scope: TimeScope,
        tier: QuestTier,
        status: TaskStatus,
        start: String?,
        end: String?,
        event: String
    ) throws -> TodoTask {
        let eventDate = date(event)
        let period = start.map { startValue -> TaskPeriod in
            TaskPeriod(start: date(startValue), end: date(end!))
        }
        return try TodoTask(
            title: title,
            timeScope: scope,
            tier: tier,
            status: status,
            period: period,
            createdAt: period?.start ?? eventDate,
            updatedAt: eventDate,
            completedAt: status == .completed ? eventDate : nil
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
