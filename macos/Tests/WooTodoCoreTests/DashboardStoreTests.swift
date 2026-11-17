import Foundation
import Testing
@testable import WooTodoCore

@Suite("DashboardStore 本地管理")
@MainActor
struct DashboardStoreTests {
    @Test("创建和编辑任务使用类型与起止日期")
    func createAndEditTask() throws {
        let repository = DashboardMemoryRepository()
        let now = date("2026-07-15T12:00:00+08:00")
        let store = DashboardStore(repository: repository, now: { now })
        store.reload()

        store.add(
            title: "完成周目标",
            categoryID: "main",
            startDate: date("2026-07-13"),
            endDate: date("2026-07-19")
        )
        let created = try #require(repository.tasks.first)
        #expect(created.title == "完成周目标")
        #expect(created.categoryID == "main")
        #expect(created.startDate == date("2026-07-13"))
        #expect(created.endDate == date("2026-07-19"))
        #expect(created.status == .pending)

        store.edit(
            id: created.id,
            title: "有空再完成",
            categoryID: "extra",
            startDate: nil,
            endDate: nil,
            reminderTime: nil
        )
        let edited = try #require(repository.tasks.first)
        #expect(edited.title == "有空再完成")
        #expect(edited.categoryID == "extra")
        #expect(edited.startDate == nil)
        #expect(edited.endDate == nil)
    }

    @Test("列表分组包含逾期、今天、未安排和今天完成")
    func sectionsGroupTasks() throws {
        let now = date("2026-07-15T12:00:00+08:00")
        let overdue = try TodoTask(
            title: "逾期",
            categoryID: "main",
            startDate: date("2026-07-10"),
            endDate: date("2026-07-12")
        )
        let today = try TodoTask(
            title: "今天",
            categoryID: "main",
            startDate: date("2026-07-15"),
            endDate: date("2026-07-15")
        )
        let unscheduled = try TodoTask(title: "未安排", categoryID: "inbox")
        var completedToday = try TodoTask(
            title: "今天完成",
            categoryID: "side",
            startDate: date("2026-07-14"),
            endDate: date("2026-07-14")
        )
        completedToday.status = .completed
        completedToday.completedAt = now
        var completedYesterday = try TodoTask(
            title: "昨天完成",
            categoryID: "side",
            startDate: date("2026-07-14"),
            endDate: date("2026-07-14")
        )
        completedYesterday.status = .completed
        completedYesterday.completedAt = date("2026-07-14T10:00:00+08:00")
        let repository = DashboardMemoryRepository(tasks: [
            overdue, today, unscheduled, completedToday, completedYesterday,
        ])
        let store = DashboardStore(repository: repository, now: { now })

        store.reload()

        #expect(store.sections.map(\.kind) == [.overdue, .today, .unscheduled, .settledToday])
        #expect(store.sections[0].tasks.map(\.id) == [overdue.id])
        #expect(store.sections[1].tasks.map(\.id) == [today.id])
        #expect(store.sections[2].tasks.map(\.id) == [unscheduled.id])
        #expect(store.sections[3].tasks.map(\.id) == [completedToday.id])
    }

    @Test("统计只在需要时计算")
    func statisticsLoadLazily() throws {
        let now = date("2026-07-18T10:00:00+08:00")
        let task = try TodoTask(title: "待办", categoryID: "main", createdAt: now)
        let repository = DashboardMemoryRepository(tasks: [task])
        let store = DashboardStore(repository: repository, now: { now })

        store.reload()
        #expect(store.statistics == .empty)
        store.reloadStatisticsIfNeeded()
        #expect(store.statistics.pendingCount == 1)
    }

    @Test("移除最近删除副本不会广播任务变更")
    func removingTrashDoesNotBroadcastTasksChanged() throws {
        let task = try TodoTask(title: "副本", categoryID: "main")
        let repository = DashboardMemoryRepository(tasks: [task])
        let store = DashboardStore(repository: repository)
        store.reload()
        store.delete(id: task.id)
        store.reloadTrash()

        var changes = 0
        store.onTasksChanged = { changes += 1 }
        store.removeTrash(ids: [task.id])
        #expect(store.trashedTasks.isEmpty)
        #expect(changes == 0)
    }

