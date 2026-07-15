package com.wootodo.domain

import java.time.LocalDate

data class StatusCounts(
    val completed: Int = 0,
    val pass: Int = 0,
    val pending: Int = 0,
) {
    val total: Int get() = completed + pass + pending

    fun add(status: TaskStatus): StatusCounts =
        when (status) {
            TaskStatus.COMPLETED -> copy(completed = completed + 1)
            TaskStatus.PASS -> copy(pass = pass + 1)
            TaskStatus.PENDING -> copy(pending = pending + 1)
        }
}

data class TrendBucket(
    val startDate: LocalDate,
    val endDateExclusive: LocalDate,
    val completed: Int = 0,
    val pass: Int = 0,
    val isEnded: Boolean,
) {
    /** 样本数与履约率分母一致，不包含异常未结算的待办记录。 */
    val sampleCount: Int get() = completed + pass

    /** 当前周期尚未结束时不生成履约率，避免用阶段进度冒充最终结果。 */
    val fulfillmentRate: Double?
        get() = if (isEnded && sampleCount > 0) completed.toDouble() / sampleCount else null
}

data class StatisticsSnapshot(
    val endedPeriodFulfillmentRate: Double?,
    val mainQuestFulfillmentRate: Double?,
    val byTimeType: Map<TaskTimeType, StatusCounts>,
    val byQuestLine: Map<QuestLine, StatusCounts>,
    val dailyTrend: List<TrendBucket>,
    val weeklyTrend: List<TrendBucket>,
    val monthlyTrend: List<TrendBucket>,
    val recentHistory: List<Task>,
)

object StatisticsEngine {
    fun calculate(
        tasks: List<Task>,
        referenceDate: LocalDate,
        recentHistoryLimit: Int = 20,
    ): StatisticsSnapshot {
        require(recentHistoryLimit >= 0)
        val endedTasks = tasks.filter { task ->
            isEndedPeriod(task, referenceDate) && task.status != TaskStatus.PENDING
        }
        val mainEndedTasks = endedTasks.filter { it.questLine == QuestLine.MAIN }
        return StatisticsSnapshot(
            endedPeriodFulfillmentRate = fulfillmentRate(endedTasks),
            mainQuestFulfillmentRate = fulfillmentRate(mainEndedTasks),
            byTimeType = TaskTimeType.entries.associateWith { type ->
                tasks.asSequence()
                    .filter { it.timeType == type }
                    .fold(StatusCounts()) { counts, task -> counts.add(task.status) }
            },
            byQuestLine = QuestLine.entries.associateWith { line ->
                tasks.asSequence()
                    .filter { it.questLine == line }
                    .fold(StatusCounts()) { counts, task -> counts.add(task.status) }
            },
            dailyTrend = trend(tasks, TaskTimeType.DAY, 7, referenceDate),
            weeklyTrend = trend(tasks, TaskTimeType.WEEK, 8, referenceDate),
            monthlyTrend = trend(tasks, TaskTimeType.MONTH, 6, referenceDate),
            recentHistory = tasks.asSequence()
                .filter { it.status != TaskStatus.PENDING && it.settledAt != null }
                .sortedWith(
                    compareByDescending<Task> { it.settledAt }
                        .thenByDescending { it.updatedAt }
                        .thenBy { it.id },
                )
                .take(recentHistoryLimit)
                .toList(),
        )
    }

    fun isEndedPeriod(task: Task, referenceDate: LocalDate): Boolean {
        val targetDate = task.targetDate ?: return false
        val cutoff = when (task.timeType) {
            TaskTimeType.DAY -> referenceDate
            TaskTimeType.WEEK -> TaskDateRules.normalizeTargetDate(TaskTimeType.WEEK, referenceDate)
            TaskTimeType.MONTH -> TaskDateRules.normalizeTargetDate(TaskTimeType.MONTH, referenceDate)
            TaskTimeType.LEISURE -> null
        } ?: return false
        return targetDate.isBefore(cutoff)
    }

    private fun trend(
        tasks: List<Task>,
        timeType: TaskTimeType,
        bucketCount: Int,
        referenceDate: LocalDate,
    ): List<TrendBucket> {
        val currentStart = TaskDateRules.normalizeTargetDate(timeType, referenceDate)
            ?: return emptyList()
        val outcomesByStart = tasks.asSequence()
            .filter { task ->
                task.timeType == timeType &&
                    task.targetDate != null &&
                    task.status != TaskStatus.PENDING
            }
            .groupBy { task ->
                TaskDateRules.normalizeTargetDate(timeType, task.targetDate!!)
            }

        return (bucketCount - 1 downTo 0).map { offset ->
            val start = offsetStart(currentStart, timeType, offset)
            val end = nextStart(start, timeType)
            val outcomes = outcomesByStart[start].orEmpty()
            TrendBucket(
                startDate = start,
                endDateExclusive = end,
                completed = outcomes.count { it.status == TaskStatus.COMPLETED },
                pass = outcomes.count { it.status == TaskStatus.PASS },
                isEnded = !end.isAfter(referenceDate),
            )
        }
    }

    private fun offsetStart(start: LocalDate, timeType: TaskTimeType, offset: Int): LocalDate =
        when (timeType) {
            TaskTimeType.DAY -> start.minusDays(offset.toLong())
            TaskTimeType.WEEK -> start.minusWeeks(offset.toLong())
            TaskTimeType.MONTH -> start.minusMonths(offset.toLong())
            TaskTimeType.LEISURE -> start
        }

    private fun nextStart(start: LocalDate, timeType: TaskTimeType): LocalDate =
        when (timeType) {
            TaskTimeType.DAY -> start.plusDays(1)
            TaskTimeType.WEEK -> start.plusWeeks(1)
            TaskTimeType.MONTH -> start.plusMonths(1)
            TaskTimeType.LEISURE -> start
        }

    private fun fulfillmentRate(tasks: List<Task>): Double? =
        tasks.takeIf { it.isNotEmpty() }
            ?.let { ended -> ended.count { it.status == TaskStatus.COMPLETED }.toDouble() / ended.size }
}
