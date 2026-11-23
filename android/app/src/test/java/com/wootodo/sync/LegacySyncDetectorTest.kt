package com.wootodo.sync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LegacySyncDetectorTest {
    @Test
    fun `存在WebDAV凭据时视为旧同步用户`() {
        assertTrue(LegacySyncDetector.detects(hasWebDavCredentials = true, syncCredentialsEndpoint = null))
    }

    @Test
    fun `凭据地址不符合HTTPS Worker规则时视为旧同步用户`() {
        assertTrue(
            LegacySyncDetector.detects(
                hasWebDavCredentials = false,
                syncCredentialsEndpoint = "http://192.168.1.10:48473",
            ),
        )
        assertTrue(
            LegacySyncDetector.detects(
                hasWebDavCredentials = false,
                syncCredentialsEndpoint = "https://localhost:8787",
            ),
        )
    }

    @Test
    fun `没有旧凭据或地址有效时不是旧同步用户`() {
        assertFalse(LegacySyncDetector.detects(false, null))
        assertFalse(
            LegacySyncDetector.detects(
                hasWebDavCredentials = false,
                syncCredentialsEndpoint = "https://sync.example.test",
            ),
        )
    }
}
