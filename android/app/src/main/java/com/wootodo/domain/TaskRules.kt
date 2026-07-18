package com.wootodo.domain

import java.time.DayOfWeek
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

object TaskDateRules {
    val zoneId: ZoneId = ZoneId.of("Asia/Shanghai")

    fun today(): LocalDate = LocalDate.now(zoneId)

    fun normalizeTargetDate(timeType: TaskTimeType, date: LocalDate): LocalDate? =
        when (timeType) {
            TaskTimeType.DAY -> date
            TaskTimeType.WEEK -> date.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
            TaskTimeType.MONTH -> date.withDayOfMonth(1)
            TaskTimeType.LEISURE -> null
        }

    fun targetForScope(timeType: TaskTimeType, referenceDate: LocalDate): LocalDate? =
        normalizeTargetDate(timeType, referenceDate)

    fun nextOccurrenceDate(date: LocalDate, recurrence: Recurrence): LocalDate? =
        when (recurrence) {
            Recurrence.ONCE -> null
            Recurrence.DAILY -> date.plusDays(1)
            Recurrence.WEEKLY -> date.plusWeeks(1)
            Recurrence.MONTHLY -> date.plusMonths(1)
        }
}

object TaskRules {
    fun allowedRecurrences(timeType: TaskTimeType): List<Recurrence> =
        when (timeType) {
            TaskTimeType.DAY -> listOf(Recurrence.ONCE, Recurrence.DAILY)
            TaskTimeType.WEEK -> listOf(Recurrence.ONCE, Recurrence.WEEKLY)
            TaskTimeType.MONTH -> listOf(Recurrence.ONCE, Recurrence.MONTHLY)
            TaskTimeType.LEISURE -> listOf(Recurrence.ONCE)
        }

    fun sanitizeRecurrence(timeType: TaskTimeType, recurrence: Recurrence): Recurrence =
        recurrence.takeIf { it in allowedRecurrences(timeType) } ?: Recurrence.ONCE

    val ordering: Comparator<Task> =
        compareBy<Task> { questRank(it.questLine) }
            .thenBy { statusRank(it.status) }
            .thenBy { it.sortOrder }
            .thenBy { it.createdAt }
            .thenBy { it.id }

    private fun questRank(line: QuestLine): Int =
        when (line) {
            QuestLine.MAIN -> 0
            QuestLine.SIDE -> 1
            QuestLine.EXTRA -> 2
        }

    private fun statusRank(status: TaskStatus): Int =
        when (status) {
            TaskStatus.PENDING -> 0
            TaskStatus.COMPLETED -> 1
            TaskStatus.PASS -> 2
        }
}
