package com.wootodo.domain

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

data class DayActivity(
    val date: LocalDate,
    val completed: Int,
)

data class CategoryActivity(
    val categoryId: String,
    val completed: Int,
    val ratio: Double,
)

data class StatisticsSnapshot(
    val completedThisWeek: Int,
    val currentStreakDays: Int,
    val onTimeRate: Double?,
    val pendingCount: Int,
    val dailyActivity: List<DayActivity>,
    val categoryActivity: List<CategoryActivity>,
    val recentHistory: List<Task>,
)

object StatisticsEngine {
    private const val ACTIVITY_DAYS = 14
    private const val CATEGORY_DAYS = 30

    fun calculate(
        tasks: List<Task>,
        referenceDate: LocalDate,
        zoneId: ZoneId = TaskDateRules.zoneId,
        recentHistoryLimit: Int = Int.MAX_VALUE,
    ): StatisticsSnapshot {
        require(recentHistoryLimit >= 0)
        val completionDates = tasks
            .filter { it.status == TaskStatus.COMPLETED }
            .mapNotNull { task -> completionDate(task, zoneId)?.let { task to it } }
            .toMap()
        val completedWithDate = completionDates.keys.toList()
        val weekStart = referenceDate.with(
            TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY),
        )
        val completedThisWeek = completedWithDate.count { task ->
            val date = completionDates.getValue(task)
            !date.isBefore(weekStart) && !date.isAfter(referenceDate)
        }
        val completedDates = completedWithDate.mapNotNull { completionDates[it] }.toSet()
        val streak = currentStreak(completedDates, referenceDate)

        val onTimeSamples = completedWithDate.filter { it.endDate != null }
        val onTimeRate = if (onTimeSamples.isEmpty()) {
            null
        } else {
            val onTime = onTimeSamples.count { task ->
                val date = completionDates.getValue(task)
                !date.isAfter(requireNotNull(task.endDate))
            }
            onTime.toDouble() / onTimeSamples.size
        }

        val dailyActivity = (ACTIVITY_DAYS - 1 downTo 0).map { offset ->
            val date = referenceDate.minusDays(offset.toLong())
            DayActivity(
                date = date,
                completed = completedWithDate.count { completionDates[it] == date },
            )
        }

        val categoryStart = referenceDate.minusDays((CATEGORY_DAYS - 1).toLong())
        val recentCompleted = completedWithDate.filter { task ->
            val date = completionDates.getValue(task)
            !date.isBefore(categoryStart) && !date.isAfter(referenceDate)
        }
        val categoryActivity = recentCompleted
            .groupingBy(Task::categoryId)
            .eachCount()
            .map { (categoryId, count) ->
                CategoryActivity(
                    categoryId = categoryId,
                    completed = count,
                    ratio = if (recentCompleted.isEmpty()) {
                        0.0
                    } else {
                        count.toDouble() / recentCompleted.size
                    },
                )
            }
            .sortedWith(compareByDescending<CategoryActivity> { it.completed }.thenBy { it.categoryId })

        val history = tasks
            .filter { it.status != TaskStatus.PENDING && it.settledAt != null }
            .sortedWith(
                compareByDescending<Task> { it.settledAt }
                    .thenByDescending { it.updatedAt }
                    .thenBy { it.id },
            )
            .take(recentHistoryLimit)

        return StatisticsSnapshot(
            completedThisWeek = completedThisWeek,
            currentStreakDays = streak,
            onTimeRate = onTimeRate,
            pendingCount = tasks.count { it.status == TaskStatus.PENDING },
            dailyActivity = dailyActivity,
            categoryActivity = categoryActivity,
            recentHistory = history,
        )
    }

    private fun completionDate(task: Task, zoneId: ZoneId): LocalDate? =
        task.settledAt?.let {
            Instant.ofEpochMilli(it).atZone(zoneId).toLocalDate()
        }

    private fun currentStreak(completedDates: Set<LocalDate>, today: LocalDate): Int {
        val start = when {
            today in completedDates -> today
            today.minusDays(1) in completedDates -> today.minusDays(1)
            else -> return 0
        }
        var cursor = start
        var count = 0
        while (cursor in completedDates) {
            count += 1
            cursor = cursor.minusDays(1)
        }
        return count
    }
}
