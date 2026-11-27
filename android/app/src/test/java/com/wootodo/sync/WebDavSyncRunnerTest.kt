package com.wootodo.sync

import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebDavSyncRunnerTest {
    private val identity = WebDavIdentity(
        vaultId = "vault-android-test",
        deviceId = "device-android-01",
        vaultKey = ByteArray(Aes256Gcm.KEY_BYTES) { 7 },
    )

    @Test
    fun `推送后拉取未应用操作并在重复同步时保持幂等`() {
        val localPush = pushOperation("local-op-0001", "entity-local-0001", 1)
        val remoteOperation = operation("remote-op-0001", "device-mac-01", "entity-remote-0001", 2)
        val transport = FakeTransport().apply {
            store(remoteOperation)
        }
        val outbox = FakeOutbox(listOf(localPush))
        val local = FakeLocal().apply { markApplied(localPush.opId) }
        val runner = WebDavSyncRunner(transport, identity, outbox, local)

        val first = runner.synchronize()

        assertEquals(1, first.pushed)
        assertEquals(1, first.pulled)
        assertEquals("vault-android-test", transport.ensuredVaultId)
        assertEquals(listOf(localPush.opId), outbox.acknowledged)
        assertEquals(listOf(remoteOperation.opId), local.applied.map(WebDavOperation::opId))
        assertEquals(listOf(localPush.opId), local.uploadedApplied)
        assertTrue(transport.paths().contains(WebDavOperation.path(identity.vaultId, localPush.opId)))

        val second = runner.synchronize()

        assertEquals(0, second.pushed)
        assertEquals(0, second.pulled)
        assertEquals(1, local.applied.size)
    }

    @Test
    fun `一次同步推送超过单批的待发送操作`() {
        val pending = (1..120).map { index ->
            pushOperation(
                opId = "local-op-${index.toString().padStart(4, '0')}",
                entityId = "entity-local-$index",
                lamport = index.toLong(),
            )
        }
        val transport = FakeTransport()
        val outbox = FakeOutbox(pending)
        val local = FakeLocal()
        val runner = WebDavSyncRunner(transport, identity, outbox, local)

        val summary = runner.synchronize()

        assertEquals(120, summary.pushed)
        assertFalse(summary.moreWork)
        assertEquals(120, transport.paths().count { it.size == 5 })
        assertTrue(outbox.pendingOperations(200).isEmpty())
        // 自己刚上传的对象不需要再下载并应用一遍。
        assertTrue(local.applied.isEmpty())
        assertEquals(120, local.uploadedApplied.size)
    }

    @Test
    fun `积压超过单轮上限时只推送不拉取并标记还有工作`() {
        val pending = (1..250).map { index ->
            pushOperation(
                opId = "local-op-${index.toString().padStart(4, '0')}",
                entityId = "entity-local-$index",
                lamport = index.toLong(),
            )
        }
        val transport = FakeTransport()
        val outbox = FakeOutbox(pending)
        val local = FakeLocal()
        val runner = WebDavSyncRunner(transport, identity, outbox, local)

        val first = runner.synchronize()

        assertEquals(WebDavSyncRunner.MAXIMUM_PUSH_OPS_PER_RUN, first.pushed)
        assertEquals(0, first.pulled)
        assertTrue(first.moreWork)

        val second = runner.synchronize()

        assertEquals(50, second.pushed)
        assertFalse(second.moreWork)
        assertTrue(outbox.pendingOperations(200).isEmpty())
    }

    @Test
    fun `WebDAV拉取超过五百条时分批应用`() {
        val transport = FakeTransport()
        repeat(501) { index ->
            transport.store(
                operation(
                    opId = "remote-op-${index.toString().padStart(4, '0')}",
                    deviceId = "device-mac-01",
                    entityId = "entity-${index.toString().padStart(4, '0')}",
                    lamport = index + 1L,
                ),
            )
        }
        val local = FakeLocal()
        val runner = WebDavSyncRunner(transport, identity, FakeOutbox(emptyList()), local)

        val summary = runner.synchronize()

        assertEquals(501, summary.pulled)
        assertEquals(2, summary.pages)
        assertEquals(501, local.applied.size)
        assertEquals(listOf(500, 1), local.batchSizes)
    }

    @Test
    fun `WebDAV对象路径与opId不匹配时跳过该操作`() {
        val transport = FakeTransport()
        val operation = operation("remote-op-bad-01", "device-mac-01", "entity-bad-01", 1)
        transport.storeRaw(
            listOf("v1", identity.vaultId, "ops", "re", "other-name.json"),
            operation.canonicalJson(),
        )
        val local = FakeLocal()
        val runner = WebDavSyncRunner(
            transport = transport,
            identity = identity,
            outbox = FakeOutbox(emptyList()),
            local = local,
            onWarning = { _, _ -> },
        )

        val summary = runner.synchronize()

        assertEquals(0, summary.pulled)
        assertTrue(local.skipped.contains("other-name"))
        assertTrue(local.applied.isEmpty())
    }

    @Test
    fun `WebDAV同步空间不一致时跳过该操作`() {
        val transport = FakeTransport()
        val foreign = WebDavOperation(
            vaultId = "other-vault",
            deviceId = "device-mac-01",
            opId = "remote-op-foreign",
            entityId = "entity-foreign-01",
            kind = SyncOperationKind.UPSERT,
            lamport = 1,
            nonce = Base64Url.encode(ByteArray(Aes256Gcm.NONCE_BYTES)),
            ciphertext = Base64Url.encode(ByteArray(Aes256Gcm.TAG_BYTES)),
        )
        transport.storeRaw(
            WebDavOperation.path(identity.vaultId, foreign.opId),
            foreign.canonicalJson(),
        )
        val local = FakeLocal()
        val runner = WebDavSyncRunner(
            transport = transport,
            identity = identity,
            outbox = FakeOutbox(emptyList()),
            local = local,
            onWarning = { _, _ -> },
        )

        val summary = runner.synchronize()

        assertEquals(0, summary.pulled)
        assertTrue(local.skipped.contains(foreign.opId))
        assertTrue(local.applied.isEmpty())
    }

    @Test
    fun `单个无法解码的操作不会阻塞其他操作`() {
        val transport = FakeTransport()
        val good = operation("remote-op-good-01", "device-mac-01", "entity-good-01", 1)
        transport.store(good)
        transport.storeRaw(
            listOf("v1", identity.vaultId, "ops", "re", "remote-op-bad-02.json"),
            "{broken",
        )
        val local = FakeLocal()
        val runner = WebDavSyncRunner(
            transport = transport,
            identity = identity,
            outbox = FakeOutbox(emptyList()),
            local = local,
            onWarning = { _, _ -> },
        )

        val summary = runner.synchronize()

        assertEquals(1, summary.pulled)
        assertEquals(listOf(good.opId), local.applied.map(WebDavOperation::opId))
        assertTrue(local.skipped.contains("remote-op-bad-02"))
    }

    @Test
    fun `单条解密失败按opId跳过且同批其他操作继续应用`() {
        val transport = FakeTransport()
        val good = operation("remote-op-good-02", "device-mac-01", "entity-good-02", 1)
        val poison = operation("remote-op-poison", "device-mac-01", "entity-poison-01", 2)
        transport.store(good)
        transport.store(poison)
        val local = FakeLocal().apply { failFor = setOf(poison.opId) }
        val runner = WebDavSyncRunner(
            transport = transport,
            identity = identity,
            outbox = FakeOutbox(emptyList()),
            local = local,
            onWarning = { _, _ -> },
        )

        val summary = runner.synchronize()

        assertEquals(2, summary.pulled)
        assertEquals(listOf(good.opId), local.applied.map(WebDavOperation::opId))
        assertEquals(listOf(poison.opId), local.skipped)
    }

    @Test
    fun `读取远端最大lamport时跳过坏操作`() {
        val transport = FakeTransport()
        transport.store(operation("remote-op-max-01", "device-mac-01", "entity-max-01", 3))
        transport.store(operation("remote-op-max-02", "device-mac-01", "entity-max-02", 9))
        transport.storeRaw(
            listOf("v1", identity.vaultId, "ops", "re", "remote-op-broken.json"),
            "not-json",
        )

        val maximum = WebDavOperationIndex.maximumLamport(
            transport = transport,
            vaultId = identity.vaultId,
            onWarning = { _, _ -> },
        )

        assertEquals(9L, maximum)
    }

    private fun pushOperation(opId: String, entityId: String, lamport: Long) = SyncPushOperation(
        opId = opId,
        entityId = entityId,
        kind = SyncOperationKind.UPSERT,
        lamport = lamport,
        ciphertext = Base64Url.encode(ByteArray(Aes256Gcm.TAG_BYTES)),
        nonce = Base64Url.encode(ByteArray(Aes256Gcm.NONCE_BYTES)),
    )

    private fun operation(
        opId: String,
        deviceId: String,
        entityId: String,
        lamport: Long,
    ) = WebDavOperation(
        vaultId = identity.vaultId,
        deviceId = deviceId,
        opId = opId,
        entityId = entityId,
        kind = SyncOperationKind.UPSERT,
        lamport = lamport,
        nonce = Base64Url.encode(ByteArray(Aes256Gcm.NONCE_BYTES)),
        ciphertext = Base64Url.encode(ByteArray(Aes256Gcm.TAG_BYTES)),
    )

    private class FakeTransport : WebDavOperationTransport {
        private val files = linkedMapOf<List<String>, String>()
        var ensuredVaultId: String? = null
            private set

        fun store(operation: WebDavOperation) {
            files[WebDavOperation.path(operation.vaultId, operation.opId)] =
                operation.canonicalJson()
        }

        fun storeRaw(path: List<String>, content: String) {
            files[path] = content
        }

        fun paths(): Set<List<String>> = files.keys

        override fun ensureCollections(vaultId: String) {
            ensuredVaultId = vaultId
        }

        override fun putOperation(operation: WebDavOperation) {
            store(operation)
        }

        override fun listOperationPaths(vaultId: String): List<List<String>> =
            files.keys.filter { path ->
                path.size == 5 && path[0] == "v1" && path[1] == vaultId && path[2] == "ops"
            }.sortedBy { it.joinToString("/") }

        override fun get(path: List<String>): ByteArray =
            checkNotNull(files[path]).toByteArray(StandardCharsets.UTF_8)
    }

    private class FakeOutbox(initial: List<SyncPushOperation>) : OutboxStore {
        private var pending = initial
        val acknowledged = mutableListOf<String>()

        override fun pendingOperations(limit: Int): List<SyncPushOperation> =
            pending.take(limit)

        override fun acknowledgeOperations(opIds: List<String>) {
            acknowledged += opIds
            pending = pending.filterNot { it.opId in opIds }
        }
    }

    private class FakeLocal : WebDavLocalApplying {
        val applied = mutableListOf<WebDavOperation>()
        val batchSizes = mutableListOf<Int>()
        val skipped = mutableListOf<String>()
        val uploadedApplied = mutableListOf<String>()
        var failFor: Set<String> = emptySet()
        private val preApplied = mutableSetOf<String>()

        fun markApplied(opId: String) {
            preApplied += opId
        }

        override fun pendingWebDavOperationIds(operationIds: List<String>): Set<String> =
            operationIds.filterNot {
                it in preApplied || it in skipped || applied.any { op -> op.opId == it }
            }.toSet()

        override fun applyWebDavOperations(operations: List<WebDavOperation>) {
            operations.firstOrNull { it.opId in failFor }?.let { poison ->
                throw SyncCryptoException("密文校验失败：${poison.opId}")
            }
            batchSizes += operations.size
            applied += operations
        }

        override fun markWebDavOperationsSkipped(operationIds: List<String>) {
            skipped += operationIds
        }

        override fun markWebDavOperationsApplied(operationIds: List<String>) {
            uploadedApplied += operationIds
            preApplied += operationIds
        }
    }
}
