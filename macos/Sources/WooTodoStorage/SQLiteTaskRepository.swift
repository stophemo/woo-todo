import CSQLite
import Foundation
import WooTodoCore
import WooTodoSync

public enum SQLiteRepositoryError: LocalizedError {
    case openFailed(String)
    case statementFailed(String)
    case invalidRecord(String)
    case invalidSyncConfiguration(String)
    case syncIdentityMismatch
    case syncCredentialsUnavailable
    case invalidRemotePage(String)
    case settledTaskImmutable
    case backupDestinationNotEmpty

    public var errorDescription: String? {
        switch self {
        case let .openFailed(message): "无法打开本地任务库：\(message)"
        case let .statementFailed(message): "本地任务库操作失败：\(message)"
        case let .invalidRecord(message): "本地任务数据无效：\(message)"
        case let .invalidSyncConfiguration(message): "同步配置无效：\(message)"
        case .syncIdentityMismatch: "本地数据库已绑定到另一同步空间或设备"
        case .syncCredentialsUnavailable: "本地数据库已绑定同步，但当前未加载同步密钥"
        case let .invalidRemotePage(message): "远端同步页无效：\(message)"
        case .settledTaskImmutable: "已完成或 Pass 的任务属于历史记录，不能再修改或删除"
        case .backupDestinationNotEmpty: "仅支持向没有任务的全新安装恢复备份"
        }
    }
}

/// SQLite 不持久化 vault key；应用启动后应从 Keychain 读取并传入。
public struct SQLiteSyncConfiguration: Sendable {
    public let vaultId: String
    public let deviceId: String
    public let vaultKey: Data
    public let timeZone: TimeZone

    public init(
        vaultId: String,
        deviceId: String,
        vaultKey: Data,
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!
    ) {
        self.vaultId = vaultId
        self.deviceId = deviceId
        self.vaultKey = vaultKey
        self.timeZone = timeZone
    }
}

