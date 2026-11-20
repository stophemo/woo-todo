package com.wootodo.domain

import com.wootodo.data.TaskEntity
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RecurringTaskSettlerTest {
    private val today = LocalDate.of(2026, 11, 20)
    private val now = today.atTime(12, 0).atZone(TaskDateRules.zoneId).toInstant().toEpochMilli()

    @Test
    fun `未完成的每日任务记为放弃并生成今天的新任务`() {
        val task = task("铲屎", LocalDate.of(2026, 11, 19), LocalDate.of(2026, 11, 19))

        val result = RecurringTaskSettler.settle(listOf(task), today, now)

        assertEquals(1, result.updatedTasks.size)
        assertEquals(TaskStatus.PASS, result.updatedTasks.single().status)
        assertEquals(1, result.createdTasks.size)
        val next = result.createdTasks.single()
        assertEquals("铲屎", next.title)
        assertEquals(task.seriesId, next.seriesId)
        assertEquals(TaskStatus.PENDING, next.status)
        assertEquals(today, next.startDate)
        assertEquals(today, next.endDate)
        assertEquals(TaskRecurrence.DAILY, next.recurrence)
        assertEquals(
            RecurringTaskSettler.occurrenceId(task.seriesId, today),
            next.id,
        )
    }

    @Test
    fun `连续漏做会逐日记录放弃并补齐到今天`() {
        val task = task("铲屎", LocalDate.of(2026, 11, 17), LocalDate.of(2026, 11, 17))

        val result = RecurringTaskSettler.settle(listOf(task), today, now)

        assertEquals(1, result.updatedTasks.size)
        assertEquals(3, result.createdTasks.size)
        val settled = result.updatedTasks + result.createdTasks.filter {
            it.status == TaskStatus.PASS
        }
        assertEquals(3, settled.size)
        assertTrue(settled.all { it.status == TaskStatus.PASS })
        val pending = result.createdTasks.filter { it.status == TaskStatus.PENDING }
        assertEquals(1, pending.size)
        assertEquals(today, pending.single().startDate)
    }

    @Test
    fun `已完成的上一条不会改写但仍生成下一条`() {
        val task = task(
            "铲屎",
            LocalDate.of(2026, 11, 19),
            LocalDate.of(2026, 11, 19),
        ).copy(status = TaskStatus.COMPLETED, settledAt = now)

        val result = RecurringTaskSettler.settle(listOf(task), today, now)

        assertTrue(result.updatedTasks.isEmpty())
        assertEquals(1, result.createdTasks.size)
        assertEquals(today, result.createdTasks.single().startDate)
    }

    @Test
    fun `重复结算保持幂等`() {
        val task = task("铲屎", LocalDate.of(2026, 11, 19), LocalDate.of(2026, 11, 19))
        val first = RecurringTaskSettler.settle(listOf(task), today, now)
        val settled = listOf(task)
            .filterNot { original -> first.updatedTasks.any { it.id == original.id } } +
            first.updatedTasks + first.createdTasks

        val second = RecurringTaskSettler.settle(settled, today, now)

        assertTrue(second.isEmpty)
    }

    @Test
    fun `删除下一条后序列停止`() {
        val task = task("铲屎", LocalDate.of(2026, 11, 19), LocalDate.of(2026, 11, 19))
        val nextId = RecurringTaskSettler.occurrenceId(task.seriesId, today)

        val result = RecurringTaskSettler.settle(
            listOf(task),
            today,
            now,
            deletedTaskIds = setOf(nextId),
        )

        assertTrue(result.createdTasks.isEmpty())
    }

    @Test
    fun `一次性任务不参与重复结算`() {
        val task = task(
            "一次性",
            LocalDate.of(2026, 11, 19),
            LocalDate.of(2026, 11, 19),
            TaskRecurrence.ONCE,
        )

        val result = RecurringTaskSettler.settle(listOf(task), today, now)

        assertTrue(result.isEmpty)
    }

    @Test
    fun `occurrence id 与 macOS 和旧周期任务保持一致`() {
        assertEquals(
            "ca7b0dc3-d6fa-57db-ad8f-568c71426692",
            RecurringTaskSettler.occurrenceId(
                "550e8400-e29b-41d4-a716-446655440000",
                LocalDate.of(2026, 11, 20),
            ),
        )
    }

    private fun task(
        title: String,
        start: LocalDate,
        end: LocalDate,
        recurrence: TaskRecurrence = TaskRecurrence.DAILY,
    ) = TaskEntity(
        id = "task-$title",
        seriesId = "series-$title",
        title = title,
        categoryId = TaskCategories.INBOX_ID,
        startDate = start,
        endDate = end,
        status = TaskStatus.PENDING,
        sortOrder = 0,
        createdAt = now,
        updatedAt = now,
        settledAt = null,
        recurrence = recurrence,
    )
}
