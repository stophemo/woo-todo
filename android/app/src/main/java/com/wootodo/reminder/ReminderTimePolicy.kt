package com.wootodo.reminder

import java.time.LocalDate
import java.time.LocalTime
import java.time.ZonedDateTime

object ReminderTimePolicy {
    val defaultReminderTime: LocalTime = LocalTime.of(23, 10)

    fun nextTrigger(
        now: ZonedDateTime,
        lastHandledDate: LocalDate?,
        reminderTime: LocalTime = defaultReminderTime,
    ): ZonedDateTime {
        val todayTrigger = now.toLocalDate().atTime(reminderTime).atZone(now.zone)
        return when {
            lastHandledDate == now.toLocalDate() ->
                now.toLocalDate().plusDays(1).atTime(reminderTime).atZone(now.zone)
            now.isBefore(todayTrigger) -> todayTrigger
            else -> now.plusSeconds(5)
        }
    }
}
