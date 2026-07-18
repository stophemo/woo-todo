package com.wootodo.data

import android.content.Context
import android.database.sqlite.SQLiteException
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.LocalDate
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
        )
        store.insert(task)

        assertThrows(SQLiteException::class.java) {
            database.onDowngrade(database.writableDatabase, 4, 3)
        }

        assertEquals(task, store.getById(task.id))
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

    private companion object {
        const val DATABASE_NAME = "woo-todo.db"
    }
}
