package com.wootodo.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.domain.RecurringTaskSettler
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskRecurrence
import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
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
            categoryId = "main",
            startDate = LocalDate.of(2026, 7, 17),
            endDate = LocalDate.of(2026, 7, 20),
            status = TaskStatus.PENDING,
            sortOrder = 0,
            createdAt = 1_000,
            updatedAt = 1_000,
            settledAt = null,
        )
        store.insert(task)

        assertThrows(SQLiteException::class.java) {
            database.onDowngrade(database.writableDatabase, 10, 9)
        }

        assertEquals(task, store.getById(task.id))
    }

    @Test
    fun `升级会补齐WebDAV应用表并保留任务`() = runBlocking {
        val store = SQLiteTaskStore(database)
        val task = TaskEntity(
            id = "task-db-upgrade-13",
            seriesId = "task-db-upgrade-13",
            title = "升级保留",
            categoryId = "main",
            startDate = LocalDate.of(2026, 7, 17),
            endDate = LocalDate.of(2026, 7, 17),
            status = TaskStatus.PENDING,
            sortOrder = 0,
            createdAt = 1_000,
            updatedAt = 1_000,
            settledAt = null,
        )
        store.insert(task)
        val sqlite = database.writableDatabase
        sqlite.execSQL(
            "CREATE TABLE IF NOT EXISTS sync_webdav_applied_operations (" +
                "op_id TEXT NOT NULL PRIMARY KEY, applied_at INTEGER NOT NULL)",
        )

        database.onUpgrade(sqlite, 12, 13)

        val legacyTableExists = sqlite.rawQuery(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' " +
                "AND name = 'sync_webdav_applied_operations' LIMIT 1",
            null,
        ).use { it.moveToFirst() }
        // v0.2.20 恢复 WebDAV 同步后，升级会幂等重建该表而不是删除。
        assertTrue(legacyTableExists)
        assertEquals(task, store.getById(task.id))
    }

    @Test
    fun `每日重复结算会写入放弃记录并生成新任务`() = runBlocking {
        val store = SQLiteTaskStore(database)
        val task = TaskEntity(
            id = "task-daily-settlement",
            seriesId = "series-daily-settlement",
            title = "铲屎",
            categoryId = TaskCategories.INBOX_ID,
            startDate = LocalDate.of(2026, 11, 19),
            endDate = LocalDate.of(2026, 11, 19),
            status = TaskStatus.PENDING,
            sortOrder = 0,
            createdAt = 1_000,
            updatedAt = 1_000,
            settledAt = null,
            recurrence = TaskRecurrence.DAILY,
        )
        store.insert(task)
        val today = LocalDate.of(2026, 11, 20)
        val settlement = RecurringTaskSettler.settle(
            store.getAll(),
            today,
            5_000,
        )
        assertTrue(
            store.applyRecurringSettlement(
                settlement.updatedTasks,
                settlement.createdTasks,
            ),
        )

        val all = store.getAll()
        assertEquals(2, all.size)
        assertEquals(TaskStatus.PASS, all.first { it.id == task.id }.status)
        val next = all.first { it.id != task.id }
        assertEquals(today, next.startDate)
        assertEquals(TaskRecurrence.DAILY, next.recurrence)
        assertTrue(store.deletePending(next.id, 6_000))
        assertTrue(next.id.lowercase() in store.deletedTaskIds())
    }

    @Test
    fun `删除待办会保留本机恢复快照并可恢复`() = runBlocking {
        val store = SQLiteTaskStore(database)
        val task = TaskEntity(
            id = "task-trash-roundtrip",
            seriesId = "task-trash-roundtrip",
            title = "误删任务",
            categoryId = "main",
            startDate = LocalDate.of(2026, 7, 16),
            endDate = LocalDate.of(2026, 7, 17),
            status = TaskStatus.PENDING,
            sortOrder = 2,
            createdAt = 1_000,
            updatedAt = 1_000,
            settledAt = null,
        )
        store.insert(task)

        assertTrue(store.deletePending(task.id, 2_000))
        assertNull(store.getById(task.id))
        val trashed = store.getTrash().single()
        assertEquals(task.title, trashed.task.title)
        assertEquals(2_000, trashed.deletedAt)

        val restoredId = requireNotNull(
            store.restoreTrash(task.id, 3_000) { "task-restored-copy" },
        )
        assertEquals("task-restored-copy", restoredId)
        val restored = requireNotNull(store.getById(restoredId))
        assertEquals(task.title, restored.title)
        assertEquals(task.seriesId, restored.seriesId)
        assertEquals(TaskStatus.PENDING, restored.status)
        assertEquals(3_000, restored.updatedAt)
        assertTrue(store.getTrash().isEmpty())
    }

    @Test
    fun `版本三升级保留任务并创建待补传删除表`() = runBlocking {
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
                    'task-v3-upgrade', 'task-v3-upgrade', '升级保留任务',
                    'day', '2026-07-21', 'main', 'pending', 'once', 0, 3000, 3000, NULL
                )
                """.trimIndent(),
            )
            legacy.version = 3
        }

        database = TaskDatabase(context)
        database.writableDatabase
        val restored = requireNotNull(SQLiteTaskStore(database).getById("task-v3-upgrade"))
        assertEquals(LocalDate.of(2026, 7, 21), restored.startDate)
        assertEquals(LocalDate.of(2026, 7, 21), restored.endDate)
        assertEquals("main", restored.categoryId)

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
    fun `版本九升级会把旧周期任务转换为起止日期`() = runBlocking {
        database.close()
        context.deleteDatabase(DATABASE_NAME)
        context.openOrCreateDatabase(DATABASE_NAME, Context.MODE_PRIVATE, null).use { legacy ->
            legacy.execSQL(
                """
                CREATE TABLE tasks (
                    id TEXT NOT NULL PRIMARY KEY,
                    series_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    time_type TEXT NOT NULL CHECK(time_type IN ('day','week','month','someday')),
                    target_date TEXT,
                    quest_line TEXT NOT NULL CHECK(quest_line IN ('main','side','extra')),
                    status TEXT NOT NULL,
                    recurrence TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    settled_at INTEGER,
                    reminder_time TEXT,
                    deadline_date TEXT
                )
                """.trimIndent(),
            )
            val insert = """
                INSERT INTO tasks (
                    id, series_id, title, time_type, target_date, quest_line, status,
                    recurrence, sort_order, created_at, updated_at, settled_at,
                    reminder_time, deadline_date
                ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, 0, 1000, 1000, NULL, NULL, ?)
            """.trimIndent()
            listOf(
                arrayOf("task-day", "day", "2026-07-15", "main", "once", "2026-07-20"),
                arrayOf("task-week", "week", "2026-07-13", "side", "weekly", null),
                arrayOf("task-month", "month", "2026-06-01", "extra", "monthly", "2026-06-10"),
                arrayOf("task-someday", "someday", null, "main", "once", "2026-07-30"),
                arrayOf("task-repeat", "day", "2026-07-15", "side", "daily", null),
            ).forEach { values ->
                legacy.execSQL(
                    insert,
                    arrayOf(values[0], values[0], "旧任务", values[1], values[2], values[3], values[4], values[5]),
                )
            }
            legacy.version = 9
        }

        database = TaskDatabase(context)
        database.writableDatabase
        val store = SQLiteTaskStore(database)

        val day = requireNotNull(store.getById("task-day"))
        assertEquals(LocalDate.of(2026, 7, 15), day.startDate)
        assertEquals(LocalDate.of(2026, 7, 20), day.endDate)

        val week = requireNotNull(store.getById("task-week"))
        assertEquals(LocalDate.of(2026, 7, 13), week.startDate)
        assertEquals(LocalDate.of(2026, 7, 19), week.endDate)

        val month = requireNotNull(store.getById("task-month"))
        assertEquals(LocalDate.of(2026, 6, 1), month.startDate)
        assertEquals(LocalDate.of(2026, 6, 30), month.endDate)

        val someday = requireNotNull(store.getById("task-someday"))
        assertEquals(LocalDate.of(2026, 7, 30), someday.startDate)
        assertEquals(LocalDate.of(2026, 7, 30), someday.endDate)

        val repeat = requireNotNull(store.getById("task-repeat"))
        assertEquals(LocalDate.of(2026, 7, 15), repeat.startDate)
        assertEquals(LocalDate.of(2026, 7, 15), repeat.endDate)

        database.readableDatabase.rawQuery(
            "SELECT COUNT(*) FROM tasks WHERE recurrence != 'once'",
            null,
        ).use { cursor ->
            check(cursor.moveToFirst())
            assertEquals(0, cursor.getInt(0))
        }
        val categories = store.getCategories()
        assertEquals(
            setOf(TaskCategories.INBOX_ID, "main", "side", "extra"),
            categories.map { it.id }.toSet(),
        )
        assertEquals("主线", categories.first { it.id == "main" }.name)
    }

    @Test
    fun `版本十升级会清理未使用的默认类型并保留正在使用的类型`() = runBlocking {
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
                    status TEXT NOT NULL CHECK(status IN ('pending', 'completed', 'pass')),
                    recurrence TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    settled_at INTEGER,
                    reminder_time TEXT,
                    deadline_date TEXT
                )
                """.trimIndent(),
            )
            legacy.execSQL(
                """
                CREATE TABLE task_categories (
                    id TEXT NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """.trimIndent(),
            )
            legacy.execSQL(
                """
                INSERT INTO tasks (
                    id, series_id, title, time_type, target_date, quest_line,
                    status, recurrence, sort_order, created_at, updated_at,
                    settled_at, reminder_time, deadline_date
                ) VALUES (
                    'task-kept-main', 'task-kept-main', '保留主线', 'day',
                    '2026-07-15', 'main', 'pending', 'once', 0, 1000, 1000, NULL, NULL, NULL
                )
                """.trimIndent(),
            )
            listOf(
                arrayOf("inbox", "未分类", 0),
                arrayOf("main", "主线", 1),
                arrayOf("side", "支线", 2),
                arrayOf("extra", "外传", 3),
            ).forEach { values ->
                legacy.execSQL(
                    "INSERT INTO task_categories(id, name, sort_order, updated_at) VALUES (?, ?, ?, ?)",
                    values + arrayOf(1000),
                )
            }
            legacy.version = 10
        }

        database = TaskDatabase(context)
        database.writableDatabase
        val categories = SQLiteTaskStore(database).getCategories()

        assertEquals(listOf(TaskCategories.INBOX_ID, "main"), categories.map { it.id })
        assertEquals(listOf(0, 1), categories.map { it.order })
        assertEquals("主线", categories.first { it.id == "main" }.name)
    }

    @Test
    fun `版本十升级会移除全部未使用的默认类型`() = runBlocking {
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
                    status TEXT NOT NULL CHECK(status IN ('pending', 'completed', 'pass')),
                    recurrence TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    settled_at INTEGER,
                    reminder_time TEXT,
                    deadline_date TEXT
                )
                """.trimIndent(),
            )
            legacy.execSQL(
                """
                CREATE TABLE task_categories (
                    id TEXT NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """.trimIndent(),
            )
            listOf(
                arrayOf("inbox", "未分类", 0),
                arrayOf("main", "主线", 1),
                arrayOf("side", "支线", 2),
                arrayOf("extra", "外传", 3),
            ).forEach { values ->
                legacy.execSQL(
                    "INSERT INTO task_categories(id, name, sort_order, updated_at) VALUES (?, ?, ?, ?)",
                    values + arrayOf(1000),
                )
            }
            legacy.version = 10
        }

        database = TaskDatabase(context)
        database.writableDatabase
        val categories = SQLiteTaskStore(database).getCategories()

        assertEquals(listOf(TaskCategories.INBOX_ID), categories.map { it.id })
        assertEquals(0, categories.single().order)
    }

    private companion object {
        const val DATABASE_NAME = "woo-todo.db"
    }
}
