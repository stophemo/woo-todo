package com.wootodo.sync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LegacySyncDetectorTest {
    @Test
    fun `存在Worker或局域网凭据时提示改为WebDAV`() {
        assertTrue(LegacySyncDetector.detects(hasWorkerOrLanCredentials = true))
    }

    @Test
    fun `没有旧凭据时不提示`() {
        assertFalse(LegacySyncDetector.detects(hasWorkerOrLanCredentials = false))
    }
}
