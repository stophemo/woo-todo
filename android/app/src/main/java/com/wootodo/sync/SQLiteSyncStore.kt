package com.wootodo.sync

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.wootodo.data.SQLiteTrashTable
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskEntity
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskRecurrence
import com.wootodo.domain.TaskStatus
import java.nio.charset.StandardCharsets
import java.time.LocalDate
import java.time.LocalTime
import java.time.YearMonth
import java.util.UUID

data class EntityVersion(val lamport: Long, val deviceId: String) : Comparable<EntityVersion> {
    init {
        require(lamport >= 1)
    }

    override fun compareTo(other: EntityVersion): Int =
        compareValuesBy(this, other, EntityVersion::lamport, EntityVersion::deviceId)
}

data class TaskMergeDecision(
    val resolvedTask: TaskInstancePayload?,
    val resolvedVersion: EntityVersion,
)

data class DisplayConfigurationMergeDecision(
    val resolvedConfiguration: DisplayConfigurationPayload?,
    val resolvedVersion: EntityVersion,
)


/** tombstone 之外先合并终态语义，其余字段使用 (lamport, deviceId) 的确定性 LWW。 */
object TaskMergePolicy {
    fun resolve(
        currentTask: TaskInstancePayload?,
        currentVersion: EntityVersion?,
        incomingTask: TaskInstancePayload,
        incomingVersion: EntityVersion,
        incomingKind: SyncOperationKind = SyncOperationKind.UPSERT,
    ): TaskMergeDecision {
        if (incomingKind == SyncOperationKind.REOPEN) {
            require(isValidReopen(incomingTask))
        }
        if (currentVersion == null) {
            return TaskMergeDecision(incomingTask, incomingVersion)
        }
        if (currentTask == null) {
            return if (incomingVersion > currentVersion) {
                TaskMergeDecision(incomingTask, incomingVersion)
            } else {
                TaskMergeDecision(null, currentVersion)
            }
        }
        val horizon = maxOf(currentVersion, incomingVersion)
        val incomingWinsLww = incomingVersion > currentVersion
        if (incomingKind == SyncOperationKind.REOPEN) {
            return if (incomingWinsLww) {
                TaskMergeDecision(incomingTask, incomingVersion)
            } else {
                TaskMergeDecision(currentTask, currentVersion)
            }
        }
        mergeCompletedOverPass(currentTask, incomingTask, incomingWinsLww)?.let {
            return TaskMergeDecision(it, horizon)
        }
        mergeSettledOverPending(currentTask, incomingTask)?.let {
            return TaskMergeDecision(it, horizon)
        }
        return if (incomingWinsLww) {
            TaskMergeDecision(incomingTask, incomingVersion)
        } else {
            TaskMergeDecision(currentTask, currentVersion)
        }
    }

    private fun mergeCompletedOverPass(
        current: TaskInstancePayload,
        incoming: TaskInstancePayload,
        incomingWinsLww: Boolean,
    ): TaskInstancePayload? {
        val completed = when {
            current.state == WireTaskState.COMPLETED && incoming.state == WireTaskState.PASS -> current
            current.state == WireTaskState.PASS && incoming.state == WireTaskState.COMPLETED -> incoming
            else -> return null
        }
        if (!isValidCompletion(completed)) return null
        val base = if (incomingWinsLww) incoming else current
        return base.copy(
            state = WireTaskState.COMPLETED,
            settledAt = completed.settledAt,
            updatedAt = maxOf(base.updatedAt, completed.updatedAt),
        )
    }

    private fun mergeSettledOverPending(
        current: TaskInstancePayload,
        incoming: TaskInstancePayload,
    ): TaskInstancePayload? = when {
        current.state != WireTaskState.PENDING && incoming.state == WireTaskState.PENDING -> current
        current.state == WireTaskState.PENDING && incoming.state != WireTaskState.PENDING -> incoming
        else -> null
    }

    fun isValidCompletion(task: TaskInstancePayload): Boolean =
        task.state == WireTaskState.COMPLETED && task.settledAt != null

    fun isValidReopen(task: TaskInstancePayload): Boolean =
        task.state == WireTaskState.PENDING && task.settledAt == null
}

/** 仓储层独立校验拉取页，避免绕过 Coordinator 时推进错误 cursor。 */
object RemotePagePolicy {
    fun validate(
        operations: List<SyncPulledOperation>,
        currentCursor: Long,
        targetCursor: Long,
    ) {
        require(targetCursor >= currentCursor) { "远端 cursor 不得回退" }
        if (operations.isEmpty()) {
            require(targetCursor == currentCursor) { "空页不能推进 cursor" }
            return
        }
        var previous = currentCursor
        operations.forEach { operation ->
            require(operation.serverSeq > previous && operation.serverSeq <= targetCursor) {
                "远端操作序号必须严格递增并且不超过页尾 cursor"
            }
            require(
                operation.lamport >= 1 && operation.opId.isNotBlank() &&
                    operation.entityId.isNotBlank() && operation.deviceId.isNotBlank(),
            ) { "远端操作版本或标识符无效" }
            previous = operation.serverSeq
        }
        require(previous == targetCursor) { "页尾序号与 cursor 不一致" }
    }
}

object SQLiteLocalMutationRecorder {
    private const val CATEGORY_SYNC_DATE = "2000-01-01"

    fun recordTask(
        database: SQLiteDatabase,
        task: TaskEntity,
        kind: SyncOperationKind,
    ) {
        require(
            kind in setOf(
                SyncOperationKind.UPSERT,
                SyncOperationKind.COMPLETE,
                SyncOperationKind.PASS,
                SyncOperationKind.REOPEN,
                SyncOperationKind.REORDER,
            ),
        )
        val normalizedTask = task.copy(id = canonicalEntityId(task.id))
        require(normalizedTask.id != DISPLAY_CONFIGURATION_ENTITY_ID) {
            "任务不能使用固定显示配置实体 ID"
        }
        check(!isDeletionBarrier(database, normalizedTask.id)) {
            "已删除任务不能以相同 ID 复活"
        }
        val version = nextLocalVersion(database) ?: return
        val payload = normalizedTask.toWirePayload()
        requireKindMatchesTask(kind, payload)
        enqueue(
            database = database,
            entityId = normalizedTask.id,
            kind = kind,
            version = version,
            payloadJson = SyncJsonCodec.encodeTaskPayload(payload),
            createdAt = normalizedTask.updatedAt,
        )
        writeVersion(database, normalizedTask.id, version, isTombstone = false)
    }

