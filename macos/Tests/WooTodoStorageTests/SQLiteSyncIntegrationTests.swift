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
        first.endDate = date("2026-07-20T00:00:00+08:00")
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
        #expect(firstPayload.deadlineDate == "2026-07-20")
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

    @Test("每日重复任务写入 repeat 正文")
    func dailyRecurrenceEntersWirePayload() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let task = try makeTask(
            title: "每天任务",
            createdAt: date("2026-11-20T08:00:00+08:00"),
            recurrence: .daily
        )
        try repository.save(task)

        let operations = try await repository.pendingOperations(limit: 10)
        let entity = try open(try #require(operations.first), configuration: configuration)
        guard case .task(let payload) = entity else {
            Issue.record("outbox 应为任务正文")
            return
        }
        #expect(payload.recurrence == .repeatRule)
        #expect(payload.timeType == .day)
    }

    @Test("删除后恢复会以新任务正文进入 outbox")
    func restoreAfterDeleteEntersOutboxAsNewTask() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let start = date("2026-07-15T08:00:00+08:00")
        let task = try makeTask(title: "误删任务", createdAt: start)
        try repository.save(task)
        try await repository.acknowledgeOperations(
            opIds: try await repository.pendingOperations(limit: 50).map(\.opId)
        )

        try repository.delete(id: task.id)
        let deleted = try await repository.pendingOperations(limit: 50)
        #expect(deleted.map(\.kind) == [.delete])
        try await repository.acknowledgeOperations(opIds: deleted.map(\.opId))

        let restoredID = try #require(
            try repository.restoreTrash(
                id: task.id,
                at: start.addingTimeInterval(60)
            )
        )
        #expect(restoredID != task.id)
        let operations = try await repository.pendingOperations(limit: 50)
        #expect(operations.map(\.kind) == [.upsert])
        guard case .task(let payload) = try open(
            try #require(operations.first),
            configuration: configuration
        ) else {
            Issue.record("恢复应写入新任务正文")
            return
        }
        #expect(payload.id == restoredID.uuidString.lowercased())
        #expect(payload.seriesId == task.seriesID.uuidString.lowercased())
        #expect(payload.state == .pending)
    }

    @Test("远端删除会保留本机恢复快照")
    func remoteTombstoneKeepsTrashSnapshot() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let start = date("2026-07-15T08:00:00+08:00")
        let task = try makeTask(title: "远端删除", createdAt: start)
        try repository.save(task)
        try await repository.acknowledgeOperations(
            opIds: try await repository.pendingOperations(limit: 50).map(\.opId)
        )

        let deletedAt = milliseconds(start.addingTimeInterval(30))
        try await repository.applyRemoteOperations([
            try remoteTombstoneOperation(
                entityID: task.id.uuidString.lowercased(),
                lamport: 10,
                serverSequence: 1,
                deviceID: "device-other",
                configuration: configuration,
                deletedAt: deletedAt
            ),
        ], advancingCursorTo: 1)

        #expect(try repository.fetchAll().isEmpty)
        let trash = try repository.fetchTrash()
        #expect(trash.map(\.task.id) == [task.id])
        #expect(trash.first?.deletedAt == Date(timeIntervalSince1970: Double(deletedAt) / 1_000))
    }

    @Test("收到恢复后的新任务会清除旧恢复快照")
    func remoteRestoredTaskClearsTrashSnapshot() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let start = date("2026-07-15T08:00:00+08:00")
        let task = try makeTask(title: "跨设备恢复", createdAt: start)
        try repository.save(task)
        try await repository.acknowledgeOperations(
            opIds: try await repository.pendingOperations(limit: 50).map(\.opId)
        )
        try repository.delete(id: task.id)
        #expect(try repository.fetchTrash().count == 1)

        let restored = try TodoTask(
            id: UUID(),
            seriesID: task.seriesID,
            title: task.title,
            categoryID: task.categoryID,
            startDate: task.startDate,
            endDate: task.endDate,
            sortIndex: task.sortIndex,
            createdAt: task.createdAt,
            updatedAt: start.addingTimeInterval(60)
        )
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                restored,
                kind: .upsert,
                lamport: 11,
                serverSequence: 1,
                deviceID: "device-other",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)

        #expect(try repository.fetchTrash().isEmpty)
        #expect(try repository.fetchAll().map(\.id) == [restored.id])
    }

    @Test("同 seriesID 的不同内容快照不会被恢复任务误删")
    func restoredTaskDoesNotRemoveDifferentSnapshot() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let seriesID = UUID()
        let day = date("2026-07-16T00:00:00+08:00")
        let createdAt = date("2026-07-15T08:00:00+08:00")
        let edited = try TodoTask(
            id: UUID(),
            seriesID: seriesID,
            title: "新内容",
            categoryID: "main",
            startDate: day,
            endDate: day,
            sortIndex: 0,
            createdAt: createdAt
        )
        try repository.save(edited)
        try repository.delete(id: edited.id)
        #expect(try repository.trashCount() == 1)

        let restoredOld = try TodoTask(
            id: UUID(),
            seriesID: seriesID,
            title: "旧内容",
            categoryID: "main",
            startDate: day,
            endDate: day,
            sortIndex: 0,
            createdAt: createdAt
        )
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                restoredOld,
                kind: .upsert,
                lamport: 20,
                serverSequence: 1,
                deviceID: "device-other",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)

        #expect(try repository.fetchTrash().map(\.task.title) == ["新内容"])
        #expect(try repository.fetchAll().map(\.title) == ["旧内容"])
    }

    @Test("同 seriesID 的其他 live 任务内容不同时仍保留删除快照")
    func tombstoneKeepsSnapshotWhenSiblingContentDiffers() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let seriesID = UUID()
        let day = date("2026-07-16T00:00:00+08:00")
        let createdAt = date("2026-07-15T08:00:00+08:00")
        let newer = try TodoTask(
            id: UUID(),
            seriesID: seriesID,
            title: "新内容",
            categoryID: "main",
            startDate: day,
            endDate: day,
            sortIndex: 0,
            createdAt: createdAt
        )
        let sibling = try TodoTask(
            id: UUID(),
            seriesID: seriesID,
            title: "旧内容",
            categoryID: "main",
            startDate: day,
            endDate: day,
            sortIndex: 0,
            createdAt: createdAt
        )
        try repository.save([newer, sibling])

        try await repository.applyRemoteOperations([
            try remoteTombstoneOperation(
                entityID: newer.id.uuidString.lowercased(),
                lamport: 20,
                serverSequence: 1,
                deviceID: "device-other",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)

        #expect(try repository.fetchTrash().map(\.task.title) == ["新内容"])
        #expect(try repository.fetchAll().map(\.title) == ["旧内容"])
    }

    @Test("撤销完成写入明确的 reopen 操作")
    func reopenEntersOutbox() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let start = date("2026-07-15T08:00:00+08:00")
        var task = try makeTask(title: "误点完成", createdAt: start)
        try repository.save(task)
        task.status = .completed
        task.completedAt = start.addingTimeInterval(60)
        task.updatedAt = start.addingTimeInterval(60)
        try repository.save(task)

        #expect(try repository.reopenCompleted(
            id: task.id,
            at: start.addingTimeInterval(120)
        ))

        let operations = try await repository.pendingOperations(limit: 50)
        #expect(operations.map(\.kind) == [.upsert, .complete, .reopen])
        guard case .task(let payload) = try open(
            try #require(operations.last),
            configuration: configuration
        ) else {
            Issue.record("reopen 应携带任务正文")
            return
        }
        #expect(payload.state == .pending)
        #expect(payload.settledAt == nil)
    }

    @Test("批量清除历史会为每条记录写入 tombstone")
    func clearHistoryEntersOutbox() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let start = date("2026-07-15T08:00:00+08:00")
        var completed = try makeTask(title: "已完成", createdAt: start)
        var passed = try makeTask(
            title: "已 Pass",
            createdAt: start.addingTimeInterval(1),
            sortIndex: 1
        )
        let pending = try makeTask(
            title: "保留待办",
            createdAt: start.addingTimeInterval(2),
            sortIndex: 2
        )
        try repository.save([completed, passed, pending])
        completed.status = .completed
        completed.completedAt = start.addingTimeInterval(3)
        completed.updatedAt = start.addingTimeInterval(3)
        passed.status = .pass
        passed.completedAt = start.addingTimeInterval(4)
        passed.updatedAt = start.addingTimeInterval(4)
        try repository.save([completed, passed])
        let existing = try await repository.pendingOperations(limit: 50)
        try await repository.acknowledgeOperations(opIds: existing.map(\.opId))

        #expect(try repository.clearHistory(ids: nil) == 2)
        #expect(try repository.clearHistory(ids: nil) == 0)

        let deletions = try await repository.pendingOperations(limit: 50)
        #expect(deletions.map(\.kind) == [.delete, .delete])
        let tombstoneIDs = try Set(deletions.map { operation -> String in
            guard case .tombstone(let tombstone) = try open(
                operation,
                configuration: configuration
            ) else {
                throw SQLiteRepositoryError.invalidRecord("历史清除操作应为 tombstone")
            }
            return tombstone.id
        })
        #expect(tombstoneIDs == Set([completed.id, passed.id].map { $0.uuidString.lowercased() }))
        #expect(try repository.fetchAll().map(\.id) == [pending.id])
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

    @Test("显示配置只留在本机，绑定同步身份后也不会入队")
    func displayConfigurationStaysLocal() async throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let display = try displayConfiguration(
            header: "{weekdayEn} · 今日任务",
            subtitle: "已进行 {elapsedMonthsDays}",
            startDate: "2026-01-01",
            deadlineDate: "2026-12-31"
        )
        try repository.saveDisplayConfiguration(display)
        #expect(try await repository.pendingOperations(limit: 50).isEmpty)

        let configuration = syncConfiguration()
        try repository.configureSync(configuration)
        // 标题、副标题与计时模板属于个人偏好，不能出现在同步队列里。
        #expect(try await repository.pendingOperations(limit: 50).isEmpty)
        #expect(try repository.displayConfiguration() == display)

        try repository.saveDisplayConfiguration(display)
        try repository.configureSync(configuration)
        #expect(try await repository.pendingOperations(limit: 50).isEmpty)
        #expect(try repository.displayConfiguration() == display)
    }

    @Test("重置同步绑定保留任务与显示配置并为新空间重新生成快照")
    func resetSyncBindingPreservesLocalSnapshot() async throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let task = try makeTask(
            title: "切换同步方式后保留",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        let display = try displayConfiguration(header: "切换后保留显示配置")
        try repository.save(task)
        try repository.seedDisplayConfiguration(display)
        let oldConfiguration = syncConfiguration()
        try repository.configureSync(oldConfiguration)
        let oldOperations = try await repository.pendingOperations(limit: 50)
        try await repository.acknowledgeOperations(opIds: oldOperations.map(\.opId))

        try repository.resetSyncBinding()

        #expect(try repository.fetchAll().map(\.id) == [task.id])
        #expect(try repository.displayConfiguration() == display)
        #expect(try await repository.pendingOperations(limit: 50).isEmpty)

        let replacement = SQLiteSyncConfiguration(
            vaultId: "vault-replacement",
            deviceId: "device-replacement",
            vaultKey: Data((32..<64).map { UInt8($0) })
        )
        try repository.configureSync(replacement)
        let replacementOperations = try await repository.pendingOperations(limit: 50)
        // 换绑只为任务重建快照，显示配置仍然只留在本机。
        #expect(Set(replacementOperations.map(\.entityId)) == Set([task.id.uuidString.lowercased()]))
    }

    @Test("原子替换同步绑定会直接重绑并保留本地任务")
    func replaceSyncBindingPreservesTasks() async throws {
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: syncConfiguration()
        )
        let task = try makeTask(
            title: "原子切换同步方式",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        try repository.save(task)
        let replacement = SQLiteSyncConfiguration(
            vaultId: "vault-atomic-replacement",
            deviceId: "device-atomic-replacement",
            vaultKey: Data((64..<96).map { UInt8($0) })
        )

        try repository.replaceSyncBinding(with: replacement)

        #expect(try repository.fetchAll().map(\.id) == [task.id])
        let operations = try await repository.pendingOperations(limit: 50)
        #expect(operations.map(\.entityId) == [task.id.uuidString.lowercased()])
        guard let operation = operations.first,
              case .task(let payload) = try open(operation, configuration: replacement) else {
            Issue.record("新空间应收到使用新密钥加密的本地任务快照")
            return
        }
        #expect(payload.title == task.title)
    }

    @Test("切回旧同步空间时本地快照从远端 Lamport 水位之后继续")
    func replaceSyncBindingContinuesAfterRemoteLamportFloor() async throws {
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: syncConfiguration()
        )
        let task = try makeTask(
            title: "切回旧空间仍保留当前版本",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        try repository.save(task)
        let replacement = SQLiteSyncConfiguration(
            vaultId: "vault-returning",
            deviceId: "device-returning",
            vaultKey: Data((96..<128).map { UInt8($0) })
        )

        try repository.replaceSyncBinding(with: replacement, remoteLamportFloor: 42)

        let operations = try await repository.pendingOperations(limit: 50)
        #expect(operations.first?.lamport == 43)
        #expect(operations.allSatisfy { $0.lamport > 42 })
    }

    @Test("新设备默认显示配置不会覆盖同步空间已有配置")
    func seededDisplayConfigurationDoesNotCreateBaseline() async throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let localDefault = try displayConfiguration(header: "新设备默认值")
        try repository.seedDisplayConfiguration(localDefault)

        try repository.configureSync(syncConfiguration())

        #expect(try await repository.pendingOperations(limit: 50).isEmpty)
        #expect(try repository.displayConfiguration() == localDefault)
    }

    @Test("备份不能恢复到仅任务表为空但仍有删除历史的任务库")
    func backupRestoreRejectsResidualDeletionHistory() throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let deleted = try makeTask(
            title: "删除后任务表为空",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        try repository.save(deleted)
        try repository.delete(id: deleted.id)
        #expect(try repository.fetchAll().isEmpty)

        let incoming = try makeTask(
            title: "另一份备份中的任务",
            createdAt: date("2026-07-16T08:00:00+08:00")
        )
        let source = try SQLiteTaskRepository(path: ":memory:")
        try source.save(incoming)
        let payload = try #require(source.makeBackupPayloads().first)

        do {
            try repository.restoreBackupPayloads([payload])
            Issue.record("残留删除历史时不应允许导入另一份备份")
        } catch SQLiteRepositoryError.backupDestinationNotEmpty {
            // 预期拒绝，避免把两份本地历史隐式合并。
        }
    }

    @Test("同步密钥暂不可用时本地变更会在恢复后补入 outbox")
    func deferredMutationsRecoverAfterCredentialsReturn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-deferred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite").path
        let configuration = syncConfiguration()
        let start = date("2026-07-15T08:00:00+08:00")
        var edited = try makeTask(title: "等待修改", createdAt: start)
        let deleted = try makeTask(
            title: "等待删除",
            createdAt: start.addingTimeInterval(1)
        )

        do {
            let repository = try SQLiteTaskRepository(
                path: path,
                syncConfiguration: configuration
            )
            try repository.save([edited, deleted])
            let baseline = try await repository.pendingOperations(limit: 50)
            try await repository.acknowledgeOperations(opIds: baseline.map(\.opId))
        }

        let localOnly = try SQLiteTaskRepository(path: path)
        edited.title = "密钥恢复前已修改"
        edited.updatedAt = start.addingTimeInterval(60)
        try localOnly.save(edited)
        try localOnly.delete(id: deleted.id)
        #expect(try localOnly.fetchAll().map(\.id) == [edited.id])
        #expect(try await localOnly.pendingOperations(limit: 50).isEmpty)

        try localOnly.configureSync(configuration)
        let recovered = try await localOnly.pendingOperations(limit: 50)
        #expect(recovered.map(\.kind) == [.upsert, .delete])
        guard case .task(let task) = try open(recovered[0], configuration: configuration) else {
            Issue.record("恢复后的首条操作应为最新任务快照")
            return
        }
        #expect(task.title == "密钥恢复前已修改")
        guard case .tombstone(let tombstone) = try open(
            recovered[1],
            configuration: configuration
        ) else {
            Issue.record("恢复后的删除应补为 tombstone")
            return
        }
        #expect(tombstone.id == deleted.id.uuidString.lowercased())

        try localOnly.configureSync(configuration)
        #expect(try await localOnly.pendingOperations(limit: 50) == recovered)
    }

    @Test("恢复同步密钥时只补录实际离线修改的实体")
    func deferredJournalDoesNotSnapshotUntouchedTasks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-deferred-dirty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite").path
        let configuration = syncConfiguration()
        let start = date("2026-07-15T08:00:00+08:00")
        var modified = try makeTask(title: "任务 A", createdAt: start)
        let untouched = try makeTask(
            title: "任务 B",
            createdAt: start.addingTimeInterval(1),
            sortIndex: 1
        )

        do {
            let repository = try SQLiteTaskRepository(
                path: path,
                syncConfiguration: configuration
            )
            try repository.save([modified, untouched])
            let baseline = try await repository.pendingOperations(limit: 50)
            try await repository.acknowledgeOperations(opIds: baseline.map(\.opId))
        }

        let localOnly = try SQLiteTaskRepository(path: path)
        modified.title = "仅修改任务 A"
        modified.updatedAt = start.addingTimeInterval(60)
        try localOnly.save(modified)
        try localOnly.configureSync(configuration)

        let recovered = try await localOnly.pendingOperations(limit: 50)
        #expect(recovered.count == 1)
        #expect(recovered.first?.entityId == modified.id.uuidString.lowercased())
        #expect(!recovered.map(\.entityId).contains(untouched.id.uuidString.lowercased()))
        guard let operation = recovered.first,
              case .task(let payload) = try open(operation, configuration: configuration) else {
            Issue.record("恢复操作应只包含任务 A 的最新快照")
            return
        }
        #expect(payload.title == "仅修改任务 A")
    }

    @Test("同步密钥恢复后只补录最新一份离线显示配置")
    func deferredDisplayConfigurationRecoversLatestValue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-display-deferred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite").path
        let configuration = syncConfiguration()

        do {
            let repository = try SQLiteTaskRepository(
                path: path,
                syncConfiguration: configuration
            )
            try repository.saveDisplayConfiguration(try displayConfiguration(header: "初始"))
            let baseline = try await repository.pendingOperations(limit: 50)
            try await repository.acknowledgeOperations(opIds: baseline.map(\.opId))
        }

        let localOnly = try SQLiteTaskRepository(path: path)
        try localOnly.saveDisplayConfiguration(try displayConfiguration(header: "离线版本一"))
        let latest = try displayConfiguration(
            header: "离线版本二",
            subtitle: "截止 {deadlineMonthsDays}",
            deadlineDate: "2027-01-01"
        )
        try localOnly.saveDisplayConfiguration(latest)
        #expect(try await localOnly.pendingOperations(limit: 50).isEmpty)

        try localOnly.configureSync(configuration)
        // 恢复同步身份后也不会补录显示配置，本机偏好始终不离开设备。
        #expect(try await localOnly.pendingOperations(limit: 50).isEmpty)
        #expect(try localOnly.displayConfiguration() == latest)
        try localOnly.configureSync(configuration)
        #expect(try await localOnly.pendingOperations(limit: 50).isEmpty)
    }

    @Test("同步身份不匹配后本地仓储仍可编辑并等待正确身份恢复")
    func identityMismatchKeepsLocalRepositoryUsable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-identity-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite").path
        let configuration = syncConfiguration()
        let start = date("2026-07-15T08:00:00+08:00")
        var task = try makeTask(title: "原任务", createdAt: start)

        do {
            let repository = try SQLiteTaskRepository(
                path: path,
                syncConfiguration: configuration
            )
            try repository.save(task)
            let baseline = try await repository.pendingOperations(limit: 50)
            try await repository.acknowledgeOperations(opIds: baseline.map(\.opId))
        }

        let localOnly = try SQLiteTaskRepository(path: path)
        let mismatched = SQLiteSyncConfiguration(
            vaultId: "vault-other",
            deviceId: "device-other",
            vaultKey: configuration.vaultKey,
            timeZone: configuration.timeZone
        )
        do {
            try localOnly.configureSync(mismatched)
            Issue.record("不匹配的同步身份应被拒绝")
        } catch SQLiteRepositoryError.syncIdentityMismatch {
            // 预期只禁用同步，不关闭本地仓储。
        }

        task.title = "身份不匹配后仍可编辑"
        task.updatedAt = start.addingTimeInterval(60)
        try localOnly.save(task)
        #expect(try localOnly.fetchAll().first?.title == "身份不匹配后仍可编辑")
        #expect(try await localOnly.pendingOperations(limit: 50).isEmpty)

        try localOnly.configureSync(configuration)
        let recovered = try await localOnly.pendingOperations(limit: 50)
        #expect(recovered.count == 1)
        #expect(recovered.first?.entityId == task.id.uuidString.lowercased())
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

    @Test("保存自定义分类会入队占位显示配置")
    func savingCategoriesEnqueuesRedactedDisplayConfiguration() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let localDisplay = try displayConfiguration(header: "本机标题", subtitle: "本机副标题")
        try repository.saveDisplayConfiguration(localDisplay)
        let categories = TaskCategory.normalizeList(
            TaskCategory.defaults + [try TaskCategory(id: "work", name: "工作", order: 4)]
        )

        try repository.saveCategories(categories)

        let operations = try await repository.pendingOperations(limit: 50)
        #expect(operations.count == 1)
        guard case .displayConfiguration(let payload) = try open(
            operations[0],
            configuration: configuration
        ) else {
            Issue.record("分类同步应使用显示配置正文")
            return
        }
        #expect(payload.headerTemplate == "")
        #expect(payload.subtitleTemplate == "")
        #expect(payload.startDate == "2000-01-01")
        #expect(payload.deadlineDate == "2000-01-01")
        #expect(payload.questLines.map(\.id) == categories.map(\.id))
        #expect(try repository.displayConfiguration() == localDisplay)
    }

    @Test("默认分类首次绑定不产生分类操作")
    func defaultCategoriesProduceNoBaseline() async throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        try repository.configureSync(syncConfiguration())

        #expect(try await repository.pendingOperations(limit: 50).isEmpty)
    }

    @Test("自定义分类首次绑定产生基线")
    func customCategoriesProduceBaselineOnFirstBinding() async throws {
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let categories = TaskCategory.normalizeList(
            TaskCategory.defaults + [try TaskCategory(id: "work", name: "工作", order: 4)]
        )
        try repository.saveCategories(categories)
        let configuration = syncConfiguration()
        try repository.configureSync(configuration)

        let operations = try await repository.pendingOperations(limit: 50)
        #expect(operations.count == 1)
        guard case .displayConfiguration(let payload) = try open(
            operations[0],
            configuration: configuration
        ) else {
            Issue.record("首次绑定应补发分类基线")
            return
        }
        #expect(payload.questLines.map(\.id) == categories.map(\.id))
    }

    @Test("远端分类列表会替换并重分配未知待办")
    func remoteCategoriesReplaceAndReassignPendingTasks() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let localDisplay = try displayConfiguration(header: "保留本机标题")
        try repository.saveDisplayConfiguration(localDisplay)
        let categories = TaskCategory.normalizeList(
            TaskCategory.defaults + [try TaskCategory(id: "work", name: "工作", order: 4)]
        )
        try repository.saveCategories(categories)
        let pending = try TodoTask(
            title: "工作待办",
            categoryID: "work",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        let settled = try TodoTask(
            title: "工作完成",
            categoryID: "work",
            status: .completed,
            createdAt: date("2026-07-15T09:00:00+08:00"),
            completedAt: date("2026-07-15T10:00:00+08:00")
        )
        try repository.save([pending, settled])
        let existing = try await repository.pendingOperations(limit: 50)
        try await repository.acknowledgeOperations(opIds: existing.map(\.opId))

        let remote = try WireDisplayConfigurationPayload(
            headerTemplate: "",
            subtitleTemplate: "",
            startDate: "2000-01-01",
            deadlineDate: "2000-01-01",
            questLines: [
                try WireQuestLineDefinition(id: "inbox", name: "未分类", order: 0),
                try WireQuestLineDefinition(id: "main", name: "主线", order: 1),
            ]
        )
        try await repository.applyRemoteOperations([
            try remoteDisplayConfigurationOperation(
                remote,
                lamport: 10,
                serverSequence: 1,
                deviceID: "device-remote",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)

        #expect(try repository.fetchCategories().map(\.id) == ["inbox", "main"])
        let stored = try repository.fetchAll()
        #expect(stored.first { $0.id == pending.id }?.categoryID == "inbox")
        #expect(stored.first { $0.id == settled.id }?.categoryID == "work")
        #expect(try repository.displayConfiguration() == localDisplay)
        let reassigned = try await repository.pendingOperations(limit: 50)
        #expect(reassigned.contains {
            $0.entityId == pending.id.uuidString.lowercased() && $0.kind == .upsert
        })
    }

    @Test("远端空分类不会修改本机分类")
    func emptyRemoteCategoriesDoNotChangeLocalCategories() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let categories = TaskCategory.normalizeList(
            TaskCategory.defaults + [try TaskCategory(id: "work", name: "工作", order: 4)]
        )
        try repository.saveCategories(categories)
        let existing = try await repository.pendingOperations(limit: 50)
        try await repository.acknowledgeOperations(opIds: existing.map(\.opId))

        try await repository.applyRemoteOperations([
            try remoteDisplayConfigurationOperation(
                try displayConfiguration(header: "远端标题"),
                lamport: 10,
                serverSequence: 1,
                deviceID: "device-remote",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)

        #expect(try repository.fetchCategories() == categories)
    }

    @Test("替换同步绑定保留分类并重建基线")
    func replacingSyncBindingPreservesCategories() async throws {
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: syncConfiguration()
        )
        let categories = TaskCategory.normalizeList(
            TaskCategory.defaults + [try TaskCategory(id: "work", name: "工作", order: 4)]
        )
        try repository.saveCategories(categories)
        let existing = try await repository.pendingOperations(limit: 50)
        try await repository.acknowledgeOperations(opIds: existing.map(\.opId))
        let replacement = SQLiteSyncConfiguration(
            vaultId: "vault-replacement",
            deviceId: "device-replacement",
            vaultKey: Data((32..<64).map { UInt8($0) }),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )

        try repository.replaceSyncBinding(with: replacement)

        #expect(try repository.fetchCategories() == categories)
        let operations = try await repository.pendingOperations(limit: 50)
        #expect(operations.count == 1)
        guard case .displayConfiguration(let payload) = try open(
            operations[0],
            configuration: replacement
        ) else {
            Issue.record("换绑后应补发分类基线")
            return
        }
        #expect(payload.questLines.map(\.id) == categories.map(\.id))
    }

    @Test("远端显示配置不会覆盖本机标题副标题，也不回写 outbox")
    func remoteDisplayConfigurationIsIgnored() async throws {
        let configuration = syncConfiguration()
        let local = try displayConfiguration(header: "本机标题", subtitle: "本机副标题")
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        try repository.saveDisplayConfiguration(local)
        #expect(try await repository.pendingOperations(limit: 50).isEmpty)

        try await repository.applyRemoteOperations([
            try remoteDisplayConfigurationOperation(
                try displayConfiguration(header: "别人的标题", subtitle: "别人的副标题"),
                lamport: 2,
                serverSequence: 1,
                deviceID: "device-z",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)

        // 游标照常推进，但本机偏好保持不变。
        #expect(try await repository.currentCursor() == 1)
        #expect(try repository.displayConfiguration() == local)
        #expect(try await repository.pendingOperations(limit: 50).isEmpty)
    }

    @Test("固定显示配置实体拒绝 tombstone 且整页回滚")
    func displayConfigurationRejectsTombstone() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        do {
            try await repository.applyRemoteOperations([
                try remoteTombstoneOperation(
                    entityID: SQLiteTaskRepository.displayConfigurationEntityID,
                    lamport: 1,
                    serverSequence: 1,
                    deviceID: "device-old",
                    configuration: configuration
                ),
            ], advancingCursorTo: 1)
            Issue.record("固定显示配置实体不应接受 tombstone")
        } catch SQLiteRepositoryError.invalidRemotePage(_) {
            // 旧客户端不能删除固定配置实体。
        }
        #expect(try repository.displayConfiguration() == nil)
        #expect(try await repository.currentCursor() == 0)
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

    @Test("低版本 tombstone 的删除时间与记录版本同源且更新的 tombstone 会刷新删除时间")
    func staleTombstoneDeletionTimeMatchesRecordedVersion() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let task = try makeTask(
            title: "将被旧 tombstone 删除",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        // 高版本活跃任务（lamport 100）。
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                task,
                kind: .upsert,
                lamport: 100,
                serverSequence: 1,
                deviceID: "device-newer",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)
        // 低版本 tombstone（lamport 2）：删除仍生效（终态），
        // 记录版本与删除时间都必须来自该 tombstone，而不是混合高版本活跃记录的 lamport。
        let earlyDeletion = milliseconds(date("2026-07-15T09:00:00+08:00"))
        try await repository.applyRemoteOperations([
            try remoteTombstoneOperation(
                entityID: task.id.uuidString.lowercased(),
                lamport: 2,
                serverSequence: 2,
                deviceID: "device-stale",
                configuration: configuration,
                deletedAt: earlyDeletion
            ),
        ], advancingCursorTo: 2)
        #expect(try repository.fetchAll().isEmpty)

        // 更高版本 tombstone（lamport 3、更晚的删除时间）应刷新记录：备份导出与记录版本同源。
        let laterDeletion = milliseconds(date("2026-07-15T10:00:00+08:00"))
        try await repository.applyRemoteOperations([
            try remoteTombstoneOperation(
                entityID: task.id.uuidString.lowercased(),
                lamport: 3,
                serverSequence: 3,
                deviceID: "device-stale",
                configuration: configuration,
                deletedAt: laterDeletion
            ),
        ], advancingCursorTo: 3)
        let tombstones = try repository.makeBackupTombstones()
        #expect(tombstones.count == 1)
        #expect(tombstones[0].deletedAt == laterDeletion)
    }

    @Test("同步 applied 记录裁剪到最近 10000 条")
    func syncAppliedTableIsBounded() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let task = try makeTask(
            title: "裁剪测试",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        let total = 10_001
        let operations = try (1...total).map { sequence in
            try remoteTaskOperation(
                task,
                kind: .upsert,
                lamport: Int64(sequence),
                serverSequence: Int64(sequence),
                deviceID: "device-trim",
                configuration: configuration
            )
        }
        try await repository.applyRemoteOperations(
            operations,
            advancingCursorTo: Int64(total)
        )
        #expect(try repository.syncAppliedOperationCount() == 10_000)
        #expect(try await repository.currentCursor() == Int64(total))
        #expect(try repository.fetchAll().map(\.title) == ["裁剪测试"])
    }

    @Test("服务端状态丢失重建（CURSOR_AHEAD）后客户端自动恢复同步")
    func cursorAheadRecoversAfterServerStateLoss() async throws {
        let configuration = syncConfiguration()
        let deviceToken = Base64URL.encode(Data(repeating: 1, count: 32))

        // 第一阶段：正常同步，客户端游标推进到 1。
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        try repository.save(makeTask(
            title: "第一台设备任务",
            createdAt: date("2026-07-15T08:00:00+08:00")
        ))
        let firstServer = CursorAwareStubServer(deviceId: configuration.deviceId)
        let firstCoordinator = SyncCoordinator(
            transport: firstServer,
            outbox: repository,
            local: repository,
            deviceToken: deviceToken
        )
        let firstSummary = try await firstCoordinator.synchronize()
        #expect(firstSummary.pushed == 1)
        #expect(firstSummary.finalCursor == 1)

        // 第二阶段：服务端状态丢失后从序号 1 重建（maxCursor = 0）。
        // 客户端 cursor=1 触发 409 CURSOR_AHEAD；协调器应重置本地游标并自动恢复，不抛错。
        let rebuiltServer = CursorAwareStubServer(deviceId: configuration.deviceId)
        let recoveredCoordinator = SyncCoordinator(
            transport: rebuiltServer,
            outbox: repository,
            local: repository,
            deviceToken: deviceToken
        )
        let recoveredSummary = try await recoveredCoordinator.synchronize()
        #expect(recoveredSummary.finalCursor == 0)
        #expect(try await repository.currentCursor() == 0)

        // 第三阶段：恢复后本地新变更照常同步，游标重新推进。
        try repository.save(makeTask(
            title: "恢复后的新任务",
            createdAt: date("2026-07-16T08:00:00+08:00")
        ))
        let finalSummary = try await recoveredCoordinator.synchronize()
        #expect(finalSummary.pushed == 1)
        #expect(finalSummary.finalCursor == 1)
        #expect(try repository.fetchAll().map(\.title).sorted() == [
            "恢复后的新任务", "第一台设备任务",
        ])
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

    @Test("较新的显式 reopen 可以同步恢复跨周期一次性完成项")
    func explicitReopenRestoresExpiredOnceTask() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let id = UUID()
        let createdAt = date("2026-07-15T08:00:00+08:00")
        let completed = try makeTask(
            id: id,
            title: "误点完成",
            status: .completed,
            createdAt: createdAt,
            updatedAt: date("2026-07-15T20:00:00+08:00"),
            settledAt: date("2026-07-15T20:00:00+08:00")
        )
        let reopened = try makeTask(
            id: id,
            title: "误点完成",
            createdAt: createdAt,
            updatedAt: date("2026-07-16T00:00:00+08:00")
        )

        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                completed,
                kind: .complete,
                lamport: 2,
                serverSequence: 1,
                deviceID: "device-completed",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)
        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                reopened,
                kind: .reopen,
                lamport: 9,
                serverSequence: 2,
                deviceID: "device-reopen",
                configuration: configuration
            ),
        ], advancingCursorTo: 2)

        let result = try #require(try repository.fetchAll().first)
        #expect(result.status == .pending)
        #expect(result.completedAt == nil)
    }

    @Test("显式 reopen 可以跨周期恢复待办")
    func explicitReopenAcrossPeriodRestoresPending() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let id = UUID()
        let createdAt = date("2026-07-15T08:00:00+08:00")
        let completed = try makeTask(
            id: id,
            title: "每日复盘",
            status: .completed,
            createdAt: createdAt,
            updatedAt: date("2026-07-15T20:00:00+08:00"),
            settledAt: date("2026-07-15T20:00:00+08:00")
        )
        let reopened = try makeTask(
            id: id,
            title: "每日复盘",
            createdAt: createdAt,
            updatedAt: date("2026-07-16T00:00:00+08:00")
        )

        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                completed,
                kind: .complete,
                lamport: 2,
                serverSequence: 1,
                deviceID: "device-completed",
                configuration: configuration
            ),
        ], advancingCursorTo: 1)

        try await repository.applyRemoteOperations([
            try remoteTaskOperation(
                reopened,
                kind: .reopen,
                lamport: 9,
                serverSequence: 2,
                deviceID: "device-reopen",
                configuration: configuration
            ),
        ], advancingCursorTo: 2)

        let cursor = try await repository.currentCursor()
        #expect(cursor == 2)
        let result = try #require(try repository.fetchAll().first)
        #expect(result.status == .pending)
        #expect(result.completedAt == nil)
    }

    @Test("completed 优先于 pass 且保留有效完成字段")
    func completionOverridesNewerPass() async throws {
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

        #expect(try repository.fetchAll().first?.status == .completed)
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

    @Test("WebDAV 重复操作幂等且不推进 Worker cursor")
    func webDavDuplicateIsIdempotent() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let task = try makeTask(
            title: "WebDAV 只应用一次",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        let pulled = try remoteTaskOperation(
            task,
            kind: .upsert,
            lamport: 7,
            serverSequence: 1,
            deviceID: "device-webdav",
            configuration: configuration
        )
        let operation = try webDavOperation(from: pulled, configuration: configuration)
        try await repository.applyWebDavOperations([operation])

        let corrupted = try WebDavOperation(
            vaultId: configuration.vaultId,
            deviceId: pulled.deviceId,
            operation: SyncPushOperation(
                opId: pulled.opId,
                entityId: pulled.entityId,
                kind: pulled.kind,
                lamport: pulled.lamport,
                ciphertext: Base64URL.encode(Data(repeating: 9, count: 16)),
                nonce: pulled.nonce
            )
        )
        try await repository.applyWebDavOperations([corrupted])

        #expect(try repository.fetchAll().first?.title == "WebDAV 只应用一次")
        #expect(try await repository.currentCursor() == 0)
        #expect(try await repository.pendingOperations(limit: 50).isEmpty)
    }

    @Test("WebDAV 单条坏密文只跳过，不阻塞整批且保留本地任务")
    func webDavBadOperationIsSkippedAndDoesNotBlockBatch() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let localTask = try makeTask(
            title: "本地任务必须保留",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        try repository.save(localTask)
        let task = try makeTask(
            title: "同批好操作",
            createdAt: date("2026-07-16T08:00:00+08:00")
        )
        let valid = try webDavOperation(
            from: remoteTaskOperation(
                task,
                kind: .upsert,
                lamport: 1,
                serverSequence: 1,
                deviceID: "device-webdav",
                configuration: configuration
            ),
            configuration: configuration
        )
        let broken = try WebDavOperation(
            vaultId: configuration.vaultId,
            deviceId: "device-webdav",
            operation: SyncPushOperation(
                opId: "operation-webdav-broken",
                entityId: localTask.id.uuidString.lowercased(),
                kind: .upsert,
                lamport: 2,
                ciphertext: Base64URL.encode(Data(repeating: 2, count: 16)),
                nonce: Base64URL.encode(Data(repeating: 3, count: 12))
            )
        )

        try await repository.applyWebDavOperations([valid, broken])

        // 好操作正常落地；坏操作按 opId 记为已处理，本地任务保持原样。
        #expect(try repository.fetchAll().map(\.title).contains("同批好操作"))
        #expect(try repository.fetchAll().first { $0.id == localTask.id }?.title
            == "本地任务必须保留")
        #expect(try await repository.pendingWebDavOperationIDs(
            [valid.opId, broken.opId]
        ).isEmpty)

        // 再次应用同一批不会重试坏操作，也不会重复写入。
        try await repository.applyWebDavOperations([valid, broken])
        #expect(try repository.webDavAppliedOperationCount() == 2)
        #expect(try repository.fetchAll().filter { $0.title == "同批好操作" }.count == 1)
    }

    @Test("WebDAV applied 记录裁剪到最近 10000 条且重放不增长")
    func webDavAppliedTableIsBounded() async throws {
        let configuration = syncConfiguration()
        let repository = try SQLiteTaskRepository(
            path: ":memory:",
            syncConfiguration: configuration
        )
        let task = try makeTask(
            title: "WebDAV 裁剪测试",
            createdAt: date("2026-07-15T08:00:00+08:00")
        )
        let total = 10_001
        let operations = try (1...total).map { index in
            try webDavOperation(
                from: remoteTaskOperation(
                    task,
                    kind: .upsert,
                    lamport: Int64(index),
                    serverSequence: Int64(index),
                    deviceID: "device-webdav",
                    configuration: configuration
                ),
                configuration: configuration
            )
        }
        try await repository.applyWebDavOperations(operations)
        #expect(try repository.webDavAppliedOperationCount() == 10_000)
        #expect(try repository.fetchAll().map(\.title) == ["WebDAV 裁剪测试"])

        // 幂等重放整批旧对象：全部被 applied 表去重跳过，行数不增长。
        try await repository.applyWebDavOperations(operations)
        #expect(try repository.webDavAppliedOperationCount() == 10_000)
        #expect(try repository.fetchAll().map(\.title) == ["WebDAV 裁剪测试"])
    }
}

