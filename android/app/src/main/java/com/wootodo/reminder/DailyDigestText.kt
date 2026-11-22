package com.wootodo.reminder

import com.wootodo.domain.Task
import com.wootodo.domain.TaskDateState
import com.wootodo.domain.TaskRecurrence
import com.wootodo.domain.TaskStatus
import java.time.LocalDate

data class DailyDigestSummary(
    val count: Int,
    val titles: List<String>,
)

object DailyDigestText {
    /** 汇总明天正在进行或已经逾期的待办；无日期任务不进入晚间提醒。 */
    fun summary(tasks: List<Task>, today: LocalDate): DailyDigestSummary {
        val tomorrow = today.plusDays(1)
        val selected = tasks
            .filter { task ->
                task.status == TaskStatus.PENDING &&
                    (
                        TaskDateState.isActiveOn(task, tomorrow) ||
                            TaskDateState.isOverdue(task, tomorrow)
                        )
            }
            .sortedWith(
                compareBy<Task> { it.startDate ?: LocalDate.MAX }
                    .thenBy { it.endDate ?: LocalDate.MAX }
                    .thenBy { it.createdAt }
                    .thenBy { it.id },
            )
            .toMutableList()

        // 每天重复任务的下一条通常要等当天结算后才生成；晚间汇总提前补上它的明日占位。
        val representedSeries = selected.mapTo(mutableSetOf()) { it.seriesId }
        val latestDailyBySeries = tasks
            .filter { task ->
                task.recurrence == TaskRecurrence.DAILY &&
                    task.startDate?.isAfter(today) == false
            }
            .groupBy(Task::seriesId)
            .mapValues { (_, occurrences) ->
                occurrences.maxBy { it.startDate ?: LocalDate.MIN }
            }
        latestDailyBySeries.values
            .filterNot { it.seriesId in representedSeries }
            .sortedWith(
                compareBy<Task> { it.createdAt }
                    .thenBy { it.id },
            )
            .forEach(selected::add)

        return DailyDigestSummary(
            count = selected.size,
            titles = selected.take(3).map(Task::title),
        )
    }
}
