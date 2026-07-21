import Foundation

public struct OfflineRelayMergePlan: Equatable, Sendable {
    public let tasksToUpsert: [WireTaskPayload]
    public let tombstonesToApply: [WireTombstonePayload]
    public let unchangedCount: Int

    public init(
        tasksToUpsert: [WireTaskPayload],
        tombstonesToApply: [WireTombstonePayload],
        unchangedCount: Int
    ) {
        self.tasksToUpsert = tasksToUpsert
        self.tombstonesToApply = tombstonesToApply
        self.unchangedCount = unchangedCount
    }
}

public struct OfflineRelayMergeResult: Equatable, Sendable {
    public let mergedTaskCount: Int
    public let mergedTombstoneCount: Int
    public let unchangedCount: Int

    public init(
        mergedTaskCount: Int,
        mergedTombstoneCount: Int,
        unchangedCount: Int
    ) {
        self.mergedTaskCount = mergedTaskCount
        self.mergedTombstoneCount = mergedTombstoneCount
        self.unchangedCount = unchangedCount
    }
}

/// 离线接力包没有同步 Lamport 版本，因此使用更新时间和稳定内容指纹做确定性 LWW。
/// 领域终态规则与在线同步一致，删除屏障永远优先于同 ID 的任务。
public enum OfflineRelayMergePolicy {
    public static func plan(
        localTasks: [WireTaskPayload],
        localTombstones: [WireTombstonePayload],
        incomingTasks: [WireTaskPayload],
        incomingTombstones: [WireTombstonePayload]
    ) throws -> OfflineRelayMergePlan {
        let localTaskByID = try canonicalTaskMap(localTasks)
        let localTombstoneByID = try canonicalTombstoneMap(localTombstones)
        let normalizedIncomingTasks = try canonicalTaskMap(incomingTasks)
            .values
            .sorted { $0.id < $1.id }
        let normalizedIncomingTombstones = try canonicalTombstoneMap(incomingTombstones)
            .values
            .sorted { $0.id < $1.id }
        let incomingTombstoneIDs = Set(normalizedIncomingTombstones.map(\.id))

        let tasksToUpsert = try normalizedIncomingTasks.compactMap { incoming -> WireTaskPayload? in
            let entityID = incoming.id
            guard !incomingTombstoneIDs.contains(entityID),
                  localTombstoneByID[entityID] == nil else { return nil }
            guard let current = localTaskByID[entityID] else { return incoming }
            let resolved = try resolveTask(current: current, incoming: incoming)
            return resolved == current ? nil : resolved
        }

        let tombstonesToApply = normalizedIncomingTombstones.filter { incoming in
            let entityID = incoming.id
            guard let current = localTombstoneByID[entityID] else { return true }
            return incoming.deletedAt > current.deletedAt || localTaskByID[entityID] != nil
        }

        return OfflineRelayMergePlan(
            tasksToUpsert: tasksToUpsert,
            tombstonesToApply: tombstonesToApply,
            unchangedCount: incomingTasks.count + incomingTombstones.count
                - tasksToUpsert.count - tombstonesToApply.count
        )
    }

    public static func resolveTask(
        current: WireTaskPayload,
        incoming: WireTaskPayload
    ) throws -> WireTaskPayload {
        if current == incoming { return current }
        let incomingWinsLWW = compareVersions(incoming, current) == .orderedDescending

        if let merged = try mergeCompletedOverPass(
            current: current,
            incoming: incoming,
            incomingWinsLWW: incomingWinsLWW
        ) {
            return merged
        }
        if current.state != .pending, incoming.state == .pending { return current }
        if current.state == .pending, incoming.state != .pending { return incoming }
        return incomingWinsLWW ? incoming : current
    }

    private static func mergeCompletedOverPass(
        current: WireTaskPayload,
        incoming: WireTaskPayload,
        incomingWinsLWW: Bool
    ) throws -> WireTaskPayload? {
        let completed: WireTaskPayload
        if current.state == .completed, incoming.state == .pass {
            completed = current
        } else if current.state == .pass, incoming.state == .completed {
            completed = incoming
        } else {
            return nil
        }
        guard isValidCompletion(completed) else { return nil }
        let base = incomingWinsLWW ? incoming : current
        let merged = try WireTaskPayload(
            id: base.id,
            seriesId: base.seriesId,
            title: base.title,
            timeType: base.timeType,
            periodStart: base.periodStart,
            timezone: base.timezone,
            questLine: base.questLine,
            state: .completed,
            recurrence: base.recurrence,
            sortOrder: base.sortOrder,
            createdAt: base.createdAt,
            updatedAt: max(base.updatedAt, completed.updatedAt),
            reminderTime: base.reminderTime,
            settledAt: completed.settledAt
        )
        return isValidCompletion(merged) ? merged : nil
    }

