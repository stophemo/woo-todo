import CryptoKit
import Foundation

public struct RecurringSettlement: Equatable, Sendable {
    public let updatedTasks: [TodoTask]
    public let createdTasks: [TodoTask]

    public var isEmpty: Bool {
        updatedTasks.isEmpty && createdTasks.isEmpty
    }

    public init(updatedTasks: [TodoTask], createdTasks: [TodoTask]) {
        self.updatedTasks = updatedTasks
        self.createdTasks = createdTasks
    }
}

/// 每天重复任务的本机结算：
/// 过期未完成的上一条标记为放弃，并按日期生成下一条；已完成/已放弃的上一条继续生成下一条。
/// 同一台设备重复执行、不同设备并发执行都使用确定性的 occurrence id，结果保持幂等。
public enum RecurringTaskSettler {
    public static func settle(
        tasks: [TodoTask],
        today: Date,
        now: Date,
        deletedTaskIDs: Set<UUID> = []
    ) -> RecurringSettlement {
        let calendar = TodoTask.protocolCalendar
        let todayStart = calendar.startOfDay(for: today)
        let originalTasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var tasksByID = originalTasksByID
        var occurrenceKeys = Set(tasks.compactMap { task -> String? in
            guard task.recurrence == .daily, let start = task.startDate else { return nil }
            return occurrenceKey(seriesID: task.seriesID, startDate: start)
        })
        var queue = tasks.sorted {
            ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture)
        }
        var index = 0

        while index < queue.count {
            var task = queue[index]
            index += 1
            guard task.recurrence == .daily,
                  let startDate = task.startDate,
                  let endDate = task.endDate else { continue }
            let start = calendar.startOfDay(for: startDate)
            let end = calendar.startOfDay(for: endDate)
            guard end < todayStart else { continue }

            if task.status == .pending {
                let expiration = calendar.startOfDay(for: end)
                task.status = .pass
                task.completedAt = expiration
                task.updatedAt = max(task.updatedAt, expiration)
                tasksByID[task.id] = task
            }

            guard let duration = calendar.dateComponents(
                [.day],
                from: start,
                to: end
            ).day.map({ $0 + 1 }), duration > 0 else { continue }
            guard let nextStart = calendar.date(byAdding: .day, value: 1, to: end),
                  let nextEnd = calendar.date(
                      byAdding: .day,
                      value: duration - 1,
                      to: nextStart
                  ) else { continue }

            let nextID = occurrenceID(seriesID: task.seriesID, startDate: nextStart)
            if deletedTaskIDs.contains(nextID) {
                // 删除过一次 occurrence 表示这条序列到此为止，避免每天重新复活。
                continue
            }
            let key = occurrenceKey(seriesID: task.seriesID, startDate: nextStart)
            if tasksByID[nextID] != nil || occurrenceKeys.contains(key) {
                continue
            }
            guard let nextTask = try? TodoTask(
                id: nextID,
                seriesID: task.seriesID,
                title: task.title,
                categoryID: task.categoryID,
                startDate: nextStart,
                endDate: nextEnd,
                sortIndex: task.sortIndex,
                createdAt: now,
                updatedAt: now,
                reminderTime: task.reminderTime,
                recurrence: .daily
            ) else {
                continue
            }
            tasksByID[nextID] = nextTask
            occurrenceKeys.insert(key)
            queue.append(nextTask)
        }

        let updatedTasks = tasksByID.compactMap { id, task in
            guard let original = originalTasksByID[id],
                  original != task else { return nil }
            return task
        }.sorted(by: TodoTask.displayOrder)
        let createdTasks = tasksByID.values
            .filter { originalTasksByID[$0.id] == nil }
            .sorted(by: TodoTask.displayOrder)
        return RecurringSettlement(
            updatedTasks: updatedTasks,
            createdTasks: createdTasks
        )
    }

    /// 与旧周期任务、Android 端共用的确定性 occurrence 标识。
    public static func occurrenceID(seriesID: UUID, startDate: Date) -> UUID {
        let source = "woo-todo-occurrence-v1|"
            + seriesID.uuidString.lowercased()
            + "|day|"
            + dateKey(startDate)
        let digest = SHA256.hash(data: Data(source.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func occurrenceKey(seriesID: UUID, startDate: Date) -> String {
        seriesID.uuidString.lowercased() + "|" + dateKey(startDate)
    }

    private static func dateKey(_ date: Date) -> String {
        let components = TodoTask.protocolCalendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
