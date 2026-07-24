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
    fun `跨月按自然月和天渲染耗时与过期截止`() {
        val settings = DayCounterSettings(
            headerTemplate = "{elapsedMonthsDays}",
            subtitleTemplate = "{deadlineMonthsDays}",
            startDate = LocalDate.of(2026, 3, 3),
            deadlineDate = LocalDate.of(2026, 6, 3),
        )

        val rendered = DayCounterText.render(settings, LocalDate.of(2026, 7, 24))

        assertEquals("4个月零22天", rendered.header)
        assertEquals("-1个月零21天", rendered.subtitle)
    }

    @Test
    fun `支持英文星期和完整日期变量`() {
        val settings = DayCounterSettings(
            headerTemplate = "{weekdayEn} / {weekdayEnShort} / {weekdayShort}",
            subtitleTemplate = "{date} | {dateLong} | {year}/{month}/{day} | {monthPadded}/{dayPadded} | {startDate} -> {deadlineDate}",
            startDate = LocalDate.of(2026, 12, 31),
            deadlineDate = LocalDate.of(2027, 1, 9),
        )

        val rendered = DayCounterText.render(settings, LocalDate.of(2027, 1, 2))

        assertEquals("Saturday / Sat / 六", rendered.header)
        assertEquals(
            "2027-01-02 | 2027年1月2日 | 2027/1/2 | 01/02 | 2026-12-31 -> 2027-01-09",
            rendered.subtitle,
        )
    }

    @Test
    fun `中英文星期在完整一周内保持对应`() {
        val monday = LocalDate.of(2026, 7, 20)
        val expected = listOf(
            "星期一|一|Monday|Mon",
            "星期二|二|Tuesday|Tue",
            "星期三|三|Wednesday|Wed",
            "星期四|四|Thursday|Thu",
            "星期五|五|Friday|Fri",
            "星期六|六|Saturday|Sat",
            "星期日|日|Sunday|Sun",
        )
        val settings = DayCounterSettings(
            headerTemplate = "{weekday}|{weekdayShort}|{weekdayEn}|{weekdayEnShort}",
        )

        expected.forEachIndexed { offset, value ->
            assertEquals(value, DayCounterText.render(settings, monday.plusDays(offset.toLong())).header)
        }
    }

    @Test
    fun `未来起始为零且空模板隐藏未知变量保留`() {
        val today = LocalDate.of(2026, 7, 21)
        val rendered = DayCounterText.render(
            DayCounterSettings(
                headerTemplate = "  ",
                subtitleTemplate = "第 {elapsedDays} 天 · {elapsedMonthsDays} · {custom}",
                startDate = today.plusDays(3),
                deadlineDate = today.plusDays(3),
            ),
            today,
        )

        assertNull(rendered.header)
        assertEquals("第 0 天 · 0个月零0天 · {custom}", rendered.subtitle)
    }
}
