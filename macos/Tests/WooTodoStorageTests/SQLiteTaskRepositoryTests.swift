import Foundation
import Testing
import WooTodoCore
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
            createdAt: now
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
}
