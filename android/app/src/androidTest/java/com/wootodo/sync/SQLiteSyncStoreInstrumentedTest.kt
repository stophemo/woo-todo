package com.wootodo.sync

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.data.SQLiteTaskStore
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskEntity
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskStatus
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
    fun `重置同步绑定保留本地数据并为新空间重新生成快照`() = runBlocking {
        val task = localTask("task-switch-binding", "切换同步方式后保留")
        SQLiteTaskStore(database).insert(task)
        val oldStore = SQLiteSyncStore(database, credentials)
        oldStore.acknowledgeOperations(oldStore.pendingOperations(50).map { it.opId })
        val display = displayConfiguration("切换后保留显示配置")
        writeDisplayConfiguration(
            database.writableDatabase,
            display,
            isLocalOverride = false,
        )
        database.writableDatabase.execSQL(
            "INSERT INTO sync_applied_operations(op_id, server_seq) VALUES ('old-op', 1)",
        )

        SQLiteSyncStore.resetSyncBinding(database)

        assertEquals("" to "", boundIdentity())
        assertEquals(0, rowCount("sync_outbox"))
        assertEquals(0, rowCount("sync_applied_operations"))
        assertEquals(task.title, taskTitle(task.id))
        assertEquals(display, readDisplayConfiguration(database.readableDatabase))
        assertTrue(readDisplayConfigurationLocalOverride(database.readableDatabase))

        val replacement = SyncCredentials(
            endpoint = "https://replacement.example.test",
            vaultId = "vault-replacement",
            deviceId = "device-replacement",
            deviceToken = Base64Url.encode(ByteArray(32) { 9 }),
            vaultKey = ByteArray(32) { (it + 31).toByte() },
        )
        val replacementStore = SQLiteSyncStore(database, replacement)
        assertEquals(replacement.vaultId to replacement.deviceId, boundIdentity())
        assertEquals(
            setOf(task.id),
            replacementStore.pendingOperations(50).map { it.entityId }.toSet(),
        )
    }

    @Test
    fun `原子替换同步绑定会直接重绑并保留任务`() = runBlocking {
        val task = localTask("task-atomic-switch", "原子切换")
        SQLiteTaskStore(database).insert(task)
        SQLiteSyncStore(database, credentials)
        val replacement = SyncCredentials(
            endpoint = "https://replacement.example.test",
            vaultId = "vault-atomic-replacement",
            deviceId = "device-atomic-replacement",
            deviceToken = Base64Url.encode(ByteArray(32) { 7 }),
            vaultKey = ByteArray(32) { (it + 41).toByte() },
        )

        val replacementStore = SQLiteSyncStore.replaceSyncBinding(database, replacement)

        assertEquals(replacement.vaultId to replacement.deviceId, boundIdentity())
        assertEquals(task.title, taskTitle(task.id))
        assertEquals(
            listOf(task.id),
            replacementStore.pendingOperations(50).map { it.entityId },
        )
    }

    @Test
    fun `数据库已绑定但没有旧凭据时配对落库会自愈重绑`() = runBlocking {
        val task = localTask("task-stale-binding", "退出中断后保留")
        SQLiteTaskStore(database).insert(task)
        // 模拟上次退出在解绑前中断：数据库仍绑定旧身份，但凭据已不存在。
        SQLiteSyncStore(database, credentials)
        val replacement = SyncCredentials(
            endpoint = "https://recovered.example.test",
            vaultId = "vault-recovered",
            deviceId = "device-recovered",
            deviceToken = Base64Url.encode(ByteArray(32) { 12 }),
            vaultKey = ByteArray(32) { (it + 22).toByte() },
        )

        val store = bindPairedSyncStore(
            database = database,
            credentials = replacement,
            replacedExistingCredentials = false,
        )

        assertEquals(replacement.vaultId to replacement.deviceId, boundIdentity())
        assertEquals(task.title, taskTitle(task.id))
        assertEquals(
            listOf(task.id),
            store.pendingOperations(50).map { it.entityId },
        )
    }

    @Test
    fun `撤销完成会写入明确的reopen操作`() = runBlocking {
        val syncStore = SQLiteSyncStore(database, credentials)
        val taskStore = SQLiteTaskStore(database)
        val task = localTask("task-reopen-outbox", "误点完成")
        taskStore.insert(task)
        assertTrue(taskStore.settle(task.id, TaskStatus.COMPLETED, 2_000))
        assertTrue(taskStore.reopenCompleted(task.id, updatedAt = 3_000))

        val operations = syncStore.pendingOperations(50)
        assertEquals(
            listOf(
                SyncOperationKind.UPSERT,
                SyncOperationKind.COMPLETE,
                SyncOperationKind.REOPEN,
            ),
            operations.map { it.kind },
        )
        val payload = decrypt(operations.last()) as TaskInstancePayload
        assertEquals(WireTaskState.PENDING, payload.state)
        assertNull(payload.settledAt)
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
    fun `批量清除历史会原子写入tombstone且保留待办`() = runBlocking {
        val syncStore = SQLiteSyncStore(database, credentials)
        val taskStore = SQLiteTaskStore(database)
        val completed = localTask("task-clear-completed", "已完成")
        val passed = localTask("task-clear-passed", "已 Pass")
        val pending = localTask("task-clear-pending", "保留待办")
        listOf(completed, passed, pending).forEach { taskStore.insert(it) }
        assertTrue(taskStore.settle(completed.id, TaskStatus.COMPLETED, 4_000))
        assertTrue(taskStore.settle(passed.id, TaskStatus.PASS, 4_001))
        syncStore.acknowledgeOperations(syncStore.pendingOperations(50).map { it.opId })

        assertEquals(2, taskStore.deleteSettled(ids = null, deletedAt = 5_000))
        assertEquals(0, taskStore.deleteSettled(ids = null, deletedAt = 5_001))

        val deletions = syncStore.pendingOperations(50)
        assertEquals(listOf(SyncOperationKind.DELETE, SyncOperationKind.DELETE), deletions.map { it.kind })
        assertEquals(
            setOf(completed.id, passed.id),
            deletions.map { (decrypt(it) as TombstonePayload).id }.toSet(),
        )
        assertEquals(pending.title, taskTitle(pending.id))
        assertEquals(2, rowCount("sync_tombstones"))
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
    fun `结算任务不会自动生成下一实例`() = runBlocking {
        val taskStore = SQLiteTaskStore(database)
        val current = localTask("task-once-current", "一次性任务")
        taskStore.insert(current)

        assertTrue(taskStore.settle(current.id, TaskStatus.COMPLETED, 9_876))

        assertEquals(TaskStatus.COMPLETED, taskStatus(current.id))
        assertEquals(1, rowCount("tasks"))
    }

    @Test
    fun `远端删除会保留本机恢复快照`() = runBlocking {
        val taskStore = SQLiteTaskStore(database)
        val store = SQLiteSyncStore(database, credentials)
        val entityId = "task-remote-trash"
        taskStore.insert(localTask(entityId, "远端删除"))
        store.acknowledgeOperations(store.pendingOperations(50).map { it.opId })

        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "op-remote-trash",
                    lamport = 10,
                    payload = TombstonePayload(id = entityId, deletedAt = 2_000),
                ),
            ),
            advancingCursorTo = 1,
        )

        assertNull(taskStore.getById(entityId))
        val trashed = taskStore.getTrash().single()
        assertEquals("远端删除", trashed.task.title)
        assertEquals(2_000, trashed.deletedAt)
    }

    @Test
    fun `收到恢复后的新任务会清除旧恢复快照`() = runBlocking {
        val taskStore = SQLiteTaskStore(database)
        val store = SQLiteSyncStore(database, credentials)
        val original = localTask("task-restore-original", "跨设备恢复")
        taskStore.insert(original)
        store.acknowledgeOperations(store.pendingOperations(50).map { it.opId })
        assertTrue(taskStore.deletePending(original.id, 2_000))
        assertEquals(1, taskStore.getTrash().size)

        val restored = remoteTask("task-restore-copy", "跨设备恢复").copy(
            seriesId = original.seriesId,
            updatedAt = 2_100,
        )
        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "op-restore-copy",
                    lamport = 20,
                    payload = restored,
                ),
            ),
            advancingCursorTo = 1,
        )

        assertTrue(taskStore.getTrash().isEmpty())
        assertEquals("跨设备恢复", taskStore.getById("task-restore-copy")?.title)
    }

    @Test
    fun `同 seriesId 的不同内容快照不会被恢复任务误删`() = runBlocking {
        val taskStore = SQLiteTaskStore(database)
        val store = SQLiteSyncStore(database, credentials)
        val seriesId = "series-shared"
        val edited = localTask("task-edited", "新内容").copy(seriesId = seriesId)
        taskStore.insert(edited)
        store.acknowledgeOperations(store.pendingOperations(50).map { it.opId })
        assertTrue(taskStore.deletePending(edited.id, 2_000))
        assertEquals(1, taskStore.getTrash().size)

        val restoredOld = remoteTask("task-restored-old", "旧内容").copy(
            seriesId = seriesId,
            updatedAt = 2_100,
        )
        store.applyRemoteOperations(
            listOf(operation(1, "op-restored-old", 20, restoredOld)),
            advancingCursorTo = 1,
        )

        assertEquals(listOf("新内容"), taskStore.getTrash().map { it.task.title })
        assertEquals(listOf("旧内容"), taskStore.getAll().map { it.title })
    }

    @Test
    fun `同 seriesId 的其他 live 任务内容不同时仍保留删除快照`() = runBlocking {
        val taskStore = SQLiteTaskStore(database)
        val store = SQLiteSyncStore(database, credentials)
        val seriesId = "series-sibling"
        val newer = localTask("task-newer", "新内容").copy(seriesId = seriesId)
        val sibling = localTask("task-sibling", "旧内容").copy(seriesId = seriesId)
        taskStore.insert(newer)
        taskStore.insert(sibling)
        store.acknowledgeOperations(store.pendingOperations(50).map { it.opId })

        store.applyRemoteOperations(
            listOf(
                operation(
                    1,
                    "op-delete-newer",
                    20,
                    TombstonePayload(id = newer.id, deletedAt = 2_000),
                ),
            ),
            advancingCursorTo = 1,
        )

        assertEquals(listOf("新内容"), taskStore.getTrash().map { it.task.title })
        assertEquals(listOf("旧内容"), taskStore.getAll().map { it.title })
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
    fun `远端大小写变体ID只保留一个任务且tombstone可以删除`() {
        val store = SQLiteSyncStore(database, credentials)
        val entityId = "task-remote-case-id"

        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "op-case-task-upper",
                    lamport = 1,
                    payload = remoteTask(entityId.uppercase(), "大写 ID 版本"),
                ),
            ),
            advancingCursorTo = 1,
        )
        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 2,
                    opId = "op-case-task-lower",
                    lamport = 2,
                    payload = remoteTask(entityId, "小写 ID 更新"),
                ),
            ),
            advancingCursorTo = 2,
        )

        assertEquals(1, rowCount("tasks"))
        assertEquals("小写 ID 更新", taskTitle(entityId))

        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 3,
                    opId = "op-case-delete-upper",
                    lamport = 3,
                    payload = TombstonePayload(
                        id = entityId.uppercase(),
                        deletedAt = 3_000,
                    ),
                ),
            ),
            advancingCursorTo = 3,
        )

        assertEquals(0, rowCount("tasks"))
        assertEquals(VersionSnapshot(3, REMOTE_DEVICE_ID, true), version(entityId))
        assertEquals(1, rowCount("sync_tombstones"))
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

    @Test
    fun `显示配置只留在本机，绑定后也不会补录进同步队列`() {
        val payload = displayConfiguration("首次配置")
        val sqlite = database.writableDatabase
        sqlite.beginTransaction()
        try {
            writeDisplayConfiguration(sqlite, payload)
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        assertEquals(0, rowCount("sync_outbox"))

        val store = SQLiteSyncStore(database, credentials)

        // 标题、副标题与计时模板属于个人偏好，不进同步空间。
        assertTrue(store.pendingOperations(50).isEmpty())
        assertEquals(payload, readDisplayConfiguration(database.readableDatabase))
        assertEquals(0, rowCount("sync_outbox"))
    }

    @Test
    fun `新设备默认显示配置不会覆盖同步空间已有配置`() {
        val localDefault = displayConfiguration("新设备默认值")
        writeDisplayConfiguration(
            database.writableDatabase,
            localDefault,
            isLocalOverride = false,
        )

        val store = SQLiteSyncStore(database, credentials)

        assertTrue(store.pendingOperations(50).isEmpty())
        assertEquals(false, readDisplayConfigurationLocalOverride(database.readableDatabase))
    }

    @Test
    fun `远端显示配置不会覆盖本机标题副标题`() {
        val refreshed = mutableListOf<DisplayConfigurationPayload>()
        val local = displayConfiguration("本机标题")
        writeDisplayConfiguration(
            database.writableDatabase,
            local,
            isLocalOverride = true,
        )
        val store = SQLiteSyncStore(
            database = database,
            credentials = credentials,
            onDisplayConfigurationChanged = refreshed::add,
        )

        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "operation-display-remote",
                    lamport = 10,
                    payload = displayConfiguration("别人的标题"),
                ),
            ),
            advancingCursorTo = 1,
        )

        assertEquals(local, readDisplayConfiguration(database.readableDatabase))
        assertTrue(refreshed.isEmpty())
        assertEquals(1, rowCount("sync_applied_operations"))
    }

    @Test
    fun `固定显示配置实体拒绝tombstone且整页回滚`() {
        val store = SQLiteSyncStore(database, credentials)
        val local = displayConfiguration("本机保留配置")
        writeDisplayConfiguration(
            database.writableDatabase,
            local,
            isLocalOverride = true,
        )
        val display = displayConfiguration("远端配置")
        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "operation-display-valid",
                    lamport = 1,
                    payload = display,
                ),
            ),
            advancingCursorTo = 1,
        )

        assertThrows(IllegalArgumentException::class.java) {
            store.applyRemoteOperations(
                listOf(
                    operation(
                        serverSeq = 2,
                        opId = "operation-display-delete",
                        lamport = 2,
                        payload = TombstonePayload(
                            id = DISPLAY_CONFIGURATION_ENTITY_ID,
                            deletedAt = 20_000,
                        ),
                    ),
                ),
                advancingCursorTo = 2,
            )
        }

        assertEquals(local, readDisplayConfiguration(database.readableDatabase))
        assertEquals(1L, store.currentCursor())
        assertEquals(1, rowCount("sync_applied_operations"))
        assertEquals(0, rowCount("sync_tombstones"))
    }

    @Test
    fun `resetCursor 归零游标且保留已应用记录与任务`() {
        val store = SQLiteSyncStore(database, credentials)
        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "op-reset-1",
                    lamport = 1,
                    payload = remoteTask("task-reset-cursor", "重置前任务"),
                ),
            ),
            advancingCursorTo = 1,
        )

        store.resetCursor()

        assertEquals(0L, store.currentCursor())
        assertEquals("重置前任务", taskTitle("task-reset-cursor"))
        assertEquals(1, rowCount("sync_applied_operations"))
    }

    @Test
    fun `同步应用记录随游标前进裁剪只保留最近窗口`() {
        val store = SQLiteSyncStore(database, credentials)
        val sqlite = database.writableDatabase
        val window = SQLiteSyncStore.APPLIED_RETENTION_WINDOW
        sqlite.beginTransaction()
        try {
            for (sequence in 1..(window + 5)) {
                sqlite.execSQL(
                    "INSERT INTO sync_applied_operations(op_id, server_seq) VALUES (?, ?)",
                    arrayOf("op-history-$sequence", sequence),
                )
            }
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        val latest = window + 6
        store.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = latest,
                    opId = "op-latest",
                    lamport = latest,
                    payload = remoteTask("task-trim-applied", "裁剪窗口后"),
                ),
            ),
            advancingCursorTo = latest,
        )

        // 窗口外（server_seq < latest - 10000）的记录被删除，表保持有界。
        assertEquals(window + 1, rowCount("sync_applied_operations").toLong())
        assertEquals(latest, store.currentCursor())
        assertEquals("裁剪窗口后", taskTitle("task-trim-applied"))
    }

    @Test
    fun `自定义分类保存会入队占位显示配置`() = runBlocking {
        val syncStore = SQLiteSyncStore(database, credentials)
        val taskStore = SQLiteTaskStore(database)
        val categories = TaskCategories.normalizeList(
            TaskCategories.defaults + TaskCategory("work", "工作", 4),
        )

        taskStore.replaceCategories(categories, 10_000)

        val operation = syncStore.pendingOperations(50).single()
        val payload = decrypt(operation) as DisplayConfigurationPayload
        assertEquals("", payload.headerTemplate)
        assertEquals("", payload.subtitleTemplate)
        assertEquals("2000-01-01", payload.startDate)
        assertEquals("2000-01-01", payload.deadlineDate)
        assertEquals(categories.map { it.id }, payload.questLines.map { it.id })
    }

    @Test
    fun `远端分类列表会重分配未知pending任务`() = runBlocking {
        val taskStore = SQLiteTaskStore(database)
        val task = localTask("task-unknown-category", "未知分类任务", categoryId = "work")
        taskStore.insert(task)
        val refreshed = mutableListOf<DisplayConfigurationPayload>()
        val receiver = SQLiteSyncStore(
            database = database,
            credentials = credentials,
            onDisplayConfigurationChanged = refreshed::add,
        )

        receiver.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "operation-categories",
                    lamport = 10,
                    payload = displayConfiguration("分类").copy(
                        questLines = listOf(
                            QuestLineDefinition(TaskCategories.INBOX_ID, "未分类", 0),
                            QuestLineDefinition("main", "主线", 1),
                        ),
                    ),
                ),
            ),
            advancingCursorTo = 1,
        )

        assertEquals(
            listOf(TaskCategories.INBOX_ID, "main"),
            taskStore.getCategories().map { it.id },
        )
        assertEquals(
            TaskCategories.INBOX_ID,
            taskStore.getById(task.id)?.categoryId,
        )
        assertEquals(1, refreshed.size)
    }

    @Test
    fun `远端空questLines不会修改本机分类`() = runBlocking {
        val taskStore = SQLiteTaskStore(database)
        val before = taskStore.getCategories()
        val refreshed = mutableListOf<DisplayConfigurationPayload>()
        val receiver = SQLiteSyncStore(
            database = database,
            credentials = credentials,
            onDisplayConfigurationChanged = refreshed::add,
        )

        receiver.applyRemoteOperations(
            listOf(
                operation(
                    serverSeq = 1,
                    opId = "operation-empty-categories",
                    lamport = 10,
                    payload = displayConfiguration("空分类"),
                ),
            ),
            advancingCursorTo = 1,
        )

        assertEquals(before, taskStore.getCategories())
        assertTrue(refreshed.isEmpty())
    }

    private fun localTask(
        id: String,
        title: String,
        categoryId: String = "main",
    ): TaskEntity = TaskEntity(
        id = id,
        seriesId = id,
        title = title,
        categoryId = categoryId,
        startDate = LocalDate.of(2026, 7, 16),
        endDate = LocalDate.of(2026, 7, 16),
        status = TaskStatus.PENDING,
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
        deadlineDate = "2026-07-16",
        timezone = "Asia/Shanghai",
        questLine = "main",
        state = WireTaskState.PENDING,
        recurrence = WireRecurrence.ONCE,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = 1_000,
        settledAt = null,
    )

    private fun displayConfiguration(label: String) = DisplayConfigurationPayload(
        headerTemplate = "$label {weekdayEn}",
        subtitleTemplate = "$label {deadlineMonthsDays}",
        startDate = "2026-01-01",
        deadlineDate = "2026-12-31",
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
            is DisplayConfigurationPayload -> SyncOperationKind.UPSERT
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
            "tasks",
            "sync_outbox",
            "sync_applied_operations",
            "sync_entity_versions",
            "sync_tombstones",
            "sync_deferred_deletions",
            "task_categories",
        )
    }
}
