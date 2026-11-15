package com.wootodo.widget

import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class TodayWidgetItemsTest {
    @Test
    fun `按分类顺序分组并跳过空分组`() {
        val items = TodayWidgetItems.from(
            listOf(
                task("extra", "extra"),
                task("main-1", "main"),
                task("main-2", "main"),
            ),
            TaskCategories.defaults,
        )

        assertEquals(
            listOf(
                "header:main",
                "task:main-1",
                "task:main-2",
                "header:extra",
                "task:extra",
            ),
            items.map { item ->
                when (item) {
                    is TodayWidgetListItem.Header -> "header:${item.category.id}"
                    is TodayWidgetListItem.Row -> "task:${item.task.id}"
                }
            },
        )
    }

    @Test
    fun `未知分类归入未分类`() {
        val items = TodayWidgetItems.from(
            listOf(task("unknown", "removed")),
            TaskCategories.defaults,
        )

        assertEquals(
            listOf("header:inbox", "task:unknown"),
            items.map { item ->
                when (item) {
                    is TodayWidgetListItem.Header -> "header:${item.category.id}"
                    is TodayWidgetListItem.Row -> "task:${item.task.id}"
                }
            },
        )
    }

    @Test
    fun `标题和任务使用不同视图类型及稳定ID命名空间`() {
        val items = TodayWidgetItems.from(
            TaskCategories.defaults.map { category -> task(category.id, category.id) },
            TaskCategories.defaults,
        )

        val headers = items.filterIsInstance<TodayWidgetListItem.Header>()
        val rows = items.filterIsInstance<TodayWidgetListItem.Row>()

        assertEquals(
            List(TaskCategories.defaults.size) { TODAY_WIDGET_VIEW_TYPE_HEADER },
            headers.map { it.viewType },
        )
        assertEquals(
            List(TaskCategories.defaults.size) { TODAY_WIDGET_VIEW_TYPE_TASK },
            rows.map { it.viewType },
        )
        assertEquals(items.size, items.map { it.stableId }.distinct().size)
        headers.forEach { header ->
            rows.forEach { row -> assertNotEquals(header.stableId, row.stableId) }
        }
    }

    private fun task(id: String, categoryId: String) = Task(
        id = id,
        seriesId = "series-$id",
        title = id,
        categoryId = categoryId,
        startDate = LocalDate.of(2026, 7, 28),
        endDate = LocalDate.of(2026, 7, 28),
        status = TaskStatus.PENDING,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = 1_000,
        settledAt = null,
    )
}
