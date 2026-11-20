import Combine
import Foundation

@MainActor
public final class TodayStore: ObservableObject {
    @Published public private(set) var tasks: [TodoTask] = []
    @Published public private(set) var upcomingTasks: [TodoTask] = []
    @Published public private(set) var categories: [TaskCategory] = TaskCategory.defaults
    @Published public private(set) var errorMessage: String?

    public var onTasksChanged: (() -> Void)?

    private let repository: TaskRepository
    private let now: () -> Date

    public init(repository: TaskRepository, now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.now = now
    }

    public func reload() {
        perform {
            let date = now()
            categories = TaskCategory.normalizeList(try repository.fetchCategories())
            let allTasks = try repository.fetchAll()
            tasks = allTasks
                .filter {
                    TaskDateState.isRelevant($0, on: date) ||
                        TaskDateState.isSettled($0, on: date)
                }
                .sorted(by: dashboardOrder)
            let today = TodoTask.protocolCalendar.startOfDay(for: date)
            upcomingTasks = allTasks
                .filter { task in
                    task.status == .pending
                        && task.startDate.map {
                            TodoTask.protocolCalendar.startOfDay(for: $0) > today
                        } == true
                }
                .sorted {
                    let left = $0.startDate ?? .distantFuture
                    let right = $1.startDate ?? .distantFuture
                    if left != right { return left < right }
                    return TodoTask.displayOrder($0, $1)
                }
        }
    }

    /// 返回任务是否已写入本地仓储；写入后的列表刷新失败不会反转已完成的写入。
    @discardableResult
    public func add(
        title: String,
        categoryID: String = TaskCategory.inboxID,
        startDate: Date? = nil,
        endDate: Date? = nil,
        reminderTime: TaskReminderTime? = nil,
        recurrence: TaskRecurrence = .once
    ) -> Bool {
        addTask(
            title: title,
            categoryID: categoryID,
            startDate: startDate,
            endDate: endDate,
            reminderTime: reminderTime,
            recurrence: recurrence
        ) != nil
    }

    /// 与 add 相同，但把写入的任务返回给调用方，便于本机 MCP 服务回传任务标识。
    @discardableResult
    public func addTask(
        title: String,
        categoryID: String = TaskCategory.inboxID,
        startDate: Date? = nil,
        endDate: Date? = nil,
        reminderTime: TaskReminderTime? = nil,
        recurrence: TaskRecurrence = .once
    ) -> TodoTask? {
        var created: TodoTask?
        let didAdd = perform {
            let date = now()
            let task = try TodoTask(
                title: title,
                categoryID: resolvedCategory(categoryID),
                startDate: startDate,
                endDate: endDate,
                sortIndex: nextSortIndex(),
                createdAt: date,
                reminderTime: reminderTime,
                recurrence: recurrence
            )
            try repository.save(task)
            created = task
        }
        if didAdd {
            reload()
            onTasksChanged?()
        }
        return didAdd ? created : nil
    }

    public func edit(
        id: UUID,
        title: String,
        categoryID: String,
        startDate: Date?,
        endDate: Date?,
        reminderTime: TaskReminderTime?,
        recurrence: TaskRecurrence = .once
    ) {
        guard tasks.first(where: { $0.id == id })?.status == .pending else { return }
        if perform({
            guard let existing = tasks.first(where: { $0.id == id }) else { return }
            let replacement = try TodoTask(
                id: existing.id,
                seriesID: existing.seriesID,
                title: title,
                categoryID: resolvedCategory(categoryID),
                status: existing.status,
                startDate: startDate,
                endDate: endDate,
                sortIndex: existing.sortIndex,
                createdAt: existing.createdAt,
                updatedAt: now(),
                reminderTime: reminderTime,
                completedAt: existing.completedAt,
                recurrence: recurrence
            )
            try repository.save(replacement)
            reload()
        }) {
            onTasksChanged?()
        }
    }

    public func toggleCompletion(id: UUID) {
        guard let current = tasks.first(where: { $0.id == id }),
              current.status != .pass else { return }
        var didChange = false
        if perform({
            let date = now()
            switch current.status {
            case .pending:
                var task = current
                task.status = .completed
                task.completedAt = date
                task.updatedAt = date
                try repository.save(task)
                didChange = true
            case .completed:
                didChange = try repository.reopenCompleted(id: id, at: date)
            case .pass:
                break
            }
            if didChange { reload() }
        }), didChange {
            onTasksChanged?()
        }
    }

