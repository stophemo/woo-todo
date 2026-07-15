package com.wootodo.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingRecoveryPolicyTest {
    @Test
    fun `进程丢失临时密钥时明确要求重新扫码`() {
        assertTrue(
            PairingRecoveryPolicy.requiresRescan(
                wasPairingInSavedState = true,
                runtimeStillActive = false,
            ),
        )
        assertFalse(
            PairingRecoveryPolicy.requiresRescan(
                wasPairingInSavedState = true,
                runtimeStillActive = true,
            ),
        )
        assertFalse(
            PairingRecoveryPolicy.requiresRescan(
                wasPairingInSavedState = false,
                runtimeStillActive = false,
            ),
        )
    }
}
