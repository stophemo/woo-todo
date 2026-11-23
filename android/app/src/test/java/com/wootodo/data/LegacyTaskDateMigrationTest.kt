package com.wootodo.data

import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskRecurrence
import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import java.time.LocalTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LegacyTaskDateMigrationTest {
    private val legacyCreatedAt = 1_790_000_000_000L

    @Test
    fun `前一天到当天的旧区间折算为当天单日任务`() {
        val task = task(
            "GI 第 3 场",
            start = LocalDate.of(2026, 11, 23),
            end = LocalDate.of(2026, 11, 24),
        )

        val planned = LegacyTaskDateMigration.plan(listOf(task))

        assertEquals(1, planned.size)
        assertEquals(LocalDate.of(2026, 11, 24), planned.first().startDate)
        assertEquals(LocalDate.of(2026, 11, 24), planned.first().endDate)
        assertEquals(LocalTime.of(21, 30), planned.first().reminderTime)
    }

    @Test
    fun `跨天任务每天重复已结算和新任务保持不变`() {
        val range = task(
            "三天项目",
            start = LocalDate.of(2026, 11, 23),
            end = LocalDate.of(2026, 11, 25),
        )
        val daily = task(
            "铲屎",
            start = LocalDate.of(2026, 11, 23),
            end = LocalDate.of(2026, 11, 24),
            recurrence = TaskRecurrence.DAILY,
        )
        val completed = task(
            "已完成",
            start = LocalDate.of(2026, 11, 23),
            end = LocalDate.of(2026, 11, 24),
            status = TaskStatus.COMPLETED,
        )
        val recent = task(
            "新版两天任务",
            start = LocalDate.of(2026, 11, 23),
            end = LocalDate.of(2026, 11, 24),
            createdAt = 1_800_000_000_000L,
        )

        assertTrue(
            LegacyTaskDateMigration.plan(listOf(range, daily, completed, recent)).isEmpty(),
        )
    }

    @Test
    fun `迁移草稿保留标题标签提醒和排序并按单日保存`() {
        val task = task(
            "GI 第 2 场",
            start = LocalDate.of(2026, 11, 22),
            end = LocalDate.of(2026, 11, 23),
        )

        val planned = LegacyTaskDateMigration.plan(listOf(task)).single().copy(
            categoryId = "work",
            sortOrder = 7,
            reminderTime = LocalTime.of(21, 30),
        )
        val draft = LegacyTaskDateMigration.draft(planned)

        assertEquals("GI 第 2 场", draft.title)
        assertEquals("work", draft.categoryId)
        assertEquals(LocalDate.of(2026, 11, 23), draft.startDate)
        assertEquals(null, draft.endDate)
        assertEquals(LocalTime.of(21, 30), draft.reminderTime)
        assertEquals(7, draft.sortOrder)
        assertEquals(TaskRecurrence.ONCE, draft.recurrence)
    }

    private fun task(
        title: String,
        start: LocalDate?,
        end: LocalDate?,
        status: TaskStatus = TaskStatus.PENDING,
        recurrence: TaskRecurrence = TaskRecurrence.ONCE,
        createdAt: Long = legacyCreatedAt,
    ) = Task(
        id = "task-$title",
        seriesId = "series-$title",
        title = title,
        categoryId = TaskCategories.INBOX_ID,
        startDate = start,
        endDate = end,
        status = status,
        sortOrder = 0,
        createdAt = createdAt,
        updatedAt = createdAt,
        settledAt = null,
        reminderTime = LocalTime.of(21, 30),
        recurrence = recurrence,
    )
}
