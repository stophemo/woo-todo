package com.wootodo.display

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TraditionalCalendarInfoTest {
    @Test
    fun `跨年份显示农历日期和节气`() {
        val cases = listOf(
            TestCase("2025-04-04", LunarDate(3, 7), "农历三月初七", "清明"),
            TestCase("2026-08-07", LunarDate(6, 25), "农历六月廿五", "立秋"),
            TestCase("2027-01-05", LunarDate(11, 28), "农历冬月廿八", "小寒"),
        )

        cases.forEach { item ->
            val rendered = TraditionalCalendarInfo.render(
                date = LocalDate.parse(item.date),
                lunarDate = item.lunarDate,
            )
            assertEquals(item.lunarText, rendered.lunarDate)
            assertEquals(item.annotation, rendered.annotation)
        }
    }

    @Test
    fun `跨农历周期显示传统节日和除夕`() {
        val springFestival = TraditionalCalendarInfo.render(
            LocalDate.of(2026, 2, 17),
            LunarDate(1, 1),
        )
        val midAutumn = TraditionalCalendarInfo.render(
            LocalDate.of(2026, 9, 25),
            LunarDate(8, 15),
        )
        val newYearsEve = TraditionalCalendarInfo.render(
            LocalDate.of(2027, 2, 5),
            LunarDate(12, 29),
            LunarDate(1, 1),
        )

        assertEquals("春节", springFestival.annotation)
        assertEquals("中秋节", midAutumn.annotation)
        assertEquals("除夕", newYearsEve.annotation)
    }

    @Test
    fun `闰月同日不误报农历节日`() {
        val rendered = TraditionalCalendarInfo.render(
            LocalDate.of(2025, 8, 8),
            LunarDate(month = 6, day = 15, isLeapMonth = true),
        )

        assertEquals("农历闰六月十五", rendered.lunarDate)
        assertNull(rendered.annotation)
    }

    private data class TestCase(
        val date: String,
        val lunarDate: LunarDate,
        val lunarText: String,
        val annotation: String,
    )
}
