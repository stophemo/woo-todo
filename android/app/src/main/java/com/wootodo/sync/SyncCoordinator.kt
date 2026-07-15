package com.wootodo.sync

interface OutboxStore {
    /** 确认前必须稳定返回相同的最早 opId。 */
    fun pendingOperations(limit: Int): List<SyncPushOperation>

    /** 仅在服务端接收成功且该批所有 pull 页落地后删除。 */
    fun acknowledgeOperations(opIds: List<String>)
}

interface RemoteApplyStore {
    fun currentCursor(): Long

    /** 实现方必须在同一事务内幂等落地操作并保存 cursor。 */
    fun applyRemoteOperations(operations: List<SyncPulledOperation>, advancingCursorTo: Long)
}

data class SyncRunSummary(
    val pushed: Int,
    val pulled: Int,
    val pages: Int,
    val finalCursor: Long,
)

sealed class SyncCoordinatorException(message: String) : Exception(message) {
    data object InvalidPushSummary : SyncCoordinatorException("服务端 push 计数不一致")
    data class CursorRegressed(val previous: Long, val received: Long) :
        SyncCoordinatorException("服务端 cursor 从 $previous 回退到 $received")
    data class CursorDidNotAdvance(val cursor: Long) :
        SyncCoordinatorException("服务端仍有分页但 cursor $cursor 未前进")
    data object InvalidPulledSequence : SyncCoordinatorException("pull 序号不连续或超出 cursor")
    data object PageLimitExceeded : SyncCoordinatorException("单次同步超过安全分页上限")
}

class SyncCoordinator(
    private val transport: SyncTransport,
    private val outbox: OutboxStore,
    private val remoteApplyStore: RemoteApplyStore,
    private val credential: BearerCredential,
) {
    @Synchronized
    fun synchronize(): SyncRunSummary {
        var cursor = remoteApplyStore.currentCursor()
        var pushed = 0
        var pulled = 0
        var pages = 0
        var performedEmptyPush = false

        while (true) {
            val pending = outbox.pendingOperations(MAXIMUM_PUSH_BATCH)
            if (pending.isEmpty() && performedEmptyPush) break
            val operationIds = pending.map(SyncPushOperation::opId)
            var outgoing = pending
            var batchPages = 0

            while (true) {
                if (pages >= MAXIMUM_PAGES_PER_RUN) {
                    throw SyncCoordinatorException.PageLimitExceeded
                }
                val previousCursor = cursor
                val response = transport.sync(
                    SyncRequest(
                        cursor = cursor,
                        ack = cursor,
                        pullLimit = MAXIMUM_PULL_BATCH,
                        push = outgoing,
                    ),
                    credential,
                )
                pages += 1
                batchPages += 1

                if (response.push.received != outgoing.size ||
                    response.push.inserted + response.push.duplicates != response.push.received
                ) {
                    throw SyncCoordinatorException.InvalidPushSummary
                }
                if (response.cursor < previousCursor) {
                    throw SyncCoordinatorException.CursorRegressed(previousCursor, response.cursor)
                }
                validatePull(response.pull, previousCursor, response.cursor)
                remoteApplyStore.applyRemoteOperations(response.pull, response.cursor)
                pulled += response.pull.size
                cursor = response.cursor

                if (response.hasMore && cursor == previousCursor) {
                    throw SyncCoordinatorException.CursorDidNotAdvance(cursor)
                }
                outgoing = emptyList()
                if (!response.hasMore) break
            }

            if (operationIds.isNotEmpty()) {
                outbox.acknowledgeOperations(operationIds)
                pushed += operationIds.size
            } else {
                performedEmptyPush = true
            }

            if (pending.size < MAXIMUM_PUSH_BATCH && (pending.isEmpty() || batchPages > 0)) break
        }

        return SyncRunSummary(pushed, pulled, pages, cursor)
    }

    private fun validatePull(
        operations: List<SyncPulledOperation>,
        previousCursor: Long,
        cursor: Long,
    ) {
        var sequence = previousCursor
        operations.forEach { operation ->
            if (operation.serverSeq <= sequence || operation.serverSeq > cursor) {
                throw SyncCoordinatorException.InvalidPulledSequence
            }
            sequence = operation.serverSeq
        }
        if (operations.lastOrNull()?.serverSeq?.let { it != cursor } == true) {
            throw SyncCoordinatorException.InvalidPulledSequence
        }
        if (operations.isEmpty() && cursor != previousCursor) {
            throw SyncCoordinatorException.InvalidPulledSequence
        }
    }

    companion object {
        const val MAXIMUM_PUSH_BATCH = 50
        const val MAXIMUM_PULL_BATCH = 100
        const val MAXIMUM_PAGES_PER_RUN = 1_000
    }
}
