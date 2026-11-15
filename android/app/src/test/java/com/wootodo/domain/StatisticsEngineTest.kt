package com.wootodo.domain

import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StatisticsEngineTest {
    private val referenceDate = LocalDate.of(2026, 7, 15)
    private val zone = ZoneId.of("Asia/Shanghai")

    @Test
    fun `本周完成只统计本周一之后的任务`() {
        val tasks = listOf(
            completed("last-week", referenceDate.minusDays(7)),
            completed("monday", LocalDate.of(2026, 7, 13)),
            completed("today", referenceDate),
            passed("ignored", referenceDate),
        )

        val snapshot = StatisticsEngine.calculate(tasks, referenceDate, zone)

        assertEquals(2, snapshot.completedThisWeek)
    }

    @Test
    fun `连续天数从今天或昨天开始回溯`() {
        val withToday = listOf(
            completed("today", referenceDate),
            completed("yesterday", referenceDate.minusDays(1)),
            completed("two-days", referenceDate.minusDays(2)),
            completed("gap", referenceDate.minusDays(4)),
        )
        assertEquals(3, StatisticsEngine.calculate(withToday, referenceDate, zone).currentStreakDays)

        val withoutToday = listOf(
            completed("yesterday", referenceDate.minusDays(1)),
            completed("two-days", referenceDate.minusDays(2)),
        )
        assertEquals(2, StatisticsEngine.calculate(withoutToday, referenceDate, zone).currentStreakDays)

        val none = listOf(completed("older", referenceDate.minusDays(3)))
        assertEquals(0, StatisticsEngine.calculate(none, referenceDate, zone).currentStreakDays)
    }

    @Test
    fun `按时率只统计有截止日期的已完成任务`() {
        val tasks = listOf(
            task("on-time", TaskStatus.COMPLETED, start = "2026-07-10", end = "2026-07-15", completed = "2026-07-14"),
            task("same-day", TaskStatus.COMPLETED, start = "2026-07-15", end = "2026-07-15", completed = "2026-07-15"),
            task("late", TaskStatus.COMPLETED, start = "2026-07-01", end = "2026-07-10", completed = "2026-07-12"),
            task("no-end", TaskStatus.COMPLETED, start = null, end = null, completed = "2026-07-11"),
            task("pass", TaskStatus.PASS, start = "2026-07-01", end = "2026-07-31", completed = "2026-07-11"),
        )

        val snapshot = StatisticsEngine.calculate(tasks, referenceDate, zone)
        assertEquals(2.0 / 3.0, snapshot.onTimeRate!!, 0.0001)

        val noSamples = listOf(task("pending", TaskStatus.PENDING, null, null, null))
        assertNull(StatisticsEngine.calculate(noSamples, referenceDate, zone).onTimeRate)
    }

    @Test
    fun `十四天趋势包含今天和窗口外排除`() {
        val tasks = listOf(
            completed("outside", referenceDate.minusDays(14)),
            completed("first", referenceDate.minusDays(13)),
            completed("today", referenceDate),
        )

        val activity = StatisticsEngine.calculate(tasks, referenceDate, zone).dailyActivity

        assertEquals(14, activity.size)
        assertEquals(referenceDate.minusDays(13), activity.first().date)
        assertEquals(referenceDate, activity.last().date)
        assertEquals(1, activity.first().completed)
        assertEquals(1, activity.last().completed)
        assertEquals(2, activity.sumOf { it.completed })
    }

    @Test
    fun `近三十天分类分布按完成数排序`() {
        val tasks = listOf(
            completed("work-1", referenceDate.minusDays(1), categoryId = "work"),
            completed("work-2", referenceDate, categoryId = "work"),
            completed("life", referenceDate.minusDays(2), categoryId = "life"),
            completed("outside", referenceDate.minusDays(30), categoryId = "life"),
        )

        val categories = StatisticsEngine.calculate(tasks, referenceDate, zone).categoryActivity

        assertEquals(listOf("work", "life"), categories.map { it.categoryId })
        assertEquals(2, categories.first().completed)
        assertEquals(2.0 / 3.0, categories.first().ratio, 0.0001)
    }

    @Test
    fun `历史按结算时间倒序且包含放弃`() {
        val tasks = listOf(
            completed("old", referenceDate.minusDays(2)),
            passed("new", referenceDate),
            task("pending", TaskStatus.PENDING, null, null, null),
        )

        val history = StatisticsEngine.calculate(tasks, referenceDate, zone).recentHistory
        assertEquals(listOf("new", "old"), history.map(Task::id))
    }

    @Test
    fun `上海零点边界按本地日期计算`() {
        val boundary = "2026-07-15T16:00:00Z"
        val task = task(
            "boundary",
            TaskStatus.COMPLETED,
            start = "2026-07-16",
            end = "2026-07-16",
            completed = boundary,
        )

        val snapshot = StatisticsEngine.calculate(listOf(task), LocalDate.of(2026, 7, 16), zone)
        assertEquals(1, snapshot.dailyActivity.last().completed)
        assertEquals(1, snapshot.currentStreakDays)
    }

    private fun completed(
        id: String,
        date: LocalDate,
        categoryId: String = TaskCategories.INBOX_ID,
    ): Task = task(
        id,
        TaskStatus.COMPLETED,
        start = null,
        end = null,
        completed = date.atTime(12, 0).atZone(zone).toInstant().toString(),
        categoryId = categoryId,
    )

    private fun passed(id: String, date: LocalDate): Task = task(
        id,
        TaskStatus.PASS,
        start = null,
        end = null,
        completed = date.atTime(12, 0).atZone(zone).toInstant().toString(),
    )

    private fun task(
        id: String,
        status: TaskStatus,
        start: String?,
        end: String?,
        completed: String?,
        categoryId: String = TaskCategories.INBOX_ID,
    ): Task = Task(
        id = id,
        seriesId = "series-$id",
        title = id,
        categoryId = categoryId,
        startDate = start?.let(LocalDate::parse),
        endDate = end?.let(LocalDate::parse),
        status = status,
        sortOrder = 0,
        createdAt = 0,
        updatedAt = 0,
        settledAt = completed?.let { value ->
            runCatching { java.time.Instant.parse(value) }
                .getOrElse {
                    LocalDate.parse(value).atTime(12, 0)
                        .atZone(TaskDateRules.zoneId)
                        .toInstant()
                }
                .toEpochMilli()
        },
    )
}