    /**
     * 分类定义借用显示配置实体同步；标题、副标题和计时日期用固定占位，
     * 接收端只应用 questLines，不会覆盖本机显示设置。
     */
    fun recordCategoryConfiguration(
        database: SQLiteDatabase,
        categories: List<TaskCategory>,
        createdAt: Long,
    ) {
        if (categories.isEmpty()) return
        val payload = DisplayConfigurationPayload(
            headerTemplate = "",
            subtitleTemplate = "",
            startDate = CATEGORY_SYNC_DATE,
            deadlineDate = CATEGORY_SYNC_DATE,
            questLines = categories
                .sortedBy { it.order }
                .map { QuestLineDefinition(it.id, it.name, it.order) },
        )
        recordDisplayConfiguration(database, payload, createdAt)
    }

    private fun recordDisplayConfiguration(
        database: SQLiteDatabase,
        payload: DisplayConfigurationPayload,
        createdAt: Long,
    ) {
        val version = nextLocalVersion(database) ?: return
        enqueue(
            database = database,
            entityId = payload.id,
            kind = SyncOperationKind.UPSERT,
            version = version,
            payloadJson = SyncJsonCodec.encodeTaskPayload(payload),
            createdAt = createdAt,
        )
        writeVersion(database, payload.id, version, isTombstone = false)
    }

    fun recordDeletion(database: SQLiteDatabase, entityId: String, deletedAt: Long) {
        val normalizedId = canonicalEntityId(entityId)
        require(normalizedId != DISPLAY_CONFIGURATION_ENTITY_ID) {
            "固定显示配置实体不能删除"
        }
        val version = nextLocalVersion(database)
        if (version == null) {
            recordDeferredDeletion(database, normalizedId, deletedAt)
            return
        }
        val payload = TombstonePayload(id = normalizedId, deletedAt = deletedAt)
        enqueue(
            database = database,
            entityId = normalizedId,
            kind = SyncOperationKind.DELETE,
            version = version,
            payloadJson = SyncJsonCodec.encodeTaskPayload(payload),
            createdAt = deletedAt,
        )
        writeVersion(database, normalizedId, version, isTombstone = true)
        writeTombstone(database, payload, version)
        database.delete(
            TABLE_DEFERRED_DELETIONS,
            "entity_id = ? COLLATE NOCASE",
            arrayOf(normalizedId),
        )
    }

