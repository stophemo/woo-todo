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
public final class SQLiteTaskRepository: TaskRepository, SyncOutbox, SyncLocalApplying,
    WebDavLocalApplying, @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var syncConfiguration: SQLiteSyncConfiguration?
    private var hasPersistedSyncIdentity = false

    public static let displayConfigurationEntityID = WireDisplayConfigurationPayload.fixedID

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
                       created_at, updated_at, completed_at, reminder_time, deadline_date
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
                        created_at, updated_at, completed_at, reminder_time, deadline_date
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        completed_at = excluded.completed_at,
                        reminder_time = excluded.reminder_time,
                        deadline_date = excluded.deadline_date
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
                    let recurrenceJSON = "{\"once\":{}}"
                    let calendar = TodoTask.protocolCalendar
                    let periodEnd = task.endDate.flatMap {
                        calendar.date(byAdding: .day, value: 1, to: $0)
                    }
                    let values: [SQLiteValue] = [
                        .text(task.id.uuidString),
                        .text(task.seriesID.uuidString),
                        .text(task.title),
                        .text(task.startDate == nil ? "someday" : "day"),
                        .text(task.categoryID),
                        .text(task.status.rawValue),
                        .text(recurrenceJSON),
                        task.startDate.map { .double($0.timeIntervalSince1970) } ?? .null,
                        periodEnd.map { .double($0.timeIntervalSince1970) } ?? .null,
                        .integer(Int64(task.sortIndex)),
                        .double(task.createdAt.timeIntervalSince1970),
                        .double(task.updatedAt.timeIntervalSince1970),
                        task.completedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                        task.reminderTime.map { .text($0.wireValue) } ?? .null,
                        task.endDate.map { .double($0.timeIntervalSince1970) } ?? .null
                    ]
                    try bind(values, to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw statementError()
                    }
                    let kind = operationKind(previous: existing, current: task)
                    if let configuration = syncConfiguration {
                        try enqueueLocalTask(
                            task,
                            kind: kind,
                            configuration: configuration
                        )
                    } else if hasPersistedSyncIdentity {
                        try recordDeferredUpsert(entityID: entityID, kind: kind)
                    }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    @discardableResult
    public func reopenCompleted(id: UUID, at date: Date) throws -> Bool {
        try withLock {
            guard var task = try storedTask(id: id),
                  task.status == .completed else { return false }

            task.status = .pending
            task.completedAt = nil
            task.updatedAt = date
            let entityID = canonicalEntityID(id.uuidString)
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try upsertTaskRow(task)
                if let configuration = syncConfiguration {
                    try enqueueLocalTask(task, kind: .reopen, configuration: configuration)
                } else if hasPersistedSyncIdentity {
                    try recordDeferredUpsert(entityID: entityID, kind: .reopen)
                }
                try execute("COMMIT")
                return true
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
                let deletedAt = Date()
                if let existing {
                    try insertTrashRow(existing, deletedAt: deletedAt)
                }
                try deleteTaskRow(entityID: entityID)
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

    public func fetchTrash() throws -> [TrashedTask] {
        try withLock {
            let statement = try prepare(
                """
                SELECT id, series_id, title, time_scope, tier, status,
                       recurrence_json, period_start, period_end, sort_index,
                       created_at, updated_at, completed_at, reminder_time,
                       deadline_date, deleted_at
                FROM trash_tasks
                ORDER BY deleted_at DESC, id ASC
                """
            )
            defer { sqlite3_finalize(statement) }
            var values: [TrashedTask] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                values.append(try decodeTrashedTask(from: statement))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw statementError() }
            return values
        }
    }

    public func trashCount() throws -> Int {
        try withLock {
            let statement = try prepare("SELECT COUNT(*) FROM trash_tasks")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw statementError()
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    @discardableResult
    public func restoreTrash(id: UUID, at date: Date) throws -> UUID? {
        try withLock {
            guard let trashed = try storedTrashTask(id: id) else { return nil }
            let categoryID = try queryCategories().contains(where: { $0.id == trashed.task.categoryID })
                ? trashed.task.categoryID
                : TaskCategory.inboxID
            let newID = UUID()
            // 保留 seriesID，便于其他设备按“seriesID + 内容”识别这是同一条任务的恢复。
            let restoredSeriesID = trashed.task.seriesID
            let restored = try TodoTask(
                id: newID,
                seriesID: restoredSeriesID,
                title: trashed.task.title,
                categoryID: categoryID,
                status: .pending,
                startDate: trashed.task.startDate,
                endDate: trashed.task.endDate,
                sortIndex: trashed.task.sortIndex,
                createdAt: trashed.task.createdAt,
                updatedAt: date,
                reminderTime: trashed.task.reminderTime,
                completedAt: nil
            )

            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try upsertTaskRow(restored)
                let entityID = canonicalEntityID(restored.id.uuidString)
                if let configuration = syncConfiguration {
                    try enqueueLocalTask(restored, kind: .upsert, configuration: configuration)
                } else if hasPersistedSyncIdentity {
                    try recordDeferredUpsert(entityID: entityID, kind: .upsert)
                }
                try deleteTrashRow(entityID: canonicalEntityID(id.uuidString))
                try execute("COMMIT")
                return restored.id
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    @discardableResult
    public func removeTrash(ids: Set<UUID>?) throws -> Int {
        if ids?.isEmpty == true { return 0 }
        return try withLock {
            let statement = try prepare("SELECT id FROM trash_tasks")
            defer { sqlite3_finalize(statement) }
            var targets: [String] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let value = text(at: 0, from: statement)
                if let id = UUID(uuidString: value),
                   ids == nil || ids?.contains(id) == true {
                    targets.append(canonicalEntityID(value))
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw statementError() }
            guard !targets.isEmpty else { return 0 }

            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                for entityID in targets {
                    try deleteTrashRow(entityID: entityID)
                }
                try execute("COMMIT")
                return targets.count
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    @discardableResult
    public func clearHistory(ids: Set<UUID>?) throws -> Int {
        if ids?.isEmpty == true { return 0 }
        return try withLock {
            let settled = try query(
                """
                SELECT id, series_id, title, time_scope, tier, status,
                       recurrence_json, period_start, period_end, sort_index,
                       created_at, updated_at, completed_at, reminder_time, deadline_date
                FROM tasks WHERE status IN ('completed', 'pass')
                """
            )
            let targets = settled.filter { task in
                ids == nil || ids?.contains(task.id) == true
            }
            guard !targets.isEmpty else { return 0 }

            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                let deletedAt = Date()
                for task in targets {
                    let entityID = canonicalEntityID(task.id.uuidString)
                    try deleteTaskRow(entityID: entityID)
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
                }
                try execute("COMMIT")
                return targets.count
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func fetchCategories() throws -> [TaskCategory] {
        try withLock {
            let values = try queryCategories()
            return values.isEmpty ? TaskCategory.defaults : values
        }
    }

    public func saveCategories(_ categories: [TaskCategory]) throws {
        let normalized = TaskCategory.normalizeList(categories)
        try withLock {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute("DELETE FROM task_categories")
                let statement = try prepare(
                    """
                    INSERT INTO task_categories(id, name, sort_order, updated_at)
                    VALUES (?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(statement) }
                let now = Date().timeIntervalSince1970
                for category in normalized {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind([
                        .text(category.id),
                        .text(category.name),
                        .integer(Int64(category.order)),
                        .double(now),
                    ], to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw statementError()
                    }
                }
                if let configuration = syncConfiguration {
                    try enqueueLocalDisplayConfiguration(
                        Self.categorySyncPayload(normalized),
                        configuration: configuration
                    )
                } else if hasPersistedSyncIdentity {
                    try recordDeferredDisplayConfiguration()
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private static func categorySyncPayload(
        _ categories: [TaskCategory]
    ) throws -> WireDisplayConfigurationPayload {
        try WireDisplayConfigurationPayload(
            headerTemplate: "",
            subtitleTemplate: "",
            startDate: "2000-01-01",
            deadlineDate: "2000-01-01",
            questLines: try categories.map { category in
                try WireQuestLineDefinition(
                    id: category.id,
                    name: category.name,
                    order: category.order
                )
            }
        )
    }

    @discardableResult
    public func reassignPendingCategory(
        from: String,
        to: String,
        at date: Date
    ) throws -> Int {
        let tasks = try fetchAll().filter {
            $0.status == .pending && $0.categoryID == from
        }
        guard !tasks.isEmpty else { return 0 }
        let updated = tasks.map { task in
            var value = task
            value.categoryID = to
            value.updatedAt = date
            return value
        }
        try save(updated)
        return updated.count
    }

    private func queryCategories() throws -> [TaskCategory] {
        let statement = try prepare(
            "SELECT id, name, sort_order FROM task_categories ORDER BY sort_order ASC, id ASC"
        )
        defer { sqlite3_finalize(statement) }
        var values: [TaskCategory] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let id = text(at: 0, from: statement)
            let name = text(at: 1, from: statement)
            let order = Int(sqlite3_column_int64(statement, 2))
            if let category = try? TaskCategory(id: id, name: name, order: order) {
                values.append(category)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw statementError() }
        return values
    }

    /// v0.2.4 曾把所有新库写成未分类 + 主线 + 支线 + 外传。
    /// 升级时只移除没有被任务使用的默认类型，保留用户自定义或已使用的类型。
    private func removeUnusedLegacyCategories() throws {
        try execute(
            """
            DELETE FROM task_categories
            WHERE id IN ('main', 'side', 'extra')
              AND name IN ('主线', '支线', '外传')
              AND NOT EXISTS (
                  SELECT 1 FROM tasks WHERE tasks.tier = task_categories.id
              )
            """
        )
        let categories = try queryCategories()
        let statement = try prepare(
            "UPDATE task_categories SET sort_order = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        for (index, category) in categories.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind([.integer(Int64(index)), .text(category.id)], to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw statementError()
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
                completed_at REAL,
                reminder_time TEXT,
                deadline_date REAL
            )
            """
        )
        if try !taskTableHasColumn("reminder_time") {
            try execute("ALTER TABLE tasks ADD COLUMN reminder_time TEXT")
        }
        if try !taskTableHasColumn("deadline_date") {
            try execute("ALTER TABLE tasks ADD COLUMN deadline_date REAL")
        }
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_period ON tasks(time_scope, period_start, period_end)"
        )
        // 本机恢复快照：删除任务时保留一份完整副本，恢复时以新任务 ID 重新入队。
        try execute(
            """
            CREATE TABLE IF NOT EXISTS trash_tasks (
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
                completed_at REAL,
                reminder_time TEXT,
                deadline_date REAL,
                deleted_at REAL NOT NULL
            )
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_trash_tasks_deleted_at ON trash_tasks(deleted_at)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_trash_tasks_series_id ON trash_tasks(series_id)"
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
        // 恢复快照会复用原 seriesID；允许多台设备各自恢复同一条任务，
        // 避免旧周期唯一索引让第二台设备的恢复任务无法落地、阻塞整页同步。
        try execute("DROP INDEX IF EXISTS idx_tasks_occurrence")
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_occurrence ON tasks(series_id, time_scope, period_start) WHERE period_start IS NOT NULL"
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
            CREATE TABLE IF NOT EXISTS sync_webdav_applied_operations (
                op_id TEXT PRIMARY KEY NOT NULL,
                applied_at INTEGER NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_deferred_upserts (
                entity_id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL DEFAULT 'upsert'
            )
            """
        )
        if try !tableHasColumn("sync_deferred_upserts", columnName: "kind") {
            try execute(
                "ALTER TABLE sync_deferred_upserts ADD COLUMN kind TEXT NOT NULL DEFAULT 'upsert'"
            )
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_deferred_deletions (
                entity_id TEXT PRIMARY KEY NOT NULL,
                deleted_at INTEGER NOT NULL CHECK (deleted_at >= 0)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_deferred_display_configuration (
                singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
                is_dirty INTEGER NOT NULL CHECK (is_dirty = 1)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_display_configuration (
                entity_id TEXT PRIMARY KEY NOT NULL,
                header_template TEXT NOT NULL,
                subtitle_template TEXT NOT NULL,
                start_date TEXT NOT NULL,
                deadline_date TEXT NOT NULL,
                is_local_override INTEGER NOT NULL DEFAULT 0
                    CHECK (is_local_override IN (0, 1))
            )
            """
        )
        if try !tableHasColumn("sync_display_configuration", columnName: "is_local_override") {
            try execute(
                "ALTER TABLE sync_display_configuration ADD COLUMN is_local_override INTEGER NOT NULL DEFAULT 1"
            )
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS task_categories (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        let now = Date().timeIntervalSince1970
        for category in TaskCategory.defaults {
            try execute(
                """
                INSERT OR IGNORE INTO task_categories(id, name, sort_order, updated_at)
                VALUES ('\(category.id)', '\(category.name.replacingOccurrences(of: "'", with: "''"))', \(category.order), \(now))
                """
            )
        }
        try removeUnusedLegacyCategories()
        try execute("PRAGMA user_version = 8")
    }

    public func displayConfiguration() throws -> WireDisplayConfigurationPayload? {
        try withLock {
            let statement = try prepare(
                """
                SELECT header_template, subtitle_template, start_date, deadline_date
                FROM sync_display_configuration WHERE entity_id = ? LIMIT 1
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind([.text(Self.displayConfigurationEntityID)], to: statement)
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                return try WireDisplayConfigurationPayload(
                    headerTemplate: text(at: 0, from: statement),
                    subtitleTemplate: text(at: 1, from: statement),
                    startDate: text(at: 2, from: statement),
                    deadlineDate: text(at: 3, from: statement)
                )
            default:
                throw statementError()
            }
        }
    }

    public func saveDisplayConfiguration(_ payload: WireDisplayConfigurationPayload) throws {
        try withLock {
            try payload.validate()
            if try displayConfiguration() == payload,
               try displayConfigurationIsLocalOverride() { return }
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try upsertDisplayConfiguration(payload, isLocalOverride: true)
                // 今日标题、副标题与计时模板属于个人偏好：只留在本机，
                // 既不进 outbox，也不会被别人加入同一同步空间后看到。
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func seedDisplayConfiguration(_ payload: WireDisplayConfigurationPayload) throws {
        try withLock {
            try payload.validate()
            guard try displayConfiguration() == nil else { return }
            try upsertDisplayConfiguration(payload, isLocalOverride: false)
        }
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
                try bindUnboundSync(configuration)
                try execute("COMMIT")
                syncConfiguration = configuration
                hasPersistedSyncIdentity = true
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// 清除当前同步空间的本地元数据，但保留任务与显示配置。
    /// 下次 configureSync 会把保留的数据作为新空间的本地快照重新入队。
    public func resetSyncBinding() throws {
        try withLock {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try resetSyncMetadata()
                try execute("COMMIT")
                syncConfiguration = nil
                hasPersistedSyncIdentity = false
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// 切换同步方式时在同一事务中清理旧空间并绑定新空间，避免留下半重置状态。
    public func replaceSyncBinding(
        with configuration: SQLiteSyncConfiguration,
        remoteLamportFloor: Int64 = 0
    ) throws {
        try withLock {
            try validate(configuration)
            guard remoteLamportFloor >= 0, remoteLamportFloor < Int64.max else {
                throw SQLiteRepositoryError.invalidSyncConfiguration("远端 Lamport 水位无效")
            }
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try resetSyncMetadata()
                let statement = try prepare(
                    "UPDATE sync_state SET lamport = ? WHERE singleton = 1"
                )
                defer { sqlite3_finalize(statement) }
                try bind([.integer(remoteLamportFloor)], to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
                try bindUnboundSync(configuration)
                try execute("COMMIT")
                syncConfiguration = configuration
                hasPersistedSyncIdentity = true
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func resetSyncMetadata() throws {
        try execute("DELETE FROM sync_outbox")
        try execute("DELETE FROM sync_entity_versions")
        try execute("DELETE FROM sync_applied_operations")
        try execute("DELETE FROM sync_webdav_applied_operations")
        try execute("DELETE FROM sync_deferred_upserts")
        try execute("DELETE FROM sync_deferred_deletions")
        try execute("DELETE FROM sync_deferred_display_configuration")
        try execute(
            """
            UPDATE sync_state
            SET vault_id = NULL, device_id = NULL, cursor = 0, lamport = 0
            WHERE singleton = 1
            """
        )
        try execute(
            "UPDATE sync_display_configuration SET is_local_override = 1"
        )
    }

    private func bindUnboundSync(_ configuration: SQLiteSyncConfiguration) throws {
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
                   created_at, updated_at, completed_at, reminder_time, deadline_date
            FROM tasks
            ORDER BY created_at, id
            """
        ) {
            try enqueueLocalTask(task, kind: .upsert, configuration: configuration)
        }
        let categories = TaskCategory.normalizeList(try queryCategories())
        if categories != TaskCategory.defaults {
            try enqueueLocalDisplayConfiguration(
                Self.categorySyncPayload(categories),
                configuration: configuration
            )
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
        try execute("DELETE FROM sync_deferred_display_configuration")
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

    public func applyWebDavOperations(_ operations: [WebDavOperation]) async throws {
        // WebDAV 远端对象可能很多；小批次落地避免长时间独占本地写锁，
        // 让用户操作可以在同步期间继续写入任务。
        for start in stride(from: 0, to: operations.count, by: Self.webDavApplyBatchSize) {
            let end = min(start + Self.webDavApplyBatchSize, operations.count)
            try applyWebDavOperationsSynchronously(Array(operations[start..<end]))
            await Task.yield()
        }
    }

    public func resetCursor() async throws {
        try withLock {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                // 服务端状态丢失重建后（CURSOR_AHEAD）把本地 cursor 重置为 0，
                // 并清空 sync_applied_operations：重建后的服务端会从序号 1 重新编号，
                // 旧记录的 server_seq 与新建 op 冲突（UNIQUE 约束），且旧 opId 不会再出现，
                // 幂等性由 LWW 与实体版本表保证。outbox 保持不变。
                try execute("UPDATE sync_state SET cursor = 0 WHERE singleton = 1")
                try execute("DELETE FROM sync_applied_operations")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func pendingWebDavOperationIDs(_ operationIDs: [String]) async throws -> Set<String> {
        try withLock {
            var pending = Set<String>()
            for operationID in Set(operationIDs) {
                if try !isWebDavOperationApplied(operationID) {
                    pending.insert(operationID)
                }
            }
            return pending
        }
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
                // 只保留最近 10000 条 applied 记录，防止表无限增长；
                // 幂等性由 LWW 与实体版本表保证，裁剪不影响重复应用的正确性。
                try trimSyncAppliedOperations(keepingServerSeqAtLeast: cursor - Self.appliedOperationRetentionWindow + 1)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func applyWebDavOperationsSynchronously(
        _ operations: [WebDavOperation]
    ) throws {
        try withLock {
            guard let configuration = syncConfiguration else {
                throw SQLiteRepositoryError.syncCredentialsUnavailable
            }
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                for operation in operations {
                    guard operation.vaultId == configuration.vaultId else {
                        throw SQLiteRepositoryError.invalidRemotePage("WebDAV 同步空间不匹配")
                    }
                    if try isWebDavOperationApplied(operation.opId) { continue }
                    if try !isOperationApplied(operation.opId) {
                        try applyRemoteOperation(
                            SyncPulledOperation(
                                serverSeq: 1,
                                opId: operation.opId,
                                deviceId: operation.deviceId,
                                entityId: operation.entityId,
                                kind: operation.kind,
                                lamport: operation.lamport,
                                ciphertext: operation.ciphertext,
                                nonce: operation.nonce,
                                createdAt: milliseconds(since1970: Date())
                            ),
                            configuration: configuration
                        )
                        try advanceLamportClock(toAtLeast: operation.lamport)
                    }
                    try recordWebDavOperation(operation.opId)
                }
                // 只保留最近 10000 条 WebDAV applied 记录，防止表无限增长；
                // 幂等性由 LWW 与实体版本表保证。
                try trimWebDavAppliedOperations(retaining: Self.appliedOperationRetentionWindow)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private static let webDavApplyBatchSize = 25

    /// applied 记录保留窗口：同步（按 server_seq）与 WebDAV（按 applied_at）各保留最近 10000 条。
    private static let appliedOperationRetentionWindow: Int64 = 10_000

    private func trimSyncAppliedOperations(keepingServerSeqAtLeast lowerBound: Int64) throws {
        // 删除 server_seq < lowerBound 的旧记录；lowerBound <= 1 时不删除任何行。
        let statement = try prepare("DELETE FROM sync_applied_operations WHERE server_seq < ?")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(lowerBound)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func trimWebDavAppliedOperations(retaining count: Int64) throws {
        let statement = try prepare(
            """
            DELETE FROM sync_webdav_applied_operations
            WHERE op_id IN (
                SELECT op_id FROM (
                    SELECT op_id FROM sync_webdav_applied_operations
                    ORDER BY applied_at DESC
                    LIMIT -1 OFFSET ?
                )
            )
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(count)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    /// 测试用：返回 sync_applied_operations 的行数（有界性断言）。
    internal func syncAppliedOperationCount() throws -> Int {
        try withLock { try scalarCount("SELECT COUNT(*) FROM sync_applied_operations") }
    }

    /// 测试用：返回 sync_webdav_applied_operations 的行数（有界性断言）。
    internal func webDavAppliedOperationCount() throws -> Int {
        try withLock { try scalarCount("SELECT COUNT(*) FROM sync_webdav_applied_operations") }
    }

    private func scalarCount(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw statementError() }
        return Int(sqlite3_column_int64(statement, 0))
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

    private func recordDeferredUpsert(
        entityID: String,
        kind: SyncOperationKind
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO sync_deferred_upserts(entity_id, kind) VALUES (?, ?)
            ON CONFLICT(entity_id) DO UPDATE SET kind = CASE
                WHEN sync_deferred_upserts.kind = 'reopen'
                    AND excluded.kind IN ('upsert', 'reorder') THEN 'reopen'
                ELSE excluded.kind
            END
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(entityID), .text(kind.rawValue)], to: statement)
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

    private func recordDeferredDisplayConfiguration() throws {
        try execute(
            """
            INSERT OR REPLACE INTO sync_deferred_display_configuration(singleton, is_dirty)
            VALUES (1, 1)
            """
        )
    }

    private func hasDeferredDisplayConfiguration() throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sync_deferred_display_configuration WHERE singleton = 1 LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw statementError()
        }
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
        let deferredKinds = try deferredUpsertKinds()

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for task in try query(
                """
                SELECT tasks.id, tasks.series_id, tasks.title, tasks.time_scope,
                       tasks.tier, tasks.status, tasks.recurrence_json,
                       tasks.period_start, tasks.period_end, tasks.sort_index,
                       tasks.created_at, tasks.updated_at, tasks.completed_at,
                       tasks.reminder_time, tasks.deadline_date
                FROM tasks
                INNER JOIN sync_deferred_upserts
                    ON sync_deferred_upserts.entity_id = lower(tasks.id)
                ORDER BY tasks.created_at, tasks.id
                """
            ) {
                try enqueueLocalTask(
                    task,
                    kind: deferredKinds[task.id] ?? .upsert,
                    configuration: configuration
                )
            }

            if try hasDeferredDisplayConfiguration() {
                try enqueueLocalDisplayConfiguration(
                    Self.categorySyncPayload(TaskCategory.normalizeList(try queryCategories())),
                    configuration: configuration
                )
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
            try execute("DELETE FROM sync_deferred_display_configuration")
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
                OR EXISTS(SELECT 1 FROM sync_deferred_display_configuration)
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
                AND NOT EXISTS(SELECT 1 FROM sync_webdav_applied_operations)
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

    private func deferredUpsertKinds() throws -> [UUID: SyncOperationKind] {
        let statement = try prepare(
            "SELECT entity_id, kind FROM sync_deferred_upserts ORDER BY entity_id"
        )
        defer { sqlite3_finalize(statement) }
        var values: [UUID: SyncOperationKind] = [:]
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = UUID(uuidString: text(at: 0, from: statement)),
                  let kind = SyncOperationKind(rawValue: text(at: 1, from: statement)) else {
                throw SQLiteRepositoryError.invalidRecord("待同步任务包含无效操作类型")
            }
            values[id] = kind
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
            case .pending: return .reopen
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

    private func enqueueLocalDisplayConfiguration(
        _ configurationPayload: WireDisplayConfigurationPayload,
        configuration: SQLiteSyncConfiguration
    ) throws {
        let entityID = Self.displayConfigurationEntityID
        let lamport = try nextLamport()
        let operationID = UUID().uuidString.lowercased()
        let metadata = SyncAADMetadata(
            vaultId: configuration.vaultId,
            operationId: operationID,
            entityId: entityID,
            kind: .upsert,
            lamport: lamport,
            deviceId: configuration.deviceId
        )
        let envelope = try TaskPayloadCodec.seal(
            .displayConfiguration(configurationPayload),
            vaultKey: configuration.vaultKey,
            metadata: metadata
        )
        try insertOutbox(
            operationID: operationID,
            entityID: entityID,
            kind: .upsert,
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
        let ranged = task.startDate != nil && task.endDate != nil
        let state: WireTaskState
        switch task.status {
        case .pending: state = .pending
        case .completed: state = .completed
        case .pass: state = .pass
        }
        let settledAt = task.status == .pending
            ? nil
            : milliseconds(since1970: task.completedAt ?? task.updatedAt)

        return try WireTaskPayload(
            id: canonicalEntityID(task.id.uuidString),
            seriesId: canonicalEntityID(task.seriesID.uuidString),
            title: task.title,
            timeType: ranged ? .day : .someday,
            periodStart: task.startDate.map { dateKey($0, timeZone: timeZone) },
            deadlineDate: task.endDate.map { dateKey($0, timeZone: timeZone) },
            timezone: timeZone.identifier,
            questLine: task.categoryID,
            state: state,
            recurrence: .once,
            sortOrder: Int64(task.sortIndex),
            createdAt: milliseconds(since1970: task.createdAt),
            updatedAt: milliseconds(since1970: task.updatedAt),
            reminderTime: ranged ? task.reminderTime?.wireValue : nil,
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
                  entityID != Self.displayConfigurationEntityID,
                  canonicalEntityID(payload.id) == entityID else {
                throw SQLiteRepositoryError.invalidRemotePage("任务正文与外层元数据不一致")
            }
            if operation.kind == .complete && payload.state != .completed {
                throw SQLiteRepositoryError.invalidRemotePage("complete 操作正文不是完成状态")
            }
            if operation.kind == .pass && payload.state != .pass {
                throw SQLiteRepositoryError.invalidRemotePage("pass 操作正文不是 Pass 状态")
            }
            if operation.kind == .reopen && payload.state != .pending {
                throw SQLiteRepositoryError.invalidRemotePage("reopen 操作正文不是待办状态")
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

            if operation.kind == .reopen {
                guard isValidReopen(incomingTask) else {
                    throw SQLiteRepositoryError.invalidRemotePage("reopen 操作超出可撤销周期")
                }
                guard incomingWins else { return }
                try upsertTaskRow(incomingTask)
                try removeMatchingTrashRows(for: incomingTask)
                try upsertEntityVersion(EntityVersion(
                    entityID: entityID,
                    lamport: operation.lamport,
                    deviceID: operation.deviceId,
                    isDeleted: false,
                    deletedAt: nil
                ))
                return
            }

            if let currentTask,
               let merged = mergeCompletedOverPass(
                   incoming: incomingTask,
                   current: currentTask,
                   incomingWinsLWW: incomingWins
               ) {
                try upsertTaskRow(merged)
                try removeMatchingTrashRows(for: merged)
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
                try removeMatchingTrashRows(for: settled)
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
            try removeMatchingTrashRows(for: incomingTask)
            try upsertEntityVersion(EntityVersion(
                entityID: entityID,
                lamport: operation.lamport,
                deviceID: operation.deviceId,
                isDeleted: false,
                deletedAt: nil
            ))

        case .tombstone(let payload):
            guard operation.kind == .delete,
                  entityID != Self.displayConfigurationEntityID,
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

            // 删除前保留本机恢复快照。若同一 seriesID 已有恢复后的新任务，
            // 说明这是一条已被其他设备恢复的旧任务，不再重复放入最近删除。
            if let taskID = UUID(uuidString: entityID),
               let currentTask = try storedTask(id: taskID),
               currentTask.status == .pending,
               !(try liveTaskMatches(
                   seriesID: currentTask.seriesID,
                   content: currentTask,
                   excludingID: currentTask.id
               )) {
                try insertTrashRow(
                    currentTask,
                    deletedAt: date(fromMilliseconds: payload.deletedAt)
                )
            }

            // 删除由本次 tombstone 触发：版本标识（lamport/deviceID）与删除时间必须同源，
            // 都取本次 tombstone，避免“lamport 属高版本活跃记录、deletedAt 属低版本 tombstone”
            // 的自相矛盾记录，保证备份导出的删除时间与记录版本一致。
            try deleteTaskRow(entityID: entityID)
            try upsertEntityVersion(EntityVersion(
                entityID: entityID,
                lamport: operation.lamport,
                deviceID: operation.deviceId,
                isDeleted: true,
                deletedAt: payload.deletedAt
            ))

        case .displayConfiguration(let payload):
            guard operation.kind == .upsert,
                  payload.id == entityID,
                  entityID == Self.displayConfigurationEntityID else {
                throw SQLiteRepositoryError.invalidRemotePage(
                    "显示配置正文与外层元数据不一致"
                )
            }
            // 显示配置已改为设备本地设置：远端内容只推进版本水位，不覆盖本机偏好。
            guard remoteVersionWins(
                lamport: operation.lamport,
                deviceID: operation.deviceId,
                over: currentVersion
            ) else { return }
            try upsertEntityVersion(EntityVersion(
                entityID: entityID,
                lamport: operation.lamport,
                deviceID: operation.deviceId,
                isDeleted: false,
                deletedAt: nil
            ))
            if !payload.questLines.isEmpty {
                try replaceCategoriesFromRemote(payload.questLines)
                try reconcileUnknownPendingCategories()
            }
        }
    }

    private func replaceCategoriesFromRemote(
        _ definitions: [WireQuestLineDefinition]
    ) throws {
        let categories = TaskCategory.normalizeList(
            try definitions.map { definition in
                try TaskCategory(
                    id: definition.id,
                    name: definition.name,
                    order: definition.order
                )
            }
        )
        try execute("DELETE FROM task_categories")
        let statement = try prepare(
            """
            INSERT INTO task_categories(id, name, sort_order, updated_at)
            VALUES (?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        for category in categories {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind([
                .text(category.id),
                .text(category.name),
                .integer(Int64(category.order)),
                .double(now),
            ], to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
        }
    }

    private func reconcileUnknownPendingCategories() throws {
        let known = Set(try queryCategories().map(\.id))
        let pending = try query(
            """
            SELECT id, series_id, title, time_scope, tier, status,
                   recurrence_json, period_start, period_end, sort_index,
                   created_at, updated_at, completed_at, reminder_time, deadline_date
            FROM tasks
            WHERE status = 'pending'
            ORDER BY created_at, id
            """
        )
        let now = Date()
        for task in pending where !known.contains(task.categoryID) {
            var updated = task
            updated.categoryID = TaskCategory.inboxID
            updated.updatedAt = now
            try upsertTaskRow(updated)
            if let configuration = syncConfiguration {
                try enqueueLocalTask(updated, kind: .upsert, configuration: configuration)
            } else if hasPersistedSyncIdentity {
                try recordDeferredUpsert(
                    entityID: canonicalEntityID(updated.id.uuidString),
                    kind: .upsert
                )
            }
        }
    }

    private func upsertDisplayConfiguration(
        _ payload: WireDisplayConfigurationPayload,
        isLocalOverride: Bool
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO sync_display_configuration(
                entity_id, header_template, subtitle_template, start_date, deadline_date,
                is_local_override
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_id) DO UPDATE SET
                header_template = excluded.header_template,
                subtitle_template = excluded.subtitle_template,
                start_date = excluded.start_date,
                deadline_date = excluded.deadline_date,
                is_local_override = excluded.is_local_override
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(payload.id),
            .text(payload.headerTemplate),
            .text(payload.subtitleTemplate),
            .text(payload.startDate),
            .text(payload.deadlineDate),
            .integer(isLocalOverride ? 1 : 0),
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func displayConfigurationIsLocalOverride() throws -> Bool {
        let statement = try prepare(
            "SELECT is_local_override FROM sync_display_configuration WHERE entity_id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(Self.displayConfigurationEntityID)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) == 1
        case SQLITE_DONE:
            return false
        default:
            throw statementError()
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
        task.status == .completed && task.completedAt != nil
    }

    private func isValidReopen(_ task: TodoTask) -> Bool {
        task.status == .pending && task.completedAt == nil
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
        let status: TaskStatus
        switch payload.state {
        case .pending: status = .pending
        case .completed: status = .completed
        case .pass: status = .pass
        }
        let start = payload.periodStart.flatMap { date(fromKey: $0, timeZone: timeZone) }
        let deadline = payload.deadlineDate.flatMap { date(fromKey: $0, timeZone: timeZone) }
        var calendar = TodoTask.protocolCalendar
        calendar.timeZone = timeZone
        let defaultEnd: Date?
        switch payload.timeType {
        case .day:
            defaultEnd = start
        case .week:
            defaultEnd = start.flatMap { calendar.date(byAdding: .day, value: 6, to: $0) }
        case .month:
            defaultEnd = start.flatMap { value in
                calendar.dateInterval(of: .month, for: value).map { interval in
                    calendar.date(byAdding: .day, value: -1, to: interval.end) ?? value
                }
            }
        case .someday:
            defaultEnd = nil
        }
        let end: Date?
        switch (start, deadline) {
        case (nil, nil):
            end = nil
        case (nil, let deadline?):
            end = deadline
        case (let start?, nil):
            end = defaultEnd ?? start
        case (let start?, let deadline?):
            end = max(defaultEnd ?? start, deadline)
        }
        let effectiveStart = start ?? end
        let settledDate = payload.settledAt.map(date(fromMilliseconds:))
        return try TodoTask(
            id: id,
            seriesID: seriesID,
            title: payload.title,
            categoryID: payload.questLine,
            status: status,
            startDate: effectiveStart,
            endDate: end,
            sortIndex: sortIndex,
            createdAt: date(fromMilliseconds: payload.createdAt),
            updatedAt: date(fromMilliseconds: payload.updatedAt),
            reminderTime: effectiveStart == nil
                ? nil
                : payload.reminderTime.flatMap(TaskReminderTime.init(wireValue:)),
            completedAt: status == .pending ? nil : settledDate
        )
    }

    private func upsertTaskRow(_ task: TodoTask) throws {
        let recurrenceJSON = "{\"once\":{}}"
        let calendar = TodoTask.protocolCalendar
        let periodEnd = task.endDate.flatMap {
            calendar.date(byAdding: .day, value: 1, to: $0)
        }
        let statement = try prepare(
            """
            INSERT INTO tasks (
                id, series_id, title, time_scope, tier, status,
                recurrence_json, period_start, period_end, sort_index,
                created_at, updated_at, completed_at, reminder_time, deadline_date
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                completed_at = excluded.completed_at,
                reminder_time = excluded.reminder_time,
                deadline_date = excluded.deadline_date
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(task.id.uuidString),
            .text(task.seriesID.uuidString),
            .text(task.title),
            .text(task.startDate == nil ? "someday" : "day"),
            .text(task.categoryID),
            .text(task.status.rawValue),
            .text(recurrenceJSON),
            task.startDate.map { .double($0.timeIntervalSince1970) } ?? .null,
            periodEnd.map { .double($0.timeIntervalSince1970) } ?? .null,
            .integer(Int64(task.sortIndex)),
            .double(task.createdAt.timeIntervalSince1970),
            .double(task.updatedAt.timeIntervalSince1970),
            task.completedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            task.reminderTime.map { .text($0.wireValue) } ?? .null,
            task.endDate.map { .double($0.timeIntervalSince1970) } ?? .null,
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func deleteTaskRow(entityID: String) throws {
        let statement = try prepare("DELETE FROM tasks WHERE lower(id) = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(entityID.lowercased())], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func insertTrashRow(_ task: TodoTask, deletedAt: Date) throws {
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO trash_tasks (
                id, series_id, title, time_scope, tier, status, recurrence_json,
                period_start, period_end, sort_index, created_at, updated_at,
                completed_at, reminder_time, deadline_date, deleted_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        let calendar = TodoTask.protocolCalendar
        let periodEnd = task.endDate.flatMap {
            calendar.date(byAdding: .day, value: 1, to: $0)
        }
        try bind([
            .text(task.id.uuidString),
            .text(task.seriesID.uuidString),
            .text(task.title),
            .text(task.startDate == nil ? "someday" : "day"),
            .text(task.categoryID),
            .text(task.status.rawValue),
            .text("{\"once\":{}}"),
            task.startDate.map { .double($0.timeIntervalSince1970) } ?? .null,
            periodEnd.map { .double($0.timeIntervalSince1970) } ?? .null,
            .integer(Int64(task.sortIndex)),
            .double(task.createdAt.timeIntervalSince1970),
            .double(task.updatedAt.timeIntervalSince1970),
            task.completedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            task.reminderTime.map { .text($0.wireValue) } ?? .null,
            task.endDate.map { .double($0.timeIntervalSince1970) } ?? .null,
            .double(deletedAt.timeIntervalSince1970),
        ], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func decodeTrashedTask(from statement: OpaquePointer) throws -> TrashedTask {
        let task = try decodeTask(from: statement)
        guard sqlite3_column_type(statement, 15) != SQLITE_NULL else {
            throw SQLiteRepositoryError.invalidRecord("恢复快照缺少删除时间")
        }
        return TrashedTask(
            task: task,
            deletedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 15))
        )
    }

    private func storedTrashTask(id: UUID) throws -> TrashedTask? {
        let statement = try prepare(
            """
            SELECT id, series_id, title, time_scope, tier, status,
                   recurrence_json, period_start, period_end, sort_index,
                   created_at, updated_at, completed_at, reminder_time,
                   deadline_date, deleted_at
            FROM trash_tasks WHERE lower(id) = ? LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(canonicalEntityID(id.uuidString))], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            return try decodeTrashedTask(from: statement)
        default:
            throw statementError()
        }
    }

    private func deleteTrashRow(entityID: String) throws {
        let statement = try prepare("DELETE FROM trash_tasks WHERE lower(id) = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(entityID.lowercased())], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    /// 收到恢复后的新任务时，只清理内容相同的旧快照。
    /// 同一 seriesID 下可能保留着另一台设备编辑过的不同内容，不能仅凭 seriesID 删除。
    private func removeMatchingTrashRows(for task: TodoTask) throws {
        let statement = try prepare(
            """
            SELECT id, series_id, title, time_scope, tier, status,
                   recurrence_json, period_start, period_end, sort_index,
                   created_at, updated_at, completed_at, reminder_time,
                   deadline_date, deleted_at
            FROM trash_tasks WHERE lower(series_id) = ?
            """
        )
        try bind([
            .text(canonicalEntityID(task.seriesID.uuidString)),
        ], to: statement)
        var matched: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let trashed = try decodeTrashedTask(from: statement)
            if restoredContentMatches(trashed.task, task) {
                matched.append(canonicalEntityID(trashed.task.id.uuidString))
            }
            result = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        guard result == SQLITE_DONE else { throw statementError() }
        for entityID in matched {
            try deleteTrashRow(entityID: entityID)
        }
    }

    /// 同一 seriesID 且内容相同，才视为“这条任务已经被恢复”。
    private func liveTaskMatches(
        seriesID: UUID,
        content task: TodoTask,
        excludingID: UUID
    ) throws -> Bool {
        let candidates = try query(
            """
            SELECT id, series_id, title, time_scope, tier, status,
                   recurrence_json, period_start, period_end, sort_index,
                   created_at, updated_at, completed_at, reminder_time,
                   deadline_date
            FROM tasks
            WHERE lower(series_id) = ? AND lower(id) != ?
            """,
            bindings: [
                .text(canonicalEntityID(seriesID.uuidString)),
                .text(canonicalEntityID(excludingID.uuidString)),
            ]
        )
        return candidates.contains { restoredContentMatches($0, task) }
    }

    private func restoredContentMatches(_ lhs: TodoTask, _ rhs: TodoTask) -> Bool {
        lhs.title == rhs.title &&
            lhs.categoryID == rhs.categoryID &&
            lhs.status == rhs.status &&
            lhs.startDate == rhs.startDate &&
            lhs.endDate == rhs.endDate &&
            lhs.sortIndex == rhs.sortIndex &&
            lhs.reminderTime == rhs.reminderTime &&
            abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 1
    }

    private func storedTask(id: UUID) throws -> TodoTask? {
        try query(
            """
            SELECT id, series_id, title, time_scope, tier, status,
                   recurrence_json, period_start, period_end, sort_index,
                   created_at, updated_at, completed_at, reminder_time, deadline_date
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

    private func isWebDavOperationApplied(_ operationID: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sync_webdav_applied_operations WHERE op_id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(operationID)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw statementError()
        }
    }

    private func recordWebDavOperation(_ operationID: String) throws {
        let statement = try prepare(
            "INSERT INTO sync_webdav_applied_operations(op_id, applied_at) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(operationID),
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
            let status = TaskStatus(rawValue: text(at: 5, from: statement))
        else {
            throw SQLiteRepositoryError.invalidRecord("任务标识或状态无法解析")
        }
        let categoryID = text(at: 4, from: statement)
        guard TaskCategory.isValidID(categoryID) else {
            throw SQLiteRepositoryError.invalidRecord("任务分类标识无法解析")
        }
        let scope = text(at: 3, from: statement)
        let start = optionalDate(at: 7, from: statement)
        let periodEnd = optionalDate(at: 8, from: statement)
        let deadline = optionalDate(at: 14, from: statement)
        let calendar = TodoTask.protocolCalendar
        let defaultEnd: Date?
        if let periodEnd {
            defaultEnd = calendar.date(byAdding: .day, value: -1, to: periodEnd)
        } else {
            switch scope {
            case "day":
                defaultEnd = start
            case "week":
                defaultEnd = start.flatMap { calendar.date(byAdding: .day, value: 6, to: $0) }
            case "month":
                defaultEnd = start.flatMap { value in
                    calendar.dateInterval(of: .month, for: value).map { interval in
                        calendar.date(byAdding: .day, value: -1, to: interval.end) ?? value
                    }
                }
            default:
                defaultEnd = nil
            }
        }
        let end: Date?
        switch (start, deadline) {
        case (nil, nil):
            end = nil
        case (nil, let deadline?):
            end = deadline
        case (let start?, nil):
            end = defaultEnd ?? start
        case (let start?, let deadline?):
            end = max(defaultEnd ?? start, deadline)
        }
        let effectiveStart = start ?? end
        return try TodoTask(
            id: id,
            seriesID: seriesID,
            title: text(at: 2, from: statement),
            categoryID: categoryID,
            status: status,
            startDate: effectiveStart,
            endDate: end,
            sortIndex: Int(sqlite3_column_int64(statement, 9)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
            reminderTime: effectiveStart == nil ? nil : try reminderTime(at: 13, from: statement),
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

    private func reminderTime(
        at index: Int32,
        from statement: OpaquePointer
    ) throws -> TaskReminderTime? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let value = TaskReminderTime(wireValue: text(at: index, from: statement)) else {
            throw SQLiteRepositoryError.invalidRecord("任务提醒时间无法解析")
        }
        return value
    }

    private func taskTableHasColumn(_ columnName: String) throws -> Bool {
        try tableHasColumn("tasks", columnName: columnName)
    }

    private func tableHasColumn(_ tableName: String, columnName: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(tableName))")
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if text(at: 1, from: statement) == columnName { return true }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw statementError() }
        return false
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
