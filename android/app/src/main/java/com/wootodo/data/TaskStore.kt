package com.wootodo.data

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskStatus
import com.wootodo.sync.SQLiteLocalMutationRecorder
import com.wootodo.sync.SyncOperationKind
import java.time.LocalDate
import java.time.LocalTime
import java.time.YearMonth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext

interface TaskStore {
    fun observeAll(): Flow<List<TaskEntity>>

    suspend fun getAll(): List<TaskEntity> = observeAll().first()

    fun observeCategories(): Flow<List<TaskCategory>>

    suspend fun getCategories(): List<TaskCategory>

    suspend fun replaceCategories(categories: List<TaskCategory>, updatedAt: Long)

    suspend fun getById(id: String): TaskEntity?

    suspend fun insert(task: TaskEntity)

    suspend fun update(task: TaskEntity): Boolean

    suspend fun deletePending(id: String, deletedAt: Long): Boolean

    suspend fun getTrash(): List<TrashedTaskEntity> = emptyList()

    suspend fun restoreTrash(
        id: String,
        restoredAt: Long,
        idFactory: () -> String,
    ): String? = null

    suspend fun removeTrash(ids: Set<String>?): Int = 0

    suspend fun deleteSettled(ids: Set<String>?, deletedAt: Long): Int

    suspend fun settle(id: String, status: TaskStatus, settledAt: Long): Boolean

    suspend fun reopenCompleted(id: String, updatedAt: Long): Boolean

    suspend fun reassignPendingCategory(from: String, to: String, updatedAt: Long): List<String>
}

class SQLiteTaskStore(private val database: TaskDatabase) : TaskStore {
    private val invalidations = MutableStateFlow(0L)
    private val categoryInvalidations = MutableStateFlow(0L)

    override fun observeAll(): Flow<List<TaskEntity>> = invalidations
        .map { queryTasks() }
        .flowOn(Dispatchers.IO)
        .distinctUntilChanged()

    override suspend fun getAll(): List<TaskEntity> = withContext(Dispatchers.IO) {
        queryTasks()
    }

    override fun observeCategories(): Flow<List<TaskCategory>> = categoryInvalidations
        .map { queryCategories() }
        .flowOn(Dispatchers.IO)
        .distinctUntilChanged()

    override suspend fun getCategories(): List<TaskCategory> = withContext(Dispatchers.IO) {
        queryCategories()
    }