    fun recordDeferredDeletion(database: SQLiteDatabase, entityId: String, deletedAt: Long) {
        require(entityId.isNotBlank() && deletedAt >= 0)
        val normalizedId = canonicalEntityId(entityId)
        require(normalizedId != DISPLAY_CONFIGURATION_ENTITY_ID) {
            "固定显示配置实体不能删除"
        }
        val values = ContentValues(2).apply {
            put("entity_id", normalizedId)
            put("deleted_at", deletedAt)
        }
        database.delete(
            TABLE_DEFERRED_DELETIONS,
            "entity_id = ? COLLATE NOCASE",
            arrayOf(normalizedId),
        )
        database.insertWithOnConflict(
            TABLE_DEFERRED_DELETIONS,
            null,
            values,
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    private fun nextLocalVersion(database: SQLiteDatabase): EntityVersion? {
        val identity = database.rawQuery(
            "SELECT vault_id, device_id FROM sync_state WHERE id = 1",
            null,
        ).use { cursor ->
            check(cursor.moveToFirst()) { "同步状态未初始化" }
            cursor.getString(0) to cursor.getString(1)
        }
        if (identity.first.isEmpty() && identity.second.isEmpty()) return null
        check(identity.first.isNotEmpty() && identity.second.isNotEmpty()) { "同步身份不完整" }
        database.execSQL("UPDATE sync_state SET lamport = lamport + 1 WHERE id = 1")
        return database.rawQuery(
            "SELECT lamport, device_id FROM sync_state WHERE id = 1",
            null,
        ).use { cursor ->
            check(cursor.moveToFirst()) { "同步状态未初始化" }
            EntityVersion(cursor.getLong(0), cursor.getString(1))
        }
    }

    /** 删除屏障是实体 ID 的永久终态，包含正式和尚未绑定时的 deferred 记录。 */
    internal fun isDeletionBarrier(database: SQLiteDatabase, entityId: String): Boolean {
        val normalizedId = canonicalEntityId(entityId)
        return database.rawQuery(
            """
            SELECT 1 FROM $TABLE_VERSIONS
            WHERE entity_id = ? COLLATE NOCASE AND is_tombstone = 1
            UNION ALL
            SELECT 1 FROM $TABLE_TOMBSTONES
            WHERE entity_id = ? COLLATE NOCASE
            UNION ALL
            SELECT 1 FROM $TABLE_DEFERRED_DELETIONS
            WHERE entity_id = ? COLLATE NOCASE
            LIMIT 1
            """.trimIndent(),
            arrayOf(normalizedId, normalizedId, normalizedId),
        ).use(Cursor::moveToFirst)
    }

    private fun enqueue(
        database: SQLiteDatabase,
        entityId: String,
        kind: SyncOperationKind,
        version: EntityVersion,
        payloadJson: String,
        createdAt: Long,
    ) {
        val values = ContentValues(7).apply {
            put("op_id", UUID.randomUUID().toString())
            put("entity_id", entityId)
            put("kind", kind.wireValue)
            put("lamport", version.lamport)
            put("payload_json", payloadJson)
            put("created_at", createdAt)
        }
        database.insertOrThrow(TABLE_OUTBOX, null, values)
    }
}

/** 本地数据库已绑定到其他同步空间或设备，必须先解绑才能切换。 */
class SyncBindingConflictException(message: String) : IllegalArgumentException(message)

class SQLiteSyncStore(
    private val database: TaskDatabase,
    private val credentials: SyncCredentials,
    private val bindOnInit: Boolean = true,
    private val onDisplayConfigurationChanged: (DisplayConfigurationPayload) -> Unit = {},
    private val onTasksChanged: () -> Unit = {},
) : OutboxStore, RemoteApplyStore {
    init {
        credentials.validate()
        if (bindOnInit) bindDeviceIdentity()
    }

    companion object {
        /** sync_applied_operations 保留的最近记录数。 */
        const val APPLIED_RETENTION_WINDOW = 10_000L

        /** 清理旧同步空间的元数据，但保留任务与显示配置。 */
        fun resetSyncBinding(database: TaskDatabase) {
            val sqlite = database.writableDatabase
            sqlite.beginTransaction()
            try {
                resetSyncMetadata(sqlite)
                sqlite.setTransactionSuccessful()
            } finally {
                sqlite.endTransaction()
            }
        }

        /** 原子清理旧空间、绑定新空间，并把保留的本地数据重新写入 outbox。 */
        fun replaceSyncBinding(
            database: TaskDatabase,
            credentials: SyncCredentials,
            onDisplayConfigurationChanged: (DisplayConfigurationPayload) -> Unit = {},
            onTasksChanged: () -> Unit = {},
        ): SQLiteSyncStore {
            val store = SQLiteSyncStore(
                database = database,
                credentials = credentials,
                onDisplayConfigurationChanged = onDisplayConfigurationChanged,
                onTasksChanged = onTasksChanged,
                bindOnInit = false,
            )
            val sqlite = database.writableDatabase
            sqlite.beginTransaction()
            try {
                resetSyncMetadata(sqlite)
                store.bindDeviceIdentity(sqlite)
                sqlite.setTransactionSuccessful()
            } finally {
                sqlite.endTransaction()
            }
            return store
        }

        private fun resetSyncMetadata(sqlite: SQLiteDatabase) {
            sqlite.delete(TABLE_OUTBOX, null, null)
            sqlite.delete(TABLE_VERSIONS, null, null)
            sqlite.delete(TABLE_TOMBSTONES, null, null)
            sqlite.delete(TABLE_APPLIED, null, null)
            sqlite.delete(TABLE_DEFERRED_DELETIONS, null, null)
            sqlite.execSQL(
                "UPDATE sync_state SET cursor = 0, lamport = 0, vault_id = '', device_id = '' " +
                    "WHERE id = 1",
            )
            sqlite.execSQL(
                "UPDATE $TABLE_DISPLAY_CONFIGURATION SET is_local_override = 1",
            )
        }
    }

    @Synchronized
    override fun pendingOperations(limit: Int): List<SyncPushOperation> {
        require(limit in 1..SyncProtocolLimits.MAX_PUSH_OPERATIONS)
        val sqlite = database.writableDatabase
        val operations = mutableListOf<SyncPushOperation>()
        sqlite.beginTransaction()
        try {
            val rows = sqlite.query(
                TABLE_OUTBOX,
                arrayOf(
                    "op_id", "entity_id", "kind", "lamport", "payload_json",
                    "ciphertext", "nonce", "encrypted_vault_id", "encrypted_device_id",
                ),
                null,
                null,
                null,
                null,
                "sequence ASC",
                limit.toString(),
            ).use { cursor ->
                buildList {
                    while (cursor.moveToNext()) add(cursor.toPendingRow())
                }
            }
            rows.forEach { row ->
                operations += materializeOperation(sqlite, row)
            }
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        return operations
    }

    @Synchronized
    override fun acknowledgeOperations(opIds: List<String>) {
        if (opIds.isEmpty()) return
        require(opIds.size <= SyncProtocolLimits.MAX_PUSH_OPERATIONS)
        val placeholders = opIds.joinToString(",") { "?" }
        database.writableDatabase.delete(
            TABLE_OUTBOX,
            "op_id IN ($placeholders)",
            opIds.toTypedArray(),
        )
    }

    override fun currentCursor(): Long = database.readableDatabase.rawQuery(
        "SELECT cursor FROM sync_state WHERE id = 1",
        null,
    ).use { cursor ->
        check(cursor.moveToFirst()) { "同步状态未初始化" }
        cursor.getLong(0)
    }

    /** 服务端状态重建导致本地游标超前时归零，保留已应用记录与本地任务。 */
    @Synchronized
    override fun resetCursor() {
        val sqlite = database.writableDatabase
        sqlite.beginTransaction()
        try {
            sqlite.execSQL("UPDATE sync_state SET cursor = 0 WHERE id = 1")
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
    }

    @Synchronized
    override fun applyRemoteOperations(
        operations: List<SyncPulledOperation>,
        advancingCursorTo: Long,
    ) {
        val sqlite = database.writableDatabase
        var tasksChanged = false
        var displayConfiguration: DisplayConfigurationPayload? = null
        sqlite.beginTransaction()
        try {
            val currentCursor = currentCursor(sqlite)
            RemotePagePolicy.validate(operations, currentCursor, advancingCursorTo)
            operations.forEach { operation ->
                if (!isAlreadyApplied(sqlite, operation.opId)) {
                    val plaintext = SyncPayloadCrypto.open(
                        envelope = EncryptedEnvelope(operation.ciphertext, operation.nonce),
                        vaultKey = credentials.vaultKey,
                        vaultId = credentials.vaultId,
                        metadata = operation.metadata(),
                    )
                    val payload = SyncJsonCodec.decodeTaskPayload(
                        String(plaintext, StandardCharsets.UTF_8),
                    )
                    require(payload.id == operation.entityId) { "密文实体与外层 entityId 不一致" }
                    val result = applyPayload(sqlite, operation, payload)
                    tasksChanged = result.tasksChanged || tasksChanged
                    displayConfiguration = result.displayConfiguration ?: displayConfiguration
                    rememberApplied(sqlite, operation)
                }
                sqlite.execSQL(
                    "UPDATE sync_state SET lamport = MAX(lamport, ?) WHERE id = 1",
                    arrayOf(operation.lamport),
                )
            }
            sqlite.execSQL(
                "UPDATE sync_state SET cursor = ? WHERE id = 1",
                arrayOf(advancingCursorTo),
            )
            // 幂等由 LWW 版本决定，旧序号记录不再需要，随游标前进裁剪窗口外的记录。
            sqlite.execSQL(
                "DELETE FROM $TABLE_APPLIED WHERE server_seq < ?",
                arrayOf(advancingCursorTo - APPLIED_RETENTION_WINDOW),
            )
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        if (tasksChanged) onTasksChanged()
        displayConfiguration?.let(onDisplayConfigurationChanged)
    }

    private fun bindDeviceIdentity() {
        val sqlite = database.writableDatabase
        sqlite.beginTransaction()
        try {
            bindDeviceIdentity(sqlite)
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
    }

    private fun bindDeviceIdentity(sqlite: SQLiteDatabase) {
        val current = sqlite.rawQuery(
            "SELECT vault_id, device_id FROM sync_state WHERE id = 1",
            null,
        ).use { cursor ->
            check(cursor.moveToFirst()) { "同步状态未初始化" }
            cursor.getString(0) to cursor.getString(1)
        }
        val isUnbound = current.first.isEmpty() && current.second.isEmpty()
        if (!isUnbound &&
            (current.first != credentials.vaultId || current.second != credentials.deviceId)
        ) {
            throw SyncBindingConflictException("本地数据库已绑定到其他同步空间或设备")
        }
        if (!isUnbound) return

        val values = ContentValues(2).apply {
            put("vault_id", credentials.vaultId)
            put("device_id", credentials.deviceId)
        }
        check(sqlite.update("sync_state", values, "id = 1", null) == 1)
        val existingTasks = sqlite.query(
            "tasks",
            null,
            null,
            null,
            null,
            null,
            "created_at ASC, id ASC",
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(cursor.toTaskEntity())
            }
        }
        val deferredDeletions = sqlite.query(
            TABLE_DEFERRED_DELETIONS,
            arrayOf("entity_id", "deleted_at"),
            null,
            null,
            null,
            null,
            "deleted_at ASC, entity_id ASC",
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(cursor.getString(0) to cursor.getLong(1))
                }
            }
        }
        existingTasks.forEach { task ->
            SQLiteLocalMutationRecorder.recordTask(
                sqlite,
                task,
                SyncOperationKind.UPSERT,
            )
        }
        deferredDeletions.forEach { (entityId, deletedAt) ->
            SQLiteLocalMutationRecorder.recordDeletion(sqlite, entityId, deletedAt)
        }
        // 显示配置不再作为同步基线；分类与默认值不同时作为独立基线入队。
        val categories = readCategories(sqlite)
        if (categories.isNotEmpty() && categories != TaskCategories.defaults) {
            SQLiteLocalMutationRecorder.recordCategoryConfiguration(
                sqlite,
                categories,
                System.currentTimeMillis(),
            )
        }
    }

    private fun materializeOperation(
        sqlite: SQLiteDatabase,
        row: PendingRow,
    ): SyncPushOperation {
        if (row.ciphertext != null && row.nonce != null) {
            require(row.encryptedVaultId == credentials.vaultId)
            require(row.encryptedDeviceId == credentials.deviceId)
            return row.toPushOperation(row.ciphertext, row.nonce)
        }
        val metadata = SyncOperationMetadata(
            opId = row.opId,
            entityId = row.entityId,
            kind = row.kind,
            lamport = row.lamport,
            deviceId = credentials.deviceId,
        )
        val envelope = SyncPayloadCrypto.seal(
            plaintext = row.payloadJson.toByteArray(StandardCharsets.UTF_8),
            vaultKey = credentials.vaultKey,
            vaultId = credentials.vaultId,
            metadata = metadata,
        )
        val values = ContentValues(4).apply {
            put("ciphertext", envelope.ciphertext)
            put("nonce", envelope.nonce)
            put("encrypted_vault_id", credentials.vaultId)
            put("encrypted_device_id", credentials.deviceId)
        }
        check(sqlite.update(TABLE_OUTBOX, values, "op_id = ?", arrayOf(row.opId)) == 1)
        return row.toPushOperation(envelope.ciphertext, envelope.nonce)
    }

    private data class ApplyResult(
        val tasksChanged: Boolean = false,
        val displayConfiguration: DisplayConfigurationPayload? = null,
    )

    private fun applyPayload(
        sqlite: SQLiteDatabase,
        operation: SyncPulledOperation,
        payload: TaskWirePayload,
    ): ApplyResult = when (payload) {
        is TaskInstancePayload -> ApplyResult(tasksChanged = applyTask(sqlite, operation, payload))
        is TombstonePayload -> ApplyResult(tasksChanged = applyTombstone(sqlite, operation, payload))
        is DisplayConfigurationPayload -> ApplyResult(
            displayConfiguration = applyDisplayConfiguration(sqlite, operation, payload),
        )
    }

    private fun applyDisplayConfiguration(
        sqlite: SQLiteDatabase,
        operation: SyncPulledOperation,
        payload: DisplayConfigurationPayload,
    ): DisplayConfigurationPayload? {
        require(operation.kind == SyncOperationKind.UPSERT) {
            "显示配置只能用于 upsert 操作"
        }
        val incomingVersion = EntityVersion(operation.lamport, operation.deviceId)
        val currentVersion = readVersion(sqlite, payload.id)
        require(currentVersion?.isTombstone != true) { "显示配置不能处于删除状态" }
        if (currentVersion == null || incomingVersion > currentVersion.version) {
            writeVersion(sqlite, payload.id, incomingVersion, isTombstone = false)
            if (payload.questLines.isNotEmpty()) {
                replaceCategories(sqlite, payload.questLines)
                reconcileUnknownPendingCategories(sqlite)
                return payload
            }
        }
        // 标题、副标题与计时日期仍只留本机；这里最多只应用分类列表。
        return null
    }

    private fun replaceCategories(
        sqlite: SQLiteDatabase,
        definitions: List<QuestLineDefinition>,
    ) {
        val categories = TaskCategories.normalizeList(
            definitions.map { TaskCategory(it.id, it.name, it.order) },
        )
        sqlite.delete(TABLE_CATEGORIES, null, null)
        val now = System.currentTimeMillis()
        categories.forEach { category ->
            sqlite.insertOrThrow(
                TABLE_CATEGORIES,
                null,
                ContentValues(4).apply {
                    put("id", category.id)
                    put("name", category.name)
                    put("sort_order", category.order)
                    put("updated_at", now)
                },
            )
        }
    }

    private fun reconcileUnknownPendingCategories(sqlite: SQLiteDatabase) {
        val known = sqlite.query(
            TABLE_CATEGORIES,
            arrayOf("id"),
            null,
            null,
            null,
            null,
            null,
        ).use { cursor ->
            buildSet {
                while (cursor.moveToNext()) add(cursor.getString(0))
            }
        }
        val pending = sqlite.query(
            TABLE_TASKS,
            null,
            "status = ?",
            arrayOf(TaskStatus.PENDING.rawValue),
            null,
            null,
            "created_at ASC, id ASC",
        ).use { it.toTaskList() }
        val now = System.currentTimeMillis()
        pending.filter { it.categoryId !in known }.forEach { task ->
            val updated = task.copy(categoryId = TaskCategories.INBOX_ID, updatedAt = now)
            sqlite.update(
                TABLE_TASKS,
                ContentValues(2).apply {
                    put("quest_line", TaskCategories.INBOX_ID)
                    put("updated_at", now)
                },
                "id = ?",
                arrayOf(task.id),
            )
            SQLiteLocalMutationRecorder.recordTask(
                sqlite,
                updated,
                SyncOperationKind.UPSERT,
            )
        }
    }

    private fun applyTask(
        sqlite: SQLiteDatabase,
        operation: SyncPulledOperation,
        payload: TaskInstancePayload,
    ): Boolean {
        val normalizedPayload = payload.withCanonicalEntityId()
        require(normalizedPayload.id != DISPLAY_CONFIGURATION_ENTITY_ID) {
            "任务不能使用固定显示配置实体 ID"
        }
        requireKindMatchesTask(operation.kind, normalizedPayload)
        val incomingVersion = EntityVersion(operation.lamport, operation.deviceId)
        val currentVersion = readVersion(sqlite, normalizedPayload.id)
        // tombstone 是实体 ID 的终态；更高 Lamport 也只能使用新 ID 创建任务。
        if (currentVersion?.isTombstone == true) {
            val horizon = maxOf(currentVersion.version, incomingVersion)
            if (horizon != currentVersion.version) {
                writeVersion(sqlite, normalizedPayload.id, horizon, isTombstone = true)
                advanceTombstoneVersion(sqlite, normalizedPayload.id, horizon)
            }
            return false
        }
        val currentTask = readTask(sqlite, normalizedPayload.id)?.toWirePayload()
        val decision = TaskMergePolicy.resolve(
            currentTask,
            currentVersion?.version,
            normalizedPayload,
            incomingVersion,
            operation.kind,
        )
        val resolvedTask = decision.resolvedTask?.withCanonicalEntityId()
        val changed = resolvedTask != null && resolvedTask != currentTask
        if (changed) {
            val values = resolvedTask.toTaskEntity().toContentValues()
            sqlite.delete(
                "tasks",
                "id = ? COLLATE NOCASE",
                arrayOf(normalizedPayload.id),
            )
            sqlite.insertWithOnConflict("tasks", null, values, SQLiteDatabase.CONFLICT_REPLACE)
            // 只清理内容相同的旧恢复快照；同 seriesId 下可能有其他设备编辑过的不同内容。
            removeMatchingTrashRows(sqlite, resolvedTask)
        }
        if (currentVersion == null || decision.resolvedVersion != currentVersion.version) {
            writeVersion(
                sqlite,
                normalizedPayload.id,
                decision.resolvedVersion,
                isTombstone = false,
            )
        }
        return changed
    }

    private fun applyTombstone(
        sqlite: SQLiteDatabase,
        operation: SyncPulledOperation,
        payload: TombstonePayload,
    ): Boolean {
        require(operation.kind == SyncOperationKind.DELETE) {
            "tombstone 只能用于 delete 操作"
        }
        val normalizedPayload = payload.withCanonicalEntityId()
        require(normalizedPayload.id != DISPLAY_CONFIGURATION_ENTITY_ID) {
            "固定显示配置实体不能删除"
        }
        val incomingVersion = EntityVersion(operation.lamport, operation.deviceId)
        val currentVersion = readVersion(sqlite, normalizedPayload.id)
        if (currentVersion?.isTombstone == true && incomingVersion <= currentVersion.version) {
            return false
        }
        val horizon = currentVersion?.version?.let { maxOf(it, incomingVersion) } ?: incomingVersion
        // 删除前保留本机恢复快照；同一 seriesId 已有恢复后的新任务时不再重复快照。
        val currentTask = readTask(sqlite, normalizedPayload.id)
        if (currentTask != null &&
            currentTask.status == TaskStatus.PENDING &&
            !liveTaskMatches(sqlite, currentTask)
        ) {
            SQLiteTrashTable.insertFromTask(
                sqlite,
                normalizedPayload.id,
                payload.deletedAt,
            )
        }
        val taskDeleted = sqlite.delete(
            "tasks",
            "id = ? COLLATE NOCASE",
            arrayOf(normalizedPayload.id),
        ) > 0
        sqlite.delete(
            TABLE_DEFERRED_DELETIONS,
            "entity_id = ? COLLATE NOCASE",
            arrayOf(normalizedPayload.id),
        )
        writeTombstone(sqlite, normalizedPayload, horizon)
        writeVersion(sqlite, normalizedPayload.id, horizon, isTombstone = true)
        return taskDeleted
    }

    private fun rememberApplied(sqlite: SQLiteDatabase, operation: SyncPulledOperation) {
        val values = ContentValues(2).apply {
            put("op_id", operation.opId)
            put("server_seq", operation.serverSeq)
        }
        sqlite.insertOrThrow(TABLE_APPLIED, null, values)
    }

    private fun isAlreadyApplied(sqlite: SQLiteDatabase, opId: String): Boolean =
        sqlite.rawQuery(
            "SELECT 1 FROM $TABLE_APPLIED WHERE op_id = ? LIMIT 1",
            arrayOf(opId),
        ).use(Cursor::moveToFirst)

    private data class PendingRow(
        val opId: String,
        val entityId: String,
        val kind: SyncOperationKind,
        val lamport: Long,
        val payloadJson: String,
        val ciphertext: String?,
        val nonce: String?,
        val encryptedVaultId: String?,
        val encryptedDeviceId: String?,
    ) {
        fun toPushOperation(ciphertext: String, nonce: String): SyncPushOperation =
            SyncPushOperation(opId, entityId, kind, lamport, ciphertext, nonce)
    }

    private fun Cursor.toPendingRow(): PendingRow = PendingRow(
        opId = getString(0),
        entityId = getString(1),
        kind = SyncOperationKind.fromWire(getString(2)),
        lamport = getLong(3),
        payloadJson = getString(4),
        ciphertext = nullableString(5),
        nonce = nullableString(6),
        encryptedVaultId = nullableString(7),
        encryptedDeviceId = nullableString(8),
    )

    private fun Cursor.nullableString(index: Int): String? =
        if (isNull(index)) null else getString(index)
}

private data class StoredVersion(
    val version: EntityVersion,
    val isTombstone: Boolean,
)

private fun readVersion(database: SQLiteDatabase, entityId: String): StoredVersion? =
    database.rawQuery(
        "SELECT lamport, device_id, is_tombstone FROM $TABLE_VERSIONS " +
            "WHERE entity_id = ? COLLATE NOCASE",
        arrayOf(canonicalEntityId(entityId)),
    ).use { cursor ->
        if (!cursor.moveToFirst()) null else StoredVersion(
            EntityVersion(cursor.getLong(0), cursor.getString(1)),
            cursor.getInt(2) != 0,
        )
    }

private fun writeVersion(
    database: SQLiteDatabase,
    entityId: String,
    version: EntityVersion,
    isTombstone: Boolean,
) {
    val normalizedId = canonicalEntityId(entityId)
    val values = ContentValues(4).apply {
        put("entity_id", normalizedId)
        put("lamport", version.lamport)
        put("device_id", version.deviceId)
        put("is_tombstone", if (isTombstone) 1 else 0)
    }
    database.delete(
        TABLE_VERSIONS,
        "entity_id = ? COLLATE NOCASE",
        arrayOf(normalizedId),
    )
    database.insertWithOnConflict(TABLE_VERSIONS, null, values, SQLiteDatabase.CONFLICT_REPLACE)
}

private fun writeTombstone(
    database: SQLiteDatabase,
    payload: TombstonePayload,
    version: EntityVersion,
) {
    val normalizedPayload = payload.withCanonicalEntityId()
    val values = ContentValues(4).apply {
        put("entity_id", normalizedPayload.id)
        put("deleted_at", normalizedPayload.deletedAt)
        put("lamport", version.lamport)
        put("device_id", version.deviceId)
    }
    database.delete(
        TABLE_TOMBSTONES,
        "entity_id = ? COLLATE NOCASE",
        arrayOf(normalizedPayload.id),
    )
    database.insertWithOnConflict(TABLE_TOMBSTONES, null, values, SQLiteDatabase.CONFLICT_REPLACE)
}

private fun advanceTombstoneVersion(
    database: SQLiteDatabase,
    entityId: String,
    version: EntityVersion,
) {
    val normalizedId = canonicalEntityId(entityId)
    val values = ContentValues(2).apply {
        put("lamport", version.lamport)
        put("device_id", version.deviceId)
    }
    check(
        database.update(
            TABLE_TOMBSTONES,
            values,
            "entity_id = ? COLLATE NOCASE",
            arrayOf(normalizedId),
        ) == 1,
    ) {
        "tombstone 版本记录缺失"
    }
}

private fun currentCursor(database: SQLiteDatabase): Long = database.rawQuery(
    "SELECT cursor FROM sync_state WHERE id = 1",
    null,
).use { cursor ->
    check(cursor.moveToFirst()) { "同步状态未初始化" }
    cursor.getLong(0)
}

private fun removeMatchingTrashRows(
    database: SQLiteDatabase,
    task: TaskInstancePayload,
) {
    database.delete(
        SQLiteTrashTable.TABLE,
        """
        series_id = ? COLLATE NOCASE AND id != ? COLLATE NOCASE
        AND title = ? AND time_type = ? AND quest_line = ?
        AND sort_order = ? AND created_at = ?
        AND IFNULL(target_date, '') = IFNULL(?, '')
        AND IFNULL(deadline_date, '') = IFNULL(?, '')
        AND IFNULL(reminder_time, '') = IFNULL(?, '')
        """.trimIndent(),
        arrayOf(
            task.seriesId,
            task.id,
            task.title,
            task.timeType.value,
            task.questLine,
            task.sortOrder.toString(),
            task.createdAt.toString(),
            task.periodStart ?: "",
            task.deadlineDate ?: "",
            task.reminderTime ?: "",
        ),
    )
}

private fun liveTaskMatches(database: SQLiteDatabase, task: TaskEntity): Boolean {
    val payload = task.toWirePayload()
    val selection = """
        series_id = ? COLLATE NOCASE AND id != ? COLLATE NOCASE
        AND title = ? AND time_type = ? AND quest_line = ?
        AND sort_order = ? AND created_at = ?
        AND IFNULL(target_date, '') = IFNULL(?, '')
        AND IFNULL(deadline_date, '') = IFNULL(?, '')
        AND IFNULL(reminder_time, '') = IFNULL(?, '')
    """.trimIndent()
    return database.query(
        "tasks",
        arrayOf("id"),
        selection,
        arrayOf(
            payload.seriesId,
            payload.id,
            payload.title,
            payload.timeType.value,
            payload.questLine,
            payload.sortOrder.toString(),
            payload.createdAt.toString(),
            payload.periodStart ?: "",
            payload.deadlineDate ?: "",
            payload.reminderTime ?: "",
        ),
        null,
        null,
        null,
        "1",
    ).use { it.moveToFirst() }
}

private fun readTask(database: SQLiteDatabase, id: String): TaskEntity? = database.query(
    "tasks",
    null,
    "id = ? COLLATE NOCASE",
    arrayOf(canonicalEntityId(id)),
    null,
    null,
    null,
    "1",
).use { cursor ->
    if (!cursor.moveToFirst()) null else cursor.toTaskEntity()
}

private fun readCategories(database: SQLiteDatabase): List<TaskCategory> =
    database.query(
        TABLE_CATEGORIES,
        arrayOf("id", "name", "sort_order"),
        null,
        null,
        null,
        null,
        "sort_order ASC, id ASC",
    ).use { cursor ->
        buildList {
            while (cursor.moveToNext()) {
                add(
                    TaskCategory(
                        id = cursor.getString(0),
                        name = cursor.getString(1),
                        order = cursor.getInt(2),
                    ),
                )
            }
        }
    }

/**
 * 配对成功后绑定本地数据库。显式替换旧身份时原子重绑；本机没有旧凭据
 * 但数据库仍绑定旧身份（上次退出或写入中断）时同样自愈为替换，避免
 * 永久停留在无法绑定、无法重新配对的状态。
 */
fun bindPairedSyncStore(
    database: TaskDatabase,
    credentials: SyncCredentials,
    replacedExistingCredentials: Boolean,
    onTasksChanged: () -> Unit = {},
    onDisplayConfigurationChanged: (DisplayConfigurationPayload) -> Unit = {},
): SQLiteSyncStore {
    if (replacedExistingCredentials) {
        return SQLiteSyncStore.replaceSyncBinding(
            database = database,
            credentials = credentials,
            onTasksChanged = onTasksChanged,
            onDisplayConfigurationChanged = onDisplayConfigurationChanged,
        )
    }
    return try {
        SQLiteSyncStore(
            database = database,
            credentials = credentials,
            onTasksChanged = onTasksChanged,
            onDisplayConfigurationChanged = onDisplayConfigurationChanged,
        )
    } catch (error: SyncBindingConflictException) {
        SQLiteSyncStore.replaceSyncBinding(
            database = database,
            credentials = credentials,
            onTasksChanged = onTasksChanged,
            onDisplayConfigurationChanged = onDisplayConfigurationChanged,
        )
    }
}

fun readDisplayConfiguration(database: SQLiteDatabase): DisplayConfigurationPayload? =
    database.query(
        TABLE_DISPLAY_CONFIGURATION,
        arrayOf("id", "header_template", "subtitle_template", "start_date", "deadline_date"),
        "id = ?",
        arrayOf(DISPLAY_CONFIGURATION_ENTITY_ID),
        null,
        null,
        null,
        "1",
    ).use { cursor ->
        if (!cursor.moveToFirst()) null else DisplayConfigurationPayload(
            id = cursor.getString(0),
            headerTemplate = cursor.getString(1),
            subtitleTemplate = cursor.getString(2),
            startDate = cursor.getString(3),
            deadlineDate = cursor.getString(4),
        ).also { SyncJsonCodec.encodeTaskPayload(it) }
    }

fun readDisplayConfigurationLocalOverride(database: SQLiteDatabase): Boolean =
    database.query(
        TABLE_DISPLAY_CONFIGURATION,
        arrayOf("is_local_override"),
        "id = ?",
        arrayOf(DISPLAY_CONFIGURATION_ENTITY_ID),
        null,
        null,
        null,
        "1",
    ).use { cursor -> cursor.moveToFirst() && cursor.getInt(0) == 1 }

fun writeDisplayConfiguration(
    database: SQLiteDatabase,
    payload: DisplayConfigurationPayload,
    isLocalOverride: Boolean = true,
) {
    // 通过 codec 校验长度、日期和固定实体 ID，避免旁路写入无效共享配置。
    SyncJsonCodec.encodeTaskPayload(payload)
    val values = ContentValues(6).apply {
        put("id", payload.id)
        put("header_template", payload.headerTemplate)
        put("subtitle_template", payload.subtitleTemplate)
        put("start_date", payload.startDate)
        put("deadline_date", payload.deadlineDate)
        put("is_local_override", if (isLocalOverride) 1 else 0)
    }
    check(
        database.insertWithOnConflict(
            TABLE_DISPLAY_CONFIGURATION,
            null,
            values,
            SQLiteDatabase.CONFLICT_REPLACE,
        ) != -1L,
    ) { "显示配置写入失败" }
}

private fun Cursor.toTaskList(): List<TaskEntity> = buildList {
    while (moveToNext()) add(toTaskEntity())
}

private fun Cursor.toTaskEntity(): TaskEntity {
    val start = getColumnIndexOrThrow("target_date").let { index ->
        if (isNull(index)) null else LocalDate.parse(getString(index))
    }
    val deadline = getColumnIndexOrThrow("deadline_date").let { index ->
        if (isNull(index)) null else LocalDate.parse(getString(index))
    }
    val timeType = getString(getColumnIndexOrThrow("time_type")).lowercase()
    val defaultEnd = when (timeType) {
        "day" -> start
        "week" -> start?.plusDays(6)
        "month" -> start?.let { YearMonth.from(it).atEndOfMonth() }
        else -> null
    }
    val end = when {
        start == null && deadline == null -> null
        start == null -> deadline
        deadline == null -> defaultEnd ?: start
        defaultEnd == null -> maxOf(start, deadline)
        else -> maxOf(defaultEnd, deadline)
    }
    val effectiveStart = if (start == null && end != null) end else start
    return TaskEntity(
        id = getString(getColumnIndexOrThrow("id")),
        seriesId = getString(getColumnIndexOrThrow("series_id")),
        title = getString(getColumnIndexOrThrow("title")),
        categoryId = getString(getColumnIndexOrThrow("quest_line")),
        startDate = effectiveStart,
        endDate = end,
        status = TaskStatus.fromRaw(getString(getColumnIndexOrThrow("status"))),
        sortOrder = getInt(getColumnIndexOrThrow("sort_order")),
        createdAt = getLong(getColumnIndexOrThrow("created_at")),
        updatedAt = getLong(getColumnIndexOrThrow("updated_at")),
        settledAt = getColumnIndexOrThrow("settled_at").let { index ->
            if (isNull(index)) null else getLong(index)
        },
        reminderTime = getColumnIndexOrThrow("reminder_time").let { index ->
            if (isNull(index) || effectiveStart == null) null else LocalTime.parse(getString(index))
        },
        recurrence = TaskRecurrence.fromRaw(getString(getColumnIndexOrThrow("recurrence"))),
    )
}

private fun TaskEntity.toContentValues(): ContentValues = ContentValues(14).apply {
    put("id", id)
    put("series_id", seriesId)
    put("title", title)
    put(
        "time_type",
        if (startDate == null && endDate == null) "someday" else "day",
    )
    if (startDate == null) putNull("target_date") else put("target_date", startDate.toString())
    put("quest_line", categoryId)
    put("status", status.rawValue)
    put("recurrence", recurrence.rawValue)
    put("sort_order", sortOrder)
    put("created_at", createdAt)
    put("updated_at", updatedAt)
    if (settledAt == null) putNull("settled_at") else put("settled_at", settledAt)
    if (reminderTime == null || startDate == null) {
        putNull("reminder_time")
    } else {
        put("reminder_time", reminderTime.toString())
    }
    if (endDate == null) putNull("deadline_date") else put("deadline_date", endDate.toString())
}

fun TaskEntity.toWirePayload(): TaskInstancePayload {
    val start = startDate ?: endDate
    val end = endDate ?: startDate
    val ranged = start != null && end != null
    return TaskInstancePayload(
        id = id,
        seriesId = seriesId,
        title = title,
        timeType = if (ranged) WireTimeType.DAY else WireTimeType.SOMEDAY,
        periodStart = start?.toString(),
        deadlineDate = end?.toString(),
        timezone = WIRE_FIXED_TIMEZONE,
        questLine = categoryId,
        state = status.toWire(),
        recurrence = if (recurrence == TaskRecurrence.DAILY) {
            WireRecurrence.REPEAT
        } else {
            WireRecurrence.ONCE
        },
        sortOrder = sortOrder.toLong(),
        createdAt = createdAt,
        updatedAt = updatedAt,
        settledAt = settledAt,
        reminderTime = if (ranged) reminderTime?.toString() else null,
    )
}

fun TaskInstancePayload.toTaskEntity(): TaskEntity {
    require(timezone == WIRE_FIXED_TIMEZONE) { "Android v1 仅支持 Asia/Shanghai 任务" }
    require(sortOrder <= Int.MAX_VALUE) { "sortOrder 超出 Android 范围" }
    val start = periodStart?.let(LocalDate::parse)
    val deadline = deadlineDate?.let(LocalDate::parse)
    val defaultEnd = when (timeType) {
        WireTimeType.DAY -> start
        WireTimeType.WEEK -> start?.plusDays(6)
        WireTimeType.MONTH -> start?.let { YearMonth.from(it).atEndOfMonth() }
        WireTimeType.SOMEDAY -> null
    }
    val end = when {
        start == null && deadline == null -> null
        start == null -> deadline
        deadline == null -> defaultEnd ?: start
        defaultEnd == null -> maxOf(start, deadline)
        else -> maxOf(defaultEnd, deadline)
    }
    val effectiveStart = if (start == null && end != null) end else start
    return TaskEntity(
        id = id,
        seriesId = seriesId,
        title = title,
        categoryId = questLine,
        startDate = effectiveStart,
        endDate = end,
        status = state.toDomain(),
        sortOrder = sortOrder.toInt(),
        createdAt = createdAt,
        updatedAt = updatedAt,
        settledAt = settledAt,
        reminderTime = if (effectiveStart == null) null else reminderTime?.let(LocalTime::parse),
        recurrence = if (recurrence == WireRecurrence.REPEAT && timeType == WireTimeType.DAY) {
            TaskRecurrence.DAILY
        } else {
            TaskRecurrence.ONCE
        },
    )
}

private fun requireKindMatchesTask(kind: SyncOperationKind, payload: TaskInstancePayload) {
    when (kind) {
        SyncOperationKind.COMPLETE -> require(payload.state == WireTaskState.COMPLETED)
        SyncOperationKind.PASS -> require(payload.state == WireTaskState.PASS)
        SyncOperationKind.REOPEN -> require(TaskMergePolicy.isValidReopen(payload))
        SyncOperationKind.UPSERT, SyncOperationKind.REORDER -> Unit
        SyncOperationKind.DELETE -> error("delete 必须携带 tombstone")
    }
}

private fun TaskStatus.toWire(): WireTaskState = when (this) {
    TaskStatus.PENDING -> WireTaskState.PENDING
    TaskStatus.COMPLETED -> WireTaskState.COMPLETED
    TaskStatus.PASS -> WireTaskState.PASS
}

private fun WireTaskState.toDomain(): TaskStatus = when (this) {
    WireTaskState.PENDING -> TaskStatus.PENDING
    WireTaskState.COMPLETED -> TaskStatus.COMPLETED
    WireTaskState.PASS -> TaskStatus.PASS
}

private const val TABLE_TASKS = "tasks"
private const val TABLE_CATEGORIES = "task_categories"
private const val TABLE_OUTBOX = "sync_outbox"
private const val TABLE_VERSIONS = "sync_entity_versions"
private const val TABLE_TOMBSTONES = "sync_tombstones"
private const val TABLE_APPLIED = "sync_applied_operations"
private const val TABLE_DEFERRED_DELETIONS = "sync_deferred_deletions"
private const val TABLE_DISPLAY_CONFIGURATION = "display_configuration"
