import Foundation

public protocol TaskRepository: AnyObject {
    func fetchAll() throws -> [TodoTask]
    func deletedTaskIDs() throws -> Set<UUID>
    func save(_ tasks: [TodoTask]) throws
    @discardableResult
    func reopenCompleted(id: UUID, at date: Date) throws -> Bool
    /// 删除待办任务。实现会在本机保留一份恢复快照，删除记录仍按现有同步语义传播。
    func delete(id: UUID) throws
    @discardableResult
    func clearHistory(ids: Set<UUID>?) throws -> Int
    func fetchTrash() throws -> [TrashedTask]
    func trashCount() throws -> Int
    /// 从本机恢复快照重新创建任务；返回新任务 ID，快照不存在时返回 nil。
    @discardableResult
    func restoreTrash(id: UUID, at date: Date) throws -> UUID?
    /// 移除本机恢复快照；ids 为 nil 时清空。不会产生新的同步删除记录。
    @discardableResult
    func removeTrash(ids: Set<UUID>?) throws -> Int
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

    func fetchTrash() throws -> [TrashedTask] { [] }

    func trashCount() throws -> Int { 0 }

    @discardableResult
    func restoreTrash(id: UUID, at date: Date) throws -> UUID? { nil }

    @discardableResult
    func removeTrash(ids: Set<UUID>?) throws -> Int { 0 }

    func fetchCategories() throws -> [TaskCategory] { TaskCategory.defaults }

    func saveCategories(_ categories: [TaskCategory]) throws {}

    @discardableResult
    func reassignPendingCategory(from: String, to: String, at date: Date) throws -> Int {
        0
    }
}
