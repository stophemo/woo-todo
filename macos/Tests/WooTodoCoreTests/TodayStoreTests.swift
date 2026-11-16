import Foundation
import Testing
@testable import WooTodoCore

@Suite("TodayStore 今日任务管理")
@MainActor
struct TodayStoreTests {
    @Test("快速新增创建未分类无日期任务")
    func quickAddCreatesUndatedInboxTask() throws {
        let now = date("2026-07-17T22:30:00+08:00")
        let repository = TodayMemoryRepository()
        let store = TodayStore(repository: repository, now: { now })
        var changeCount = 0
        store.onTasksChanged = { changeCount += 1 }

        let didAdd = store.add(title: "  写明日计划\n")

        let task = try #require(repository.tasks.only)
        #expect(didAdd)
        #expect(task.title == "写明日计划")
        #expect(task.categoryID == TaskCategory.inboxID)
        #expect(task.startDate == nil)
        #expect(task.endDate == nil)
        #expect(task.status == .pending)
        #expect(task.createdAt == now)
        #expect(changeCount == 1)
    }

    @Test("面板内删除类型会把待办归入未分类")
    func updateCategoriesReassignsRemovedCategory() throws {
        let now = date("2026-07-17T22:30:00+08:00")
        let work = try TaskCategory(id: "work", name: "工作", order: 1)
        let repository = TodayMemoryRepository()
        repository.categories = TaskCategory.normalizeList(
            TaskCategory.defaults + [work]
        )
        repository.tasks = [
            try TodoTask(
                title: "工作待办",
                categoryID: work.id,
                createdAt: now
            ),
        ]
        let store = TodayStore(repository: repository, now: { now })
        var changeCount = 0
        store.onTasksChanged = { changeCount += 1 }
        store.reload()

        let updated = store.updateCategories(TaskCategory.defaults)

        #expect(updated.map(\.id) == [TaskCategory.inboxID])
        #expect(store.categories.map(\.id) == [TaskCategory.inboxID])
        #expect(repository.tasks.first?.categoryID == TaskCategory.inboxID)
        #expect(repository.categories.map(\.id) == [TaskCategory.inboxID])
        #expect(changeCount == 1)
    }

    @Test("今日任务按标签优先级排列")
    func tasksFollowCategoryPriority() throws {
        let now = date("2026-07-17T10:00:00+08:00")
        let life = try TaskCategory(id: "life", name: "生活", order: 0)
        let work = try TaskCategory(id: "work", name: "工作", order: 1)
        let inbox = try TaskCategory(
            id: TaskCategory.inboxID,
            name: "未分类",
            order: 2
        )
        let repository = TodayMemoryRepository(tasks: [
            try TodoTask(title: "低优先级", categoryID: work.id, createdAt: now),
            try TodoTask(title: "高优先级", categoryID: life.id, createdAt: now),
        ])
        repository.categories = [life, work, inbox]
        let store = TodayStore(repository: repository, now: { now })

        store.reload()

        #expect(store.categories.map(\.id) == ["life", "work", "inbox"])
        #expect(store.tasks.map(\.title) == ["高优先级", "低优先级"])
    }

    @Test("按名称添加标签会复用已有名称或创建新标签")
    func addCategoryByNameMatchesOrCreates() throws {
        let now = date("2026-07-17T22:30:00+08:00")
        let work = try TaskCategory(id: "work", name: "工作", order: 1)
        let repository = TodayMemoryRepository()
        repository.categories = TaskCategory.normalizeList(
            TaskCategory.defaults + [work]
        )
        let store = TodayStore(repository: repository, now: { now })
        store.reload()

        let existing = store.addCategory(named: " 工作 ")
        #expect(existing?.id == work.id)

        let created = try #require(store.addCategory(named: "学习"))
        #expect(created.name == "学习")
        #expect(store.categories.contains(where: { $0.id == created.id }))
        #expect(repository.categories.contains(where: { $0.id == created.id }))
    }

    @Test("按名称添加标签在达到上限时失败")
    func addCategoryByNameRejectsLimit() throws {
        let now = date("2026-07-17T22:30:00+08:00")
        let repository = TodayMemoryRepository()
        repository.categories = TaskCategory.normalizeList(
            (1...7).map { index in
                try! TaskCategory(id: "c\(index)", name: "标签\(index)", order: index)
            }
        )
        let store = TodayStore(repository: repository, now: { now })
        store.reload()

        #expect(store.addCategory(named: "新标签") == nil)
        #expect(store.errorMessage == TaskValidationError.categoryLimitReached.localizedDescription)
        #expect(repository.categories.count == 8)
    }

    @Test("按名称添加标签不会改动既有待办的标签")
    func addCategoryByNameKeepsPendingAssignments() throws {
        let now = date("2026-07-17T22:30:00+08:00")
        let work = try TaskCategory(id: "work", name: "工作", order: 1)
        let repository = TodayMemoryRepository(tasks: [
            try TodoTask(title: "工作待办", categoryID: work.id, createdAt: now),
        ])
        repository.categories = TaskCategory.normalizeList(
            TaskCategory.defaults + [work]
        )
        let store = TodayStore(repository: repository, now: { now })
        store.reload()

        _ = try #require(store.addCategory(named: "学习"))

        #expect(repository.tasks.first?.categoryID == work.id)
        #expect(repository.categories.count == 3)
        #expect(repository.categories.contains(where: { $0.id == "inbox" }))
        #expect(repository.categories.contains(where: { $0.id == "work" }))
    }

