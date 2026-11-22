package com.wootodo.reminder

import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Test

class DailyDigestTextTest {
    private val today = LocalDate.of(2026, 11, 22)

    @Test
    fun `汇总明天进行中明天开始和已逾期任务`() {
        val summary = DailyDigestText.summary(
            listOf(
                task("跨天项目", today, today.plusDays(2)),
                task("明天开始", today.plusDays(1), today.plusDays(1)),
                task("已经逾期", today.minusDays(2), today.minusDays(1)),
                task("以后再说", today.plusDays(3), today.plusDays(3)),
                task("未安排", null, null),
            ),
            today,
        )

        assertEquals(3, summary.count)
        assertEquals(listOf("已经逾期", "跨天项目", "明天开始"), summary.titles)
    }

    @Test
    fun `每天重复任务会提前进入晚间汇总`() {
        val summary = DailyDigestText.summary(
            listOf(
                task("铲屎", today, today).copy(
                    recurrence = com.wootodo.domain.TaskRecurrence.DAILY,
                ),
            ),
            today,
        )

        assertEquals(1, summary.count)
        assertEquals(listOf("铲屎"), summary.titles)
    }

    @Test
    fun `没有明天任务时返回空汇总`() {
        val summary = DailyDigestText.summary(
            listOf(task("以后再说", today.plusDays(3), today.plusDays(3))),
            today,
        )

        assertEquals(0, summary.count)
        assertEquals(emptyList<String>(), summary.titles)
    }

    @Test
    fun `超过三条时只保留前三条`() {
        val tomorrow = today.plusDays(1)
        val summary = DailyDigestText.summary(
            (1..5).map { task("任务$it", tomorrow, tomorrow) },
            today,
        )

        assertEquals(5, summary.count)
        assertEquals(listOf("任务1", "任务2", "任务3"), summary.titles)
    }

    private fun task(title: String, start: LocalDate?, end: LocalDate?) = Task(
        id = title,
        seriesId = "series-$title",
        title = title,
        categoryId = TaskCategories.INBOX_ID,
        startDate = start,
        endDate = end,
        status = TaskStatus.PENDING,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = 1_000,
        settledAt = null,
    )
}
