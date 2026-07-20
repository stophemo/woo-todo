package com.wootodo.sync

import android.content.Context
import android.database.sqlite.SQLiteConstraintException
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.data.SQLiteTaskStore
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskEntity
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.LocalDate
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SQLiteBackupDatabaseInstrumentedTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    private lateinit var database: TaskDatabase

    @Before
    fun setUp() {
        context.deleteDatabase(DATABASE_NAME)
        database = TaskDatabase(context)
        database.writableDatabase
    }

    @After
    fun tearDown() {
        if (::database.isInitialized) database.close()
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun `SQLite快照读取完整保留已结束任务历史`() = runBlocking {
        val original = taskEntity("task-snapshot-0001", TaskStatus.COMPLETED, 8_888)
        SQLiteTaskStore(database).insert(original)

        val snapshot = SQLiteBackupDatabase(database).readTaskSnapshot()
        val payload = snapshot.tasks.single()

        assertEquals(original.id, payload.id)
        assertEquals(original.seriesId, payload.seriesId)
        assertEquals(WireTaskState.COMPLETED, payload.state)
        assertEquals(original.settledAt, payload.settledAt)
        assertEquals(original.createdAt, payload.createdAt)
        assertEquals(original.updatedAt, payload.updatedAt)
    }

    @Test
    fun `空库恢复凭据后在同一事务生成完整baseline`() {
        val credentialsStore = MemoryCredentialsStore()
        val credentials = credentials()
        val completed = taskPayload("task-restore-0001", WireTaskState.COMPLETED, 8_888)
        val passed = taskPayload("task-restore-0002", WireTaskState.PASS, 9_999)
        val deleted = TombstonePayload(id = "task-restore-deleted", deletedAt = 10_001)

        val result = BackupRestoreCoordinator(
            SQLiteBackupDatabase(database),
            credentialsStore,
        ).restore(
            BackupSnapshot(
                exportedAt = 20_000,
                tasks = listOf(completed, passed),
                syncCredentials = BackupSyncCredentials.from(credentials),
                tombstones = listOf(deleted),
            ),
        )

        assertEquals(2, result.restoredTaskCount)
        assertEquals(2, count("tasks"))
        assertEquals(3, count("sync_outbox"))
        assertEquals(3, count("sync_entity_versions"))
        assertEquals(1, count("sync_tombstones"))
        assertEquals(0, count("sync_deferred_deletions"))
        assertEquals(credentials.vaultId to credentials.deviceId, boundIdentity())
        assertEquals(3L, lamport())
        assertEquals(8_888L, settledAt(completed.id))
        assertEquals(9_999L, settledAt(passed.id))
        assertEquals(deleted.deletedAt, tombstoneDeletedAt(deleted.id))
        assertEquals(listOf(deleted), SQLiteBackupDatabase(database).readTaskSnapshot().tombstones)
        assertEquals(credentials.deviceId, credentialsStore.load()?.deviceId)
    }

    @Test
    fun `无身份恢复删除屏障后重启不复活且首次绑定转为正式tombstone`() = runBlocking {
        val deleted = TombstonePayload(id = "task-restored-barrier", deletedAt = 11_234)
        val backupDatabase = SQLiteBackupDatabase(database)
        val credentialsStore = MemoryCredentialsStore()

        BackupRestoreCoordinator(backupDatabase, credentialsStore).restore(
            BackupSnapshot(
                exportedAt = 20_000,
                tasks = emptyList(),
                syncCredentials = null,
                tombstones = listOf(deleted),
            ),
        )

        assertEquals(1, backupDatabase.readState().tombstoneCount)
        assertEquals(listOf(deleted), backupDatabase.readTaskSnapshot().tombstones)
        assertEquals(1, count("sync_deferred_deletions"))
        assertEquals(0, count("sync_tombstones"))
        assertThrows(BackupTransferException.ResidualSyncState::class.java) {
            BackupRestoreCoordinator(backupDatabase, credentialsStore).requireReady()
        }

        database.close()
        database = TaskDatabase(context)
        database.writableDatabase
        val reopenedTaskStore = SQLiteTaskStore(database)
        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                reopenedTaskStore.insert(
                    taskEntity(deleted.id, TaskStatus.PENDING, settledAt = null),
                )
            }
        }
        assertEquals(0, count("tasks"))
        assertEquals(1, count("sync_deferred_deletions"))

        val credentials = credentials()
        val operation = SQLiteSyncStore(database, credentials).pendingOperations(50).single()

        assertEquals(SyncOperationKind.DELETE, operation.kind)
        assertEquals(deleted.id, operation.entityId)
        assertEquals(deleted, outboxPayload(deleted.id))
        assertEquals(0, count("sync_deferred_deletions"))
        assertEquals(1, count("sync_tombstones"))
        assertEquals(deleted.deletedAt, tombstoneDeletedAt(deleted.id))
        assertEquals(credentials.vaultId to credentials.deviceId, boundIdentity())

        SQLiteSyncStore(database, credentials)
        assertEquals(1, count("sync_outbox"))
        assertEquals(1, count("sync_tombstones"))
    }

    @Test
    fun `恢复中任一任务冲突会原子回滚全部任务`() {
        val duplicate = taskPayload("task-duplicate-01", WireTaskState.PENDING, null)

        assertThrows(SQLiteConstraintException::class.java) {
            BackupRestoreCoordinator(
                SQLiteBackupDatabase(database),
                MemoryCredentialsStore(),
            ).restore(
                BackupSnapshot(
                    exportedAt = 20_000,
                    tasks = listOf(duplicate, duplicate.copy(title = "重复 ID")),
                    syncCredentials = null,
                ),
            )
        }

        assertEquals(0, count("tasks"))
        assertEquals(0, count("sync_outbox"))
        assertEquals("" to "", boundIdentity())
        assertEquals(0L, lamport())
    }

    @Test
    fun `离线接力合并现有库会写入outbox且重复导入不重复入队`() = runBlocking {
        val firstId = "task-relay-sqlite-01"
        val deletedId = "task-relay-sqlite-02"
        val taskStore = SQLiteTaskStore(database)
        taskStore.insert(taskEntity(firstId, TaskStatus.PENDING, null))
        taskStore.insert(taskEntity(deletedId, TaskStatus.PENDING, null))
        SQLiteSyncStore(database, credentials())
        assertEquals(2, count("sync_outbox"))

        val snapshot = BackupSnapshot(
            exportedAt = 30_000,
            tasks = listOf(
                taskPayload(firstId, WireTaskState.PENDING, null).copy(
                    title = "手机端更新",
                    updatedAt = 3_000,
                ),
            ),
            tombstones = listOf(TombstonePayload(id = deletedId, deletedAt = 4_000)),
            syncCredentials = null,
        )
        val backupDatabase = SQLiteBackupDatabase(database)

        val first = backupDatabase.mergeOfflineRelay(snapshot)
        val second = backupDatabase.mergeOfflineRelay(snapshot)

        assertEquals(1, first.mergedTaskCount)
        assertEquals(1, first.mergedTombstoneCount)
        assertEquals(0, second.mergedTaskCount)
        assertEquals(0, second.mergedTombstoneCount)
        assertEquals(2, second.unchangedCount)
        assertEquals(1, count("tasks"))
        assertEquals(4, count("sync_outbox"))
        assertEquals(1, count("sync_tombstones"))
        assertEquals("手机端更新", backupDatabase.readTaskSnapshot().tasks.single().title)
    }

    @Test
    fun `离线接力按大小写无关ID覆盖和删除且重复导入幂等`() = runBlocking {
        val updatedId = "task-relay-case-update"
        val deletedId = "task-relay-case-delete"
        val taskStore = SQLiteTaskStore(database)
        taskStore.insert(taskEntity(updatedId, TaskStatus.PENDING, null))
        taskStore.insert(taskEntity(deletedId, TaskStatus.PENDING, null))
        val snapshot = BackupSnapshot(
            exportedAt = 30_000,
            tasks = listOf(
                taskPayload(updatedId.uppercase(), WireTaskState.PENDING, null).copy(
                    title = "大小写变体更新",
                    updatedAt = 3_000,
                ),
            ),
            tombstones = listOf(
                TombstonePayload(id = deletedId.uppercase(), deletedAt = 4_000),
            ),
            syncCredentials = null,
        )
        val backupDatabase = SQLiteBackupDatabase(database)

        val first = backupDatabase.mergeOfflineRelay(snapshot)
        val second = backupDatabase.mergeOfflineRelay(snapshot)
        val mergedSnapshot = backupDatabase.readTaskSnapshot()

        assertEquals(1, first.mergedTaskCount)
        assertEquals(1, first.mergedTombstoneCount)
        assertEquals(0, second.mergedTaskCount)
        assertEquals(0, second.mergedTombstoneCount)
        assertEquals(listOf(updatedId), mergedSnapshot.tasks.map { it.id })
        assertEquals("大小写变体更新", mergedSnapshot.tasks.single().title)
        assertEquals(listOf(deletedId), mergedSnapshot.tombstones.map { it.id })
        assertEquals(1, count("tasks"))
        assertEquals(1, count("sync_deferred_deletions"))
    }

    private fun taskEntity(id: String, status: TaskStatus, settledAt: Long?): TaskEntity =
        TaskEntity(
            id = id,
            seriesId = "series-$id",
            title = "SQLite 备份任务",
            timeType = TaskTimeType.DAY,
            targetDate = LocalDate.of(2026, 7, 16),
            questLine = QuestLine.MAIN,
            status = status,
            recurrence = Recurrence.ONCE,
            sortOrder = 4,
            createdAt = 1_000,
            updatedAt = 2_000,
            settledAt = settledAt,
        )

    private fun taskPayload(
        id: String,
        state: WireTaskState,
        settledAt: Long?,
    ): TaskInstancePayload = TaskInstancePayload(
        id = id,
        seriesId = "series-$id",
        title = "SQLite 恢复任务",
        timeType = WireTimeType.DAY,
        periodStart = "2026-07-16",
        timezone = WIRE_FIXED_TIMEZONE,
        questLine = WireQuestLine.MAIN,
        state = state,
        recurrence = WireRecurrence.ONCE,
        sortOrder = 4,
        createdAt = 1_000,
        updatedAt = 2_000,
        settledAt = settledAt,
    )

    private fun credentials(): SyncCredentials = SyncCredentials(
        endpoint = "https://sync.example.test",
        vaultId = "vault-backup-instrumented",
        deviceId = "device-backup-instrumented",
        deviceToken = Base64Url.encode(ByteArray(32) { 4 }),
        vaultKey = ByteArray(32) { (it + 2).toByte() },
    )

    private fun count(table: String): Int {
        assertTrue(table in COUNTABLE_TABLES)
        return database.readableDatabase.rawQuery("SELECT COUNT(*) FROM $table", null).use {
            assertTrue(it.moveToFirst())
            it.getInt(0)
        }
    }

    private fun settledAt(id: String): Long? = database.readableDatabase.rawQuery(
        "SELECT settled_at FROM tasks WHERE id = ?",
        arrayOf(id),
    ).use {
        if (!it.moveToFirst() || it.isNull(0)) null else it.getLong(0)
    }

    private fun boundIdentity(): Pair<String, String> = database.readableDatabase.rawQuery(
        "SELECT vault_id, device_id FROM sync_state WHERE id = 1",
        null,
    ).use {
        assertTrue(it.moveToFirst())
        it.getString(0) to it.getString(1)
    }

    private fun lamport(): Long = database.readableDatabase.rawQuery(
        "SELECT lamport FROM sync_state WHERE id = 1",
        null,
    ).use {
        assertTrue(it.moveToFirst())
        it.getLong(0)
    }

    private fun tombstoneDeletedAt(id: String): Long? = database.readableDatabase.rawQuery(
        "SELECT deleted_at FROM sync_tombstones WHERE entity_id = ?",
        arrayOf(id),
    ).use {
        if (it.moveToFirst()) it.getLong(0) else null
    }

    private fun outboxPayload(id: String): TaskWirePayload? = database.readableDatabase.rawQuery(
        "SELECT payload_json FROM sync_outbox WHERE entity_id = ?",
        arrayOf(id),
    ).use {
        if (it.moveToFirst()) SyncJsonCodec.decodeTaskPayload(it.getString(0)) else null
    }

    private class MemoryCredentialsStore : SyncCredentialsStore {
        private var credentials: SyncCredentials? = null

        override fun save(credentials: SyncCredentials) {
            this.credentials = SyncCredentials(
                endpoint = credentials.endpoint,
                vaultId = credentials.vaultId,
                deviceId = credentials.deviceId,
                deviceToken = credentials.deviceToken,
                vaultKey = credentials.vaultKey,
            )
        }

        override fun saveIfAbsent(credentials: SyncCredentials): Boolean {
            if (this.credentials != null) return false
            save(credentials)
            return true
        }

        override fun load(): SyncCredentials? = credentials

        override fun delete() {
            credentials = null
        }
    }

    private companion object {
        const val DATABASE_NAME = "woo-todo.db"
        val COUNTABLE_TABLES = setOf(
            "tasks",
            "sync_outbox",
            "sync_entity_versions",
            "sync_tombstones",
            "sync_deferred_deletions",
        )
    }
}
