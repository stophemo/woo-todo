import Foundation
import Testing
@testable import WooTodoCore

@Suite("TodayStore 今日任务管理")
@MainActor
struct TodayStoreTests {
    @Test("同组已有完成项时仍可拖动剩余待办")
    func pendingTasksRemainReorderableAfterCompletion() throws {
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-17T10:00:00+08:00")
        )
        let engine = PeriodEngine(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let period = try #require(engine.period(containing: now, for: .daily))
        let first = try TodoTask(
            title: "先做",
            timeScope: .daily,
            tier: .mainline,
            period: period,
            sortIndex: 0,
            createdAt: now
        )
        var completed = try TodoTask(
            title: "已完成",
            timeScope: .daily,
            tier: .mainline,
            period: period,
            sortIndex: 1,
            createdAt: now.addingTimeInterval(1)
        )
        completed.status = .completed
        completed.completedAt = now
        let last = try TodoTask(
            title: "后做",
            timeScope: .daily,
            tier: .mainline,
            period: period,
            sortIndex: 2,
            createdAt: now.addingTimeInterval(2)
        )
        let repository = TodayMemoryTaskRepository(tasks: [first, completed, last])
        let store = TodayStore(repository: repository, engine: engine, now: { now })
        store.reload()

        store.move(tier: .mainline, fromOffsets: IndexSet(integer: 1), toOffset: 0)

        let pending = repository.tasks
            .filter { $0.status == .pending }
            .sorted(by: TodoTask.displayOrder)
        #expect(pending.map(\.title) == ["后做", "先做"])
        #expect(repository.tasks.first { $0.id == completed.id }?.status == .completed)
    }
}

private final class TodayMemoryTaskRepository: TaskRepository {
    var tasks: [TodoTask]

    init(tasks: [TodoTask]) {
        self.tasks = tasks
    }

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
