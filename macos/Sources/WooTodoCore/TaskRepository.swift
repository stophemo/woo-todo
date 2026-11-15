import Foundation

public protocol TaskRepository: AnyObject {
    func fetchAll() throws -> [TodoTask]
    func deletedTaskIDs() throws -> Set<UUID>
    func save(_ tasks: [TodoTask]) throws
    @discardableResult
    func reopenCompleted(id: UUID, at date: Date) throws -> Bool
    func delete(id: UUID) throws
    @discardableResult
    func clearHistory(ids: Set<UUID>?) throws -> Int
    func fetchCategories() throws -> [TaskCategory]
    func saveCategories(_ categories: [TaskCategory]) throws
    @discardableResult
    func reassignPendingCategory(from: String, to: String, at date: Date) throws -> Int
}

public extension TaskRepository {
    func deletedTaskIDs() throws -> Set<UUID> { [] }

    func save(_ task: TodoTask) throws {
        try save([task])
    }

    func fetchCategories() throws -> [TaskCategory] { TaskCategory.defaults }

    func saveCategories(_ categories: [TaskCategory]) throws {}

    @discardableResult
    func reassignPendingCategory(from: String, to: String, at date: Date) throws -> Int {
        0
    }
}
