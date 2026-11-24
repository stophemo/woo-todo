package com.wootodo.sync

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.data.SQLiteTaskStore
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskEntity
import com.wootodo.domain.TaskStatus
import java.nio.charset.StandardCharsets
import java.time.LocalDate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WebDavLocalApplyingInstrumentedTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    private lateinit var database: TaskDatabase
    private lateinit var credentials: SyncCredentials

    @Before
    fun setUp() {
        context.deleteDatabase(DATABASE_NAME)
        database = TaskDatabase(context)
        database.writableDatabase
        credentials = SyncCredentials(
            endpoint = "https://dav.example.test/woo-todo/",
            vaultId = "vault-webdav-apply",
            deviceId = "device-android-apply",
            deviceToken = Base64Url.encode(ByteArray(32) { 3 }),
            vaultKey = ByteArray(32) { (it + 7).toByte() },
        )
    }

    @After
    fun tearDown() {
        if (::database.isInitialized) database.close()
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun `WebDAV表存在且同一操作重复应用只生效一次`() {
        val store = SQLiteSyncStore(database, credentials)
        val operation = webDavOperation(
            entityId = "task-webdav-apply-01",
            title = "WebDAV 幂等任务",
        )

        store.applyWebDavOperations(listOf(operation))
        store.applyWebDavOperations(listOf(operation))

        assertEquals(1, count("tasks"))
        assertEquals(1, count("sync_webdav_applied_operations"))
        assertTrue(store.pendingWebDavOperationIds(listOf(operation.opId)).isEmpty())
        assertEquals(2L, lamport())
        assertEquals(
            "WebDAV 幂等任务",
            database.readableDatabase.rawQuery(
                "SELECT title FROM tasks WHERE id = ?",
                arrayOf(operation.entityId),
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                cursor.getString(0)
            },
        )
    }

    @Test
    fun `单条坏密文操作被跳过并记录已处理`() {
        val store = SQLiteSyncStore(database, credentials)
        val good = webDavOperation("task-webdav-good-01", "正常任务")
        val poison = good.copy(
            opId = "webdav-op-poison-001",
            entityId = "task-webdav-poison-01",
            ciphertext = Base64Url.encode(ByteArray(Aes256Gcm.TAG_BYTES)),
        )

        store.applyWebDavOperations(listOf(poison, good))

        assertEquals(1, count("tasks"))
        assertEquals("正常任务", taskTitle("task-webdav-good-01"))
        assertTrue(store.pendingWebDavOperationIds(listOf(poison.opId)).isEmpty())
        assertTrue(store.pendingWebDavOperationIds(listOf(good.opId)).isEmpty())
    }

    @Test
    fun `从0点3数据库升级时重建WebDAV表并保留任务`() = kotlinx.coroutines.runBlocking {
        SQLiteTaskStore(database).insert(
            TaskEntity(
                id = "task-upgrade-keep-01",
                seriesId = "series-task-upgrade-keep-01",
                title = "升级前任务",
                categoryId = "main",
                startDate = LocalDate.of(2026, 11, 24),
                endDate = LocalDate.of(2026, 11, 24),
                status = TaskStatus.PENDING,
                sortOrder = 1,
                createdAt = 1_000,
                updatedAt = 2_000,
                settledAt = null,
            ),
        )
        database.close()

        // 模拟删除过 WebDAV 表的旧数据库：用户版本 13，WebDAV 已应用表已被删除。
        val path = context.getDatabasePath(DATABASE_NAME)
        SQLiteDatabase.openDatabase(path.path, null, SQLiteDatabase.OPEN_READWRITE).use { raw ->
            raw.execSQL("DROP TABLE IF EXISTS sync_webdav_applied_operations")
            raw.execSQL("PRAGMA user_version = 13")
        }

        database = TaskDatabase(context)
        database.writableDatabase

        assertTrue(tableExists("sync_webdav_applied_operations"))
        assertEquals(1, count("tasks"))
        assertEquals("升级前任务", taskTitle("task-upgrade-keep-01"))
    }

    @Test
    fun `加入已有空间时远端lamport水位高于本地基线`() = kotlinx.coroutines.runBlocking {
        SQLiteTaskStore(database).insert(
            TaskEntity(
                id = "task-lamport-floor-01",
                seriesId = "series-task-lamport-floor-01",
                title = "水位测试任务",
                categoryId = "main",
                startDate = LocalDate.of(2026, 11, 24),
                endDate = LocalDate.of(2026, 11, 24),
                status = TaskStatus.PENDING,
                sortOrder = 1,
                createdAt = 1_000,
                updatedAt = 2_000,
                settledAt = null,
            ),
        )

        val store = SQLiteSyncStore.replaceSyncBinding(
            database = database,
            credentials = credentials,
            remoteLamportFloor = 41,
        )

        assertEquals(42L, lamport())
        val pending = store.pendingOperations(10)
        assertTrue(pending.isNotEmpty())
        assertTrue(pending.all { it.lamport > 41L })
    }

    private fun webDavOperation(entityId: String, title: String): WebDavOperation {
        val payload = TaskInstancePayload(
            id = entityId,
            seriesId = "series-$entityId",
            title = title,
            timeType = WireTimeType.DAY,
            periodStart = "2026-11-24",
            deadlineDate = "2026-11-24",
            timezone = WIRE_FIXED_TIMEZONE,
            questLine = "main",
            state = WireTaskState.PENDING,
            recurrence = WireRecurrence.ONCE,
            sortOrder = 1,
            createdAt = 1_000,
            updatedAt = 2_000,
            settledAt = null,
        )
        val opId = "webdav-op-apply-0001"
        val metadata = SyncOperationMetadata(
            opId = opId,
            entityId = entityId,
            kind = SyncOperationKind.UPSERT,
            lamport = 2,
            deviceId = credentials.deviceId,
        )
        val envelope = SyncPayloadCrypto.seal(
            plaintext = SyncJsonCodec.encodeTaskPayload(payload)
                .toByteArray(StandardCharsets.UTF_8),
            vaultKey = credentials.vaultKey,
            vaultId = credentials.vaultId,
            metadata = metadata,
        )
        return WebDavOperation(
            vaultId = credentials.vaultId,
            deviceId = credentials.deviceId,
            opId = opId,
            entityId = entityId,
            kind = SyncOperationKind.UPSERT,
            lamport = 2,
            nonce = envelope.nonce,
            ciphertext = envelope.ciphertext,
        )
    }

    private fun tableExists(name: String): Boolean =
        database.readableDatabase.rawQuery(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            arrayOf(name),
        ).use { it.moveToFirst() }

    private fun count(table: String): Int = database.readableDatabase.rawQuery(
        "SELECT COUNT(*) FROM $table",
        null,
    ).use {
        assertTrue(it.moveToFirst())
        it.getInt(0)
    }

    private fun lamport(): Long = database.readableDatabase.rawQuery(
        "SELECT lamport FROM sync_state WHERE id = 1",
        null,
    ).use {
        assertTrue(it.moveToFirst())
        it.getLong(0)
    }

    private fun taskTitle(id: String): String? = database.readableDatabase.rawQuery(
        "SELECT title FROM tasks WHERE id = ?",
        arrayOf(id),
    ).use {
        if (it.moveToFirst()) it.getString(0) else null
    }

    private companion object {
        const val DATABASE_NAME = "woo-todo.db"
    }
}
