package com.wootodo.domain

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Test

class TaskListDatePolicyTest {
    @Test
    fun `明日清单能跨月跨年`() {
        assertEquals(
            LocalDate.of(2027, 1, 1),
            TaskListDatePolicy.referenceDate(
                scope = TaskTimeType.DAY,
                showTomorrow = true,
                today = LocalDate.of(2026, 12, 31),
            ),
        )
    }

    @Test
    fun `周月闲时清单不受明日选择影响`() {
        val today = LocalDate.of(2026, 7, 17)
        listOf(TaskTimeType.WEEK, TaskTimeType.MONTH, TaskTimeType.LEISURE).forEach { scope ->
            assertEquals(today, TaskListDatePolicy.referenceDate(scope, true, today))
        }
    }
}
