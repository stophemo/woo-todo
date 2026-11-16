package com.wootodo.ui

import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskListPresenterTest {
    private val today = LocalDate.of(2026, 7, 15)
    private val zone = ZoneId.of("Asia/Shanghai")
    private val categories = listOf(
        TaskCategory(TaskCategories.INBOX_ID, "未分类", 0),
        TaskCategory("work", "工作", 1),
        TaskCategory("life", "生活", 2),
    )

    @Test
    fun `五组任务按固定顺序输出`() {
        val settledAt = today.atTime(9, 0).atZone(zone).toInstant().toEpochMilli()
        val tasks = listOf(
            task("settled", status = TaskStatus.COMPLETED, settledAt = settledAt),
            task("unscheduled"),
            task("upcoming", startDate = today.plusDays(1), endDate = today.plusDays(2)),
            task("today", startDate = today, endDate = today),
            task("overdue", startDate = today.minusDays(2), endDate = today.minusDays(1)),
        )

        val sections = TaskListPresenter.sections(tasks, categories, today, zone)

        assertEquals(
            listOf(
                TaskSectionKind.OVERDUE,
                TaskSectionKind.TODAY,
                TaskSectionKind.UPCOMING,
                TaskSectionKind.UNSCHEDULED,
                TaskSectionKind.SETTLED_TODAY,
            ),
            sections.map { it.kind },
        )
        assertEquals(listOf("overdue"), sections[0].tasks.map(Task::id))
        assertEquals(listOf("today"), sections[1].tasks.map(Task::id))
        assertEquals(listOf("upcoming"), sections[2].tasks.map(Task::id))
        assertEquals(listOf("unscheduled"), sections[3].tasks.map(Task::id))
        assertEquals(listOf("settled"), sections[4].tasks.map(Task::id))
    }

    @Test
    fun `组内先按标签优先级再按结束日期和排序值排列`() {
        val tasks = listOf(
            task("late", startDate = today, endDate = today.plusDays(3), categoryId = "work", sortOrder = 0),
            task("early-life", startDate = today, endDate = today.plusDays(1), categoryId = "life", sortOrder = 0),
            task("early-work-2", startDate = today, endDate = today.plusDays(1), categoryId = "work", sortOrder = 2),
            task("early-work-1", startDate = today, endDate = today.plusDays(1), categoryId = "work", sortOrder = 1),
            task("undated", sortOrder = 0),
        )

        val sections = TaskListPresenter.sections(tasks, categories, today, zone)
        val todayTasks = sections.first { it.kind == TaskSectionKind.TODAY }.tasks
        assertEquals(
            listOf("early-work-1", "early-work-2", "late", "early-life"),
            todayTasks.map(Task::id),
        )
        assertEquals(
            listOf("undated"),
            sections.first { it.kind == TaskSectionKind.UNSCHEDULED }.tasks.map(Task::id),
        )
    }

    @Test
    fun `标签优先级高的任务排在组内前面`() {
        val prioritized = listOf(
            TaskCategory("life", "生活", 0),
            TaskCategory("work", "工作", 1),
            TaskCategory(TaskCategories.INBOX_ID, "未分类", 2),
        )
        val tasks = listOf(
            task("work-sooner", startDate = today, endDate = today, categoryId = "work"),
            task("life-later", startDate = today, endDate = today.plusDays(2), categoryId = "life"),
        )

        val sections = TaskListPresenter.sections(tasks, prioritized, today, zone)

        assertEquals(
            listOf("life-later", "work-sooner"),
            sections.first { it.kind == TaskSectionKind.TODAY }.tasks.map(Task::id),
        )
    }

    @Test
    fun `昨天完成和未来完成不进入今天完成`() {
        val yesterday = today.minusDays(1).atTime(10, 0)
            .atZone(zone).toInstant().toEpochMilli()
        val todaySettled = today.atTime(10, 0)
            .atZone(zone).toInstant().toEpochMilli()
        val tasks = listOf(
            task("yesterday", status = TaskStatus.COMPLETED, settledAt = yesterday),
            task("today", status = TaskStatus.PASS, settledAt = todaySettled),
        )

        val sections = TaskListPresenter.sections(tasks, categories, today, zone)
        assertEquals(
            listOf("today"),
            sections.first { it.kind == TaskSectionKind.SETTLED_TODAY }.tasks.map(Task::id),
        )
    }

    @Test
    fun `空组不输出且全部为空时返回空列表`() {
        assertTrue(TaskListPresenter.sections(emptyList(), categories, today, zone).isEmpty())
        assertEquals(
            listOf(TaskSectionKind.UNSCHEDULED),
            TaskListPresenter.sections(
                listOf(task("only")),
                categories,
                today,
                zone,
            ).map { it.kind },
        )
    }

    private fun task(
        id: String,
        status: TaskStatus = TaskStatus.PENDING,
        startDate: LocalDate? = null,
        endDate: LocalDate? = null,
        categoryId: String = TaskCategories.INBOX_ID,
        sortOrder: Int = 0,
        settledAt: Long? = null,
    ) = Task(
        id = id,
        seriesId = "series-$id",
        title = id,
        categoryId = categoryId,
        startDate = startDate,
        endDate = endDate,
        status = status,
        sortOrder = sortOrder,
        createdAt = 1_000,
        updatedAt = settledAt ?: 1_000,
        settledAt = settledAt,
    )
}
