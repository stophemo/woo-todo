package com.wootodo.sync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncJobRetryPolicyTest {
    @Test
    fun `连续失败达到上限后不再自动重试`() {
        assertTrue(SyncJobRetryPolicy.shouldReschedule(isImmediate = true, retryable = true))
        assertTrue(
            SyncJobRetryPolicy.shouldReschedule(
                isImmediate = true,
                retryable = true,
                retryCount = SyncJobRetryPolicy.MAX_IMMEDIATE_RETRIES - 1,
            ),
        )
        assertFalse(
            SyncJobRetryPolicy.shouldReschedule(
                isImmediate = true,
                retryable = true,
                retryCount = SyncJobRetryPolicy.MAX_IMMEDIATE_RETRIES,
            ),
        )
        assertFalse(
            SyncJobRetryPolicy.shouldReschedule(
                isImmediate = true,
                retryable = true,
                retryCount = SyncJobRetryPolicy.MAX_IMMEDIATE_RETRIES + 1,
            ),
        )
        assertFalse(SyncJobRetryPolicy.shouldReschedule(isImmediate = false, retryable = true))
        assertFalse(SyncJobRetryPolicy.shouldReschedule(isImmediate = true, retryable = false))
    }
}
