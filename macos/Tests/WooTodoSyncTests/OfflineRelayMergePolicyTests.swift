import Foundation
import Testing
@testable import WooTodoSync

@Suite("离线接力合并策略")
struct OfflineRelayMergePolicyTests {
    @Test("按时完成与 Pass 无论导入顺序都收敛为完成")
    func completedWinsPassRegardlessOfOrder() throws {
        let completed = try task(
            id: "task-relay-completed",
            title: "完成端标题",
            state: .completed,
            updatedAt: 2_000,
            settledAt: 1_900
        )
        let passed = try task(
            id: completed.id,
            title: "Pass 端较新标题",
            state: .pass,
            updatedAt: 3_000,
            settledAt: 3_000
        )

        let first = try OfflineRelayMergePolicy.resolveTask(
            current: completed,
            incoming: passed
        )
        let second = try OfflineRelayMergePolicy.resolveTask(
            current: passed,
            incoming: completed
        )

        #expect(first == second)
        #expect(first.state == .completed)
        #expect(first.title == "Pass 端较新标题")
        #expect(first.settledAt == 1_900)
    }

    @Test("相同更新时间使用内容指纹并在双向导入时收敛")
    func fingerprintBreaksTimestampTie() throws {
        let first = try task(
            id: "task-relay-tie-0001",
            title: "甲版本",
            updatedAt: 5_000
        )
        let second = try task(
            id: first.id,
            title: "乙版本",
            updatedAt: 5_000
        )

        #expect(
            try OfflineRelayMergePolicy.resolveTask(current: first, incoming: second)
                == OfflineRelayMergePolicy.resolveTask(current: second, incoming: first)
        )
        #expect(
            try OfflineRelayMergePolicy.resolveTask(current: first, incoming: second).title
                == "甲版本"
        )
    }

    @Test("完成时间超过 LWW 基础周期截止时保留 Pass")
    func completedAfterResolvedPeriodDeadlineDoesNotWinPass() throws {
        let completed = try task(
            id: "task-relay-period",
            title: "旧周期完成",
            state: .completed,
            updatedAt: 2_000,
            settledAt: 1_752_985_800_000,
            periodStart: "2025-07-20"
        )
        let passed = try task(
            id: completed.id,
            title: "新周期 Pass",
            state: .pass,
            updatedAt: 3_000,
            settledAt: 1_752_982_400_000,
            periodStart: "2025-07-19"
        )

        let first = try OfflineRelayMergePolicy.resolveTask(
            current: completed,
            incoming: passed
        )
        let second = try OfflineRelayMergePolicy.resolveTask(
            current: passed,
            incoming: completed
        )

        #expect(first == second)
        #expect(first.state == .pass)
        #expect(first.periodStart == "2025-07-19")
    }

    @Test("删除屏障优先且同一接力包重复规划幂等")
    func tombstoneWinsAndPlanningIsIdempotent() throws {
        let existing = try task(
            id: "task-relay-existing",
            title: "本机旧标题",
            updatedAt: 1_000
        )
        let deleted = try WireTombstonePayload(
            id: "task-relay-deleted",
            deletedAt: 2_000
        )
        let updated = try task(
            id: existing.id,
            title: "手机新标题",
            updatedAt: 4_000
        )
        let mustNotResurrect = try task(
            id: deleted.id,
            title: "不能复活",
            updatedAt: 5_000
        )
        let newDeletion = try WireTombstonePayload(
            id: "task-relay-new-delete",
            deletedAt: 3_000
        )

        let firstPlan = try OfflineRelayMergePolicy.plan(
            localTasks: [existing],
            localTombstones: [deleted],
            incomingTasks: [updated, mustNotResurrect],
            incomingTombstones: [newDeletion]
        )
        #expect(firstPlan.tasksToUpsert.map(\.title) == ["手机新标题"])
        #expect(firstPlan.tombstonesToApply.map(\.id) == ["task-relay-new-delete"])
        #expect(firstPlan.unchangedCount == 1)

        let secondPlan = try OfflineRelayMergePolicy.plan(
            localTasks: firstPlan.tasksToUpsert,
            localTombstones: [deleted] + firstPlan.tombstonesToApply,
            incomingTasks: [updated, mustNotResurrect],
            incomingTombstones: [newDeletion]
        )
        #expect(secondPlan.tasksToUpsert.isEmpty)
        #expect(secondPlan.tombstonesToApply.isEmpty)
        #expect(secondPlan.unchangedCount == 3)
    }

    @Test("大小写不同的同 ID 任务会规范化且重复规划幂等")
    func caseVariantIDsAreCanonicalAndIdempotent() throws {
        let existing = try task(
            id: "task-relay-case-id",
            title: "本机版本",
            updatedAt: 1_000
        )
        let incoming = try task(
            id: existing.id.uppercased(),
            title: "接力包版本",
            updatedAt: 2_000
        )

        let firstPlan = try OfflineRelayMergePolicy.plan(
            localTasks: [existing],
            localTombstones: [],
            incomingTasks: [incoming],
            incomingTombstones: []
        )
        #expect(firstPlan.tasksToUpsert.first?.id == existing.id)

        let secondPlan = try OfflineRelayMergePolicy.plan(
            localTasks: firstPlan.tasksToUpsert,
            localTombstones: [],
            incomingTasks: [incoming],
            incomingTombstones: []
        )
        #expect(secondPlan.tasksToUpsert.isEmpty)
        #expect(secondPlan.unchangedCount == 1)
    }

    @Test("较旧删除记录仍是较新本地任务的永久删除屏障")
    func olderTombstoneStillDeletesNewerLocalTask() throws {
        let existing = try task(
            id: "task-relay-old-delete",
            title: "较新本地任务",
            updatedAt: 9_000
        )
        let tombstone = try WireTombstonePayload(
            id: existing.id.uppercased(),
            deletedAt: 1_000
        )

        let plan = try OfflineRelayMergePolicy.plan(
            localTasks: [existing],
            localTombstones: [],
            incomingTasks: [],
            incomingTombstones: [tombstone]
        )

        #expect(plan.tombstonesToApply.first?.id == existing.id)
        #expect(plan.tasksToUpsert.isEmpty)
    }

    @Test("同一输入内大小写重复 ID 会确定性折叠")
    func duplicateCaseVariantIDsCollapseDeterministically() throws {
        let taskID = "task-relay-duplicate-case"
        let olderTask = try task(
            id: taskID.uppercased(),
            title: "较旧版本",
            updatedAt: 1_000
        )
        let newerTask = try task(
            id: taskID,
            title: "较新版本",
            updatedAt: 2_000
        )
        let tombstoneID = "task-relay-duplicate-tombstone"
        let olderTombstone = try WireTombstonePayload(
            id: tombstoneID.uppercased(),
            deletedAt: 1_000
        )
        let newerTombstone = try WireTombstonePayload(
            id: tombstoneID,
            deletedAt: 2_000
        )

        let forward = try OfflineRelayMergePolicy.plan(
            localTasks: [],
            localTombstones: [],
            incomingTasks: [olderTask, newerTask],
            incomingTombstones: [olderTombstone, newerTombstone]
        )
        let reverse = try OfflineRelayMergePolicy.plan(
            localTasks: [],
            localTombstones: [],
            incomingTasks: [newerTask, olderTask],
            incomingTombstones: [newerTombstone, olderTombstone]
        )

        #expect(forward == reverse)
        #expect(forward.tasksToUpsert.map(\.id) == [taskID])
        #expect(forward.tasksToUpsert.first?.title == "较新版本")
        #expect(forward.tombstonesToApply.map(\.id) == [tombstoneID])
        #expect(forward.unchangedCount == 2)
    }

    private func task(
        id: String,
        title: String,
        state: WireTaskState = .pending,
        updatedAt: Int64,
        settledAt: Int64? = nil,
        periodStart: String = "2026-07-20"
    ) throws -> WireTaskPayload {
        try WireTaskPayload(
            id: id,
            seriesId: "series-\(id)",
            title: title,
            timeType: .day,
            periodStart: periodStart,
            timezone: WireTaskPayload.fixedTimeZone,
            questLine: .main,
            state: state,
            recurrence: .once,
            sortOrder: 0,
            createdAt: 1_000,
            updatedAt: updatedAt,
            settledAt: settledAt
        )
    }
}
