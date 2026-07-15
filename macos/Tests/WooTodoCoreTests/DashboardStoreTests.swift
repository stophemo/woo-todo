import Foundation
import Testing
@testable import WooTodoCore

@Suite("DashboardStore 本地管理")
@MainActor
struct DashboardStoreTests {
    @Test("创建和编辑任务会遵守自身时间类型")
    func createAndEditAcrossScopes() throws {
        let repository = MemoryTaskRepository()
        let now = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00+08:00")!
        let store = DashboardStore(repository: repository, now: { now })

        store.add(
            title: "完成周目标",
            scope: .weekly,
            targetDate: now,
            tier: .mainline,
            repeats: true
        )
        let weekly = try #require(repository.tasks.first)
        #expect(weekly.timeScope == .weekly)
        #expect(weekly.period?.contains(now) == true)
        #expect(weekly.recurrence == .repeating(RepeatRule(frequency: .weekly)))
        #expect(store.tasks(for: .weekly).map(\.id) == [weekly.id])

        store.edit(
            id: weekly.id,
            title: "有空再完成",
            scope: .anytime,
            targetDate: now,
            tier: .extra,
            repeats: true
        )
        let someday = try #require(repository.tasks.first)
        #expect(someday.title == "有空再完成")
        #expect(someday.timeScope == .anytime)
        #expect(someday.period == nil)
        #expect(someday.recurrence == .once)
    }
}

private final class MemoryTaskRepository: TaskRepository {
    var tasks: [TodoTask] = []

    func fetchAll() throws -> [TodoTask] { tasks }

    func fetchTasks(scope: TimeScope, in period: TaskPeriod?) throws -> [TodoTask] {
        tasks.filter { task in
            guard task.timeScope == scope else { return false }
            guard let period else { return true }
            guard let taskPeriod = task.period else { return false }
            return taskPeriod.start < period.end && taskPeriod.end > period.start
        }
    }

    func save(_ updated: [TodoTask]) throws {
        for task in updated {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            } else {
                tasks.append(task)
            }
        }
    }

    func delete(id: UUID) throws {
        tasks.removeAll { $0.id == id }
    }
}
