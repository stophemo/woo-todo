import Foundation
import Testing
import WooTodoCore
import WooTodoSync
@testable import WooTodoStorage

@Suite("SQLite 本地仓储")
struct SQLiteTaskRepositoryTests {
    @Test("每天重复任务可以持久化并随恢复保留")
    func dailyRecurrenceRoundTrip() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let now = date("2026-11-20T12:00:00+08:00")
        let task = try TodoTask(
            title: "铲屎",
            categoryID: TaskCategory.inboxID,
            startDate: date("2026-11-20"),
            endDate: date("2026-11-20"),
            createdAt: now,
            recurrence: .daily
        )

        try repository.save(task)
        let stored = try #require(try repository.fetchAll().first)
        #expect(stored.recurrence == .daily)

        try repository.delete(id: task.id)
        let trashed = try #require(try repository.fetchTrash().first)
        #expect(trashed.task.recurrence == .daily)

        let restoredID = try #require(
            try repository.restoreTrash(id: task.id, at: now)
        )
        let restored = try #require(
            try repository.fetchAll().first { $0.id == restoredID }
        )
        #expect(restored.recurrence == .daily)
    }

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

    @Test("删除会保留本机恢复快照，恢复后生成新任务")
    func deleteKeepsRecoverableTrash() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let createdAt = date("2026-07-15T12:00:00+08:00")
        let task = try TodoTask(
            title: "误删任务",
            categoryID: TaskCategory.inboxID,
            startDate: date("2026-07-15"),
            endDate: date("2026-07-20"),
            sortIndex: 4,
            createdAt: createdAt,
            reminderTime: try TaskReminderTime(hour: 9, minute: 30)
        )
        try repository.save(task)

        try repository.delete(id: task.id)
        #expect(try repository.fetchAll().isEmpty)
        let trash = try repository.fetchTrash()
        #expect(trash.count == 1)
        #expect(trash.first?.task.id == task.id)
        #expect(trash.first?.task.title == task.title)
        #expect(trash.first?.task.startDate == task.startDate)
        #expect(trash.first?.task.endDate == task.endDate)
        #expect(trash.first?.task.reminderTime == task.reminderTime)
        #expect(trash.first?.deletedAt != nil)
        #expect(try repository.trashCount() == 1)
        #expect(try repository.deletedTaskIDs() == [task.id])

        let restoredID = try #require(
            try repository.restoreTrash(id: task.id, at: date("2026-07-16T09:00:00+08:00"))
        )
        #expect(restoredID != task.id)
        #expect(try repository.fetchTrash().isEmpty)
        #expect(try repository.trashCount() == 0)
        let restored = try #require(try repository.fetchAll().first)
        #expect(restored.id == restoredID)
        #expect(restored.seriesID == task.seriesID)
        #expect(restored.title == task.title)
        #expect(restored.startDate == task.startDate)
        #expect(restored.endDate == task.endDate)
        #expect(restored.reminderTime == task.reminderTime)
        #expect(restored.status == .pending)
        // 原任务 ID 仍保持墓碑终态，恢复使用的是新 ID。
        #expect(try repository.deletedTaskIDs() == [task.id])
    }

    @Test("删除与恢复都是幂等的")
    func trashOperationsAreIdempotent() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let task = try TodoTask(title: "幂等", categoryID: TaskCategory.inboxID)
        try repository.save(task)

        try repository.delete(id: task.id)
        try repository.delete(id: task.id)
        #expect(try repository.fetchTrash().count == 1)
        #expect(try repository.fetchAll().isEmpty)

        #expect(try repository.restoreTrash(id: task.id, at: Date()) != nil)
        #expect(try repository.restoreTrash(id: task.id, at: Date()) == nil)
        #expect(try repository.fetchTrash().isEmpty)
        #expect(try repository.fetchAll().count == 1)

        #expect(try repository.removeTrash(ids: nil) == 0)
        #expect(try repository.restoreTrash(id: task.id, at: Date()) == nil)
    }

    @Test("移除本机恢复快照不会产生新的删除记录")
    func removingTrashKeepsDeletionHistory() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let task = try TodoTask(title: "清除副本", categoryID: TaskCategory.inboxID)
        try repository.save(task)
        try repository.delete(id: task.id)

        #expect(try repository.removeTrash(ids: [task.id]) == 1)
        #expect(try repository.removeTrash(ids: [task.id]) == 0)
        #expect(try repository.removeTrash(ids: nil) == 0)
        #expect(try repository.fetchTrash().isEmpty)
        #expect(try repository.deletedTaskIDs() == [task.id])
    }

    @Test("同一 seriesID 的两条恢复任务可以同时存在")
    func restoredTasksMayShareSeries() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let seriesID = UUID()
        let day = date("2026-07-15")
        let first = try TodoTask(
            id: UUID(),
            seriesID: seriesID,
            title: "设备一恢复",
            categoryID: TaskCategory.inboxID,
            startDate: day,
            endDate: day
        )
        let second = try TodoTask(
            id: UUID(),
            seriesID: seriesID,
            title: "设备二恢复",
            categoryID: TaskCategory.inboxID,
            startDate: day,
            endDate: day
        )

        try repository.save([first, second])
        #expect(Set(try repository.fetchAll().map(\.id)) == [first.id, second.id])
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
