package com.wootodo.sync

internal const val WIRE_FIXED_TIMEZONE = "Asia/Shanghai"
internal const val WIRE_MAXIMUM_SORT_ORDER = 2_147_483_647L
internal const val WIRE_MAXIMUM_SAFE_INTEGER = 9_007_199_254_740_991L

enum class WireTimeType(val value: String) {
    DAY("day"), WEEK("week"), MONTH("month"), SOMEDAY("someday");

    companion object {
        fun fromWire(value: String): WireTimeType = entries.firstOrNull { it.value == value }
            ?: throw IllegalArgumentException("未知时间类型：$value")
    }
}

enum class WireQuestLine(val value: String) {
    MAIN("main"), SIDE("side"), EXTRA("extra");

    companion object {
        fun fromWire(value: String): WireQuestLine = entries.firstOrNull { it.value == value }
            ?: throw IllegalArgumentException("未知任务线：$value")
    }
}

enum class WireTaskState(val value: String) {
    PENDING("pending"), COMPLETED("completed"), PASS("pass");

    companion object {
        fun fromWire(value: String): WireTaskState = entries.firstOrNull { it.value == value }
            ?: throw IllegalArgumentException("未知任务状态：$value")
    }
}

enum class WireRecurrence(val value: String) {
    ONCE("once"), REPEAT("repeat");

    companion object {
        fun fromWire(value: String): WireRecurrence = entries.firstOrNull { it.value == value }
            ?: throw IllegalArgumentException("未知重复快照：$value")
    }
}

sealed interface TaskWirePayload {
    val protocolVersion: Int
    val entityType: String
    val id: String
}

data class TaskInstancePayload(
    override val protocolVersion: Int = 1,
    override val entityType: String = "task",
    override val id: String,
    val seriesId: String,
    val title: String,
    val timeType: WireTimeType,
    val periodStart: String?,
    val timezone: String,
    val questLine: WireQuestLine,
    val state: WireTaskState,
    val recurrence: WireRecurrence,
    val sortOrder: Long,
    val createdAt: Long,
    val updatedAt: Long,
    val settledAt: Long?,
    val reminderTime: String? = null,
) : TaskWirePayload

data class TombstonePayload(
    override val protocolVersion: Int = 1,
    override val entityType: String = "tombstone",
    override val id: String,
    val deletedAt: Long,
) : TaskWirePayload
