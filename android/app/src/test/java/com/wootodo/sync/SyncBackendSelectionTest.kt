package com.wootodo.sync

import android.app.job.JobInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncBackendSelectionTest {
    @Test
    fun `局域网待发送任务使用固定短退避且周期任务不额外重试`() {
        assertEquals(
            JobInfo.BACKOFF_POLICY_LINEAR,
            SyncJobRetryPolicy.backoffPolicy(SyncTransportMode.LOCAL_NETWORK),
        )
        assertEquals(
            JobInfo.BACKOFF_POLICY_EXPONENTIAL,
            SyncJobRetryPolicy.backoffPolicy(SyncTransportMode.SELF_HOSTED_SERVICE),
        )
        assertTrue(SyncJobRetryPolicy.shouldReschedule(isImmediate = true, retryable = true))
        assertFalse(SyncJobRetryPolicy.shouldReschedule(isImmediate = false, retryable = true))
        assertFalse(SyncJobRetryPolicy.shouldReschedule(isImmediate = true, retryable = false))
    }

    @Test
    fun `活动同步方式明确区分局域网自建服务和WebDAV`() {
        assertEquals(
            SyncTransportMode.LOCAL_NETWORK,
            SyncTransportModePolicy.resolve(
                SyncBackend.WORKER_OR_LOCAL,
                "http://192.168.43.12:48473",
            ),
        )
        assertEquals(
            SyncTransportMode.SELF_HOSTED_SERVICE,
            SyncTransportModePolicy.resolve(
                SyncBackend.WORKER_OR_LOCAL,
                "https://sync.example.test",
            ),
        )
        assertEquals(
            SyncTransportMode.WEB_DAV,
            SyncTransportModePolicy.resolve(SyncBackend.WEB_DAV, null),
        )
    }

    @Test
    fun `显式选择决定同时保存两套凭据时启用哪一套`() {
        assertEquals(
            SyncBackend.WORKER_OR_LOCAL,
            SyncBackendSelectionPolicy.resolve(
                persistedValue = SyncBackend.WORKER_OR_LOCAL.persistedValue,
                hasWorkerOrLocalCredentials = true,
                hasWebDavCredentials = true,
            ),
        )
        assertEquals(
            SyncBackend.WEB_DAV,
            SyncBackendSelectionPolicy.resolve(
                persistedValue = SyncBackend.WEB_DAV.persistedValue,
                hasWorkerOrLocalCredentials = true,
                hasWebDavCredentials = true,
            ),
        )
    }

    @Test
    fun `旧版本未保存选择时保持WebDAV优先行为`() {
        assertEquals(
            SyncBackend.WEB_DAV,
            SyncBackendSelectionPolicy.resolve(
                persistedValue = null,
                hasWorkerOrLocalCredentials = true,
                hasWebDavCredentials = true,
            ),
        )
    }

    @Test
    fun `已选方式凭据缺失时回退到仍可用的身份`() {
        assertEquals(
            SyncBackend.WORKER_OR_LOCAL,
            SyncBackendSelectionPolicy.resolve(
                persistedValue = SyncBackend.WEB_DAV.persistedValue,
                hasWorkerOrLocalCredentials = true,
                hasWebDavCredentials = false,
            ),
        )
        assertEquals(
            SyncBackend.WEB_DAV,
            SyncBackendSelectionPolicy.resolve(
                persistedValue = SyncBackend.WORKER_OR_LOCAL.persistedValue,
                hasWorkerOrLocalCredentials = false,
                hasWebDavCredentials = true,
            ),
        )
    }

    @Test
    fun `两套凭据保留时往返切换不会退回未配对状态`() {
        val bothCredentialsAvailable = true
        val webDav = SyncBackendSelectionPolicy.resolve(
            persistedValue = SyncBackend.WEB_DAV.persistedValue,
            hasWorkerOrLocalCredentials = bothCredentialsAvailable,
            hasWebDavCredentials = bothCredentialsAvailable,
        )
        val switchedBack = SyncBackendSelectionPolicy.resolve(
            persistedValue = SyncBackend.WORKER_OR_LOCAL.persistedValue,
            hasWorkerOrLocalCredentials = bothCredentialsAvailable,
            hasWebDavCredentials = bothCredentialsAvailable,
        )

        assertEquals(SyncBackend.WEB_DAV, webDav)
        assertEquals(SyncBackend.WORKER_OR_LOCAL, switchedBack)
    }
}
