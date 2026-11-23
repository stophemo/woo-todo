package com.wootodo.data

import com.wootodo.domain.Task
import com.wootodo.domain.TaskDraft
import com.wootodo.domain.TaskRecurrence
import com.wootodo.domain.TaskStatus

/**
 * v0.2.18 之前任务必须同时填写开始和结束日期，旧客户端/Agent 常把“某天要做的事”
 * 写成前一天到当天的一天区间。升级后统一折算成“任务日期 = 区间最后一天”，
 * 只执行一次；之后用户主动创建的两天任务不会再次被折叠。
 */
object LegacyTaskDateMigration {
    const val PREFERENCES = "woo_todo_migrations"
    const val KEY = "legacy_task_dates_v1"

    /** v0.2.18 发布时间；此前创建的任务才使用旧的“必须两段日期”语义。 */
    const val LEGACY_CUTOFF_MILLIS = 1_795_355_665_000L

    fun plan(tasks: List<Task>): List<Task> = tasks.mapNotNull { task ->
        if (task.status != TaskStatus.PENDING ||
            task.recurrence != TaskRecurrence.ONCE ||
            task.createdAt >= LEGACY_CUTOFF_MILLIS
        ) {
            return@mapNotNull null
        }
        val start = task.startDate ?: return@mapNotNull null
        val end = task.endDate ?: return@mapNotNull null
        if (end != start.plusDays(1)) return@mapNotNull null
        task.copy(startDate = end, endDate = end)
    }

    fun draft(task: Task): TaskDraft = TaskDraft(
        title = task.title,
        categoryId = task.categoryId,
        startDate = task.startDate,
        endDate = null,
        reminderTime = task.reminderTime,
        sortOrder = task.sortOrder,
        recurrence = task.recurrence,
    )
}
