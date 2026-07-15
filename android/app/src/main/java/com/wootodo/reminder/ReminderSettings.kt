package com.wootodo.reminder

import java.time.LocalTime

data class ReminderSettings(
    val enabled: Boolean = true,
    val hour: Int = 23,
    val minute: Int = 10,
) {
    init {
        require(hour in 0..23)
        require(minute in 0..59)
    }

    val time: LocalTime get() = LocalTime.of(hour, minute)
}
