package com.wootodo.display

import android.content.Context
import java.time.LocalDate
import java.time.temporal.ChronoUnit

data class DayCounterSettings(
    val enabled: Boolean = false,
    val title: String = "",
    val startDate: LocalDate = LocalDate.now(),
)

object DayCounterText {
    fun format(settings: DayCounterSettings, today: LocalDate = LocalDate.now()): String? {
        val title = settings.title.trim()
        if (!settings.enabled || title.isEmpty() || today.isBefore(settings.startDate)) return null
        val day = ChronoUnit.DAYS.between(settings.startDate, today) + 1
        return "$title · 第 $day 天"
    }
}

object DayCounterPreferences {
    private const val FILE_NAME = "display_preferences"
    private const val KEY_ENABLED = "day_counter_enabled"
    private const val KEY_TITLE = "day_counter_title"
    private const val KEY_START_DATE = "day_counter_start_date"

    fun load(context: Context): DayCounterSettings {
        val preferences = context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
        val startDate = preferences.getString(KEY_START_DATE, null)
            ?.let { value -> runCatching { LocalDate.parse(value) }.getOrNull() }
            ?: LocalDate.now()
        return DayCounterSettings(
            enabled = preferences.getBoolean(KEY_ENABLED, false),
            title = preferences.getString(KEY_TITLE, "").orEmpty(),
            startDate = startDate,
        )
    }

    fun save(context: Context, settings: DayCounterSettings) {
        val title = settings.title.trim().take(80)
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ENABLED, settings.enabled && title.isNotEmpty())
            .putString(KEY_TITLE, title)
            .putString(KEY_START_DATE, settings.startDate.toString())
            .apply()
    }

    fun displayText(context: Context, today: LocalDate = LocalDate.now()): String? =
        DayCounterText.format(load(context), today)
}
