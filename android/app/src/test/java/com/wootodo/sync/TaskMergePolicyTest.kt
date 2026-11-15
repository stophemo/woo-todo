package com.wootodo.sync

import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class TaskMergePolicyTest {
    private val older = EntityVersion(2, "device-completed")
    private val newer = EntityVersion(9, "device-pass")

    @Test
    fun `completed在两种到达顺序下均保留状态且字段取LWW`() {
        val completed = task(
            title = "完成时标题",
            state = WireTaskState.COMPLETED,
            settledAt = instant("2026-07-15", 23, 0),
            updatedAt = instant("2026-07-15", 23, 0),
        )
        val passed = task(
            title = "Pass端较新标题",
            state = WireTaskState.PASS,
            settledAt = instant("2026-07-16", 0, 0),
            updatedAt = instant("2026-07-16", 0, 0),
        )

        val completedThenPass = TaskMergePolicy.resolve(completed, older, passed, newer)
        val passThenCompleted = TaskMergePolicy.resolve(passed, newer, completed, older)

        assertEquals(completedThenPass, passThenCompleted)
        assertEquals(WireTaskState.COMPLETED, completedThenPass.resolvedTask?.state)
        assertEquals("Pass端较新标题", completedThenPass.resolvedTask?.title)
        assertEquals(completed.settledAt, completedThenPass.resolvedTask?.settledAt)
        assertEquals(newer, completedThenPass.resolvedVersion)
    }

    @Test
    fun `已结算快照不会被较大Lamport改回pending`() {
        val completed = task(
            title = "不可改写的历史",
            state = WireTaskState.COMPLETED,
            settledAt = instant("2026-07-15", 20, 0),
            updatedAt = instant("2026-07-15", 20, 0),
        )
        val stalePending = task(
            title = "旧设备待办标题",
            state = WireTaskState.PENDING,
            settledAt = null,
            updatedAt = instant("2026-07-16", 0, 0),
        )

        val completedThenPending = TaskMergePolicy.resolve(completed, older, stalePending, newer)
        val pendingThenCompleted = TaskMergePolicy.resolve(stalePending, newer, completed, older)

        assertEquals(completedThenPending, pendingThenCompleted)
        assertEquals(completed, completedThenPending.resolvedTask)
        assertEquals(newer, completedThenPending.resolvedVersion)
    }

    @Test
    fun `显式reopen仅在版本较新时恢复pending`() {
        val completed = task(
            title = "已完成",
            state = WireTaskState.COMPLETED,
            settledAt = instant("2026-07-15", 20, 0),
            updatedAt = instant("2026-07-15", 20, 0),
        )
        val reopened = task(
            title = "已完成",
            state = WireTaskState.PENDING,
            settledAt = null,
            updatedAt = instant("2026-07-15", 21, 0),
        )

        val accepted = TaskMergePolicy.resolve(
            completed,
            older,
            reopened,
            newer,
            SyncOperationKind.REOPEN,
        )
        val ignored = TaskMergePolicy.resolve(
            completed,
            newer,
            reopened,
            older,
            SyncOperationKind.REOPEN,
        )

        assertEquals(WireTaskState.PENDING, accepted.resolvedTask?.state)
        assertEquals(null, accepted.resolvedTask?.settledAt)
        assertEquals(completed, ignored.resolvedTask)
    }

    @Test
    fun `reopen不再受周期限制且仍拒绝已结算快照`() {
        val reopened = task(
            title = "跨月恢复",
            state = WireTaskState.PENDING,
            settledAt = null,
            updatedAt = instant("2026-08-15", 0, 0),
        )

        val accepted = TaskMergePolicy.resolve(
            currentTask = null,
            currentVersion = null,
            incomingTask = reopened,
            incomingVersion = newer,
            incomingKind = SyncOperationKind.REOPEN,
        )
        assertEquals(WireTaskState.PENDING, accepted.resolvedTask?.state)

        assertThrows(IllegalArgumentException::class.java) {
            TaskMergePolicy.resolve(
                currentTask = null,
                currentVersion = null,
                incomingTask = reopened.copy(settledAt = 1),
                incomingVersion = newer,
                incomingKind = SyncOperationKind.REOPEN,
            )
        }
    }

    private fun task(
        title: String,
        state: WireTaskState,
        settledAt: Long?,
        updatedAt: Long,
    ): TaskInstancePayload = TaskInstancePayload(
        id = "550e8400-e29b-41d4-a716-446655440000",
        seriesId = "550e8400-e29b-41d4-a716-446655440000",
        title = title,
        timeType = WireTimeType.DAY,
        periodStart = "2026-07-15",
        deadlineDate = "2026-07-20",
        timezone = "Asia/Shanghai",
        questLine = "main",
        state = state,
        recurrence = WireRecurrence.ONCE,
        sortOrder = 0,
        createdAt = instant("2026-07-15", 8, 0),
        updatedAt = updatedAt,
        settledAt = settledAt,
    )

    private fun instant(date: String, hour: Int, minute: Int): Long =
        LocalDate.parse(date)
            .atTime(hour, minute)
            .atZone(ZoneId.of("Asia/Shanghai"))
            .toInstant()
            .toEpochMilli()
}
