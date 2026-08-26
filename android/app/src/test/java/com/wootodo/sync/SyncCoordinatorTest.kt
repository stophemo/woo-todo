package com.wootodo.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncCoordinatorTest {
    private val credential = BearerCredential(Base64Url.encode(ByteArray(32) { 1 }))

    @Test
    fun `分页全部落地后才确认Outbox`() {
        val operation = pushOperation(1)
        val outbox = FakeOutbox(mutableListOf(operation))
        val local = FakeRemoteApplyStore(0)
        val transport = ScriptedTransport(
            mutableListOf(
                Result.success(syncData(1, true, listOf(pulledOperation(1)), received = 1)),
                Result.success(syncData(2, false, listOf(pulledOperation(2)), received = 0)),
            ),
        )

        val summary = SyncCoordinator(transport, outbox, local, credential).synchronize()

        assertEquals(SyncRunSummary(1, 2, 2, 2), summary)
        assertEquals(emptyList<String>(), outbox.operations.map { it.opId })
        assertEquals(listOf(listOf(operation.opId)), outbox.acknowledged)
        assertEquals(2, local.cursor)
        assertEquals(listOf(1, 0), transport.requests.map { it.push.size })
    }

    @Test
    fun `分页失败保留Outbox但已落地页保留cursor`() {
        val operation = pushOperation(1)
        val outbox = FakeOutbox(mutableListOf(operation))
        val local = FakeRemoteApplyStore(0)
        val transport = ScriptedTransport(
            mutableListOf(
                Result.success(syncData(1, true, listOf(pulledOperation(1)), received = 1)),
                Result.failure(TestFailure()),
            ),
        )

        assertThrows(TestFailure::class.java) {
            SyncCoordinator(transport, outbox, local, credential).synchronize()
        }
        assertEquals(listOf(operation.opId), outbox.operations.map { it.opId })
        assertEquals(emptyList<List<String>>(), outbox.acknowledged)
        assertEquals(1, local.cursor)
    }

    @Test
    fun `远端落地失败不推进cursor也不删除Outbox`() {
        val operation = pushOperation(1)
        val outbox = FakeOutbox(mutableListOf(operation))
        val local = FakeRemoteApplyStore(0, failApply = true)
        val transport = ScriptedTransport(
            mutableListOf(Result.success(syncData(1, false, listOf(pulledOperation(1)), received = 1))),
        )

        assertThrows(TestFailure::class.java) {
            SyncCoordinator(transport, outbox, local, credential).synchronize()
        }
        assertEquals(0, local.cursor)
        assertEquals(listOf(operation.opId), outbox.operations.map { it.opId })
    }

    @Test
    fun `超过五十条Outbox分批推送`() {
        val outbox = FakeOutbox((0 until 51).map(::pushOperation).toMutableList())
        val transport = ScriptedTransport(
            mutableListOf(
                Result.success(syncData(0, false, emptyList(), received = 50)),
                Result.success(syncData(0, false, emptyList(), received = 1)),
            ),
        )

        val summary = SyncCoordinator(
            transport,
            outbox,
            FakeRemoteApplyStore(0),
            credential,
        ).synchronize()

        assertEquals(51, summary.pushed)
        assertEquals(listOf(50, 1), transport.requests.map { it.push.size })
    }

    @Test
    fun `服务端游标超前时重置游标并从头重新同步`() {
        val operation = pushOperation(1)
        val outbox = FakeOutbox(mutableListOf(operation))
        val local = FakeRemoteApplyStore(5)
        val transport = ScriptedTransport(
            mutableListOf(
                Result.failure(
                    SyncApiException.Server(
                        statusCode = 409,
                        payload = ServerErrorPayload("CURSOR_AHEAD", "服务端状态已重建"),
                        requestId = "req-cursor-ahead",
                    ),
                ),
                Result.success(syncData(1, false, listOf(pulledOperation(1)), received = 1)),
            ),
        )

        val summary = SyncCoordinator(transport, outbox, local, credential).synchronize()

        assertEquals(1, local.resetCount)
        assertEquals(1, summary.pushed)
        assertEquals(1, summary.pulled)
        assertEquals(1, local.cursor)
        assertEquals(listOf(5L, 0L), transport.requests.map { it.cursor })
        assertEquals(listOf(listOf(operation.opId)), outbox.acknowledged)
        assertEquals(emptyList<String>(), outbox.operations.map { it.opId })
    }

    @Test
    fun `其他服务端错误照常抛出且不重置游标`() {
        val outbox = FakeOutbox(mutableListOf(pushOperation(1)))
        val local = FakeRemoteApplyStore(7)
        val transport = ScriptedTransport(
            mutableListOf(
                Result.failure(
                    SyncApiException.Server(
                        statusCode = 500,
                        payload = ServerErrorPayload("INTERNAL", "服务端错误"),
                        requestId = "req-other",
                    ),
                ),
            ),
        )

        assertThrows(SyncApiException.Server::class.java) {
            SyncCoordinator(transport, outbox, local, credential).synchronize()
        }
        assertEquals(0, local.resetCount)
        assertEquals(7, local.cursor)
        assertEquals(listOf(pushOperation(1)), outbox.operations)
    }

    @Test
    fun `游标超前反复出现时受分页上限保护`() {
        val outbox = FakeOutbox(mutableListOf())
        val local = FakeRemoteApplyStore(5)
        val transport = AlwaysCursorAheadTransport()

        assertThrows(SyncCoordinatorException.PageLimitExceeded::class.java) {
            SyncCoordinator(transport, outbox, local, credential).synchronize()
        }
        assertTrue(local.resetCount >= 1)
        assertEquals(SyncCoordinator.MAXIMUM_PAGES_PER_RUN, transport.requests)
    }

    private fun pushOperation(index: Int): SyncPushOperation = SyncPushOperation(
        opId = "op-$index",
        entityId = "task-$index",
        kind = SyncOperationKind.UPSERT,
        lamport = (index + 1).toLong(),
        ciphertext = Base64Url.encode(ByteArray(16) { index.toByte() }),
        nonce = Base64Url.encode(ByteArray(12) { (index + 1).toByte() }),
    )

    private fun pulledOperation(sequence: Long): SyncPulledOperation = SyncPulledOperation(
        serverSeq = sequence,
        opId = "remote-$sequence",
        deviceId = "remote-device",
        entityId = "remote-task-$sequence",
        kind = SyncOperationKind.UPSERT,
        lamport = sequence,
        ciphertext = Base64Url.encode(ByteArray(16) { 8 }),
        nonce = Base64Url.encode(ByteArray(12) { 9 }),
        createdAt = sequence,
    )

    private fun syncData(
        cursor: Long,
        hasMore: Boolean,
        pull: List<SyncPulledOperation>,
        received: Int,
    ): SyncData = SyncData(
        push = SyncPushSummary(received, received, 0),
        pull = pull,
        cursor = cursor,
        hasMore = hasMore,
        serverTime = 1,
    )
}

