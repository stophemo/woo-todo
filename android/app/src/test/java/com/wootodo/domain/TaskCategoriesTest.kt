package com.wootodo.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskCategoriesTest {
    @Test
    fun `规范列表保留未分类的当前优先级位置`() {
        val normalized = TaskCategories.normalizeList(
            listOf(
                TaskCategory("work", "工作", 0),
                TaskCategory(TaskCategories.INBOX_ID, "未分类", 1),
                TaskCategory("life", "生活", 2),
            ),
        )

        assertEquals(listOf("work", TaskCategories.INBOX_ID, "life"), normalized.map { it.id })
        assertEquals(listOf(0, 1, 2), normalized.map { it.order })
    }

    @Test
    fun `超过上限时仍保留未分类兜底`() {
        val customs = (1..8).map { index ->
            TaskCategory("c$index", "标签$index", index - 1)
        }
        val normalized = TaskCategories.normalizeList(
            customs + TaskCategory(TaskCategories.INBOX_ID, "未分类", 8),
        )

        assertEquals(TaskCategories.MAXIMUM_COUNT, normalized.size)
        assertTrue(normalized.any { it.id == TaskCategories.INBOX_ID })
    }

    @Test
    fun `缺少未分类时仍补在最前`() {
        val normalized = TaskCategories.normalizeList(
            listOf(TaskCategory("work", "工作", 0)),
        )

        assertEquals(listOf(TaskCategories.INBOX_ID, "work"), normalized.map { it.id })
    }
}
