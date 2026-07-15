import Combine
import Foundation

@MainActor
public final class TodayStore: ObservableObject {
    @Published public private(set) var tasks: [TodoTask] = []
    @Published public private(set) var errorMessage: String?

    public var onTasksChanged: (() -> Void)?

    private let repository: TaskRepository
    private var engine: PeriodEngine
    private let now: () -> Date

    public init(
        repository: TaskRepository,
        engine: PeriodEngine = PeriodEngine(),
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.engine = engine
        self.now = now
    }

    public func reload() {
        perform {
            let date = now()
            try LazySettlementService(repository: repository, engine: engine).settle(at: date)
            let period = engine.period(containing: date, for: .daily)!
            tasks = try repository
                .fetchTasks(scope: .daily, in: period)
                .sorted(by: TodoTask.displayOrder)
        }
    }

    public func add(
        title: String,
        tier: QuestTier,
        repeatsDaily: Bool
    ) {
        if perform({
            let date = now()
            let maxIndex = tasks
                .filter { $0.tier == tier }
                .map(\.sortIndex)
                .max() ?? -1
            let task = try TodoTask(
                title: title,
                timeScope: .daily,
                tier: tier,
                recurrence: repeatsDaily
                    ? .repeating(RepeatRule(frequency: .daily))
                    : .once,
                period: engine.period(containing: date, for: .daily),
                sortIndex: maxIndex + 1,
                createdAt: date
            )
            try repository.save(task)
            reload()
        }) {
            onTasksChanged?()
        }
    }

    public func edit(
        id: UUID,
        title: String,
        tier: QuestTier,
        repeatsDaily: Bool
    ) {
        guard tasks.first(where: { $0.id == id })?.status == .pending else { return }
        if perform({
            guard var task = tasks.first(where: { $0.id == id }) else { return }
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw TaskValidationError.emptyTitle }
            if task.tier != tier {
                task.sortIndex = (tasks
                    .filter { $0.tier == tier }
                    .map(\.sortIndex)
                    .max() ?? -1) + 1
            }
            task.title = normalized
            task.tier = tier
            task.recurrence = repeatsDaily
                ? .repeating(RepeatRule(frequency: .daily))
                : .once
            task.updatedAt = now()
            try repository.save(task)
            reload()
        }) {
            onTasksChanged?()
        }
    }

    public func toggleCompletion(id: UUID) {
        guard tasks.first(where: { $0.id == id })?.status == .pending else { return }
        if perform({
            guard var task = tasks.first(where: { $0.id == id }) else { return }
            let date = now()
            task.status = .completed
            task.completedAt = date
            task.updatedAt = date
            try repository.save(task)
            reload()
        }) {
            onTasksChanged?()
        }
    }

    /// 仅允许在同一级别内排序，跨级别调整应走编辑入口。
    public func move(tier: QuestTier, fromOffsets: IndexSet, toOffset: Int) {
        if perform({
            var group = tasks.filter { $0.tier == tier }.sorted(by: TodoTask.displayOrder)
            guard group.allSatisfy({ $0.status == .pending }) else { return }
            let validOffsets = fromOffsets.filter { group.indices.contains($0) }.sorted()
            guard !validOffsets.isEmpty else { return }

            let moved = validOffsets.map { group[$0] }
            for index in validOffsets.reversed() {
                group.remove(at: index)
            }
            let removedBeforeDestination = validOffsets.filter { $0 < toOffset }.count
            let insertionIndex = min(
                max(0, toOffset - removedBeforeDestination),
                group.count
            )
            group.insert(contentsOf: moved, at: insertionIndex)

            let date = now()
            for index in group.indices {
                group[index].sortIndex = index
                group[index].updatedAt = date
            }
            try repository.save(group)
            reload()
        }) {
            onTasksChanged?()
        }
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
}
