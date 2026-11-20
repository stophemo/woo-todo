package com.wootodo.widget

import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskStatus
import com.wootodo.ui.TaskListPresenter
import com.wootodo.ui.TaskSectionKind
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class TodayWidgetItemsTest {
    @Test
    fun `小组件按主界面的日期分区顺序展示`() {
        val today = LocalDate.of(2026, 11, 20)
        val tasks = listOf(
            task("overdue", "inbox", today.minusDays(1), today.minusDays(1)),
            task("today", "inbox", today, today),
            task("upcoming", "inbox", today.plusDays(2), today.plusDays(2)),
            task("unscheduled", "inbox", null, null),
            task(
                "completed",
                "inbox",
                today,
                today,
                status = TaskStatus.COMPLETED,
                settledAt = today.atStartOfDay(TaskDateRulesZone).toInstant().toEpochMilli(),
            ),
        )
        val sections = TaskListPresenter.sections(
            tasks,
            listOf(TaskCategory(TaskCategories.INBOX_ID, "未分类", 0)),
            today,
        )

        val items = TodayWidgetItems.from(sections)

        assertEquals(
            listOf(
                "header:OVERDUE",
                "task:overdue",
                "header:TODAY",
                "task:today",
                "header:UPCOMING",
                "task:upcoming",
                "header:UNSCHEDULED",
                "task:unscheduled",
                "header:SETTLED_TODAY",
                "task:completed",
            ),
            items.map { item ->
                when (item) {
                    is TodayWidgetListItem.Header -> "header:${item.kind.name}"
                    is TodayWidgetListItem.Row -> "task:${item.task.id}"
                }
            },
        )
    }

    @Test
    fun `限制行数时保留分区标题且不截断出空标题`() {
        val today = LocalDate.of(2026, 11, 20)
        val sections = TaskListPresenter.sections(
            listOf(
                task("a", "inbox", today, today),
                task("b", "inbox", today, today),
                task("c", "inbox", today.plusDays(1), today.plusDays(1)),
            ),
            listOf(TaskCategory(TaskCategories.INBOX_ID, "未分类", 0)),
            today,
        )

        val items = TodayWidgetItems.from(sections, maxRows = 2)

        assertEquals(
            listOf("header:TODAY", "task:a", "task:b"),
            items.map { item ->
                when (item) {
                    is TodayWidgetListItem.Header -> "header:${item.kind.name}"
                    is TodayWidgetListItem.Row -> "task:${item.task.id}"
                }
            },
        )
    }

    @Test
    fun `标题和任务使用不同视图类型及稳定ID命名空间`() {
        val today = LocalDate.of(2026, 11, 20)
        val sections = TaskListPresenter.sections(
            listOf(
                task("a", "inbox", today, today),
                task("b", "inbox", today.plusDays(1), today.plusDays(1)),
            ),
            listOf(TaskCategory(TaskCategories.INBOX_ID, "未分类", 0)),
            today,
        )

        val items = TodayWidgetItems.from(sections)
        val headers = items.filterIsInstance<TodayWidgetListItem.Header>()
        val rows = items.filterIsInstance<TodayWidgetListItem.Row>()

        assertEquals(
            List(headers.size) { TODAY_WIDGET_VIEW_TYPE_HEADER },
            headers.map { it.viewType },
        )
        assertEquals(
            List(rows.size) { TODAY_WIDGET_VIEW_TYPE_TASK },
            rows.map { it.viewType },
        )
        assertEquals(items.size, items.map { it.stableId }.distinct().size)
        headers.forEach { header ->
            rows.forEach { row -> assertNotEquals(header.stableId, row.stableId) }
        }
        assertEquals(
            setOf(TaskSectionKind.TODAY, TaskSectionKind.UPCOMING),
            headers.map { it.kind }.toSet(),
        )
    }

    private fun task(
        id: String,
        categoryId: String,
        start: LocalDate?,
        end: LocalDate?,
        status: TaskStatus = TaskStatus.PENDING,
        settledAt: Long? = null,
    ) = Task(
        id = id,
        seriesId = "series-$id",
        title = id,
        categoryId = categoryId,
        startDate = start,
        endDate = end,
        status = status,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = 1_000,
        settledAt = settledAt,
    )

    private companion object {
        val TaskDateRulesZone = com.wootodo.domain.TaskDateRules.zoneId
    }
}
