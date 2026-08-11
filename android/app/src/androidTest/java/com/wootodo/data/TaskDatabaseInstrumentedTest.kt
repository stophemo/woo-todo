package com.wootodo.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.LocalDate
import java.time.LocalTime
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TaskDatabaseInstrumentedTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    private lateinit var database: TaskDatabase

    @Before
    fun setUp() {
        context.deleteDatabase(DATABASE_NAME)
        database = TaskDatabase(context)
        database.writableDatabase
    }

    @After
    fun tearDown() {
        if (::database.isInitialized) database.close()
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun `拒绝数据库降级且保留已有任务`() = runBlocking {
        val store = SQLiteTaskStore(database)
        val task = TaskEntity(
            id = "task-downgrade-guard",
            seriesId = "task-downgrade-guard",
            title = "不可清空",
            timeType = TaskTimeType.DAY,
            targetDate = LocalDate.of(2026, 7, 17),
            questLine = QuestLine.MAIN,
            status = TaskStatus.PENDING,
            recurrence = Recurrence.ONCE,
            sortOrder = 0,
            createdAt = 1_000,
            updatedAt = 1_000,
            settledAt = null,
            deadlineDate = LocalDate.of(2026, 7, 20),
        )
        store.insert(task)

        assertThrows(SQLiteException::class.java) {
            database.onDowngrade(database.writableDatabase, 4, 3)
        }

        assertEquals(task, store.getById(task.id))
    }

    @Test
    fun `逾期一次性任务完成当天仍在今日查询且次日退出`() = runBlocking {
        val completedDate = LocalDate.of(2026, 7, 18)
        val settledAt = completedDate.atTime(10, 30)
            .atZone(TaskDateRules.zoneId)
            .toInstant()
            .toEpochMilli()
        val task = TaskEntity(
            id = "completed-overdue-once",
            seriesId = "completed-overdue-once",
            title = "昨日待办",
            timeType = TaskTimeType.DAY,
            targetDate = completedDate.minusDays(1),
            questLine = QuestLine.MAIN,
            status = TaskStatus.COMPLETED,
            recurrence = Recurrence.ONCE,
            sortOrder = 0,
            createdAt = settledAt - 86_400_000,
            updatedAt = settledAt,
            settledAt = settledAt,
        )
        val store = SQLiteTaskStore(database)
        store.insert(task)

        assertEquals(
            listOf(task.id),
            store.observeForPeriod(
                TaskTimeType.DAY,
                completedDate,
                includeOverdueOnce = true,
            ).first().map { it.id },
        )
        assertEquals(listOf(task.id), store.getForDay(completedDate).map { it.id })

        val nextDate = completedDate.plusDays(1)
        assertEquals(
            emptyList<String>(),
            store.observeForPeriod(
                TaskTimeType.DAY,
                nextDate,
                includeOverdueOnce = true,
            ).first().map { it.id },
        )
        assertEquals(emptyList<String>(), store.getForDay(nextDate).map { it.id })
    }

    @Test
    fun `版本三升级会保留任务并创建待补传删除表`() = runBlocking {
        val task = TaskEntity(
            id = "task-v3-upgrade-guard",
            seriesId = "task-v3-upgrade-guard",
            title = "升级不可清空",
            timeType = TaskTimeType.DAY,
            targetDate = LocalDate.of(2026, 7, 18),
            questLine = QuestLine.MAIN,
            status = TaskStatus.PENDING,
            recurrence = Recurrence.ONCE,
            sortOrder = 0,
            createdAt = 2_000,
            updatedAt = 2_000,
            settledAt = null,
        )
        SQLiteTaskStore(database).insert(task)
        database.writableDatabase.execSQL("DROP TABLE sync_deferred_deletions")
        database.writableDatabase.execSQL("PRAGMA user_version = 3")
        database.close()

        database = TaskDatabase(context)
        database.writableDatabase

        assertEquals(task, SQLiteTaskStore(database).getById(task.id))
        assertEquals(
            1,
            database.readableDatabase.rawQuery(
                "SELECT COUNT(*) FROM sqlite_master " +
                    "WHERE type = 'table' AND name = 'sync_deferred_deletions'",
                null,
            ).use { cursor ->
                check(cursor.moveToFirst())
                cursor.getInt(0)
            },
        )
    }

    @Test
    fun `版本四升级会保留任务并新增提醒时间`() = runBlocking {
        database.close()
        context.deleteDatabase(DATABASE_NAME)
        context.openOrCreateDatabase(DATABASE_NAME, Context.MODE_PRIVATE, null).use { legacy ->
            legacy.execSQL(
                """
                CREATE TABLE tasks (
                    id TEXT NOT NULL PRIMARY KEY,
                    series_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    time_type TEXT NOT NULL,
                    target_date TEXT,
                    quest_line TEXT NOT NULL,
                    status TEXT NOT NULL,
                    recurrence TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    settled_at INTEGER
                )
                """.trimIndent(),
            )
            legacy.execSQL(
                """
                INSERT INTO tasks VALUES (
                    'task-v4-upgrade', 'task-v4-upgrade', '升级后提醒', 'day', '2026-07-21',
                    'main', 'pending', 'once', 0, 3000, 3000, NULL
                )
                """.trimIndent(),
            )
            legacy.version = 4
        }

        database = TaskDatabase(context)
        database.writableDatabase
        val store = SQLiteTaskStore(database)
        val restored = requireNotNull(store.getById("task-v4-upgrade"))
        assertEquals(null, restored.reminderTime)

        val withReminder = restored.copy(reminderTime = LocalTime.of(8, 30))
        assertEquals(true, store.update(withReminder))
        assertEquals(LocalTime.of(8, 30), store.getById(withReminder.id)?.reminderTime)
    }

    @Test
    fun `版本五升级会保留任务并创建WebDAV幂等记录表`() = runBlocking {
        database.close()
        context.deleteDatabase(DATABASE_NAME)
        context.openOrCreateDatabase(DATABASE_NAME, Context.MODE_PRIVATE, null).use { legacy ->
            createVersionFiveOrSixTasksTable(legacy, "task-v5-upgrade")
            legacy.version = 5
        }

        database = TaskDatabase(context)
        val sqlite = database.writableDatabase
        val restored = requireNotNull(SQLiteTaskStore(database).getById("task-v5-upgrade"))
        assertEquals(LocalTime.of(8, 30), restored.reminderTime)
        assertEquals(null, restored.deadlineDate)
        assertEquals(
            1,
            sqlite.rawQuery(
                "SELECT COUNT(*) FROM sqlite_master " +
                    "WHERE type = 'table' AND name = 'sync_webdav_applied_operations'",
                null,
            ).use { cursor ->
                check(cursor.moveToFirst())
                cursor.getInt(0)
            },
        )
        sqlite.execSQL(
            "INSERT INTO sync_webdav_applied_operations(op_id, applied_at) VALUES (?, ?)",
            arrayOf("operation-v5-upgrade", 1_000),
        )
        assertEquals(
            1,
            sqlite.rawQuery(
                "SELECT COUNT(*) FROM sync_webdav_applied_operations WHERE op_id = ?",
                arrayOf("operation-v5-upgrade"),
            ).use { cursor ->
                check(cursor.moveToFirst())
                cursor.getInt(0)
            },
        )
    }

    @Test
    fun `版本六升级会保留任务并创建显示配置表且不删除旧表`() = runBlocking {
        database.close()
        context.deleteDatabase(DATABASE_NAME)
        context.openOrCreateDatabase(DATABASE_NAME, Context.MODE_PRIVATE, null).use { legacy ->
            createVersionFiveOrSixTasksTable(legacy, "task-v6-upgrade")
            legacy.execSQL("CREATE TABLE migration_marker(id INTEGER PRIMARY KEY)")
            legacy.execSQL("INSERT INTO migration_marker(id) VALUES (1)")
            legacy.version = 6
        }

        database = TaskDatabase(context)
        val sqlite = database.writableDatabase
        val restored = requireNotNull(SQLiteTaskStore(database).getById("task-v6-upgrade"))
        assertEquals(LocalTime.of(8, 30), restored.reminderTime)
        assertEquals(null, restored.deadlineDate)
        assertEquals(
            1,
            sqlite.rawQuery(
                "SELECT COUNT(*) FROM sqlite_master " +
                    "WHERE type = 'table' AND name = 'display_configuration'",
                null,
            ).use { cursor ->
                check(cursor.moveToFirst())
                cursor.getInt(0)
            },
        )
        assertEquals(
            1,
            sqlite.rawQuery("SELECT COUNT(*) FROM migration_marker", null).use { cursor ->
                check(cursor.moveToFirst())
                cursor.getInt(0)
            },
        )
    }

    @Test
    fun `版本八升级会保留任务并新增截止日期`() = runBlocking {
        database.close()
        context.deleteDatabase(DATABASE_NAME)
        context.openOrCreateDatabase(DATABASE_NAME, Context.MODE_PRIVATE, null).use { legacy ->
            legacy.execSQL(
                """
                CREATE TABLE tasks (
                    id TEXT NOT NULL PRIMARY KEY,
                    series_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    time_type TEXT NOT NULL,
                    target_date TEXT,
                    quest_line TEXT NOT NULL,
                    status TEXT NOT NULL,
                    recurrence TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    settled_at INTEGER,
                    reminder_time TEXT
                )
                """.trimIndent(),
            )
            legacy.execSQL(
                """
                INSERT INTO tasks VALUES (
                    'task-v8-upgrade', 'task-v8-upgrade', '升级后截止日期',
                    'day', '2026-07-21', 'main', 'pending', 'once', 0,
                    4000, 4000, NULL, '08:30'
                )
                """.trimIndent(),
            )
            legacy.version = 8
        }

        database = TaskDatabase(context)
        database.writableDatabase
        val store = SQLiteTaskStore(database)
        val restored = requireNotNull(store.getById("task-v8-upgrade"))
        assertEquals(null, restored.deadlineDate)

        val deadline = LocalDate.of(2026, 7, 30)
        assertEquals(true, store.update(restored.copy(deadlineDate = deadline)))
        assertEquals(deadline, store.getById(restored.id)?.deadlineDate)
    }

    private fun createVersionFiveOrSixTasksTable(
        database: SQLiteDatabase,
        taskId: String,
    ) {
        database.execSQL(
            """
            CREATE TABLE tasks (
                id TEXT NOT NULL PRIMARY KEY,
                series_id TEXT NOT NULL,
                title TEXT NOT NULL,
                time_type TEXT NOT NULL CHECK(time_type IN ('day', 'week', 'month', 'someday')),
                target_date TEXT,
                quest_line TEXT NOT NULL CHECK(quest_line IN ('main', 'side', 'extra')),
                status TEXT NOT NULL CHECK(status IN ('pending', 'completed', 'pass')),
                recurrence TEXT NOT NULL CHECK(recurrence IN ('once', 'daily', 'weekly', 'monthly')),
                sort_order INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                settled_at INTEGER,
                reminder_time TEXT
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            INSERT INTO tasks (
                id, series_id, title, time_type, target_date, quest_line, status,
                recurrence, sort_order, created_at, updated_at, settled_at, reminder_time
            ) VALUES (?, ?, '升级保留任务', 'day', '2026-07-21', 'main', 'pending',
                'once', 0, 3500, 3500, NULL, '08:30')
            """.trimIndent(),
            arrayOf(taskId, taskId),
        )
    }

    private companion object {
        const val DATABASE_NAME = "woo-todo.db"
    }
}
