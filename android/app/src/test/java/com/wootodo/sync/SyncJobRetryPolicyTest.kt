package com.wootodo.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncJobRetryPolicyTest {
    @Test
    fun `局域网线性退避云端指数退避`() {
        assertEquals(
            android.app.job.JobInfo.BACKOFF_POLICY_LINEAR,
            SyncJobRetryPolicy.backoffPolicy(SyncTransportMode.LOCAL_NETWORK),
        )
        assertEquals(
            android.app.job.JobInfo.BACKOFF_POLICY_EXPONENTIAL,
            SyncJobRetryPolicy.backoffPolicy(SyncTransportMode.SELF_HOSTED_SERVICE),
        )
    }

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
    }
}
