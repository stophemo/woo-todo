package com.wootodo.display

import android.icu.util.Calendar
import android.icu.util.ChineseCalendar
import android.icu.util.TimeZone
import com.wootodo.domain.TaskDateRules
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.roundToLong

data class TraditionalCalendarRenderResult(
    val lunarDate: String,
    val annotation: String?,
)

internal data class LunarDate(
    val month: Int,
    val day: Int,
    val isLeapMonth: Boolean = false,
)

object TraditionalCalendarInfo {
    fun render(date: LocalDate = TaskDateRules.today()): TraditionalCalendarRenderResult =
        render(
            date = date,
            lunarDate = AndroidLunarDateConverter.convert(date),
            nextLunarDate = AndroidLunarDateConverter.convert(date.plusDays(1)),
        )

    internal fun render(
        date: LocalDate,
        lunarDate: LunarDate,
        nextLunarDate: LunarDate? = null,
    ): TraditionalCalendarRenderResult {
        val lunarText = buildString {
            append("农历")
            if (lunarDate.isLeapMonth) append("闰")
            append(LUNAR_MONTHS.getOrNull(lunarDate.month - 1) ?: lunarDate.month.toString())
            append("月")
            append(LUNAR_DAYS.getOrNull(lunarDate.day - 1) ?: lunarDate.day.toString())
        }
        val notes = listOfNotNull(
            solarTerm(date),
            lunarFestival(lunarDate, nextLunarDate),
            SOLAR_FESTIVALS[festivalKey(date.monthValue, date.dayOfMonth)],
        ).distinct()

        return TraditionalCalendarRenderResult(
            lunarDate = lunarText,
            annotation = notes.takeIf(List<String>::isNotEmpty)?.joinToString(" · "),
        )
    }

    private fun lunarFestival(date: LunarDate, nextDate: LunarDate?): String? {
        if (date.isLeapMonth) return null
        if (nextDate?.month == 1 && nextDate.day == 1 && !nextDate.isLeapMonth) {
            return "除夕"
        }
        return LUNAR_FESTIVALS[festivalKey(date.month, date.day)]
    }

    private fun solarTerm(date: LocalDate): String? {
        if (date.year !in 1900..2100) return null
        return SOLAR_TERMS.firstOrNull { term ->
            val offset = TROPICAL_YEAR_MILLISECONDS * (date.year - 1900) +
                term.minutes * 60_000.0
            val termDate = Instant.ofEpochMilli(
                BASE_SOLAR_TERM.toEpochMilli() + offset.roundToLong(),
            ).atZone(ZoneOffset.UTC).toLocalDate()
            termDate.monthValue == date.monthValue && termDate.dayOfMonth == date.dayOfMonth
        }?.name
    }

    private fun festivalKey(month: Int, day: Int): Int = month * 100 + day

    private data class SolarTerm(val name: String, val minutes: Int)

    private val LUNAR_MONTHS = listOf(
        "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊",
    )
    private val LUNAR_DAYS = listOf(
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    )
    private val LUNAR_FESTIVALS = mapOf(
        festivalKey(1, 1) to "春节",
        festivalKey(1, 15) to "元宵节",
        festivalKey(2, 2) to "龙抬头",
        festivalKey(5, 5) to "端午节",
        festivalKey(7, 7) to "七夕",
        festivalKey(7, 15) to "中元节",
        festivalKey(8, 15) to "中秋节",
        festivalKey(9, 9) to "重阳节",
        festivalKey(12, 8) to "腊八节",
    )
    private val SOLAR_FESTIVALS = mapOf(
        festivalKey(1, 1) to "元旦",
        festivalKey(3, 8) to "妇女节",
        festivalKey(5, 1) to "劳动节",
        festivalKey(5, 4) to "青年节",
        festivalKey(6, 1) to "儿童节",
        festivalKey(10, 1) to "国庆节",
    )
    private val SOLAR_TERMS = listOf(
        SolarTerm("小寒", 0), SolarTerm("大寒", 21_208),
        SolarTerm("立春", 42_467), SolarTerm("雨水", 63_836),
        SolarTerm("惊蛰", 85_337), SolarTerm("春分", 107_014),
        SolarTerm("清明", 128_867), SolarTerm("谷雨", 150_921),
        SolarTerm("立夏", 173_149), SolarTerm("小满", 195_551),
        SolarTerm("芒种", 218_072), SolarTerm("夏至", 240_693),
        SolarTerm("小暑", 263_343), SolarTerm("大暑", 285_989),
        SolarTerm("立秋", 308_563), SolarTerm("处暑", 331_033),
        SolarTerm("白露", 353_350), SolarTerm("秋分", 375_494),
        SolarTerm("寒露", 397_447), SolarTerm("霜降", 419_210),
        SolarTerm("立冬", 440_795), SolarTerm("小雪", 462_224),
        SolarTerm("大雪", 483_532), SolarTerm("冬至", 504_758),
    )
    private val BASE_SOLAR_TERM = Instant.parse("1900-01-06T02:05:00Z")
    private const val TROPICAL_YEAR_MILLISECONDS = 31_556_925_974.7
}

private object AndroidLunarDateConverter {
    fun convert(date: LocalDate): LunarDate {
        val calendar = ChineseCalendar(TimeZone.getTimeZone(TaskDateRules.zoneId.id))
        calendar.timeInMillis = date.atStartOfDay(TaskDateRules.zoneId).toInstant().toEpochMilli()
        return LunarDate(
            month = calendar.get(Calendar.MONTH) + 1,
            day = calendar.get(Calendar.DAY_OF_MONTH),
            isLeapMonth = calendar.get(Calendar.IS_LEAP_MONTH) == 1,
        )
    }
}
