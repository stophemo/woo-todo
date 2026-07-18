package com.wootodo.sync

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.data.SQLiteTaskStore
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskEntity
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.nio.charset.StandardCharsets
import java.time.LocalDate
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SQLiteSyncStoreInstrumentedTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    private lateinit var database: TaskDatabase
    private lateinit var credentials: SyncCredentials
    private var nonceSeed = 1

    @Before
    fun setUp() {
        context.deleteDatabase(DATABASE_NAME)
        nonceSeed = 1
        database = TaskDatabase(context)
        database.writableDatabase
        credentials = SyncCredentials(
            endpoint = "https://sync.example.test",
            vaultId = "vault-android-test",
            deviceId = "device-android-test",
            deviceToken = Base64Url.encode(ByteArray(32) { 3 }),
            vaultKey = ByteArray(32) { (it + 11).toByte() },
        )
    }

    @After
    fun tearDown() {
        if (::database.isInitialized) database.close()
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun `首次绑定会把既有任务稳定写入 Outbox 且拒绝更换身份`() = runBlocking {
        val localTask = localTask("task-before-binding", "绑定前任务")
        SQLiteTaskStore(database).insert(localTask)
        assertEquals(0, rowCount("sync_outbox"))

        val store = SQLiteSyncStore(database, credentials)

        assertEquals(credentials.vaultId to credentials.deviceId, boundIdentity())
        val firstRead = store.pendingOperations(50).single()
        val secondRead = store.pendingOperations(50).single()
        assertEquals(firstRead, secondRead)
        assertEquals(localTask.id, firstRead.entityId)
        assertEquals(SyncOperationKind.UPSERT, firstRead.kind)
        val decoded = decrypt(firstRead) as TaskInstancePayload
        assertEquals(localTask.id, decoded.id)
        assertEquals(localTask.title, decoded.title)

        val reopened = SQLiteSyncStore(database, credentials)
        assertEquals(firstRead, reopened.pendingOperations(50).single())
        val otherCredentials = SyncCredentials(
            endpoint = credentials.endpoint,
            vaultId = credentials.vaultId,
            deviceId = "device-other",
            deviceToken = Base64Url.encode(ByteArray(32) { 4 }),
            vaultKey = credentials.vaultKey,
        )
        assertThrows(IllegalArgumentException::class.java) {
            SQLiteSyncStore(database, otherCredentials)
        }
        assertEquals(credentials.vaultId to credentials.deviceId, boundIdentity())
        assertEquals(1, rowCount("sync_outbox"))

        store.acknowledgeOperations(listOf(firstRead.opId))
        assertTrue(store.pendingOperations(50).isEmpty())
    }

    @Test
    fun `未绑定时删除会持久化并在首次绑定后只补录一次tombstone`() = runBlocking {
        val entityId = "task-deleted-before-binding"
        val taskStore = SQLiteTaskStore(database)
        taskStore.insert(localTask(entityId, "绑定前删除"))

        assertTrue(taskStore.deletePending(entityId, deletedAt = 7_654))
        assertNull(taskTitle(entityId))
        assertEquals(1, rowCount("sync_deferred_deletions"))
        assertEquals(0, rowCount("sync_outbox"))
        assertEquals(0, rowCount("sync_entity_versions"))

        val syncStore = SQLiteSyncStore(database, credentials)
        val operation = syncStore.pendingOperations(50).single()

        assertEquals(SyncOperationKind.DELETE, operation.kind)
        assertEquals(entityId, operation.entityId)
        assertEquals(
            TombstonePayload(id = entityId, deletedAt = 7_654),
            decrypt(operation),
        )
        assertEquals(0, rowCount("sync_deferred_deletions"))
        assertEquals(1, rowCount("sync_tombstones"))
        assertEquals(VersionSnapshot(1, credentials.deviceId, true), version(entityId))

        SQLiteSyncStore(database, credentials)
        assertEquals(1, rowCount("sync_outbox"))
        assertEquals(1, rowCount("sync_tombstones"))
    }

    @Test
    fun `未绑定删除后同ID任务在重启后也不能复活`() = runBlocking {
        val entityId = "task-terminal-before-binding"
        val taskStore = SQLiteTaskStore(database)
        val task = localTask(entityId, "删除后不得复活")
        taskStore.insert(task)
        assertTrue(taskStore.deletePending(entityId, deletedAt = 8_765))

        database.close()
        database = TaskDatabase(context)
        database.writableDatabase
        val reopenedTaskStore = SQLiteTaskStore(database)
        assertThrows(IllegalStateException::class.java) {
            runBlocking { reopenedTaskStore.insert(task.copy(title = "不得复活")) }
        }

        assertNull(taskTitle(entityId))
        assertEquals(1, rowCount("sync_deferred_deletions"))
    }

    @Test
    fun `重复下一实例命中删除屏障时只结算当前任务`() = runBlocking {
        val taskStore = SQLiteTaskStore(database)
        val current = localTask("task-recurrence-current", "当前重复任务")
        val deletedNext = localTask("task-recurrence-next", "已删除的下一实例")
        taskStore.insert(deletedNext)
        assertTrue(taskStore.deletePending(deletedNext.id, deletedAt = 8_765))
        taskStore.insert(current)

        assertTrue(
            taskStore.settleAndSchedule(
                id = current.id,
                status = TaskStatus.COMPLETED,
                settledAt = 9_876,
                nextTask = { deletedNext },
            ),
        )

        assertEquals(TaskStatus.COMPLETED, taskStatus(current.id))
        assertNull(taskTitle(deletedNext.id))
        assertEquals(1, rowCount("sync_deferred_deletions"))
    }

    @Test
    fun `任务先到时后续 tombstone 会永久压制同 ID 高版本任务`() {
        var taskChangeCount = 0
        val store = SQLiteSyncStore(database, credentials) { taskChangeCount += 1 }
        val entityId = "task-task-then-delete"

        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "op-task-first",
                    lamport = 50,
                    payload = remoteTask(entityId, "先到任务"),
                ),
            ),
            advancingCursorTo = 1,
        )
        assertEquals("先到任务", taskTitle(entityId))

        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 2,
                    opId = "op-delete-second",
                    lamport = 1,
                    payload = TombstonePayload(id = entityId, deletedAt = 2_000),
                ),
            ),
            advancingCursorTo = 2,
        )
        assertNull(taskTitle(entityId))

        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 3,
                    opId = "op-task-after-delete",
                    lamport = 100,
                    payload = remoteTask(entityId, "不得复活"),
                ),
            ),
            advancingCursorTo = 3,
        )

        assertNull(taskTitle(entityId))
        assertEquals(VersionSnapshot(100, REMOTE_DEVICE_ID, true), version(entityId))
        assertEquals(100L, tombstoneLamport(entityId))
        assertEquals(3L, store.currentCursor())
        assertEquals(2, taskChangeCount)
    }

    @Test
    fun `tombstone 先到时后续同 ID 任务即使版本更高也不能创建`() {
        var taskChangeCount = 0
        val store = SQLiteSyncStore(database, credentials) { taskChangeCount += 1 }
        val entityId = "task-delete-then-task"

        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "op-delete-first",
                    lamport = 2,
                    payload = TombstonePayload(id = entityId, deletedAt = 1_000),
                ),
            ),
            advancingCursorTo = 1,
        )
        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 2,
                    opId = "op-task-second",
                    lamport = 200,
                    payload = remoteTask(entityId, "不得创建"),
                ),
            ),
            advancingCursorTo = 2,
        )

        assertNull(taskTitle(entityId))
        assertEquals(VersionSnapshot(200, REMOTE_DEVICE_ID, true), version(entityId))
        assertEquals(200L, tombstoneLamport(entityId))
        assertEquals(2L, store.currentCursor())
        assertEquals(0, taskChangeCount)
    }

    @Test
    fun `重复 op 只应用一次并可在不解密重复正文时推进 cursor`() {
        var taskChangeCount = 0
        val store = SQLiteSyncStore(database, credentials) { taskChangeCount += 1 }
        val entityId = "task-duplicate-op"
        val opId = "op-duplicate"

        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = opId,
                    lamport = 10,
                    payload = remoteTask(entityId, "只应用一次"),
                ),
            ),
            advancingCursorTo = 1,
        )
        store.applyRemoteOperations(
            listOf(
                corruptedOperation(
                    serverSeq = 2,
                    opId = opId,
                    entityId = entityId,
                    kind = SyncOperationKind.DELETE,
                    lamport = 999,
                ),
            ),
            advancingCursorTo = 2,
        )

        assertEquals("只应用一次", taskTitle(entityId))
        assertEquals(1, rowCount("sync_applied_operations"))
        assertEquals(2L, store.currentCursor())
        assertEquals(1, taskChangeCount)
    }

    @Test
    fun `乱序页与推进空页会被拒绝且不改变 cursor 或任务`() {
        val store = SQLiteSyncStore(database, credentials)
        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "op-baseline",
                    lamport = 1,
                    payload = remoteTask("task-baseline", "基线"),
                ),
            ),
            advancingCursorTo = 1,
        )

        assertThrows(IllegalArgumentException::class.java) {
            store.applyRemoteOperations(
                listOf(
                    operation(3, "op-out-of-order-3", 3, remoteTask("task-order-3", "三")),
                    operation(2, "op-out-of-order-2", 2, remoteTask("task-order-2", "二")),
                ),
                advancingCursorTo = 3,
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            store.applyRemoteOperations(emptyList(), advancingCursorTo = 2)
        }
        assertThrows(IllegalArgumentException::class.java) {
            store.applyRemoteOperations(emptyList(), advancingCursorTo = 0)
        }

        assertEquals(1L, store.currentCursor())
        assertNull(taskTitle("task-order-2"))
        assertNull(taskTitle("task-order-3"))
        assertEquals(1, rowCount("sync_applied_operations"))
    }

    @Test
    fun `页内后续密文失败会回滚此前任务 applied 记录与 cursor`() {
        val store = SQLiteSyncStore(database, credentials)
        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "op-rollback-baseline",
                    lamport = 1,
                    payload = remoteTask("task-rollback-baseline", "基线"),
                ),
            ),
            advancingCursorTo = 1,
        )

        assertThrows(SyncCryptoException::class.java) {
            store.applyRemoteOperations(
                listOf(
                    operation(
                        serverSeq = 2,
                        opId = "op-rollback-valid",
                        lamport = 2,
                        payload = remoteTask("task-must-rollback", "必须回滚"),
                    ),
                    corruptedOperation(
                        serverSeq = 3,
                        opId = "op-rollback-corrupt",
                        entityId = "task-corrupt",
                        kind = SyncOperationKind.UPSERT,
                        lamport = 3,
                    ),
                ),
                advancingCursorTo = 3,
            )
        }

        assertEquals(1L, store.currentCursor())
        assertNull(taskTitle("task-must-rollback"))
        assertEquals(1, rowCount("sync_applied_operations"))
        assertNull(version("task-must-rollback"))
    }

    private fun localTask(id: String, title: String): TaskEntity = TaskEntity(
        id = id,
        seriesId = id,
        title = title,
        timeType = TaskTimeType.DAY,
        targetDate = LocalDate.of(2026, 7, 16),
        questLine = QuestLine.MAIN,
        status = TaskStatus.PENDING,
        recurrence = Recurrence.ONCE,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = 1_000,
        settledAt = null,
    )

    private fun remoteTask(id: String, title: String): TaskInstancePayload = TaskInstancePayload(
        id = id,
        seriesId = id,
        title = title,
        timeType = WireTimeType.DAY,
        periodStart = "2026-07-16",
        timezone = "Asia/Shanghai",
        questLine = WireQuestLine.MAIN,
        state = WireTaskState.PENDING,
        recurrence = WireRecurrence.ONCE,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = 1_000,
        settledAt = null,
    )

    private fun operation(
        serverSeq: Long,
        opId: String,
        lamport: Long,
        payload: TaskWirePayload,
    ): SyncPulledOperation {
        val kind = when (payload) {
            is TombstonePayload -> SyncOperationKind.DELETE
            is TaskInstancePayload -> SyncOperationKind.UPSERT
        }
        val metadata = SyncOperationMetadata(
            opId = opId,
            entityId = payload.id,
            kind = kind,
            lamport = lamport,
            deviceId = REMOTE_DEVICE_ID,
        )
        val envelope = SyncPayloadCrypto.seal(
            plaintext = SyncJsonCodec.encodeTaskPayload(payload)
                .toByteArray(StandardCharsets.UTF_8),
            vaultKey = credentials.vaultKey,
            vaultId = credentials.vaultId,
            metadata = metadata,
            nonce = nextNonce(),
        )
        return SyncPulledOperation(
            serverSeq = serverSeq,
            opId = opId,
            deviceId = REMOTE_DEVICE_ID,
            entityId = payload.id,
            kind = kind,
            lamport = lamport,
            ciphertext = envelope.ciphertext,
            nonce = envelope.nonce,
            createdAt = 10_000 + serverSeq,
        )
    }

    private fun corruptedOperation(
        serverSeq: Long,
        opId: String,
        entityId: String,
        kind: SyncOperationKind,
        lamport: Long,
    ): SyncPulledOperation = SyncPulledOperation(
        serverSeq = serverSeq,
        opId = opId,
        deviceId = REMOTE_DEVICE_ID,
        entityId = entityId,
        kind = kind,
        lamport = lamport,
        ciphertext = Base64Url.encode(ByteArray(Aes256Gcm.TAG_BYTES) { 5 }),
        nonce = Base64Url.encode(nextNonce()),
        createdAt = 10_000 + serverSeq,
    )

    private fun decrypt(operation: SyncPushOperation): TaskWirePayload {
        val plaintext = SyncPayloadCrypto.open(
            envelope = EncryptedEnvelope(operation.ciphertext, operation.nonce),
            vaultKey = credentials.vaultKey,
            vaultId = credentials.vaultId,
            metadata = SyncOperationMetadata(
                opId = operation.opId,
                entityId = operation.entityId,
                kind = operation.kind,
                lamport = operation.lamport,
                deviceId = credentials.deviceId,
            ),
        )
        return SyncJsonCodec.decodeTaskPayload(String(plaintext, StandardCharsets.UTF_8))
    }

    private fun nextNonce(): ByteArray {
        val seed = nonceSeed++
        return ByteArray(Aes256Gcm.NONCE_BYTES) { index -> (seed + index).toByte() }
    }

    private fun boundIdentity(): Pair<String, String> = database.readableDatabase.rawQuery(
        "SELECT vault_id, device_id FROM sync_state WHERE id = 1",
        null,
    ).use { cursor ->
        assertTrue(cursor.moveToFirst())
        cursor.getString(0) to cursor.getString(1)
    }

    private fun taskTitle(entityId: String): String? = database.readableDatabase.rawQuery(
        "SELECT title FROM tasks WHERE id = ?",
        arrayOf(entityId),
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    }

    private fun taskStatus(entityId: String): TaskStatus? = database.readableDatabase.rawQuery(
        "SELECT status FROM tasks WHERE id = ?",
        arrayOf(entityId),
    ).use { cursor ->
        if (cursor.moveToFirst()) TaskStatus.fromRaw(cursor.getString(0)) else null
    }

    private fun version(entityId: String): VersionSnapshot? = database.readableDatabase.rawQuery(
        "SELECT lamport, device_id, is_tombstone FROM sync_entity_versions WHERE entity_id = ?",
        arrayOf(entityId),
    ).use { cursor ->
        if (!cursor.moveToFirst()) null else VersionSnapshot(
            lamport = cursor.getLong(0),
            deviceId = cursor.getString(1),
            isTombstone = cursor.getInt(2) != 0,
        )
    }

    private fun tombstoneLamport(entityId: String): Long? = database.readableDatabase.rawQuery(
        "SELECT lamport FROM sync_tombstones WHERE entity_id = ?",
        arrayOf(entityId),
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getLong(0) else null
    }

    private fun rowCount(table: String): Int {
        assertTrue(table in ALLOWED_COUNT_TABLES)
        return database.readableDatabase.rawQuery("SELECT COUNT(*) FROM $table", null).use { cursor ->
            assertTrue(cursor.moveToFirst())
            cursor.getInt(0)
        }
    }

    private data class VersionSnapshot(
        val lamport: Long,
        val deviceId: String,
        val isTombstone: Boolean,
    )

    private companion object {
        const val DATABASE_NAME = "woo-todo.db"
        const val REMOTE_DEVICE_ID = "device-macos-test"
        val ALLOWED_COUNT_TABLES = setOf(
            "sync_outbox",
            "sync_applied_operations",
            "sync_entity_versions",
            "sync_tombstones",
            "sync_deferred_deletions",
        )
    }
}
