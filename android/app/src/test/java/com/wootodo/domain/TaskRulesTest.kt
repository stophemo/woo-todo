package com.wootodo.domain

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TaskRulesTest {
    @Test
    fun `周与月任务会归一到周期起点`() {
        val date = LocalDate.of(2026, 7, 15)

        assertEquals(
            LocalDate.of(2026, 7, 13),
            TaskDateRules.normalizeTargetDate(TaskTimeType.WEEK, date),
        )
        assertEquals(
            LocalDate.of(2026, 7, 1),
            TaskDateRules.normalizeTargetDate(TaskTimeType.MONTH, date),
        )
        assertNull(TaskDateRules.normalizeTargetDate(TaskTimeType.LEISURE, date))
    }

    @Test
    fun `重复规则会推进到下一个实例日期`() {
        val date = LocalDate.of(2026, 1, 31)

        assertEquals(
            LocalDate.of(2026, 2, 28),
            TaskDateRules.nextOccurrenceDate(date, Recurrence.MONTHLY),
        )
        assertEquals(
            LocalDate.of(2026, 2, 7),
            TaskDateRules.nextOccurrenceDate(date, Recurrence.WEEKLY),
        )
    }

    @Test
    fun `闲时任务不会保留重复规则`() {
        assertEquals(
            Recurrence.ONCE,
            TaskRules.sanitizeRecurrence(TaskTimeType.LEISURE, Recurrence.DAILY),
        )
    }

    @Test
    fun `各时间类型只允许同周期重复`() {
        assertEquals(
            listOf(Recurrence.ONCE, Recurrence.DAILY),
            TaskRules.allowedRecurrences(TaskTimeType.DAY),
        )
        assertEquals(
            listOf(Recurrence.ONCE, Recurrence.WEEKLY),
            TaskRules.allowedRecurrences(TaskTimeType.WEEK),
        )
        assertEquals(
            listOf(Recurrence.ONCE, Recurrence.MONTHLY),
            TaskRules.allowedRecurrences(TaskTimeType.MONTH),
        )
    }

    @Test
    fun `协议值使用固定小写映射`() {
        assertEquals("day", TaskTimeType.DAY.rawValue)
        assertEquals("someday", TaskTimeType.LEISURE.rawValue)
        assertEquals("main", QuestLine.MAIN.rawValue)
        assertEquals(TaskTimeType.LEISURE, TaskTimeType.fromRaw("someday"))
    }

    @Test
    fun `重复实例ID与跨端协议固定输出一致`() {
        assertEquals(
            "bd19b6b6-7f10-55af-bf1e-323457e79404",
            OccurrenceId.create(
                seriesId = "550E8400-E29B-41D4-A716-446655440000",
                timeType = TaskTimeType.DAY,
                periodStart = LocalDate.of(2026, 7, 16),
            ),
        )
    }

    @Test
    fun `排序按任务线 状态和自定义序号执行`() {
        val base = task(id = "base", line = QuestLine.SIDE, status = TaskStatus.PENDING, order = 0)
        val tasks = listOf(
            base.copy(id = "extra", questLine = QuestLine.EXTRA),
            base.copy(id = "done", questLine = QuestLine.MAIN, status = TaskStatus.COMPLETED),
            base.copy(id = "second", questLine = QuestLine.MAIN, sortOrder = 2),
            base.copy(id = "first", questLine = QuestLine.MAIN, sortOrder = 1),
            base,
        )

        assertEquals(
            listOf("done", "first", "second", "base", "extra"),
            tasks.sortedWith(TaskRules.ordering).map { it.id },
        )
    }

    private fun task(
        id: String,
        line: QuestLine,
        status: TaskStatus,
        order: Int,
    ): Task = Task(
        id = id,
        seriesId = id,
        title = id,
        timeType = TaskTimeType.DAY,
        targetDate = LocalDate.of(2026, 7, 15),
        questLine = line,
        status = status,
        recurrence = Recurrence.ONCE,
        sortOrder = order,
        createdAt = 0,
        updatedAt = 0,
        settledAt = null,
    )
}
