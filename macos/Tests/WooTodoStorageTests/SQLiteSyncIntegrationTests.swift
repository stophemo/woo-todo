import Foundation
import Testing
import WooTodoCore
import WooTodoSync
@testable import WooTodoStorage

@Suite("SQLite 同步落地")
struct SQLiteSyncIntegrationTests {
    @Test("本地各类变更写入稳定密文 outbox 并可逐项确认")
    func localMutationsEnterOutbox() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let start = date("2026-07-15T08:00:00+08:00")
        var first = try makeTask(title: "初始任务", createdAt: start)
        try repository.save(first)

        first.title = "修改标题"
        first.updatedAt = start.addingTimeInterval(60)
        try repository.save(first)

        first.sortIndex = 2
        first.updatedAt = start.addingTimeInterval(120)
        try repository.save(first)

        first.status = .completed
        first.completedAt = start.addingTimeInterval(180)
        first.updatedAt = start.addingTimeInterval(180)
        try repository.save(first)

        var passed = try makeTask(
            title: "自动 Pass",
            createdAt: start.addingTimeInterval(1),
            sortIndex: 3
        )
        try repository.save(passed)
        passed.status = .pass
        passed.updatedAt = start.addingTimeInterval(240)
        try repository.save(passed)

        let deleted = try makeTask(
            title: "待删除",
            createdAt: start.addingTimeInterval(2),
            sortIndex: 4
        )
        try repository.save(deleted)
        try repository.delete(id: deleted.id)

