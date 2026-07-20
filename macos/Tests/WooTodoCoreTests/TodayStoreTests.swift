import Foundation
import Testing
@testable import WooTodoCore

@Suite("TodayStore 今日任务管理")
@MainActor
struct TodayStoreTests {
    @Test("快速新增会规范标题并创建今日主线单次任务")
    func quickAddCreatesNormalizedOneTimeTask() throws {
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-17T22:30:00+08:00")
        )
        let engine = PeriodEngine(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let repository = TodayMemoryTaskRepository(tasks: [])
        let store = TodayStore(repository: repository, engine: engine, now: { now })
        var changeCount = 0
        store.onTasksChanged = { changeCount += 1 }

        let didAdd = store.add(
            title: "  写明日计划\n",
            tier: .mainline,
            repeatsDaily: false
        )

        let task = try #require(repository.tasks.only)
        #expect(didAdd)
        #expect(task.title == "写明日计划")
        #expect(task.timeScope == .daily)
        #expect(task.tier == .mainline)
        #expect(task.recurrence == .once)
        #expect(task.status == .pending)
        #expect(task.createdAt == now)
        #expect(changeCount == 1)
    }

    @Test("快速新增空白任务时不写入也不发送变更回调")
    func quickAddRejectsBlankTitle() throws {
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-17T22:30:00+08:00")
        )
        let engine = PeriodEngine(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let repository = TodayMemoryTaskRepository(tasks: [])
        let store = TodayStore(repository: repository, engine: engine, now: { now })
        var changeCount = 0
        store.onTasksChanged = { changeCount += 1 }

        let didAdd = store.add(title: " \n ", tier: .mainline, repeatsDaily: false)

        #expect(!didAdd)
        #expect(repository.tasks.isEmpty)
        #expect(store.errorMessage != nil)
        #expect(changeCount == 0)
    }

    @Test("未预先刷新时按今日周期的现有任务计算排序")
    func quickAddUsesPersistedCurrentPeriodForSortIndex() throws {
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-17T22:30:00+08:00")
        )
        let engine = PeriodEngine(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let today = try #require(engine.period(containing: now, for: .daily))
        let tomorrow = try #require(
            engine.period(containing: today.end.addingTimeInterval(1), for: .daily)
        )
        let currentTask = try TodoTask(
            title: "今日已有任务",
            timeScope: .daily,
            tier: .mainline,
            period: today,
            sortIndex: 4,
            createdAt: now
        )
        let tomorrowTask = try TodoTask(
            title: "明日任务",
            timeScope: .daily,
            tier: .mainline,
            period: tomorrow,
            sortIndex: 99,
            createdAt: now
        )
        let repository = TodayMemoryTaskRepository(tasks: [currentTask, tomorrowTask])
        let store = TodayStore(repository: repository, engine: engine, now: { now })

        let didAdd = store.add(title: "今日新增任务", tier: .mainline, repeatsDaily: false)

        let added = try #require(repository.tasks.first { $0.title == "今日新增任务" })
        #expect(didAdd)
        #expect(added.period == today)
        #expect(added.sortIndex == 5)
    }

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

private extension Array {
    var only: Element? { count == 1 ? first : nil }
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