    override suspend fun replaceCategories(
        categories: List<TaskCategory>,
        updatedAt: Long,
    ) = withContext(Dispatchers.IO) {
        val sqlite = database.writableDatabase
        sqlite.beginTransaction()
        try {
            sqlite.delete(TABLE_CATEGORIES, null, null)
            categories.forEach { category ->
                sqlite.insertOrThrow(
                    TABLE_CATEGORIES,
                    null,
                    ContentValues(4).apply {
                        put("id", category.id)
                        put("name", category.name)
                        put("sort_order", category.order)
                        put("updated_at", updatedAt)
                    },
                )
            }
            SQLiteLocalMutationRecorder.recordCategoryConfiguration(
                sqlite,
                categories,
                updatedAt,
            )
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        invalidateCategories()
    }

    override suspend fun getById(id: String): TaskEntity? = withContext(Dispatchers.IO) {
        getById(database.readableDatabase, id)
    }

    override suspend fun insert(task: TaskEntity): Unit = withContext(Dispatchers.IO) {
        val sqlite = database.writableDatabase
        sqlite.beginTransaction()
        try {
            sqlite.insertOrThrow(TABLE_TASKS, null, task.toContentValues())
            SQLiteLocalMutationRecorder.recordTask(sqlite, task, SyncOperationKind.UPSERT)
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        invalidate()
    }

    override suspend fun update(task: TaskEntity): Boolean = withContext(Dispatchers.IO) {
        val sqlite = database.writableDatabase
        var changed = false
        sqlite.beginTransaction()
        try {
            changed = sqlite.update(
                TABLE_TASKS,
                task.toContentValues(),
                "id = ?",
                arrayOf(task.id),
            ) == 1
            if (changed) {
                SQLiteLocalMutationRecorder.recordTask(sqlite, task, SyncOperationKind.UPSERT)
            }
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        if (changed) invalidate()
        changed
    }

    override suspend fun deletePending(id: String, deletedAt: Long): Boolean =
        withContext(Dispatchers.IO) {
            val sqlite = database.writableDatabase
            var changed = false
            sqlite.beginTransaction()
            try {
                SQLiteTrashTable.insertFromTask(sqlite, id, deletedAt)
                changed = sqlite.delete(
                    TABLE_TASKS,
                    "id = ? AND status = ?",
                    arrayOf(id, TaskStatus.PENDING.rawValue),
                ) == 1
                if (changed) SQLiteLocalMutationRecorder.recordDeletion(sqlite, id, deletedAt)
                sqlite.setTransactionSuccessful()
            } finally {
                sqlite.endTransaction()
            }
            if (changed) invalidate()
            changed
        }

    override suspend fun getTrash(): List<TrashedTaskEntity> = withContext(Dispatchers.IO) {
        queryTrash()
    }

    override suspend fun restoreTrash(
        id: String,
        restoredAt: Long,
        idFactory: () -> String,
    ): String? = withContext(Dispatchers.IO) {
        val sqlite = database.writableDatabase
        var restoredId: String? = null
        sqlite.beginTransaction()
        try {
            val trashed = getTrashById(sqlite, id)
            if (trashed != null) {
                val newId = idFactory()
                val restored = TaskEntity(
                    id = newId,
                    // 保留 seriesId，便于其他设备按“seriesId + 内容”识别同一条任务的恢复。
                    seriesId = trashed.task.seriesId,
                    title = trashed.task.title,
                    categoryId = resolveCategoryId(sqlite, trashed.task.categoryId),
                    startDate = trashed.task.startDate,
                    endDate = trashed.task.endDate,
                    status = TaskStatus.PENDING,
                    sortOrder = trashed.task.sortOrder,
                    createdAt = trashed.task.createdAt,
                    updatedAt = restoredAt,
                    settledAt = null,
                    reminderTime = trashed.task.reminderTime,
                )
                sqlite.insertOrThrow(TABLE_TASKS, null, restored.toContentValues())
                SQLiteLocalMutationRecorder.recordTask(sqlite, restored, SyncOperationKind.UPSERT)
                sqlite.delete(
                    SQLiteTrashTable.TABLE,
                    "id = ? COLLATE NOCASE",
                    arrayOf(id),
                )
                restoredId = newId
            }
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        if (restoredId != null) invalidate()
        restoredId
    }

    override suspend fun removeTrash(ids: Set<String>?): Int = withContext(Dispatchers.IO) {
        if (ids?.isEmpty() == true) return@withContext 0
        val sqlite = database.writableDatabase
        if (ids == null) {
            sqlite.delete(SQLiteTrashTable.TABLE, null, null)
        } else {
            ids.sumOf { id ->
                sqlite.delete(
                    SQLiteTrashTable.TABLE,
                    "id = ? COLLATE NOCASE",
                    arrayOf(id),
                )
            }
        }
    }

    override suspend fun deleteSettled(ids: Set<String>?, deletedAt: Long): Int =
        withContext(Dispatchers.IO) {
            if (ids?.isEmpty() == true) return@withContext 0
            val sqlite = database.writableDatabase
            var deletedCount = 0
            sqlite.beginTransaction()
            try {
                val requestedIds = ids?.mapTo(HashSet()) { it.lowercase() }
                val settledIds = sqlite.rawQuery(
                    "SELECT id FROM $TABLE_TASKS WHERE status IN (?, ?)",
                    arrayOf(TaskStatus.COMPLETED.rawValue, TaskStatus.PASS.rawValue),
                ).use { cursor ->
                    buildList {
                        while (cursor.moveToNext()) {
                            val id = cursor.getString(0)
                            if (requestedIds == null || id.lowercase() in requestedIds) add(id)
                        }
                    }
                }
                settledIds.forEach { id ->
                    val deleted = sqlite.delete(
                        TABLE_TASKS,
                        "id = ? AND status IN (?, ?)",
                        arrayOf(
                            id,
                            TaskStatus.COMPLETED.rawValue,
                            TaskStatus.PASS.rawValue,
                        ),
                    ) == 1
                    if (deleted) {
                        SQLiteLocalMutationRecorder.recordDeletion(sqlite, id, deletedAt)
                        deletedCount += 1
                    }
                }
                sqlite.setTransactionSuccessful()
            } finally {
                sqlite.endTransaction()
            }
            if (deletedCount > 0) invalidate()
            deletedCount
        }

    override suspend fun settle(
        id: String,
        status: TaskStatus,
        settledAt: Long,
    ): Boolean = withContext(Dispatchers.IO) {
        val sqlite = database.writableDatabase
        var changed = false
        sqlite.beginTransaction()
        try {
            val current = getById(sqlite, id)
            if (current != null && current.status == TaskStatus.PENDING) {
                val values = ContentValues(3).apply {
                    put("status", status.rawValue)
                    put("settled_at", settledAt)
                    put("updated_at", settledAt)
                }
                changed = sqlite.update(
                    TABLE_TASKS,
                    values,
                    "id = ? AND status = ?",
                    arrayOf(id, TaskStatus.PENDING.rawValue),
                ) == 1
                if (changed) {
                    SQLiteLocalMutationRecorder.recordTask(
                        sqlite,
                        current.copy(status = status, settledAt = settledAt, updatedAt = settledAt),
                        if (status == TaskStatus.COMPLETED) {
                            SyncOperationKind.COMPLETE
                        } else {
                            SyncOperationKind.PASS
                        },
                    )
                }
            }
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        if (changed) invalidate()
        changed
    }

    override suspend fun reopenCompleted(id: String, updatedAt: Long): Boolean =
        withContext(Dispatchers.IO) {
            val sqlite = database.writableDatabase
            var changed = false
            sqlite.beginTransaction()
            try {
                val values = ContentValues(3).apply {
                    put("status", TaskStatus.PENDING.rawValue)
                    putNull("settled_at")
                    put("updated_at", updatedAt)
                }
                changed = sqlite.update(
                    TABLE_TASKS,
                    values,
                    "id = ? AND status = ?",
                    arrayOf(id, TaskStatus.COMPLETED.rawValue),
                ) == 1
                if (changed) {
                    getById(sqlite, id)?.let { reopened ->
                        SQLiteLocalMutationRecorder.recordTask(
                            sqlite,
                            reopened,
                            SyncOperationKind.REOPEN,
                        )
                    }
                }
                sqlite.setTransactionSuccessful()
            } finally {
                sqlite.endTransaction()
            }
            if (changed) invalidate()
            changed
        }

    override suspend fun reassignPendingCategory(
        from: String,
        to: String,
        updatedAt: Long,
    ): List<String> = withContext(Dispatchers.IO) {
        val sqlite = database.writableDatabase
        val changed = mutableListOf<String>()
        sqlite.beginTransaction()
        try {
            val tasks = sqlite.query(
                TABLE_TASKS,
                null,
                "status = ? AND quest_line = ?",
                arrayOf(TaskStatus.PENDING.rawValue, from),
                null,
                null,
                "created_at ASC, id ASC",
            ).use { it.toTaskList() }
            tasks.forEach { task ->
                val updated = task.copy(categoryId = to, updatedAt = updatedAt)
                val values = ContentValues(3).apply {
                    put("quest_line", to)
                    put("updated_at", updatedAt)
                }
                if (sqlite.update(TABLE_TASKS, values, "id = ?", arrayOf(task.id)) == 1) {
                    SQLiteLocalMutationRecorder.recordTask(
                        sqlite,
                        updated,
                        SyncOperationKind.UPSERT,
                    )
                    changed += task.id
                }
            }
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        if (changed.isNotEmpty()) invalidate()
        changed
    }

    private fun queryTasks(): List<TaskEntity> = database.readableDatabase.query(
        TABLE_TASKS,
        null,
        null,
        null,
        null,
        null,
        "created_at ASC, id ASC",
    ).use { it.toTaskList() }

    private fun queryCategories(): List<TaskCategory> = database.readableDatabase.query(
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

    private fun getById(sqlite: SQLiteDatabase, id: String): TaskEntity? =
        sqlite.query(
            TABLE_TASKS,
            null,
            "id = ?",
            arrayOf(id),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            if (cursor.moveToFirst()) cursor.toTaskEntity() else null
        }

    private fun invalidate() {
        invalidations.update { it + 1 }
    }

    private fun invalidateCategories() {
        categoryInvalidations.update { it + 1 }
    }

    internal fun invalidateFromSync() = invalidate()

    internal fun invalidateCategoriesFromSync() = invalidateCategories()

    private fun queryTrash(): List<TrashedTaskEntity> =
        database.readableDatabase.query(
            SQLiteTrashTable.TABLE,
            null,
            null,
            null,
            null,
            null,
            "deleted_at DESC, id ASC",
        ).use { cursor ->
            buildList {
                val deletedAtIndex = cursor.getColumnIndexOrThrow("deleted_at")
                while (cursor.moveToNext()) {
                    add(TrashedTaskEntity(cursor.toTaskEntity(), cursor.getLong(deletedAtIndex)))
                }
            }
        }

    private fun getTrashById(sqlite: SQLiteDatabase, id: String): TrashedTaskEntity? =
        sqlite.query(
            SQLiteTrashTable.TABLE,
            null,
            "id = ? COLLATE NOCASE",
            arrayOf(id),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            if (!cursor.moveToFirst()) {
                null
            } else {
                TrashedTaskEntity(
                    cursor.toTaskEntity(),
                    cursor.getLong(cursor.getColumnIndexOrThrow("deleted_at")),
                )
            }
        }

    private fun resolveCategoryId(sqlite: SQLiteDatabase, categoryId: String): String =
        sqlite.query(
            TABLE_CATEGORIES,
            arrayOf("id"),
            "id = ?",
            arrayOf(categoryId),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            if (cursor.moveToFirst()) categoryId else com.wootodo.domain.TaskCategories.INBOX_ID
        }

    private fun TaskEntity.toContentValues(): ContentValues = ContentValues(14).apply {
        put("id", id)
        put("series_id", seriesId)
        put("title", title)
        put("time_type", if (startDate == null && endDate == null) "someday" else "day")
        if (startDate == null) putNull("target_date") else put("target_date", startDate.toString())
        put("quest_line", categoryId)
        put("status", status.rawValue)
        put("recurrence", "once")
        put("sort_order", sortOrder)
        put("created_at", createdAt)
        put("updated_at", updatedAt)
        if (settledAt == null) putNull("settled_at") else put("settled_at", settledAt)
        if (reminderTime == null) putNull("reminder_time") else put("reminder_time", reminderTime.toString())
        if (endDate == null) putNull("deadline_date") else put("deadline_date", endDate.toString())
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
                if (isNull(index)) {
                    null
                } else if (effectiveStart == null) {
                    null
                } else {
                    LocalTime.parse(getString(index))
                }
            },
        )
    }

    private companion object {
        const val TABLE_TASKS = "tasks"
        const val TABLE_CATEGORIES = "task_categories"
    }
}
