package com.wootodo.display

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DayCounterTextTest {
    @Test
    fun `旧版设置迁移后仍按起始日为第一天显示`() {
        val settings = DayCounterSettings(
            enabled = true,
            title = "来到西安 remake",
            startDate = LocalDate.of(2026, 7, 20),
        )

        assertEquals(
            "来到西安 remake · 第 2 天",
            DayCounterText.format(settings, LocalDate.of(2026, 7, 21)),
        )
        assertEquals("今日任务", DayCounterText.render(settings).header)
    }

    @Test
    fun `跨年渲染星期耗时和过期截止天数`() {
        val settings = DayCounterSettings(
            headerTemplate = "重启 · {weekday}",
            subtitleTemplate = "耗时 {elapsedDays} 天 · 截止 {deadlineDays} 天",
            startDate = LocalDate.of(2026, 12, 31),
            deadlineDate = LocalDate.of(2027, 1, 1),
        )

        val rendered = DayCounterText.render(settings, LocalDate.of(2027, 1, 2))

        assertEquals("重启 · 星期六", rendered.header)
        assertEquals("耗时 3 天 · 截止 -1 天", rendered.subtitle)
    }

    @Test
    fun `未来起始为零且空模板隐藏未知变量保留`() {
        val today = LocalDate.of(2026, 7, 21)
        val rendered = DayCounterText.render(
            DayCounterSettings(
                headerTemplate = "  ",
                subtitleTemplate = "第 {elapsedDays} 天 · {custom}",
                startDate = today.plusDays(3),
                deadlineDate = today.plusDays(3),
            ),
            today,
        )

        assertNull(rendered.header)
        assertEquals("第 0 天 · {custom}", rendered.subtitle)
    }
}
