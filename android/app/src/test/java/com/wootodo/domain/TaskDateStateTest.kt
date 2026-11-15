package com.wootodo.domain

import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskDateStateTest {
    private val today = LocalDate.of(2026, 7, 15)
    private val zone = ZoneId.of("Asia/Shanghai")

    @Test
    fun `结束日期早于今天且仍待办时算逾期`() {
        val task = task(endDate = today.minusDays(1))

        assertTrue(TaskDateState.isOverdue(task, today))
        assertTrue(TaskDateState.isRelevantOn(task, today))
    }

    @Test
    fun `开始和结束日期边界当天均算有效`() {
        val task = task(startDate = today, endDate = today.plusDays(2))

        assertTrue(TaskDateState.isActiveOn(task, today))
        assertTrue(TaskDateState.isActiveOn(task, today.plusDays(2)))
        assertFalse(TaskDateState.isActiveOn(task, today.minusDays(1)))
        assertFalse(TaskDateState.isActiveOn(task, today.plusDays(3)))
    }

    @Test
    fun `无日期待办始终相关`() {
        val task = task()

        assertTrue(TaskDateState.isRelevantOn(task, today))
        assertFalse(TaskDateState.isActiveOn(task, today))
    }

    @Test
    fun `已结算任务只在结算当天算今日结算`() {
        val settledAt = today.atTime(10, 30).atZone(zone).toInstant().toEpochMilli()
        val task = task(
            status = TaskStatus.COMPLETED,
            settledAt = settledAt,
        )

        assertTrue(TaskDateState.isSettledOn(task, today, zone))
        assertFalse(TaskDateState.isSettledOn(task, today.plusDays(1), zone))
        assertFalse(TaskDateState.isRelevantOn(task, today))
    }

    private fun task(
        startDate: LocalDate? = null,
        endDate: LocalDate? = null,
        status: TaskStatus = TaskStatus.PENDING,
        settledAt: Long? = null,
    ) = Task(
        id = "task-${startDate}-$endDate-$status",
        seriesId = "task-${startDate}-$endDate-$status",
        title = "测试任务",
        categoryId = TaskCategories.INBOX_ID,
        startDate = startDate,
        endDate = endDate,
        status = status,
        sortOrder = 0,
        createdAt = 0,
        updatedAt = settledAt ?: 0,
        settledAt = settledAt,
    )
}
