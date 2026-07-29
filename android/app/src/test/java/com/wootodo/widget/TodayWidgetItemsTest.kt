package com.wootodo.widget

import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.Task
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class TodayWidgetItemsTest {
    @Test
    fun `按主线支线外传分组并跳过空分组`() {
        val items = TodayWidgetItems.from(
            listOf(
                task("extra", QuestLine.EXTRA),
                task("main-1", QuestLine.MAIN),
                task("main-2", QuestLine.MAIN),
            ),
        )

        assertEquals(
            listOf(
                "header:MAIN",
                "task:main-1",
                "task:main-2",
                "header:EXTRA",
                "task:extra",
            ),
            items.map { item ->
                when (item) {
                    is TodayWidgetListItem.Header -> "header:${item.questLine}"
                    is TodayWidgetListItem.Row -> "task:${item.task.id}"
                }
            },
        )
    }

    @Test
    fun `标题和任务使用不同视图类型及稳定ID命名空间`() {
        val items = TodayWidgetItems.from(
            QuestLine.entries.map { questLine -> task(questLine.rawValue, questLine) },
        )

        val headers = items.filterIsInstance<TodayWidgetListItem.Header>()
        val rows = items.filterIsInstance<TodayWidgetListItem.Row>()

        assertEquals(List(QuestLine.entries.size) { TODAY_WIDGET_VIEW_TYPE_HEADER }, headers.map { it.viewType })
        assertEquals(List(QuestLine.entries.size) { TODAY_WIDGET_VIEW_TYPE_TASK }, rows.map { it.viewType })
        assertEquals(items.size, items.map { it.stableId }.distinct().size)
        headers.forEach { header ->
            rows.forEach { row -> assertNotEquals(header.stableId, row.stableId) }
        }
    }

    private fun task(id: String, questLine: QuestLine) = Task(
        id = id,
        seriesId = "series-$id",
        title = id,
        timeType = TaskTimeType.DAY,
        targetDate = LocalDate.of(2026, 7, 28),
        questLine = questLine,
        status = TaskStatus.PENDING,
        recurrence = Recurrence.ONCE,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = 1_000,
        settledAt = null,
    )
}
