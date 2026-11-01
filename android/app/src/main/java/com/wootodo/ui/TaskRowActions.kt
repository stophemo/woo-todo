package com.wootodo.ui

import com.wootodo.R
import com.wootodo.domain.Task
import com.wootodo.domain.TaskDraft
import com.wootodo.domain.TaskStatus

/** 任务行支持的操作，顺序即菜单展示顺序。 */
internal enum class TaskRowAction {
    COMPLETE,
    REOPEN,
    PASS,
    EDIT,
    DELETE,
}

internal fun taskRowActions(status: TaskStatus): List<TaskRowAction> = when (status) {
    TaskStatus.PENDING -> listOf(
        TaskRowAction.COMPLETE,
        TaskRowAction.PASS,
        TaskRowAction.EDIT,
        TaskRowAction.DELETE,
    )
    TaskStatus.COMPLETED -> listOf(TaskRowAction.REOPEN, TaskRowAction.EDIT)
    TaskStatus.PASS -> listOf(TaskRowAction.EDIT)
}

/** 右滑：待办标记完成，已完成撤销完成；Pass 不可逆，不提供滑动。 */
internal fun swipeRightAction(status: TaskStatus): TaskRowAction? = when (status) {
    TaskStatus.PENDING -> TaskRowAction.COMPLETE
    TaskStatus.COMPLETED -> TaskRowAction.REOPEN
    TaskStatus.PASS -> null
}

/** 左滑：只有待办任务可以删除，已结算任务仍可通过历史入口清理。 */
internal fun swipeLeftAction(status: TaskStatus): TaskRowAction? =
    if (status == TaskStatus.PENDING) TaskRowAction.DELETE else null

/** 已结算任务只能查看，避免用户误以为仍可修改。 */
internal fun isReadOnly(status: TaskStatus): Boolean = status != TaskStatus.PENDING

internal fun TaskRowAction.labelRes(status: TaskStatus): Int = when (this) {
    TaskRowAction.COMPLETE -> R.string.task_menu_complete
    TaskRowAction.REOPEN -> R.string.task_menu_reopen
    TaskRowAction.PASS -> R.string.task_menu_pass
    TaskRowAction.EDIT -> if (isReadOnly(status)) {
        R.string.task_menu_view
    } else {
        R.string.task_menu_edit
    }
    TaskRowAction.DELETE -> R.string.task_menu_delete
}

/** 撤销删除时用原任务字段重建，沿用原排序位置。 */
internal fun Task.toRestoreDraft(): TaskDraft = TaskDraft(
    title = title,
    timeType = timeType,
    targetDate = targetDate,
    questLine = questLine,
    recurrence = recurrence,
    sortOrder = sortOrder,
    reminderTime = reminderTime,
    deadlineDate = deadlineDate,
)
