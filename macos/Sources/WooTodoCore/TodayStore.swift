import Combine
import Foundation

@MainActor
public final class TodayStore: ObservableObject {
    @Published public private(set) var tasks: [TodoTask] = []
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
            tasks = try repository.fetchAll()
                .filter {
                    TaskDateState.isRelevant($0, on: date) ||
                        TaskDateState.isSettled($0, on: date)
                }
                .sorted(by: dashboardOrder)
        }
    }

    /// 返回任务是否已写入本地仓储；写入后的列表刷新失败不会反转已完成的写入。
    @discardableResult
    public func add(
        title: String,
        categoryID: String = TaskCategory.inboxID,
        startDate: Date? = nil,
        endDate: Date? = nil,
        reminderTime: TaskReminderTime? = nil
    ) -> Bool {
        let didAdd = perform {
            let date = now()
            let task = try TodoTask(
                title: title,
                categoryID: resolvedCategory(categoryID),
                startDate: startDate,
                endDate: endDate,
                sortIndex: nextSortIndex(),
                createdAt: date,
                reminderTime: reminderTime
            )
            try repository.save(task)
        }
        if didAdd {
            reload()
            onTasksChanged?()
        }
        return didAdd
    }

    public func edit(
        id: UUID,
        title: String,
        categoryID: String,
        startDate: Date?,
        endDate: Date?,
        reminderTime: TaskReminderTime?
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
                completedAt: existing.completedAt
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

    /// 仅供面板内编辑器管理类型；删除类型时待办归入未分类，历史保留原类型。
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
