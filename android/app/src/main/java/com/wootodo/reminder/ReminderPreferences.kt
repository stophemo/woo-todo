package com.wootodo.reminder

import android.content.Context
import java.time.LocalDate

object ReminderPreferences {
    private const val PREFERENCES = "planning_reminder"
    private const val ENABLED = "enabled"
    private const val HOUR = "hour"
    private const val MINUTE = "minute"
    private const val LAST_HANDLED_DATE = "last_handled_date"

    fun load(context: Context): ReminderSettings {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        return ReminderSettings(
            enabled = preferences.getBoolean(ENABLED, true),
            hour = preferences.getInt(HOUR, 23),
            minute = preferences.getInt(MINUTE, 10),
        )
    }

    fun save(context: Context, settings: ReminderSettings) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(ENABLED, settings.enabled)
            .putInt(HOUR, settings.hour)
            .putInt(MINUTE, settings.minute)
            .apply()
    }

    fun markHandled(context: Context, date: LocalDate) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putString(LAST_HANDLED_DATE, date.toString())
            .apply()
    }

    fun lastHandledDate(context: Context): LocalDate? =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getString(LAST_HANDLED_DATE, null)
            ?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
}