    @Test("快速新增空白任务时不写入也不发送变更回调")
    func quickAddRejectsBlankTitle() throws {
        let now = date("2026-07-17T22:30:00+08:00")
        let repository = TodayMemoryRepository()
        let store = TodayStore(repository: repository, now: { now })
        var changeCount = 0
        store.onTasksChanged = { changeCount += 1 }

        let didAdd = store.add(title: " \n ")

        #expect(!didAdd)
        #expect(repository.tasks.isEmpty)
        #expect(store.errorMessage != nil)
        #expect(changeCount == 0)
    }

    @Test("面板只显示逾期、今天、无日期和今天结算任务")
    func reloadFiltersRelevantTasks() throws {
        let now = date("2026-07-18T10:00:00+08:00")
        let overdue = try TodoTask(
            title: "逾期",
            categoryID: "main",
            startDate: date("2026-07-16"),
            endDate: date("2026-07-17")
        )
        let active = try TodoTask(
            title: "进行中",
            categoryID: "main",
            startDate: date("2026-07-18"),
            endDate: date("2026-07-20")
        )
        let undated = try TodoTask(title: "无日期", categoryID: "inbox")
        let future = try TodoTask(
            title: "未来",
            categoryID: "main",
            startDate: date("2026-07-20"),
            endDate: date("2026-07-21")
        )
        var completedToday = try TodoTask(
            title: "今天完成",
            categoryID: "side",
            startDate: date("2026-07-18"),
            endDate: date("2026-07-18")
        )
        completedToday.status = .completed
        completedToday.completedAt = now
        var completedYesterday = try TodoTask(
            title: "昨天完成",
            categoryID: "side",
            startDate: date("2026-07-17"),
            endDate: date("2026-07-17")
        )
        completedYesterday.status = .completed
        completedYesterday.completedAt = date("2026-07-17T10:00:00+08:00")
        let repository = TodayMemoryRepository(tasks: [
            overdue, active, undated, future, completedToday, completedYesterday,
        ])
        let store = TodayStore(repository: repository, now: { now })

        store.reload()

        #expect(Set(store.tasks.map(\.id)) == [
            overdue.id, active.id, undated.id, completedToday.id,
        ])
    }

    @Test("完成和撤销完成会更新面板")
    func toggleCompletionUpdatesTasks() throws {
        let now = date("2026-07-17T10:00:00+08:00")
        let task = try TodoTask(title: "误点完成", categoryID: "main", createdAt: now)
        let repository = TodayMemoryRepository(tasks: [task])
        let store = TodayStore(repository: repository, now: { now })
        var changeCount = 0
        store.onTasksChanged = { changeCount += 1 }
        store.reload()

        store.toggleCompletion(id: task.id)
        #expect(repository.tasks.only?.status == .completed)
        #expect(repository.tasks.only?.completedAt == now)
        #expect(changeCount == 1)

        store.toggleCompletion(id: task.id)
        #expect(repository.tasks.only?.status == .pending)
        #expect(repository.tasks.only?.completedAt == nil)
        #expect(changeCount == 2)
    }

    @Test("编辑日期范围会移入或移出面板")
    func editDateRangeMovesTaskInAndOut() throws {
        let now = date("2026-07-17T10:00:00+08:00")
        let task = try TodoTask(title: "安排今天", categoryID: "main", createdAt: now)
        let repository = TodayMemoryRepository(tasks: [task])
        let store = TodayStore(repository: repository, now: { now })
        store.reload()
        #expect(store.tasks.map(\.id) == [task.id])

        store.edit(
            id: task.id,
            title: "安排今天",
            categoryID: "main",
            startDate: date("2026-07-17"),
            endDate: date("2026-07-17"),
            reminderTime: nil
        )
        #expect(store.tasks.map(\.id) == [task.id])

        store.edit(
            id: task.id,
            title: "安排未来",
            categoryID: "main",
            startDate: date("2026-07-20"),
            endDate: date("2026-07-20"),
            reminderTime: nil
        )
        #expect(store.tasks.isEmpty)
        #expect(repository.tasks.only?.startDate == date("2026-07-20"))
    }

    @Test("新增排序值取现有最大值加一")
    func quickAddUsesPersistedMaxSortIndex() throws {
        let now = date("2026-07-17T22:30:00+08:00")
        let existing = try TodoTask(
            title: "已有任务",
            categoryID: "main",
            sortIndex: 4,
            createdAt: now
        )
        let repository = TodayMemoryRepository(tasks: [existing])
        let store = TodayStore(repository: repository, now: { now })

        let didAdd = store.add(title: "新增任务")

        let added = try #require(repository.tasks.first { $0.title == "新增任务" })
        #expect(didAdd)
        #expect(added.sortIndex == 5)
    }

    @Test("放弃后任务以已结算状态留在今天")
    func passKeepsTaskAsSettledToday() throws {
        let now = date("2026-07-18T10:00:00+08:00")
        let task = try TodoTask(
            title: "昨日未完成",
            categoryID: "main",
            startDate: date("2026-07-17"),
            endDate: date("2026-07-17")
        )
        let repository = TodayMemoryRepository(tasks: [task])
        let store = TodayStore(repository: repository, now: { now })
        store.reload()
        #expect(store.tasks.map(\.id) == [task.id])

        store.pass(id: task.id)

        #expect(store.tasks.only?.status == .pass)
        #expect(repository.tasks.only?.status == .pass)
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

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private final class TodayMemoryRepository: TaskRepository {
    var tasks: [TodoTask]
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
        tasks.removeAll { $0.id == id }
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
