package com.wootodo.display

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DayCounterTextTest {
    @Test
    fun `起始日按第一天计算`() {
        val settings = DayCounterSettings(
            enabled = true,
            title = "来到西安 remake",
            startDate = LocalDate.of(2026, 7, 20),
        )

        assertEquals(
            "来到西安 remake · 第 2 天",
            DayCounterText.format(settings, LocalDate.of(2026, 7, 21)),
        )
    }

    @Test
    fun `关闭空标题或未来日期不显示`() {
        val today = LocalDate.of(2026, 7, 21)
        assertNull(DayCounterText.format(DayCounterSettings(startDate = today), today))
        assertNull(
            DayCounterText.format(
                DayCounterSettings(true, "   ", today),
                today,
            ),
        )
        assertNull(
            DayCounterText.format(
                DayCounterSettings(true, "纪念日", today.plusDays(1)),
                today,
            ),
        )
    }
}