private class ScriptedTransport(
    private val responses: MutableList<Result<SyncData>>,
) : SyncTransport {
    val requests = mutableListOf<SyncRequest>()

    override fun sync(request: SyncRequest, credential: BearerCredential): SyncData {
        requests += request
        return responses.removeAt(0).getOrThrow()
    }
}

private class FakeOutbox(val operations: MutableList<SyncPushOperation>) : OutboxStore {
    val acknowledged = mutableListOf<List<String>>()

    override fun pendingOperations(limit: Int): List<SyncPushOperation> = operations.take(limit)

    override fun acknowledgeOperations(opIds: List<String>) {
        acknowledged += opIds
        operations.removeAll { it.opId in opIds.toSet() }
    }
}

private class FakeRemoteApplyStore(
    var cursor: Long,
    private val failApply: Boolean = false,
) : RemoteApplyStore {
    var resetCount = 0

    override fun currentCursor(): Long = cursor

    override fun applyRemoteOperations(
        operations: List<SyncPulledOperation>,
        advancingCursorTo: Long,
    ) {
        if (failApply) throw TestFailure()
        cursor = advancingCursorTo
    }

    override fun resetCursor() {
        resetCount += 1
        cursor = 0
    }
}

private class AlwaysCursorAheadTransport : SyncTransport {
    var requests = 0

    override fun sync(request: SyncRequest, credential: BearerCredential): SyncData {
        requests += 1
        throw SyncApiException.Server(
            statusCode = 409,
            payload = ServerErrorPayload("CURSOR_AHEAD", "服务端状态已重建"),
            requestId = "req-always",
        )
    }
}

private class TestFailure : RuntimeException()
