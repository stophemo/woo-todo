package com.wootodo.domain

import java.time.LocalDate

enum class TaskTimeType(val rawValue: String) {
    DAY("day"),
    WEEK("week"),
    MONTH("month"),
    LEISURE("someday");

    companion object {
        fun fromRaw(value: String): TaskTimeType =
            entries.firstOrNull { it.rawValue == value }
                ?: entries.first { it.name.equals(value, ignoreCase = true) }
    }
}

enum class QuestLine(val rawValue: String) {
    MAIN("main"),
    SIDE("side"),
    EXTRA("extra");

    companion object {
        fun fromRaw(value: String): QuestLine =
            entries.firstOrNull { it.rawValue == value }
                ?: entries.first { it.name.equals(value, ignoreCase = true) }
    }
}

enum class TaskStatus(val rawValue: String) {
    PENDING("pending"),
    COMPLETED("completed"),
    PASS("pass");

    companion object {
        fun fromRaw(value: String): TaskStatus =
            entries.firstOrNull { it.rawValue == value }
                ?: entries.first { it.name.equals(value, ignoreCase = true) }
    }
}

enum class Recurrence(val rawValue: String) {
    ONCE("once"),
    DAILY("daily"),
    WEEKLY("weekly"),
    MONTHLY("monthly");

    companion object {
        fun fromRaw(value: String): Recurrence =
            entries.firstOrNull { it.rawValue == value }
                ?: entries.first { it.name.equals(value, ignoreCase = true) }
    }
}

data class Task(
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
)

data class TaskDraft(
    val title: String,
    val timeType: TaskTimeType = TaskTimeType.DAY,
    val targetDate: LocalDate? = null,
    val questLine: QuestLine = QuestLine.MAIN,
    val recurrence: Recurrence = Recurrence.ONCE,
    val sortOrder: Int? = null,
)
