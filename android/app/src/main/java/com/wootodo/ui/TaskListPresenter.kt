package com.wootodo.ui

import androidx.annotation.StringRes
import com.wootodo.R
import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskDateState
import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import java.time.ZoneId

enum class TaskSectionKind(@StringRes val titleRes: Int) {
    OVERDUE(R.string.section_overdue),
    TODAY(R.string.section_today),
    UPCOMING(R.string.section_upcoming),
    UNSCHEDULED(R.string.section_unscheduled),
    SETTLED_TODAY(R.string.section_settled_today),
}

data class TaskListSection(
    val kind: TaskSectionKind,
    val tasks: List<Task>,
)

object TaskListPresenter {
    fun sections(
        tasks: List<Task>,
        categories: List<TaskCategory>,
        today: LocalDate,
        zoneId: ZoneId = TaskDateRules.zoneId,
    ): List<TaskListSection> {
        val categoryOrder = categories.associate { it.id to it.order }
        val pending = tasks.filter { it.status == TaskStatus.PENDING }
        val overdue = pending.filter { TaskDateState.isOverdue(it, today) }
        val todayTasks = pending.filter {
            !TaskDateState.isOverdue(it, today) && TaskDateState.isActiveOn(it, today)
        }
        val upcoming = pending.filter {
            it.startDate != null && it.startDate.isAfter(today)
        }
        val unscheduled = pending.filter {
            it.startDate == null && it.endDate == null
        }
        val settledToday = tasks.filter { task ->
            task.status != TaskStatus.PENDING &&
                TaskDateState.isSettledOn(task, today, zoneId)
        }
        fun order(values: List<Task>): List<Task> = values.sortedWith(
            compareBy<Task> { it.endDate ?: LocalDate.MAX }
                .thenBy { categoryOrder[it.categoryId] ?: Int.MAX_VALUE }
                .thenBy { it.sortOrder }
                .thenBy { it.createdAt }
                .thenBy { it.id },
        )

        return buildList {
            fun add(kind: TaskSectionKind, values: List<Task>) {
                if (values.isNotEmpty()) add(TaskListSection(kind, order(values)))
            }
            add(TaskSectionKind.OVERDUE, overdue)
            add(TaskSectionKind.TODAY, todayTasks)
            add(TaskSectionKind.UPCOMING, upcoming)
            add(TaskSectionKind.UNSCHEDULED, unscheduled)
            add(TaskSectionKind.SETTLED_TODAY, settledToday)
        }
    }
}
