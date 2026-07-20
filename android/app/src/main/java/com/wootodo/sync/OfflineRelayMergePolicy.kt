package com.wootodo.sync

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.nio.charset.StandardCharsets
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

data class OfflineRelayMergePlan(
    val tasksToUpsert: List<TaskInstancePayload>,
    val tombstonesToApply: List<TombstonePayload>,
    val unchangedCount: Int,
)

data class OfflineRelayMergeResult(
    val mergedTaskCount: Int,
    val mergedTombstoneCount: Int,
    val unchangedCount: Int,
)

/**
 * 离线接力包不携带同步 Lamport 版本，因此使用任务更新时间和稳定内容指纹做确定性 LWW。
 * 领域终态规则与在线同步一致，删除屏障永远优先于同 ID 的任务。
 */
object OfflineRelayMergePolicy {
    fun plan(local: BackupTaskSnapshot, incoming: BackupSnapshot): OfflineRelayMergePlan {
        val localTasks = canonicalTaskMap(local.tasks)
        val localTombstones = canonicalTombstoneMap(local.tombstones)
        val incomingTasks = canonicalTaskMap(incoming.tasks).values.sortedBy(TaskInstancePayload::id)
        val incomingTombstones = canonicalTombstoneMap(incoming.tombstones)
            .values
            .sortedBy(TombstonePayload::id)
        val incomingTombstoneIds = incomingTombstones.mapTo(mutableSetOf(), TombstonePayload::id)

        val tasksToUpsert = incomingTasks.mapNotNull { incomingTask ->
            val entityId = incomingTask.id
            if (entityId in incomingTombstoneIds || entityId in localTombstones) {
                null
            } else {
                val current = localTasks[entityId]
                val resolved = current?.let { resolveTask(it, incomingTask) } ?: incomingTask
                resolved.takeIf { it != current }
            }
        }

        val tombstonesToApply = incomingTombstones.filter { incomingTombstone ->
            val entityId = incomingTombstone.id
            val current = localTombstones[entityId]
            current == null ||
                incomingTombstone.deletedAt > current.deletedAt ||
                entityId in localTasks
        }

        return OfflineRelayMergePlan(
            tasksToUpsert = tasksToUpsert,
            tombstonesToApply = tombstonesToApply,
            unchangedCount = incoming.tasks.size + incoming.tombstones.size -
                tasksToUpsert.size - tombstonesToApply.size,
        )
    }

    fun resolveTask(
        current: TaskInstancePayload,
        incoming: TaskInstancePayload,
    ): TaskInstancePayload {
        if (current == incoming) return current
        val incomingWinsLww = compareVersions(incoming, current) > 0

        mergeCompletedOverPass(current, incoming, incomingWinsLww)?.let { return it }
        if (current.state != WireTaskState.PENDING && incoming.state == WireTaskState.PENDING) {
            return current
        }
        if (current.state == WireTaskState.PENDING && incoming.state != WireTaskState.PENDING) {
            return incoming
        }
        return if (incomingWinsLww) incoming else current
    }

    private fun mergeCompletedOverPass(
        current: TaskInstancePayload,
        incoming: TaskInstancePayload,
        incomingWinsLww: Boolean,
    ): TaskInstancePayload? {
        val completed = when {
            current.state == WireTaskState.COMPLETED && incoming.state == WireTaskState.PASS -> current
            current.state == WireTaskState.PASS && incoming.state == WireTaskState.COMPLETED -> incoming
            else -> return null
        }
        if (!isValidCompletion(completed)) return null
        val base = if (incomingWinsLww) incoming else current
        val merged = base.copy(
            state = WireTaskState.COMPLETED,
            settledAt = completed.settledAt,
            updatedAt = maxOf(base.updatedAt, completed.updatedAt),
        )
        return merged.takeIf(::isValidCompletion)
    }

