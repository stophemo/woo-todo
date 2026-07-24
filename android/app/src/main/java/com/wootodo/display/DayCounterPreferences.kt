package com.wootodo.display

import android.content.Context
import java.time.LocalDate
import java.time.Period
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

data class DayCounterSettings(
    val headerTemplate: String = DayCounterText.DEFAULT_HEADER_TEMPLATE,
    val subtitleTemplate: String = "",
    val startDate: LocalDate = LocalDate.now(),
    val deadlineDate: LocalDate = LocalDate.now(),
) {
    constructor(enabled: Boolean, title: String, startDate: LocalDate) : this(
        subtitleTemplate = title.trim().takeIf { enabled && it.isNotEmpty() }
            ?.let { "$it · 第 ${DayCounterText.ELAPSED_DAYS_TOKEN} 天" }
            .orEmpty(),
        startDate = startDate,
    )
}

data class DayCounterRenderResult(
    val header: String?,
    val subtitle: String?,
)

object DayCounterText {
    const val DEFAULT_HEADER_TEMPLATE = "今日任务"
    const val WEEKDAY_TOKEN = "{weekday}"
    const val WEEKDAY_SHORT_TOKEN = "{weekdayShort}"
    const val WEEKDAY_EN_TOKEN = "{weekdayEn}"
    const val WEEKDAY_EN_SHORT_TOKEN = "{weekdayEnShort}"
    const val DATE_TOKEN = "{date}"
    const val DATE_LONG_TOKEN = "{dateLong}"
    const val YEAR_TOKEN = "{year}"
    const val MONTH_TOKEN = "{month}"
    const val MONTH_PADDED_TOKEN = "{monthPadded}"
    const val DAY_TOKEN = "{day}"
    const val DAY_PADDED_TOKEN = "{dayPadded}"
    const val START_DATE_TOKEN = "{startDate}"
    const val DEADLINE_DATE_TOKEN = "{deadlineDate}"
    const val ELAPSED_DAYS_TOKEN = "{elapsedDays}"
    const val DEADLINE_DAYS_TOKEN = "{deadlineDays}"
    const val ELAPSED_MONTHS_DAYS_TOKEN = "{elapsedMonthsDays}"
    const val DEADLINE_MONTHS_DAYS_TOKEN = "{deadlineMonthsDays}"

    fun render(
        settings: DayCounterSettings,
        today: LocalDate = LocalDate.now(),
    ): DayCounterRenderResult {
        val elapsedDays = (ChronoUnit.DAYS.between(settings.startDate, today) + 1)
            .coerceAtLeast(0)
        val deadlineDays = ChronoUnit.DAYS.between(today, settings.deadlineDate)
        val elapsedMonthsDays = if (today.isBefore(settings.startDate)) {
            ZERO_MONTHS_DAYS
        } else {
            monthsDays(settings.startDate, today.plusDays(1))
        }
        val deadlineMonthsDays = monthsDays(today, settings.deadlineDate)
        val weekdayIndex = today.dayOfWeek.value - 1
        val date = today.format(DATE_FORMAT)
        val dateLong = today.format(DATE_LONG_FORMAT)
        val values = mapOf(
            WEEKDAY_TOKEN to WEEKDAYS[weekdayIndex],
            WEEKDAY_SHORT_TOKEN to WEEKDAY_SHORT[weekdayIndex],
            WEEKDAY_EN_TOKEN to WEEKDAYS_EN[weekdayIndex],
            WEEKDAY_EN_SHORT_TOKEN to WEEKDAYS_EN_SHORT[weekdayIndex],
            DATE_TOKEN to date,
            DATE_LONG_TOKEN to dateLong,
            YEAR_TOKEN to today.year.toString(),
            MONTH_TOKEN to today.monthValue.toString(),
            MONTH_PADDED_TOKEN to today.monthValue.toString().padStart(2, '0'),
            DAY_TOKEN to today.dayOfMonth.toString(),
            DAY_PADDED_TOKEN to today.dayOfMonth.toString().padStart(2, '0'),
            START_DATE_TOKEN to settings.startDate.format(DATE_FORMAT),
            DEADLINE_DATE_TOKEN to settings.deadlineDate.format(DATE_FORMAT),
            ELAPSED_DAYS_TOKEN to elapsedDays.toString(),
            DEADLINE_DAYS_TOKEN to deadlineDays.toString(),
            ELAPSED_MONTHS_DAYS_TOKEN to elapsedMonthsDays,
            DEADLINE_MONTHS_DAYS_TOKEN to deadlineMonthsDays,
        )

        fun renderTemplate(template: String): String? = template.trim()
            .takeIf(String::isNotEmpty)
            ?.let { source ->
                values.entries.fold(source) { rendered, (token, value) ->
                    rendered.replace(token, value)
                }
            }

        return DayCounterRenderResult(
            header = renderTemplate(settings.headerTemplate),
            subtitle = renderTemplate(settings.subtitleTemplate),
        )
    }

