package com.wootodo.domain

import com.wootodo.data.TaskEntity
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import java.util.UUID

data class RecurringSettlement(
    val updatedTasks: List<TaskEntity>,
    val createdTasks: List<TaskEntity>,
) {
    val isEmpty: Boolean get() = updatedTasks.isEmpty() && createdTasks.isEmpty()
}

/**
 * 每天重复任务的本机结算：过期未完成的上一条记为放弃，并逐日补齐到今天。
 * occurrence id 与 macOS/旧周期任务使用同一算法，保证多设备生成结果一致。
 */
object RecurringTaskSettler {
    fun settle(
        tasks: List<TaskEntity>,
        today: LocalDate,
        now: Long,
        deletedTaskIds: Set<String> = emptySet(),
    ): RecurringSettlement {
        val originalById = tasks.associateBy { it.id }
        val tasksById = originalById.toMutableMap()
        val occurrenceKeys = tasks.mapNotNullTo(mutableSetOf()) { task ->
            if (task.recurrence != TaskRecurrence.DAILY) return@mapNotNullTo null
            val start = task.startDate ?: return@mapNotNullTo null
            occurrenceKey(task.seriesId, start)
        }
        val queue = tasks.sortedBy { it.startDate ?: LocalDate.MAX }.toMutableList()
        var index = 0

        while (index < queue.size) {
            val task = queue[index]
            index += 1
            if (task.recurrence != TaskRecurrence.DAILY) continue
            val start = task.startDate ?: continue
            val end = task.endDate ?: continue
            if (!end.isBefore(today)) continue

            if (task.status == TaskStatus.PENDING) {
                val expiration = end.atStartOfDay(TaskDateRules.zoneId).toInstant().toEpochMilli()
                tasksById[task.id] = task.copy(
                    status = TaskStatus.PASS,
                    settledAt = expiration,
                    updatedAt = maxOf(task.updatedAt, expiration),
                )
            }

            val duration = ChronoUnit.DAYS.between(start, end) + 1
            if (duration <= 0) continue
            val nextStart = end.plusDays(1)
            val nextEnd = nextStart.plusDays(duration - 1)
            val nextId = occurrenceId(task.seriesId, nextStart)
            if (nextId.lowercase() in deletedTaskIds) continue
            val key = occurrenceKey(task.seriesId, nextStart)
            if (tasksById.containsKey(nextId) || key in occurrenceKeys) continue
            val next = TaskEntity(
                id = nextId,
                seriesId = task.seriesId,
                title = task.title,
                categoryId = task.categoryId,
                startDate = nextStart,
                endDate = nextEnd,
                status = TaskStatus.PENDING,
                sortOrder = task.sortOrder,
                createdAt = now,
                updatedAt = now,
                settledAt = null,
                reminderTime = task.reminderTime,
                recurrence = TaskRecurrence.DAILY,
            )
            tasksById[nextId] = next
            occurrenceKeys += key
            queue += next
        }

        val updated = tasksById.values.filter { task ->
            val original = originalById[task.id]
            original != null && original != task
        }
        val created = tasksById.values.filter { originalById[it.id] == null }
        return RecurringSettlement(
            updatedTasks = updated,
            createdTasks = created,
        )
    }

    fun occurrenceId(seriesId: String, startDate: LocalDate): String {
        val source = "woo-todo-occurrence-v1|${seriesId.lowercase()}|day|$startDate"
        val digest = MessageDigest.getInstance("SHA-256").digest(source.toByteArray(Charsets.UTF_8))
        digest[6] = ((digest[6].toInt() and 0x0f) or 0x50).toByte()
        digest[8] = ((digest[8].toInt() and 0x3f) or 0x80).toByte()
        val bytes = ByteBuffer.wrap(digest.copyOf(16))
        return UUID(bytes.long, bytes.long).toString()
    }

    private fun occurrenceKey(seriesId: String, startDate: LocalDate): String =
        "${seriesId.lowercase()}|$startDate"
}
