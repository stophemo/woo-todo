package com.wootodo.sync

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskEntity
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.nio.charset.StandardCharsets
import java.time.LocalDate
import java.time.ZoneId
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

/** tombstone 之外先合并终态语义，其余字段使用 (lamport, deviceId) 的确定性 LWW。 */
object TaskMergePolicy {
    fun resolve(
        currentTask: TaskInstancePayload?,
        currentVersion: EntityVersion?,
        incomingTask: TaskInstancePayload,
        incomingVersion: EntityVersion,
    ): TaskMergeDecision {
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

    fun isValidCompletion(task: TaskInstancePayload): Boolean {
        if (task.state != WireTaskState.COMPLETED || task.settledAt == null) return false
        if (task.timeType == WireTimeType.SOMEDAY) return true
        val periodStart = task.periodStart?.let(LocalDate::parse) ?: return false
        val periodEnd = when (task.timeType) {
            WireTimeType.DAY -> periodStart.plusDays(1)
            WireTimeType.WEEK -> periodStart.plusWeeks(1)
            WireTimeType.MONTH -> periodStart.plusMonths(1)
            WireTimeType.SOMEDAY -> return true
        }
        val endMillis = periodEnd.atStartOfDay(ZoneId.of(task.timezone))
            .toInstant()
            .toEpochMilli()
        return task.settledAt < endMillis
    }
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
                SyncOperationKind.REORDER,
            ),
        )
        check(!isDeletionBarrier(database, task.id)) {
            "已删除任务不能以相同 ID 复活"
        }
        val version = nextLocalVersion(database) ?: return
        val payload = task.toWirePayload()
        requireKindMatchesTask(kind, payload)
        enqueue(
            database = database,
            entityId = task.id,
            kind = kind,
            version = version,
            payloadJson = SyncJsonCodec.encodeTaskPayload(payload),
            createdAt = task.updatedAt,
        )
        writeVersion(database, task.id, version, isTombstone = false)
    }

    fun recordDeletion(database: SQLiteDatabase, entityId: String, deletedAt: Long) {
        val version = nextLocalVersion(database)
        if (version == null) {
            recordDeferredDeletion(database, entityId, deletedAt)
            return
        }
        val payload = TombstonePayload(id = entityId, deletedAt = deletedAt)
        enqueue(
            database = database,
            entityId = entityId,
            kind = SyncOperationKind.DELETE,
            version = version,
            payloadJson = SyncJsonCodec.encodeTaskPayload(payload),
            createdAt = deletedAt,
        )
        writeVersion(database, entityId, version, isTombstone = true)
        writeTombstone(database, payload, version)
        database.delete(TABLE_DEFERRED_DELETIONS, "entity_id = ?", arrayOf(entityId))
    }

    fun recordDeferredDeletion(database: SQLiteDatabase, entityId: String, deletedAt: Long) {
        require(entityId.isNotBlank() && deletedAt >= 0)
        val values = ContentValues(2).apply {
            put("entity_id", entityId)
            put("deleted_at", deletedAt)
        }
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
    internal fun isDeletionBarrier(database: SQLiteDatabase, entityId: String): Boolean =
        database.rawQuery(
            """
            SELECT 1 FROM $TABLE_VERSIONS
            WHERE entity_id = ? AND is_tombstone = 1
            UNION ALL
            SELECT 1 FROM $TABLE_TOMBSTONES
            WHERE entity_id = ?
            UNION ALL
            SELECT 1 FROM $TABLE_DEFERRED_DELETIONS
            WHERE entity_id = ?
            LIMIT 1
            """.trimIndent(),
            arrayOf(entityId, entityId, entityId),
        ).use(Cursor::moveToFirst)

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

class SQLiteSyncStore(
    private val database: TaskDatabase,
    private val credentials: SyncCredentials,
    private val onTasksChanged: () -> Unit = {},
) : OutboxStore, RemoteApplyStore {
    init {
        credentials.validate()
        bindDeviceIdentity()
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

    @Synchronized
    override fun applyRemoteOperations(
        operations: List<SyncPulledOperation>,
        advancingCursorTo: Long,
    ) {
        val sqlite = database.writableDatabase
        var tasksChanged = false
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
                    tasksChanged = applyPayload(sqlite, operation, payload) || tasksChanged
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
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        if (tasksChanged) onTasksChanged()
    }

    private fun bindDeviceIdentity() {
        val sqlite = database.writableDatabase
        sqlite.beginTransaction()
        try {
            val current = sqlite.rawQuery(
                "SELECT vault_id, device_id FROM sync_state WHERE id = 1",
                null,
            ).use { cursor ->
                check(cursor.moveToFirst()) { "同步状态未初始化" }
                cursor.getString(0) to cursor.getString(1)
            }
            val isUnbound = current.first.isEmpty() && current.second.isEmpty()
            require(
                isUnbound ||
                    (current.first == credentials.vaultId && current.second == credentials.deviceId),
            ) {
                "本地数据库已绑定到其他同步空间或设备"
            }
            if (isUnbound) {
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
            }
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
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

    private fun applyPayload(
        sqlite: SQLiteDatabase,
        operation: SyncPulledOperation,
        payload: TaskWirePayload,
    ): Boolean = when (payload) {
        is TaskInstancePayload -> applyTask(sqlite, operation, payload)
        is TombstonePayload -> applyTombstone(sqlite, operation, payload)
    }

    private fun applyTask(
        sqlite: SQLiteDatabase,
        operation: SyncPulledOperation,
        payload: TaskInstancePayload,
    ): Boolean {
        requireKindMatchesTask(operation.kind, payload)
        val incomingVersion = EntityVersion(operation.lamport, operation.deviceId)
        val currentVersion = readVersion(sqlite, payload.id)
        // tombstone 是实体 ID 的终态；更高 Lamport 也只能使用新 ID 创建任务。
        if (currentVersion?.isTombstone == true) {
            val horizon = maxOf(currentVersion.version, incomingVersion)
            if (horizon != currentVersion.version) {
                writeVersion(sqlite, payload.id, horizon, isTombstone = true)
                advanceTombstoneVersion(sqlite, payload.id, horizon)
            }
            return false
        }
        val currentTask = readTask(sqlite, payload.id)?.toWirePayload()
        val decision = TaskMergePolicy.resolve(
            currentTask,
            currentVersion?.version,
            payload,
            incomingVersion,
        )
        val resolvedTask = decision.resolvedTask
        val changed = resolvedTask != null && resolvedTask != currentTask
        if (changed) {
            val values = resolvedTask.toTaskEntity().toContentValues()
            sqlite.insertWithOnConflict("tasks", null, values, SQLiteDatabase.CONFLICT_REPLACE)
        }
        if (currentVersion == null || decision.resolvedVersion != currentVersion.version) {
            writeVersion(sqlite, payload.id, decision.resolvedVersion, isTombstone = false)
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
        val incomingVersion = EntityVersion(operation.lamport, operation.deviceId)
        val currentVersion = readVersion(sqlite, payload.id)
        if (currentVersion?.isTombstone == true && incomingVersion <= currentVersion.version) {
            return false
        }
        val horizon = currentVersion?.version?.let { maxOf(it, incomingVersion) } ?: incomingVersion
        val taskDeleted = sqlite.delete("tasks", "id = ?", arrayOf(payload.id)) == 1
        sqlite.delete(TABLE_DEFERRED_DELETIONS, "entity_id = ?", arrayOf(payload.id))
        writeTombstone(sqlite, payload, horizon)
        writeVersion(sqlite, payload.id, horizon, isTombstone = true)
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
        "SELECT lamport, device_id, is_tombstone FROM $TABLE_VERSIONS WHERE entity_id = ?",
        arrayOf(entityId),
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
    val values = ContentValues(4).apply {
        put("entity_id", entityId)
        put("lamport", version.lamport)
        put("device_id", version.deviceId)
        put("is_tombstone", if (isTombstone) 1 else 0)
    }
    database.insertWithOnConflict(TABLE_VERSIONS, null, values, SQLiteDatabase.CONFLICT_REPLACE)
}

private fun writeTombstone(
    database: SQLiteDatabase,
    payload: TombstonePayload,
    version: EntityVersion,
) {
    val values = ContentValues(4).apply {
        put("entity_id", payload.id)
        put("deleted_at", payload.deletedAt)
        put("lamport", version.lamport)
        put("device_id", version.deviceId)
    }
    database.insertWithOnConflict(TABLE_TOMBSTONES, null, values, SQLiteDatabase.CONFLICT_REPLACE)
}

private fun advanceTombstoneVersion(
    database: SQLiteDatabase,
    entityId: String,
    version: EntityVersion,
) {
    val values = ContentValues(2).apply {
        put("lamport", version.lamport)
        put("device_id", version.deviceId)
    }
    check(database.update(TABLE_TOMBSTONES, values, "entity_id = ?", arrayOf(entityId)) == 1) {
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

private fun readTask(database: SQLiteDatabase, id: String): TaskEntity? = database.query(
    "tasks",
    null,
    "id = ?",
    arrayOf(id),
    null,
    null,
    null,
    "1",
).use { cursor ->
    if (!cursor.moveToFirst()) null else cursor.toTaskEntity()
}

private fun Cursor.toTaskEntity(): TaskEntity = TaskEntity(
    id = getString(getColumnIndexOrThrow("id")),
    seriesId = getString(getColumnIndexOrThrow("series_id")),
    title = getString(getColumnIndexOrThrow("title")),
    timeType = TaskTimeType.fromRaw(getString(getColumnIndexOrThrow("time_type"))),
    targetDate = getColumnIndexOrThrow("target_date").let { index ->
        if (isNull(index)) null else LocalDate.parse(getString(index))
    },
    questLine = QuestLine.fromRaw(getString(getColumnIndexOrThrow("quest_line"))),
    status = TaskStatus.fromRaw(getString(getColumnIndexOrThrow("status"))),
    recurrence = Recurrence.fromRaw(getString(getColumnIndexOrThrow("recurrence"))),
    sortOrder = getInt(getColumnIndexOrThrow("sort_order")),
    createdAt = getLong(getColumnIndexOrThrow("created_at")),
    updatedAt = getLong(getColumnIndexOrThrow("updated_at")),
    settledAt = getColumnIndexOrThrow("settled_at").let { index ->
        if (isNull(index)) null else getLong(index)
    },
)

private fun TaskEntity.toContentValues(): ContentValues = ContentValues(12).apply {
    put("id", id)
    put("series_id", seriesId)
    put("title", title)
    put("time_type", timeType.rawValue)
    if (targetDate == null) putNull("target_date") else put("target_date", targetDate.toString())
    put("quest_line", questLine.rawValue)
    put("status", status.rawValue)
    put("recurrence", recurrence.rawValue)
    put("sort_order", sortOrder)
    put("created_at", createdAt)
    put("updated_at", updatedAt)
    if (settledAt == null) putNull("settled_at") else put("settled_at", settledAt)
}

fun TaskEntity.toWirePayload(): TaskInstancePayload = TaskInstancePayload(
    id = id,
    seriesId = seriesId,
    title = title,
    timeType = timeType.toWire(),
    periodStart = targetDate?.toString(),
    timezone = TaskDateRules.zoneId.id,
    questLine = questLine.toWire(),
    state = status.toWire(),
    recurrence = if (recurrence == Recurrence.ONCE) WireRecurrence.ONCE else WireRecurrence.REPEAT,
    sortOrder = sortOrder.toLong(),
    createdAt = createdAt,
    updatedAt = updatedAt,
    settledAt = settledAt,
)

fun TaskInstancePayload.toTaskEntity(): TaskEntity {
    require(timezone == TaskDateRules.zoneId.id) { "Android v1 仅支持 Asia/Shanghai 任务周期" }
    require(sortOrder <= Int.MAX_VALUE) { "sortOrder 超出 Android 范围" }
    return TaskEntity(
        id = id,
        seriesId = seriesId,
        title = title,
        timeType = timeType.toDomain(),
        targetDate = periodStart?.let(LocalDate::parse),
        questLine = questLine.toDomain(),
        status = state.toDomain(),
        recurrence = when (recurrence) {
            WireRecurrence.ONCE -> Recurrence.ONCE
            WireRecurrence.REPEAT -> when (timeType) {
                WireTimeType.DAY -> Recurrence.DAILY
                WireTimeType.WEEK -> Recurrence.WEEKLY
                WireTimeType.MONTH -> Recurrence.MONTHLY
                WireTimeType.SOMEDAY -> error("闲时任务不能重复")
            }
        },
        sortOrder = sortOrder.toInt(),
        createdAt = createdAt,
        updatedAt = updatedAt,
        settledAt = settledAt,
    )
}

private fun requireKindMatchesTask(kind: SyncOperationKind, payload: TaskInstancePayload) {
    when (kind) {
        SyncOperationKind.COMPLETE -> require(payload.state == WireTaskState.COMPLETED)
        SyncOperationKind.PASS -> require(payload.state == WireTaskState.PASS)
        SyncOperationKind.UPSERT, SyncOperationKind.REORDER -> Unit
        SyncOperationKind.DELETE -> error("delete 必须携带 tombstone")
    }
}

private fun TaskTimeType.toWire(): WireTimeType = when (this) {
    TaskTimeType.DAY -> WireTimeType.DAY
    TaskTimeType.WEEK -> WireTimeType.WEEK
    TaskTimeType.MONTH -> WireTimeType.MONTH
    TaskTimeType.LEISURE -> WireTimeType.SOMEDAY
}

private fun WireTimeType.toDomain(): TaskTimeType = when (this) {
    WireTimeType.DAY -> TaskTimeType.DAY
    WireTimeType.WEEK -> TaskTimeType.WEEK
    WireTimeType.MONTH -> TaskTimeType.MONTH
    WireTimeType.SOMEDAY -> TaskTimeType.LEISURE
}

private fun QuestLine.toWire(): WireQuestLine = when (this) {
    QuestLine.MAIN -> WireQuestLine.MAIN
    QuestLine.SIDE -> WireQuestLine.SIDE
    QuestLine.EXTRA -> WireQuestLine.EXTRA
}

private fun WireQuestLine.toDomain(): QuestLine = when (this) {
    WireQuestLine.MAIN -> QuestLine.MAIN
    WireQuestLine.SIDE -> QuestLine.SIDE
    WireQuestLine.EXTRA -> QuestLine.EXTRA
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

private const val TABLE_OUTBOX = "sync_outbox"
private const val TABLE_VERSIONS = "sync_entity_versions"
private const val TABLE_TOMBSTONES = "sync_tombstones"
private const val TABLE_APPLIED = "sync_applied_operations"
private const val TABLE_DEFERRED_DELETIONS = "sync_deferred_deletions"
