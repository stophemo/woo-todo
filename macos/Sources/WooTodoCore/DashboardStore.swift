import Combine
import Foundation

@MainActor
public final class DashboardStore: ObservableObject {
    @Published public private(set) var allTasks: [TodoTask] = []
    @Published public private(set) var categories: [TaskCategory] = TaskCategory.defaults
    @Published public private(set) var statistics: StatisticsSnapshot = .empty
    @Published public private(set) var trashedTasks: [TrashedTask] = []
    @Published public private(set) var trashedCount = 0
    @Published public private(set) var referenceDate = Date()
    @Published public private(set) var errorMessage: String?

    private var hasLoadedTrash = false
    private var statisticsDirty = true

    public var onTasksChanged: (() -> Void)?

    private let repository: TaskRepository
    private let statisticsEngine: StatisticsEngine
    private let now: () -> Date

    public init(
        repository: TaskRepository,
        statisticsEngine: StatisticsEngine = StatisticsEngine(),
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.statisticsEngine = statisticsEngine
        self.now = now
    }

    public var sections: [TaskListSection] {
        TaskListPresenter.sections(
            tasks: allTasks,
            categories: categories,
            on: referenceDate
        )
    }

    public var recentHistory: [TodoTask] { statistics.recentHistory }

    public var history: [TodoTask] {
        allTasks
            .filter { $0.status == .completed || $0.status == .pass }
            .sorted { lhs, rhs in
                let lhsDate = lhs.completedAt ?? lhs.updatedAt
                let rhsDate = rhs.completedAt ?? rhs.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func categoryName(for id: String) -> String {
        TaskCategory.resolveName(id: id, categories: categories)
    }

    public func reload() {
        do {
            errorMessage = nil
            let hasLoadedStatistics = !statisticsDirty
            let date = now()
            let loaded = try repository.fetchAll()
            allTasks = loaded
            categories = TaskCategory.normalizeList(try repository.fetchCategories())
            referenceDate = date
            trashedCount = (try? repository.trashCount()) ?? trashedCount
            // 统计只在用户打开过统计页后才计算；第一次打开前不产生趋势与分布开销。
            statisticsDirty = true
            if hasLoadedStatistics {
                reloadStatisticsIfNeeded()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func reloadStatisticsIfNeeded() {
        guard statisticsDirty else { return }
        statistics = statisticsEngine.calculate(tasks: allTasks, at: referenceDate)
        statisticsDirty = false
    }

    public func reloadTrash() {
        do {
            errorMessage = nil
            hasLoadedTrash = true
            trashedTasks = try repository.fetchTrash()
            trashedCount = trashedTasks.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restoreTrash(id: UUID) {
        do {
            errorMessage = nil
            let restoredID = try repository.restoreTrash(id: id, at: now())
            reload()
            if restoredID != nil {
                onTasksChanged?()
            }
            if hasLoadedTrash {
                trashedTasks = try repository.fetchTrash()
                trashedCount = trashedTasks.count
            } else {
                trashedCount = (try? repository.trashCount()) ?? trashedCount
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeTrash(ids: Set<UUID>? = nil) {
        do {
            errorMessage = nil
            _ = try repository.removeTrash(ids: ids)
            if hasLoadedTrash {
                trashedTasks = try repository.fetchTrash()
                trashedCount = trashedTasks.count
            } else {
                trashedCount = (try? repository.trashCount()) ?? trashedCount
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func add(
        title: String,
        categoryID: String = TaskCategory.inboxID,
        startDate: Date? = nil,
        endDate: Date? = nil,
        reminderTime: TaskReminderTime? = nil
    ) {
        mutate {
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
    }

    public func edit(
        id: UUID,
        title: String,
        categoryID: String,
        startDate: Date?,
        endDate: Date?,
        reminderTime: TaskReminderTime?
    ) {
        guard allTasks.first(where: { $0.id == id })?.status == .pending else { return }
        mutate {
            guard let existing = allTasks.first(where: { $0.id == id }) else { return }
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
        }
    }

    public func toggleCompletion(id: UUID) {
        guard let current = allTasks.first(where: { $0.id == id }),
              current.status != .pass else { return }
        mutate {
            let date = now()
            switch current.status {
            case .pending:
                var task = current
                task.status = .completed
                task.completedAt = date
                task.updatedAt = date
                try repository.save(task)
            case .completed:
                _ = try repository.reopenCompleted(id: id, at: date)
            case .pass:
                break
            }
        }
    }

    public func delete(id: UUID) {
        guard allTasks.first(where: { $0.id == id })?.status == .pending else { return }
        mutate { try repository.delete(id: id) }
    }

    public func updateCategories(_ categories: [TaskCategory]) {
        let normalized = TaskCategory.normalizeList(categories)
        mutate {
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
        }
    }

    public func clearHistory(ids: Set<UUID>? = nil) {
        let available = Set(history.map(\.id))
        let targets = ids.map { $0.intersection(available) } ?? available
        guard !targets.isEmpty else { return }
        mutate { _ = try repository.clearHistory(ids: targets) }
    }

    public func pass(id: UUID) {
        guard var task = allTasks.first(where: { $0.id == id }),
              task.status == .pending else { return }
        mutate {
            let date = now()
            task.status = .pass
            task.completedAt = date
            task.updatedAt = date
            try repository.save(task)
        }
    }

    private func mutate(_ action: () throws -> Void) {
        do {
            errorMessage = nil
            try action()
            reload()
            onTasksChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolvedCategory(_ categoryID: String) -> String {
        categories.contains(where: { $0.id == categoryID })
            ? categoryID
            : TaskCategory.inboxID
    }

    private func nextSortIndex() -> Int {
        (allTasks.map(\.sortIndex).max() ?? -1) + 1
    }
}
