package com.wootodo.data

import com.wootodo.domain.Task
import com.wootodo.domain.TaskRecurrence
import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import java.time.LocalTime

data class TaskEntity(
    val id: String,
    val seriesId: String,
    val title: String,
    val categoryId: String,
    val startDate: LocalDate?,
    val endDate: LocalDate?,
    val status: TaskStatus,
    val sortOrder: Int,
    val createdAt: Long,
    val updatedAt: Long,
    val settledAt: Long?,
    val reminderTime: LocalTime? = null,
    val recurrence: TaskRecurrence = TaskRecurrence.ONCE,
)

data class TrashedTaskEntity(
    val task: TaskEntity,
    val deletedAt: Long,
)

fun TaskEntity.toDomain(): Task =
    Task(
        id = id,
        seriesId = seriesId,
        title = title,
        categoryId = categoryId,
        startDate = startDate,
        endDate = endDate,
        status = status,
        sortOrder = sortOrder,
        createdAt = createdAt,
        updatedAt = updatedAt,
        settledAt = settledAt,
        reminderTime = reminderTime,
        recurrence = recurrence,
    )