        let operations = try await repository.pendingOperations(limit: 50)
        #expect(operations.map(\.kind) == [
            .upsert, .upsert, .reorder, .complete,
            .upsert, .pass, .upsert, .delete,
        ])
        #expect(operations.map(\.lamport) == Array(1...8).map(Int64.init))
        #expect(try await repository.pendingOperations(limit: 50) == operations)

        let firstEntity = try open(operations[0], configuration: configuration)
        guard case .task(let firstPayload) = firstEntity else {
            Issue.record("首条 outbox 应为任务正文")
            return
        }
        #expect(firstPayload.title == "初始任务")
        let deletedEntity = try open(operations[7], configuration: configuration)
        guard case .tombstone(let tombstone) = deletedEntity else {
            Issue.record("删除操作应为 tombstone")
            return
        }
        #expect(tombstone.id == deleted.id.uuidString.lowercased())

        try await repository.acknowledgeOperations(
            opIds: Array(operations.prefix(3).map(\.opId))
        )
        #expect(try await repository.pendingOperations(limit: 50) == Array(operations.dropFirst(3)))
    }

    @Test("首次绑定为既有任务生成一次基线快照")
    func firstBindingCreatesOneBaseline() async throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let task = try makeTask(
            title: "绑定前任务",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        try repository.save(task)
        #expect(try await repository.pendingOperations(limit: 50).isEmpty)

        let configuration = syncConfiguration()
        try repository.configureSync(configuration)
        let baseline = try await repository.pendingOperations(limit: 50)
        #expect(baseline.count == 1)
        #expect(baseline.first?.kind == .upsert)

        try repository.configureSync(configuration)
        #expect(try await repository.pendingOperations(limit: 50) == baseline)
    }

    @Test("远端 LWW 更新 cursor 且不会反向写入 outbox")
    func remoteLWWAndLamportClock() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let id = UUID()
        let newest = try makeTask(
            id: id,
            title: "远端新版本",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        let stale = try makeTask(
            id: id,
            title: "远端旧版本",
            createdAt: newest.createdAt
        )
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                newest,
                kind: .upsert,
                lamport: 2,
                serverSequence: 1,
                deviceID: "device-z",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                stale,
                kind: .upsert,
                lamport: 1,
                serverSequence: 2,
                deviceID: "device-a",
                configuration: configuration
            ),
        ], advancingCursorTo: 2)

        #expect(try repository.fetchAll().first?.title == "远端新版本")
        #expect(try await repository.currentCursor() == 2)
        #expect(try await repository.pendingOperations(limit: 50).isEmpty)

        var localEdit = try #require(try repository.fetchAll().first)
        localEdit.title = "本地继续修改"
        localEdit.updatedAt = localEdit.updatedAt.addingTimeInterval(60)
        try repository.save(localEdit)
        let localOperation = try #require(try await repository.pendingOperations(limit: 1).first)
        #expect(localOperation.lamport == 3)
    }

    @Test("远端页面失败时任务、inbox 与 cursor 一起回滚后可重试")
    func remotePageIsAtomicAndRetryable() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let task = try makeTask(
            title: "原子写入",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        let first = try remoteTaskOperation(
            task,
            kind: .upsert,
            lamport: 1,
            serverSequence: 1,
            deviceID: "device-remote",
            configuration: configuration
        )
        let broken = SyncPulledOperation(
            serverSeq: 2,
            opId: "broken-operation",
            deviceId: "device-remote",
            entityId: task.id.uuidString.lowercased(),
            kind: .upsert,
            lamport: 2,
            ciphertext: Base64URL.encode(Data([1])),
            nonce: Base64URL.encode(Data(repeating: 2, count: 12)),
            createdAt: 2
        )

        do {
            try await repository.applyRemoteOperations(
                [first, broken],
                advancingCursorTo: 2
            )
            Issue.record("损坏密文应使整页失败")
        } catch {
            // 预期解密失败。
        }
        #expect(try repository.fetchAll().isEmpty)
        #expect(try await repository.currentCursor() == 0)

        try await repository.applyRemoteOperations([first], advancingCursorTo: 1)
        #expect(try repository.fetchAll() == [task])
        #expect(try await repository.currentCursor() == 1)
    }

    @Test("tombstone 是最高优先级终态且与 task 到达顺序无关")
    func tombstonePreventsResurrection() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let task = try makeTask(
            title: "将被删除",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                task,
                kind: .upsert,
                lamport: 99,
                serverSequence: 1,
                deviceID: "device-a",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)
        try await repository.applyRemoteOperations([
            try remoteTombstoneOperation(
                entityID: task.id.uuidString.lowercased(),
                lamport: 2,
                serverSequence: 2,
                deviceID: "device-b",
                configuration: configuration
            ),
        ], advancingCursorTo: 2)
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                task,
                kind: .upsert,
                lamport: 100,
                serverSequence: 3,
                deviceID: "device-stale",
                configuration: configuration
            ),
        ], advancingCursorTo: 3)

        #expect(try repository.fetchAll().isEmpty)
        #expect(try await repository.currentCursor() == 3)
        do {
            try repository.save(task)
            Issue.record("本地也不能复活 tombstone 的 ID")
        } catch SQLiteRepositoryError.invalidRecord(_) {
            // 预期错误。
        }
    }

    @Test("截止前 completed 在两种到达顺序下都优先于 pass")
    func validCompletedWinsPassRegardlessOfArrivalOrder() async throws {
        let configuration = syncConfiguration()
        let completionTime = date("2026-07-15T23:00:00+08:00")
        let passTime = date("2026-07-16T00:00:00+08:00")
        let id = UUID()
        let completed = try makeTask(
            id: id,
            title: "完成时标题",
            status: .completed,
            createdAt: date("2026-07-15T08:00:00+08:00"),
            updatedAt: completionTime,
            settledAt: completionTime
        )
        let passed = try makeTask(
            id: id,
            title: "Pass 端较新标题",
            status: .pass,
            createdAt: completed.createdAt,
            updatedAt: passTime,
            settledAt: passTime
        )

        let completedThenPass = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        try await completedThenPass.applyRemoteOperations([
            try remoteTaskOperation(
                completed,
                kind: .complete,
                lamport: 2,
                serverSequence: 1,
                deviceID: "device-completed",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)
        try await completedThenPass.applyRemoteOperations([
            try remoteTaskOperation(
                passed,
                kind: .pass,
                lamport: 9,
                serverSequence: 2,
                deviceID: "device-pass",
                configuration: configuration
            ),
        ], advancingCursorTo: 2)

        let passThenCompleted = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        try await passThenCompleted.applyRemoteOperations([
            try remoteTaskOperation(
                passed,
                kind: .pass,
                lamport: 9,
                serverSequence: 1,
                deviceID: "device-pass",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)
        try await passThenCompleted.applyRemoteOperations([
            try remoteTaskOperation(
                completed,
                kind: .complete,
                lamport: 2,
                serverSequence: 2,
                deviceID: "device-completed",
                configuration: configuration
            ),
        ], advancingCursorTo: 2)

        let firstResult = try #require(try completedThenPass.fetchAll().first)
        let secondResult = try #require(try passThenCompleted.fetchAll().first)
        #expect(firstResult == secondResult)
        #expect(firstResult.status == .completed)
        #expect(firstResult.completedAt == completionTime)
        #expect(firstResult.title == "Pass 端较新标题")

        let laterPass = try makeTask(
            id: id,
            title: "后续 Pass 端标题",
            status: .pass,
            createdAt: completed.createdAt,
            updatedAt: passTime.addingTimeInterval(60),
            settledAt: passTime.addingTimeInterval(60)
        )
        for repository in [completedThenPass, passThenCompleted] {
            try await repository.applyRemoteOperations([
                try remoteTaskOperation(
                    laterPass,
                    kind: .pass,
                    lamport: 10,
                    serverSequence: 3,
                    deviceID: "device-pass",
                    configuration: configuration
                ),
            ], advancingCursorTo: 3)
            let result = try #require(try repository.fetchAll().first)
            #expect(result.status == .completed)
            #expect(result.completedAt == completionTime)
            #expect(result.title == "后续 Pass 端标题")
        }
    }

    @Test("已结算快照不会被较大 Lamport 改回 pending")
    func settledSnapshotWinsPendingRegardlessOfArrivalOrder() async throws {
        let configuration = syncConfiguration()
        let id = UUID()
        let createdAt = date("2026-07-15T08:00:00+08:00")
        let completed = try makeTask(
            id: id,
            title: "不可改写的历史",
            status: .completed,
            createdAt: createdAt,
            updatedAt: date("2026-07-15T20:00:00+08:00"),
            settledAt: date("2026-07-15T20:00:00+08:00")
        )
        let stalePending = try makeTask(
            id: id,
            title: "旧设备待办标题",
            createdAt: createdAt,
            updatedAt: date("2026-07-16T00:01:00+08:00")
        )

        let completedThenPending = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        try await completedThenPending.applyRemoteOperations([
            try remoteTaskOperation(
                completed,
                kind: .complete,
                lamport: 2,
                serverSequence: 1,
                deviceID: "device-completed",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)
        try await completedThenPending.applyRemoteOperations([
            try remoteTaskOperation(
                stalePending,
                kind: .upsert,
                lamport: 9,
                serverSequence: 2,
                deviceID: "device-pending",
                configuration: configuration
            ),
        ], advancingCursorTo: 2)

        let pendingThenCompleted = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        try await pendingThenCompleted.applyRemoteOperations([
            try remoteTaskOperation(
                stalePending,
                kind: .upsert,
                lamport: 9,
                serverSequence: 1,
                deviceID: "device-pending",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)
        try await pendingThenCompleted.applyRemoteOperations([
            try remoteTaskOperation(
                completed,
                kind: .complete,
                lamport: 2,
                serverSequence: 2,
                deviceID: "device-completed",
                configuration: configuration
            ),
        ], advancingCursorTo: 2)

        #expect(try completedThenPending.fetchAll() == [completed])
        #expect(try pendingThenCompleted.fetchAll() == [completed])
    }

    @Test("左闭右开周期的截止瞬间 completed 不享有领域优先级")
    func completionAtDeadlineDoesNotOverrideNewerPass() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let id = UUID()
        let createdAt = date("2026-07-15T08:00:00+08:00")
        let passed = try makeTask(
            id: id,
            title: "按时 Pass",
            status: .pass,
            createdAt: createdAt,
            updatedAt: date("2026-07-16T00:00:00+08:00"),
            settledAt: date("2026-07-16T00:00:00+08:00")
        )
        let lateCompleted = try makeTask(
            id: id,
            title: "截止瞬间完成",
            status: .completed,
            createdAt: createdAt,
            updatedAt: date("2026-07-16T00:00:00+08:00"),
            settledAt: date("2026-07-16T00:00:00+08:00")
        )
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                passed,
                kind: .pass,
                lamport: 9,
                serverSequence: 1,
                deviceID: "device-pass",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                lateCompleted,
                kind: .complete,
                lamport: 2,
                serverSequence: 2,
                deviceID: "device-completed",
                configuration: configuration
            ),
        ], advancingCursorTo: 2)

        #expect(try repository.fetchAll().first?.status == .pass)
        #expect(try repository.fetchAll().first?.title == "按时 Pass")
    }

    @Test("远端 Pass 保留独立于 updatedAt 的原始结算时间")
    func remotePassPreservesSettledAt() async throws {
        let configuration = syncConfiguration()
        let settledAt = date("2026-07-16T00:00:00+08:00")
        let task = try makeTask(
            title: "保留 Pass 时间",
            status: .pass,
            createdAt: date("2026-07-15T08:00:00+08:00"),
            updatedAt: date("2026-07-16T00:05:00+08:00"),
            settledAt: settledAt
        )
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )

        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                task,
                kind: .pass,
                lamport: 1,
                serverSequence: 1,
                deviceID: "device-pass",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)

        let restored = try #require(try repository.fetchAll().first)
        #expect(restored.status == .pass)
        #expect(restored.completedAt == settledAt)
        #expect(restored.updatedAt != restored.completedAt)
    }
}

private func syncConfiguration() -> SQLiteSyncConfiguration {
    SQLiteSyncConfiguration(
        vaultId: "vault-test",
        deviceId: "device-mac",
        vaultKey: Data((0..<32).map { UInt8($0) }),
        timeZone: TimeZone(identifier: "Asia/Shanghai")!
    )
}

private func makeTask(
    id: UUID = UUID(),
    title: String,
    status: TaskStatus = .pending,
    createdAt: Date,
    updatedAt: Date? = nil,
    settledAt: Date? = nil,
    sortIndex: Int = 0
) throws -> TodoTask {
    let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return try TodoTask(
        id: id,
        title: title,
        timeScope: .daily,
        tier: .mainline,
        status: status,
        recurrence: .once,
        period: PeriodEngine(timeZone: timeZone).period(containing: createdAt, for: .daily),
        sortIndex: sortIndex,
        createdAt: createdAt,
        updatedAt: updatedAt ?? createdAt,
        completedAt: status == .pending ? nil : settledAt
    )
}

private func remoteTaskOperation(
    _ task: TodoTask,
    kind: SyncOperationKind,
    lamport: Int64,
    serverSequence: Int64,
    deviceID: String,
    configuration: SQLiteSyncConfiguration
) throws -> SyncPulledOperation {
    let entityID = task.id.uuidString.lowercased()
    let operationID = "remote-\(serverSequence)-\(lamport)-\(deviceID)"
    let state: WireTaskState
    switch task.status {
    case .pending: state = .pending
    case .completed: state = .completed
    case .pass: state = .pass
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = configuration.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let payload = try WireTaskPayload(
        id: entityID,
        seriesId: task.seriesID.uuidString.lowercased(),
        title: task.title,
        timeType: .day,
        periodStart: task.period.map { formatter.string(from: $0.start) },
        timezone: configuration.timeZone.identifier,
        questLine: .main,
        state: state,
        recurrence: .once,
        sortOrder: Int64(task.sortIndex),
        createdAt: milliseconds(task.createdAt),
        updatedAt: milliseconds(task.updatedAt),
        settledAt: task.status == .pending
            ? nil
            : milliseconds(task.completedAt ?? task.updatedAt)
    )
    let metadata = SyncAADMetadata(
        vaultId: configuration.vaultId,
        operationId: operationID,
        entityId: entityID,
        kind: kind,
        lamport: lamport,
        deviceId: deviceID
    )
    let envelope = try TaskPayloadCodec.seal(
        .task(payload),
        vaultKey: configuration.vaultKey,
        metadata: metadata
    )
    return SyncPulledOperation(
        serverSeq: serverSequence,
        opId: operationID,
        deviceId: deviceID,
        entityId: entityID,
        kind: kind,
        lamport: lamport,
        ciphertext: envelope.ciphertext,
        nonce: envelope.nonce,
        createdAt: milliseconds(task.updatedAt)
    )
}

private func remoteTombstoneOperation(
    entityID: String,
    lamport: Int64,
    serverSequence: Int64,
    deviceID: String,
    configuration: SQLiteSyncConfiguration
) throws -> SyncPulledOperation {
    let operationID = "remote-delete-\(serverSequence)-\(deviceID)"
    let payload = try WireTombstonePayload(
        id: entityID,
        deletedAt: milliseconds(date("2026-07-15T09:00:00+08:00"))
    )
    let metadata = SyncAADMetadata(
        vaultId: configuration.vaultId,
        operationId: operationID,
        entityId: entityID,
        kind: .delete,
        lamport: lamport,
        deviceId: deviceID
    )
    let envelope = try TaskPayloadCodec.seal(
        .tombstone(payload),
        vaultKey: configuration.vaultKey,
        metadata: metadata
    )
    return SyncPulledOperation(
        serverSeq: serverSequence,
        opId: operationID,
        deviceId: deviceID,
        entityId: entityID,
        kind: .delete,
        lamport: lamport,
        ciphertext: envelope.ciphertext,
        nonce: envelope.nonce,
        createdAt: payload.deletedAt
    )
}

private func open(
    _ operation: SyncPushOperation,
    configuration: SQLiteSyncConfiguration
) throws -> WireTaskEntity {
    try TaskPayloadCodec.open(
        EncryptedEnvelope(
            ciphertext: operation.ciphertext,
            nonce: operation.nonce
        ),
        vaultKey: configuration.vaultKey,
        metadata: SyncAADMetadata(
            vaultId: configuration.vaultId,
            operation: operation,
            deviceId: configuration.deviceId
        )
    )
}

private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
