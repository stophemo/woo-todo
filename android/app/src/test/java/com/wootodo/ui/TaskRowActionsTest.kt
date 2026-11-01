package com.wootodo.ui

import com.wootodo.R
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.Task
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.LocalDate
import java.time.LocalTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TaskRowActionsTest {
    @Test
    fun `待办任务提供完成 Pass 编辑与删除`() {
        assertEquals(
            listOf(
                TaskRowAction.COMPLETE,
                TaskRowAction.PASS,
                TaskRowAction.EDIT,
                TaskRowAction.DELETE,
            ),
            taskRowActions(TaskStatus.PENDING),
        )
    }

    @Test
    fun `已完成任务只能撤销完成或查看详情`() {
        assertEquals(
            listOf(TaskRowAction.REOPEN, TaskRowAction.EDIT),
            taskRowActions(TaskStatus.COMPLETED),
        )
    }

    @Test
    fun `Pass任务只能查看详情`() {
        assertEquals(listOf(TaskRowAction.EDIT), taskRowActions(TaskStatus.PASS))
    }

    @Test
    fun `右滑只在可逆状态生效`() {
        assertEquals(TaskRowAction.COMPLETE, swipeRightAction(TaskStatus.PENDING))
        assertEquals(TaskRowAction.REOPEN, swipeRightAction(TaskStatus.COMPLETED))
        assertNull(swipeRightAction(TaskStatus.PASS))
    }

    @Test
    fun `左滑删除只对待办任务生效`() {
        assertEquals(TaskRowAction.DELETE, swipeLeftAction(TaskStatus.PENDING))
        assertNull(swipeLeftAction(TaskStatus.COMPLETED))
        assertNull(swipeLeftAction(TaskStatus.PASS))
    }

    @Test
    fun `已结算任务的编辑入口改为查看详情`() {
        assertEquals(R.string.task_menu_edit, TaskRowAction.EDIT.labelRes(TaskStatus.PENDING))
        assertEquals(R.string.task_menu_view, TaskRowAction.EDIT.labelRes(TaskStatus.COMPLETED))
        assertEquals(R.string.task_menu_view, TaskRowAction.EDIT.labelRes(TaskStatus.PASS))
    }

    @Test
    fun `已结算任务为只读`() {
        assertEquals(false, isReadOnly(TaskStatus.PENDING))
        assertEquals(true, isReadOnly(TaskStatus.COMPLETED))
        assertEquals(true, isReadOnly(TaskStatus.PASS))
    }

    @Test
    fun `撤销删除保留原任务全部可编辑字段`() {
        val task = Task(
            id = "task-1",
            seriesId = "series-1",
            title = "写周报",
            timeType = TaskTimeType.WEEK,
            targetDate = LocalDate.of(2026, 7, 13),
            questLine = QuestLine.SIDE,
            status = TaskStatus.PENDING,
            recurrence = Recurrence.WEEKLY,
            sortOrder = 4,
            createdAt = 1_000,
            updatedAt = 2_000,
            settledAt = null,
            reminderTime = LocalTime.of(9, 30),
            deadlineDate = LocalDate.of(2026, 7, 19),
        )

        val draft = task.toRestoreDraft()

        assertEquals(task.title, draft.title)
        assertEquals(task.timeType, draft.timeType)
        assertEquals(task.targetDate, draft.targetDate)
        assertEquals(task.questLine, draft.questLine)
        assertEquals(task.recurrence, draft.recurrence)
        assertEquals(task.sortOrder, draft.sortOrder)
        assertEquals(task.reminderTime, draft.reminderTime)
        assertEquals(task.deadlineDate, draft.deadlineDate)
    }
}
