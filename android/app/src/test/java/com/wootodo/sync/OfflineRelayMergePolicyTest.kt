package com.wootodo.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OfflineRelayMergePolicyTest {
    @Test
    fun `按时完成与Pass无论导入顺序都收敛为完成`() {
        val completed = task(
            id = "task-relay-completed",
            title = "完成端标题",
            state = WireTaskState.COMPLETED,
            updatedAt = 2_000,
            settledAt = 1_900,
        )
        val passed = task(
            id = completed.id,
            title = "Pass 端较新标题",
            state = WireTaskState.PASS,
            updatedAt = 3_000,
            settledAt = 3_000,
        )

        val first = OfflineRelayMergePolicy.resolveTask(completed, passed)
        val second = OfflineRelayMergePolicy.resolveTask(passed, completed)

        assertEquals(first, second)
        assertEquals(WireTaskState.COMPLETED, first.state)
        assertEquals("Pass 端较新标题", first.title)
        assertEquals(1_900L, first.settledAt)
    }

    @Test
    fun `相同更新时间使用内容指纹并在双向导入时收敛`() {
        val first = task("task-relay-tie-0001", "甲版本", updatedAt = 5_000)
        val second = first.copy(title = "乙版本")

        assertEquals(
            OfflineRelayMergePolicy.resolveTask(first, second),
            OfflineRelayMergePolicy.resolveTask(second, first),
        )
        assertEquals(
            "甲版本",
            OfflineRelayMergePolicy.resolveTask(first, second).title,
        )
    }

    @Test
    fun `完成时间超过LWW基础周期截止时保留Pass`() {
        val completed = task(
            id = "task-relay-period",
            title = "旧周期完成",
            state = WireTaskState.COMPLETED,
            updatedAt = 2_000,
            settledAt = 1_752_985_800_000,
            periodStart = "2025-07-20",
        )
        val passed = task(
            id = completed.id,
            title = "新周期Pass",
            state = WireTaskState.PASS,
            updatedAt = 3_000,
            settledAt = 1_752_982_400_000,
            periodStart = "2025-07-19",
        )

        val first = OfflineRelayMergePolicy.resolveTask(completed, passed)
        val second = OfflineRelayMergePolicy.resolveTask(passed, completed)

        assertEquals(first, second)
        assertEquals(WireTaskState.PASS, first.state)
        assertEquals("2025-07-19", first.periodStart)
    }

    @Test
    fun `删除屏障优先且同一接力包重复规划幂等`() {
        val existing = task("task-relay-existing", "本机旧标题", updatedAt = 1_000)
        val deleted = TombstonePayload(id = "task-relay-deleted", deletedAt = 2_000)
        val incoming = BackupSnapshot(
            exportedAt = 6_000,
            tasks = listOf(
                existing.copy(title = "手机新标题", updatedAt = 4_000),
                task(deleted.id, "不能复活", updatedAt = 5_000),
            ),
            tombstones = listOf(
                TombstonePayload(id = "task-relay-new-delete", deletedAt = 3_000),
            ),
            syncCredentials = null,
        )
        val local = BackupTaskSnapshot(
            state = pristineState().copy(taskCount = 1, tombstoneCount = 1),
            tasks = listOf(existing),
            tombstones = listOf(deleted),
        )

        val firstPlan = OfflineRelayMergePolicy.plan(local, incoming)
        assertEquals(listOf("手机新标题"), firstPlan.tasksToUpsert.map { it.title })
        assertEquals(listOf("task-relay-new-delete"), firstPlan.tombstonesToApply.map { it.id })
        assertEquals(1, firstPlan.unchangedCount)

        val mergedLocal = BackupTaskSnapshot(
            state = pristineState().copy(taskCount = 1, tombstoneCount = 2),
            tasks = firstPlan.tasksToUpsert,
            tombstones = listOf(deleted) + firstPlan.tombstonesToApply,
        )
        val secondPlan = OfflineRelayMergePolicy.plan(mergedLocal, incoming)
        assertTrue(secondPlan.tasksToUpsert.isEmpty())
        assertTrue(secondPlan.tombstonesToApply.isEmpty())
        assertEquals(3, secondPlan.unchangedCount)
    }

    @Test
    fun `大小写不同的同ID任务会规范化且重复规划幂等`() {
        val existing = task("task-relay-case-id", "本机版本", updatedAt = 1_000)
        val incomingTask = task(
            existing.id.uppercase(),
            "接力包版本",
            updatedAt = 2_000,
        )
        val incoming = BackupSnapshot(
            exportedAt = 3_000,
            tasks = listOf(incomingTask),
            syncCredentials = null,
        )

        val firstPlan = OfflineRelayMergePolicy.plan(
            BackupTaskSnapshot(
                state = pristineState().copy(taskCount = 1),
                tasks = listOf(existing),
                tombstones = emptyList(),
            ),
            incoming,
        )
        assertEquals(existing.id, firstPlan.tasksToUpsert.single().id)

        val secondPlan = OfflineRelayMergePolicy.plan(
            BackupTaskSnapshot(
                state = pristineState().copy(taskCount = 1),
                tasks = firstPlan.tasksToUpsert,
                tombstones = emptyList(),
            ),
            incoming,
        )
        assertTrue(secondPlan.tasksToUpsert.isEmpty())
        assertEquals(1, secondPlan.unchangedCount)
    }

    @Test
    fun `较旧删除记录仍是较新本地任务的永久删除屏障`() {
        val existing = task("task-relay-old-delete", "较新本地任务", updatedAt = 9_000)
        val incoming = BackupSnapshot(
            exportedAt = 10_000,
            tasks = emptyList(),
            tombstones = listOf(
                TombstonePayload(id = existing.id.uppercase(), deletedAt = 1_000),
            ),
            syncCredentials = null,
        )

        val plan = OfflineRelayMergePolicy.plan(
            BackupTaskSnapshot(
                state = pristineState().copy(taskCount = 1),
                tasks = listOf(existing),
                tombstones = emptyList(),
            ),
            incoming,
        )

        assertEquals(existing.id, plan.tombstonesToApply.single().id)
        assertTrue(plan.tasksToUpsert.isEmpty())
    }

    @Test
    fun `同一输入内大小写重复ID会确定性折叠`() {
        val taskId = "task-relay-duplicate-case"
        val olderTask = task(taskId.uppercase(), "较旧版本", updatedAt = 1_000)
        val newerTask = task(taskId, "较新版本", updatedAt = 2_000)
        val tombstoneId = "task-relay-duplicate-tombstone"
        val olderTombstone = TombstonePayload(
            id = tombstoneId.uppercase(),
            deletedAt = 1_000,
        )
        val newerTombstone = TombstonePayload(id = tombstoneId, deletedAt = 2_000)
        val incoming = BackupSnapshot(
            exportedAt = 3_000,
            tasks = listOf(olderTask, newerTask),
            tombstones = listOf(olderTombstone, newerTombstone),
            syncCredentials = null,
        )

        val forward = OfflineRelayMergePolicy.plan(
            BackupTaskSnapshot(pristineState(), emptyList(), emptyList()),
            incoming,
        )
        val reverse = OfflineRelayMergePolicy.plan(
            BackupTaskSnapshot(pristineState(), emptyList(), emptyList()),
            incoming.copy(
                tasks = incoming.tasks.reversed(),
                tombstones = incoming.tombstones.reversed(),
            ),
        )

        assertEquals(forward, reverse)
        assertEquals(listOf(taskId), forward.tasksToUpsert.map { it.id })
        assertEquals("较新版本", forward.tasksToUpsert.single().title)
        assertEquals(listOf(tombstoneId), forward.tombstonesToApply.map { it.id })
        assertEquals(2, forward.unchangedCount)
    }

    private fun task(
        id: String,
        title: String,
        state: WireTaskState = WireTaskState.PENDING,
        updatedAt: Long,
        settledAt: Long? = null,
        periodStart: String = "2026-07-20",
    ): TaskInstancePayload = TaskInstancePayload(
        id = id,
        seriesId = "series-$id",
        title = title,
        timeType = WireTimeType.DAY,
        periodStart = periodStart,
        timezone = WIRE_FIXED_TIMEZONE,
        questLine = WireQuestLine.MAIN,
        state = state,
        recurrence = WireRecurrence.ONCE,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = updatedAt,
        settledAt = settledAt,
    )

    private fun pristineState(): BackupDatabaseState = BackupDatabaseState(
        taskCount = 0,
        vaultId = "",
        deviceId = "",
        cursor = 0,
        lamport = 0,
        outboxCount = 0,
        entityVersionCount = 0,
        tombstoneCount = 0,
        appliedOperationCount = 0,
    )
}
