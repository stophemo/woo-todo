package com.wootodo.domain

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StatisticsEngineTest {
    private val referenceDate = LocalDate.of(2026, 7, 15)

    @Test
    fun `履约率只统计已经结束的日周月周期`() {
        val tasks = listOf(
            task("day-done", TaskTimeType.DAY, referenceDate.minusDays(1), QuestLine.MAIN, TaskStatus.COMPLETED, 10),
            task("day-pass", TaskTimeType.DAY, referenceDate.minusDays(1), QuestLine.SIDE, TaskStatus.PASS, 20),
            task("week-done", TaskTimeType.WEEK, LocalDate.of(2026, 7, 6), QuestLine.MAIN, TaskStatus.COMPLETED, 30),
            task("month-pass", TaskTimeType.MONTH, LocalDate.of(2026, 6, 1), QuestLine.MAIN, TaskStatus.PASS, 40),
            task("current-week", TaskTimeType.WEEK, LocalDate.of(2026, 7, 13), QuestLine.MAIN, TaskStatus.PENDING, null),
            task("current-month", TaskTimeType.MONTH, LocalDate.of(2026, 7, 1), QuestLine.SIDE, TaskStatus.COMPLETED, 50),
            task("someday", TaskTimeType.LEISURE, null, QuestLine.MAIN, TaskStatus.COMPLETED, 60),
            task("expired-pending", TaskTimeType.DAY, referenceDate.minusDays(2), QuestLine.SIDE, TaskStatus.PENDING, null),
        )

        val snapshot = StatisticsEngine.calculate(tasks, referenceDate)

        assertEquals(0.5, snapshot.endedPeriodFulfillmentRate!!, 0.0001)
        assertEquals(2.0 / 3.0, snapshot.mainQuestFulfillmentRate!!, 0.0001)
        assertEquals(
            StatusCounts(completed = 1, pass = 1, pending = 1),
            snapshot.byTimeType[TaskTimeType.DAY],
        )
        assertEquals(StatusCounts(completed = 3, pass = 1, pending = 1), snapshot.byQuestLine[QuestLine.MAIN])
    }

    @Test
    fun `最近历史按结算时间倒序并排除待办`() {
        val tasks = listOf(
            task("old", TaskTimeType.DAY, referenceDate.minusDays(2), QuestLine.MAIN, TaskStatus.COMPLETED, 10),
            task("new", TaskTimeType.DAY, referenceDate.minusDays(1), QuestLine.SIDE, TaskStatus.PASS, 30),
            task("pending", TaskTimeType.DAY, referenceDate, QuestLine.EXTRA, TaskStatus.PENDING, null),
        )

        assertEquals(
            listOf("new", "old"),
            StatisticsEngine.calculate(tasks, referenceDate, recentHistoryLimit = 2)
                .recentHistory.map { it.id },
        )
    }

    @Test
    fun `没有已结束周期时履约率为空`() {
        val current = task(
            "current",
            TaskTimeType.DAY,
            referenceDate,
            QuestLine.MAIN,
            TaskStatus.PENDING,
            null,
        )

        val snapshot = StatisticsEngine.calculate(listOf(current), referenceDate)

        assertNull(snapshot.endedPeriodFulfillmentRate)
        assertNull(snapshot.mainQuestFulfillmentRate)
    }

    @Test
    fun `趋势按固定日周月窗口分桶并排除窗口外样本`() {
        val tasks = listOf(
            task("day-outside", TaskTimeType.DAY, LocalDate.of(2026, 7, 8), QuestLine.MAIN, TaskStatus.COMPLETED, 10),
            task("day-oldest", TaskTimeType.DAY, LocalDate.of(2026, 7, 9), QuestLine.MAIN, TaskStatus.COMPLETED, 20),
            task("day-yesterday", TaskTimeType.DAY, LocalDate.of(2026, 7, 14), QuestLine.SIDE, TaskStatus.PASS, 30),
            task("day-current", TaskTimeType.DAY, LocalDate.of(2026, 7, 15), QuestLine.SIDE, TaskStatus.COMPLETED, 40),
            task("week-outside", TaskTimeType.WEEK, LocalDate.of(2026, 5, 18), QuestLine.MAIN, TaskStatus.COMPLETED, 50),
            task("week-oldest", TaskTimeType.WEEK, LocalDate.of(2026, 5, 27), QuestLine.MAIN, TaskStatus.COMPLETED, 60),
            task("week-current", TaskTimeType.WEEK, LocalDate.of(2026, 7, 15), QuestLine.MAIN, TaskStatus.COMPLETED, 70),
            task("month-outside", TaskTimeType.MONTH, LocalDate.of(2026, 1, 1), QuestLine.MAIN, TaskStatus.COMPLETED, 80),
            task("month-oldest", TaskTimeType.MONTH, LocalDate.of(2026, 2, 20), QuestLine.MAIN, TaskStatus.COMPLETED, 90),
            task("month-previous", TaskTimeType.MONTH, LocalDate.of(2026, 6, 30), QuestLine.SIDE, TaskStatus.PASS, 100),
            task("month-current", TaskTimeType.MONTH, LocalDate.of(2026, 7, 15), QuestLine.SIDE, TaskStatus.COMPLETED, 110),
        )

        val snapshot = StatisticsEngine.calculate(tasks, referenceDate)

        assertEquals(7, snapshot.dailyTrend.size)
        assertEquals(LocalDate.of(2026, 7, 9), snapshot.dailyTrend.first().startDate)
        assertEquals(LocalDate.of(2026, 7, 15), snapshot.dailyTrend.last().startDate)
        assertEquals(3, snapshot.dailyTrend.sumOf { it.sampleCount })
        val yesterday = snapshot.dailyTrend.first { it.startDate == LocalDate.of(2026, 7, 14) }
        assertEquals(0, yesterday.completed)
        assertEquals(1, yesterday.pass)
        assertEquals(1, yesterday.sampleCount)
        assertEquals(0.0, yesterday.fulfillmentRate!!, 0.0001)
        val today = snapshot.dailyTrend.last()
        assertEquals(1, today.completed)
        assertEquals(1, today.sampleCount)
        assertFalse(today.isEnded)
        assertNull(today.fulfillmentRate)

        assertEquals(8, snapshot.weeklyTrend.size)
        assertEquals(LocalDate.of(2026, 5, 25), snapshot.weeklyTrend.first().startDate)
        assertEquals(LocalDate.of(2026, 7, 13), snapshot.weeklyTrend.last().startDate)
        assertEquals(2, snapshot.weeklyTrend.sumOf { it.sampleCount })
        assertNull(snapshot.weeklyTrend.last().fulfillmentRate)

        assertEquals(6, snapshot.monthlyTrend.size)
        assertEquals(LocalDate.of(2026, 2, 1), snapshot.monthlyTrend.first().startDate)
        assertEquals(LocalDate.of(2026, 7, 1), snapshot.monthlyTrend.last().startDate)
        assertEquals(3, snapshot.monthlyTrend.sumOf { it.sampleCount })
        assertNull(snapshot.monthlyTrend.last().fulfillmentRate)
    }

    @Test
    fun `周一边界会结束上周桶并开启无履约率的新桶`() {
        val monday = LocalDate.of(2026, 7, 20)
        val previousWeek = task(
            "previous-week",
            TaskTimeType.WEEK,
            LocalDate.of(2026, 7, 13),
            QuestLine.MAIN,
            TaskStatus.COMPLETED,
            10,
        )

        val trend = StatisticsEngine.calculate(listOf(previousWeek), monday).weeklyTrend
        val endedPreviousWeek = trend.first {
            it.startDate == LocalDate.of(2026, 7, 13)
        }
        val currentWeek = trend.last()

        assertTrue(endedPreviousWeek.isEnded)
        assertEquals(1.0, endedPreviousWeek.fulfillmentRate!!, 0.0001)
        assertEquals(LocalDate.of(2026, 7, 20), currentWeek.startDate)
        assertFalse(currentWeek.isEnded)
        assertEquals(0, currentWeek.sampleCount)
        assertNull(currentWeek.fulfillmentRate)
    }

    private fun task(
        id: String,
        timeType: TaskTimeType,
        targetDate: LocalDate?,
        line: QuestLine,
        status: TaskStatus,
        settledAt: Long?,
    ): Task = Task(
        id = id,
        seriesId = id,
        title = id,
        timeType = timeType,
        targetDate = targetDate,
        questLine = line,
        status = status,
        recurrence = Recurrence.ONCE,
        sortOrder = 0,
        createdAt = 0,
        updatedAt = settledAt ?: 0,
        settledAt = settledAt,
    )
}