    private fun isValidCompletion(task: TaskInstancePayload): Boolean {
        val settledAt = task.settledAt ?: return false
        if (task.state != WireTaskState.COMPLETED) return false
        if (task.timeType == WireTimeType.SOMEDAY) return true
        val periodStart = task.periodStart?.let(LocalDate::parse) ?: return false
        val periodEnd = when (task.timeType) {
            WireTimeType.DAY -> periodStart.plusDays(1)
            WireTimeType.WEEK -> periodStart.plusWeeks(1)
            WireTimeType.MONTH -> periodStart.plusMonths(1)
            WireTimeType.SOMEDAY -> return true
        }
        return settledAt < periodEnd.atStartOfDay(ZoneId.of(task.timezone)).toInstant().toEpochMilli()
    }

    private fun compareVersions(
        first: TaskInstancePayload,
        second: TaskInstancePayload,
    ): Int {
        val timestampComparison = first.updatedAt.compareTo(second.updatedAt)
        if (timestampComparison != 0) return timestampComparison
        val firstFingerprint = fingerprint(first)
        val secondFingerprint = fingerprint(second)
        for (index in 0 until minOf(firstFingerprint.size, secondFingerprint.size)) {
            val comparison = (firstFingerprint[index].toInt() and 0xff)
                .compareTo(secondFingerprint[index].toInt() and 0xff)
            if (comparison != 0) return comparison
        }
        return firstFingerprint.size.compareTo(secondFingerprint.size)
    }

    private fun canonicalTaskMap(
        tasks: List<TaskInstancePayload>,
    ): Map<String, TaskInstancePayload> = buildMap {
        tasks.forEach { task ->
            val normalized = task.withCanonicalEntityId()
            put(
                normalized.id,
                get(normalized.id)?.let { current -> resolveTask(current, normalized) }
                    ?: normalized,
            )
        }
    }

    private fun canonicalTombstoneMap(
        tombstones: List<TombstonePayload>,
    ): Map<String, TombstonePayload> = buildMap {
        tombstones.forEach { tombstone ->
            val normalized = tombstone.withCanonicalEntityId()
            val current = get(normalized.id)
            if (current == null || normalized.deletedAt > current.deletedAt) {
                put(normalized.id, normalized)
            }
        }
    }

    /** 字段顺序和编码必须与 macOS OfflineRelayMergePolicy 保持一致。 */
    private fun fingerprint(task: TaskInstancePayload): ByteArray {
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { data ->
            data.writeLong(task.protocolVersion.toLong())
            data.writeRequiredString(task.entityType)
            data.writeRequiredString(task.id)
            data.writeRequiredString(task.seriesId)
            data.writeRequiredString(task.title)
            data.writeRequiredString(task.timeType.value)
            data.writeOptionalString(task.periodStart)
            data.writeRequiredString(task.timezone)
            data.writeRequiredString(task.questLine.value)
            data.writeRequiredString(task.state.value)
            data.writeRequiredString(task.recurrence.value)
            data.writeLong(task.sortOrder)
            data.writeLong(task.createdAt)
            data.writeLong(task.updatedAt)
            data.writeOptionalLong(task.settledAt)
        }
        return output.toByteArray()
    }

}

internal fun canonicalEntityId(value: String): String = value.lowercase(Locale.ROOT)

internal fun TaskInstancePayload.withCanonicalEntityId(): TaskInstancePayload {
    val canonicalId = canonicalEntityId(id)
    return if (canonicalId == id) this else copy(id = canonicalId)
}

internal fun TombstonePayload.withCanonicalEntityId(): TombstonePayload {
    val canonicalId = canonicalEntityId(id)
    return if (canonicalId == id) this else copy(id = canonicalId)
}

private fun DataOutputStream.writeRequiredString(value: String) {
    writeByte(1)
    val bytes = value.toByteArray(StandardCharsets.UTF_8)
    writeInt(bytes.size)
    write(bytes)
}

private fun DataOutputStream.writeOptionalString(value: String?) {
    if (value == null) {
        writeByte(0)
    } else {
        writeRequiredString(value)
    }
}

private fun DataOutputStream.writeOptionalLong(value: Long?) {
    if (value == null) {
        writeByte(0)
    } else {
        writeByte(1)
        writeLong(value)
    }
}