    public func pass(id: UUID) {
        guard var task = tasks.first(where: { $0.id == id }),
              task.status == .pending else { return }
        if perform({
            let date = now()
            task.status = .pass
            task.completedAt = date
            task.updatedAt = date
            try repository.save(task)
            reload()
        }) {
            onTasksChanged?()
        }
    }

    /// 按输入名称查找或创建标签，不改动已有待办的标签归属。
    @discardableResult
    public func addCategory(named name: String) -> TaskCategory? {
        var result: TaskCategory?
        var didCreate = false
        if perform({
            let normalized = try TaskCategory.normalizeName(name)
            if let existing = categories.first(where: {
                $0.name.compare(
                    normalized,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }) {
                result = existing
                return
            }
            guard categories.count < TaskCategory.maximumCount else {
                throw TaskValidationError.categoryLimitReached
            }
            let category = try TaskCategory(
                id: TaskCategory.newID(existing: Set(categories.map(\.id))),
                name: normalized,
                order: categories.count
            )
            try repository.saveCategories(
                TaskCategory.normalizeList(categories + [category])
            )
            result = category
            didCreate = true
        }), didCreate {
            reload()
            onTasksChanged?()
        }
        return result
    }

    /// 仅供面板内编辑器管理标签；删除标签时待办归入未分类，历史保留原标签。
    @discardableResult
    public func updateCategories(_ categories: [TaskCategory]) -> [TaskCategory] {
        let normalized = TaskCategory.normalizeList(categories)
        if perform({
            let date = now()
            let known = Set(normalized.map(\.id))
            for category in self.categories where !known.contains(category.id) {
                _ = try repository.reassignPendingCategory(
                    from: category.id,
                    to: TaskCategory.inboxID,
                    at: date
                )
            }
            try repository.saveCategories(normalized)
            reload()
        }) {
            onTasksChanged?()
        }
        return normalized
    }

    /// 结算每天重复任务：过期未完成的上一条记为已放弃，并生成下一条。
    /// 多次调用、跨设备调用都依赖确定性 occurrence id 保持幂等。
    @discardableResult
    public func settleRecurringTasks() -> Bool {
        let date = now()
        var didChange = false
        let didSettle = perform {
            let allTasks = try repository.fetchAll()
            let deleted = try repository.deletedTaskIDs()
            let settlement = RecurringTaskSettler.settle(
                tasks: allTasks,
                today: date,
                now: date,
                deletedTaskIDs: deleted
            )
            if !settlement.isEmpty {
                try repository.save(
                    settlement.updatedTasks + settlement.createdTasks
                )
                didChange = true
            }
            reload()
        }
        if didSettle, didChange {
            onTasksChanged?()
        }
        return didChange
    }

    public func delete(id: UUID) {
        guard tasks.first(where: { $0.id == id })?.status == .pending else { return }
        if perform({
            try repository.delete(id: id)
            reload()
        }) {
            onTasksChanged?()
        }
    }

    @discardableResult
    private func perform(_ action: () throws -> Void) -> Bool {
        do {
            errorMessage = nil
            try action()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func resolvedCategory(_ categoryID: String) -> String {
        categories.contains(where: { $0.id == categoryID })
            ? categoryID
            : TaskCategory.inboxID
    }

    private func nextSortIndex() -> Int {
        let persisted = (try? repository.fetchAll())?.map(\.sortIndex).max() ?? -1
        return max(persisted, tasks.map(\.sortIndex).max() ?? -1) + 1
    }

    private func dashboardOrder(_ lhs: TodoTask, _ rhs: TodoTask) -> Bool {
        let lhsOrder = categories.first(where: { $0.id == lhs.categoryID })?.order ?? Int.max
        let rhsOrder = categories.first(where: { $0.id == rhs.categoryID })?.order ?? Int.max
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        let lhsEnd = lhs.endDate ?? .distantFuture
        let rhsEnd = rhs.endDate ?? .distantFuture
        if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
        return TodoTask.displayOrder(lhs, rhs)
    }
}
