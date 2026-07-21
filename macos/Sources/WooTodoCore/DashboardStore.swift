import Combine
import Foundation

@MainActor
public final class DashboardStore: ObservableObject {
    @Published public private(set) var statistics: StatisticsSnapshot = .empty
    @Published public private(set) var referenceDate = Date()
    @Published public private(set) var errorMessage: String?
    @Published private var sectionTasks: [TimeScope: [TodoTask]] = [:]

    public var onTasksChanged: (() -> Void)?

    private let repository: TaskRepository
    private let engine: PeriodEngine
    private let statisticsEngine: StatisticsEngine
    private let now: () -> Date
    private var allTasks: [TodoTask] = []

    public init(
        repository: TaskRepository,
        engine: PeriodEngine = PeriodEngine(),
        statisticsEngine: StatisticsEngine = StatisticsEngine(),
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.engine = engine
        self.statisticsEngine = statisticsEngine
        self.now = now
    }

    public var recentHistory: [TodoTask] { statistics.recentHistory }

    public func tasks(for scope: TimeScope) -> [TodoTask] {
        sectionTasks[scope] ?? []
    }

    public func reload() {
        do {
            errorMessage = nil
            let date = now()
            try LazySettlementService(repository: repository, engine: engine).settle(at: date)
            let loaded = try repository.fetchAll()
            allTasks = loaded
            referenceDate = date
            statistics = statisticsEngine.calculate(tasks: loaded, at: date)

            var sections: [TimeScope: [TodoTask]] = [:]
            for scope in TimeScope.allCases {
                let tasks = loaded.filter { task in
                    guard task.timeScope == scope else { return false }
                    if scope == .anytime { return true }
                    return task.period.map { $0.end > date } ?? false
                }
                sections[scope] = tasks.sorted(by: dashboardOrder)
            }
            sectionTasks = sections
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func add(
        title: String,
        scope: TimeScope,
        targetDate: Date,
        tier: QuestTier,
        repeats: Bool,
        reminderTime: TaskReminderTime? = nil
    ) {
        mutate {
            let date = now()
            let period = engine.period(containing: targetDate, for: scope)
            let task = try TodoTask(
                title: title,
                timeScope: scope,
                tier: tier,
                recurrence: recurrence(scope: scope, repeats: repeats),
                period: period,
                sortIndex: nextSortIndex(scope: scope, tier: tier, period: period),
                createdAt: date,
                reminderTime: reminderTime
            )
            try repository.save(task)
        }
    }

    public func edit(
        id: UUID,
        title: String,
        scope: TimeScope,
        targetDate: Date,
        tier: QuestTier,
        repeats: Bool,
        reminderTime: TaskReminderTime? = nil
    ) {
        guard allTasks.first(where: { $0.id == id })?.status == .pending else { return }
        mutate {
            guard let existing = allTasks.first(where: { $0.id == id }) else { return }
            let date = now()
            let period = engine.period(containing: targetDate, for: scope)
            let groupChanged = existing.timeScope != scope
                || existing.tier != tier
                || existing.period != period
            let replacement = try TodoTask(
                id: existing.id,
                seriesID: existing.seriesID,
                title: title,
                timeScope: scope,
                tier: tier,
                status: existing.status,
                recurrence: recurrence(scope: scope, repeats: repeats),
                period: period,
                sortIndex: groupChanged
                    ? nextSortIndex(scope: scope, tier: tier, period: period)
                    : existing.sortIndex,
                createdAt: existing.createdAt,
                updatedAt: date,
                reminderTime: reminderTime,
                completedAt: existing.completedAt
            )
            try repository.save(replacement)
        }
    }

    public func toggleCompletion(id: UUID) {
        guard allTasks.first(where: { $0.id == id })?.status == .pending else { return }
        mutate {
            guard var task = allTasks.first(where: { $0.id == id }) else { return }
            let date = now()
            task.status = .completed
            task.completedAt = date
            task.updatedAt = date
            try repository.save(task)
        }
    }

    public func delete(id: UUID) {
        guard allTasks.first(where: { $0.id == id })?.status == .pending else { return }
        mutate {
            try repository.delete(id: id)
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

    private func recurrence(scope: TimeScope, repeats: Bool) -> RecurrenceRule {
        guard repeats, scope != .anytime else { return .once }
        return .repeating(RepeatRule(frequency: scope))
    }

    private func nextSortIndex(
        scope: TimeScope,
        tier: QuestTier,
        period: TaskPeriod?
    ) -> Int {
        let maximum = allTasks
            .filter { $0.timeScope == scope && $0.tier == tier && $0.period == period }
            .map(\.sortIndex)
            .max() ?? -1
        return maximum + 1
    }

    private func dashboardOrder(_ lhs: TodoTask, _ rhs: TodoTask) -> Bool {
        let lhsStart = lhs.period?.start ?? .distantPast
        let rhsStart = rhs.period?.start ?? .distantPast
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        return TodoTask.displayOrder(lhs, rhs)
    }
}
