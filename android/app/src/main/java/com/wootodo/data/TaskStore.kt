package com.wootodo.data

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import com.wootodo.sync.SQLiteLocalMutationRecorder
import com.wootodo.sync.SyncOperationKind
import java.time.LocalDate
import java.time.LocalTime
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext

interface TaskStore {
    fun observeAll(): Flow<List<TaskEntity>>

    suspend fun getAll(): List<TaskEntity> = observeAll().first()

    fun observeForPeriod(
        timeType: TaskTimeType,
        targetDate: LocalDate,
        includeOverdueOnce: Boolean = false,
    ): Flow<List<TaskEntity>>

    fun observeLeisure(): Flow<List<TaskEntity>>

    suspend fun getForDay(date: LocalDate): List<TaskEntity>

    suspend fun getExpiredPending(
        dayCutoff: LocalDate,
        weekCutoff: LocalDate,
        monthCutoff: LocalDate,
    ): List<TaskEntity>

    suspend fun countForDay(date: LocalDate): Int

    suspend fun getById(id: String): TaskEntity?

    suspend fun maximumSortOrder(
        timeType: TaskTimeType,
        targetDate: LocalDate?,
        questLine: QuestLine,
    ): Int?

    suspend fun insert(task: TaskEntity)

    suspend fun update(task: TaskEntity): Boolean

    suspend fun deletePending(id: String, deletedAt: Long): Boolean

    suspend fun settleAndSchedule(
        id: String,
        status: TaskStatus,
        settledAt: Long,
        nextTask: (TaskEntity) -> TaskEntity?,
    ): Boolean

    suspend fun reopenCompleted(id: String, updatedAt: Long): Boolean

    suspend fun reorder(idsInOrder: List<String>, updatedAt: Long): Boolean
}

class SQLiteTaskStore(private val database: TaskDatabase) : TaskStore {
    private val invalidations = MutableStateFlow(0L)

    override fun observeAll(): Flow<List<TaskEntity>> = invalidations
        .map { queryTasks(selection = "1", selectionArgs = emptyArray()) }
        .flowOn(Dispatchers.IO)
        .distinctUntilChanged()

    override suspend fun getAll(): List<TaskEntity> = withContext(Dispatchers.IO) {
        queryTasks(selection = "1", selectionArgs = emptyArray())
    }

    override fun observeForPeriod(
        timeType: TaskTimeType,
        targetDate: LocalDate,
        includeOverdueOnce: Boolean,
    ): Flow<List<TaskEntity>> = invalidations
        .map {
            val selection = if (includeOverdueOnce) {
                "time_type = ? AND (target_date = ? OR " +
                    "(target_date < ? AND recurrence = ? AND " +
                    "(status = ? OR (status = ? AND settled_at >= ? AND settled_at < ?))))"
            } else {
                "time_type = ? AND target_date = ?"
            }
            val arguments = buildList {
                add(timeType.rawValue)
                add(targetDate.toString())
                if (includeOverdueOnce) {
                    val (periodStart, periodEnd) = settlementWindow(timeType, targetDate)
                    add(targetDate.toString())
                    add(Recurrence.ONCE.rawValue)
                    add(TaskStatus.PENDING.rawValue)
                    add(TaskStatus.COMPLETED.rawValue)
                    add(periodStart.toString())
                    add(periodEnd.toString())
                }
            }.toTypedArray()
            queryTasks(selection = selection, selectionArgs = arguments)
        }
        .flowOn(Dispatchers.IO)
        .distinctUntilChanged()

    override fun observeLeisure(): Flow<List<TaskEntity>> = invalidations
        .map {
            queryTasks(
                selection = "time_type = ? AND target_date IS NULL",
                selectionArgs = arrayOf(TaskTimeType.LEISURE.rawValue),
            )
        }
        .flowOn(Dispatchers.IO)
        .distinctUntilChanged()

    override suspend fun getForDay(date: LocalDate): List<TaskEntity> =
        withContext(Dispatchers.IO) {
            val (periodStart, periodEnd) = settlementWindow(TaskTimeType.DAY, date)
            queryTasks(
                selection = "time_type = ? AND ((target_date = ? AND status IN (?, ?)) OR " +
                    "(target_date < ? AND recurrence = ? AND " +
                    "(status = ? OR (status = ? AND settled_at >= ? AND settled_at < ?))))",
                selectionArgs = arrayOf(
                    TaskTimeType.DAY.rawValue,
                    date.toString(),
                    TaskStatus.PENDING.rawValue,
                    TaskStatus.COMPLETED.rawValue,
                    date.toString(),
                    Recurrence.ONCE.rawValue,
                    TaskStatus.PENDING.rawValue,
                    TaskStatus.COMPLETED.rawValue,
                    periodStart.toString(),
                    periodEnd.toString(),
                ),
            )
        }

    override suspend fun getExpiredPending(
        dayCutoff: LocalDate,
        weekCutoff: LocalDate,
        monthCutoff: LocalDate,
    ): List<TaskEntity> = withContext(Dispatchers.IO) {
        val sql =
            """
            SELECT * FROM tasks
            WHERE status = ? AND recurrence != ? AND (
                (time_type = ? AND target_date < ?) OR
                (time_type = ? AND target_date < ?) OR
                (time_type = ? AND target_date < ?)
            )
            ORDER BY target_date ASC, created_at ASC
            """.trimIndent()
        database.readableDatabase.rawQuery(
            sql,
            arrayOf(
                TaskStatus.PENDING.rawValue,
                Recurrence.ONCE.rawValue,
                TaskTimeType.DAY.rawValue,
                dayCutoff.toString(),
                TaskTimeType.WEEK.rawValue,
                weekCutoff.toString(),
                TaskTimeType.MONTH.rawValue,
                monthCutoff.toString(),
            ),
        ).use { it.toTaskList() }
    }

