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

    @Test("过期一次性任务仅在完成当天留在当前列表")
    func completedOverdueOnceRemainsVisibleForCurrentDay() throws {
        let engine = PeriodEngine(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let now = ISO8601DateFormatter().date(from: "2026-07-18T10:00:00+08:00")!
        let yesterday = try #require(
            engine.period(containing: now.addingTimeInterval(-86_400), for: .daily)
        )
        var completedToday = try TodoTask(
            title: "今日完成的逾期任务",
            timeScope: .daily,
            tier: .mainline,
            period: yesterday,
            createdAt: yesterday.start
        )
        completedToday.status = .completed
        completedToday.completedAt = now.addingTimeInterval(-60)
        var completedYesterday = try TodoTask(
            title: "昨日已完成",
            timeScope: .daily,
            tier: .mainline,
            period: yesterday,
            createdAt: yesterday.start.addingTimeInterval(1)
        )
        completedYesterday.status = .completed
        completedYesterday.completedAt = yesterday.start.addingTimeInterval(60)
        let repository = MemoryTaskRepository()
        repository.tasks = [completedToday, completedYesterday]
        let store = DashboardStore(repository: repository, engine: engine, now: { now })

        store.reload()

        #expect(store.tasks(for: .daily).map(\.id) == [completedToday.id])
    }
}

private final class MemoryTaskRepository: TaskRepository {
    var tasks: [TodoTask] = []

    func fetchAll() throws -> [TodoTask] { tasks }

    func fetchTasks(
        scope: TimeScope,
        in period: TaskPeriod?,
        includeOverdueOnce: Bool
    ) throws -> [TodoTask] {
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

    func reopenCompleted(id: UUID, at date: Date) throws -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].status == .completed,
              (tasks[index].period?.end ?? .distantFuture) > date else { return false }
        tasks[index].status = .pending
        tasks[index].completedAt = nil
        tasks[index].updatedAt = date
        return true
    }

    func delete(id: UUID) throws {
        tasks.removeAll { $0.id == id }
    }
}
