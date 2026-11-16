import Foundation
import Testing
import WooTodoCore
import WooTodoSync
@testable import WooTodoStorage

@Suite("SQLite 本地仓储")
struct SQLiteTaskRepositoryTests {
    @Test("可以保存、更新和读取，已结算任务不可改写")
    func repositoryRoundTrip() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let now = date("2026-07-15T12:00:00+08:00")
        var task = try TodoTask(
            title: "完成 M1 骨架",
            categoryID: "main",
            startDate: date("2026-07-15"),
            endDate: date("2026-07-20"),
            sortIndex: 3,
            createdAt: now
        )

        try repository.save(task)
        #expect(try repository.fetchAll() == [task])

        task.status = .completed
        task.completedAt = now.addingTimeInterval(60)
        task.updatedAt = now.addingTimeInterval(60)
        try repository.save(task)
        let stored = try #require(try repository.fetchAll().first)
        #expect(stored.status == .completed)
        #expect(stored.completedAt == task.completedAt)
        #expect(stored.startDate == date("2026-07-15"))
        #expect(stored.endDate == date("2026-07-20"))

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
    }

    @Test("历史记录可批量清除并生成幂等删除记录")
    func clearHistory() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let now = date("2026-07-15T12:00:00+08:00")
        var completed = try TodoTask(
            title: "已完成",
            categoryID: "main",
            createdAt: now
        )
        var passed = try TodoTask(
            title: "已放弃",
            categoryID: "side",
            createdAt: now.addingTimeInterval(1)
        )
        let pending = try TodoTask(
            title: "保留待办",
            categoryID: "extra",
            createdAt: now.addingTimeInterval(2)
        )
        try repository.save([completed, passed, pending])
        completed.status = .completed
        completed.completedAt = now.addingTimeInterval(3)
        completed.updatedAt = now.addingTimeInterval(3)
        passed.status = .pass
        passed.completedAt = now.addingTimeInterval(4)
        passed.updatedAt = now.addingTimeInterval(4)
        try repository.save([completed, passed])

        #expect(try repository.clearHistory(ids: [completed.id, pending.id]) == 1)
        #expect(try repository.clearHistory(ids: [completed.id]) == 0)
        #expect(Set(try repository.fetchAll().map(\.id)) == [pending.id, passed.id])
        #expect(try repository.clearHistory(ids: nil) == 1)
        #expect(try repository.clearHistory(ids: nil) == 0)
        #expect(try repository.fetchAll().map(\.id) == [pending.id])
        #expect(try repository.deletedTaskIDs() == [completed.id, passed.id])
    }

    @Test("无日期任务可以保存并读取")
    func anytimeTaskRoundTrip() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let createdAt = date("2026-07-15T12:00:00+08:00")
        let task = try TodoTask(
            title: "闲时阅读",
            categoryID: "extra",
            createdAt: createdAt
        )
        try repository.save(task)

        #expect(try repository.fetchAll() == [task])
    }

    @Test("日期范围写入后读取一致")
    func dateRangeRoundTrip() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let ranged = try TodoTask(
            title: "多日任务",
            categoryID: "work",
            startDate: date("2026-07-13"),
            endDate: date("2026-07-25")
        )
        try repository.save(ranged)

        let stored = try repository.fetchAll()
        let storedRanged = try #require(stored.first { $0.id == ranged.id })
        #expect(storedRanged.categoryID == "work")
        #expect(storedRanged.startDate == date("2026-07-13"))
        #expect(storedRanged.endDate == date("2026-07-25"))
    }

    @Test("完成项可以撤销且不再受周期限制")
    func reopenCompletedTask() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let now = date("2026-07-15T12:00:00+08:00")
        var task = try TodoTask(
            title: "误点完成",
            categoryID: "main",
            startDate: date("2026-07-15"),
            endDate: date("2026-07-15"),
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
        reopened.completedAt = date("2026-09-01")
        reopened.updatedAt = date("2026-09-01")
        try repository.save(reopened)
        #expect(try repository.reopenCompleted(id: task.id, at: date("2026-09-02")))
        reopened = try #require(try repository.fetchAll().first { $0.id == task.id })
        #expect(reopened.status == .pending)
    }

    @Test("分类可保存、读取并在删除时重分配待办")
    func categoriesRoundTripAndReassign() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let work = try TaskCategory(id: "work", name: "工作", order: 4)
        let categories = TaskCategory.normalizeList(TaskCategory.defaults + [work])
        try repository.saveCategories(categories)
        #expect(try repository.fetchCategories() == categories)

        let pending = try TodoTask(title: "工作待办", categoryID: "work")
        let completed = try TodoTask(
            title: "工作完成",
            categoryID: "work",
            status: .completed,
            completedAt: Date()
        )
        try repository.save([pending, completed])

        #expect(try repository.reassignPendingCategory(
            from: "work",
            to: TaskCategory.inboxID,
            at: Date()
        ) == 1)
        let stored = try repository.fetchAll()
        #expect(stored.first { $0.id == pending.id }?.categoryID == TaskCategory.inboxID)
        #expect(stored.first { $0.id == completed.id }?.categoryID == "work")
    }

    @Test("升级会移除未使用的旧默认类型")
    func unusedLegacyDefaultCategoriesAreRemovedOnReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("tasks.sqlite")

        do {
            let repository = try SQLiteTaskRepository(databaseURL: databaseURL)
            try repository.saveCategories(legacyDefaultCategories())
        }

        let reopened = try SQLiteTaskRepository(databaseURL: databaseURL)
        #expect(try reopened.fetchCategories().map(\.id) == [TaskCategory.inboxID])
    }

    @Test("升级会保留任务正在使用的旧默认类型")
    func usedLegacyDefaultCategoryIsPreservedOnReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("tasks.sqlite")

        do {
            let repository = try SQLiteTaskRepository(databaseURL: databaseURL)
            try repository.saveCategories(legacyDefaultCategories())
            try repository.save(try TodoTask(title: "保留主线", categoryID: "main"))
        }

        let reopened = try SQLiteTaskRepository(databaseURL: databaseURL)
        #expect(try reopened.fetchCategories().map(\.id) == [
            TaskCategory.inboxID, "main",
        ])
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

    private func legacyDefaultCategories() -> [TaskCategory] {
        TaskCategory.normalizeList(TaskCategory.defaults + [
            try! TaskCategory(id: "main", name: "主线", order: 1),
            try! TaskCategory(id: "side", name: "支线", order: 2),
            try! TaskCategory(id: "extra", name: "外传", order: 3),
        ])
    }

    private func date(_ value: String) -> Date {
        if value.count == 10 {
            var calendar = TodoTask.protocolCalendar
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return calendar.date(from: DateComponents(
                year: Int(value.prefix(4)),
                month: Int(value.dropFirst(5).prefix(2)),
                day: Int(value.suffix(2))
            ))!
        }
        return ISO8601DateFormatter().date(from: value)!
    }
}