    override suspend fun countForDay(date: LocalDate): Int = withContext(Dispatchers.IO) {
        database.readableDatabase.rawQuery(
            "SELECT COUNT(*) FROM tasks WHERE time_type = ? AND target_date = ?",
            arrayOf(TaskTimeType.DAY.rawValue, date.toString()),
        ).use { cursor ->
            if (cursor.moveToFirst()) cursor.getInt(0) else 0
        }
    }

    override suspend fun getById(id: String): TaskEntity? = withContext(Dispatchers.IO) {
        getById(database.readableDatabase, id)
    }

    override suspend fun maximumSortOrder(
        timeType: TaskTimeType,
        targetDate: LocalDate?,
        questLine: QuestLine,
    ): Int? = withContext(Dispatchers.IO) {
        val targetClause = if (targetDate == null) "target_date IS NULL" else "target_date = ?"
        val arguments = buildList {
            add(timeType.rawValue)
            add(questLine.rawValue)
            if (targetDate != null) add(targetDate.toString())
        }.toTypedArray()
        database.readableDatabase.rawQuery(
            "SELECT MAX(sort_order) FROM tasks " +
                "WHERE time_type = ? AND quest_line = ? AND $targetClause",
            arguments,
        ).use { cursor ->
            if (!cursor.moveToFirst() || cursor.isNull(0)) null else cursor.getInt(0)
        }
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

    override suspend fun settleAndSchedule(
        id: String,
        status: TaskStatus,
        settledAt: Long,
        nextTask: (TaskEntity) -> TaskEntity?,
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
                    val settled = current.copy(
                        status = status,
                        settledAt = settledAt,
                        updatedAt = settledAt,
                    )
                    SQLiteLocalMutationRecorder.recordTask(
                        sqlite,
                        settled,
                        if (status == TaskStatus.COMPLETED) {
                            SyncOperationKind.COMPLETE
                        } else {
                            SyncOperationKind.PASS
                        },
                    )
                    nextTask(current)?.takeUnless { next ->
                        SQLiteLocalMutationRecorder.isDeletionBarrier(sqlite, next.id)
                    }?.let { next ->
                        val inserted = sqlite.insertWithOnConflict(
                            TABLE_TASKS,
                            null,
                            next.toContentValues(),
                            SQLiteDatabase.CONFLICT_IGNORE,
                        )
                        if (inserted != -1L) {
                            SQLiteLocalMutationRecorder.recordTask(
                                sqlite,
                                next,
                                SyncOperationKind.UPSERT,
                            )
                        }
                    }
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

    override suspend fun reorder(
        idsInOrder: List<String>,
        updatedAt: Long,
    ): Boolean = withContext(Dispatchers.IO) {
        if (idsInOrder.isEmpty()) return@withContext false
        val sqlite = database.writableDatabase
        var changed = false
        sqlite.beginTransaction()
        try {
            idsInOrder.forEachIndexed { index, id ->
                val values = ContentValues(2).apply {
                    put("sort_order", index)
                    put("updated_at", updatedAt)
                }
                val rowChanged = sqlite.update(
                    TABLE_TASKS,
                    values,
                    "id = ? AND status = ?",
                    arrayOf(id, TaskStatus.PENDING.rawValue),
                ) == 1
                if (rowChanged) {
                    changed = true
                    getById(sqlite, id)?.let { reordered ->
                        SQLiteLocalMutationRecorder.recordTask(
                            sqlite,
                            reordered,
                            SyncOperationKind.REORDER,
                        )
                    }
                }
            }
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        if (changed) invalidate()
        changed
    }

    private fun queryTasks(
        selection: String,
        selectionArgs: Array<String>,
    ): List<TaskEntity> = database.readableDatabase.query(
        TABLE_TASKS,
        null,
        selection,
        selectionArgs,
        null,
        null,
        null,
    ).use { it.toTaskList() }

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

    internal fun invalidateFromSync() = invalidate()

    private fun TaskEntity.toContentValues(): ContentValues = ContentValues(15).apply {
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
        if (reminderTime == null) putNull("reminder_time") else put("reminder_time", reminderTime.toString())
        if (deadlineDate == null) putNull("deadline_date") else put("deadline_date", deadlineDate.toString())
    }

    private fun Cursor.toTaskList(): List<TaskEntity> = buildList {
        while (moveToNext()) add(toTaskEntity())
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
        reminderTime = getColumnIndexOrThrow("reminder_time").let { index ->
            if (isNull(index)) null else LocalTime.parse(getString(index))
        },
        deadlineDate = getColumnIndexOrThrow("deadline_date").let { index ->
            if (isNull(index)) null else LocalDate.parse(getString(index))
        },
    )

    private companion object {
        const val TABLE_TASKS = "tasks"

        fun settlementWindow(timeType: TaskTimeType, start: LocalDate): Pair<Long, Long> {
            val end = when (timeType) {
                TaskTimeType.DAY -> start.plusDays(1)
                TaskTimeType.WEEK -> start.plusWeeks(1)
                TaskTimeType.MONTH -> start.plusMonths(1)
                TaskTimeType.LEISURE -> error("闲时任务没有结算周期")
            }
            return start.atStartOfDay(TaskDateRules.zoneId).toInstant().toEpochMilli() to
                end.atStartOfDay(TaskDateRules.zoneId).toInstant().toEpochMilli()
        }
    }
}
