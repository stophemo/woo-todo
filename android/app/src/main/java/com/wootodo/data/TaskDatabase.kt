package com.wootodo.data

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.database.sqlite.SQLiteOpenHelper
import com.wootodo.domain.TaskCategories
import java.time.LocalDate
import java.time.YearMonth

class TaskDatabase(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DATABASE_NAME, null, DATABASE_VERSION) {

    override fun onCreate(database: SQLiteDatabase) {
        createSchema(database)
    }

    override fun onUpgrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 3) {
            migrateToVersionThree(database)
        }
        if (oldVersion < 4) {
            createDeferredDeletionSchema(database)
        }
        if (oldVersion < 5 && !columnExists(database, "tasks", "reminder_time")) {
            database.execSQL("ALTER TABLE tasks ADD COLUMN reminder_time TEXT")
        }
        if (oldVersion < 6) {
            createWebDavAppliedSchema(database)
        }
        if (oldVersion < 7) {
            createDisplayConfigurationSchema(database)
        }
        if (oldVersion < 8) {
            createDisplayConfigurationSchema(database)
            if (!columnExists(database, "display_configuration", "is_local_override")) {
                database.execSQL(
                    "ALTER TABLE display_configuration " +
                        "ADD COLUMN is_local_override INTEGER NOT NULL DEFAULT 1",
                )
            }
        }
        if (oldVersion < 9 && !columnExists(database, "tasks", "deadline_date")) {
            database.execSQL("ALTER TABLE tasks ADD COLUMN deadline_date TEXT")
        }
        if (oldVersion < 10) {
            migrateToVersionTen(database)
        }
        // 兼容曾经中断或裁剪过的旧升级：同步表均使用 IF NOT EXISTS，可安全幂等补齐。
        createSyncSchema(database)
        createCategorySchema(database)
    }

    override fun onDowngrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        throw SQLiteException(
            "拒绝将任务数据库从版本 $oldVersion 降级到 $newVersion，以免清空本地数据",
        )
    }

    private fun migrateToVersionThree(database: SQLiteDatabase) {
        if (!tableExists(database, "tasks")) {
            createSchema(database)
            return
        }
        database.execSQL("ALTER TABLE tasks RENAME TO tasks_legacy")
        database.execSQL("DROP INDEX IF EXISTS index_tasks_time_type_target_date")
        database.execSQL("DROP INDEX IF EXISTS index_tasks_series_id_occurrence_number")
        database.execSQL("DROP INDEX IF EXISTS index_tasks_status")
        createSchema(database)
        database.execSQL(
            """
            INSERT INTO tasks (
                id, series_id, title, time_type, target_date,
                quest_line, status, recurrence, sort_order, created_at, updated_at, settled_at
            )
            SELECT
                id,
                series_id,
                title,
                CASE time_type
                    WHEN 'DAY' THEN 'day'
                    WHEN 'WEEK' THEN 'week'
                    WHEN 'MONTH' THEN 'month'
                    WHEN 'LEISURE' THEN 'someday'
                    ELSE lower(time_type)
                END,
                target_date,
                CASE quest_line
                    WHEN 'MAIN' THEN 'main'
                    WHEN 'SIDE' THEN 'side'
                    WHEN 'EXTRA' THEN 'extra'
                    ELSE lower(quest_line)
                END,
                lower(status),
                CASE
                    WHEN upper(time_type) = 'DAY' AND upper(recurrence) = 'DAILY' THEN 'daily'
                    WHEN upper(time_type) = 'WEEK' AND upper(recurrence) = 'WEEKLY' THEN 'weekly'
                    WHEN upper(time_type) = 'MONTH' AND upper(recurrence) = 'MONTHLY' THEN 'monthly'
                    ELSE 'once'
                END,
                sort_order,
                created_at,
                updated_at,
                settled_at
            FROM tasks_legacy
            """.trimIndent(),
        )
        database.execSQL("DROP TABLE tasks_legacy")
        database.execSQL("DROP TABLE IF EXISTS room_master_table")
    }

    private fun createSchema(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS tasks (
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
        database.execSQL(
            "CREATE INDEX IF NOT EXISTS index_tasks_status_target_deadline " +
                "ON tasks(status, target_date, deadline_date)",
        )
        database.execSQL(
            "CREATE INDEX IF NOT EXISTS index_tasks_quest_line ON tasks(quest_line)",
        )
        database.execSQL(
            "CREATE INDEX IF NOT EXISTS index_tasks_series_id ON tasks(series_id)",
        )
        createCategorySchema(database)
        createSyncSchema(database)
    }

    private fun createCategorySchema(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS task_categories (
                id TEXT NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        val count = database.rawQuery("SELECT COUNT(*) FROM task_categories", null).use { cursor ->
            if (cursor.moveToFirst()) cursor.getInt(0) else 0
        }
        if (count == 0) {
            TaskCategories.defaults.forEach { category ->
                database.execSQL(
                    "INSERT INTO task_categories(id, name, sort_order, updated_at) VALUES (?, ?, ?, ?)",
                    arrayOf(category.id, category.name, category.order, System.currentTimeMillis()),
                )
            }
        }
    }

    private fun createSyncSchema(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_state (
                id INTEGER NOT NULL PRIMARY KEY CHECK(id = 1),
                cursor INTEGER NOT NULL DEFAULT 0 CHECK(cursor >= 0),
                lamport INTEGER NOT NULL DEFAULT 0 CHECK(lamport >= 0),
                vault_id TEXT NOT NULL DEFAULT '',
                device_id TEXT NOT NULL DEFAULT ''
            )
            """.trimIndent(),
        )
        database.execSQL(
            "INSERT OR IGNORE INTO sync_state(id, cursor, lamport, vault_id, device_id) " +
                "VALUES (1, 0, 0, '', '')",
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_outbox (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                op_id TEXT NOT NULL UNIQUE,
                entity_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                lamport INTEGER NOT NULL CHECK(lamport >= 1),
                payload_json TEXT NOT NULL,
                ciphertext TEXT,
                nonce TEXT,
                encrypted_vault_id TEXT,
                encrypted_device_id TEXT,
                created_at INTEGER NOT NULL,
                CHECK (
                    (ciphertext IS NULL AND nonce IS NULL AND encrypted_vault_id IS NULL AND encrypted_device_id IS NULL)
                    OR
                    (ciphertext IS NOT NULL AND nonce IS NOT NULL AND encrypted_vault_id IS NOT NULL AND encrypted_device_id IS NOT NULL)
                )
            )
            """.trimIndent(),
        )
        database.execSQL(
            "CREATE INDEX IF NOT EXISTS index_sync_outbox_sequence ON sync_outbox(sequence)",
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_entity_versions (
                entity_id TEXT NOT NULL PRIMARY KEY,
                lamport INTEGER NOT NULL CHECK(lamport >= 1),
                device_id TEXT NOT NULL,
                is_tombstone INTEGER NOT NULL DEFAULT 0 CHECK(is_tombstone IN (0, 1))
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_tombstones (
                entity_id TEXT NOT NULL PRIMARY KEY,
                deleted_at INTEGER NOT NULL CHECK(deleted_at >= 0),
                lamport INTEGER NOT NULL CHECK(lamport >= 1),
                device_id TEXT NOT NULL
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_applied_operations (
                op_id TEXT NOT NULL PRIMARY KEY,
                server_seq INTEGER NOT NULL UNIQUE CHECK(server_seq >= 1)
            )
            """.trimIndent(),
        )
        createWebDavAppliedSchema(database)
        createDeferredDeletionSchema(database)
        createDisplayConfigurationSchema(database)
    }

    private fun createWebDavAppliedSchema(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_webdav_applied_operations (
                op_id TEXT NOT NULL PRIMARY KEY,
                applied_at INTEGER NOT NULL CHECK(applied_at >= 0)
            )
            """.trimIndent(),
        )
    }

    private fun createDeferredDeletionSchema(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_deferred_deletions (
                entity_id TEXT NOT NULL PRIMARY KEY,
                deleted_at INTEGER NOT NULL CHECK(deleted_at >= 0)
            )
            """.trimIndent(),
        )
    }

    private fun createDisplayConfigurationSchema(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS display_configuration (
                id TEXT NOT NULL PRIMARY KEY CHECK(id = 'display.today.configuration'),
                header_template TEXT NOT NULL,
                subtitle_template TEXT NOT NULL,
                start_date TEXT NOT NULL,
                deadline_date TEXT NOT NULL,
                is_local_override INTEGER NOT NULL DEFAULT 0
                    CHECK(is_local_override IN (0, 1))
            )
            """.trimIndent(),
        )
    }

    private fun migrateToVersionTen(database: SQLiteDatabase) {
        if (tableExists(database, "tasks_v9")) {
            database.execSQL("DROP TABLE tasks_v9")
        }
        database.execSQL("ALTER TABLE tasks RENAME TO tasks_v9")
        database.execSQL("DROP INDEX IF EXISTS index_tasks_time_type_target_date")
        database.execSQL("DROP INDEX IF EXISTS index_tasks_status")
        database.execSQL("DROP INDEX IF EXISTS index_tasks_status_target_deadline")
        database.execSQL("DROP INDEX IF EXISTS index_tasks_quest_line")
        database.execSQL("DROP INDEX IF EXISTS index_tasks_series_id")
        createSchema(database)

        database.rawQuery("SELECT * FROM tasks_v9", null).use { cursor ->
            while (cursor.moveToNext()) {
                val old = cursor.toLegacyTask()
                val start = old.startDate
                val end = old.endDate
                database.execSQL(
                    """
                    INSERT INTO tasks (
                        id, series_id, title, time_type, target_date, quest_line,
                        status, recurrence, sort_order, created_at, updated_at,
                        settled_at, reminder_time, deadline_date
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'once', ?, ?, ?, ?, ?, ?)
                    """.trimIndent(),
                    arrayOf(
                        old.id,
                        old.seriesId,
                        old.title,
                        if (start == null && end == null) "someday" else "day",
                        start?.toString(),
                        old.categoryId,
                        old.status,
                        old.sortOrder,
                        old.createdAt,
                        old.updatedAt,
                        old.settledAt,
                        if (start == null && end == null) null else old.reminderTime,
                        end?.toString(),
                    ),
                )
            }
        }
        database.execSQL("DROP TABLE tasks_v9")
        createCategorySchema(database)
    }

    private fun Cursor.toLegacyTask(): LegacyTask {
        fun text(column: String): String? {
            val index = getColumnIndexOrThrow(column)
            return if (isNull(index)) null else getString(index)
        }

        fun long(column: String): Long? {
            val index = getColumnIndexOrThrow(column)
            return if (isNull(index)) null else getLong(index)
        }

        val target = text("target_date")?.let(LocalDate::parse)
        val deadline = text("deadline_date")?.let(LocalDate::parse)
        val timeType = text("time_type").orEmpty()
        val defaultEnd = when (timeType) {
            "day" -> target
            "week" -> target?.plusDays(6)
            "month" -> target?.let { date ->
                YearMonth.from(date).atEndOfMonth()
            }
            else -> null
        }
        val start: LocalDate?
        val end: LocalDate?
        if (target == null) {
            start = deadline
            end = deadline
        } else {
            start = target
            end = when {
                deadline == null -> defaultEnd ?: target
                defaultEnd == null -> maxOf(target, deadline)
                else -> maxOf(defaultEnd, deadline)
            }
        }
        return LegacyTask(
            id = requireNotNull(text("id")),
            seriesId = requireNotNull(text("series_id")),
            title = requireNotNull(text("title")),
            categoryId = requireNotNull(text("quest_line")),
            status = requireNotNull(text("status")),
            sortOrder = getInt(getColumnIndexOrThrow("sort_order")),
            createdAt = getLong(getColumnIndexOrThrow("created_at")),
            updatedAt = getLong(getColumnIndexOrThrow("updated_at")),
            settledAt = long("settled_at"),
            reminderTime = text("reminder_time"),
            startDate = start,
            endDate = end,
        )
    }

    private data class LegacyTask(
        val id: String,
        val seriesId: String,
        val title: String,
        val categoryId: String,
        val status: String,
        val sortOrder: Int,
        val createdAt: Long,
        val updatedAt: Long,
        val settledAt: Long?,
        val reminderTime: String?,
        val startDate: LocalDate?,
        val endDate: LocalDate?,
    )

    private fun tableExists(database: SQLiteDatabase, tableName: String): Boolean =
        database.rawQuery(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            arrayOf(tableName),
        ).use { it.moveToFirst() }

    private fun columnExists(database: SQLiteDatabase, tableName: String, columnName: String): Boolean =
        database.rawQuery("PRAGMA table_info($tableName)", null).use { cursor ->
            val nameIndex = cursor.getColumnIndexOrThrow("name")
            generateSequence { if (cursor.moveToNext()) cursor.getString(nameIndex) else null }
                .any { it == columnName }
        }

    private companion object {
        const val DATABASE_NAME = "woo-todo.db"
        const val DATABASE_VERSION = 10
    }
}
