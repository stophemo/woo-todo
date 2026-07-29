package com.wootodo.ui

import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TaskDeadlineIndicatorTest {
    private val today = LocalDate.of(2026, 7, 28)

    @Test
    fun `待办截止日期跨日后显示准确逾期天数`() {
        assertEquals(
            TaskDeadlineIndicator.Overdue(LocalDate.of(2026, 7, 25), 3),
            taskDeadlineIndicator(TaskStatus.PENDING, LocalDate.of(2026, 7, 25), today),
        )
    }

    @Test
    fun `今天与未来截止日期使用非逾期状态`() {
        assertEquals(
            TaskDeadlineIndicator.DueToday(today),
            taskDeadlineIndicator(TaskStatus.PENDING, today, today),
        )
        assertEquals(
            TaskDeadlineIndicator.DateOnly(LocalDate.of(2026, 7, 29)),
            taskDeadlineIndicator(TaskStatus.PENDING, LocalDate.of(2026, 7, 29), today),
        )
    }

    @Test
    fun `已结算任务保留截止日期但不标记逾期`() {
        val deadline = LocalDate.of(2026, 7, 25)

        assertEquals(
            TaskDeadlineIndicator.DateOnly(deadline),
            taskDeadlineIndicator(TaskStatus.COMPLETED, deadline, today),
        )
        assertEquals(
            TaskDeadlineIndicator.DateOnly(deadline),
            taskDeadlineIndicator(TaskStatus.PASS, deadline, today),
        )
        assertNull(taskDeadlineIndicator(TaskStatus.PENDING, null, today))
    }
}
