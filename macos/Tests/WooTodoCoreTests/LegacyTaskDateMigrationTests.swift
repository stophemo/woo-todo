import Foundation
import Testing
@testable import WooTodoCore

@Suite("旧任务日期折算")
struct LegacyTaskDateMigrationTests {
    @Test("前一天到当天的旧区间折算为当天单日任务")
    func collapsesOneDayRangeToEndDate() throws {
        let task = try TodoTask(
            title: "GI 第 3 场",
            categoryID: "main",
            startDate: date("2026-11-23"),
            endDate: date("2026-11-24"),
            createdAt: date("2026-11-20T16:17:50+08:00"),
            reminderTime: TaskReminderTime(hour: 21, minute: 30)
        )

        let migrated = LegacyTaskDateMigration.plan(tasks: [task])

        #expect(migrated.count == 1)
        #expect(migrated.first?.startDate == date("2026-11-24"))
        #expect(migrated.first?.endDate == date("2026-11-24"))
        #expect(migrated.first?.reminderTime == task.reminderTime)
    }

    @Test("真正的跨天任务、每天重复任务和已结算任务保持不变")
    func keepsGenuineRangesAndSettledTasks() throws {
        let range = try TodoTask(
            title: "三天项目",
            categoryID: "main",
            startDate: date("2026-11-23"),
            endDate: date("2026-11-25")
        )
        let daily = try TodoTask(
            title: "铲屎",
            categoryID: "main",
            startDate: date("2026-11-23"),
            endDate: date("2026-11-24"),
            recurrence: .daily
        )
        let completed = try TodoTask(
            title: "已完成",
            categoryID: "main",
            status: .completed,
            startDate: date("2026-11-23"),
            endDate: date("2026-11-24"),
            completedAt: date("2026-11-24")
        )

        #expect(
            LegacyTaskDateMigration.plan(tasks: [range, daily, completed]).isEmpty
        )
    }

    @Test("只执行一次，已迁移过的任务不会再次改动")
    func runsOncePerInstall() throws {
        let repository = LegacyDateTestRepository(tasks: [
            try TodoTask(
                title: "GI 第 2 场",
                categoryID: "main",
                startDate: date("2026-11-22"),
                endDate: date("2026-11-23"),
                createdAt: date("2026-11-20T16:17:50+08:00")
            ),
        ])
        let suiteName = "legacy-date-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try LegacyTaskDateMigration.run(
            repository: repository,
            defaults: defaults,
            now: date("2026-11-23T09:00:00+08:00")
        )
        let second = try LegacyTaskDateMigration.run(
            repository: repository,
            defaults: defaults,
            now: date("2026-11-23T10:00:00+08:00")
        )

        #expect(first == 1)
        #expect(second == 0)
        #expect(repository.saved.count == 1)
        #expect(repository.saved.first?.startDate == date("2026-11-23"))
    }

    private func date(_ value: String) -> Date {
        if value.count == 10 {
            return TodoTask.protocolCalendar.date(from: DateComponents(
                year: Int(value.prefix(4)),
                month: Int(value.dropFirst(5).prefix(2)),
                day: Int(value.suffix(2))
            ))!
        }
        return ISO8601DateFormatter().date(from: value)!
    }
}

private final class LegacyDateTestRepository: TaskRepository {
    private var tasks: [TodoTask]
    private(set) var saved: [TodoTask] = []

    init(tasks: [TodoTask]) {
        self.tasks = tasks
    }

    func fetchAll() throws -> [TodoTask] { tasks }
    func deletedTaskIDs() throws -> Set<UUID> { [] }

    func save(_ tasks: [TodoTask]) throws {
        saved.append(contentsOf: tasks)
        for task in tasks {
            if let index = self.tasks.firstIndex(where: { $0.id == task.id }) {
                self.tasks[index] = task
            }
        }
    }

    func reopenCompleted(id: UUID, at date: Date) throws -> Bool { false }
    func delete(id: UUID) throws {}
    func clearHistory(ids: Set<UUID>?) throws -> Int { 0 }
    func fetchTrash() throws -> [TrashedTask] { [] }
    func trashCount() throws -> Int { 0 }
    func restoreTrash(id: UUID, at date: Date) throws -> UUID? { nil }
    func removeTrash(ids: Set<UUID>?) throws -> Int { 0 }
}