private func webDavOperation(
    from operation: SyncPulledOperation,
    configuration: SQLiteSyncConfiguration
) throws -> WebDavOperation {
    try WebDavOperation(
        vaultId: configuration.vaultId,
        deviceId: operation.deviceId,
        operation: SyncPushOperation(
            opId: operation.opId,
            entityId: operation.entityId,
            kind: operation.kind,
            lamport: operation.lamport,
            ciphertext: operation.ciphertext,
            nonce: operation.nonce
        )
    )
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
    sortIndex: Int = 0,
    recurrence: TaskRecurrence = .once
) throws -> TodoTask {
    let day = TodoTask.protocolCalendar.startOfDay(for: createdAt)
    return try TodoTask(
        id: id,
        title: title,
        categoryID: "main",
        status: status,
        startDate: day,
        endDate: day,
        sortIndex: sortIndex,
        createdAt: createdAt,
        updatedAt: updatedAt ?? createdAt,
        completedAt: status == .pending ? nil : settledAt,
        recurrence: recurrence
    )
}

private func displayConfiguration(
    header: String,
    subtitle: String = "",
    startDate: String = "2026-01-01",
    deadlineDate: String = "2026-12-31"
) throws -> WireDisplayConfigurationPayload {
    try WireDisplayConfigurationPayload(
        headerTemplate: header,
        subtitleTemplate: subtitle,
        startDate: startDate,
        deadlineDate: deadlineDate
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
    let recurrence = WireRecurrence.once
    let ranged = task.startDate != nil && task.endDate != nil
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = configuration.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let payload = try WireTaskPayload(
        id: entityID,
        seriesId: task.seriesID.uuidString.lowercased(),
        title: task.title,
        timeType: ranged ? .day : .someday,
        periodStart: task.startDate.map { formatter.string(from: $0) },
        deadlineDate: task.endDate.map { formatter.string(from: $0) },
        timezone: configuration.timeZone.identifier,
        questLine: task.categoryID,
        state: state,
        recurrence: recurrence,
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

private func remoteDisplayConfigurationOperation(
    _ payload: WireDisplayConfigurationPayload,
    lamport: Int64,
    serverSequence: Int64,
    deviceID: String,
    configuration: SQLiteSyncConfiguration
) throws -> SyncPulledOperation {
    let entityID = WireDisplayConfigurationPayload.fixedID
    let operationID = "remote-display-\(serverSequence)-\(lamport)-\(deviceID)"
    let metadata = SyncAADMetadata(
        vaultId: configuration.vaultId,
        operationId: operationID,
        entityId: entityID,
        kind: .upsert,
        lamport: lamport,
        deviceId: deviceID
    )
    let envelope = try TaskPayloadCodec.seal(
        .displayConfiguration(payload),
        vaultKey: configuration.vaultKey,
        metadata: metadata
    )
    return SyncPulledOperation(
        serverSeq: serverSequence,
        opId: operationID,
        deviceId: deviceID,
        entityId: entityID,
        kind: .upsert,
        lamport: lamport,
        ciphertext: envelope.ciphertext,
        nonce: envelope.nonce,
        createdAt: serverSequence
    )
}

private func remoteTombstoneOperation(
    entityID: String,
    lamport: Int64,
    serverSequence: Int64,
    deviceID: String,
    configuration: SQLiteSyncConfiguration,
    deletedAt: Int64 = milliseconds(date("2026-07-15T09:00:00+08:00"))
) throws -> SyncPulledOperation {
    let operationID = "remote-delete-\(serverSequence)-\(deviceID)"
    let payload = try WireTombstonePayload(
        id: entityID,
        deletedAt: deletedAt
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

/// 模拟 Worker 的游标推进：请求游标超过服务端记录时返回 CURSOR_AHEAD。
/// 推送的操作会分配新的 server_seq，并在下一次拉取中回显，交由本地仓储幂等应用。
private actor CursorAwareStubServer: SyncTransport {
    private let deviceId: String
    private var cursor: Int64 = 0
    private var storedOperations: [SyncPulledOperation] = []
    private var seenOperationIDs = Set<String>()

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    func sync(_ request: SyncRequest, deviceToken: String) async throws -> SyncData {
        guard request.cursor <= cursor else {
            throw SyncAPIError.server(
                statusCode: 409,
                payload: ServerErrorPayload(
                    code: "CURSOR_AHEAD",
                    message: "客户端游标超过服务端"
                ),
                requestId: nil
            )
        }
        var inserted = 0
        var duplicates = 0
        for operation in request.push {
            if seenOperationIDs.insert(operation.opId).inserted {
                cursor += 1
                inserted += 1
                storedOperations.append(SyncPulledOperation(
                    serverSeq: cursor,
                    opId: operation.opId,
                    deviceId: deviceId,
                    entityId: operation.entityId,
                    kind: operation.kind,
                    lamport: operation.lamport,
                    ciphertext: operation.ciphertext,
                    nonce: operation.nonce,
                    createdAt: 0
                ))
            } else {
                duplicates += 1
            }
        }
        let pulled = storedOperations.filter { $0.serverSeq > request.cursor }
        return SyncData(
            push: SyncPushSummary(
                received: request.push.count,
                inserted: inserted,
                duplicates: duplicates
            ),
            pull: pulled,
            cursor: pulled.last?.serverSeq ?? request.cursor,
            hasMore: false,
            serverTime: 0
        )
    }
}
