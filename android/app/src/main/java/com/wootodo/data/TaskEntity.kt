package com.wootodo.data

import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.Task
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.LocalDate
import java.time.LocalTime

data class TaskEntity(
    val id: String,
    val seriesId: String,
    val title: String,
    val timeType: TaskTimeType,
    val targetDate: LocalDate?,
    val questLine: QuestLine,
    val status: TaskStatus,
    val recurrence: Recurrence,
    val sortOrder: Int,
    val createdAt: Long,
    val updatedAt: Long,
    val settledAt: Long?,
    val reminderTime: LocalTime? = null,
)

fun TaskEntity.toDomain(): Task =
    Task(
        id = id,
        seriesId = seriesId,
        title = title,
        timeType = timeType,
        targetDate = targetDate,
        questLine = questLine,
        status = status,
        recurrence = recurrence,
        sortOrder = sortOrder,
        createdAt = createdAt,
        updatedAt = updatedAt,
        settledAt = settledAt,
        reminderTime = reminderTime,
    )
