package com.wootodo.sync

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskEntity
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.LocalDate

class SQLiteBackupDatabase(private val database: TaskDatabase) : BackupDatabase {
    @Synchronized
    override fun readState(): BackupDatabaseState = readState(database.readableDatabase)

    @Synchronized
    override fun readTaskSnapshot(): BackupTaskSnapshot {
        val sqlite = database.readableDatabase
        sqlite.beginTransaction()
        return try {
            val snapshot = BackupTaskSnapshot(
                state = readState(sqlite),
                tasks = sqlite.query(
                    TABLE_TASKS,
                    null,
                    null,
                    null,
                    null,
                    null,
                    "created_at ASC, id ASC",
                ).use { cursor ->
                    buildList {
                        while (cursor.moveToNext()) add(cursor.toTaskEntity().toWirePayload())
                    }
                },
                tombstones = readTombstones(sqlite),
            )
            sqlite.setTransactionSuccessful()
            snapshot
        } finally {
            sqlite.endTransaction()
        }
    }

    @Synchronized
    override fun <T> inTransaction(block: (BackupRestoreTransaction) -> T): T {
        val sqlite = database.writableDatabase
        sqlite.beginTransaction()
        return try {
            val result = block(SQLiteTransaction(sqlite))
            sqlite.setTransactionSuccessful()
            result
        } finally {
            sqlite.endTransaction()
        }
    }

    private class SQLiteTransaction(
        private val sqlite: SQLiteDatabase,
    ) : BackupRestoreTransaction {
        override fun readState(): BackupDatabaseState = readState(sqlite)

        override fun insertTask(task: TaskInstancePayload) {
            check(!hasDeletionBarrier(sqlite, task.id)) {
                "已删除任务不能以相同 ID 恢复"
            }
            val entity = task.toTaskEntity()
            sqlite.insertOrThrow(TABLE_TASKS, null, entity.toContentValues())
        }

        override fun insertTombstone(tombstone: TombstonePayload) {
            check(!hasTask(sqlite, tombstone.id)) {
                "同一备份不能同时包含相同 ID 的任务和删除记录"
            }
            val values = ContentValues(2).apply {
                put("entity_id", tombstone.id)
                put("deleted_at", tombstone.deletedAt)
            }
            sqlite.insertOrThrow(TABLE_DEFERRED_DELETIONS, null, values)
        }

        override fun bindIdentityAndCreateBaseline(credentials: SyncCredentials) {
            credentials.validate()
            val identity = ContentValues(2).apply {
                put("vault_id", credentials.vaultId)
                put("device_id", credentials.deviceId)
            }
            check(
                sqlite.update(
                    TABLE_SYNC_STATE,
                    identity,
                    "id = 1 AND vault_id = '' AND device_id = ''",
                    null,
                ) == 1,
            ) { "恢复期间本地同步身份发生变化" }

            sqlite.query(
                TABLE_TASKS,
                null,
                null,
                null,
                null,
                null,
                "created_at ASC, id ASC",
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    SQLiteLocalMutationRecorder.recordTask(
                        sqlite,
                        cursor.toTaskEntity(),
                        SyncOperationKind.UPSERT,
                    )
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
            deferredDeletions.forEach { (entityId, deletedAt) ->
                SQLiteLocalMutationRecorder.recordDeletion(sqlite, entityId, deletedAt)
            }
        }
    }
}

private fun readTombstones(sqlite: SQLiteDatabase): List<TombstonePayload> = sqlite.rawQuery(
    """
    SELECT entity_id, MAX(deleted_at) AS deleted_at
    FROM (
        SELECT entity_id, deleted_at FROM sync_tombstones
        UNION ALL
        SELECT entity_id, deleted_at FROM sync_deferred_deletions
    )
    GROUP BY entity_id
    ORDER BY deleted_at ASC, entity_id ASC
    """.trimIndent(),
    null,
).use { cursor ->
    buildList {
        while (cursor.moveToNext()) {
            add(TombstonePayload(id = cursor.getString(0), deletedAt = cursor.getLong(1)))
        }
    }
}

private fun hasTask(sqlite: SQLiteDatabase, entityId: String): Boolean = sqlite.rawQuery(
    "SELECT 1 FROM tasks WHERE id = ? LIMIT 1",
    arrayOf(entityId),
).use(Cursor::moveToFirst)

private fun hasDeletionBarrier(sqlite: SQLiteDatabase, entityId: String): Boolean = sqlite.rawQuery(
    """
    SELECT 1 FROM sync_entity_versions
    WHERE entity_id = ? AND is_tombstone = 1
    UNION ALL
    SELECT 1 FROM sync_tombstones
    WHERE entity_id = ?
    UNION ALL
    SELECT 1 FROM sync_deferred_deletions
    WHERE entity_id = ?
    LIMIT 1
    """.trimIndent(),
    arrayOf(entityId, entityId, entityId),
).use(Cursor::moveToFirst)

private fun readState(sqlite: SQLiteDatabase): BackupDatabaseState = sqlite.rawQuery(
    """
    SELECT
        cursor,
        lamport,
        vault_id,
        device_id,
        (SELECT COUNT(*) FROM tasks),
        (SELECT COUNT(*) FROM sync_outbox),
        (SELECT COUNT(*) FROM sync_entity_versions),
        (SELECT COUNT(*) FROM sync_tombstones) +
            (SELECT COUNT(*) FROM sync_deferred_deletions),
        (SELECT COUNT(*) FROM sync_applied_operations)
    FROM sync_state
    WHERE id = 1
    """.trimIndent(),
    null,
).use { cursor ->
    check(cursor.moveToFirst()) { "同步状态未初始化" }
    BackupDatabaseState(
        cursor = cursor.getLong(0),
        lamport = cursor.getLong(1),
        vaultId = cursor.getString(2),
        deviceId = cursor.getString(3),
        taskCount = cursor.getInt(4),
        outboxCount = cursor.getInt(5),
        entityVersionCount = cursor.getInt(6),
        tombstoneCount = cursor.getInt(7),
        appliedOperationCount = cursor.getInt(8),
    )
}

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

private const val TABLE_TASKS = "tasks"
private const val TABLE_SYNC_STATE = "sync_state"
private const val TABLE_DEFERRED_DELETIONS = "sync_deferred_deletions"
