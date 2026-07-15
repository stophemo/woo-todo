package com.wootodo.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupTransferTest {
    @Test
    fun `导出口令必须二次输入完全一致且满足长度要求`() {
        val passphrase = "这是一个足够长的备份口令"
        assertEquals(
            passphrase,
            BackupPassphraseConfirmation.requireConfirmed(passphrase, passphrase),
        )
        assertThrows(BackupTransferException.PassphraseMismatch::class.java) {
            BackupPassphraseConfirmation.requireConfirmed(passphrase, "$passphrase！")
        }
        assertThrows(BackupPackageException.InvalidPassphrase::class.java) {
            BackupPassphraseConfirmation.requireConfirmed("太短", "太短")
        }
    }

    @Test
    fun `恢复策略只允许空任务库无身份且无同步历史的全新安装`() {
        BackupRestorePolicy.requireReady(pristineState(), hasStoredCredentials = false)

        assertThrows(BackupTransferException.ExistingTasks::class.java) {
            BackupRestorePolicy.requireReady(
                pristineState().copy(taskCount = 1),
                hasStoredCredentials = false,
            )
        }
        assertThrows(BackupTransferException.ExistingIdentity::class.java) {
            BackupRestorePolicy.requireReady(
                pristineState(),
                hasStoredCredentials = true,
            )
        }
        assertThrows(BackupTransferException.ExistingIdentity::class.java) {
            BackupRestorePolicy.requireReady(
                pristineState().copy(vaultId = "vault-existing"),
                hasStoredCredentials = false,
            )
        }
        assertThrows(BackupTransferException.ResidualSyncState::class.java) {
            BackupRestorePolicy.requireReady(
                pristineState().copy(tombstoneCount = 1),
                hasStoredCredentials = false,
            )
        }
    }

    @Test
    fun `恢复完整保留任务标识状态和结算时间并为身份生成baseline`() {
        val database = FakeBackupDatabase()
        val credentialsStore = FakeCredentialsStore()
        val coordinator = BackupRestoreCoordinator(database, credentialsStore)
        val completed = task(
            id = "task-completed-0001",
            state = WireTaskState.COMPLETED,
            settledAt = 9_876,
        )
        val passed = task(
            id = "task-passed-0000002",
            state = WireTaskState.PASS,
            settledAt = 12_345,
        )
        val credentials = credentials()

        val result = coordinator.restore(
            BackupSnapshot(
                exportedAt = 20_000,
                tasks = listOf(completed, passed),
                syncCredentials = BackupSyncCredentials.from(credentials),
            ),
        )

        assertEquals(2, result.restoredTaskCount)
        assertTrue(result.syncCredentialsRestored)
        assertEquals(listOf(completed, passed), database.committedTasks)
        assertEquals(listOf(completed, passed), database.baselineTasks)
        assertEquals(completed.id, database.committedTasks[0].id)
        assertEquals(WireTaskState.COMPLETED, database.committedTasks[0].state)
        assertEquals(9_876L, database.committedTasks[0].settledAt)
        assertEquals(WireTaskState.PASS, database.committedTasks[1].state)
        assertEquals(12_345L, database.committedTasks[1].settledAt)
        assertEquals(credentials.vaultId, credentialsStore.stored?.vaultId)
        assertEquals(credentials.deviceId, database.boundDeviceId)
    }

    @Test
    fun `备份任务与SQLite实体往返时历史字段不变`() {
        val original = task(
            id = "task-roundtrip-0001",
            state = WireTaskState.COMPLETED,
            settledAt = 98_765,
        )

        val restored = original.toTaskEntity()
        val roundTrip = restored.toWirePayload()

        assertEquals(original.id, restored.id)
        assertEquals(original.seriesId, restored.seriesId)
        assertEquals(original.state.value, restored.status.rawValue)
        assertEquals(original.settledAt, restored.settledAt)
        assertEquals(original, roundTrip)
    }

    @Test
    fun `不含同步身份时只恢复任务且不创建baseline`() {
        val database = FakeBackupDatabase()
        val credentialsStore = FakeCredentialsStore()
        val task = task("task-local-only-01", WireTaskState.PENDING, null)

        val result = BackupRestoreCoordinator(database, credentialsStore).restore(
            BackupSnapshot(
                exportedAt = 20_000,
                tasks = listOf(task),
                syncCredentials = null,
            ),
        )

        assertEquals(listOf(task), database.committedTasks)
        assertTrue(database.baselineTasks.isEmpty())
        assertNull(credentialsStore.stored)
        assertFalse(result.syncCredentialsRestored)
    }

    @Test
    fun `baseline失败会回滚任务并删除本轮新写入的凭据`() {
        val database = FakeBackupDatabase(failWhileBinding = true)
        val credentialsStore = FakeCredentialsStore()
        val credentials = credentials()

        assertThrows(IllegalStateException::class.java) {
            BackupRestoreCoordinator(database, credentialsStore).restore(
                BackupSnapshot(
                    exportedAt = 20_000,
                    tasks = listOf(task("task-rollback-0001", WireTaskState.PENDING, null)),
                    syncCredentials = BackupSyncCredentials.from(credentials),
                ),
            )
        }

        assertTrue(database.committedTasks.isEmpty())
        assertNull(credentialsStore.stored)
        assertEquals(1, credentialsStore.saveCount)
        assertEquals(1, credentialsStore.deleteCount)
    }

    @Test
    fun `已有Keystore身份时拒绝恢复且绝不调用保存或删除`() {
        val existing = credentials(deviceId = "device-existing")
        val credentialsStore = FakeCredentialsStore(existing)
        val database = FakeBackupDatabase()

        assertThrows(BackupTransferException.ExistingIdentity::class.java) {
            BackupRestoreCoordinator(database, credentialsStore).restore(
                BackupSnapshot(
                    exportedAt = 20_000,
                    tasks = listOf(task("task-must-not-write", WireTaskState.PENDING, null)),
                    syncCredentials = BackupSyncCredentials.from(credentials()),
                ),
            )
        }

        assertTrue(database.committedTasks.isEmpty())
        assertEquals(existing.deviceId, credentialsStore.stored?.deviceId)
        assertEquals(0, credentialsStore.saveCount)
        assertEquals(0, credentialsStore.deleteCount)
    }

    @Test
    fun `检查后若并发出现身份也不会覆盖或在失败清理时删除它`() {
        val concurrentIdentity = credentials(deviceId = "device-concurrent")
        val credentialsStore = FakeCredentialsStore(
            identityAppearingBeforeConditionalSave = concurrentIdentity,
        )
        val database = FakeBackupDatabase()

        assertThrows(BackupTransferException.ExistingIdentity::class.java) {
            BackupRestoreCoordinator(database, credentialsStore).restore(
                BackupSnapshot(
                    exportedAt = 20_000,
                    tasks = listOf(task("task-concurrent-001", WireTaskState.PENDING, null)),
                    syncCredentials = BackupSyncCredentials.from(credentials()),
                ),
            )
        }

        assertTrue(database.committedTasks.isEmpty())
        assertEquals(concurrentIdentity.deviceId, credentialsStore.stored?.deviceId)
        assertEquals(0, credentialsStore.saveCount)
        assertEquals(0, credentialsStore.deleteCount)
    }

    private fun task(
        id: String,
        state: WireTaskState,
        settledAt: Long?,
    ): TaskInstancePayload = TaskInstancePayload(
        id = id,
        seriesId = "series-$id",
        title = "备份任务 $id",
        timeType = WireTimeType.DAY,
        periodStart = "2026-07-16",
        timezone = WIRE_FIXED_TIMEZONE,
        questLine = WireQuestLine.MAIN,
        state = state,
        recurrence = WireRecurrence.ONCE,
        sortOrder = 7,
        createdAt = 1_000,
        updatedAt = 2_000,
        settledAt = settledAt,
    )

    private fun credentials(deviceId: String = "device-backup-test"): SyncCredentials =
        SyncCredentials(
            endpoint = "https://sync.example.test",
            vaultId = "vault-backup-test",
            deviceId = deviceId,
            deviceToken = Base64Url.encode(ByteArray(32) { 3 }),
            vaultKey = ByteArray(32) { (it + 1).toByte() },
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

    private class FakeBackupDatabase(
        private val failWhileBinding: Boolean = false,
    ) : BackupDatabase {
        var state = BackupDatabaseState(
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
        val committedTasks = mutableListOf<TaskInstancePayload>()
        val baselineTasks = mutableListOf<TaskInstancePayload>()
        var boundDeviceId: String? = null

        override fun readState(): BackupDatabaseState = state

        override fun readTaskSnapshot(): BackupTaskSnapshot =
            BackupTaskSnapshot(state, committedTasks.toList())

        override fun <T> inTransaction(block: (BackupRestoreTransaction) -> T): T {
            val pendingTasks = mutableListOf<TaskInstancePayload>()
            var pendingCredentials: SyncCredentials? = null
            val transaction = object : BackupRestoreTransaction {
                override fun readState(): BackupDatabaseState = state

                override fun insertTask(task: TaskInstancePayload) {
                    pendingTasks += task
                }

                override fun bindIdentityAndCreateBaseline(credentials: SyncCredentials) {
                    if (failWhileBinding) error("模拟 baseline 写入失败")
                    pendingCredentials = credentials
                }
            }
            val result = block(transaction)
            committedTasks += pendingTasks
            pendingCredentials?.let { credentials ->
                baselineTasks += pendingTasks
                boundDeviceId = credentials.deviceId
                state = state.copy(
                    taskCount = pendingTasks.size,
                    vaultId = credentials.vaultId,
                    deviceId = credentials.deviceId,
                    lamport = pendingTasks.size.toLong(),
                    outboxCount = pendingTasks.size,
                    entityVersionCount = pendingTasks.size,
                )
            } ?: run {
                state = state.copy(taskCount = pendingTasks.size)
            }
            return result
        }
    }

    private class FakeCredentialsStore(
        initial: SyncCredentials? = null,
        private val identityAppearingBeforeConditionalSave: SyncCredentials? = null,
    ) : SyncCredentialsStore {
        var stored: SyncCredentials? = initial
        var saveCount = 0
        var deleteCount = 0

        override fun save(credentials: SyncCredentials) {
            saveCount += 1
            stored = SyncCredentials(
                endpoint = credentials.endpoint,
                vaultId = credentials.vaultId,
                deviceId = credentials.deviceId,
                deviceToken = credentials.deviceToken,
                vaultKey = credentials.vaultKey,
            )
        }

        override fun saveIfAbsent(credentials: SyncCredentials): Boolean {
            identityAppearingBeforeConditionalSave?.let {
                stored = it
                return false
            }
            if (stored != null) return false
            save(credentials)
            return true
        }

        override fun load(): SyncCredentials? = stored

        override fun delete() {
            deleteCount += 1
            stored = null
        }
    }
}
