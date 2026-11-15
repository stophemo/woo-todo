package com.wootodo.domain

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** 任务与日期的关系判断，列表、Widget、提醒和统计共用。 */
object TaskDateState {
    fun isOverdue(task: Task, today: LocalDate): Boolean =
        task.status == TaskStatus.PENDING &&
            task.endDate?.isBefore(today) == true

    fun isActiveOn(task: Task, date: LocalDate): Boolean {
        val start = task.startDate ?: return false
        val end = task.endDate ?: return false
        return !date.isBefore(start) && !date.isAfter(end)
    }

    fun isRelevantOn(task: Task, date: LocalDate): Boolean {
        if (task.status != TaskStatus.PENDING) return false
        if (task.startDate == null && task.endDate == null) return true
        return isOverdue(task, date) || isActiveOn(task, date)
    }

    fun isSettledOn(task: Task, date: LocalDate, zoneId: ZoneId): Boolean {
        if (task.status == TaskStatus.PENDING) return false
        val settledAt = task.settledAt ?: return false
        return Instant.ofEpochMilli(settledAt).atZone(zoneId).toLocalDate() == date
    }
}
