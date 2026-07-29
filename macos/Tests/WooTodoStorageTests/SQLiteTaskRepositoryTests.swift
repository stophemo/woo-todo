import Foundation
import Testing
import WooTodoCore
import WooTodoSync
@testable import WooTodoStorage

@Suite("SQLite 本地仓储")
struct SQLiteTaskRepositoryTests {
    @Test("可以保存、更新和筛选，已结算任务不可改写")
    func repositoryRoundTrip() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let engine = PeriodEngine(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let now = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00+08:00")!
        var task = try TodoTask(
            title: "完成 M1 骨架",
            timeScope: .daily,
            tier: .mainline,
            recurrence: .repeating(RepeatRule(frequency: .daily)),
            period: engine.period(containing: now, for: .daily),
            sortIndex: 3,
            createdAt: now,
            deadlineDate: now.addingTimeInterval(5 * 86_400)
        )

        try repository.save(task)
        #expect(try repository.fetchAll() == [task])

        task.status = .completed
        task.completedAt = now.addingTimeInterval(60)
        task.updatedAt = now.addingTimeInterval(60)
        try repository.save(task)
        let today = try repository.fetchTasks(
            scope: .daily,
            in: engine.period(containing: now, for: .daily)
        )
        #expect(today.first?.status == .completed)
        #expect(today.first?.completedAt == task.completedAt)

        do {
            try repository.delete(id: task.id)
            Issue.record("已完成任务不应允许删除")
        } catch SQLiteRepositoryError.settledTaskImmutable {
            // 预期错误。
        }

        var rewritten = task
        rewritten.title = "改写历史"
        rewritten.updatedAt = now.addingTimeInterval(120)
        do {
            try repository.save(rewritten)
            Issue.record("已完成任务不应允许编辑")
        } catch SQLiteRepositoryError.settledTaskImmutable {
            // 预期错误。
        }
        #expect(try repository.fetchAll() == [task])

        let pending = try TodoTask(
            title: "可以删除",
            timeScope: .daily,
            tier: .side,
            period: engine.period(containing: now, for: .daily),
            sortIndex: 4,
            createdAt: now.addingTimeInterval(1)
        )
        try repository.save(pending)
        try repository.delete(id: pending.id)
        #expect(try repository.fetchAll() == [task])
    }

    @Test("闲时任务可以无周期保存")
    func anytimeTaskRoundTrip() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let createdAt = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00+08:00")!
        let task = try TodoTask(
            title: "闲时阅读",
            timeScope: .anytime,
            tier: .extra,
            period: nil,
            createdAt: createdAt
        )
        try repository.save(task)

        #expect(try repository.fetchTasks(scope: .anytime, in: nil) == [task])
    }

    @Test("只有显式请求当前列表时才带入过期一次性任务")
    func overdueOnceRequiresExplicitInclusion() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let engine = PeriodEngine(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let yesterday = ISO8601DateFormatter().date(from: "2026-07-14T12:00:00+08:00")!
        let today = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00+08:00")!
        let task = try TodoTask(
            title: "昨日未完成",
            timeScope: .daily,
            tier: .mainline,
            period: engine.period(containing: yesterday, for: .daily),
            createdAt: yesterday
        )
        try repository.save(task)
        let todayPeriod = try #require(engine.period(containing: today, for: .daily))

        #expect(try repository.fetchTasks(scope: .daily, in: todayPeriod).isEmpty)
        #expect(
            try repository.fetchTasks(
                scope: .daily,
                in: todayPeriod,
                includeOverdueOnce: true
            ) == [task]
        )
    }

    @Test("一次性完成项跨周期可恢复，过期重复周期不能恢复")
    func reopenCompletedTask() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let engine = PeriodEngine(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let now = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00+08:00")!
        var task = try TodoTask(
            title: "误点完成",
            timeScope: .daily,
            tier: .mainline,
            period: engine.period(containing: now, for: .daily),
            createdAt: now.addingTimeInterval(-60)
        )
        task.status = .completed
        task.completedAt = now.addingTimeInterval(-30)
        task.updatedAt = now.addingTimeInterval(-30)
        try repository.save(task)

        #expect(try repository.reopenCompleted(id: task.id, at: now))
        var reopened = try #require(try repository.fetchAll().first)
        #expect(reopened.status == .pending)
        #expect(reopened.completedAt == nil)
        #expect(try repository.reopenCompleted(id: task.id, at: now) == false)

        reopened.status = .completed
        reopened.completedAt = now
        reopened.updatedAt = now
        try repository.save(reopened)
        let periodEnd = try #require(reopened.period?.end)
        #expect(try repository.reopenCompleted(id: task.id, at: periodEnd))
        reopened = try #require(try repository.fetchAll().first { $0.id == task.id })
        #expect(reopened.status == .pending)
        #expect(reopened.completedAt == nil)

        var repeating = try TodoTask(
            title: "昨日重复任务",
            timeScope: .daily,
            tier: .mainline,
            recurrence: .repeating(RepeatRule(frequency: .daily)),
            period: engine.period(containing: now, for: .daily),
            createdAt: now.addingTimeInterval(-60)
        )
        repeating.status = .completed
        repeating.completedAt = now
        repeating.updatedAt = now
        try repository.save(repeating)

        #expect(try repository.reopenCompleted(id: repeating.id, at: periodEnd) == false)
        let storedRepeating = try #require(
            try repository.fetchAll().first { $0.id == repeating.id }
        )
        #expect(storedRepeating.status == .completed)
    }

    @Test("显示配置在仓储关闭并重新打开后仍保留")
    func displayConfigurationSurvivesRepositoryReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("tasks.sqlite")
        let payload = try WireDisplayConfigurationPayload(
            headerTemplate: "{dateLong} · 今日任务",
            subtitleTemplate: "坚持第 {elapsedDays} 天",
            startDate: "2026-01-01",
            deadlineDate: "2026-12-31"
        )

        do {
            let repository = try SQLiteTaskRepository(databaseURL: databaseURL)
            try repository.saveDisplayConfiguration(payload)
            #expect(try repository.displayConfiguration() == payload)
        }

        let reopened = try SQLiteTaskRepository(databaseURL: databaseURL)
        #expect(try reopened.displayConfiguration() == payload)
    }
}