    private static func isValidCompletion(_ task: WireTaskPayload) -> Bool {
        guard task.state == .completed, let settledAt = task.settledAt else { return false }
        if task.timeType == .someday { return true }
        guard let periodStart = task.periodStart,
              let timeZone = TimeZone(identifier: task.timezone),
              let start = date(periodStart, timeZone: timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let component: Calendar.Component
        switch task.timeType {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .someday: return true
        }
        guard let end = calendar.date(byAdding: component, value: 1, to: start) else { return false }
        let endMilliseconds = Int64((end.timeIntervalSince1970 * 1_000).rounded())
        return settledAt < endMilliseconds
    }

    private static func date(_ value: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return nil
        }
        return date
    }

    private static func compareVersions(
        _ first: WireTaskPayload,
        _ second: WireTaskPayload
    ) -> ComparisonResult {
        if first.updatedAt != second.updatedAt {
            return first.updatedAt > second.updatedAt ? .orderedDescending : .orderedAscending
        }
        let firstFingerprint = fingerprint(first)
        let secondFingerprint = fingerprint(second)
        if firstFingerprint == secondFingerprint { return .orderedSame }
        return firstFingerprint.lexicographicallyPrecedes(secondFingerprint)
            ? .orderedAscending
            : .orderedDescending
    }

    /// 字段顺序和编码必须与 Android OfflineRelayMergePolicy 保持一致。
    private static func fingerprint(_ task: WireTaskPayload) -> Data {
        var data = Data()
        data.appendInt64(Int64(task.protocolVersion))
        data.appendRequiredString(task.entityType)
        data.appendRequiredString(task.id)
        data.appendRequiredString(task.seriesId)
        data.appendRequiredString(task.title)
        data.appendRequiredString(task.timeType.rawValue)
        data.appendOptionalString(task.periodStart)
        data.appendRequiredString(task.timezone)
        data.appendRequiredString(task.questLine.rawValue)
        data.appendRequiredString(task.state.rawValue)
        data.appendRequiredString(task.recurrence.rawValue)
        data.appendInt64(task.sortOrder)
        data.appendInt64(task.createdAt)
        data.appendInt64(task.updatedAt)
        data.appendOptionalString(task.reminderTime)
        data.appendOptionalInt64(task.settledAt)
        return data
    }

    private static func canonicalID(_ value: String) -> String {
        value.lowercased()
    }

    private static func canonicalTaskMap(
        _ tasks: [WireTaskPayload]
    ) throws -> [String: WireTaskPayload] {
        var result: [String: WireTaskPayload] = [:]
        for task in tasks {
            let normalized = try canonicalized(task)
            if let current = result[normalized.id] {
                result[normalized.id] = try resolveTask(current: current, incoming: normalized)
            } else {
                result[normalized.id] = normalized
            }
        }
        return result
    }

    private static func canonicalTombstoneMap(
        _ tombstones: [WireTombstonePayload]
    ) throws -> [String: WireTombstonePayload] {
        var result: [String: WireTombstonePayload] = [:]
        for tombstone in tombstones {
            let normalized = try canonicalized(tombstone)
            if let current = result[normalized.id], current.deletedAt >= normalized.deletedAt {
                continue
            }
            result[normalized.id] = normalized
        }
        return result
    }

    private static func canonicalized(_ task: WireTaskPayload) throws -> WireTaskPayload {
        let id = canonicalID(task.id)
        guard id != task.id else { return task }
        return try WireTaskPayload(
            id: id,
            seriesId: task.seriesId,
            title: task.title,
            timeType: task.timeType,
            periodStart: task.periodStart,
            timezone: task.timezone,
            questLine: task.questLine,
            state: task.state,
            recurrence: task.recurrence,
            sortOrder: task.sortOrder,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            reminderTime: task.reminderTime,
            settledAt: task.settledAt
        )
    }

    private static func canonicalized(
        _ tombstone: WireTombstonePayload
    ) throws -> WireTombstonePayload {
        let id = canonicalID(tombstone.id)
        guard id != tombstone.id else { return tombstone }
        return try WireTombstonePayload(id: id, deletedAt: tombstone.deletedAt)
    }
}

private extension Data {
    mutating func appendRequiredString(_ value: String) {
        append(1)
        let bytes = Data(value.utf8)
        var length = UInt32(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }

    mutating func appendOptionalString(_ value: String?) {
        guard let value else {
            append(0)
            return
        }
        appendRequiredString(value)
    }

    mutating func appendInt64(_ value: Int64) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendOptionalInt64(_ value: Int64?) {
        guard let value else {
            append(0)
            return
        }
        append(1)
        appendInt64(value)
    }
}