    @Test("删除待办会进入最近删除并可恢复为新任务")
    func deleteAndRestoreTrash() throws {
        let now = date("2026-07-18T10:00:00+08:00")
        let task = try TodoTask(title: "误删", categoryID: "main", createdAt: now)
        let repository = DashboardMemoryRepository(tasks: [task])
        let store = DashboardStore(repository: repository, now: { now })
        store.reload()

        store.delete(id: task.id)
        #expect(store.allTasks.isEmpty)
        #expect(store.trashedCount == 1)
        store.reloadTrash()
        #expect(store.trashedTasks.map(\.task.id) == [task.id])
        #expect(store.trashedCount == 1)

        store.restoreTrash(id: task.id)
        let restored = try #require(store.allTasks.first)
        #expect(restored.id != task.id)
        #expect(restored.title == task.title)
        #expect(store.trashedTasks.isEmpty)
        #expect(store.trashedCount == 0)
    }

    @Test("可以多选清除历史且保留待办")
    func clearSelectedHistory() throws {
        let now = date("2026-07-18T10:00:00+08:00")
        var completed = try TodoTask(title: "已完成", categoryID: "main", createdAt: now)
        completed.status = .completed
        completed.completedAt = now
        let pending = try TodoTask(title: "待办", categoryID: "side", createdAt: now)
        let repository = DashboardMemoryRepository(tasks: [completed, pending])
        let store = DashboardStore(repository: repository, now: { now })
        store.reload()

        store.clearHistory(ids: [completed.id, pending.id])
        store.clearHistory(ids: [completed.id])

        #expect(repository.tasks.map(\.id) == [pending.id])
        #expect(store.history.isEmpty)
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

private final class DashboardMemoryRepository: TaskRepository {
    var tasks: [TodoTask]
    var trash: [TrashedTask] = []
    var categories: [TaskCategory] = TaskCategory.normalizeList(
        TaskCategory.defaults + [
            try! TaskCategory(id: "main", name: "主线", order: 1),
            try! TaskCategory(id: "side", name: "支线", order: 2),
            try! TaskCategory(id: "extra", name: "外传", order: 3),
        ]
    )

    init(tasks: [TodoTask] = []) {
        self.tasks = tasks
    }

    func fetchAll() throws -> [TodoTask] { tasks }

    func save(_ updated: [TodoTask]) throws {
        for task in updated {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            } else {
                tasks.append(task)
            }
        }
    }

    func reopenCompleted(id: UUID, at date: Date) throws -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].status == .completed else { return false }
        tasks[index].status = .pending
        tasks[index].completedAt = nil
        tasks[index].updatedAt = date
        return true
    }

    func delete(id: UUID) throws {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        tasks.removeAll { $0.id == id }
        trash.append(TrashedTask(task: task, deletedAt: Date()))
    }

    func fetchTrash() throws -> [TrashedTask] { trash }

    func trashCount() throws -> Int { trash.count }

    @discardableResult
    func restoreTrash(id: UUID, at date: Date) throws -> UUID? {
        guard let index = trash.firstIndex(where: { $0.task.id == id }) else { return nil }
        let snapshot = trash.remove(at: index)
        let restored = try TodoTask(
            id: UUID(),
            seriesID: snapshot.task.seriesID,
            title: snapshot.task.title,
            categoryID: snapshot.task.categoryID,
            startDate: snapshot.task.startDate,
            endDate: snapshot.task.endDate,
            sortIndex: snapshot.task.sortIndex,
            createdAt: snapshot.task.createdAt,
            updatedAt: date,
            reminderTime: snapshot.task.reminderTime
        )
        tasks.append(restored)
        return restored.id
    }

    @discardableResult
    func removeTrash(ids: Set<UUID>?) throws -> Int {
        let before = trash.count
        trash.removeAll { ids == nil || ids?.contains($0.task.id) == true }
        return before - trash.count
    }

    func clearHistory(ids: Set<UUID>?) throws -> Int {
        let before = tasks.count
        tasks.removeAll { task in
            task.status != .pending && (ids == nil || ids?.contains(task.id) == true)
        }
        return before - tasks.count
    }

    func fetchCategories() throws -> [TaskCategory] { categories }

    func saveCategories(_ categories: [TaskCategory]) throws {
        self.categories = categories
    }

    @discardableResult
    func reassignPendingCategory(
        from: String,
        to: String,
        at date: Date
    ) throws -> Int {
        var count = 0
        for index in tasks.indices where tasks[index].status == .pending &&
            tasks[index].categoryID == from {
            tasks[index].categoryID = to
            tasks[index].updatedAt = date
            count += 1
        }
        return count
    }
}
