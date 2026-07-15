package com.wootodo.sync

import org.junit.Assert.assertThrows
import org.junit.Test

class RemotePagePolicyTest {
    @Test
    fun `允许跨vault序号间隙但页尾必须等于cursor`() {
        RemotePagePolicy.validate(
            operations = listOf(operation(2), operation(5)),
            currentCursor = 0,
            targetCursor = 5,
        )

        assertThrows(IllegalArgumentException::class.java) {
            RemotePagePolicy.validate(
                operations = listOf(operation(2)),
                currentCursor = 0,
                targetCursor = 5,
            )
        }
    }

    @Test
    fun `拒绝乱序重复与空页推进`() {
        listOf(
            listOf(operation(3), operation(2)),
            listOf(operation(2), operation(2)),
        ).forEach { operations ->
            assertThrows(IllegalArgumentException::class.java) {
                RemotePagePolicy.validate(operations, currentCursor = 0, targetCursor = 3)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            RemotePagePolicy.validate(emptyList(), currentCursor = 4, targetCursor = 5)
        }
    }

    private fun operation(sequence: Long): SyncPulledOperation = SyncPulledOperation(
        serverSeq = sequence,
        opId = "op-$sequence",
        deviceId = "device-remote",
        entityId = "task-$sequence",
        kind = SyncOperationKind.UPSERT,
        lamport = sequence,
        ciphertext = Base64Url.encode(ByteArray(16)),
        nonce = Base64Url.encode(ByteArray(12)),
        createdAt = sequence,
    )
}