/// 小数据量本地优先仓储；串行锁确保面板刷新与后台同步不会并发访问同一连接。
public final class SQLiteTaskRepository: TaskRepository, SyncOutbox, SyncLocalApplying, @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var syncConfiguration: SQLiteSyncConfiguration?
    private var hasPersistedSyncIdentity = false

    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    public convenience init(
        databaseURL: URL,
        syncConfiguration: SQLiteSyncConfiguration? = nil
    ) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try self.init(path: databaseURL.path, syncConfiguration: syncConfiguration)
    }

    public init(path: String, syncConfiguration: SQLiteSyncConfiguration? = nil) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let database {
                sqlite3_close(database)
            }
            database = nil
            throw SQLiteRepositoryError.openFailed(message)
        }

        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try execute("PRAGMA foreign_keys = ON")
            try migrate()
            hasPersistedSyncIdentity = try persistedSyncIdentity() != nil
            if let syncConfiguration {
                try configureSync(syncConfiguration)
            }
        } catch {
            if let database {
                sqlite3_close(database)
            }
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func fetchAll() throws -> [TodoTask] {
        try withLock {
            try query(
                """
                SELECT id, series_id, title, time_scope, tier, status,
                       recurrence_json, period_start, period_end, sort_index,
                       created_at, updated_at, completed_at
                FROM tasks
                ORDER BY CASE tier
                    WHEN 'main' THEN 0
                    WHEN 'side' THEN 1
                    ELSE 2
                END, sort_index, created_at
                """
            )
        }
    }

    public func fetchTasks(scope: TimeScope, in period: TaskPeriod?) throws -> [TodoTask] {
        try withLock {
            if let period {
                return try query(
                    """
                    SELECT id, series_id, title, time_scope, tier, status,
                           recurrence_json, period_start, period_end, sort_index,
                           created_at, updated_at, completed_at
                    FROM tasks
                    WHERE time_scope = ?
                      AND period_start < ?
                      AND period_end > ?
                    ORDER BY CASE tier
                        WHEN 'main' THEN 0
                        WHEN 'side' THEN 1
                        ELSE 2
                    END, sort_index, created_at
                    """,
                    bindings: [
                        .text(scope.rawValue),
                        .double(period.end.timeIntervalSince1970),
                        .double(period.start.timeIntervalSince1970)
                    ]
                )
            }

            return try query(
                """
                SELECT id, series_id, title, time_scope, tier, status,
                       recurrence_json, period_start, period_end, sort_index,
                       created_at, updated_at, completed_at
                FROM tasks
                WHERE time_scope = ?
                ORDER BY CASE tier
                    WHEN 'main' THEN 0
                    WHEN 'side' THEN 1
                    ELSE 2
                END, sort_index, created_at
                """,
                bindings: [.text(scope.rawValue)]
            )
        }
    }

    public func deletedTaskIDs() throws -> Set<UUID> {
        try withLock {
            let statement = try prepare(
                """
                SELECT entity_id FROM sync_entity_versions WHERE is_deleted = 1
                UNION
                SELECT entity_id FROM sync_deferred_deletions
                """
            )
            defer { sqlite3_finalize(statement) }
            var values = Set<UUID>()
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let id = UUID(uuidString: text(at: 0, from: statement)) else {
                    throw SQLiteRepositoryError.invalidRecord("删除记录包含无效任务 ID")
                }
                values.insert(id)
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw statementError() }
            return values
        }
    }

    public func save(_ tasks: [TodoTask]) throws {
        guard !tasks.isEmpty else { return }
        try withLock {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                let sql = """
                    INSERT INTO tasks (
                        id, series_id, title, time_scope, tier, status,
                        recurrence_json, period_start, period_end, sort_index,
                        created_at, updated_at, completed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        series_id = excluded.series_id,
                        title = excluded.title,
                        time_scope = excluded.time_scope,
                        tier = excluded.tier,
                        status = excluded.status,
                        recurrence_json = excluded.recurrence_json,
                        period_start = excluded.period_start,
                        period_end = excluded.period_end,
                        sort_index = excluded.sort_index,
                        updated_at = excluded.updated_at,
                        completed_at = excluded.completed_at
                    """
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }

                for task in tasks {
                    guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          task.title.unicodeScalars.count <= 120 else {
                        throw SQLiteRepositoryError.invalidRecord("任务标题为空或超过 120 个 Unicode 字符")
                    }
                    let existing = try storedTask(id: task.id)
                    if existing == task { continue }
                    if let existing, existing.status != .pending {
                        throw SQLiteRepositoryError.settledTaskImmutable
                    }
                    let entityID = canonicalEntityID(task.id.uuidString)
                    if try entityVersion(for: entityID)?.isDeleted == true ||
                        (try isDeferredDeletion(entityID: entityID)) {
                        throw SQLiteRepositoryError.invalidRecord("已删除任务不能以相同 ID 复活")
                    }

                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    let recurrenceData = try encoder.encode(task.recurrence)
                    guard let recurrenceJSON = String(data: recurrenceData, encoding: .utf8) else {
                        throw SQLiteRepositoryError.invalidRecord("重复规则无法编码")
                    }

                    let values: [SQLiteValue] = [
                        .text(task.id.uuidString),
                        .text(task.seriesID.uuidString),
                        .text(task.title),
                        .text(task.timeScope.rawValue),
                        .text(task.tier.rawValue),
                        .text(task.status.rawValue),
                        .text(recurrenceJSON),
                        task.period.map { .double($0.start.timeIntervalSince1970) } ?? .null,
                        task.period.map { .double($0.end.timeIntervalSince1970) } ?? .null,
                        .integer(Int64(task.sortIndex)),
                        .double(task.createdAt.timeIntervalSince1970),
                        .double(task.updatedAt.timeIntervalSince1970),
                        task.completedAt.map { .double($0.timeIntervalSince1970) } ?? .null
                    ]
                    try bind(values, to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw statementError()
                    }
                    if let configuration = syncConfiguration {
                        try enqueueLocalTask(
                            task,
                            kind: operationKind(previous: existing, current: task),
                            configuration: configuration
                        )
                    } else if hasPersistedSyncIdentity {
                        try recordDeferredUpsert(entityID: entityID)
                    }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func delete(id: UUID) throws {
        try withLock {
            let entityID = canonicalEntityID(id.uuidString)
            let existing = try storedTask(id: id)
            let version = try entityVersion(for: entityID)
            guard existing != nil || version != nil else { return }
            guard version?.isDeleted != true,
                  !(try isDeferredDeletion(entityID: entityID)) else { return }
            if let existing, existing.status != .pending {
                throw SQLiteRepositoryError.settledTaskImmutable
            }

            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try deleteTaskRow(entityID: entityID)
                let deletedAt = Date()
                if let configuration = syncConfiguration {
                    try enqueueLocalTombstone(
                        entityID: entityID,
                        deletedAt: deletedAt,
                        configuration: configuration
                    )
                } else {
                    try removeDeferredUpsert(entityID: entityID)
                    try recordDeferredDeletion(entityID: entityID, deletedAt: deletedAt)
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY NOT NULL,
                series_id TEXT NOT NULL,
                title TEXT NOT NULL,
                time_scope TEXT NOT NULL,
                tier TEXT NOT NULL,
                status TEXT NOT NULL,
                recurrence_json TEXT NOT NULL,
                period_start REAL,
                period_end REAL,
                sort_index INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL
            )
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_period ON tasks(time_scope, period_start, period_end)"
        )
        // 兼容原型阶段曾写入的旧枚举值，迁移后与共享 Wire 协议一致。
        try execute(
            """
            UPDATE tasks
            SET time_scope = CASE time_scope
                WHEN 'daily' THEN 'day'
                WHEN 'weekly' THEN 'week'
                WHEN 'monthly' THEN 'month'
                WHEN 'anytime' THEN 'someday'
                ELSE time_scope
            END
            WHERE time_scope IN ('daily', 'weekly', 'monthly', 'anytime')
            """
        )
        try execute(
            "UPDATE tasks SET tier = 'main' WHERE tier = 'mainline'"
        )
        try execute(
            """
            UPDATE tasks
            SET recurrence_json = replace(
                replace(
                    replace(
                        replace(recurrence_json, '"daily"', '"day"'),
                        '"weekly"', '"week"'
                    ),
                    '"monthly"', '"month"'
                ),
                '"anytime"', '"someday"'
            )
            """
        )
        try execute("DROP INDEX IF EXISTS idx_tasks_occurrence")
        try execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_occurrence ON tasks(series_id, time_scope, period_start) WHERE period_start IS NOT NULL"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_state (
                singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
                vault_id TEXT,
                device_id TEXT,
                cursor INTEGER NOT NULL DEFAULT 0 CHECK (cursor >= 0),
                lamport INTEGER NOT NULL DEFAULT 0 CHECK (lamport >= 0),
                CHECK ((vault_id IS NULL) = (device_id IS NULL))
            )
            """
        )
        try execute(
            "INSERT OR IGNORE INTO sync_state(singleton, cursor, lamport) VALUES (1, 0, 0)"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_outbox (
                op_id TEXT PRIMARY KEY NOT NULL,
                entity_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                lamport INTEGER NOT NULL CHECK (lamport >= 1),
                ciphertext TEXT NOT NULL,
                nonce TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_sync_outbox_order ON sync_outbox(created_at, op_id)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_sync_outbox_lamport ON sync_outbox(lamport, op_id)"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_entity_versions (
                entity_id TEXT PRIMARY KEY NOT NULL,
                lamport INTEGER NOT NULL CHECK (lamport >= 1),
                device_id TEXT NOT NULL,
                is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
                deleted_at INTEGER
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_applied_operations (
                op_id TEXT PRIMARY KEY NOT NULL,
                server_seq INTEGER NOT NULL UNIQUE CHECK (server_seq >= 1),
                applied_at INTEGER NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_deferred_upserts (
                entity_id TEXT PRIMARY KEY NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_deferred_deletions (
                entity_id TEXT PRIMARY KEY NOT NULL,
                deleted_at INTEGER NOT NULL CHECK (deleted_at >= 0)
            )
            """
        )
        try execute("PRAGMA user_version = 4")
    }

    /// 只读预检安全存储中的候选身份，不修改数据库或生成 outbox。
    public func validateSyncBinding(vaultId: String, deviceId: String) throws {
        try withLock {
            guard !vaultId.isEmpty, !deviceId.isEmpty else {
                throw SQLiteRepositoryError.invalidSyncConfiguration("同步身份不能为空")
            }
            if let identity = try persistedSyncIdentity() {
                guard identity.vaultId == vaultId, identity.deviceId == deviceId else {
                    throw SQLiteRepositoryError.syncIdentityMismatch
                }
            }
        }
    }

    public func makeBackupContents(
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!
    ) throws -> (tasks: [WireTaskPayload], tombstones: [WireTombstonePayload]) {
        try withLock {
            let tasks = try fetchAll().map { try wirePayload(for: $0, timeZone: timeZone) }
            return (tasks, try backupTombstones())
        }
    }

    public func makeBackupPayloads(
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!
    ) throws -> [WireTaskPayload] {
        try makeBackupContents(timeZone: timeZone).tasks
    }

    public func makeBackupTombstones() throws -> [WireTombstonePayload] {
        try withLock { try backupTombstones() }
    }

    /// 备份恢复只允许没有任务、删除记录或同步历史的全新任务库。
    /// 调用方负责在成功后恢复 Keychain 同步身份。
    public func restoreBackupPayloads(
        _ payloads: [WireTaskPayload],
        tombstones: [WireTombstonePayload] = []
    ) throws {
        try withLock {
            guard try isPristineBackupDestination() else {
                throw SQLiteRepositoryError.backupDestinationNotEmpty
            }
            let tasks = try payloads.map(task(from:))
            let taskIDs = Set(tasks.map { canonicalEntityID($0.id.uuidString) })
            guard taskIDs.count == tasks.count else {
                throw SQLiteRepositoryError.invalidRecord("备份包含重复的任务 ID")
            }
            let deletions = try tombstones.map { tombstone -> (String, Int64) in
                let entityID = canonicalEntityID(tombstone.id)
                guard UUID(uuidString: entityID) != nil,
                      !taskIDs.contains(entityID) else {
                    throw SQLiteRepositoryError.invalidRecord("备份删除记录的任务 ID 无效或重复")
                }
                return (entityID, tombstone.deletedAt)
            }
            guard Set(deletions.map { $0.0 }).count == deletions.count else {
                throw SQLiteRepositoryError.invalidRecord("备份包含重复的删除记录")
            }

            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                for task in tasks {
                    try upsertTaskRow(task)
                }
                for (entityID, deletedAt) in deletions {
                    try recordDeferredDeletion(
                        entityID: entityID,
                        deletedAtMilliseconds: deletedAt
                    )
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// 首次绑定会把现有任务作为加密快照写入 outbox；再次加载相同身份不会重复入队。
    public func configureSync(_ configuration: SQLiteSyncConfiguration) throws {
        try withLock {
            try validate(configuration)
            if let identity = try persistedSyncIdentity() {
                guard identity.vaultId == configuration.vaultId,
                      identity.deviceId == configuration.deviceId else {
                    throw SQLiteRepositoryError.syncIdentityMismatch
                }
                try recoverDeferredChanges(using: configuration)
                syncConfiguration = configuration
                hasPersistedSyncIdentity = true
                return
            }

            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                let statement = try prepare(
                    "UPDATE sync_state SET vault_id = ?, device_id = ? WHERE singleton = 1"
                )
                defer { sqlite3_finalize(statement) }
                try bind(
                    [.text(configuration.vaultId), .text(configuration.deviceId)],
                    to: statement
                )
                guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }

                for task in try query(
                    """
                    SELECT id, series_id, title, time_scope, tier, status,
                           recurrence_json, period_start, period_end, sort_index,
                           created_at, updated_at, completed_at
                    FROM tasks
                    ORDER BY created_at, id
                    """
                ) {
                    try enqueueLocalTask(task, kind: .upsert, configuration: configuration)
                }
                for deletion in try deferredDeletions() {
                    try deleteTaskRow(entityID: deletion.entityID)
                    try enqueueLocalTombstone(
                        entityID: deletion.entityID,
                        deletedAtMilliseconds: deletion.deletedAtMilliseconds,
                        configuration: configuration
                    )
                }
                try execute("DELETE FROM sync_deferred_upserts")
                try execute("DELETE FROM sync_deferred_deletions")
                try execute("COMMIT")
                syncConfiguration = configuration
                hasPersistedSyncIdentity = true
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func pendingOperations(limit: Int) async throws -> [SyncPushOperation] {
        try pendingOperationsSynchronously(limit: limit)
    }

    public func acknowledgeOperations(opIds: [String]) async throws {
        try acknowledgeOperationsSynchronously(opIds: opIds)
    }

    public func currentCursor() async throws -> Int64 {
        try currentCursorSynchronously()
    }

    public func applyRemoteOperations(
        _ operations: [SyncPulledOperation],
        advancingCursorTo cursor: Int64
    ) async throws {
        try applyRemoteOperationsSynchronously(operations, advancingCursorTo: cursor)
    }

    private func pendingOperationsSynchronously(limit: Int) throws -> [SyncPushOperation] {
        guard limit > 0 else { return [] }
        return try withLock {
            let statement = try prepare(
                """
                SELECT op_id, entity_id, kind, lamport, ciphertext, nonce
                FROM sync_outbox
                ORDER BY lamport, op_id
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind([.integer(Int64(limit))], to: statement)

            var operations: [SyncPushOperation] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let kind = SyncOperationKind(rawValue: text(at: 2, from: statement)) else {
                        throw SQLiteRepositoryError.invalidRecord("outbox 操作类型无法解析")
                    }
                    operations.append(SyncPushOperation(
                        opId: text(at: 0, from: statement),
                        entityId: text(at: 1, from: statement),
                        kind: kind,
                        lamport: sqlite3_column_int64(statement, 3),
                        ciphertext: text(at: 4, from: statement),
                        nonce: text(at: 5, from: statement)
                    ))
                case SQLITE_DONE:
                    return operations
                default:
                    throw statementError()
                }
            }
        }
    }

    private func acknowledgeOperationsSynchronously(opIds: [String]) throws {
        guard !opIds.isEmpty else { return }
        try withLock {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                let statement = try prepare("DELETE FROM sync_outbox WHERE op_id = ?")
                defer { sqlite3_finalize(statement) }
                for opId in Set(opIds) {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind([.text(opId)], to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func currentCursorSynchronously() throws -> Int64 {
        try withLock { try syncStateNumber(column: "cursor") }
    }

    private func applyRemoteOperationsSynchronously(
        _ operations: [SyncPulledOperation],
        advancingCursorTo cursor: Int64
    ) throws {
        try withLock {
            guard let configuration = syncConfiguration else {
                throw SQLiteRepositoryError.syncCredentialsUnavailable
            }
            let previousCursor = try syncStateNumber(column: "cursor")
            try validateRemotePage(
                operations,
                previousCursor: previousCursor,
                targetCursor: cursor
            )

            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                for operation in operations {
                    if try isOperationApplied(operation.opId) { continue }
                    try applyRemoteOperation(operation, configuration: configuration)
                    try recordAppliedOperation(operation)
                    try advanceLamportClock(toAtLeast: operation.lamport)
                }
                let statement = try prepare("UPDATE sync_state SET cursor = ? WHERE singleton = 1")
                defer { sqlite3_finalize(statement) }
                try bind([.integer(cursor)], to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func validate(_ configuration: SQLiteSyncConfiguration) throws {
        guard !configuration.vaultId.isEmpty,
              !configuration.deviceId.isEmpty,
              configuration.vaultKey.count == AES256GCM.keyByteCount else {
            throw SQLiteRepositoryError.invalidSyncConfiguration(
                "vaultId、deviceId 不能为空，vault key 必须为 32 字节"
            )
        }
    }

    private func recordDeferredUpsert(entityID: String) throws {
        let statement = try prepare(
            "INSERT OR IGNORE INTO sync_deferred_upserts(entity_id) VALUES (?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(entityID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func removeDeferredUpsert(entityID: String) throws {
        let statement = try prepare(
            "DELETE FROM sync_deferred_upserts WHERE entity_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(entityID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func isDeferredDeletion(entityID: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sync_deferred_deletions WHERE entity_id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(entityID)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw statementError()
        }
    }

    private func recordDeferredDeletion(entityID: String, deletedAt: Date) throws {
        try recordDeferredDeletion(
            entityID: entityID,
            deletedAtMilliseconds: milliseconds(since1970: deletedAt)
        )
    }

    private func recordDeferredDeletion(
        entityID: String,
        deletedAtMilliseconds: Int64
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO sync_deferred_deletions(entity_id, deleted_at)
            VALUES (?, ?)
            ON CONFLICT(entity_id) DO UPDATE SET deleted_at = excluded.deleted_at
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(entityID),
            .integer(deletedAtMilliseconds),
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func recoverDeferredChanges(
        using configuration: SQLiteSyncConfiguration
    ) throws {
        guard try hasDeferredChanges() else { return }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for task in try query(
                """
                SELECT tasks.id, tasks.series_id, tasks.title, tasks.time_scope,
                       tasks.tier, tasks.status, tasks.recurrence_json,
                       tasks.period_start, tasks.period_end, tasks.sort_index,
                       tasks.created_at, tasks.updated_at, tasks.completed_at
                FROM tasks
                INNER JOIN sync_deferred_upserts
                    ON sync_deferred_upserts.entity_id = lower(tasks.id)
                ORDER BY tasks.created_at, tasks.id
                """
            ) {
                try enqueueLocalTask(task, kind: .upsert, configuration: configuration)
            }

            for deletion in try deferredDeletions() {
                try deleteTaskRow(entityID: deletion.entityID)
                try enqueueLocalTombstone(
                    entityID: deletion.entityID,
                    deletedAtMilliseconds: deletion.deletedAtMilliseconds,
                    configuration: configuration
                )
            }
            try execute("DELETE FROM sync_deferred_upserts")
            try execute("DELETE FROM sync_deferred_deletions")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func hasDeferredChanges() throws -> Bool {
        let statement = try prepare(
            """
            SELECT EXISTS(SELECT 1 FROM sync_deferred_upserts)
                OR EXISTS(SELECT 1 FROM sync_deferred_deletions)
            """
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw statementError() }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func isPristineBackupDestination() throws -> Bool {
        let statement = try prepare(
            """
            SELECT
                NOT EXISTS(SELECT 1 FROM tasks)
                AND NOT EXISTS(SELECT 1 FROM sync_outbox)
                AND NOT EXISTS(SELECT 1 FROM sync_entity_versions)
                AND NOT EXISTS(SELECT 1 FROM sync_applied_operations)
                AND NOT EXISTS(SELECT 1 FROM sync_deferred_upserts)
                AND NOT EXISTS(SELECT 1 FROM sync_deferred_deletions)
                AND vault_id IS NULL
                AND device_id IS NULL
                AND cursor = 0
                AND lamport = 0
            FROM sync_state
            WHERE singleton = 1
            """
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw statementError() }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func deferredDeletions() throws -> [(
        entityID: String,
        deletedAtMilliseconds: Int64
    )] {
        let statement = try prepare(
            "SELECT entity_id, deleted_at FROM sync_deferred_deletions ORDER BY entity_id"
        )
        defer { sqlite3_finalize(statement) }
        var values: [(entityID: String, deletedAtMilliseconds: Int64)] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            values.append((
                entityID: text(at: 0, from: statement),
                deletedAtMilliseconds: sqlite3_column_int64(statement, 1)
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw statementError() }
        return values
    }

    private func backupTombstones() throws -> [WireTombstonePayload] {
        let statement = try prepare(
            """
            SELECT entity_id, MAX(deleted_at)
            FROM (
                SELECT entity_id, deleted_at
                FROM sync_entity_versions
                WHERE is_deleted = 1
                UNION ALL
                SELECT entity_id, deleted_at
                FROM sync_deferred_deletions
            )
            GROUP BY entity_id
            ORDER BY entity_id
            """
        )
        defer { sqlite3_finalize(statement) }
        var values: [WireTombstonePayload] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let entityID = canonicalEntityID(text(at: 0, from: statement))
            guard UUID(uuidString: entityID) != nil,
                  sqlite3_column_type(statement, 1) != SQLITE_NULL else {
                throw SQLiteRepositoryError.invalidRecord("删除记录包含无效任务 ID 或时间")
            }
            values.append(try WireTombstonePayload(
                id: entityID,
                deletedAt: sqlite3_column_int64(statement, 1)
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw statementError() }
        return values
    }

    private func persistedSyncIdentity() throws -> SyncIdentity? {
        let statement = try prepare(
            "SELECT vault_id, device_id FROM sync_state WHERE singleton = 1"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw statementError() }
        let hasVault = sqlite3_column_type(statement, 0) != SQLITE_NULL
        let hasDevice = sqlite3_column_type(statement, 1) != SQLITE_NULL
        guard hasVault == hasDevice else {
            throw SQLiteRepositoryError.invalidRecord("同步身份字段不完整")
        }
        guard hasVault else { return nil }
        return SyncIdentity(
            vaultId: text(at: 0, from: statement),
            deviceId: text(at: 1, from: statement)
        )
    }

    private func operationKind(
        previous: TodoTask?,
        current: TodoTask
    ) -> SyncOperationKind {
        guard let previous else { return .upsert }
        if previous.status != current.status {
            switch current.status {
            case .completed: return .complete
            case .pass: return .pass
            case .pending: return .upsert
            }
        }
        if previous.sortIndex != current.sortIndex {
            var withoutOrderChange = current
            withoutOrderChange.sortIndex = previous.sortIndex
            withoutOrderChange.updatedAt = previous.updatedAt
            if withoutOrderChange == previous { return .reorder }
        }
        return .upsert
    }

    private func enqueueLocalTask(
        _ task: TodoTask,
        kind: SyncOperationKind,
        configuration: SQLiteSyncConfiguration
    ) throws {
        let entityID = canonicalEntityID(task.id.uuidString)
        let lamport = try nextLamport()
        let operationID = UUID().uuidString.lowercased()
        let payload = try WireTaskEntity.task(wirePayload(
            for: task,
            timeZone: configuration.timeZone
        ))
        let metadata = SyncAADMetadata(
            vaultId: configuration.vaultId,
            operationId: operationID,
            entityId: entityID,
            kind: kind,
            lamport: lamport,
            deviceId: configuration.deviceId
        )
        let envelope = try TaskPayloadCodec.seal(
            payload,
            vaultKey: configuration.vaultKey,
            metadata: metadata
        )
        try insertOutbox(
            operationID: operationID,
            entityID: entityID,
            kind: kind,
            lamport: lamport,
            envelope: envelope
        )
        try upsertEntityVersion(EntityVersion(
            entityID: entityID,
            lamport: lamport,
            deviceID: configuration.deviceId,
            isDeleted: false,
            deletedAt: nil
        ))
    }

    private func enqueueLocalTombstone(
        entityID: String,
        deletedAt: Date,
        configuration: SQLiteSyncConfiguration
    ) throws {
        try enqueueLocalTombstone(
            entityID: entityID,
            deletedAtMilliseconds: milliseconds(since1970: deletedAt),
            configuration: configuration
        )
    }

    private func enqueueLocalTombstone(
        entityID: String,
        deletedAtMilliseconds: Int64,
        configuration: SQLiteSyncConfiguration
    ) throws {
        let lamport = try nextLamport()
        let operationID = UUID().uuidString.lowercased()
        let payload = try WireTaskEntity.tombstone(WireTombstonePayload(
            id: entityID,
            deletedAt: deletedAtMilliseconds
        ))
        let metadata = SyncAADMetadata(
            vaultId: configuration.vaultId,
            operationId: operationID,
            entityId: entityID,
            kind: .delete,
            lamport: lamport,
            deviceId: configuration.deviceId
        )
        let envelope = try TaskPayloadCodec.seal(
            payload,
            vaultKey: configuration.vaultKey,
            metadata: metadata
        )
        try insertOutbox(
            operationID: operationID,
            entityID: entityID,
            kind: .delete,
            lamport: lamport,
            envelope: envelope
        )
        try upsertEntityVersion(EntityVersion(
            entityID: entityID,
            lamport: lamport,
            deviceID: configuration.deviceId,
            isDeleted: true,
            deletedAt: deletedAtMilliseconds
        ))
    }

    private func wirePayload(
        for task: TodoTask,
        timeZone: TimeZone
    ) throws -> WireTaskPayload {
        let timeType: WireTaskTimeType
        switch task.timeScope {
        case .daily: timeType = .day
        case .weekly: timeType = .week
        case .monthly: timeType = .month
        case .anytime: timeType = .someday
        }
        let questLine: WireQuestLine
        switch task.tier {
        case .mainline: questLine = .main
        case .side: questLine = .side
        case .extra: questLine = .extra
        }
        let state: WireTaskState
        switch task.status {
        case .pending: state = .pending
        case .completed: state = .completed
        case .pass: state = .pass
        }
        let recurrence: WireRecurrence
        switch task.recurrence {
        case .once: recurrence = .once
        case .repeating: recurrence = .repeatRule
        }
        let settledAt = task.status == .pending
            ? nil
            : milliseconds(since1970: task.completedAt ?? task.updatedAt)

        return try WireTaskPayload(
            id: canonicalEntityID(task.id.uuidString),
            seriesId: canonicalEntityID(task.seriesID.uuidString),
            title: task.title,
            timeType: timeType,
            periodStart: task.period.map { dateKey($0.start, timeZone: timeZone) },
            timezone: timeZone.identifier,
            questLine: questLine,
            state: state,
            recurrence: recurrence,
            sortOrder: Int64(task.sortIndex),
            createdAt: milliseconds(since1970: task.createdAt),
            updatedAt: milliseconds(since1970: task.updatedAt),
            settledAt: settledAt
        )
    }

    private func nextLamport() throws -> Int64 {
        let current = try syncStateNumber(column: "lamport")
        guard current < Int64.max else {
            throw SQLiteRepositoryError.invalidRecord("Lamport 时钟已溢出")
        }
        let next = current + 1
        let statement = try prepare("UPDATE sync_state SET lamport = ? WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(next)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
        return next
    }

    private func insertOutbox(
        operationID: String,
        entityID: String,
        kind: SyncOperationKind,
        lamport: Int64,
        envelope: EncryptedEnvelope
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO sync_outbox(
                op_id, entity_id, kind, lamport, ciphertext, nonce, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(operationID),
            .text(entityID),
            .text(kind.rawValue),
            .integer(lamport),
            .text(envelope.ciphertext),
            .text(envelope.nonce),
            .integer(milliseconds(since1970: Date())),
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func validateRemotePage(
        _ operations: [SyncPulledOperation],
        previousCursor: Int64,
        targetCursor: Int64
    ) throws {
        guard targetCursor >= previousCursor else {
            throw SQLiteRepositoryError.invalidRemotePage("cursor 发生回退")
        }
        if operations.isEmpty {
            guard targetCursor == previousCursor else {
                throw SQLiteRepositoryError.invalidRemotePage("空页不能推进 cursor")
            }
            return
        }

        var sequence = previousCursor
        for operation in operations {
            guard operation.serverSeq > sequence,
                  operation.serverSeq <= targetCursor,
                  operation.lamport >= 1,
                  !operation.opId.isEmpty,
                  !operation.entityId.isEmpty,
                  !operation.deviceId.isEmpty else {
                throw SQLiteRepositoryError.invalidRemotePage("操作序号、版本或标识符无效")
            }
            sequence = operation.serverSeq
        }
        guard sequence == targetCursor else {
            throw SQLiteRepositoryError.invalidRemotePage("页尾序号与 cursor 不一致")
        }
    }

    private func applyRemoteOperation(
        _ operation: SyncPulledOperation,
        configuration: SQLiteSyncConfiguration
    ) throws {
        let metadata = SyncAADMetadata(
            vaultId: configuration.vaultId,
            operation: operation
        )
        let entity = try TaskPayloadCodec.open(
            EncryptedEnvelope(
                ciphertext: operation.ciphertext,
                nonce: operation.nonce
            ),
            vaultKey: configuration.vaultKey,
            metadata: metadata
        )
        let entityID = canonicalEntityID(operation.entityId)
        let currentVersion = try entityVersion(for: entityID)

        switch entity {
        case .task(let payload):
            guard operation.kind != .delete,
                  canonicalEntityID(payload.id) == entityID else {
                throw SQLiteRepositoryError.invalidRemotePage("任务正文与外层元数据不一致")
            }
            if operation.kind == .complete && payload.state != .completed {
                throw SQLiteRepositoryError.invalidRemotePage("complete 操作正文不是完成状态")
            }
            if operation.kind == .pass && payload.state != .pass {
                throw SQLiteRepositoryError.invalidRemotePage("pass 操作正文不是 Pass 状态")
            }
            // 同一实体 ID 的删除是终态；仍推进版本水位，但永不恢复任务正文。
            if let currentVersion, currentVersion.isDeleted {
                if remoteVersionWins(
                    lamport: operation.lamport,
                    deviceID: operation.deviceId,
                    over: currentVersion
                ) {
                    try upsertEntityVersion(EntityVersion(
                        entityID: entityID,
                        lamport: operation.lamport,
                        deviceID: operation.deviceId,
                        isDeleted: true,
                        deletedAt: currentVersion.deletedAt
                    ))
                }
                return
            }
            let incomingTask = try task(from: payload)
            let currentTask = try storedTask(id: incomingTask.id)
            let incomingWins = remoteVersionWins(
                lamport: operation.lamport,
                deviceID: operation.deviceId,
                over: currentVersion
            )

            if let currentTask,
               let merged = mergeCompletedOverPass(
                   incoming: incomingTask,
                   current: currentTask,
                   incomingWinsLWW: incomingWins
               ) {
                try upsertTaskRow(merged)
                let winningVersion = maximumVersion(
                    currentVersion,
                    incomingLamport: operation.lamport,
                    incomingDeviceID: operation.deviceId,
                    entityID: entityID
                )
                try upsertEntityVersion(winningVersion)
                return
            }
            if let currentTask,
               let settled = mergeSettledOverPending(
                   incoming: incomingTask,
                   current: currentTask
               ) {
                try upsertTaskRow(settled)
                let winningVersion = maximumVersion(
                    currentVersion,
                    incomingLamport: operation.lamport,
                    incomingDeviceID: operation.deviceId,
                    entityID: entityID
                )
                try upsertEntityVersion(winningVersion)
                return
            }
            guard incomingWins else { return }

            try upsertTaskRow(incomingTask)
            try upsertEntityVersion(EntityVersion(
                entityID: entityID,
                lamport: operation.lamport,
                deviceID: operation.deviceId,
                isDeleted: false,
                deletedAt: nil
            ))

        case .tombstone(let payload):
            guard operation.kind == .delete,
                  canonicalEntityID(payload.id) == entityID else {
                throw SQLiteRepositoryError.invalidRemotePage("tombstone 与外层元数据不一致")
            }
            if let currentVersion, currentVersion.isDeleted,
               !remoteVersionWins(
                   lamport: operation.lamport,
                   deviceID: operation.deviceId,
                   over: currentVersion
               ) {
                return
            }

            let horizon = maximumVersion(
                currentVersion,
                incomingLamport: operation.lamport,
                incomingDeviceID: operation.deviceId,
                entityID: entityID
            )

            try deleteTaskRow(entityID: entityID)
            try upsertEntityVersion(EntityVersion(
                entityID: entityID,
                lamport: horizon.lamport,
                deviceID: horizon.deviceID,
                isDeleted: true,
                deletedAt: payload.deletedAt
            ))
        }
    }

    private func remoteVersionWins(
        lamport: Int64,
        deviceID: String,
        over current: EntityVersion?
    ) -> Bool {
        guard let current else { return true }
        if lamport != current.lamport { return lamport > current.lamport }
        return deviceID > current.deviceID
    }

    /// completed/pass 是同一结算机会的竞争结果；截止前完成只覆盖状态字段，
    /// 其余字段仍取实体版本较新的完整快照，保证不同到达顺序最终一致。
    private func mergeCompletedOverPass(
        incoming: TodoTask,
        current: TodoTask,
        incomingWinsLWW: Bool
    ) -> TodoTask? {
        let completed: TodoTask
        guard (incoming.status == .completed && current.status == .pass)
                || (incoming.status == .pass && current.status == .completed) else {
            return nil
        }
        if incoming.status == .completed {
            completed = incoming
        } else {
            completed = current
        }
        guard isCompletionWithinDeadline(completed) else { return nil }

        var merged = incomingWinsLWW ? incoming : current
        merged.status = .completed
        merged.completedAt = completed.completedAt
        merged.updatedAt = max(merged.updatedAt, completed.updatedAt)
        return merged
    }

    /// pending 与已结算状态冲突时保留完整的结算快照，避免旧设备用较大的
    /// Lamport 把历史记录改回待完成；版本水位仍推进到两者中的较大值。
    private func mergeSettledOverPending(
        incoming: TodoTask,
        current: TodoTask
    ) -> TodoTask? {
        if current.status != .pending, incoming.status == .pending {
            return current
        }
        if current.status == .pending, incoming.status != .pending {
            return incoming
        }
        return nil
    }

    private func isCompletionWithinDeadline(_ task: TodoTask) -> Bool {
        guard task.status == .completed,
              let completedAt = task.completedAt else { return false }
        if task.timeScope == .anytime { return true }
        guard let deadline = task.period?.end else { return false }
        return completedAt < deadline
    }

    private func maximumVersion(
        _ current: EntityVersion?,
        incomingLamport: Int64,
        incomingDeviceID: String,
        entityID: String
    ) -> EntityVersion {
        if let current,
           !remoteVersionWins(
               lamport: incomingLamport,
               deviceID: incomingDeviceID,
               over: current
           ) {
            return EntityVersion(
                entityID: entityID,
                lamport: current.lamport,
                deviceID: current.deviceID,
                isDeleted: false,
                deletedAt: nil
            )
        }
        return EntityVersion(
            entityID: entityID,
            lamport: incomingLamport,
            deviceID: incomingDeviceID,
            isDeleted: false,
            deletedAt: nil
        )
    }

    private func task(from payload: WireTaskPayload) throws -> TodoTask {
        guard let id = UUID(uuidString: payload.id),
              let seriesID = UUID(uuidString: payload.seriesId),
              let sortIndex = Int(exactly: payload.sortOrder),
              let timeZone = TimeZone(identifier: payload.timezone) else {
            throw SQLiteRepositoryError.invalidRecord("远端任务的 ID、排序或时区无效")
        }
        let scope: TimeScope
        switch payload.timeType {
        case .day: scope = .daily
        case .week: scope = .weekly
        case .month: scope = .monthly
        case .someday: scope = .anytime
        }
        let tier: QuestTier
        switch payload.questLine {
        case .main: tier = .mainline
        case .side: tier = .side
        case .extra: tier = .extra
        }
        let status: TaskStatus
        switch payload.state {
        case .pending: status = .pending
        case .completed: status = .completed
        case .pass: status = .pass
        }
        let recurrence: RecurrenceRule
        switch payload.recurrence {
        case .once: recurrence = .once
        case .repeatRule: recurrence = .repeating(RepeatRule(frequency: scope))
        }

        let period: TaskPeriod?
        if let periodStart = payload.periodStart {
            guard let date = date(fromKey: periodStart, timeZone: timeZone),
                  let calculated = PeriodEngine(timeZone: timeZone)
                    .period(containing: date, for: scope),
                  calculated.start == date else {
                throw SQLiteRepositoryError.invalidRecord("远端任务的周期起点无效")
            }
            period = calculated
        } else {
            period = nil
        }
        let settledDate = payload.settledAt.map(date(fromMilliseconds:))
        return try TodoTask(
            id: id,
            seriesID: seriesID,
            title: payload.title,
            timeScope: scope,
            tier: tier,
            status: status,
            recurrence: recurrence,
            period: period,
            sortIndex: sortIndex,
            createdAt: date(fromMilliseconds: payload.createdAt),
            updatedAt: date(fromMilliseconds: payload.updatedAt),
            completedAt: status == .pending ? nil : settledDate
        )
    }

    private func upsertTaskRow(_ task: TodoTask) throws {
        let recurrenceData = try encoder.encode(task.recurrence)
        guard let recurrenceJSON = String(data: recurrenceData, encoding: .utf8) else {
            throw SQLiteRepositoryError.invalidRecord("重复规则无法编码")
        }
        let statement = try prepare(
            """
            INSERT INTO tasks (
                id, series_id, title, time_scope, tier, status,
                recurrence_json, period_start, period_end, sort_index,
                created_at, updated_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                series_id = excluded.series_id,
                title = excluded.title,
                time_scope = excluded.time_scope,
                tier = excluded.tier,
                status = excluded.status,
                recurrence_json = excluded.recurrence_json,
                period_start = excluded.period_start,
                period_end = excluded.period_end,
                sort_index = excluded.sort_index,
                updated_at = excluded.updated_at,
                completed_at = excluded.completed_at
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(task.id.uuidString),
            .text(task.seriesID.uuidString),
            .text(task.title),
            .text(task.timeScope.rawValue),
            .text(task.tier.rawValue),
            .text(task.status.rawValue),
            .text(recurrenceJSON),
            task.period.map { .double($0.start.timeIntervalSince1970) } ?? .null,
            task.period.map { .double($0.end.timeIntervalSince1970) } ?? .null,
            .integer(Int64(task.sortIndex)),
            .double(task.createdAt.timeIntervalSince1970),
            .double(task.updatedAt.timeIntervalSince1970),
            task.completedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func deleteTaskRow(entityID: String) throws {
        let statement = try prepare("DELETE FROM tasks WHERE lower(id) = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(entityID.lowercased())], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func storedTask(id: UUID) throws -> TodoTask? {
        try query(
            """
            SELECT id, series_id, title, time_scope, tier, status,
                   recurrence_json, period_start, period_end, sort_index,
                   created_at, updated_at, completed_at
            FROM tasks WHERE id = ? LIMIT 1
            """,
            bindings: [.text(id.uuidString)]
        ).first
    }

    private func entityVersion(for entityID: String) throws -> EntityVersion? {
        let statement = try prepare(
            """
            SELECT lamport, device_id, is_deleted, deleted_at
            FROM sync_entity_versions WHERE entity_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(entityID)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            return EntityVersion(
                entityID: entityID,
                lamport: sqlite3_column_int64(statement, 0),
                deviceID: text(at: 1, from: statement),
                isDeleted: sqlite3_column_int(statement, 2) != 0,
                deletedAt: sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_int64(statement, 3)
            )
        default:
            throw statementError()
        }
    }

    private func upsertEntityVersion(_ version: EntityVersion) throws {
        let statement = try prepare(
            """
            INSERT INTO sync_entity_versions(
                entity_id, lamport, device_id, is_deleted, deleted_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(entity_id) DO UPDATE SET
                lamport = excluded.lamport,
                device_id = excluded.device_id,
                is_deleted = excluded.is_deleted,
                deleted_at = excluded.deleted_at
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(version.entityID),
            .integer(version.lamport),
            .text(version.deviceID),
            .integer(version.isDeleted ? 1 : 0),
            version.deletedAt.map(SQLiteValue.integer) ?? .null,
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func isOperationApplied(_ operationID: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sync_applied_operations WHERE op_id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(operationID)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw statementError()
        }
    }

    private func recordAppliedOperation(_ operation: SyncPulledOperation) throws {
        let statement = try prepare(
            """
            INSERT INTO sync_applied_operations(op_id, server_seq, applied_at)
            VALUES (?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(operation.opId),
            .integer(operation.serverSeq),
            .integer(milliseconds(since1970: Date())),
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func advanceLamportClock(toAtLeast incoming: Int64) throws {
        let statement = try prepare(
            "UPDATE sync_state SET lamport = MAX(lamport, ?) WHERE singleton = 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(incoming)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func syncStateNumber(column: String) throws -> Int64 {
        guard column == "cursor" || column == "lamport" else {
            throw SQLiteRepositoryError.invalidRecord("未知同步状态字段")
        }
        let statement = try prepare(
            "SELECT \(column) FROM sync_state WHERE singleton = 1"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw statementError() }
        return sqlite3_column_int64(statement, 0)
    }

    private func dateKey(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func date(fromKey value: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value),
              formatter.string(from: date) == value else { return nil }
        return date
    }

    private func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func date(fromMilliseconds value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1_000)
    }

    private func canonicalEntityID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    private struct SyncIdentity {
        let vaultId: String
        let deviceId: String
    }

    private struct EntityVersion {
        let entityID: String
        let lamport: Int64
        let deviceID: String
        let isDeleted: Bool
        let deletedAt: Int64?
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw SQLiteRepositoryError.openFailed("连接已关闭") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw SQLiteRepositoryError.statementFailed(message)
        }
    }

    private func query(
        _ sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> [TodoTask] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var tasks: [TodoTask] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                tasks.append(try decodeTask(from: statement))
            case SQLITE_DONE:
                return tasks
            default:
                throw statementError()
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw SQLiteRepositoryError.openFailed("连接已关闭") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw statementError()
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text):
                result = text.withCString {
                    sqlite3_bind_text(
                        statement,
                        index,
                        $0,
                        -1,
                        Self.transientDestructor
                    )
                }
            case let .double(number):
                result = sqlite3_bind_double(statement, index, number)
            case let .integer(number):
                result = sqlite3_bind_int64(statement, index, number)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw statementError() }
        }
    }

    private func decodeTask(from statement: OpaquePointer) throws -> TodoTask {
        guard
            let id = UUID(uuidString: text(at: 0, from: statement)),
            let seriesID = UUID(uuidString: text(at: 1, from: statement)),
            let scope = TimeScope(rawValue: text(at: 3, from: statement)),
            let tier = QuestTier(rawValue: text(at: 4, from: statement)),
            let status = TaskStatus(rawValue: text(at: 5, from: statement)),
            let recurrenceData = text(at: 6, from: statement).data(using: .utf8)
        else {
            throw SQLiteRepositoryError.invalidRecord("枚举或标识符无法解析")
        }

        let recurrence: RecurrenceRule
        do {
            recurrence = try decoder.decode(RecurrenceRule.self, from: recurrenceData)
        } catch {
            throw SQLiteRepositoryError.invalidRecord("重复规则无法解析")
        }

        let period: TaskPeriod?
        if sqlite3_column_type(statement, 7) == SQLITE_NULL {
            period = nil
        } else {
            period = TaskPeriod(
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            )
        }

        return try TodoTask(
            id: id,
            seriesID: seriesID,
            title: text(at: 2, from: statement),
            timeScope: scope,
            tier: tier,
            status: status,
            recurrence: recurrence,
            period: period,
            sortIndex: Int(sqlite3_column_int64(statement, 9)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
            completedAt: optionalDate(at: 12, from: statement)
        )
    }

    private func text(at index: Int32, from statement: OpaquePointer) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func optionalDate(at index: Int32, from statement: OpaquePointer) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func statementError() -> SQLiteRepositoryError {
        guard let database else { return .statementFailed("连接已关闭") }
        return .statementFailed(String(cString: sqlite3_errmsg(database)))
    }

    private func withLock<T>(_ action: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try action()
    }

    private enum SQLiteValue {
        case text(String)
        case double(Double)
        case integer(Int64)
        case null
    }
}
