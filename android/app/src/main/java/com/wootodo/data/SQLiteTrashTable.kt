package com.wootodo.data

import android.database.sqlite.SQLiteDatabase
import com.wootodo.domain.TaskStatus

/**
 * 本机恢复快照表。删除仍按现有 tombstone 同步；恢复时以新任务重新入队，
 * 这样旧版本客户端不需要理解新的任务状态。
 */
object SQLiteTrashTable {
    const val TABLE = "trash_tasks"

    fun insertFromTask(database: SQLiteDatabase, taskId: String, deletedAt: Long) {
        database.execSQL(
            """
            INSERT OR IGNORE INTO $TABLE (
                id, series_id, title, time_type, target_date, quest_line,
                status, recurrence, sort_order, created_at, updated_at,
                settled_at, reminder_time, deadline_date, deleted_at
            )
            SELECT id, series_id, title, time_type, target_date, quest_line,
                   status, recurrence, sort_order, created_at, updated_at,
                   settled_at, reminder_time, deadline_date, ?
            FROM tasks WHERE id = ? COLLATE NOCASE AND status = ?
            """.trimIndent(),
            arrayOf(deletedAt, taskId, TaskStatus.PENDING.rawValue),
        )
    }

}