    fun format(settings: DayCounterSettings, today: LocalDate = LocalDate.now()): String? =
        render(settings, today).subtitle

    private val WEEKDAYS = listOf(
        "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日",
    )
    private val WEEKDAY_SHORT = listOf("一", "二", "三", "四", "五", "六", "日")
    private val WEEKDAYS_EN = listOf(
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    )
    private val WEEKDAYS_EN_SHORT = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
    private val DATE_FORMAT = DateTimeFormatter.ISO_LOCAL_DATE
    private val DATE_LONG_FORMAT = DateTimeFormatter.ofPattern("yyyy年M月d日")
    private const val ZERO_MONTHS_DAYS = "0个月零0天"

    private fun monthsDays(source: LocalDate, destination: LocalDate): String {
        if (source == destination) return ZERO_MONTHS_DAYS
        val isNegative = destination.isBefore(source)
        val earlier = if (isNegative) destination else source
        val later = if (isNegative) source else destination
        val period = Period.between(earlier, later)
        val months = period.years * 12 + period.months
        val sign = if (isNegative) "-" else ""
        return "$sign${months}个月零${period.days}天"
    }
}

object DayCounterPreferences {
    private const val FILE_NAME = "display_preferences"
    private const val KEY_CONFIGURATION_VERSION = "today_template_configuration_version"
    private const val KEY_HEADER_TEMPLATE = "today_header_template"
    private const val KEY_SUBTITLE_TEMPLATE = "today_subtitle_template"
    private const val KEY_START_DATE = "today_template_start_date"
    private const val KEY_DEADLINE_DATE = "today_template_deadline_date"

    private const val LEGACY_KEY_ENABLED = "day_counter_enabled"
    private const val LEGACY_KEY_TITLE = "day_counter_title"
    private const val LEGACY_KEY_START_DATE = "day_counter_start_date"
    private const val CURRENT_CONFIGURATION_VERSION = 1

    fun load(context: Context): DayCounterSettings {
        val preferences = context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
        val today = LocalDate.now()
        val headerTemplate = preferences.getString(KEY_HEADER_TEMPLATE, null)
        val subtitleTemplate = preferences.getString(KEY_SUBTITLE_TEMPLATE, null)
        val startDate = preferences.getString(KEY_START_DATE, null)?.let(::parseDateOrNull)
        val deadlineDate = preferences.getString(KEY_DEADLINE_DATE, null)?.let(::parseDateOrNull)
        val complete = preferences.getInt(KEY_CONFIGURATION_VERSION, 0) ==
            CURRENT_CONFIGURATION_VERSION && headerTemplate != null && subtitleTemplate != null &&
            startDate != null && deadlineDate != null
        if (complete) {
            return DayCounterSettings(
                headerTemplate = requireNotNull(headerTemplate),
                subtitleTemplate = requireNotNull(subtitleTemplate),
                startDate = requireNotNull(startDate),
                deadlineDate = requireNotNull(deadlineDate),
            )
        }

        val legacyStartDate = parseDate(
            preferences.getString(LEGACY_KEY_START_DATE, null),
            today,
        )
        val fallback = DayCounterSettings(
            enabled = preferences.getBoolean(LEGACY_KEY_ENABLED, false),
            title = preferences.getString(LEGACY_KEY_TITLE, "").orEmpty(),
            startDate = legacyStartDate,
        )
        return DayCounterSettings(
            headerTemplate = headerTemplate ?: fallback.headerTemplate,
            subtitleTemplate = subtitleTemplate ?: fallback.subtitleTemplate,
            startDate = startDate ?: fallback.startDate,
            deadlineDate = deadlineDate ?: startDate ?: fallback.startDate,
        ).also { save(context, it) }
    }

    fun save(context: Context, settings: DayCounterSettings) {
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_HEADER_TEMPLATE, normalize(settings.headerTemplate, 80))
            .putString(KEY_SUBTITLE_TEMPLATE, normalize(settings.subtitleTemplate, 160))
            .putString(KEY_START_DATE, settings.startDate.toString())
            .putString(KEY_DEADLINE_DATE, settings.deadlineDate.toString())
            .putInt(KEY_CONFIGURATION_VERSION, CURRENT_CONFIGURATION_VERSION)
            .apply()
    }

    fun render(
        context: Context,
        today: LocalDate = LocalDate.now(),
    ): DayCounterRenderResult = DayCounterText.render(load(context), today)

    fun displayText(context: Context, today: LocalDate = LocalDate.now()): String? =
        render(context, today).subtitle

    private fun normalize(value: String, limit: Int): String = value
        .replace('\r', ' ')
        .replace('\n', ' ')
        .trim()
        .take(limit)

    private fun parseDate(value: String?, fallback: LocalDate): LocalDate = value
        ?.let(::parseDateOrNull)
        ?: fallback

    private fun parseDateOrNull(value: String): LocalDate? =
        runCatching { LocalDate.parse(value) }.getOrNull()
}
