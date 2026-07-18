package com.wootodo.domain

import java.time.LocalDate

object TaskListDatePolicy {
    fun referenceDate(
        scope: TaskTimeType,
        showTomorrow: Boolean,
        today: LocalDate,
    ): LocalDate = if (scope == TaskTimeType.DAY && showTomorrow) {
        today.plusDays(1)
    } else {
        today
    }
}
