import Foundation

public protocol TaskRepository: AnyObject {
    func fetchAll() throws -> [TodoTask]
    func fetchTasks(
        scope: TimeScope,
        in period: TaskPeriod?,
        includeOverdueOnce: Bool
    ) throws -> [TodoTask]
    func deletedTaskIDs() throws -> Set<UUID>
    func save(_ tasks: [TodoTask]) throws
    @discardableResult
    func reopenCompleted(id: UUID, at date: Date) throws -> Bool
    func delete(id: UUID) throws
    @discardableResult
    func clearHistory(ids: Set<UUID>?) throws -> Int
}

public extension TaskRepository {
    func fetchTasks(scope: TimeScope, in period: TaskPeriod?) throws -> [TodoTask] {
        try fetchTasks(scope: scope, in: period, includeOverdueOnce: false)
    }

    func deletedTaskIDs() throws -> Set<UUID> { [] }

    func save(_ task: TodoTask) throws {
        try save([task])
    }
}

public struct LazySettlementService {
    private let repository: TaskRepository
    private let engine: PeriodEngine

    public init(repository: TaskRepository, engine: PeriodEngine) {
        self.repository = repository
        self.engine = engine
    }

    @discardableResult
    public func settle(at now: Date = Date()) throws -> SettlementResult {
        let result = engine.settle(
            try repository.fetchAll(),
            at: now,
            reservedTaskIDs: try repository.deletedTaskIDs()
        )
        let affected = result.changedTaskIDs.union(result.generatedTaskIDs)
        if !affected.isEmpty {
            try repository.save(result.tasks.filter { affected.contains($0.id) })
        }
        return result
    }
}
